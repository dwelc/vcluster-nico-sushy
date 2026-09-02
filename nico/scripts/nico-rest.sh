#!/usr/bin/env bash
# Talk to nico-rest-api as the provider org with a Keycloak client-credentials
# token (the same path nico-day0.sh uses). No Platform involved.
#   nico-rest.sh GET /machine
#   nico-rest.sh POST /instance '{"name":...}'
# The org is taken from the token's realm roles (ncx). Port-forwards are per call.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

METHOD="${1:?GET|POST|PATCH|DELETE}"; PATH_="${2:?/path}"; BODY="${3:-}"
KEYCLOAK_CLIENT_ID="${KEYCLOAK_CLIENT_ID:-ncx-service}"
REST_ORG="${REST_ORG:-${NICO_ORG}}"

pf() { # ns svc port -> local port
    local lp; lp=$((20000 + RANDOM % 20000))
    kubectl port-forward -n "$1" "svc/$2" "${lp}:$3" >/dev/null 2>&1 &
    echo $! > "/tmp/nico-rest-pf-$lp.pid"
    for _ in $(seq 1 40); do (exec 4<>"/dev/tcp/127.0.0.1/${lp}") 2>/dev/null && { echo "${lp}"; return; }; sleep 0.25; done
    die "port-forward to $2 never came up"
}
cleanup() { for f in /tmp/nico-rest-pf-*.pid; do [[ -f $f ]] && { kill "$(cat "$f")" 2>/dev/null; rm -f "$f"; }; done; }
trap cleanup EXIT

if [[ -z "${REST_TOKEN:-}" ]]; then
    kp="$(pf "${NICO_REST_NS}" keycloak "${KEYCLOAK_PORT}")"
    REST_TOKEN="$(curl -sS --fail-with-body -H "Host: ${KEYCLOAK_AUTHORITY}" \
        -d grant_type=client_credentials -d "client_id=${KEYCLOAK_CLIENT_ID}" \
        -d "client_secret=${KEYCLOAK_CLIENT_SECRET}" \
        "http://127.0.0.1:${kp}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token" | jq -re .access_token)"
fi
rp="$(pf "${NICO_REST_NS}" nico-rest-api "${NICO_REST_PORT}")"
curl -sS -X "${METHOD}" -H "Host: $(nico_rest_authority)" -H "Authorization: Bearer ${REST_TOKEN}" \
    -H 'Accept: application/json' -H 'Content-Type: application/json' \
    ${BODY:+--data "${BODY}"} "http://127.0.0.1:${rp}/v2/org/${REST_ORG}/nico${PATH_}"
echo
