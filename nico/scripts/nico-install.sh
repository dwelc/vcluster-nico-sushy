#!/usr/bin/env bash
# shellcheck disable=SC2034
set -euo pipefail

# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NICO_REPO_URL="${NICO_REPO_URL:-https://github.com/NVIDIA/infra-controller.git}"
# An existing checkout to copy rather than clone. Never mutated.
NICO_SRC_DIR="${NICO_SRC_DIR:-}"
NICO_WORKDIR="${NICO_WORKDIR:-/var/tmp/nico-install-${NICO_VERSION}}"
export KUBECONFIG="${KUBECONFIG:-${REMOTE_KUBECONFIG}}"

# --- images ------------------------------------------------------------------
NICO_CORE_IMAGE_TAG="${NICO_CORE_IMAGE_TAG:-${NICO_VERSION}}"
NICO_REST_IMAGE_TAG="${NICO_REST_IMAGE_TAG:-${NICO_VERSION}}"
BOOT_ARTIFACTS_ENABLED="${BOOT_ARTIFACTS_ENABLED:-true}"
BOOT_ARTIFACTS_X86_REPO="${BOOT_ARTIFACTS_X86_REPO:-${NICO_IMAGE_REGISTRY}/boot-artifacts-x86_64}"
BOOT_ARTIFACTS_X86_TAG="${BOOT_ARTIFACTS_X86_TAG:-${NICO_CORE_IMAGE_TAG}}"
_BOOT_DEST=/forge-boot-artifacts/blobs/internal
BOOT_ARTIFACTS_X86_COMMAND="${BOOT_ARTIFACTS_X86_COMMAND:-cp -r /x86_64 ${_BOOT_DEST}}"

REGISTRY_PULL_SECRET="${REGISTRY_PULL_SECRET:-}"
REGISTRY_PULL_USERNAME="${REGISTRY_PULL_USERNAME:-janekbaraniewski}"

# Third-party images pulled by Core subcharts. unbound ships repository: "".
NTP_IMAGE_REPOSITORY="${NTP_IMAGE_REPOSITORY:-dockurr/chrony}"
NTP_IMAGE_TAG="${NTP_IMAGE_TAG:-latest}"
UNBOUND_IMAGE_REPOSITORY="${UNBOUND_IMAGE_REPOSITORY:-madnuttah/unbound}"
# The chart renders repository:tag, so a digest has to ride in the tag.
_UNBOUND_DIGEST=sha256:7bcb11b0c8c54a1b8807bb452b59f112791c42801c5cf43b98931d4b584275a1
UNBOUND_IMAGE_TAG="${UNBOUND_IMAGE_TAG:-latest@${_UNBOUND_DIGEST}}"

SITE_NAME="${SITE_NAME:-${NICO_SITE_NAME}}"
SITE_DOMAIN="${SITE_DOMAIN:-${NICO_SITE_DOMAIN}}"
API_HOSTNAME="${API_HOSTNAME:-api-${SITE_NAME}.${SITE_DOMAIN}}"
BRIDGE_GW="${BRIDGE_GW:-${GATEWAY}}"
BRIDGE_PREFIX="${BRIDGE_PREFIX:-${BRIDGE_CIDR}}"
BRIDGE_REVERSE_ZONE="$(printf '%s' "${BRIDGE_PREFIX%%/*}" |
    awk -F. '{print $3"."$2"."$1".in-addr.arpa"}')"

METALLB_INTERNAL_RANGE="${METALLB_INTERNAL_RANGE:-${NICO_METALLB_INTERNAL}}"
METALLB_EXTERNAL_RANGE="${METALLB_EXTERNAL_RANGE:-${NICO_METALLB_EXTERNAL}}"
VIP_DHCP="${NICO_VIP_DHCP}" VIP_DNS_0="${NICO_VIP_DNS_0}" VIP_DNS_1="${NICO_VIP_DNS_1}"
VIP_PXE="${NICO_VIP_PXE}" VIP_NTP_0="${NICO_VIP_NTP_0}" VIP_NTP_1="${NICO_VIP_NTP_1}"
VIP_NTP_2="${NICO_VIP_NTP_2}" VIP_SSH_CONSOLE="${NICO_VIP_SSH_CONSOLE}"
VIP_UNBOUND="${NICO_VIP_UNBOUND}" VIP_API="${NICO_VIP_API}"

# The FLAT tenant underlay: br0 itself.
HOSTINBAND_NAME="${HOSTINBAND_NAME:-demo-inband}"
HOSTINBAND_PREFIX="${HOSTINBAND_PREFIX:-${BRIDGE_PREFIX}}"
HOSTINBAND_GATEWAY="${HOSTINBAND_GATEWAY:-${BRIDGE_GW}}"
HOSTINBAND_MTU="${HOSTINBAND_MTU:-1500}"
HOSTINBAND_ALLOCATION_STRATEGY="${HOSTINBAND_ALLOCATION_STRATEGY:-dynamic}"

OOB_NAME="${OOB_NAME:-demo-oob}"
OOB_PREFIX="${OOB_PREFIX:?set in config/site.env}"
OOB_GW="${OOB_GW:?set in config/site.env}"
OOB_MTU="${OOB_MTU:-1500}"
OOB_RESERVE_FIRST="${OOB_RESERVE_FIRST:-1}"

ADMIN_PREFIX="${ADMIN_PREFIX:-192.168.176.0/20}"
ADMIN_GW="${ADMIN_GW:-192.168.176.1}"
ADMIN_MTU="${ADMIN_MTU:-1500}"
ADMIN_RESERVE_FIRST="${ADMIN_RESERVE_FIRST:-1}"
ADMIN_SEGMENT_TYPE_NON_DPU="${ADMIN_SEGMENT_TYPE_NON_DPU:-false}"
ALLOW_INSECURE_DISCOVERY="${ALLOW_INSECURE_DISCOVERY:-true}"
ALLOW_BMC_BASIC_AUTH_FALLBACK="${ALLOW_BMC_BASIC_AUTH_FALLBACK:-true}"

# --- resource pools ----------------------------------------------------------
POOL_LO_IP_START="${POOL_LO_IP_START:-10.203.0.1}"
POOL_LO_IP_END="${POOL_LO_IP_END:-10.203.0.254}"
POOL_VLAN_START="${POOL_VLAN_START:-100}"
POOL_VLAN_END="${POOL_VLAN_END:-501}"
POOL_VNI_START="${POOL_VNI_START:-1024500}"
POOL_VNI_END="${POOL_VNI_END:-1024800}"
POOL_VPC_VNI_START="${POOL_VPC_VNI_START:-2024500}"
POOL_VPC_VNI_END="${POOL_VPC_VNI_END:-2024800}"
POOL_EXT_VPC_VNI_START="${POOL_EXT_VPC_VNI_START:-3024500}"
POOL_EXT_VPC_VNI_END="${POOL_EXT_VPC_VNI_END:-3024800}"
POOL_FNN_ASN_START="${POOL_FNN_ASN_START:-4268060405}"
POOL_FNN_ASN_END="${POOL_FNN_ASN_END:-4268060499}"
SITE_IP_BLOCK_CIDR="${SITE_IP_BLOCK_CIDR:-10.210.0.0/24}"
DATACENTER_ASN="${DATACENTER_ASN:-4266030000}"
ADMIN_VPC_VNI="${ADMIN_VPC_VNI:-61325}"

POSTGRES_INSTANCES="${POSTGRES_INSTANCES:-3}"
VAULT_REPLICAS="${VAULT_REPLICAS:-3}"
NICO_STORAGE_CLASS="${NICO_STORAGE_CLASS:?set in config/site.env}"
VAULT_CPU_REQUEST="${VAULT_CPU_REQUEST:-250m}"
VAULT_MEM_REQUEST="${VAULT_MEM_REQUEST:-512Mi}"
VAULT_CPU_LIMIT="${VAULT_CPU_LIMIT:-2000m}"
VAULT_MEM_LIMIT="${VAULT_MEM_LIMIT:-2Gi}"

# LB_MODE=cilium: Cilium LB-IPAM + L2 (VIPs pinned per Service, nico-system announced only from
# NICO_EDGE_NODE). LB_MODE=metallb: MetalLB pools + L2Advertisement, no pinning needed.
LB_MODE="${LB_MODE:-cilium}"
case "${LB_MODE}" in
    cilium)
        METALLB_NAMESPACE="${METALLB_NAMESPACE:-kube-system}"
        METALLB_DEPLOYMENT="${METALLB_DEPLOYMENT:-cilium-operator}"
        LB_IPS_ANNOTATION="lbipam.cilium.io/ips"
        LB_SHARING_ANNOTATION="lbipam.cilium.io/sharing-key"
        LB_TEMPLATE="lb-cilium.yaml.tmpl"
        [[ -n "${NICO_EDGE_NODE:-}" && -n "${L2_INTERFACE:-}" ]] || die "LB_MODE=cilium needs NICO_EDGE_NODE and L2_INTERFACE in config/site.env"
        ;;
    metallb)
        METALLB_NAMESPACE="${METALLB_NAMESPACE:-metallb-system}"
        METALLB_DEPLOYMENT="${METALLB_DEPLOYMENT:-controller}"
        LB_IPS_ANNOTATION="metallb.universe.tf/loadBalancerIPs"
        LB_SHARING_ANNOTATION="metallb.universe.tf/allow-shared-ip"
        LB_TEMPLATE="lb-metallb.yaml.tmpl"
        NICO_EDGE_NODE=""
        ;;
    *) die "LB_MODE must be cilium or metallb" ;;
esac
NICO_SKIP_DHCP_RELAY="${NICO_SKIP_DHCP_RELAY:-true}"   # relay lives on the sushy host, done by hand
# Holds the Core chart's legacy-alias ExternalName Services.
FORGE_SYSTEM_NS="${FORGE_SYSTEM_NS:-forge-system}"

PLATFORM_ISSUER_NAME="${PLATFORM_ISSUER_NAME:-vcluster-platform}"
PLATFORM_ISSUER_URL="${PLATFORM_ISSUER_URL:-}"
PLATFORM_JWKS_URL="${PLATFORM_JWKS_URL:-}"
# aud is the NodeProvider endpoint, so this must equal what install.sh sets.
PLATFORM_AUDIENCE="${PLATFORM_AUDIENCE:-http://$(nico_rest_authority)}"

SKIP_FLOW="${SKIP_FLOW:-true}"
SKIP_REST="${SKIP_REST:-false}"
ASSUME_YES="${ASSUME_YES:-false}"

confirm() {
    [[ "${ASSUME_YES}" == "true" ]] && return 0
    local answer
    read -r -p "    $* [y/N] " answer
    [[ "${answer}" == [yY] ]]
}

usage() {
    sed -n '4,9p' "$0" | sed 's/^# \{0,1\}//'
    cat <<'HELP'

USAGE
  nico-install.sh [-y] [--with-flow] [--skip-rest] [--workdir DIR]

  -y, --yes         Non-interactive.
      --with-flow   Install NICo Flow, which is skipped by default.
      --skip-rest   Prereqs and Core only: no instance types, VPCs or instances.
      --workdir DIR Where to check out upstream and render the values.

Everything else is an environment variable, listed at the top of this file.
config/demo.env supplies the versions, namespaces, VIPs and site identity.
HELP
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)    ASSUME_YES=true ;;
        --with-flow) SKIP_FLOW=false ;;
        --skip-flow) SKIP_FLOW=true ;;
        --skip-rest) SKIP_REST=true ;;
        --workdir)   shift; NICO_WORKDIR="${1:?--workdir needs a value}" ;;
        -h|--help)   usage; exit 0 ;;
        *)           die "unknown argument: $1 (try --help)" ;;
    esac
    shift
done

phase "Phase 0: preflight"

for tool in kubectl helm helmfile jq git envsubst ssh-keygen curl; do need "${tool}"; done
ok "helmfile $(helmfile --version | head -1)  (verified with v1.7.4, helm-diff 3.15.11)"

[[ -r "${KUBECONFIG}" ]] || die "KUBECONFIG is missing or unreadable: ${KUBECONFIG}"
kubectl cluster-info >/dev/null 2>&1 ||
    die "cannot reach the cluster with KUBECONFIG=${KUBECONFIG}"
ok "cluster reachable (KUBECONFIG=${KUBECONFIG})"

if [[ -e "${NICO_WORKDIR}" ]]; then
    probe="${NICO_WORKDIR}/.write-probe.$$"
    (: >"${probe}") 2>/dev/null ||
        die "workdir not writable by $(id -un): ${NICO_WORKDIR} (disposable: sudo rm -rf it)"
    rm -f "${probe}"
fi

nodes="$(kq get nodes --no-headers | wc -l | tr -d ' ')"
[[ "${nodes}" == 1 ]] ||
    warn "postgres=${POSTGRES_INSTANCES}, vault=${VAULT_REPLICAS} on ${nodes} nodes"

if [[ -z "${OOB_PREFIX}" ]]; then
    OOB_PREFIX="$(kubectl create service clusterip _nico_probe_ \
        --clusterip=1.1.1.1 --tcp=1:1 --dry-run=server -o yaml 2>&1 |
        grep -m1 -oE '[0-9.]+/[0-9]+' || true)"
    [[ -n "${OOB_PREFIX}" ]] ||
        die "could not detect the Service CIDR; set OOB_PREFIX and OOB_GW"
fi
[[ -n "${OOB_GW}" ]] ||
    OOB_GW="$(echo "${OOB_PREFIX}" | cut -d/ -f1 | awk -F. '{print $1"."$2"."$3"."($4+1)}')"
ok "OOB/BMC network (underlay): ${OOB_PREFIX} gw ${OOB_GW}"

[[ "${OOB_PREFIX%%/*}" != "${HOSTINBAND_PREFIX%%/*}" &&
   "${ADMIN_PREFIX%%/*}" != "${HOSTINBAND_PREFIX%%/*}" &&
   "${ADMIN_PREFIX%%/*}" != "${OOB_PREFIX%%/*}" ]] ||
    die "OOB ${OOB_PREFIX}, HostInband ${HOSTINBAND_PREFIX} and admin
  ${ADMIN_PREFIX} must not overlap"
ok "images: ${NICO_IMAGE_REGISTRY} core=${NICO_CORE_IMAGE_TAG} rest=${NICO_REST_IMAGE_TAG}"

phase "Phase 1: upstream source at ${NICO_VERSION}"

SRC="${NICO_WORKDIR}/src"
mkdir -p "${NICO_WORKDIR}"

if [[ -d "${SRC}/.git" ]]; then
    info "reusing ${SRC}"
    git -C "${SRC}" fetch --tags --prune origin >/dev/null 2>&1 ||
        warn "could not fetch; using what is on disk"
elif [[ -n "${NICO_SRC_DIR}" ]]; then
    [[ -d "${NICO_SRC_DIR}/.git" ]] || die "NICO_SRC_DIR is not a git checkout: ${NICO_SRC_DIR}"
    info "copying ${NICO_SRC_DIR} -> ${SRC} (the source is never modified)"
    rm -rf "${SRC}"
    cp -a "${NICO_SRC_DIR}" "${SRC}"
    # The copy's default remote may be a personal fork.
    git -C "${SRC}" remote get-url upstream >/dev/null 2>&1 ||
        git -C "${SRC}" remote add upstream "${NICO_REPO_URL}" >/dev/null
    git -C "${SRC}" fetch --tags --prune upstream >/dev/null 2>&1 ||
        warn "could not fetch upstream; relying on the tags already present"
else
    info "cloning ${NICO_REPO_URL} at ${NICO_VERSION} (shallow)"
    rm -rf "${SRC}"
    git clone --depth 1 --branch "${NICO_VERSION}" "${NICO_REPO_URL}" "${SRC}" >/dev/null 2>&1 ||
        die "clone of ${NICO_REPO_URL} at tag ${NICO_VERSION} failed"
fi

git -C "${SRC}" rev-parse -q --verify "refs/tags/${NICO_VERSION}" >/dev/null 2>&1 ||
    die "tag ${NICO_VERSION} is not in ${SRC}. With NICO_SRC_DIR set, that checkout is
  missing the tag: git fetch upstream --tags, or unset NICO_SRC_DIR to clone fresh."
git -C "${SRC}" -c advice.detachedHead=false checkout -q "${NICO_VERSION}"
git -C "${SRC}" reset -q --hard "${NICO_VERSION}"
git -C "${SRC}" clean -qfdx -e .dpf-src 2>/dev/null || true

SRC_COMMIT="$(git -C "${SRC}" rev-parse HEAD)"
ok "checked out ${NICO_VERSION} = ${SRC_COMMIT}"

PREREQS="${SRC}/helm-prereqs"
for file in bootstrap_ssh_host_key.sh values.yaml; do
    need_file "${PREREQS}/${file}" "unexpected tree layout for ${NICO_VERSION}"
done

phase "Phase 2: render the site values"

VALUES_DIR="${PREREQS}/values"
CORE_VALUES="${VALUES_DIR}/nico-core-demo.yaml"
METALLB_CONFIG="${VALUES_DIR}/metallb-config-demo.yaml"
DEMO_VALUES="${NICO_WORKDIR}/values"
mkdir -p "${DEMO_VALUES}"
PREREQS_OVERLAY="${DEMO_VALUES}/nico-prereqs.yaml"
REST_OVERLAY_NAME="nico-rest-demo.yaml"
REST_OVERLAY="${VALUES_DIR}/${REST_OVERLAY_NAME}"
VAULT_OVERLAY="${DEMO_VALUES}/vault.yaml"

export NICO_SITE_NAME="${SITE_NAME}"

((POSTGRES_INSTANCES >= 2)) ||
    die "POSTGRES_INSTANCES=${POSTGRES_INSTANCES}: patroni synchronous_mode_strict is hardcoded,
  so one instance has no sync standby and blocks every commit. Use 2 or more."

render "nico-prereqs.yaml.tmpl" >"${PREREQS_OVERLAY}"
render "${LB_TEMPLATE}" >"${METALLB_CONFIG}"
ok "rendered the prereqs overlay (postgres=${POSTGRES_INSTANCES}) and the MetalLB L2 config"

if [[ "${BOOT_ARTIFACTS_ENABLED}" == "true" ]]; then
    BOOT_ARTIFACT_CONTAINERS_YAML="$(
        cat <<ARTIFACTS

    - name: boot-artifacts-x86-64
      repository: "${BOOT_ARTIFACTS_X86_REPO}"
      tag: "${BOOT_ARTIFACTS_X86_TAG}"
      command: ["sh", "-c", "${BOOT_ARTIFACTS_X86_COMMAND}"]
ARTIFACTS
    )"
else
    BOOT_ARTIFACT_CONTAINERS_YAML=" []"
    warn "BOOT_ARTIFACTS_ENABLED=false: host HTTP boot will 404 and nothing provisions"
fi

render "nico-core.yaml.tmpl" >"${CORE_VALUES}"
ok "rendered ${CORE_VALUES##*/}"

KEYCLOAK_ENABLED="${KEYCLOAK_ENABLED:-true}"

if [[ "${PLATFORM_TRUST:-false}" == "true" &&
      -z "${PLATFORM_ISSUER_URL}" && -z "${PLATFORM_JWKS_URL}" ]]; then
    _lh="$(kq get --raw /apis/management.loft.sh/v1/configs/loft-manager-config |
           jq -r '.status.loftHost // empty')"
    if [[ -n "${_lh}" ]]; then
        PLATFORM_ISSUER_URL="https://${_lh#http*://}/oidc"
        PLATFORM_JWKS_URL="http://loft.${PLATFORM_NS}.svc.cluster.local:80/oidc/keys"
        info "platform issuer discovered: ${PLATFORM_ISSUER_URL}"
    else
        info "no Platform config readable, leaving the bundled Keycloak in place"
    fi
fi
if [[ -n "${PLATFORM_ISSUER_URL}" && -z "${PLATFORM_JWKS_URL}" ]] ||
   [[ -z "${PLATFORM_ISSUER_URL}" && -n "${PLATFORM_JWKS_URL}" ]]; then
    die "PLATFORM_ISSUER_URL and PLATFORM_JWKS_URL must be set together"
fi

render "nico-rest.yaml.tmpl" >"${REST_OVERLAY}"
if [[ -n "${PLATFORM_ISSUER_URL}" && -n "${PLATFORM_JWKS_URL}" ]]; then
    ok "rendered ${REST_OVERLAY##*/} (issuers: Keycloak and ${PLATFORM_ISSUER_URL})"
else
    ok "rendered ${REST_OVERLAY##*/} (bundled Keycloak)"
fi

phase "Phase 3: single-node patches to the workdir copy"

render "vault.yaml.tmpl" >"${VAULT_OVERLAY}"
ok "rendered the vault overlay (anti-affinity off, resources reduced)"

TEMPORAL_VALUES_KIND="${NICO_WORKDIR}/src/rest-api/temporal-helm/temporal/values-kind.yaml"
need_file "${TEMPORAL_VALUES_KIND}" "Temporal values"
if grep -q '^    type: NodePort$' "${TEMPORAL_VALUES_KIND}"; then
    [[ "$(grep -c '^    type: NodePort$' "${TEMPORAL_VALUES_KIND}")" == 1 ]] ||
        die "unexpected number of Temporal NodePort service blocks"
    [[ "$(grep -c '^    nodePort: 30233$' "${TEMPORAL_VALUES_KIND}")" == 1 ]] ||
        die "Temporal values no longer pin the expected nodePort 30233"
    temporal_tmp="${TEMPORAL_VALUES_KIND}.tmp"
    sed -e 's/^    type: NodePort$/    type: ClusterIP/' \
        -e '/^    nodePort: 30233$/d' \
        "${TEMPORAL_VALUES_KIND}" > "${temporal_tmp}"
    mv "${temporal_tmp}" "${TEMPORAL_VALUES_KIND}"
fi
grep -q '^    type: ClusterIP$' "${TEMPORAL_VALUES_KIND}" ||
    die "Temporal web service was not patched to ClusterIP"
ok "patched Temporal web to ClusterIP (no fixed NodePort collision)"

phase "Phase 3b: the host DHCP relay"

if [[ "${NICO_SKIP_DHCP_RELAY}" == "true" ]]; then
    info "NICO_SKIP_DHCP_RELAY=true: leaving the host relay alone"
elif ! have_host; then
    warn "host transport unavailable. Arm the relay on the host yourself:"
    warn "  sudo nico-demo-set-dhcp-vip ${VIP_DHCP}"
elif on_host "sudo nico-demo-set-dhcp-vip ${VIP_DHCP}" >/dev/null 2>&1; then
    ok "nico-dhcp-relay armed on ${SSH_HOST}: ${BRIDGE} -> ${VIP_DHCP}"
else
    warn "could not arm the relay on ${SSH_HOST}; check: journalctl -u nico-dhcp-relay"
fi

phase "Phase 4: hand off to nico-setup.sh"

SETUP_ARGS=(--core-values "${CORE_VALUES}" --metallb-config "${METALLB_CONFIG}")
[[ -z "${NICO_FROM:-}" ]] || SETUP_ARGS+=(--from "${NICO_FROM}")
[[ "${SKIP_FLOW}" != "true" ]] || SETUP_ARGS+=(--skip-flow)
[[ "${SKIP_REST}" != "true" ]] || SETUP_ARGS+=(--skip-rest)

confirm "install NICo ${NICO_VERSION} into this cluster now?" || die "aborted by user"

if [[ -z "${NICO_SITE_UUID:-}" ]]; then
    existing="$(nico_site_uuid)"
    if [[ -n "${existing}" ]]; then
        export NICO_SITE_UUID="${existing}"
        ok "reusing the site UUID from a previous install: ${NICO_SITE_UUID}"
    fi
fi

kubectl create namespace "${FORGE_SYSTEM_NS}" --dry-run=client -o yaml |
    kubectl apply -f - >/dev/null
ok "namespace ${FORGE_SYSTEM_NS} present (the Core chart's legacy aliases target it)"

# What nico-setup.sh reads from the environment.
export NICO_IMAGE_REGISTRY NICO_CORE_IMAGE_TAG NICO_REST_IMAGE_TAG NICO_CORE_IMAGE_NAME
export NICO_STORAGE_CLASS REGISTRY_PULL_SECRET REGISTRY_PULL_USERNAME
export METALLB_NAMESPACE METALLB_DEPLOYMENT KEYCLOAK_ENABLED NICO_EDGE_NODE LB_MODE
export SITE_AGENT_REPLICAS="${SITE_AGENT_REPLICAS:-1}"
export PREREQS SRC_ROOT="${SRC}" PREREQS_OVERLAY VAULT_OVERLAY
export HELMFILE="${ROOT}/values/helmfile.yaml.gotmpl"
export REST_VALUES="${VALUES_DIR}/nico-rest.yaml" REST_DEMO_VALUES="${REST_OVERLAY}"

bash "$(dirname "${BASH_SOURCE[0]}")/nico-setup.sh" "${SETUP_ARGS[@]}"

phase "Phase 4b: roll Kea if its config moved"

kea_cm_sum() {
    kubectl get configmap nico-dhcp-config -n "${NICO_SYSTEM_NS}" \
        -o 'jsonpath={.data.kea_config\.json}' 2>/dev/null | shasum -a 256 | cut -c1-16
}
KEA_SUM="$(kea_cm_sum)"
if [[ -z "${KEA_SUM}" ]]; then
    info "no nico-dhcp-config ConfigMap yet, nothing to roll"
else
    KEA_ANN='{.spec.template.metadata.annotations.nico-demo/kea-config-sum}'
    KEA_SEEN="$(kubectl get deploy nico-dhcp -n "${NICO_SYSTEM_NS}" \
        -o "jsonpath=${KEA_ANN}" 2>/dev/null || true)"
    KEA_PATCH="$(printf '{"spec":{"template":{"metadata":{"annotations":{"%s":"%s"}}}}}' \
        "nico-demo/kea-config-sum" "${KEA_SUM}")"
    if [[ "${KEA_SEEN}" == "${KEA_SUM}" ]]; then
        ok "kea already running config ${KEA_SUM}"
    elif kubectl patch deploy nico-dhcp -n "${NICO_SYSTEM_NS}" --type=merge \
            -p "${KEA_PATCH}" >/dev/null 2>&1; then
        kubectl rollout status deploy/nico-dhcp -n "${NICO_SYSTEM_NS}" \
            --timeout=180s >/dev/null 2>&1 \
            && ok "kea rolled onto config ${KEA_SUM}" \
            || warn "kea rollout did not settle; check deploy/nico-dhcp"
    else
        warn "could not annotate deploy/nico-dhcp; kea may still run an older config"
    fi
fi

phase "Phase 5: verify"

_ready="$(ready_count "${NICO_SYSTEM_NS}")"
_rest="$(ready_count "${NICO_REST_NS}")"
ok "${NICO_SYSTEM_NS} ${_ready:-0/0} running, ${NICO_REST_NS} ${_rest:-0/0} running"
info "site ${SITE_NAME} (${SITE_DOMAIN}), API ${VIP_API}, resolver ${VIP_UNBOUND}"
info "HostInband ${HOSTINBAND_PREFIX} from .${HOSTINBAND_RESERVE_FIRST}"
