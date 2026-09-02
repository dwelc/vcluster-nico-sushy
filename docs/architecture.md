# How it fits together

```
KUBERNETES LAB CLUSTER                                  LIBVIRT HOST
  vCluster Platform 4.13+ ── NodeProvider nico            VMs (UEFI, NIC-first boot, USB root disk)
  NiCo site controller: nico-api, dhcp (Kea), pxe,          one sushy-tools-nico process per VM
    dns, ntp, unbound, ssh-console, hw-health                 (TLS :443 on its own LAN alias)
  NiCo REST: api, site-manager, workers, site-agent        host bridge = the VM segment
  Vault, Postgres (Zalando), Temporal, ESO                  dhcrelay on that bridge -> Kea VIP
  (optionally, unchanged: Metal3/Ironic for other VMs)     (optionally, unchanged: the Metal3 sushy)

ROUTER: routes the VM segment <-> the LAN where the LB VIPs and the BMC aliases live
```

## Segments NiCo needs

| NiCo segment | Type | What it is here |
| --- | --- | --- |
| HostInband | `hostinband` | the L2 segment the VM NICs are on; NiCo DHCP hands out addresses from `reserve_first` up; the relay's `giaddr` must be inside it |
| OOB / BMC | `underlay` | the LAN where the per-VM sushy instances listen (`OOB_PREFIX`); BMCs are registered with fixed addresses and never DHCP |
| admin | `admin` | mandatory, nominal, nothing attaches (`192.168.176.0/20` default) |
| site IP block | n/a | unused by FLAT addressing, but the NodeProvider requires `siteIPBlockID` |

The three prefixes must have distinct network addresses. VIPs for Kea and PXE must be routable from
the VM segment; the API VIP from wherever the admin CLI runs (day 0 runs it as a Job in-cluster
against the `nico-api` ClusterIP to sidestep the VIP entirely).

## The boot chain, and where each hop fails

1. site-explorer probes the BMC over Redfish (TLS, basic auth), matches the serial, resets the
   BMC (`Manager.Reset`), sets BIOS attributes, boot order and lockdown, powers the host on.
   Failure: exploration report errors in nico-api logs, `machine_setup` diffs never empty.
2. OVMF PXE: DHCP DISCOVER (class `PXEClient`) → relay → Kea. Kea answers only the NiCo client
   class with option 67 = `http://<pxe-vip>:8080/public/blobs/internal/x86_64/ipxe.efi`.
   Failure: `Dropping reply received on <bridge>` in the relay log; no lease in Kea logs.
3. OVMF HTTP boot fetches `ipxe.efi`; iPXE does its own DHCP (client id `01:<mac>`) and fetches
   `/api/v0/pxe/boot?...&serial=<serial>` from nico-pxe, which looks the client up **by source IP**.
   Failure: boot script says `Client not found: <ip>`: the source IP was NATed (a
   `externalTrafficPolicy: Cluster` Service) or the lease is not NiCo's.
4. iPXE loads `scout.efi` + `scout.squashfs`; scout DHCPs again, connects to nico-api (gRPC, mTLS
   via the site CA), reports inventory, runs storage cleanup, and is told to reboot.
   Failure: `Failed/NVMECleanFailed` (fixed disk on a bus QEMU cannot sanitize; use USB).
5. Machine `Ready`, attached to an instance type. Instance create → NiCo resets the host again,
   iPXE gets an image-install script, scout writes the qcow2 to `/dev/sda`, host reboots into the
   OS, cloud-init runs the user-data NiCo serves (NoCloud over the network), DHCP again.

Redfish traffic: cluster → BMC aliases on the LAN. Boot traffic: VM segment → LB VIPs on the LAN via
the router. Image traffic: VM segment → your image server.
