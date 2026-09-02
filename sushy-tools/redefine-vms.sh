#!/usr/bin/env bash
# Make libvirt VMs NiCo-shaped, in place (idempotent, VMs are powered off if running):
#   - SMBIOS serial/manufacturer/product (site-explorer matches Systems[0].SerialNumber
#     against the ExpectedMachine chassis serial)
#   - root disk on a USB bus so it is /dev/sda (NiCo rejects /dev/vda) AND scout's storage
#     cleanup skips it (it runs sg_sanitize/hdparm on fixed disks; QEMU implements neither)
# Boot order (NIC first) and firmware (UEFI) are left as they are. Backups of the XML land in
# /var/lib/sushy-nico/xml-backup/ on the host.
# Inputs: vms.conf (this dir), SUSHY_HOST=user@host, optional SSH_KEY.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${SUSHY_HOST:?user@host of the libvirt/sushy machine}"
SSH_KEY="${SSH_KEY:-}"; SSHOPTS=(-o BatchMode=yes); [[ -n "${SSH_KEY}" ]] && SSHOPTS+=(-i "${SSH_KEY}")
mapfile -t VMS < <(grep -vE '^\s*(#|$)' "${HERE}/vms.conf")

for e in "${VMS[@]}"; do set -- $e; vm=$1; serial=$5
ssh "${SSHOPTS[@]}" "${SUSHY_HOST}" "sudo python3 - '$vm' '$serial'" <<'PY'
import subprocess, sys, xml.etree.ElementTree as ET, os, time
vm, serial = sys.argv[1], sys.argv[2]
state = subprocess.check_output(['virsh', 'domstate', vm], text=True).strip()
if state != 'shut off':
    subprocess.run(['virsh', 'destroy', vm], check=True, stdout=subprocess.DEVNULL); print(f'{vm}: powered off')
xml = subprocess.check_output(['virsh', 'dumpxml', '--inactive', vm], text=True)
os.makedirs('/var/lib/sushy-nico/xml-backup', exist_ok=True)
open(f'/var/lib/sushy-nico/xml-backup/{vm}-{int(time.time())}.xml', 'w').write(xml)
t = ET.fromstring(xml); changed = []

si = t.find("sysinfo[@type='smbios']")
if si is None:
    si = ET.SubElement(t, 'sysinfo', type='smbios'); changed.append('sysinfo')
sysel = si.find('system')
if sysel is None:
    sysel = ET.SubElement(si, 'system')
def entry(name, value):
    for e in sysel.findall('entry'):
        if e.get('name') == name:
            if e.text != value: e.text = value; changed.append(name)
            return
    ET.SubElement(sysel, 'entry', name=name).text = value; changed.append(name)
entry('serial', serial); entry('manufacturer', 'AMI'); entry('product', 'kvm-guest')
osel = t.find('os')
if osel.find('smbios') is None:
    ET.SubElement(osel, 'smbios', mode='sysinfo'); changed.append('os/smbios')

dev = t.find('devices')
for d in dev.findall('disk'):
    if d.get('device') != 'disk': continue
    tg = d.find('target')
    if tg.get('bus') != 'usb':
        tg.set('bus', 'usb'); tg.set('dev', 'sda'); changed.append('disk->usb')
        a = d.find('address')
        if a is not None: d.remove(a)
for c in dev.findall('controller'):
    if c.get('type') == 'scsi' and c.get('model') == 'virtio-scsi':
        dev.remove(c); changed.append('drop virtio-scsi ctrl')
if not any(c.get('type') == 'usb' and c.get('model') == 'qemu-xhci' for c in dev.findall('controller')):
    ET.SubElement(dev, 'controller', type='usb', model='qemu-xhci', index='0'); changed.append('xhci ctrl')

if changed:
    open(f'/tmp/{vm}.nico.xml', 'w').write(ET.tostring(t, encoding='unicode'))
    subprocess.run(['virsh', 'define', f'/tmp/{vm}.nico.xml'], check=True, stdout=subprocess.DEVNULL)
    print(f'{vm}: redefined ({", ".join(changed)})')
else:
    print(f'{vm}: already NiCo-shaped')
tt = ET.fromstring(subprocess.check_output(['virsh', 'dumpxml', '--inactive', vm], text=True))
print('  serial:', tt.find("sysinfo/system/entry[@name='serial']").text,
      '| disk:', [(d.find('target').get('dev'), d.find('target').get('bus')) for d in tt.find('devices').findall('disk') if d.get('device') == 'disk'],
      '| boot:', [(x.tag, x.find('boot').get('order')) for x in tt.find('devices') if x.find('boot') is not None])
PY
done
