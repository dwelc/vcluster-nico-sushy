#!/usr/bin/env bash
set -euo pipefail
unset PHASE_PREFIX PHASE_ELAPSED

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
. "${ROOT}/scripts/lib.sh"

JQ_LIST='if type == "array" then . else (.items // .data // .sites // .results // []) end'

exec 1>&2

# --- configuration -----------------------------------------------------------
NICO_SYSTEM_NS="${NICO_SYSTEM_NS:-nico-system}"
NICO_REST_NS="${NICO_REST_NS:-nico-rest}"
VIRTBMC_NAMESPACE="${VIRTBMC_NAMESPACE:-default}"
VAULT_NS="${VAULT_NS:-vault}"
PG_NS="${PG_NS:-postgres}"
NICO_DB="${NICO_DB:-nico_system_nico}"

SITE_NAME="${SITE_NAME:-${NICO_SITE_NAME}}"
SITE_DOMAIN="${SITE_DOMAIN:-${NICO_SITE_DOMAIN}}"
API_HOSTNAME="${API_HOSTNAME:-api-${SITE_NAME}.${SITE_DOMAIN}}"
VM_NAMES="${VM_NAMES:-nico-machine-1 nico-machine-2 nico-machine-3}"

NICO_IMAGE_REGISTRY="${NICO_IMAGE_REGISTRY:-ghcr.io/janekbaraniewski}"
NICO_CORE_IMAGE_NAME="${NICO_CORE_IMAGE_NAME:-nvmetal-carbide}"
NICO_VERSION="${NICO_VERSION:-v2.1.0-rc.8}"
ADMIN_CLI_IMAGE="${ADMIN_CLI_IMAGE:-${NICO_IMAGE_REGISTRY}/${NICO_CORE_IMAGE_NAME}:${NICO_VERSION}}"
ADMIN_CLI_PATH="${ADMIN_CLI_PATH:-/opt/carbide/nico-admin-cli}"
IMAGE_PULL_SECRET="${IMAGE_PULL_SECRET:-imagepullsecret}"

KEYCLOAK_CLIENT_ID="${KEYCLOAK_CLIENT_ID:-ncx-service}"
KEYCLOAK_CLIENT_SECRET="${KEYCLOAK_CLIENT_SECRET:-}"
REST_ORG="${REST_ORG:-}"
REST_TOKEN="${REST_TOKEN:-}"
REST_PORT="${REST_PORT:-${NICO_REST_PORT}}"
REST_AUTHORITY="${REST_AUTHORITY:-$(nico_rest_authority)}"

MACHINE_WAIT="${MACHINE_WAIT_TIMEOUT:-1800}"
MACHINE_POLL="${MACHINE_POLL:-15}"
# Re-arm only after a real stall; site-explorer runs its own sweep every 30s.
MACHINE_STALL_POLLS="${MACHINE_STALL_POLLS:-8}"
MACHINE_ARM_ROUNDS="${MACHINE_ARM_ROUNDS:-3}"
# A Machine row appears long before the machine is Ready and usable by a tenant.
MACHINE_READY_WAIT="${MACHINE_READY_WAIT:-1800}"

RECREATE_MACHINES="${RECREATE_MACHINES:-false}"

# The site password must differ from the BMC's own, or rotation is a no-op.
BMC_SITE_PASSWORD="${BMC_SITE_PASSWORD:-NicoSiteRoot1}"
# nico-prereqs seeds these empty, which fails check_preconditions.
UEFI_PASSWORD="${UEFI_PASSWORD:-bluefield}"
# A vendor NICo does not recognise resolves to "unknown".
BMC_VENDOR="${BMC_VENDOR:-unknown}"

DRY_RUN=false
ONLY=""
THROUGH=""
SITE_UUID_FILE=""
SITE_IP_BLOCK_ID_FILE=""

STAGES="site creds machines segment rest platform"

usage() {
    cat >&2 <<'USAGE'
nico-day0.sh - seed a NICo zero-DPU / FLAT-VPC demo site.

Stages, in order:
  site      register the site through the REST API, print its uuid on stdout
  creds     BMC and UEFI credentials in Vault
  machines  ExpectedMachine registration, then wait for site-explorer
  segment   HostInband segment, created if config seeding did not run
  rest      instance type and site IP block
  platform  vCluster Platform Tenant annotations (off by default)

  --only <stage>          run exactly this stage
  --through <stage>       run the first stage up to and including this one
  --site-uuid-file <path> also write the site uuid here, on success only
  --site-ip-block-id-file <path>
                         write the site IP block id here, on success only
  --recreate-machines     delete each Machine first, so it is ingested again
  --dry-run               report what would change, change nothing
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -only|--only)                   ONLY="$2"; shift 2 ;;
        -through|--through)             THROUGH="$2"; shift 2 ;;
        -site-uuid-file|--site-uuid-file) SITE_UUID_FILE="$2"; shift 2 ;;
        -site-ip-block-id-file|--site-ip-block-id-file) SITE_IP_BLOCK_ID_FILE="$2"; shift 2 ;;
        -recreate-machines|--recreate-machines) RECREATE_MACHINES=true; shift ;;
        -dry-run|--dry-run)             DRY_RUN=true; shift ;;
        -h|--help)         usage; exit 0 ;;
        *)                 usage; die "unknown argument: $1" ;;
    esac
done

for _bool in DRY_RUN RECREATE_MACHINES; do
    case "${!_bool}" in
        true|false) ;;
        *) die "${_bool} must be true or false, not '${!_bool}'" ;;
    esac
done
unset _bool

# --- stage planning ----------------------------------------------------------
stage_index() {
    local want="$1" i=0 s
    for s in ${STAGES}; do
        [[ "${s}" == "${want}" ]] && { printf '%s' "${i}"; return 0; }
        i=$((i + 1))
    done
    return 1
}

# --only runs exactly one stage; --through runs the first stage up to it.
plan_stages() {
    local only through first last i=0 s out=""
    only="$(printf '%s' "${ONLY}" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"
    through="$(printf '%s' "${THROUGH}" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"
    [[ -n "${only}" && -n "${through}" ]] \
        && die "--only '${only}' and --through '${through}' cannot be combined"

    first=0
    last=$(($(printf '%s' "${STAGES}" | wc -w) - 1))
    if [[ -n "${only}" ]]; then
        first="$(stage_index "${only}")" || die "unknown stage '${only}', want one of ${STAGES}"
        last="${first}"
    elif [[ -n "${through}" ]]; then
        last="$(stage_index "${through}")" || die "unknown stage '${through}', want one of ${STAGES}"
    fi
    for s in ${STAGES}; do
        if [[ "${i}" -ge "${first}" && "${i}" -le "${last}" ]]; then out="${out}${s} "; fi
        i=$((i + 1))
    done
    printf '%s' "${out% }"
}

runs() {
    local want="$1" s
    for s in ${PLAN}; do [[ "${s}" == "${want}" ]] && return 0; done
    return 1
}

machine_serial()  { printf '%s%d' "${NICO_SERIAL_PREFIX}" "$1"; }
machine_bmc_mac() { printf '%s:%02X' "${NICO_BMC_MAC_PREFIX}" "$1"; }
# data NICs are ${NICO_DATA_MAC_PREFIX}:00:00, :01 ... (zero-based)
machine_data_mac(){ printf '%s:%02X' "${NICO_DATA_MAC_PREFIX}" "$(( $1 - 1 ))"; }

machine_index() {
    local want="$1" i=1 n
    for n in ${VM_NAMES}; do
        [[ "${n}" == "${want}" ]] && { printf '%s' "${i}"; return 0; }
        i=$((i + 1))
    done
    return 1
}

# --- vault -------------------------------------------------------------------
vault_exec() {
    kq exec -i -n "${VAULT_NS}" vault-0 -c vault -- sh -c \
        "export VAULT_TOKEN='${VAULT_TOKEN}' VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true; $1"
}

vault_token() {
    local t
    for ref in "${NICO_SYSTEM_NS} nico-vault-token token" "${VAULT_NS} vaultroottoken token"; do
        # shellcheck disable=SC2086
        set -- ${ref}
        t="$(kq get secret -n "$1" "$2" -o "jsonpath={.data.$3}" 2>/dev/null | base64 -d 2>/dev/null || true)"
        [[ -n "${t}" ]] && { printf '%s' "${t}"; return 0; }
    done
    die "no vault root token in any configured secret"
}

vault_get_cred() {
    vault_exec "vault kv get -format=json secrets/$1" 2>/dev/null \
        | jq -r '.data.data.UsernamePassword | "\(.username)\t\(.password)"' 2>/dev/null || true
}

vault_put_cred() {
    printf '{"UsernamePassword":{"username":"%s","password":"%s"}}\n' "$2" "$3" \
        | vault_exec "vault kv put secrets/$1 -" >/dev/null \
        || die "writing vault secrets/$1"
}

# --- database ----------------------------------------------------------------
pg_primary() {
    kq get pods -n "${PG_NS}" -l application=spilo,spilo-role=master \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# SQL travels on stdin so quoting inside it cannot break the command apart.
db_query() {
    local pod; pod="$(pg_primary)"
    [[ -n "${pod}" ]] || die "no spilo-role=master pod in namespace ${PG_NS}"
    kq exec -i -n "${PG_NS}" "${pod}" -c postgres -- \
        sh -c "exec su postgres -c 'psql -d ${NICO_DB} -v ON_ERROR_STOP=1 -tA -f -'"
}

db_count() { printf '%s' "$1" | db_query | tr -d ' \r\n' | digits; }

# --- nico-admin-cli ----------------------------------------------------------
CERT_SECRET="nico-day0-admincli-cert"
_ADMINCLI_READY=false

admincli_prepare() {
    ${_ADMINCLI_READY} && return 0
    local addr cert
    # Lab: the external VIP has externalTrafficPolicy=Local and is not
    # reachable from pods on other nodes; use nico-api's ClusterIP on its
    # native gRPC/TLS port (the cert carries the api-<site> name too).
    addr="$(kq get svc -n "${NICO_SYSTEM_NS}" nico-api -o jsonpath='{.spec.clusterIP}')"
    [[ -n "${addr}" ]] || die "nico-api has no ClusterIP"
    API_ADDRESS="${addr}"
    API_PORT_INCLUSTER="${API_PORT_INCLUSTER:-1079}"

    cert="$(vault_exec "vault write -format=json nicoca/issue/nico-cluster \
        common_name='${API_HOSTNAME}' ttl=2h")" || die "issuing an admin-cli client certificate"
    printf '%s' "${cert}" | jq -e '.data.certificate and .data.private_key and .data.issuing_ca' \
        >/dev/null || die "nicoca/issue/nico-cluster returned an incomplete certificate"

    kq create secret generic "${CERT_SECRET}" -n "${NICO_SYSTEM_NS}" \
        --from-literal=client.crt="$(printf '%s' "${cert}" | jq -r .data.certificate)" \
        --from-literal=client.key="$(printf '%s' "${cert}" | jq -r .data.private_key)" \
        --from-literal=ca.crt="$(printf '%s' "${cert}" | jq -r .data.issuing_ca)" \
        --dry-run=client -o yaml | kq apply -f - >/dev/null \
        || die "storing the admin-cli client certificate"
    _ADMINCLI_READY=true
}

# Job names must stay unique against a previous invocation still being cleaned up.
_JOB_SEQ=0
admincli() {
    local name="$1"; shift
    if ${DRY_RUN}; then info "dry run: nico-admin-cli $*"; return 0; fi
    admincli_prepare
    _JOB_SEQ=$((_JOB_SEQ + 1))
    JOB_NAME="$(printf 'nico-day0-%s-%d' "${name}" "${_JOB_SEQ}" \
        | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | cut -c1-50 | sed 's/-*$//')"
    JOB_DEADLINE=300
    JOB_ARGS="$(printf '%s\n' "$@" | jq -R . | jq -sc .)"
    JOB_PULL_SECRET=""
    if kq get secret -n "${NICO_SYSTEM_NS}" "${IMAGE_PULL_SECRET}" >/dev/null 2>&1; then
        JOB_PULL_SECRET="imagePullSecrets: [{name: ${IMAGE_PULL_SECRET}}]"
    fi
    export JOB_NAME JOB_DEADLINE JOB_ARGS JOB_PULL_SECRET API_ADDRESS API_PORT_INCLUSTER

    kq delete job "${JOB_NAME}" -n "${NICO_SYSTEM_NS}" --ignore-not-found >/dev/null 2>&1 || true
    render nico-admincli-job.yaml.tmpl | kq apply -f - >/dev/null || return 1
    if ! kq wait --for=condition=complete --timeout=300s \
        "job/${JOB_NAME}" -n "${NICO_SYSTEM_NS}" >/dev/null 2>&1; then
        warn "$(oneline "$(kq logs -n "${NICO_SYSTEM_NS}" "job/${JOB_NAME}" --tail=20 2>/dev/null)")"
        return 1
    fi
    return 0
}

_PF_DIR="$(mktemp -d)"
_REST_BASE=""
_REST_TOKEN=""
REST_ORG_RESOLVED=""

rest_disconnect() {
    local f p
    for f in "${_PF_DIR}"/*.pid; do
        [[ -f "${f}" ]] || continue
        p="$(cat "${f}")"
        [[ -n "${p}" ]] && kill "${p}" >/dev/null 2>&1
        rm -f "${f}"
    done
    rmdir "${_PF_DIR}" >/dev/null 2>&1 || true
}
trap rest_disconnect EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# Returns the local port; the forward is torn down by the EXIT trap.
port_forward() {
    local ns="$1" svc="$2" port="$3" local_port i
    local_port="$(jot -r 1 20000 39999 2>/dev/null || printf '%s' $((20000 + RANDOM % 20000)))"
    kubectl port-forward -n "${ns}" "svc/${svc}" "${local_port}:${port}" >/dev/null 2>&1 3>&- &
    printf '%s' "$!" > "${_PF_DIR}/${local_port}.pid"
    for i in $(seq 1 40); do
        if (exec 4<>"/dev/tcp/127.0.0.1/${local_port}") 2>/dev/null; then
            printf '%s' "${local_port}"; return 0
        fi
        sleep 0.25
    done
    die "port-forward to ${svc}.${ns}:${port} never became ready"
}

mint_token() {
    local port body
    if [[ -n "${REST_TOKEN}" ]]; then printf '%s' "${REST_TOKEN}"; return 0; fi
    [[ -n "${KEYCLOAK_CLIENT_SECRET}" ]] || die "KEYCLOAK_CLIENT_SECRET is required to mint a REST token"
    port="$(port_forward "${NICO_REST_NS}" keycloak "${KEYCLOAK_PORT}")"
    body="$(curl -sS --fail-with-body -H "Host: ${KEYCLOAK_AUTHORITY}" \
        -d grant_type=client_credentials -d "client_id=${KEYCLOAK_CLIENT_ID}" \
        -d "client_secret=${KEYCLOAK_CLIENT_SECRET}" \
        "http://127.0.0.1:${port}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token")" \
        || die "Keycloak refused the client-credentials grant for ${KEYCLOAK_CLIENT_ID}"
    printf '%s' "${body}" | jq -re .access_token || die "no access_token from Keycloak"
}

org_from_token() {
    local payload orgs
    payload="$(printf '%s' "$1" | cut -d. -f2 | tr '_-' '/+')"
    while [[ $(( ${#payload} % 4 )) -ne 0 ]]; do payload="${payload}="; done
    orgs="$(printf '%s' "${payload}" | base64 -d 2>/dev/null \
        | jq -r '[.realm_access.roles[]? | select(test(":")) | split(":")[0]] | unique | .[]' 2>/dev/null)"
    case "$(printf '%s' "${orgs}" | grep -c .)" in
        1) printf '%s' "${orgs}" ;;
        0) die "no org-scoped realm role in the token; set REST_ORG" ;;
        *) die "the token's realm roles name several organizations: $(oneline "${orgs}")" ;;
    esac
}

rest_connect() {
    [[ -n "${_REST_BASE}" ]] && return 0
    local port
    _REST_TOKEN="$(mint_token)"
    REST_ORG_RESOLVED="${REST_ORG}"
    [[ -n "${REST_ORG_RESOLVED}" ]] || REST_ORG_RESOLVED="$(org_from_token "${_REST_TOKEN}")"
    port="$(port_forward "${NICO_REST_NS}" nico-rest-api "${REST_PORT}")"
    _REST_BASE="http://127.0.0.1:${port}/v2/org/${REST_ORG_RESOLVED}/nico"
    ok "org ${REST_ORG_RESOLVED} at http://${REST_AUTHORITY}/v2/org/${REST_ORG_RESOLVED}/nico"
}

rest() {
    local method="$1" path="$2" body="${3:-}" f status rc i
    f="/tmp/nico-day0-rest.$$"
    for i in 1 2 3 4 5; do
        rc=0
        status="$(curl -sS -o "${f}" -w '%{http_code}' -X "${method}" \
            -H "Host: ${REST_AUTHORITY}" -H "Authorization: Bearer ${_REST_TOKEN}" \
            -H 'Accept: application/json' -H 'Content-Type: application/json' \
            ${body:+--data "${body}"} "${_REST_BASE}${path}" 2>/dev/null)" || rc=$?
        ((rc == 0)) && break
        sleep 1
    done
    if ((rc != 0)); then
        rm -f "${f}"
        warn "${method} ${path}: no response after 5 attempts (curl ${rc})"
        return 1
    fi
    if [[ "${status}" == "401" && "${_REST_RETRIED_AUTH:-0}" == "0" ]]; then
        rm -f "${f}"
        info "REST token expired, re-authenticating"
        _REST_TOKEN="$(REST_TOKEN="" mint_token)" || { warn "re-auth failed"; return 1; }
        _REST_RETRIED_AUTH=1
        rest "${method}" "${path}" "${body}"
        local rc2=$?
        _REST_RETRIED_AUTH=0
        return "${rc2}"
    fi
    cat "${f}"; rm -f "${f}"
    if [[ "${status}" -lt 200 || "${status}" -ge 300 ]]; then
        warn "${method} ${path}: HTTP ${status}"
        return 1
    fi
}

stage_site() {
    if [[ -n "${NICO_SITE_UUID:-}" ]]; then
        SITE_ID="${NICO_SITE_UUID}"
        phase "site: ${SITE_NAME}"
        ok "already registered, ${SITE_ID:0:8}"
        return 0
    fi
    phase "site: register ${SITE_NAME} through the REST API"
    if ${DRY_RUN}; then info "dry run: would POST /site name=${SITE_NAME}"; return 0; fi
    rest_connect
    # Creates the InfrastructureProvider the site create requires.
    rest GET /service-account/current >/dev/null || die "GET /service-account/current"

    local id
    id="$(rest GET /site | jq -r --arg n "${SITE_NAME}" "${JQ_LIST} | map(select(.name==\$n)) | .[0].id // empty")"
    if [[ -n "${id}" ]]; then
        ok "adopted site ${SITE_NAME} (${id:0:8})"
    else
        local body
        body="$(rest POST /site "$(jq -nc --arg n "${SITE_NAME}" '{name:$n}')")" || {
            # Names are unique per Infrastructure Provider; a lost race adopts.
            id="$(rest GET /site | jq -r --arg n "${SITE_NAME}" "${JQ_LIST} | map(select(.name==\$n)) | .[0].id // empty")"
            [[ -n "${id}" ]] || die "could not create site ${SITE_NAME}: $(oneline "${body}")"
        }
        [[ -n "${id}" ]] || id="$(printf '%s' "${body}" | jq -r .id)"
        [[ -n "${id}" && "${id}" != null ]] || die "site ${SITE_NAME} was created but carried no id"
        ok "created site ${SITE_NAME} (${id:0:8})"
    fi
    SITE_ID="${id}"
    if [[ -n "${SITE_UUID_FILE}" ]]; then
        printf '%s\n' "${id}" > "${SITE_UUID_FILE}"
    fi
}

resolve_bmc_credential() {
    [[ -n "${BMC_USER:-}" ]] && return 0
    BMC_USER="${BMC_USERNAME}"; BMC_PASS="${BMC_PASSWORD}"
    ok "bmc credential \"${BMC_USER}\" from config/site.env (sushy-tools htpasswd)"
}

# machines/bmc/site/root is required, or check_preconditions aborts with MissingCredentials.
stage_creds() {
    phase "creds: BMC and UEFI credentials in Vault"
    resolve_bmc_credential
    local host_factory="machines/all_hosts/factory_default/bmc-metadata-items/${BMC_VENDOR}"
    local site_root="machines/bmc/site/root"
    local host_uefi="machines/all_hosts/site_default/uefi-metadata-items/auth"
    local dpu_uefi="machines/all_dpus/site_default/uefi-metadata-items/auth"
    if ${DRY_RUN}; then info "dry run: would seed ${host_factory}, ${site_root}, ${host_uefi}, ${dpu_uefi}"; return 0; fi
    local _seeded=0 _present=0

    vault_put_cred "${host_factory}" "${BMC_USER}" "${BMC_PASS}"
    _seeded=$((_seeded + 1))
    # AMI-class hosts carry no BMCVendor in NiCo; seed the likely segments too.
    local v
    for v in ami unknown; do
        [[ "${v}" == "${BMC_VENDOR}" ]] && continue
        vault_put_cred "machines/all_hosts/factory_default/bmc-metadata-items/${v}" "${BMC_USER}" "${BMC_PASS}"
        _seeded=$((_seeded + 1))
    done
    # Seeded for parity on a site with no DPUs so check_preconditions finds the path.
    vault_put_cred "machines/all_dpus/factory_default/bmc-metadata-items/root" root 0penBmc
    _seeded=$((_seeded + 1))

    local cur user pass
    cur="$(vault_get_cred "${site_root}")"
    user="$(printf '%s' "${cur}" | cut -f1)"; pass="$(printf '%s' "${cur}" | cut -f2)"
    if [[ -z "${pass}" || "${pass}" == "${BMC_PASS}" || "${user}" != "${BMC_USER}" ]]; then
        vault_put_cred "${site_root}" "${BMC_USER}" "${BMC_SITE_PASSWORD}"
        _seeded=$((_seeded + 1))
    else
        _present=$((_present + 1))
    fi

    local p
    for p in "${host_uefi}" "${dpu_uefi}"; do
        cur="$(vault_get_cred "${p}")"
        if [[ -n "$(printf '%s' "${cur}" | cut -f2)" ]]; then
            _present=$((_present + 1)); continue
        fi
        vault_put_cred "${p}" admin "${UEFI_PASSWORD}"
        _seeded=$((_seeded + 1))
    done
    ok "${_seeded} credentials seeded, ${_present} already in place"
}

# --- stage: machines ---------------------------------------------------------
# Static: sushy-nico instance per VM on a LAN alias (sushy-tools/deploy.sh).
bmc_ip() {
    local i; i="$(machine_index "$1")"
    set -- ${NICO_BMC_IPS}
    printf '%s' "${!i}"
}

correct_endpoint_credentials() {
    local n i mac cur path
    for n in ${VM_NAMES}; do
        i="$(machine_index "${n}")"
        mac="$(machine_bmc_mac "${i}")"
        path="machines/bmc/${mac}/root"
        if ${DRY_RUN}; then info "dry run: would seed ${path}"; continue; fi
        cur="$(vault_get_cred "${path}")"
        [[ "${cur}" == "$(printf '%s\t%s' "${BMC_USER}" "${BMC_PASS}")" ]] && continue
        vault_put_cred "${path}" "${BMC_USER}" "${BMC_PASS}"
        ok "${n}: endpoint credential corrected at ${path}"
    done
}

# refresh alone does not clear the AvoidLockout latch, so clear-error precedes it.
arm_explorer() {
    local round="$1" n i ip
    for n in ${VM_NAMES}; do
        i="$(machine_index "${n}")"; ip="$(bmc_ip "${n}")"
        admincli "se-clear-${round}-${i}" site-explorer clear-error "${ip}" \
            || { warn "${n}: clear-error not accepted"; continue; }
        admincli "se-refresh-${round}-${i}" site-explorer refresh "${ip}" \
            || warn "${n}: refresh not accepted"
    done
}

register_machines() {
    local existing n i mac ip serial data
    existing="$(printf 'SELECT bmc_mac_address::text FROM expected_machines;' | db_query | tr 'A-Z' 'a-z')"
    for n in ${VM_NAMES}; do
        i="$(machine_index "${n}")"
        mac="$(machine_bmc_mac "${i}")"; ip="$(bmc_ip "${n}")"
        serial="$(machine_serial "${i}")"; data="$(machine_data_mac "${i}")"
        if printf '%s\n' "${existing}" | grep -qix "$(printf '%s' "${mac}" | tr 'A-Z' 'a-z')"; then
            admincli "em-patch-${i}" expected-machine patch \
                --bmc-mac-address "$(printf '%s' "${mac}" | tr 'A-Z' 'a-z')" \
                --bmc-username "${BMC_USER}" --bmc-password "${BMC_PASS}" \
                --dpu-policy ignore && ok "${n}: patched" || warn "${n}: patch failed"
            continue
        fi
        # The BMC must stay out of --interfaces; --bmc-ip-address identifies it.
        admincli "em-add-${i}" expected-machine add \
            --bmc-mac-address "$(printf '%s' "${mac}" | tr 'A-Z' 'a-z')" \
            --bmc-username "${BMC_USER}" --bmc-password "${BMC_PASS}" \
            --chassis-serial-number "${serial}" --bmc-ip-address "${ip}" \
            --meta-name "${n}" \
            --interfaces "$(jq -nc --arg m "$(printf '%s' "${data}" | tr 'A-Z' 'a-z')" \
                '[{mac_address:$m,role:"host",ip_allocation:"dynamic",network_segment_type:3,primary:true}]')" \
            --dpu-policy ignore \
            --dpf-enabled false --disable-lockdown true --bmc-retain-credentials true \
            && ok "${n}: registered (bmc ${mac} at ${ip}, data nic ${data})" \
            || warn "${n}: registration failed"
    done
}

wait_for_machines() {
    local want deadline last="" stalls=0 round=0 explored machines
    want="$(printf '%s' "${VM_NAMES}" | wc -w | tr -d ' ')"
    info "waiting for site-explorer to discover ${want} machines, up to $((MACHINE_WAIT / 60))m"
    deadline=$(( $(date +%s) + MACHINE_WAIT ))
    while :; do
        explored="$(db_count 'SELECT count(*) FROM explored_endpoints;')"
        machines="$(db_count 'SELECT count(*) FROM machines;')"
        [[ "${machines:-0}" -ge "${want}" ]] && { ok "${want} Machines exist"; return 0; }
        if [[ "${explored}/${machines}" != "${last}" ]]; then
            info "reached ${explored} of ${want} BMCs, ingested ${machines} of ${want} machines"
            last="${explored}/${machines}"; stalls=0
        else
            stalls=$((stalls + 1))
        fi
        if [[ "${stalls}" -ge "${MACHINE_STALL_POLLS}" && "${round}" -lt "${MACHINE_ARM_ROUNDS}" ]]; then
            round=$((round + 1)); stalls=0
            warn "no progress in ${MACHINE_STALL_POLLS} polls, re-arming site-explorer, round ${round} of ${MACHINE_ARM_ROUNDS}"
            arm_explorer "${round}"
        fi
        [[ "$(date +%s)" -ge "${deadline}" ]] && break
        sleep "${MACHINE_POLL}"
    done
    machines="$(db_count 'SELECT count(*) FROM machines;')"
    explored="$(db_count 'SELECT count(*) FROM explored_endpoints;')"
    # Every later stage allocates machines; proceeding would report a hollow success.
    [[ "${machines:-0}" -eq 0 ]] && die "no Machines after ${MACHINE_WAIT}s: ${explored} endpoints explored, none ingested, ${want} expected"
    warn "only ${machines} of ${want} Machines after ${MACHINE_WAIT}s"
    return 0
}

recreate_machines() {
    local rows n id it
    warn "recreating Machines: every Machine record below is deleted, not adopted"
    if ${DRY_RUN}; then info "dry run: would delete the Machine of ${VM_NAMES}"; return 0; fi
    # One query, filtered by name in the shell, so no VM name reaches SQL.
    rows="$(printf "SELECT name, id, coalesce(instance_type_id, '') FROM machines;" | db_query)"
    for n in ${VM_NAMES}; do
        id="$(printf '%s\n' "${rows}" | awk -F'|' -v n="${n}" '$1 == n {print $2; exit}')"
        [[ -n "${id}" ]] || { info "${n}: no Machine record, nothing to delete"; continue; }
        # force-delete refuses outright while an instance type is associated.
        it="$(printf '%s\n' "${rows}" | awk -F'|' -v n="${n}" '$1 == n {print $3; exit}')"
        if [[ -n "${it}" ]]; then
            admincli "it-free-${n}" instance-type disassociate "${id}" \
                || { warn "${n}: instance type ${it} still associated, not deleting"; continue; }
        fi
        admincli "m-del-${n}" machine force-delete --machine "${id}" \
            --allow-delete-with-instance \
            && ok "${n}: Machine deleted, site-explorer will ingest it again" \
            || warn "${n}: force-delete failed, ${id} left in place"
    done
}

stage_machines() {
    local want; want="$(printf '%s' "${VM_NAMES}" | wc -w | tr -d ' ')"
    phase "machines: ${want} ExpectedMachine entries"
    resolve_bmc_credential
    if ${RECREATE_MACHINES}; then recreate_machines; fi
    register_machines
    correct_endpoint_credentials
    wait_for_machines
}

# --- stage: segment ----------------------------------------------------------
HOSTINBAND_NAME="${HOSTINBAND_NAME:-demo-inband}"
HOSTINBAND_PREFIX="${HOSTINBAND_PREFIX:-${BRIDGE_CIDR}}"
HOSTINBAND_GATEWAY="${HOSTINBAND_GATEWAY:-${GATEWAY}}"
HOSTINBAND_RESERVE_FIRST="${HOSTINBAND_RESERVE_FIRST:-150}"
UNSAFE_OP_USER="${UNSAFE_OP_USER:-nico-day0}"

find_segment() {
    printf "SELECT id::text FROM network_segments WHERE name = '%s' AND deleted IS NULL;" \
        "${HOSTINBAND_NAME}" | db_query | tr -d ' \r\n'
}

# Config-driven creation is bootstrap-once, so an established site needs the runtime API.
stage_segment() {
    phase "segment: HostInband ${HOSTINBAND_NAME}"
    [[ -n "${SEG_ID:-}" ]] && { ok "segment id supplied: ${SEG_ID}"; return 0; }
    SEG_ID="$(find_segment)"
    [[ -n "${SEG_ID}" ]] && { ok "adopted segment ${HOSTINBAND_NAME} (${SEG_ID})"; return 0; }
    if ${DRY_RUN}; then info "dry run: would create segment ${HOSTINBAND_NAME}"; return 0; fi

    # A host-inband segment needs a subdomain id.
    local subdomain="${SUBDOMAIN_ID:-}"
    [[ -n "${subdomain}" ]] || subdomain="$(printf \
        'SELECT id::text FROM domains WHERE deleted IS NULL ORDER BY created LIMIT 1;' \
        | db_query | tr -d ' \r\n')"
    [[ -n "${subdomain}" ]] || die "no live DNS domain to use as the segment subdomain id"

    # --cloud-unsafe-op is global and must precede the subcommand.
    admincli seg-create "--cloud-unsafe-op=${UNSAFE_OP_USER}" network-segment create \
        --name "${HOSTINBAND_NAME}" --segment-type host-inband \
        --prefix "${HOSTINBAND_PREFIX}" --gateway "${HOSTINBAND_GATEWAY}" \
        --reserve-first "${HOSTINBAND_RESERVE_FIRST}" --subdomain-id "${subdomain}" \
        || die "creating segment ${HOSTINBAND_NAME}"
    SEG_ID="$(find_segment)"
    [[ -n "${SEG_ID}" ]] || die "segment ${HOSTINBAND_NAME} was created but cannot be found"
    ok "created segment ${HOSTINBAND_NAME} (${SEG_ID})"
}

# --- stage: rest -------------------------------------------------------------
INSTANCE_TYPE_NAME="${INSTANCE_TYPE_NAME:-flat-demo-type}"
IPBLOCK_NAME="${IPBLOCK_NAME:-flat-demo-ipblock}"
# Stays off the host bridge's /24.
IPBLOCK_PREFIX="${IPBLOCK_PREFIX:-10.210.0.0}"
IPBLOCK_PREFIX_LENGTH="${IPBLOCK_PREFIX_LENGTH:-24}"

# The order below is the only workable one.
stage_rest() {
    phase "rest: instance type and site IP block"
    if ${DRY_RUN}; then
        info "dry run: would create the instance type and ip block"
        return 0
    fi
    rest_connect

    TENANT_ID="$(rest GET /service-account/current | jq -r '.tenantId // empty')"
    [[ -n "${TENANT_ID}" ]] || TENANT_ID="$(rest GET /tenant/current | jq -r .id)"
    [[ -n "${TENANT_ID}" && "${TENANT_ID}" != null ]] || die "no tenant id from the REST API"
    ok "tenant ${TENANT_ID}"

    # The installer's site-agent phase creates the site and a second one cannot be adopted.
    [[ -n "${SITE_ID:-}" ]] || SITE_ID="$(rest GET /site \
        | jq -r --arg n "${SITE_NAME}" "${JQ_LIST} | (map(select(.name==\$n)) | .[0].id) // (if length==1 then .[0].id else empty end)")"
    [[ -n "${SITE_ID}" ]] || die "no site named ${SITE_NAME}"
    ok "site ${SITE_NAME} (${SITE_ID})"

    # Without this capability no machine can be given an operating system.
    if [[ "$(rest GET "/site/${SITE_ID}" | jq -r '.capabilities.imageBasedOperatingSystem // false')" != true ]]; then
        rest PATCH "/site/${SITE_ID}" '{"capabilities":{"imageBasedOperatingSystem":true}}' >/dev/null \
            || die "enabling imageBasedOperatingSystem on site ${SITE_ID}"
        ok "imageBasedOperatingSystem enabled"
    else
        ok "imageBasedOperatingSystem already enabled"
    fi

    # The prose docs say /instance-type; the registered route does not.
    INSTANCE_TYPE_ID="$(rest GET "/instance/type?siteId=${SITE_ID}" \
        | jq -r --arg n "${INSTANCE_TYPE_NAME}" "${JQ_LIST} | map(select(.name==\$n)) | .[0].id // empty")"
    if [[ -z "${INSTANCE_TYPE_ID}" ]]; then
        # The API rejects a null machineCapabilities; an empty list is "any machine".
        INSTANCE_TYPE_ID="$(rest POST /instance/type "$(jq -nc \
            --arg n "${INSTANCE_TYPE_NAME}" --arg s "${SITE_ID}" \
            '{name:$n,siteId:$s,machineCapabilities:[]}')" | jq -r .id)" \
            || die "creating instance type ${INSTANCE_TYPE_NAME}"
    fi
    ok "instance type ${INSTANCE_TYPE_NAME} (${INSTANCE_TYPE_ID:0:8})"

    # FLAT addressing does not use it, but a Platform NodeProvider needs a siteIPBlockID.
    IPBLOCK_ID="$(rest GET "/ipblock?siteId=${SITE_ID}" \
        | jq -r --arg n "${IPBLOCK_NAME}" "${JQ_LIST} | map(select(.name==\$n)) | .[0].id // empty")"
    if [[ -z "${IPBLOCK_ID}" ]]; then
        IPBLOCK_ID="$(rest POST /ipblock "$(jq -nc --arg n "${IPBLOCK_NAME}" --arg s "${SITE_ID}" \
            --arg p "${IPBLOCK_PREFIX}" --argjson l "${IPBLOCK_PREFIX_LENGTH}" \
            '{name:$n,siteId:$s,routingType:"DatacenterOnly",prefix:$p,prefixLength:$l,protocolVersion:"IPv4"}')" \
            | jq -r .id)" || die "creating ip block ${IPBLOCK_NAME}"
    fi
    ok "ip block ${IPBLOCK_NAME} (${IPBLOCK_ID:0:8})"

    local ids n inuse want deadline last=""
    want="$(printf '%s' "${VM_NAMES}" | wc -w | tr -d ' ')"
    deadline=$(( $(date +%s) + MACHINE_READY_WAIT ))
    while :; do
        ids="$(rest GET "/machine?siteId=${SITE_ID}" \
            | jq -r "[${JQ_LIST} | .[] | select(.status==\"Ready\" and .isUsableByTenant and ((.associatedDpuMachineIds // []) | length == 0)) | .id]")"
        n="$(printf '%s' "${ids}" | jq 'length')"
        inuse="$(rest GET "/machine?siteId=${SITE_ID}" \
            | jq -r "[${JQ_LIST} | .[] | select(.status==\"InUse\")] | length")"
        [[ $(( n + ${inuse:-0} )) -ge "${want}" ]] && break
        [[ "$(date +%s)" -ge "${deadline}" ]] && {
            [[ "${n}" -gt 0 ]] && warn "only ${n} of ${want} machines allocatable after ${MACHINE_READY_WAIT}s"
            break
        }
        if [[ "${n}" != "${last}" ]]; then
            info "machines initialising in NICo, ${n} of ${want} ready"
            last="${n}"
        fi
        sleep "${MACHINE_POLL}"
    done
    if [[ "${n}" -gt 0 ]]; then
        rest POST "/instance/type/${INSTANCE_TYPE_ID}/machine" \
            "$(jq -nc --argjson m "${ids}" '{machineIds:$m}')" >/dev/null \
            || warn "associating machines with the instance type"
        ok "$(printf '%s' "${ids}" | jq 'length') machines attached to ${INSTANCE_TYPE_NAME}"
    else
        warn "no allocatable zero-DPU machine at ${SITE_NAME}"
    fi

    if [[ -n "${SITE_IP_BLOCK_ID_FILE}" ]]; then
        mkdir -p "$(dirname "${SITE_IP_BLOCK_ID_FILE}")"
        local tmp
        tmp="$(mktemp "${SITE_IP_BLOCK_ID_FILE}.XXXXXX")"
        printf '%s\n' "${IPBLOCK_ID}" > "${tmp}"
        mv "${tmp}" "${SITE_IP_BLOCK_ID_FILE}"
        ok "site IP block id written to ${SITE_IP_BLOCK_ID_FILE}"
    fi
}

# --- stage: platform ---------------------------------------------------------
PLATFORM_WIRE_TENANT="${PLATFORM_WIRE_TENANT:-false}"
PLATFORM_TENANT_NAME="${PLATFORM_TENANT_NAME:-}"
# Must differ from the provider's own org, or onboarding is refused.
PLATFORM_NICO_ORG="${PLATFORM_NICO_ORG:-vcluster-autonodes}"

stage_platform() {
    phase "platform: vCluster Platform Tenant annotations"
    [[ "${PLATFORM_WIRE_TENANT}" == true ]] || { ok "skipped (PLATFORM_WIRE_TENANT is not true)"; return 0; }
    [[ -n "${PLATFORM_TENANT_NAME}" ]] || die "PLATFORM_WIRE_TENANT needs PLATFORM_TENANT_NAME"
    if ${DRY_RUN}; then info "dry run: would annotate Tenant ${PLATFORM_TENANT_NAME}"; return 0; fi
    # Merge, not replace: the driver writes annotations back and a replace prunes the vpc-id.
    kq patch tenant.management.loft.sh "${PLATFORM_TENANT_NAME}" --type=merge -p "$(jq -nc \
        --arg o "${PLATFORM_NICO_ORG}" --arg s "${SITE_ID:-}" --arg i "${INSTANCE_TYPE_ID:-}" \
        '{metadata:{annotations:{"nico.loft.sh/org":$o,"nico.loft.sh/site-id":$s,"nico.loft.sh/instance-type-ids":$i}}}')" \
        >/dev/null || die "annotating Tenant ${PLATFORM_TENANT_NAME}"
    ok "Tenant ${PLATFORM_TENANT_NAME} annotated for org ${PLATFORM_NICO_ORG}"
}

# --- main --------------------------------------------------------------------
need kubectl; need jq; need curl; need base64
PLAN="$(plan_stages)"
phase "nico-day0: site ${SITE_NAME}, $(printf '%s' "${VM_NAMES}" | wc -w | tr -d ' ') machines, stages ${PLAN// /,}"
${DRY_RUN} && warn "dry run: nothing will be created or changed"

if runs creds || runs machines || runs segment; then VAULT_TOKEN="$(vault_token)"; fi
for _stage in ${PLAN}; do "stage_${_stage}"; done

phase "summary"
info "site            ${SITE_NAME} ${SITE_ID:--}"
info "hostinband      ${HOSTINBAND_NAME} ${HOSTINBAND_PREFIX} ${SEG_ID:--}"
info "instance type   ${INSTANCE_TYPE_NAME} ${INSTANCE_TYPE_ID:--}"
info "site ip block   ${IPBLOCK_NAME} ${IPBLOCK_ID:--}"
info "NodeProvider spec.nico: endpoint http://${REST_AUTHORITY}, org ${REST_ORG_RESOLVED:--}, siteId ${SITE_ID:--}, siteIPBlockID ${IPBLOCK_ID:--}, instanceTypeIds ${INSTANCE_TYPE_ID:--}"
