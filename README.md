# NiCo + sushy-tools: vMetal's NiCo driver on a libvirt lab

vCluster Platform 4.13 adds a NodeProvider backed by **NiCo** (NVIDIA Infra Controller,
[github.com/NVIDIA/infra-controller](https://github.com/NVIDIA/infra-controller)) next to the
Metal3 one. NiCo expects real BMCs. This repo is what it takes to make libvirt VMs behind
**sushy-tools** pass as NiCo-managed bare metal, so the same VMs you already use for Metal3
demos can serve a NiCo demo too. Validated end to end on 2026-09-02: NiCo v2.1.0-rc.8,
sushy-tools 2.2.0, Platform 4.13.0-alpha.6, Ubuntu 24.04 guests.

NiCo does not need GPUs or DPUs for this: "zero-DPU, FLAT" mode. It does need Redfish that
sushy-tools does not serve out of the box, a DHCP relay, and VMs shaped a particular way.
That is what is here.

## Layout

| Dir | What |
| --- | --- |
| `sushy-tools/` | the NiCo surface as a patch on sushy-tools 2.2.0, per-VM deployment on the libvirt host, VM reshaping, a no-libvirt test rig |
| `host/` | DHCP relay from the VM segment to NiCo's Kea |
| `nico/` | the NiCo installer (scripted; there is no chart), day 0, REST helpers, Platform trust |
| `platform/` | vCluster Platform objects: NodeProvider, Tenant, NetworkEnvironment, OSImage, NodeClaim, auto-nodes snippet |
| `docs/` | how it fits together, the boot chain hop by hop, and a symptom-first troubleshooting table |

## Order of operations

1. **VMs**: pick the VMs NiCo gets (a VM cannot be a BareMetalHost and a NiCo machine at the same
   time; the Metal3 operator would power it off). Fill `sushy-tools/vms.conf`. Run
   `sushy-tools/redefine-vms.sh` (SMBIOS serial, USB root disk).
2. **BMCs**: `sushy-tools/get-source.sh`, then `sushy-tools/deploy.sh`. One TLS Redfish endpoint
   per VM on its own LAN address. Your existing sushy-tools service stays as it is.
3. **Relay**: `host/install-relay.sh` on the libvirt host.
4. **NiCo**: fill `nico/config/site.env`, run `nico/scripts/nico-install.sh -y`, then
   `nico-day0.sh --through rest`. Both VMs should reach `Ready` in NiCo; this is the real proof
   and needs no Platform.
5. **Platform** (4.13+): `nico/scripts/nico-trust.sh`, apply `platform/*.yaml`, claim a node.

## What you are signing up for

NiCo is a suite: Postgres (operator, 3 instances), Vault (3 replicas), external-secrets, Temporal,
Keycloak (until the Platform is the issuer), ~10 Gi RAM, three amd64 nodes. Its own `clean.sh`
would delete your cert-manager and monitoring; `nico/README.md` has the safe uninstall.

## Where the numbers come from

Lab-specific values live only in `nico/config/site.env` and `sushy-tools/vms.conf`; the examples use
RFC 5737 documentation ranges. The address planning you need: one L2 segment for the VMs
(HostInband) with NiCo's dynamic range above any static addresses, ten LoadBalancer IPs, one LAN
alias per VM for its BMC, and a relay address on the VM bridge.
