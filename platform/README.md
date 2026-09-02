# vCluster Platform side (4.13+)

Order matters. The Platform mints its own tokens for NiCo, so NiCo has to trust the Platform's
OIDC issuer before the NodeProvider can pass its readiness probe.

1. Platform 4.13+ installed and reachable; feature `auto-nodes-nico` on the licence.
2. `nico/scripts/nico-trust.sh` (see nico/README.md): re-renders nico-rest with the Platform issuer
   and audience, disables the bundled Keycloak.
3. Apply, in this order or all at once: `nodeprovider-nico.yaml` (fill `siteId`, `siteIPBlockID`
   from day 0), `osimage-ubuntu-noble-nico.yaml`, `tenant-nico-demo.yaml`,
   `networkenvironment-nico-flat.yaml`.
4. Verify:

```
kubectl get nodeproviders nico -o jsonpath='{.status.phase} {.status.message}'   # Available
kubectl get nodetypes | grep nico                                                # nico.<instance-type>, discovered
kubectl get tenants.management.loft.sh nico-demo -o jsonpath='{.status.conditions}'   # NICoOnboarded=True
kubectl get networkenvironments nico-flat -o jsonpath='{.status.phase}'          # Available, vpc-id annotation written
kubectl get machines.management.loft.sh                                          # NiCo machines mirrored
```

5. `nodeclaim-example.yaml` for a standalone machine, or `vcluster-autonodes-snippet.yaml` to have
   a vCluster claim NiCo nodes.

Expect a few minutes between the NiCo instance reporting `Ready` and the node actually being up:
for a FLAT instance NiCo reports Ready once addresses are allocated, then power-cycles the host,
scout writes the image, and the host reboots into it. The Platform shows no node IP for FLAT
instances (the driver reads `interfaces[].ipAddresses`, which NiCo leaves empty in flat mode);
cosmetic.
