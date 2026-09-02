#!/usr/bin/env bash
# Deploy the sushy-tools NiCo fork on the libvirt host as one Redfish BMC per VM.
# Additive: an existing sushy-tools service (e.g. the one Metal3 uses) is not touched.
#   /opt/sushy-nico/{src,venv}      patched sushy-tools + venv (libvirt-python built on the host)
#   /etc/sushy-nico/<vm>.conf       one config per VM (own LAN alias, TLS on :443)
#   sushy-nico-addrs.service        adds the LAN aliases (no netplan changes)
#   sushy-nico@<vm>.service         one emulator process per VM
# Inputs: vms.conf (this dir), SUSHY_HOST=user@host, SUSHY_HOST_LAN_IF=<nic carrying the LAN>,
#         optional SUSHY_HTPASSWD=/path/on/host (default: a fresh admin/password file).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${SUSHY_HOST:?user@host of the libvirt/sushy machine}"
: "${SUSHY_HOST_LAN_IF:?NIC on the sushy host that carries the BMC LAN, e.g. eno1}"
SSH_KEY="${SSH_KEY:-}"; SSHOPTS=(-o BatchMode=yes); [[ -n "${SSH_KEY}" ]] && SSHOPTS+=(-i "${SSH_KEY}")
SUSHY_HTPASSWD="${SUSHY_HTPASSWD:-/etc/sushy-nico/htpasswd}"
BMC_USERNAME="${BMC_USERNAME:-admin}"; BMC_PASSWORD="${BMC_PASSWORD:-password}"
SRC="${SUSHY_SRC:-${HERE}/src}"   # a sushy-tools checkout with nico-surface.patch applied (see README)
[[ -f "${SRC}/sushy_tools/emulator/nico.py" ]] || { echo "no patched sushy-tools at ${SRC}; run: bash ${HERE}/get-source.sh" >&2; exit 1; }
mapfile -t VMS < <(grep -vE '^\s*(#|$)' "${HERE}/vms.conf")
ssh_() { ssh "${SSHOPTS[@]}" "${SUSHY_HOST}" "$@"; }

echo "==> copying fork source"
tar -C "${SRC}" --exclude=.venv --exclude=.git --exclude='*.pyc' --exclude=__pycache__ -czf - . \
  | ssh_ 'sudo mkdir -p /opt/sushy-nico/src && sudo tar -C /opt/sushy-nico/src -xzf - && sudo chown -R root:root /opt/sushy-nico/src'

echo "==> venv + libvirt-python + fork"
ssh_ 'set -e
which gcc pkg-config >/dev/null || { echo "need gcc, pkg-config, python3-dev, libvirt-dev on the host" >&2; exit 1; }
[ -x /opt/sushy-nico/venv/bin/python ] || sudo python3 -m venv /opt/sushy-nico/venv
sudo -H /opt/sushy-nico/venv/bin/pip install -q --upgrade pip
sudo -H /opt/sushy-nico/venv/bin/pip install -q libvirt-python
sudo -H env PBR_VERSION=2.2.0.post1 /opt/sushy-nico/venv/bin/pip install -q -e /opt/sushy-nico/src
/opt/sushy-nico/venv/bin/python -c "import libvirt, sushy_tools.emulator.nico; print(\"venv ok\")"'

SANS="IP:$(ssh_ "ip -4 -o addr show dev ${SUSHY_HOST_LAN_IF} | awk '{print \$4}' | cut -d/ -f1 | head -1")"
for e in "${VMS[@]}"; do set -- $e; SANS="${SANS},IP:$3"; done

echo "==> config, TLS, units"
{
cat <<EOF
set -e
sudo mkdir -p /etc/sushy-nico /var/lib/sushy-nico
if [ ! -s "${SUSHY_HTPASSWD}" ]; then
  sudo sh -c 'echo "${BMC_USERNAME}:\$(openssl passwd -apr1 "${BMC_PASSWORD}")" > "${SUSHY_HTPASSWD}"'
fi
if [ ! -s /etc/sushy-nico/tls.key ]; then
  sudo openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj '/CN=sushy-nico' \
    -addext 'subjectAltName=${SANS}' -keyout /etc/sushy-nico/tls.key -out /etc/sushy-nico/tls.crt 2>/dev/null
fi
sudo tee /usr/local/sbin/sushy-nico-addrs.sh >/dev/null <<'SH'
#!/usr/bin/env bash
# Idempotently add the per-VM BMC aliases. Remove with: ip addr del <ip>/24 dev ${SUSHY_HOST_LAN_IF}
for ip in \$(grep -h SUSHY_EMULATOR_LISTEN_IP /etc/sushy-nico/*.conf | grep -oE '[0-9.]+'); do
  ip -4 addr show dev ${SUSHY_HOST_LAN_IF} | grep -q " \$ip/" || ip addr add "\$ip/24" dev ${SUSHY_HOST_LAN_IF}
done
SH
sudo chmod +x /usr/local/sbin/sushy-nico-addrs.sh
sudo tee /etc/systemd/system/sushy-nico-addrs.service >/dev/null <<'UNIT'
[Unit]
Description=LAN aliases for sushy-nico BMCs
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/sushy-nico-addrs.sh
[Install]
WantedBy=multi-user.target
UNIT
sudo tee /etc/systemd/system/sushy-nico@.service >/dev/null <<'UNIT'
[Unit]
Description=sushy-tools NiCo fork Redfish BMC for %i
After=network-online.target libvirtd.service sushy-nico-addrs.service
Requires=libvirtd.service sushy-nico-addrs.service
[Service]
Type=simple
ExecStart=/opt/sushy-nico/venv/bin/python -m sushy_tools.emulator.main --config /etc/sushy-nico/%i.conf
Restart=on-failure
RestartSec=5
User=root
LimitNOFILE=1048576
SyslogIdentifier=sushy-nico-%i
[Install]
WantedBy=multi-user.target
UNIT
EOF
for e in "${VMS[@]}"; do set -- $e
cat <<EOF
sudo mkdir -p /var/lib/sushy-nico/$1
sudo tee /etc/sushy-nico/$1.conf >/dev/null <<'CONF'
# sushy-tools NiCo fork: $1 as a single-system AMI-class Redfish BMC
SUSHY_EMULATOR_LISTEN_IP = '$3'
SUSHY_EMULATOR_LISTEN_PORT = 443
SUSHY_EMULATOR_SSL_CERT = '/etc/sushy-nico/tls.crt'
SUSHY_EMULATOR_SSL_KEY = '/etc/sushy-nico/tls.key'
SUSHY_EMULATOR_LIBVIRT_URI = 'qemu:///system'
SUSHY_EMULATOR_AUTH_FILE = '${SUSHY_HTPASSWD}'
SUSHY_EMULATOR_STATE_DIR = '/var/lib/sushy-nico/$1'
SUSHY_EMULATOR_ALLOWED_INSTANCES = {'$2'}
SUSHY_EMULATOR_NICO_VENDOR = 'AMI'
SUSHY_EMULATOR_NICO_MODEL = 'kvm-guest'
# Fallback when the domain has no SMBIOS serial (redefine-vms.sh sets one; libvirt wins).
SUSHY_EMULATOR_SYSTEM_SERIALS = {'$1': '$5'}
SUSHY_EMULATOR_BMC_MACS = {'$2': '$4'}
CONF
EOF
done
cat <<'EOF'
sudo systemctl daemon-reload
sudo systemctl enable --now sushy-nico-addrs.service >/dev/null
EOF
for e in "${VMS[@]}"; do set -- $e; echo "sudo systemctl enable --now sushy-nico@$1.service >/dev/null; sudo systemctl restart sushy-nico@$1.service"; done
echo 'sleep 3; systemctl --no-pager --plain list-units "sushy-nico*" | grep sushy-nico'
} | ssh_ 'bash -s'

echo "==> probe"
for e in "${VMS[@]}"; do set -- $e
  printf '%s @ %s: ' "$1" "$3"
  curl -sk -u "${BMC_USERNAME}:${BMC_PASSWORD}" "https://$3/redfish/v1/Systems" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["Members@odata.count"], "system(s)")'
done
