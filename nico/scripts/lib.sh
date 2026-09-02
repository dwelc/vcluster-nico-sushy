# shellcheck shell=bash
# Sourced by every script here, never run.
# shellcheck disable=SC2034

ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Exported so a script can hand these to a child without restating them.
set -a
# shellcheck source=config/site.env disable=SC1091
. "${ROOT}/config/site.env"
# Aliases the scripts still use for the HostInband segment.
BRIDGE_CIDR="${HOSTINBAND_CIDR}"; GATEWAY="${HOSTINBAND_GW}"; SUBNET="${HOSTINBAND_NET}"; BRIDGE_PREFIX_LEN="${HOSTINBAND_CIDR#*/}"
set +a

# Returns 0 even without a tty, or set -e kills the assignments below.
_sgr() { if [[ -t 1 ]]; then printf '\033[%sm' "$1"; fi; }
BOLD="$(_sgr 1)" RED="$(_sgr 31)" GREEN="$(_sgr 32)" YELLOW="$(_sgr 33)"
BLUE="$(_sgr 34)" NC="$(_sgr 0)"

# STEP/STEP_TOTAL come from the Makefile, so a user always knows where they are.
phase() {
    local sub="" el=""
    [[ -n "${PHASE_PREFIX:-}" ]] && sub=" (${PHASE_PREFIX})"
    [[ -n "${PHASE_ELAPSED:-}" ]] && el=" ${PHASE_ELAPSED}"
    if [[ -n "${STEP:-}" ]]; then
        printf '\n%s%s==> [%s/%s]%s %s%s%s\n' \
            "${BOLD}" "${BLUE}" "${STEP}" "${STEP_TOTAL:-?}" "${sub}" "$*" "${el}" "${NC}" >&2
    else
        printf '\n%s%s==>%s %s%s%s\n' \
            "${BOLD}" "${BLUE}" "${sub}" "$*" "${el}" "${NC}" >&2
    fi
}
info()  { printf '    %s\n' "$*" >&2; }

converged() {
    local label="$1" want="$2" ns="$3" obj="$4"; shift 4
    local have; have="$("$@" 2>/dev/null | tr -d ' \r\n')"
    [[ -n "${have}" && "${have}" == *"${want}"* ]] || return 1
    kubectl -n "${ns}" rollout status "${obj}" --timeout=20s >/dev/null 2>&1 || return 1
    ok "${label} already converged"
}

apply_day0() {
    local dir="${ROOT}/manifests/day0" f base req var missing allow applied=0 deferred=0
    for f in "${dir}"/*.yaml; do
        [[ -e "${f}" ]] || continue
        base="$(basename "${f}")"
        req="$(grep -oE '\$\{[A-Z_][A-Z0-9_]*\}' "${f}" 2>/dev/null | tr -d '${}' | sort -u || true)"
        missing=""; allow=""
        for var in ${req}; do
            if [[ -z "${!var:-}" ]]; then missing="${missing} ${var}"; else allow="${allow}\${${var}} "; fi
        done
        if [[ -n "${missing}" ]]; then
            info "defer    ${base} (needs${missing})"
            deferred=$((deferred + 1))
            continue
        fi
        envsubst "${allow}" < "${f}" \
            | quiet kubectl apply --server-side --force-conflicts -f - \
            || die "applying ${base}"
        info "apply    ${base}"
        applied=$((applied + 1))
    done
    if ((deferred)); then
        ok "day 0: ${applied} applied, ${deferred} deferred until their inputs exist"
    else
        ok "day 0: ${applied} applied"
    fi
}

ready_count() {
    kubectl get pods -n "$1" --no-headers 2>/dev/null | awk '
        $3 == "Completed" || $3 == "Succeeded" {next}
        {split($2,a,"/"); if (a[1]==a[2] && $3=="Running") r++; t++}
        END {printf "%d/%d", r, t}'
}
ok()    { printf '    %s[ok]%s %s\n' "${GREEN}" "${NC}" "$*" >&2; }
warn()  { printf '    %s[warn]%s %s\n' "${YELLOW}" "${NC}" "$*" >&2; }

# Lets an EXIT trap tell a deliberate exit from an unexpected one.
_DIED=false
die() { _DIED=true; printf '%sERROR:%s %s\n' "${RED}" "${NC}" "$*" >&2; exit 1; }

need()      { command -v "$1" >/dev/null 2>&1 || die "not on PATH: $1${2:+ ($2)}"; }
need_file() { [[ -f "$1" ]] || die "missing $1${2:+ -- $2}"; }

retry() {
    local timeout="$1" interval="$2" label="$3"; shift 3
    local start; start="$(date +%s)"
    local deadline=$((start + timeout)) state next=0 now
    info "waiting  ${label}"
    while :; do
        state="$("$@" 2>/dev/null)" && { ok "${label}"; return 0; }
        now="$(date +%s)"
        ((now < deadline)) || {
            warn "TIMEOUT after $((timeout / 60))m: ${label}${state:+ (${state})}"
            # The polls above discard stderr to keep the wait readable. One last
            # attempt with it shown turns "it timed out" into a reason.
            local err
            err="$("$@" 2>&1 >/dev/null | tail -3)"
            [[ -n "${err}" ]] && warn "last error: $(oneline "${err}")"
            return 1
        }
        if ((now >= next)); then
            printf '             %s  %dm of %dm%s\n' \
                "${label}" "$(((now - start) / 60))" "$((timeout / 60))" \
                "${state:+ - ${state}}"
            next=$((now + 60))
        fi
        sleep "${interval}"
    done
}

# IdentitiesOnly is not optional: without it ssh offers every identity the agent
# holds before the one named by -i, and the host accepts only the generated key.
# Six refusals hit the server's MaxAuthTries and the connection closes, so on any
# machine with a populated ssh-agent every attempt fails and the wait times out
# with nothing to show for it.
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ConnectTimeout=10 -o BatchMode=yes
          -o IdentitiesOnly=yes)

HOST_TRANSPORT="${HOST_TRANSPORT:-ssh}"
HOST_SSH_KEY="${HOST_SSH_KEY:-${SSH_KEY:-}}"
MACHINE_SSH_KEY="${MACHINE_SSH_KEY:-${SSH_KEY:-}}"

tailscale_cli() {
    if [[ -n "${TAILSCALE_BIN:-}" && -x "${TAILSCALE_BIN}" ]]; then
        printf '%s' "${TAILSCALE_BIN}"
    elif command -v tailscale >/dev/null 2>&1; then
        command -v tailscale
    elif [[ -x /Applications/Tailscale.app/Contents/MacOS/tailscale ]]; then
        printf '%s' /Applications/Tailscale.app/Contents/MacOS/tailscale
    else
        return 1
    fi
}

run_with_timeout() {
    local seconds="$1"; shift
    python3 -c 'import os, signal, subprocess, sys
p = subprocess.Popen(sys.argv[2:], start_new_session=True)
def forward(signum, _frame):
    try:
        os.killpg(p.pid, signum)
        p.wait(timeout=2)
    except ProcessLookupError:
        pass
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        p.wait()
    raise SystemExit(128 + signum)
for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(sig, forward)
try:
    rc = p.wait(timeout=float(sys.argv[1]))
except subprocess.TimeoutExpired:
    try:
        os.killpg(p.pid, signal.SIGTERM)
        p.wait(timeout=2)
    except (ProcessLookupError, subprocess.TimeoutExpired):
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        p.wait()
    rc = 124
raise SystemExit(rc)' "${seconds}" "$@"
}

on_host() {
    [[ -n "${SSH_HOST:-}" ]] || die "SSH_HOST is unset (run this through make)"
    case "${HOST_TRANSPORT}" in
        ssh)
            [[ -f "${HOST_SSH_KEY:-}" ]] ||
                die "no host private key at ${HOST_SSH_KEY:-<unset>}"
            if [[ -n "${HOST_COMMAND_TIMEOUT:-}" ]]; then
                run_with_timeout "${HOST_COMMAND_TIMEOUT}" \
                    ssh -i "${HOST_SSH_KEY}" "${SSH_OPTS[@]}" \
                    "${SSH_USER}@${SSH_HOST}" "$@"
            else
                ssh -i "${HOST_SSH_KEY}" "${SSH_OPTS[@]}" \
                    "${SSH_USER}@${SSH_HOST}" "$@"
            fi
            ;;
        tailscale)
            local ts
            ts="$(tailscale_cli)" || die "tailscale CLI not found"
            if [[ -n "${HOST_COMMAND_TIMEOUT:-}" ]]; then
                run_with_timeout "${HOST_COMMAND_TIMEOUT}" \
                    "${ts}" ssh "${SSH_USER}@${SSH_HOST}" "$@"
            else
                "${ts}" ssh "${SSH_USER}@${SSH_HOST}" "$@"
            fi
            ;;
        *) die "unknown HOST_TRANSPORT '${HOST_TRANSPORT}'; use ssh|tailscale" ;;
    esac
}

have_host() {
    [[ -n "${SSH_HOST:-}" ]] || return 1
    case "${HOST_TRANSPORT}" in
        ssh)       [[ -f "${HOST_SSH_KEY:-}" ]] ;;
        tailscale) tailscale_cli >/dev/null ;;
        *)         return 1 ;;
    esac
}

kq() {
    local out err rc=0 tmp
    tmp="$(mktemp)"
    out="$(kubectl "$@" 2>"${tmp}")" || rc=$?
    err="$(cat "${tmp}")"; rm -f "${tmp}"
    case "${rc}:${err}" in
        0:*|*:*NotFound*|*:*"not found"*|*:*"No resources found"*|*:"") ;;
        *) warn "kubectl ${1:-}: $(oneline "${err}")" ;;
    esac
    printf '%s' "${out}"
}

RUN_LOG="${RUN_LOG:-${ROOT}/debug/run.log}"
QUIET_TAIL="${QUIET_TAIL:-25}"

_drop_noise() {
    grep -vE 'unlicensed vCluster|warnings\.go:[0-9]+' >&2 || true
}
kubectl() {
    local rc=0 tmp; tmp="$(mktemp)"
    command kubectl "$@" 2>"${tmp}" || rc=$?
    _drop_noise <"${tmp}"; rm -f "${tmp}"
    return "${rc}"
}
helm() {
    local rc=0 tmp; tmp="$(mktemp)"
    command helm "$@" 2>"${tmp}" || rc=$?
    _drop_noise <"${tmp}"; rm -f "${tmp}"
    return "${rc}"
}

quiet() {
    local rc=0
    mkdir -p "$(dirname "${RUN_LOG}")"
    printf '\n=== %s :: %s\n' "$(date -u +%H:%M:%S)" "$*" >>"${RUN_LOG}"
    "$@" >>"${RUN_LOG}" 2>&1 || rc=$?
    ((rc == 0)) && return 0
    warn "failed (exit ${rc}): $1"
    tail -n "${QUIET_TAIL}" "${RUN_LOG}" | sed 's/^/        /' >&2
    printf '        full log: %s\n' "${RUN_LOG}" >&2
    return "${rc}"
}

summary() {
    printf '\n%s%s%s\n' "${BOLD}" "$1" "${NC}" >&2; shift
    while (($# >= 2)); do printf '  %-14s %s\n' "$1" "$2" >&2; shift 2; done
    printf '\n' >&2
}

oneline() { printf '%s' "${1:-}" | tr '\n\r\t' '   ' | tr -s ' ' | sed 's/^ //; s/ $//'; }
digits()  { tr -dc '0-9'; }

# Named so the waits and the smoke test assert the same thing.

JQ_DHCP_UNHEALTHY='.items[]
  | select(.metadata.name | test("^dhcp-proxy"))
  | select((.status.phase != "Running")
      or (((.metadata.annotations["k8s.v1.cni.cncf.io/network-status"] // "")
           | contains($vip)) | not))
  | .metadata.namespace + "/" + .metadata.name'

JQ_LB_PENDING='[.items[]
  | select(.spec.type == "LoadBalancer")
  | select((.status.loadBalancer.ingress // []) | length == 0)
  | .metadata.namespace + "/" + .metadata.name] | join(" ")'

KEYCLOAK_PORT="${KEYCLOAK_PORT:-8082}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-nico}"
KEYCLOAK_AUTHORITY="${KEYCLOAK_AUTHORITY:-keycloak.${NICO_REST_NS}:${KEYCLOAK_PORT}}"

nico_rest_authority() {
    printf 'nico-rest-api.%s.svc.cluster.local:%s' "${NICO_REST_NS}" "${NICO_REST_PORT}"
}

# Reaches the site-agent through a ConfigMap, under either key spelling.
JQ_SITE_UUID='[.items[].data // {} | to_entries[]
  | select(.key | test("CLUSTER_ID|SITE_UUID")) | .value]
  | map(select(. != null and . != "")) | first // empty'

dhcp_unhealthy() {
    kubectl get pods -A -o json |
        jq -r --arg vip "${METAL3_DHCP_VIP}" "${JQ_DHCP_UNHEALTHY}" | tr '\n' ' '
}

nico_site_uuid() {
    kq get cm -n "${NICO_REST_NS}" -o json | jq -r "${JQ_SITE_UUID}"
}

render() {
    local tmpl="${ROOT}/values/$1"
    need_file "${tmpl}" "values template"
    eval "cat <<__RENDER_EOF__
$(cat "${tmpl}")
__RENDER_EOF__"
}
