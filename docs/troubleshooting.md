# Troubleshooting

Everything below was hit while bringing this up on a lab with Cilium, a shared Metal3/NiCo VM
segment and a router between the VM segment and the LAN. Symptom first.

| Symptom | Cause | Fix |
| --- | --- | --- |
| REST Postgres pod crash-loops: `directory "/var/lib/postgresql/data" exists but is not empty ... lost+found` | a block PVC mounted directly as PGDATA | `nico-setup.sh` sets `PGDATA=/var/lib/postgresql/data/pgdata` after the kustomize apply |
| DNS/PXE/unbound LoadBalancer Services never get an IP (Cilium) | the chart splits TCP and UDP into separate Services sharing one IP (MetalLB `allow-shared-ip`) | `lbipam.cilium.io/sharing-key` per group, in `nico-core.yaml.tmpl` |
| Day-0 admin-CLI Job: `tcp connect error` to the API VIP | `externalTrafficPolicy: Local` and the L2 lease sits on a node without the pod | the Job talks to `nico-api` ClusterIP:1079 |
| API/PXE VIPs unreachable from the LAN; ok from one node | same lease/endpoint mismatch | keep `Local` (PXE needs the client IP), pin `nico-api/pxe/dhcp` to one node and announce `nico-system` only from it |
| `Initial BMC reset failed ... 404 .../Actions/Manager.Reset` | NiCo resets the BMC before preingestion | in the fork: no-op 204 |
| Kea logs `DHCP4_LEASE_ADVERT` but the VM never boots | relay drops Kea's reply: it comes back through the router onto the VM bridge | `dhcrelay -i <bridge>` (bidirectional), not `-id/-iu` |
| iPXE: `Failed to fetch custom_ipxe ... Client not found: <node or router IP>` | source NAT: PXE Service with `externalTrafficPolicy: Cluster`, or the request came from the relay host itself | `Local` + pinning as above; the log line names the IP nico-pxe saw |
| `HostInitializing/WaitingForLockdown`, `405 Method Not Allowed` on `HostInterfaces/Self` | NiCo PATCHes the host interface and IPMI state | in the fork: PATCH handlers |
| `MachineSetupStatus` diff `LEM0001 expected "3" actual "3"` | string vs JSON number | in the fork: `SUSHY_EMULATOR_NICO_INT_ATTRS` |
| `Failed/NVMECleanFailed: sg_sanitize ... Invalid opcode` on `/dev/sda` | scout wipes fixed disks; QEMU implements neither SCSI SANITIZE nor ATA secure erase; USB/removable devices are skipped | root disk on a USB bus (`redefine-vms.sh`) |
| Machine Failed and stays Failed | NiCo does not retry a failed ingestion | `nico-day0.sh --only machines --recreate-machines` (force-delete + re-ingest) |
| Tenant `NICoOnboarded=False AllocationCapacityUnavailable`; NetworkEnvironment `403 Site is not associated with org` | every machine is already reserved by another allocation (e.g. one you created by hand for the provider org) | shrink it: `PATCH /allocation/<id>/constraint/<cid> {"constraintValue":N}`; a tenant only sees a site through an allocation |
| Keycloak tokens rejected after `nico-trust.sh` | `issuers` and `keycloak` are mutually exclusive in nico-rest | mint Platform-style tokens with `mint-platform-token.sh` |
| Everything installed, `nico-setup.sh` says `syntax error` at the last line | you edited a running script; bash reads incrementally | cosmetic; check the phases actually completed |

## Reading the state machine

```
kubectl logs -n nico-system deploy/nico-api --since=5m | grep -oE 'object_id=fm100[a-z0-9]{6}[a-z0-9]* span_name=handle_object_state state="?[A-Za-z/]+' | sort | uniq -c
```

Expected path: `HostInitializing/WaitingForLockdown` → `PollingBiosSetup` → `SetBootOrder` →
`WaitingForPlatformConfiguration` → `Measuring` → `WaitingForDiscovery` → (scout) → `Assigned/Ready`
or `Ready`. The machine id changes at discovery: NiCo derives it from the hardware scout reports.

Useful single lines:

```
kubectl logs -n nico-system deploy/nico-pxe --since=5m | grep -oE 'remote_ip=[^ ]+|request_path=[^ ]+|response_status=[0-9]+' | paste - - -
kubectl logs -n nico-system deploy/nico-dhcp --since=5m | grep -E 'LEASE_ALLOC|LEASE_ADVERT'
journalctl -u nico-dhcp-relay -f                      # on the libvirt host
journalctl -u sushy-nico@<vm> -f | grep -E 'PATCH|POST' # what NiCo writes to the BMC
virsh qemu-agent-command <vm> '{"execute":"guest-exec",...}'   # inside a provisioned guest (agent via cloud-init)
```
