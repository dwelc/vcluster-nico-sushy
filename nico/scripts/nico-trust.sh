#!/usr/bin/env bash
# Post-Platform-upgrade: make nico-rest trust Platform-issued tokens (the NodeProvider mints
# RS256 JWTs with the Platform's OIDC key). This re-renders the nico-rest values with the
# Platform issuer and re-runs only the REST + site-agent phases. It disables the bundled
# Keycloak integration (issuers and keycloak are mutually exclusive), so nico-rest.sh stops
# working for provider-org calls afterwards; the Platform is the token issuer from here on.
#
# Run AFTER the Platform is on 4.13 and /oidc/keys answers:
#   curl -s http://loft.vcluster-platform.svc.cluster.local/oidc/keys   (from a pod)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
export PATH="$HOME/.local/bin:$PATH"
. config/demo.env

LOFT_HOST="${LOFT_HOST:-$(kubectl get --raw /apis/management.loft.sh/v1/configs/loft-manager-config 2>/dev/null | jq -r '.status.loftHost // empty')}"
[[ -n "${LOFT_HOST}" ]] || die "could not read status.loftHost from the Platform config; set LOFT_HOST=<platform hostname>"
export PLATFORM_ISSUER_URL="https://${LOFT_HOST#http*://}/oidc"
export PLATFORM_JWKS_URL="http://loft.${PLATFORM_NS}.svc.cluster.local:80/oidc/keys"
export PLATFORM_AUDIENCE="http://nico-rest-api.${NICO_REST_NS}.svc.cluster.local:${NICO_REST_PORT}"
export NICO_SITE_UUID="${NICO_SITE_UUID:-$(kubectl get cm -n "${NICO_REST_NS}" nico-rest-site-agent-config -o jsonpath='{.data.CLUSTER_ID}')}"
export PLATFORM_TRUST=true KEYCLOAK_ENABLED=false NICO_FROM=rest ASSUME_YES=true NICO_SKIP_DHCP_RELAY=true

echo "issuer   ${PLATFORM_ISSUER_URL}"
echo "jwks     ${PLATFORM_JWKS_URL}"
echo "audience ${PLATFORM_AUDIENCE}"
echo "site     ${NICO_SITE_UUID}"
exec ./scripts/nico-install.sh -y "$@"
