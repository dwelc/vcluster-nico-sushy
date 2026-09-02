# Host side: DHCP relay from the VM segment to NiCo's Kea

Zero-DPU hosts get their addresses and boot URL from NiCo's central DHCP (Kea with the NiCo hook).
Kea runs in the cluster behind a LoadBalancer VIP, so the L2 segment your VMs sit on needs a relay.
The libvirt host already bridges that segment, so it is the natural place.

Two units, rendered by `install-relay.sh`:

- `nico-relay-addr.service`: puts `RELAY_IP` (an address inside the HostInband prefix, outside
  NiCo's dynamic range) on the host bridge. NiCo resolves the segment purely by prefix containment
  of `giaddr`, so this address is what makes the relay's requests land on the right segment.
- `nico-dhcp-relay.service`: `dhcrelay -d -i <bridge> <kea-vip>`. One **bidirectional** interface,
  not `-id/-iu`: Kea unicasts its reply to `giaddr`, your router delivers it back onto the VM
  segment, and it arrives on the same bridge. With `-iu <lan-nic>` isc-dhcp-relay drops those
  replies as "received on the wrong interface" and the VMs never get an offer.

Sharing the segment with a Metal3/Ironic DHCP is fine as long as each server only answers its own
MACs: vCluster's dhcp-proxy answers only MACs that have a BareMetalHost, and Kea's client class in
`nico/values/nico-core.yaml.tmpl` restricts NiCo to your VM MAC prefix. Keep NiCo's dynamic range
(`HOSTINBAND_RESERVE_FIRST`) above any static Metal3 addresses.

```
SUSHY_HOST=user@host SUSHY_HOST_BRIDGE=br-provision RELAY_IP=192.0.2.4 KEA_VIP=198.51.100.236 ./install-relay.sh
```

Check: `journalctl -u nico-dhcp-relay -f` should show `Forwarded BOOTREQUEST ... to <kea-vip>` and
`Forwarded BOOTREPLY ... to 255.255.255.255` once a VM boots. "Dropping reply received on <bridge>"
means the `-i` form is not in place.
