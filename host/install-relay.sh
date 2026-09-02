#!/usr/bin/env bash
# Install the DHCP relay (VM bridge -> NiCo Kea VIP) on the libvirt host. Idempotent.
set -euo pipefail
: "${SUSHY_HOST:?user@host}" "${SUSHY_HOST_BRIDGE:?bridge the VM NICs attach to}" "${RELAY_IP:?giaddr inside the HostInband prefix}" "${KEA_VIP:?NiCo DHCP LoadBalancer IP}"
SSH_KEY="${SSH_KEY:-}"; SSHOPTS=(-o BatchMode=yes); [[ -n "${SSH_KEY}" ]] && SSHOPTS+=(-i "${SSH_KEY}")
PREFIX_LEN="${PREFIX_LEN:-24}"
ssh "${SSHOPTS[@]}" "${SUSHY_HOST}" "sudo bash -s" <<EOF
set -e
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq isc-dhcp-relay >/dev/null 2>&1 || apt-get install -y isc-dhcp-relay
systemctl mask --now isc-dhcp-relay.service isc-dhcp-relay6.service >/dev/null 2>&1 || true
cat > /usr/local/sbin/nico-relay-addr.sh <<'SH'
#!/usr/bin/env bash
ip -4 addr show dev ${SUSHY_HOST_BRIDGE} | grep -q " ${RELAY_IP}/" || ip addr add ${RELAY_IP}/${PREFIX_LEN} dev ${SUSHY_HOST_BRIDGE}
SH
chmod +x /usr/local/sbin/nico-relay-addr.sh
cat > /etc/systemd/system/nico-relay-addr.service <<'UNIT'
[Unit]
Description=NiCo relay address ${RELAY_IP} on ${SUSHY_HOST_BRIDGE}
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/nico-relay-addr.sh
[Install]
WantedBy=multi-user.target
UNIT
cat > /etc/systemd/system/nico-dhcp-relay.service <<'UNIT'
[Unit]
Description=DHCP relay ${SUSHY_HOST_BRIDGE} -> NiCo Kea (${KEA_VIP})
After=network-online.target nico-relay-addr.service
Wants=network-online.target
Requires=nico-relay-addr.service
[Service]
Type=simple
# -i (bidirectional): Kea's replies to giaddr come back via the router onto this same bridge.
ExecStart=/usr/sbin/dhcrelay -d -i ${SUSHY_HOST_BRIDGE} ${KEA_VIP}
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now nico-relay-addr.service nico-dhcp-relay.service >/dev/null
sleep 2
systemctl --no-pager --plain list-units 'nico-*' | grep -E 'nico-(relay|dhcp)'
ip -br -4 addr show ${SUSHY_HOST_BRIDGE}
EOF
