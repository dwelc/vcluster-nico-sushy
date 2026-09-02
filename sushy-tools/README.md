# sushy-tools as a NiCo BMC

NiCo's site-explorer expects a lot more Redfish than Ironic does. `nico-surface.patch` adds the
missing surface to upstream sushy-tools 2.2.0 (one new module, `sushy_tools/emulator/nico.py`,
plus small template/driver edits). What it adds, all configurable:

| Need | Why NiCo wants it | Patch |
| --- | --- | --- |
| Service root `Vendor`, `Product`, `Links.Sessions` | hardware type is keyed on `Vendor`; `AMI` is the lightest path (no Dell/Supermicro OEM probes); the typed client requires `Links` | templates |
| System `SerialNumber`, `Model`, `SKU`, `Manufacturer` | serial must equal the ExpectedMachine chassis serial | libvirt `<sysinfo>` serial, config fallback |
| `Boot.BootOrder` + `BootOptions` (expanded members, `Alias`, `UefiDevicePath`, DisplayName with the MAC) | machine setup wants "UEFI HTTP IPv4 for the boot NIC" first; libredfish parses `Members` straight into `BootOption` | stored per system; first entry maps onto the libvirt boot device |
| `PATCH Systems/<id>/SD`, `Bios`, `Bios/Settings`, `Bios/SD`, `Bios/Actions/Bios.ResetBios` | AMI-specific spellings libredfish uses; sushy serves `BIOS` | route aliases |
| Manager `EthernetInterfaces/1`, `HostInterfaces/Self` (PATCHable), `NetworkProtocol` (PATCHable), `Actions/Manager.Reset` | BMC MAC, lockdown checks and writes, initial BMC reset | new resources |
| `UpdateService/FirmwareInventory` | fetched unconditionally | empty collection |
| BIOS defaults + integer typing | `LEM0001` etc. are compared as JSON numbers; libvirt metadata stores strings | rendered defaults, `SUSHY_EMULATOR_NICO_INT_ATTRS` |
| `UefiHttp` + `HttpBootUri` → network boot | stock sushy downloads the URI as a CD image | config flag |
| Systems/Managers/Chassis collections honour `SUSHY_EMULATOR_ALLOWED_INSTANCES` | one system per BMC | filters |

Things sushy already had that NiCo needs: Manager `DateTime`, System `EthernetInterfaces` with the
real MAC, `UefiHttp` in the boot override allow-list, basic auth (libredfish never uses sessions), TLS.

## Layout on the libvirt host

One emulator process per VM, each on its own LAN alias with TLS on :443, restricted to one libvirt
domain with `SUSHY_EMULATOR_ALLOWED_INSTANCES`. An existing sushy-tools service (for Metal3) can keep
running unchanged next to it.

```
get-source.sh                       # clone upstream 2.2.0 + apply the patch into ./src
vms.conf                            # name uuid bmc-ip bmc-mac serial, one VM per line
SUSHY_HOST=user@host SUSHY_HOST_LAN_IF=eno1 ./deploy.sh
SUSHY_HOST=user@host ./redefine-vms.sh   # SMBIOS serial + USB root disk (see below)
```

`deploy.sh` needs `gcc`, `pkg-config`, `python3-dev`, `libvirt-dev` on the host (libvirt-python is
built there). It creates `/opt/sushy-nico/{src,venv}`, `/etc/sushy-nico/<vm>.conf`, a self-signed
cert with all BMC IPs as SANs, an htpasswd, a oneshot unit that adds the aliases, and
`sushy-nico@<vm>.service` per VM.

## VM shape

`redefine-vms.sh` changes two things on each domain, idempotently:

- **SMBIOS serial** (`<sysinfo type="smbios">` + `<os><smbios mode="sysinfo"/>`) so the serial NiCo
  reads over Redfish and the one scout reads from DMI agree with the ExpectedMachine.
- **Root disk on a USB bus** (`qemu-xhci`). Two reasons: NiCo's REST API only accepts
  `imageDisk` matching `^/dev/(nvme\d+n\d+|sd*)`, and scout's storage cleanup runs `sg_sanitize`
  (SCSI) or `hdparm --security-erase` (ATA) on every fixed disk, which QEMU does not implement, but
  skips removable and USB-transport devices. A virtio or virtio-scsi disk fails ingestion with
  `Failed/NVMECleanFailed: sg_sanitize ... Invalid opcode`.

Leave UEFI firmware, a TPM (optional) and NIC-first boot order as you have them for Metal3.

## Testing without a cluster

`local-test.conf` runs the fork with sushy's fake driver. NiCo's own site-explorer probe,
`bmc-explorer-cli`, is not in the published image but builds from the NiCo repo:

```
cd infra-controller && docker build -t nico-build -f dev/docker/Dockerfile.cargo-docker-minimal .
docker run --rm -v "$PWD":/code -w /code nico-build cargo build -p bmc-explorer-cli
docker run --rm --network host -v "$PWD":/code -w /code nico-build \
  ./target/debug/bmc-explorer-cli --username admin --password password --mode nv-redfish \
  --bmc-port 8444 --boot-mac 52:54:00:bb:00:00 127.0.0.1
```

A good report ends with `"LastExplorationError":null` and, after NiCo's machine-setup writes,
`"MachineSetupStatus":{"IsDone":true,"Diffs":[]}`. `--mode libredfish` exercises the client NiCo
uses for the writes; `nv-redfish` is the default explorer. Run it against a real host BMC address
too (`--bmc-port 443`).
