# Installing NiCo on your lab cluster

NiCo has no single chart. These scripts are a trimmed, resumable port of NVIDIA's `helm-prereqs`
flow (16 phases) for a lab that already has cert-manager, a LoadBalancer implementation and a
Retain-capable StorageClass. Everything is driven by `config/site.env`.

Tools on your workstation: `kubectl`, `helm`, `helmfile` (1.7.x), the helm-diff plugin, `jq`,
`envsubst`, `openssl`, `ssh-keygen`, `python3`, `git`, `curl`. The cluster needs three schedulable
amd64 nodes (Vault and Postgres run three replicas), ~10 Gi RAM headroom, and a few Retain PVs.
NiCo images are amd64 only; taint or exclude arm64 nodes.

```
$EDITOR config/site.env               # the live config: fill every CHANGE-ME
./scripts/nico-install.sh -y          # phases: postgres-operator, vault (+init/unseal), external-secrets,
                                      #   nico-prereqs, core, rest bootstrap, keycloak, temporal, rest, site-agent
```

A failed phase prints `resume: nico-setup.sh --from <phase>`; every phase is idempotent. The
upstream source is checked out under `/var/tmp/nico-install-<version>/src`, copied never edited.
Logs: `debug/run.log`.

## Day 0

```
NICO_SITE_UUID=$(kubectl get cm -n nico-rest nico-rest-site-agent-config -o jsonpath='{.data.CLUSTER_ID}')
NICO_SITE_UUID=$NICO_SITE_UUID ASSUME_YES=true VM_NAMES="nico-vm-1 nico-vm-2" \
  ADMIN_CLI_IMAGE=ghcr.io/janekbaraniewski/nvmetal-carbide:v2.1.0-rc.8 \
  HOSTINBAND_PREFIX=192.0.2.0/24 HOSTINBAND_GATEWAY=192.0.2.1 HOSTINBAND_RESERVE_FIRST=50 \
  ./scripts/nico-day0.sh --through rest --site-ip-block-id-file debug/site-ip-block-id
```

Stages: `creds` (Vault: site BMC root, factory BMC creds, UEFI passwords), `machines`
(ExpectedMachines with fixed BMC addresses, then a wait for site-explorer to ingest: reset, BIOS
setup, boot order, lockdown, power on, scout, cleanup, Ready), `segment`, `rest` (instance type +
site IP block, machines attached). The summary line at the end has the `siteId` and
`siteIPBlockID` the Platform NodeProvider needs. `--recreate-machines` force-deletes and
re-ingests (use after changing a VM's disk or serial).

## Load balancer modes

- `LB_MODE=cilium` (LB-IPAM + L2): VIPs are pinned per Service with `lbipam.cilium.io/ips` from
  your existing pool; TCP/UDP pairs share an address via `lbipam.cilium.io/sharing-key`. NiCo's PXE
  and API identify a booting host by its **source IP**, so their Services keep
  `externalTrafficPolicy: Local`. Cilium's L2 lease holder is not endpoint-aware, so the installer
  pins `nico-api`, `nico-pxe` and `nico-dhcp` to `NICO_EDGE_NODE` and creates a
  `CiliumL2AnnouncementPolicy` that announces `nico-system` only from that node. Your default
  policy must exclude the namespace:
  ```yaml
  serviceSelector:
    matchExpressions:
      - {key: io.kubernetes.service.namespace, operator: NotIn, values: [nico-system]}
  ```
- `LB_MODE=metallb`: pools + L2Advertisement from `values/lb-metallb.yaml.tmpl`, the upstream
  layout; MetalLB announces `Local` Services from the right node by itself.

## After the Platform is on 4.13

`./scripts/nico-trust.sh` makes nico-rest trust Platform-issued tokens (issuer
`https://<loftHost>/oidc`, JWKS from the in-cluster loft Service, audience = the NodeProvider
endpoint) and disables the bundled Keycloak. From then on `nico-rest.sh` needs a Platform-minted
token: `REST_TOKEN=$(./scripts/mint-platform-token.sh ncx PROVIDER_ADMIN) ./scripts/nico-rest.sh GET /machine`
(`mint-platform-token.sh <org> TENANT_ADMIN` for a tenant org). The minter signs with the
Platform's `loft-cert` key, the same way `pkg/autoscaling/nico/credentials.go` does.

## Uninstall

Do not run upstream's `helm-prereqs/clean.sh` on a shared cluster: it deletes cert-manager,
monitoring, local-path and more. The safe subset, in reverse order: `helm uninstall`
`nico-rest-site-agent`, `nico-rest`, `temporal`, `nico`, `nico-prereqs`, `external-secrets`, `vault`,
`postgres-operator`; delete namespaces `nico-system nico-rest temporal vault postgres external-secrets
forge-system`; delete ClusterIssuers `site-issuer selfsigned-bootstrap vault-nico-issuer
nico-rest-ca-issuer`, the `site-root` Certificate in cert-manager, and the ESO CRDs. Retain-class
PVs stay until you delete them.
