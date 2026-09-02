#!/usr/bin/env bash
# Mint a NiCo token the way the Platform does (pkg/autoscaling/nico/credentials.go): RS256 with
# the Platform's OIDC key (loft-cert tls.key), iss = https://<loftHost>/oidc, aud = the NodeProvider
# endpoint, organization + roles as private claims. Only needed for ad-hoc REST calls after
# nico-trust.sh disabled Keycloak. Usage: mint-platform-token.sh [org] [role] [ttl-seconds]
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ORG="${1:-${NICO_ORG}}"; ROLE="${2:-PROVIDER_ADMIN}"; TTL="${3:-600}"
case "${ROLE}" in PROVIDER_ADMIN) SUB="platform:provider:${ORG}";; *) SUB="platform:tenant:${ORG}";; esac
LOFT_HOST="${LOFT_HOST:-$(kubectl get --raw /apis/management.loft.sh/v1/configs/loft-manager-config | jq -r '.status.loftHost')}"
ISS="https://${LOFT_HOST#http*://}/oidc"
AUD="http://nico-rest-api.${NICO_REST_NS}.svc.cluster.local:${NICO_REST_PORT}"
KEY="$(mktemp)"; trap 'rm -f "${KEY}"' EXIT; chmod 600 "${KEY}"
kubectl -n "${PLATFORM_NS}" get secret loft-cert -o jsonpath='{.data.tls\.key}' | base64 -d > "${KEY}"
lp=$((20000 + RANDOM % 20000))
kubectl port-forward -n "${PLATFORM_NS}" svc/loft "${lp}:80" >/dev/null 2>&1 & pf=$!
trap 'kill ${pf} 2>/dev/null; rm -f "${KEY}"' EXIT
for _ in $(seq 1 40); do (exec 4<>"/dev/tcp/127.0.0.1/${lp}") 2>/dev/null && break; sleep 0.25; done
KID="$(curl -s "http://127.0.0.1:${lp}/oidc/keys" | jq -r '.keys[0].kid')"
[[ -n "${KID}" && "${KID}" != null ]] || die "could not read the JWKS kid"
b64() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
now=$(date +%s)
HDR="$(jq -nc --arg kid "${KID}" '{alg:"RS256",typ:"JWT",kid:$kid}' | b64)"
PAY="$(jq -nc --arg iss "${ISS}" --arg sub "${SUB}" --arg aud "${AUD}" --arg org "${ORG}" --arg role "${ROLE}" \
      --argjson iat "${now}" --argjson exp "$((now + TTL))" \
      '{iss:$iss,sub:$sub,aud:[$aud],iat:$iat,nbf:$iat,exp:$exp,organization:$org,roles:[$role]}' | b64)"
SIG="$(printf '%s.%s' "${HDR}" "${PAY}" | openssl dgst -sha256 -sign "${KEY}" | b64)"
printf '%s.%s.%s\n' "${HDR}" "${PAY}" "${SIG}"
