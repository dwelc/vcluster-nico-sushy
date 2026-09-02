#!/usr/bin/env bash

# -E so the ERR trap reaches functions and subshells.
set -Eeuo pipefail

# shellcheck source=scripts/lib.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/lib.sh"

PREREQS="${PREREQS:-}"
SRC_ROOT="${SRC_ROOT:-${PREREQS:+$(cd "${PREREQS}/.." && pwd)}}"
NICO_REST_DIR="${NICO_REST_DIR:-${SRC_ROOT}/rest-api}"
NICO_REST_HELM_DIR="${NICO_REST_HELM_DIR:-${SRC_ROOT}/helm/rest}"

# Rendered by nico-install.sh from config/*.tmpl.
CORE_VALUES="${CORE_VALUES:-}"
METALLB_CONFIG="${METALLB_CONFIG:-}"
PREREQS_OVERLAY="${PREREQS_OVERLAY:-values-demo.yaml}"   # relative to PREREQS
REST_VALUES="${REST_VALUES:-${PREREQS}/values/nico-rest.yaml}"
REST_DEMO_VALUES="${REST_DEMO_VALUES:-${PREREQS}/values/nico-rest-demo.yaml}"
SITE_AGENT_VALUES="${SITE_AGENT_VALUES:-${PREREQS}/values/nico-site-agent.yaml}"

NICO_IMAGE_REGISTRY="${NICO_IMAGE_REGISTRY:-}"
NICO_CORE_IMAGE_TAG="${NICO_CORE_IMAGE_TAG:-}"
NICO_REST_IMAGE_TAG="${NICO_REST_IMAGE_TAG:-}"
# A mirror publishing the Core image under another name sets this.
NICO_CORE_IMAGE_NAME="${NICO_CORE_IMAGE_NAME:-nvmetal-carbide}"
NICO_STORAGE_CLASS="${NICO_STORAGE_CLASS:-local-path-persistent}"
REGISTRY_PULL_SECRET="${REGISTRY_PULL_SECRET:-}"
REGISTRY_PULL_USERNAME="${REGISTRY_PULL_USERNAME:-\$oauthtoken}"

VAULT_NS="${VAULT_NS:-vault}"
CERT_MANAGER_NS="${CERT_MANAGER_NS:-cert-manager}"
NICO_SYSTEM_NS="nico-system"   # hardcoded throughout the charts; not a knob
NICO_REST_NS="nico-rest"       # ditto

# A pre-existing MetalLB rarely names its controller metallb-controller.
METALLB_NAMESPACE="${METALLB_NAMESPACE:-metallb-system}"
HELM_TIMEOUT="${HELM_TIMEOUT:-1200s}"
METALLB_DEPLOYMENT="${METALLB_DEPLOYMENT:-controller}"

# A re-run must re-adopt the existing site or a second one gets registered.
NICO_SITE_NAME="${NICO_SITE_NAME:-nicodemo}"
NICO_ORG="${NICO_ORG:-ncx}"
NICO_SITE_UUID="${NICO_SITE_UUID:-}"
NICO_EDGE_NODE="${NICO_EDGE_NODE:-}"

# nico-install.sh sets this false in platform-issuer mode.
KEYCLOAK_ENABLED="${KEYCLOAK_ENABLED:-true}"

SITE_AGENT_REPLICAS="${SITE_AGENT_REPLICAS:-}"

SKIP_REST="${SKIP_REST:-false}"
SKIP_FLOW="${SKIP_FLOW:-true}"

export REGISTRY_PULL_SECRET NICO_STORAGE_CLASS

abspath() { echo "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; }

run() {
    _RUNNING_CMD="$*"
    quiet "$@"
}

# Subshell cd: the relative chart paths resolve only from that directory.
run_in() {
    local dir="$1"; shift
    _RUNNING_CMD="(cd ${dir} && $*)"
    quiet bash -c 'cd "$1" && shift && "$@"' _ "${dir}" "$@"
}

# on cluster state it has not created.
wait_for() { # <timeout> <interval> <label> <cmd...>
    retry "$@"
}

# Under set -e the failing phase and command are recorded for the exit banner.
_PHASE_LABEL="startup"
_FAILED_COMMAND=""
# BASH_COMMAND holds only the wrapper's body, so run/run_in record their own.
_RUNNING_CMD=""
_TMPFILES=()

_on_exit() {
    local rc=$?
    if (( ${#_TMPFILES[@]} )); then rm -f "${_TMPFILES[@]}"; fi
    (( rc == 0 )) && return 0
    [[ "${_DIED}" == "true" || "${_PHASE_LABEL}" == "startup" ]] && return 0
    printf '\n%sFAILED%s phase=%s rc=%s: %s\n  resume: %s --from %s\n' \
        "${RED}" "${NC}" "${_PHASE_LABEL}" "${rc}" \
        "${_RUNNING_CMD:-${_FAILED_COMMAND:-unknown}}" "${0##*/}" "${_PHASE_LABEL}" >&2
    return 0
}
trap '_FAILED_COMMAND="${BASH_COMMAND}"' ERR
trap _on_exit EXIT

# Interpolated into SQL, so charset-restricted rather than escaped.
NAME_RE='[A-Za-z0-9][A-Za-z0-9._-]*'

ensure_namespace() {
    kubectl create namespace "$1" --dry-run=client -o yaml | kubectl apply -f -
}

# Spilo relabels on failover, so read leadership live, never by ordinal.
patroni_primary() {
    kubectl get pods -n postgres -l application=spilo \
        -o jsonpath='{range .items[*]}{.metadata.name} {.metadata.labels.spilo-role}{"\n"}{end}' \
        2>/dev/null | awk '$2=="master"{print $1}' | head -1
}

patroni_running() {
    [[ "$(kubectl get postgresql nico-pg-cluster -n postgres \
        -o jsonpath='{.status.PostgresClusterStatus}')" == "Running" ]]
}

create_pg_trgm() {
    local pod
    pod="$(patroni_primary)"
    [[ -n "${pod}" ]] || return 1
    kubectl exec -n postgres "${pod}" -- \
        su postgres -c "psql -d nico_rest -c 'CREATE EXTENSION IF NOT EXISTS pg_trgm;'"
}

vault_pki_job_done() {
    [[ -n "$(kubectl get job vault-pki-config -n "${NICO_SYSTEM_NS}" \
        -o jsonpath='{.status.succeeded}')" ]]
}

approle_ids_present() {
    local keys
    keys="$(kubectl get secret nico-vault-approle-tokens -n "${NICO_SYSTEM_NS}" \
        -o jsonpath='{.data.VAULT_ROLE_ID}{" "}{.data.VAULT_SECRET_ID}')"
    [[ "${keys}" =~ ^[^\ ]+\ [^\ ]+$ ]]
}

dockerconfigjson() {
    printf '{"auths":{"%s":{"username":"%s","password":"%s"}}}' \
        "${NICO_IMAGE_REGISTRY%%/*}" "${REGISTRY_PULL_USERNAME}" "${REGISTRY_PULL_SECRET}" \
        | base64 | tr -d '\n'
}

ensure_pull_secret() {
    local server="${NICO_IMAGE_REGISTRY%%/*}"
    [[ -n "${REGISTRY_PULL_SECRET}" ]] \
        || { info "no REGISTRY_PULL_SECRET: images must be public"; return 0; }
    kubectl create secret docker-registry imagepullsecret -n "${NICO_SYSTEM_NS}" \
        --docker-server="${server}" \
        --docker-username="${REGISTRY_PULL_USERNAME}" \
        --docker-password="${REGISTRY_PULL_SECRET}" \
        --dry-run=client -o yaml | kubectl apply -f -
    ok "imagepullsecret present in ${NICO_SYSTEM_NS}"
}

# Paths inside the admintools pod, not on this host.
TEMPORAL_ADDR="temporal-frontend.temporal:7233"
TEMPORAL_TLS="--tls-cert-path /var/secrets/temporal/certs/server-interservice/tls.crt \
--tls-key-path /var/secrets/temporal/certs/server-interservice/tls.key \
--tls-ca-path /var/secrets/temporal/certs/server-interservice/ca.crt \
--tls-server-name interservice.server.temporal.local"

# Never interpolated: the same value flows into SQL in the site_agent phase.
temporal_namespace_create() {
    local ns="$1" out
    if kubectl exec -n temporal deploy/temporal-admintools -- \
        sh -c "temporal operator namespace describe -n \"\$1\" \
            --address ${TEMPORAL_ADDR} ${TEMPORAL_TLS}" \
        sh "${ns}" >/dev/null 2>&1; then
        ok "temporal namespace for site ${ns:0:8} already exists"
        return 0
    fi
    if out="$(kubectl exec -n temporal deploy/temporal-admintools -- \
        sh -c "temporal operator namespace create -n \"\$1\" --retention 72h \
            --address ${TEMPORAL_ADDR} ${TEMPORAL_TLS}" \
        sh "${ns}" 2>&1)"; then
        ok "temporal namespace for site ${ns:0:8} created"
        return 0
    fi
    if printf '%s' "${out}" | grep -qi "already exists"; then
        ok "temporal namespace for site ${ns:0:8} already exists"
        return 0
    fi
    printf '%s\n' "${out}" >&2
    die "could not create the temporal namespace for site ${ns:0:8}"
}

# create returns before the namespace is registered cluster-wide.
temporal_namespace_verify() {
    local out missing=() ns
    out="$(kubectl exec -n temporal deploy/temporal-admintools -- \
        sh -c "temporal operator namespace list --address ${TEMPORAL_ADDR} ${TEMPORAL_TLS}" 2>&1)" \
        || { printf '%s\n' "${out}" >&2; die "could not list temporal namespaces"; }
    for ns in "$@"; do
        # grep -w mis-matches: - and _ are legal in Temporal namespace names.
        printf '%s' "${out}" \
            | grep -Eq "(^|[^[:alnum:]_-])${ns}([^[:alnum:]_-]|\$)" || missing+=("${ns}")
    done
}

do_preflight() {
    phase "preflight"
    local t
    for t in kubectl helm helmfile jq openssl ssh-keygen python3; do
        command -v "${t}" >/dev/null 2>&1 || die "required tool not found in PATH: ${t}"
    done
    local v
    for v in PREREQS NICO_IMAGE_REGISTRY NICO_CORE_IMAGE_TAG NICO_REST_IMAGE_TAG; do
        [[ -n "${!v}" ]] || die "${v} must be set"
    done
    need_file "${HELMFILE}" "this repo ships the helmfile; upstream's is unused"
    [[ -n "${CORE_VALUES}" && -f "${CORE_VALUES}" ]] \
        || die "core values not rendered: ${CORE_VALUES:-<unset>}"
    [[ "${NICO_SITE_NAME}" =~ ^${NAME_RE}$ ]] || die "bad NICO_SITE_NAME: ${NICO_SITE_NAME}"
    [[ "${NICO_ORG}" =~ ^${NAME_RE}$ ]]       || die "bad NICO_ORG: ${NICO_ORG}"
    kubectl version --request-timeout=10s >/dev/null || die "cluster unreachable"
    ok "tools, trees and cluster present"
}

# Vault's PVCs and postgresql.storageClass both name local-path-persistent.
do_storage_class() {
    phase "local-path-persistent StorageClass"
    run kubectl apply -f "${PREREQS}/operators/storageclass-local-path-persistent.yaml"
    ok "StorageClass ${NICO_STORAGE_CLASS} applied"
}

do_postgres_operator() {
    phase "postgres-operator"
    run_in "${PREREQS}" helmfile -f "${HELMFILE}" sync -l name=postgres-operator
    ok "postgres-operator installed"
}

do_metallb_config() {
    phase "MetalLB site config"
    run kubectl wait --for=condition=Available \
        "deployment/${METALLB_DEPLOYMENT}" -n "${METALLB_NAMESPACE}" --timeout=120s
    local cfg="${METALLB_CONFIG:-${PREREQS}/values/metallb-config.yaml}"
    if [[ -d "${cfg}" ]]; then
        run kubectl apply -k "${cfg}"
    elif [[ -f "${cfg}" ]]; then
        run kubectl apply -f "${cfg}"
    fi
    ok "MetalLB site config applied from ${cfg##*/}"
}

# Must precede the Vault chart: its StatefulSet mounts two of these Secrets.
do_vault_tls() {
    phase "CRDs and Vault TLS bootstrap"
    # Lab: the bundled CRDs are prometheus-operator ones; never overwrite
    # CRDs another operator owns. Apply only the missing ones.
    local crd_file crd_name
    for crd_file in "${PREREQS}"/operators/crds/*.yaml; do
        crd_name="$(grep -m1 '^  name:' "${crd_file}" | awk '{print $2}')"
        if kubectl get crd "${crd_name}" >/dev/null 2>&1; then
            info "crd ${crd_name} already present, skipping"
        else
            run kubectl apply --server-side -f "${crd_file}" \
                --field-manager=helmfile --force-conflicts
        fi
    done
    ensure_namespace "${VAULT_NS}"

    # --field-manager=helm lets nico-prereqs adopt these objects next phase.
    local overlay_args=()
    [[ -f "${PREREQS}/${PREREQS_OVERLAY}" ]] && overlay_args=(-f "${PREREQS_OVERLAY}")
    ( cd "${PREREQS}" && helm template nico-prereqs . \
        ${overlay_args[@]+"${overlay_args[@]}"} \
        --namespace "${NICO_SYSTEM_NS}" \
        --set imagePullSecrets.ngcNicoPull="${REGISTRY_PULL_SECRET}" \
        --show-only templates/site-root-certificate.yaml \
        --show-only templates/vault-tls-certs.yaml ) \
        | kubectl apply --server-side --field-manager=helm -f -

    run kubectl wait --for=condition=Ready certificate/site-root \
        -n "${CERT_MANAGER_NS}" --timeout=120s
    run kubectl wait --for=condition=Ready certificate/nicoca-vault-client \
        -n "${VAULT_NS}" --timeout=120s
    run kubectl wait --for=condition=Ready certificate/vault-raft-tls \
        -n "${VAULT_NS}" --timeout=120s
    ok "Vault TLS ready"
}

do_vault() {
    phase "vault"
    run_in "${PREREQS}" helmfile -f "${HELMFILE}" sync -l name=vault \
        --set server.dataStorage.storageClass="${NICO_STORAGE_CLASS}" \
        --set server.auditStorage.storageClass="${NICO_STORAGE_CLASS}"
    ok "vault chart installed"
}

do_vault_unseal() {
    run "${SCRIPT_DIR}/vault-init.sh"
    run_in "${PREREQS}" ./bootstrap_ssh_host_key.sh "${NICO_SYSTEM_NS}"
    ok "vault initialised and unsealed, ssh-host-key seeded"
}

do_external_secrets() {
    phase "external-secrets"
    run_in "${PREREQS}" helmfile -f "${HELMFILE}" sync -l name=external-secrets
    ok "external-secrets installed"
}

do_nico_prereqs() {
    phase "nico-prereqs"
    run_in "${PREREQS}" helmfile -f "${HELMFILE}" sync -l name=nico-prereqs

    wait_for 600 10 "postgresql/nico-pg-cluster is Running" patroni_running \
        || die "nico-pg-cluster never reached Running after 10m
  at postgresql.instances=1 Patroni strict sync has no standby; use 2 or more"

    # Installed here for a migration five phases later, whose GIN index needs it.
    wait_for 120 5 "pg_trgm on nico_rest" create_pg_trgm \
        || die "pg_trgm could not be installed on nico_rest in 120s; the [7g] GIN index needs it"

    local pg_creds="nico-system.nico.nico-pg-cluster.credentials"
    wait_for 180 5 "secret ${pg_creds} synced" \
        kubectl get secret "${pg_creds}" -n "${NICO_SYSTEM_NS}" \
        || die "ESO never synced nico-system.nico.nico-pg-cluster.credentials (180s).
  Check: kubectl describe clusterexternalsecret -n ${NICO_SYSTEM_NS}"

    wait_for 600 10 "job vault-pki-config complete" vault_pki_job_done \
        || die "the vault-pki-config Job did not complete in 10m
  check: kubectl logs job/vault-pki-config -n ${NICO_SYSTEM_NS} --all-containers"

    wait_for 120 5 "AppRole ids patched into nico-vault-approle-tokens" approle_ids_present \
        || die "nico-vault-approle-tokens still has empty VAULT_ROLE_ID/VAULT_SECRET_ID"
    ok "nico-prereqs installed and all four gates passed"
}

do_core() {
    phase "NICo Core"
    ensure_pull_secret

    # ./helm is relative to the repo root, not helm-prereqs.
    run_in "${SRC_ROOT}" helm upgrade --install nico ./helm \
        --namespace "${NICO_SYSTEM_NS}" \
        -f "${CORE_VALUES}" \
        --set-string "global.image.repository=${NICO_IMAGE_REGISTRY}/${NICO_CORE_IMAGE_NAME}" \
        --set-string "global.image.tag=${NICO_CORE_IMAGE_TAG}" \
        --timeout "${HELM_TIMEOUT}" --wait
    # Lab (Cilium L2): NiCo's PXE/API identify hosts by source IP, so their
    # Services keep externalTrafficPolicy=Local. Cilium's L2 lease holder is not
    # endpoint-aware, so the edge pods are pinned to the node the nico L2 policy
    # announces from (values/cilium-l2-nico.yaml). Charts expose no nodeSelector.
    local d
    [[ -n "${NICO_EDGE_NODE}" ]] || { ok "NICo Core installed"; return 0; }
    for d in nico-api nico-pxe nico-dhcp; do
        run kubectl patch deploy -n "${NICO_SYSTEM_NS}" "${d}" -p \
            "{\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":{\"kubernetes.io/hostname\":\"${NICO_EDGE_NODE}\"}}}}}"
        info "${d} pinned to ${NICO_EDGE_NODE}"
    done
    ok "NICo Core installed"
}

ensure_site_ca() {
    if kubectl get secret ca-signing-secret -n "${CERT_MANAGER_NS}" >/dev/null 2>&1; then
        ok "site CA already present"
        return 0
    fi
    run_in "${NICO_REST_DIR}" ./scripts/gen-site-ca.sh --namespace "${NICO_REST_NS}"
    kubectl get secret ca-signing-secret -n "${CERT_MANAGER_NS}" >/dev/null \
        || die "gen-site-ca.sh did not create ca-signing-secret in ${CERT_MANAGER_NS}"
    ok "site CA generated"
}

do_rest_bootstrap() {
    phase "NICo REST bootstrap"
    ensure_namespace "${NICO_REST_NS}"
    ensure_site_ca

    run_in "${NICO_REST_DIR}" kubectl apply -k deploy/kustomize/base/cert-manager-io
    run_in "${NICO_REST_DIR}" kubectl apply -k deploy/kustomize/base/postgres
    # Longhorn volumes carry lost+found; initdb refuses a non-empty mount point.
    run kubectl set env statefulset/postgres -n postgres PGDATA=/var/lib/postgresql/data/pgdata
    run kubectl rollout status statefulset/postgres -n postgres --timeout=180s
    ok "REST namespace, CA, ClusterIssuer and postgres ready"
}

do_keycloak() {
    phase "Keycloak"
    if [[ "${KEYCLOAK_ENABLED}" != "true" ]]; then
        info "KEYCLOAK_ENABLED=${KEYCLOAK_ENABLED}, skipping"
        return 0
    fi
    run_in "${PREREQS}" ./keycloak/setup.sh
    ok "Keycloak ready"
}

do_temporal_tls() {
    phase "Temporal TLS bootstrap"
    local b="deploy/kustomize/base/temporal-helm"
    run_in "${NICO_REST_DIR}" kubectl apply -f "${b}/namespace.yaml"
    run_in "${NICO_REST_DIR}" kubectl apply -f "${b}/db-creds.yaml"
    run_in "${NICO_REST_DIR}" kubectl apply -f "${b}/certificates.yaml"

    local c
    for c in server-interservice-cert server-cloud-cert server-site-cert; do
        run kubectl wait --for=condition=Ready "certificate/${c}" \
            -n temporal --timeout=120s
    done
    ok "Temporal namespace, db-creds and three mTLS certificates ready"
}

do_temporal() {
    phase "Temporal"
    # Vendored chart: no `helm dependency update` needed.
    run helm upgrade --install temporal "${NICO_REST_DIR}/temporal-helm/temporal" \
        --namespace temporal \
        -f "${NICO_REST_DIR}/temporal-helm/temporal/values-kind.yaml" \
        --timeout "${HELM_TIMEOUT}" --wait

    run kubectl rollout status deploy/temporal-frontend -n temporal --timeout=120s
    run kubectl rollout status deploy/temporal-admintools -n temporal --timeout=120s
    wait_for 120 5 "Temporal API accepts namespace operations" \
        bash -c "kubectl exec -n temporal deploy/temporal-admintools -- \
            sh -c 'temporal operator namespace list --address ${TEMPORAL_ADDR} ${TEMPORAL_TLS}'" \
        || die "the Temporal frontend never accepted namespace operations (120s).
  Check the mTLS certs mounted at /var/secrets/temporal/certs and the frontend logs."

    # flow is created even with --skip-flow: the Flow workers panic without it.
    local ns
    for ns in cloud site flow; do
        temporal_namespace_create "${ns}"
    done
    temporal_namespace_verify cloud site flow
    ok "Temporal ready"
}

rest_creds_file() {
    local f u p
    f="$(mktemp)"; chmod 600 "${f}"
    _TMPFILES+=("${f}")   # cleaned by the EXIT trap; upstream leaks this file
    u="$(kubectl get secret nico-rest-pg-creds -n "${NICO_REST_NS}" \
        -o jsonpath='{.data.username}' | base64 -d)"
    p="$(kubectl get secret nico-rest-pg-creds -n "${NICO_REST_NS}" \
        -o jsonpath='{.data.password}' | base64 -d)"
    printf 'nico-rest-common:\n  secrets:\n    dbCreds:\n' > "${f}"
    printf '      username: "%s"\n      password: "%s"\n' \
        "${u}" "${p}" >> "${f}"
    cat >> "${f}" <<'YAML'
nico-rest-workflow:
  secrets:
    dbCreds: "db-creds"
  config:
    db:
      host: "nico-pg-cluster.postgres.svc.cluster.local"
      name: "nico_rest"
      user: "nico-rest.nico"
YAML
    printf '%s' "${f}"
}

do_rest() {
    phase "NICo REST"
    wait_for 120 5 "secret nico-rest-pg-creds synced by ESO" \
        kubectl get secret nico-rest-pg-creds -n "${NICO_REST_NS}" \
        || die "nico-rest-pg-creds was not synced after 120s
  check: kubectl describe clusterexternalsecret nico-rest-db-eso"

    local creds args
    creds="$(rest_creds_file)"
    args=(
        helm upgrade --install nico-rest "${NICO_REST_HELM_DIR}/nico-rest"
        --namespace "${NICO_REST_NS}"
        -f "${REST_VALUES}"
    )
    [[ -f "${REST_DEMO_VALUES}" ]] && args+=(-f "${REST_DEMO_VALUES}")
    args+=(
        -f "${creds}"
        --set "global.image.repository=${NICO_IMAGE_REGISTRY}"
        --set "global.image.tag=${NICO_REST_IMAGE_TAG}"
        --timeout "${HELM_TIMEOUT}" --wait
    )
    [[ -n "${REGISTRY_PULL_SECRET}" ]] && args+=(
        --set "nico-rest-common.secrets.imagePullSecret.dockerconfigjson=$(dockerconfigjson)")
    run "${args[@]}"
    rm -f "${creds}"
    run kubectl rollout status deploy/nico-rest-site-manager -n "${NICO_REST_NS}" --timeout=300s
    ok "NICo REST installed"
}

resolve_site_uuid() {
    _PRIOR_CLUSTER_ID="$(kubectl get configmap nico-rest-site-agent-config -n "${NICO_REST_NS}" \
        -o jsonpath='{.data.CLUSTER_ID}' 2>/dev/null || true)"

    if [[ -n "${NICO_SITE_UUID}" ]]; then
        info "site uuid supplied: ${NICO_SITE_UUID}"
    else
        _uuid_file="$(mktemp)"
        SITE_NAME="${NICO_SITE_NAME}" NICO_REST_NS="${NICO_REST_NS}" \
            REST_ORG="${NICO_ORG}" \
            bash "$(dirname "${BASH_SOURCE[0]}")/nico-day0.sh" --only site \
            --site-uuid-file "${_uuid_file}" >/dev/null \
            || die "nico-day0.sh --only site failed"
        NICO_SITE_UUID="$(tr -d ' \r\n' < "${_uuid_file}")"
        rm -f "${_uuid_file}"
        info "site '${NICO_SITE_NAME}' registered through the REST API: ${NICO_SITE_UUID}"
    fi
    [[ "${NICO_SITE_UUID}" =~ ^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$ ]] \
        || die "resolved NICO_SITE_UUID is not a valid UUID: '${NICO_SITE_UUID}'"
}

do_site_agent() {
    phase "NICo REST site-agent"
    _PRIOR_CLUSTER_ID=""
    resolve_site_uuid

    if kubectl get secret site-registration -n "${NICO_REST_NS}" >/dev/null 2>&1 \
       && [[ -n "${_PRIOR_CLUSTER_ID}" && "${_PRIOR_CLUSTER_ID}" != "${NICO_SITE_UUID}" ]]; then
        warn "site-registration holds stale UUID ${_PRIOR_CLUSTER_ID}; deleting"
        kubectl delete secret site-registration -n "${NICO_REST_NS}" >/dev/null
    fi

    local args=(
        --namespace "${NICO_REST_NS}"
        -f "${SITE_AGENT_VALUES}"
        --set "global.image.repository=${NICO_IMAGE_REGISTRY}"
        --set "global.image.tag=${NICO_REST_IMAGE_TAG}"
    )
    [[ -n "${REGISTRY_PULL_SECRET}" ]] \
        && args+=(--set "global.imagePullSecrets[0].name=image-pull-secret")
    [[ -n "${SITE_AGENT_REPLICAS}" ]] && args+=(--set "replicaCount=${SITE_AGENT_REPLICAS}")

    helm template nico-rest-site-agent "${NICO_REST_HELM_DIR}/nico-rest-site-agent" \
        "${args[@]}" --show-only templates/certificate.yaml | kubectl apply -f -
    kubectl annotate certificate/core-grpc-client-site-agent-certs -n "${NICO_REST_NS}" \
        "meta.helm.sh/release-name=nico-rest-site-agent" \
        "meta.helm.sh/release-namespace=${NICO_REST_NS}" --overwrite
    kubectl label certificate/core-grpc-client-site-agent-certs -n "${NICO_REST_NS}" \
        "app.kubernetes.io/managed-by=Helm" --overwrite
    run kubectl wait --for=condition=Ready certificate/core-grpc-client-site-agent-certs \
        -n "${NICO_REST_NS}" --timeout=120s

    # The site-agent panics on startup without its per-site Temporal namespace.
    temporal_namespace_create "${NICO_SITE_UUID}"
    temporal_namespace_verify "${NICO_SITE_UUID}"

    local flow_grpc=true
    [[ "${SKIP_FLOW}" == "true" ]] && flow_grpc=false

    run helm upgrade --install nico-rest-site-agent \
        "${NICO_REST_HELM_DIR}/nico-rest-site-agent" \
        "${args[@]}" \
        --set "envConfig.CLUSTER_ID=${NICO_SITE_UUID}" \
        --set "envConfig.TEMPORAL_SUBSCRIBE_NAMESPACE=${NICO_SITE_UUID}" \
        --set "envConfig.TEMPORAL_SUBSCRIBE_QUEUE=site" \
        --set "envConfig.FLOW_GRPC_ENABLED=${flow_grpc}" \
        --timeout "${HELM_TIMEOUT}" --wait
    ok "site-agent deployed for site ${NICO_SITE_UUID:0:8}"

    verify_site_agent_grpc
}

site_agent_connected() {
    local pods pod logs
    pods="$(kubectl get pods -n "${NICO_REST_NS}" \
        -l app.kubernetes.io/name=nico-rest-site-agent \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)"
    [[ -n "${pods}" ]] || return 1
    while IFS= read -r pod; do
        [[ -n "${pod}" ]] || continue
        logs="$(kubectl logs -n "${NICO_REST_NS}" "${pod}" 2>/dev/null || true)"
        if grep -Eqi \
            'CoreGrpcClient: Successfully connected to server|Successfully registered InvokeCoreGRPC workflow and activity' \
            <<<"${logs}"; then
            return 0
        fi
    done <<<"${pods}"
    return 1
}

verify_site_agent_grpc() {
    if site_agent_connected; then
        ok "site-agent already reached NICo Core"
        return 0
    fi
    info "restarting the site-agent, which does not reach Core on its first start"
    quiet kubectl rollout restart statefulset/nico-rest-site-agent -n "${NICO_REST_NS}"
    quiet kubectl rollout status statefulset/nico-rest-site-agent -n "${NICO_REST_NS}" \
        --timeout=180s
    wait_for "${SITE_AGENT_GRPC_WAIT:-300}" 10 "site-agent connecting to NICo Core" \
        site_agent_connected ||
        warn "site-agent never confirmed a Core gRPC connection"
}

PHASES=(
    preflight
    storage_class
    postgres_operator
    metallb_config
    vault_tls
    vault
    vault_unseal
    external_secrets
    nico_prereqs
    core
    rest_bootstrap
    keycloak
    temporal_tls
    temporal
    rest
    site_agent
)
REST_PHASES=" rest_bootstrap keycloak temporal_tls temporal rest site_agent "

usage() {
    cat <<'USAGE'
nico-setup.sh - install the NICo phases this demo needs.

  --core-values <file>          values file for the Core chart
  --metallb-config <file|dir>   MetalLB site config
  --skip-rest                   skip every NICo REST phase
  --skip-flow                   FLOW_GRPC_ENABLED=false on the site-agent
  --from <phase>                resume from this phase; every phase is idempotent
  -h, --help                    this text
USAGE
}

FROM=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-rest)      SKIP_REST=true; shift ;;
        --skip-flow)      SKIP_FLOW=true; shift ;;
        --core-values)    CORE_VALUES="$(abspath "${2:?needs a file}")"; shift 2 ;;
        --metallb-config) METALLB_CONFIG="$(abspath "${2:?needs a path}")"; shift 2 ;;
        --from)           FROM="${2:?--from needs a phase}"; shift 2 ;;
        -h|--help)        usage; exit 0 ;;
        *)                usage >&2; die "unknown argument: $1" ;;
    esac
done

if [[ -n "${FROM}" ]]; then
    printf '%s\n' "${PHASES[@]}" | grep -qxF "${FROM}" || die "unknown phase: ${FROM}"
fi

started=false
[[ -n "${FROM}" ]] || started=true
_PLANNED=0
for _p in "${PHASES[@]}"; do
    [[ "${_p}" == "${FROM}" ]] && started=true
    [[ "${started}" == true ]] || continue
    [[ "${SKIP_REST}" == "true" && "${REST_PHASES}" == *" ${_p} "* ]] && continue
    _PLANNED=$((_PLANNED + 1))
done
started=false
[[ -n "${FROM}" ]] || started=true
_DONE=0
_T0="$(date +%s)"
for _p in "${PHASES[@]}"; do
    [[ "${_p}" == "${FROM}" ]] && started=true
    [[ "${started}" == true ]] || continue
    [[ "${SKIP_REST}" == "true" && "${REST_PHASES}" == *" ${_p} "* ]] && continue
    _DONE=$((_DONE + 1))
    _PHASE_LABEL="${_p}"
    PHASE_PREFIX="${_DONE}/${_PLANNED}" PHASE_ELAPSED="$(( ($(date +%s) - _T0) / 60 ))m" \
        "do_${_p}"
done

_PHASE_LABEL="complete"
phase "done"
ok "NICo installed"
