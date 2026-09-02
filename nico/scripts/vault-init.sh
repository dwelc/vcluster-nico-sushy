#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VAULT_NS="${VAULT_NS:-vault}"
NICO_SYSTEM_NS="${NICO_SYSTEM_NS:-nico-system}"
VAULT_REPLICAS="${VAULT_REPLICAS:-3}"
STATUS_RETRIES="${STATUS_RETRIES:-36}"

vault_exec() { kubectl exec -n "${VAULT_NS}" "$1" -c vault -- "${@:2}"; }

# The listener accepts connections before it serves a parseable status.
vault_status() {
    local pod="$1" out i
    for (( i = 1; i <= STATUS_RETRIES; i++ )); do
        out="$(vault_exec "${pod}" vault status -tls-skip-verify -format=json 2>/dev/null || true)"
        if jq -e '.initialized|type=="boolean"' <<<"${out}" >/dev/null 2>&1; then
            printf '%s' "${out}"
            return 0
        fi
        sleep 5
    done
    die "no parseable vault status from ${pod} after $(( STATUS_RETRIES * 5 ))s"
}

cluster_keys() {
    kubectl -n "${VAULT_NS}" get secret vault-cluster-keys \
        -o jsonpath='{.data.cluster-keys\.json}' | base64 -d
}

# Helm adopts objects it did not create only when they carry its own labels.
adopt() {
    kubectl label "$@" app.kubernetes.io/managed-by=Helm --overwrite >/dev/null
    kubectl annotate "$@" meta.helm.sh/release-name=nico-prereqs \
        meta.helm.sh/release-namespace="${NICO_SYSTEM_NS}" --overwrite >/dev/null
}

phase "vault init and unseal"

for (( i = 0; i < VAULT_REPLICAS; i++ )); do
    until kubectl get pod "vault-${i}" -n "${VAULT_NS}" >/dev/null 2>&1; do sleep 5; done
    kubectl wait "pod/vault-${i}" -n "${VAULT_NS}" --for=condition=Initialized --timeout=300s
done

if [[ "$(vault_status vault-0 | jq -r '.initialized')" == "false" ]]; then
    keys="$(mktemp)"
    trap 'rm -f "${keys}"' EXIT
    vault_exec vault-0 vault operator init \
        -tls-skip-verify -key-shares=5 -key-threshold=3 -format=json >"${keys}"
    kubectl create secret generic vault-cluster-keys -n "${VAULT_NS}" \
        --from-file=cluster-keys.json="${keys}"
    ok "vault initialised"
else
    ok "vault already initialised"
fi

CLUSTER_JSON="$(cluster_keys)"
UNSEAL=()
while IFS= read -r _k; do UNSEAL+=("${_k}"); done < <(
    jq -r '.unseal_keys_b64[]' <<<"${CLUSTER_JSON}")
(( ${#UNSEAL[@]} == 5 )) || die "expected 5 unseal keys, got ${#UNSEAL[@]}"
ROOT_TOKEN="$(jq -r '.root_token' <<<"${CLUSTER_JSON}")"

unseal_pod() {
    local pod="$1" round key
    if [[ "$(vault_status "${pod}" | jq -r '.sealed')" == "false" ]]; then
        ok "${pod} already unsealed"
        return 0
    fi
    for round in 1 2 3; do
        for key in "${UNSEAL[@]:0:3}"; do
            vault_exec "${pod}" vault operator unseal -tls-skip-verify "${key}" >/dev/null || true
            sleep 5
        done
        [[ "$(vault_status "${pod}" | jq -r '.sealed')" == "false" ]] && { ok "${pod} unsealed"
            return 0; }
        warn "${pod} still sealed after round ${round}"
    done
    die "${pod} is still sealed after 3 rounds"
}

unseal_pod vault-0

if (( VAULT_REPLICAS > 1 )); then
    for (( i = 1; i <= 30; i++ )); do
        [[ -n "$(vault_status vault-0 | jq -r '.leader_address // empty')" ]] && break
        sleep 5
    done
    leader="$(vault_status vault-0 | jq -r '.leader_address // empty')"
    if [[ -n "${leader}" ]]; then ok "raft leader elected: ${leader}"
    else warn "vault-0 reports no leader_address; followers may fail to join the raft"; fi
    for (( i = 1; i < VAULT_REPLICAS; i++ )); do unseal_pod "vault-${i}"; done
fi

kubectl create secret generic vaultunsealkeys -n "${VAULT_NS}" --type=Opaque \
    --from-literal=0="${UNSEAL[0]}" --from-literal=1="${UNSEAL[1]}" \
    --from-literal=2="${UNSEAL[2]}" --from-literal=3="${UNSEAL[3]}" \
    --from-literal=4="${UNSEAL[4]}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl create secret generic vaultroottoken -n "${VAULT_NS}" --type=Opaque \
    --from-literal=token="${ROOT_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl create namespace "${NICO_SYSTEM_NS}" --dry-run=client -o yaml \
    | kubectl apply -f - >/dev/null
adopt namespace "${NICO_SYSTEM_NS}"
kubectl create secret generic nico-vault-token -n "${NICO_SYSTEM_NS}" --type=Opaque \
    --from-literal=token="${ROOT_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
adopt secret nico-vault-token -n "${NICO_SYSTEM_NS}"

ok "vault unsealed, root token in ${VAULT_NS}/vaultroottoken and ${NICO_SYSTEM_NS}/nico-vault-token"
