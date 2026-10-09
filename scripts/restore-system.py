#!/usr/bin/env python3
"""Restore one coherent LVM/LUKS/UEFI backup onto an explicitly selected disk."""
from __future__ import annotations
import argparse
import copy
from datetime import datetime
import fcntl
import getpass
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile

spec = importlib.util.spec_from_file_location('restore_config', Path(__file__).with_name('restore-config.py'))
CONFIG = importlib.util.module_from_spec(spec)
spec.loader.exec_module(CONFIG)
GIB = 1024 ** 3


def run(*args, capture=False, env=None):
    command = [str(arg) for arg in args]
    result = subprocess.run(command, check=True, text=True, stdout=subprocess.PIPE if capture else None, env=env)
    return result.stdout.strip() if capture else None


def atomic_json(path, data):
    path = Path(path)
    temp = path.with_suffix(path.suffix + '.tmp')
    with temp.open('w') as stream:
        os.fchmod(stream.fileno(), 0o600)
        json.dump(data, stream, indent=2, sort_keys=True)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())
    temp.replace(path)


def descendants(node):
    yield node
    for child in node.get('children', []):
        yield from descendants(child)


def inventory():
    # --tree is explicit: PATH instead of NAME otherwise makes lsblk flatten output.
    devices = json.loads(run('lsblk', '--tree', '--json', '--bytes', '--paths', '-o',
                             'PATH,TYPE,SIZE,FSTYPE,UUID,PARTUUID,MOUNTPOINTS,SERIAL,WWN,MODEL', capture=True))['blockdevices']
    groups = json.loads(run('vgs', '--reportformat', 'json', '-o', 'vg_name', capture=True))
    names = {row['vg_name'].strip() for report in groups['report'] for row in report.get('vg', [])}
    return devices, names


def check_target(config, devices, *, resume=False):
    requested = config['target']
    if not requested['device'] or not requested['serial']:
        raise ValueError('Set target.device and target.serial, or use --interactive')
    resolved = str(Path(requested['device']).resolve())
    disk = next((node for node in devices if node['type'] == 'disk' and str(Path(node['path']).resolve()) == resolved), None)
    if disk is None:
        raise ValueError('Target must be a connected whole disk')
    if (disk.get('serial') or '').strip() != requested['serial']:
        raise ValueError('Target serial mismatch; refusing this disk')
    for node in descendants(disk):
        if any(node.get('mountpoints') or []):
            raise ValueError(f'Target is mounted or used as swap: {node["path"]}')
        if node['type'] not in ('disk', 'part'):
            raise ValueError(f'Target has an active storage mapping: {node["path"]}; close it manually')
    return disk


def check_conflicts(ids, devices, vg_names, target, *, resume=False):
    target_paths = {str(Path(node['path']).resolve()) for node in descendants(target)}
    for disk in devices:
        for node in descendants(disk):
            on_target = str(Path(node['path']).resolve()) in target_paths
            existing = (node.get('uuid') or '').lower()
            for key, value in ids.items():
                if key.endswith('_uuid') and existing == value.lower() and not (resume and on_target):
                    raise ValueError(f'{key} conflicts with {node["path"]}; choose generate or disconnect the original')
            if node['type'] == 'crypt' and Path(node['path']).name == ids['crypt_name']:
                raise ValueError('LUKS mapping name is already active')
    if ids['vg_name'] in vg_names:
        # Verify an inactive VG belongs solely to this target on a resume.
        if not resume:
            raise ValueError('VG name already exists; choose generate or disconnect the original')
        pv_paths = run('pvs', '--noheadings', '-o', 'pv_name', '--select', 'vg_name=' + ids['vg_name'], capture=True).split()
        if not pv_paths or any(str(Path(p).resolve()) not in target_paths for p in pv_paths):
            raise ValueError('Existing VG does not belong solely to the resume target')
    if Path('/dev/mapper', ids['crypt_name']).exists():
        raise ValueError('Mapping name is already in use')


def select_run(snapshots, config):
    groups = {}
    for snapshot in snapshots:
        host = snapshot.get('hostname', '')
        if config['backup_host'] and host != config['backup_host']:
            continue
        tags = snapshot.get('tags', [])
        runs = [tag for tag in tags if re.fullmatch(r'run-[0-9]{8}-[0-9]{6}', tag)]
        if len(runs) != 1 or (config['backup_run'] != 'latest' and runs[0] != config['backup_run']):
            continue
        group = groups.setdefault((host, runs[0]), {})
        for kind in ('system-root', 'system-boot', 'recovery-metadata', 'system-home'):
            if kind in tags:
                group.setdefault(kind, []).append(snapshot)
    complete = [(host, tag, group) for (host, tag), group in groups.items()
                if all(len(group.get(kind, [])) == 1 for kind in ('system-root', 'system-boot', 'recovery-metadata'))]
    if not complete:
        raise ValueError('No complete root+boot+metadata run found; independent latest snapshots are never mixed')
    if len({host for host, _, _ in complete}) != 1:
        raise ValueError('Multiple backup hosts found; specify backup_host')
    host, tag, group = max(complete, key=lambda item: datetime.fromisoformat(item[2]['recovery-metadata'][0]['time']))
    return {'host': host, 'run_tag': tag,
            'snapshots': {kind: items[0] for kind, items in group.items() if len(items) == 1}}


def supported_layout(layout, selection):
    root, boot = layout.get('root', {}), layout.get('boot', {})
    if (layout.get('run_tag') != selection['run_tag'] or
            layout.get('profile', {}).get('recovery_profile') != 'lvm-luks-uefi' or
            root.get('backup_path') != '/mnt/root-backup-snapshot' or root.get('snapshot') != 'lvm' or
            root.get('filesystem_type') != 'ext4' or boot.get('filesystem_type') != 'ext4' or
            not boot.get('separate_mount') or not boot.get('efi') or
            layout.get('profile', {}).get('boot_mode') == 'none'):
        raise ValueError('unsupported-backup-layout: only LVM snapshot + LUKS + separate ext4 boot + UEFI is supported')
    if selection['snapshots']['system-root'].get('paths') != [root['backup_path']]:
        raise ValueError('Root snapshot paths do not match metadata')
    if set(selection['snapshots']['system-boot'].get('paths', [])) != {'/boot', '/boot/efi'}:
        raise ValueError('Boot snapshot must contain /boot and /boot/efi')


class Repository:
    def __init__(self, config):
        self.config = config
        self.env = os.environ.copy()
        if config['restic_password_file']:
            self.env.pop('RESTIC_PASSWORD', None)
            self.env.pop('RESTIC_PASSWORD_COMMAND', None)
            self.env['RESTIC_PASSWORD_FILE'] = config['restic_password_file']
        elif not any(self.env.get(k) for k in ('RESTIC_PASSWORD', 'RESTIC_PASSWORD_FILE', 'RESTIC_PASSWORD_COMMAND')):
            self.env['RESTIC_PASSWORD'] = getpass.getpass('Restic password: ')
        self.path = Path(config['backup_dir']) / 'restic'

    def command(self, *args, capture=False):
        return run('restic', '-r', self.path, *args, capture=capture, env=self.env)

    def selection(self):
        return select_run(json.loads(self.command('snapshots', '--json', capture=True)), self.config)

    def ensure_selection(self, selection):
        available = {s['id']: s for s in json.loads(self.command('snapshots', '--json', capture=True))}
        for kind in ('system-root', 'system-boot', 'recovery-metadata'):
            expected = selection['snapshots'][kind]
            actual = available.get(expected['id'])
            if not actual or actual.get('hostname', '') != selection['host'] or selection['run_tag'] not in actual.get('tags', []) or kind not in actual.get('tags', []):
                raise ValueError(f'Selected {kind} snapshot no longer available or inconsistent')

    def metadata(self, selection, directory):
        snapshot = selection['snapshots']['recovery-metadata']
        paths = snapshot.get('paths', [])
        if len(paths) != 1 or not paths[0].startswith('/') or '..' in Path(paths[0]).parts:
            raise ValueError('Unexpected metadata snapshot path')
        self.command('restore', snapshot['id'] + ':' + paths[0], '--target', directory, '--verify')
        metadata = Path(directory)
        layout = json.loads((metadata / 'layout.json').read_text())
        supported_layout(layout, selection)
        profile_file = metadata / 'backup-config.json'
        if profile_file.exists():
            profile_spec = importlib.util.spec_from_file_location('backup_config', Path(__file__).with_name('backup-config.py'))
            profile_helper = importlib.util.module_from_spec(profile_spec)
            profile_spec.loader.exec_module(profile_helper)
            profile, _ = profile_helper.load(str(profile_file))
            if profile['home']['mode'] != layout['home']['mode'] or profile['boot']['mode'] != layout['profile']['boot_mode']:
                raise ValueError('Archived backup config disagrees with layout')
        # LUKS UUID is available in new manifests, with blkid fallback for older runs.
        luks_uuid = layout['luks'].get('uuid')
        if not luks_uuid:
            source = layout['luks']['device']
            for line in (metadata / 'blkid.txt').read_text().splitlines():
                if line.startswith(source + ':'):
                    match = re.search(r'(?<!PART)UUID="([^"]+)"', line)
                    if match:
                        luks_uuid = match[1]
        return layout, CONFIG.original_ids(layout, luks_uuid)


def check_tools():
    tools = ('restic', 'lsblk', 'blkid', 'findmnt', 'vgs', 'pvs', 'lvs', 'cryptsetup', 'sgdisk',
             'wipefs', 'partprobe', 'udevadm', 'pvcreate', 'vgcreate', 'vgchange', 'lvcreate',
             'mkfs.ext4', 'mkfs.fat', 'mount', 'umount', 'chroot', 'blockdev')
    missing = [tool for tool in tools if not shutil.which(tool)]
    if missing:
        raise ValueError('Install required tools first: ' + ', '.join(missing))


def config_hash(config):
    return hashlib.sha256(json.dumps(config, sort_keys=True).encode()).hexdigest()


def fix_system_files(target, ids, originals):
    etc = Path(target) / 'etc'
    if etc.is_symlink():
        raise ValueError('Restored /etc must not be a symlink')
    source = etc / 'fstab'
    if not source.is_file() or source.is_symlink():
        raise ValueError('Restored /etc/fstab is missing or a symlink')
    if not (etc / 'fstab.pre-restore.bak').exists():
        shutil.copy2(source, etc / 'fstab.pre-restore.bak')
    wanted = {'/': ids['root_uuid'], '/boot': ids['boot_uuid'], '/boot/efi': ids['efi_uuid']}
    lines = []
    for line in source.read_text().splitlines():
        fields = line.split()
        if fields and not fields[0].startswith('#') and len(fields) >= 2 and fields[1] in wanted:
            continue
        lines.append(line)
    lines += [f'UUID={wanted[mount]} {mount} {fs} {options} 0 {order}'
              for mount, fs, options, order in [('/', 'ext4', 'defaults', 1), ('/boot', 'ext4', 'defaults', 2),
                                               ('/boot/efi', 'vfat', 'umask=0077', 2)]]
    source.write_text('\n'.join(lines) + '\n')
    crypttab = etc / 'crypttab'
    if crypttab.is_symlink():
        raise ValueError('Restored crypttab is a symlink')
    old = crypttab.read_text() if crypttab.exists() else ''
    if crypttab.exists() and not (etc / 'crypttab.pre-restore.bak').exists():
        shutil.copy2(crypttab, etc / 'crypttab.pre-restore.bak')
    retained = []
    for line in old.splitlines():
        fields = line.split()
        if fields and not fields[0].startswith('#') and (fields[0] in (originals['crypt_name'], ids['crypt_name']) or
                (len(fields) > 1 and fields[1] == 'UUID=' + originals['luks_uuid'])):
            continue
        retained.append(line)
    retained.append(f"{ids['crypt_name']} UUID={ids['luks_uuid']} none luks,initramfs")
    crypttab.write_text('\n'.join(retained) + '\n')
    # Update explicit kernel command line and copied EFI grub config references.
    candidates = [etc / 'default/grub']
    candidates += list((etc / 'default/grub.d').glob('*.cfg'))
    candidates += list((Path(target) / 'boot/efi/EFI').glob('**/*.cfg'))
    for filename in candidates:
        if filename.is_file() and not filename.is_symlink():
            text = filename.read_text()
            for key in ('luks_uuid', 'root_uuid', 'boot_uuid', 'efi_uuid'):
                text = text.replace(originals[key], ids[key])
            old_lv = '/dev/mapper/' + originals['vg_name'].replace('-', '--') + '-' + originals['lv_name'].replace('-', '--')
            new_lv = '/dev/mapper/' + ids['vg_name'].replace('-', '--') + '-' + ids['lv_name'].replace('-', '--')
            text = text.replace(originals['crypt_name'], ids['crypt_name'])
            text = text.replace(originals['vg_name'] + '/' + originals['lv_name'], ids['vg_name'] + '/' + ids['lv_name'])
            text = text.replace(old_lv, new_lv).replace('/dev/' + originals['vg_name'] + '/' + originals['lv_name'],
                                                       '/dev/' + ids['vg_name'] + '/' + ids['lv_name'])
            filename.write_text(text)
    for stale in ('lvm/devices/system.devices', 'lvm/cache/.cache'):
        filename = etc / stale
        if filename.is_file() and not filename.is_symlink():
            filename.rename(filename.with_name(filename.name + '.pre-restore.bak'))
    # Do not let a restored timer run with the old disk/profile settings at boot.
    timer_link = etc / 'systemd/system/timers.target.wants/system-backup.timer'
    if timer_link.is_symlink():
        timer_link.unlink()
    # Explicitly disable stale resume configuration from the source system.
    resume = etc / 'initramfs-tools/conf.d/resume'
    if resume.parent.exists():
        resume.write_text('RESUME=none\n')


BOOT_SCRIPT = r'''set -euo pipefail
command -v unmkinitramfs >/dev/null
# Avoid discovering boot entries for the still-running original disk.
printf 'GRUB_DISABLE_OS_PROBER=true\n' > /etc/default/grub.d/99-system-restore.cfg
shopt -s nullglob
if command -v dracut >/dev/null; then
  # Chroot sees the running host kernel and devices: do not capture its root.
  mkdir -p /etc/dracut.conf.d
  cat > /etc/dracut.conf.d/99-system-restore.conf <<'DRACUT'
hostonly="no"
hostonly_cmdline="no"
add_dracutmodules+=" crypt lvm "
install_items+=" /etc/crypttab "
DRACUT
  kernels=(/boot/vmlinuz-*)
  [[ ${#kernels[@]} -gt 0 ]]
  for kernel in "${kernels[@]}"; do
    version=${kernel##*/vmlinuz-}
    [[ -d /lib/modules/$version ]]
    dracut --force --no-hostonly --no-hostonly-cmdline --add "crypt lvm" \
      --include /etc/crypttab /etc/crypttab "/boot/initrd.img-$version" "$version"
  done
  printf 'GRUB_CMDLINE_LINUX="${GRUB_CMDLINE_LINUX} rd.luks.uuid=%s rd.lvm.lv=%s"\n' \
    "$EXPECTED_LUKS_UUID" "$RESTORE_ROOT_LV" >> /etc/default/grub.d/99-system-restore.cfg
else
  [[ -f /usr/share/initramfs-tools/hooks/cryptroot ]] || {
    echo "Missing cryptsetup-initramfs hook in restored system" >&2; exit 1;
  }
  update-initramfs -u -k all
fi
shopt -s nullglob
initrds=(/boot/initrd.img-*)
[[ ${#initrds[@]} -gt 0 ]]
for initrd in "${initrds[@]}"; do
  directory=$(mktemp -d)
  unmkinitramfs "$initrd" "$directory"
  embedded_ok=0
  while IFS= read -r embedded; do
    if grep -qF "UUID=$EXPECTED_LUKS_UUID" "$embedded"; then embedded_ok=1; break; fi
  done < <(find "$directory" \( -path '*/cryptroot/crypttab' -o -path '*/etc/crypttab' \) -type f -size +0c)
  if [[ $embedded_ok != 1 ]]; then
    rm -rf "$directory"
    echo "Missing target cryptroot entry in $initrd" >&2
    exit 1
  fi
  rm -rf "$directory"
done
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id="$RESTORE_BOOTLOADER_ID" --no-nvram --recheck
grub-install --target=x86_64-efi --efi-directory=/boot/efi --removable --no-nvram --recheck
update-grub
'''


class Executor:
    def __init__(self, config, plan, state_file, state, repository, metadata):
        self.config, self.plan, self.state_file, self.state = config, plan, state_file, state
        self.repo, self.metadata = repository, Path(metadata)
        self.ids, self.disk = plan['identifiers'], plan['target']['path']
        suffix = 'p' if self.disk[-1].isdigit() else ''
        self.esp, self.boot, self.luks = (self.disk + suffix + str(i) for i in (1, 2, 3))
        self.mapping = '/dev/mapper/' + self.ids['crypt_name']
        self.lv = '/dev/' + self.ids['vg_name'] + '/' + self.ids['lv_name']
        self.mount = Path(config['mount_dir'])
        self.mounts = []
        self.opened = False

    def step(self, name, action, verify=None):
        if name in self.state['completed']:
            if verify and not verify():
                raise ValueError(f'Saved step {name} disagrees with target; refusing to repeat a destructive operation')
            print('Already completed:', name, flush=True)
            return
        print('Restore step:', name, flush=True)
        action()
        if verify and not verify():
            raise ValueError(f'Verification failed after {name}')
        self.state['completed'].append(name)
        atomic_json(self.state_file, self.state)

    def uuid_of(self, device):
        return run('blkid', '-c', '/dev/null', '-s', 'UUID', '-o', 'value', device, capture=True)

    def attach(self, source, target, *, bind=False):
        target = Path(target)
        if target.is_symlink() or str(target.resolve()) != str(target):
            raise ValueError(f'Mount path contains a symlink: {target}')
        target.mkdir(parents=True, exist_ok=True)
        mount_status = subprocess.run(['findmnt', '-rn', '--mountpoint', str(target)], stdout=subprocess.DEVNULL, check=False).returncode
        if mount_status == 0:
            raise ValueError(f'Mount directory already in use: {target}')
        if mount_status != 1:
            raise ValueError(f'Cannot inspect mount directory: {target}')
        run('mount', *(['--bind'] if bind else []), source, target)
        self.mounts.append(target)

    def execute(self):
        self.step('partition', self.partition, self.verify_partitions)
        self.step('luks', self.create_luks, lambda: self.uuid_of(self.luks).lower() == self.ids['luks_uuid'].lower())
        run('cryptsetup', 'open', self.luks, self.ids['crypt_name'])
        self.opened = True
        run('udevadm', 'settle')
        if 'lvm' in self.state['completed']:
            pv_paths = run('pvs', '--noheadings', '-o', 'pv_name', '--select', 'vg_name=' + self.ids['vg_name'], capture=True).split()
            if len(pv_paths) != 1 or Path(pv_paths[0]).resolve() != Path(self.mapping).resolve():
                raise ValueError('Saved VG does not belong to the target mapper')
            run('vgchange', '-ay', self.ids['vg_name'])
        self.step('lvm', self.create_lvm, self.verify_lvm)
        if 'format' not in self.state['completed']:
            for device, expected, filesystem in [(self.esp, self.ids['efi_uuid'], 'vfat'),
                                                  (self.boot, self.ids['boot_uuid'], 'ext4'),
                                                  (self.lv, self.ids['root_uuid'], 'ext4')]:
                print('Formatting', device, 'as', filesystem, flush=True)
                if filesystem == 'vfat':
                    run('mkfs.fat', '-F', '32', '-i', expected.replace('-', ''), device)
                else:
                    run('mkfs.ext4', '-F', '-U', expected, device)
            self.step('format', lambda: None, self.verify_filesystems)
        else:
            self.step('format', lambda: None, self.verify_filesystems)
        if int(run('blockdev', '--getsize64', self.lv, capture=True)) < self.plan['root_bytes'] * 1.15:
            raise ValueError('Root LV too small for restored data plus filesystem overhead')
        self.attach(self.lv, self.mount)
        snapshots = self.plan['selection']['snapshots']
        # Subfolder restore writes DIRECTLY into target root, without host bind mounts.
        self.step('root_files', lambda: self.repo.command('restore', snapshots['system-root']['id'] + ':/mnt/root-backup-snapshot',
                                                        '--target', self.mount, '--sparse', '--verify'),
                  lambda: (self.mount / 'etc/fstab').is_file())
        self.attach(self.boot, self.mount / 'boot')
        self.attach(self.esp, self.mount / 'boot/efi')
        self.step('boot_files', lambda: self.repo.command('restore', snapshots['system-boot']['id'] + ':/boot',
                                                        '--target', self.mount / 'boot', '--sparse', '--verify'),
                  lambda: (self.mount / 'boot/grub').is_dir() and (self.mount / 'boot/efi/EFI').is_dir())
        self.step('system_files', lambda: fix_system_files(self.mount, self.ids, self.plan['originals']))
        if 'bootloader' not in self.state['completed']:
            for path in ('dev', 'dev/pts', 'proc', 'sys'):
                self.attach('/' + path, self.mount / path, bind=True)
            # Private /run prevents restored services from reaching host systemd sockets.
            (self.mount / 'run').mkdir(parents=True, exist_ok=True)
            run('mount', '-t', 'tmpfs', '-o', 'nosuid,nodev', 'tmpfs', self.mount / 'run')
            self.mounts.append(self.mount / 'run')
            def bootloader():
                environment = os.environ.copy()
                environment.update(EXPECTED_LUKS_UUID=self.ids['luks_uuid'], RESTORE_BOOTLOADER_ID=self.config['bootloader_id'],
                                   RESTORE_ROOT_LV=self.ids['vg_name'] + '/' + self.ids['lv_name'])
                subprocess.run(['chroot', str(self.mount), '/bin/bash', '-c', BOOT_SCRIPT], check=True, env=environment)
            (self.mount / 'etc/default/grub.d').mkdir(parents=True, exist_ok=True)
            self.step('bootloader', bootloader)
        run('sync')

    def partition(self):
        run('wipefs', '-a', self.disk)
        run('sgdisk', '--zap-all', self.disk)
        run('sgdisk', '--new=1:0:+1G', '--typecode=1:ef00', '--new=2:0:+2G', '--typecode=2:8300',
            '--new=3:0:0', '--typecode=3:8309', self.disk)
        run('partprobe', self.disk)
        run('udevadm', 'settle')

    def verify_partitions(self):
        tree = json.loads(run('lsblk', '--tree', '--json', '--bytes', '--paths', '-o', 'PATH,TYPE,SIZE,PTTYPE', self.disk, capture=True))['blockdevices']
        if len(tree) != 1 or tree[0].get('pttype') != 'gpt':
            return False
        parts = {node['path']: node for node in tree[0].get('children', []) if node['type'] == 'part'}
        return set(parts) == {self.esp, self.boot, self.luks} and int(parts[self.esp]['size']) == GIB and int(parts[self.boot]['size']) == 2 * GIB

    def create_luks(self):
        if self.config['luks_header'] == 'new':
            print('Enter a NEW LUKS passphrase; this is separate from the Restic password.', flush=True)
            run('cryptsetup', 'luksFormat', '--type', 'luks2', '--uuid', self.ids['luks_uuid'], self.luks)
        else:
            header = self.metadata / self.plan['header_file']
            run('cryptsetup', 'luksHeaderRestore', self.luks, '--header-backup-file', header)
            run('cryptsetup', 'luksUUID', self.luks, '--uuid', self.ids['luks_uuid'])

    def create_lvm(self):
        # A partially created VG is recoverable only when it is solely on our mapper.
        probe = subprocess.run(['pvs', '--noheadings', '-o', 'vg_name', self.mapping], text=True, capture_output=True)
        group = probe.stdout.strip() if probe.returncode == 0 else ''
        if group and group != self.ids['vg_name']:
            raise ValueError('Target PV belongs to an unexpected VG')
        if not group:
            if probe.returncode != 0:
                run('pvcreate', self.mapping)
            run('vgcreate', self.ids['vg_name'], self.mapping)
        if not Path(self.lv).exists():
            run('lvcreate', '-l', str(self.config['root_lv_percent']) + '%FREE', '-n', self.ids['lv_name'], self.ids['vg_name'])

    def verify_lvm(self):
        paths = run('pvs', '--noheadings', '-o', 'pv_name', '--select', 'vg_name=' + self.ids['vg_name'], capture=True).split()
        return len(paths) == 1 and Path(paths[0]).resolve() == Path(self.mapping).resolve() and Path(self.lv).exists()

    def verify_filesystems(self):
        return all(self.uuid_of(device).lower() == self.ids[key].lower() and
                   run('blkid', '-c', '/dev/null', '-s', 'TYPE', '-o', 'value', device, capture=True) == filesystem
                   for device, key, filesystem in [(self.esp, 'efi_uuid', 'vfat'), (self.boot, 'boot_uuid', 'ext4'), (self.lv, 'root_uuid', 'ext4')])

    def cleanup(self):
        clean = True
        for mount in reversed(self.mounts):
            try:
                run('umount', mount)
            except subprocess.CalledProcessError:
                clean = False
                print('Could not unmount:', mount, file=sys.stderr)
        if self.opened and clean:
            try:
                owned_pvs = run('pvs', '--noheadings', '-o', 'pv_name', '--select', 'vg_name=' + self.ids['vg_name'], capture=True).split()
                if owned_pvs:
                    if len(owned_pvs) != 1 or Path(owned_pvs[0]).resolve() != Path(self.mapping).resolve():
                        raise ValueError('Refusing cleanup of a VG not owned by this restore')
                    run('vgchange', '-an', self.ids['vg_name'])
                run('cryptsetup', 'close', self.ids['crypt_name'])
            except (ValueError, subprocess.CalledProcessError) as exc:
                clean = False
                print('Mapping cleanup failed:', exc, file=sys.stderr)
        return clean


def wizard(args):
    config = copy.deepcopy(CONFIG.DEFAULT)
    config['backup_dir'] = args.backup_dir or input('Backup storage directory [/backup/system/system-backups]: ').strip() or config['backup_dir']
    devices, _ = inventory()
    candidates = [node for node in devices if node['type'] == 'disk' and node.get('serial') and
                  all(not any(child.get('mountpoints') or []) and child['type'] in ('disk', 'part') for child in descendants(node))]
    if not candidates:
        raise ValueError('No unmounted whole disks with a serial found. Connect the restore disk first.')
    for index, node in enumerate(candidates, 1):
        print(index, node['path'], node.get('model'), node['serial'], round(int(node['size']) / GIB, 1), 'GiB')
    choice = int(input('Target disk number: '))
    if not 1 <= choice <= len(candidates):
        raise ValueError('Invalid disk number')
    selected = candidates[choice - 1]
    config['target'] = dict(device=selected['path'], serial=selected['serial'].strip())
    mode = input('Identifiers: original / generate / custom [original]: ').strip() or 'original'
    if mode not in ('original', 'generate', 'custom'):
        raise ValueError('Invalid identifier mode')
    for key in config['identifiers']:
        config['identifiers'][key] = (input(f'{key} [original]: ').strip() or 'original') if mode == 'custom' else mode
    config['luks_header'] = input('LUKS header: new / restore [new]: ').strip() or 'new'
    config['backup_host'] = input('Backup host (empty for a single host): ').strip()
    config['backup_run'] = input('Backup run tag [latest]: ').strip() or 'latest'
    config['restic_password_file'] = input('Restic password file (empty for prompt): ').strip()
    CONFIG.validate(config)
    filename = Path(args.config or Path(__file__).resolve().parent.parent / 'configs/user/restore-config.json')
    if filename.exists() or filename.is_symlink():
        raise ValueError(f'{filename} already exists; choose --config with a different filename')
    filename.parent.mkdir(parents=True, exist_ok=True)
    atomic_json(filename, config)
    print('Config saved:', filename, '\nNo disk changes. Next: restore-system.sh --config FILE --dry-run')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config')
    parser.add_argument('--interactive', action='store_true', help='create restore config with prompts; do not restore')
    parser.add_argument('--backup-dir', help='backup storage for interactive config creation')
    parser.add_argument('--dry-run', action='store_true', help='fetch selected metadata and check plan without target changes')
    parser.add_argument('--resume', action='store_true', help='continue only the plan saved in the state journal')
    parser.add_argument('--status', action='store_true', help='show saved restore plan and completed steps')
    args = parser.parse_args()
    if args.interactive:
        wizard(args)
        return
    if not args.config or args.backup_dir:
        parser.error('Use --config FILE; --backup-dir is only for the interactive wizard')
    config = CONFIG.load(args.config)
    state_file = Path(config['backup_dir']) / '.restore-state.json'
    if args.status:
        print(state_file.read_text() if state_file.exists() else 'No saved restore state')
        return
    if os.geteuid() != 0:
        raise ValueError('Run with sudo (device inventory and LVM checks need root)')
    check_tools()
    if os.uname().machine != 'x86_64':
        raise ValueError('This restore currently supports x86_64 UEFI only')
    for variable in Path('/sys/firmware/efi/efivars').glob('SecureBoot-*'):
        data = variable.read_bytes()
        if len(data) >= 5 and data[4] == 1:
            raise ValueError('Secure Boot is enabled; this GRUB restore path requires it disabled for testing')
    if not (Path(config['backup_dir']) / 'restic/config').is_file():
        raise ValueError('Restic repository unavailable')
    # Never let a local backup/prune run race restore snapshot selection or root mount work.
    with (Path(config['backup_dir']) / '.backup.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError('A backup or another restore is running; try later')
        repository = Repository(config)
        old_state = json.loads(state_file.read_text()) if state_file.exists() else None
        if args.resume:
            if not old_state or old_state['config_hash'] != config_hash(config):
                raise ValueError('Resume requires the unchanged config and its saved state')
            selection = old_state['plan']['selection']
        else:
            if old_state and not args.dry_run:
                raise ValueError('Restore state already exists. Use --resume or archive it manually before a new restore')
            selection = repository.selection()
        repository.ensure_selection(selection)
        with tempfile.TemporaryDirectory(prefix='system-restore-metadata-') as temporary:
            layout, originals = repository.metadata(selection, temporary)
            ids = old_state['plan']['identifiers'] if args.resume else CONFIG.resolve_ids(config, originals)
            devices, names = inventory()
            target = check_target(config, devices, resume=args.resume)
            check_conflicts(ids, devices, names, target, resume=args.resume)
            if ids['vg_name'] == originals['vg_name']:
                target_paths = {str(Path(n['path']).resolve()) for n in descendants(target)}
                if any((n.get('uuid') or '').lower() == originals['luks_uuid'].lower()
                       and str(Path(n['path']).resolve()) not in target_paths
                       for d in devices for n in descendants(d)):
                    raise ValueError('Original encrypted disk is connected; its hidden VG could conflict. Generate vg_name or disconnect it.')
            # Reject inactive LVM members too, except when resuming our saved target.
            if not args.resume and any(node.get('fstype') == 'LVM2_member' for node in descendants(target)):
                raise ValueError('Target contains an LVM PV; inspect and remove it manually before restoring')
            mount_dir = Path(config['mount_dir'])
            if str(mount_dir.resolve()) != str(mount_dir) or mount_dir.is_symlink() or (mount_dir.exists() and any(mount_dir.iterdir())):
                raise ValueError('mount_dir must be an empty directory and not a symlink')
            source_os = repository.command('dump', selection['snapshots']['system-root']['id'], '/mnt/root-backup-snapshot/usr/lib/os-release', capture=True)
            if not re.search(r'^ID="?ubuntu"?$', source_os, re.MULTILINE):
                raise ValueError('This restore currently supports an Ubuntu source system only')
            repository.command('check')
            root_bytes = (old_state['plan']['root_bytes'] if args.resume else
                          json.loads(repository.command('stats', selection['snapshots']['system-root']['id'],
                                                        '--mode', 'restore-size', '--json', capture=True))['total_size'])
            available_root = (int(target['size']) - 3 * GIB - 64 * 1024 ** 2) * config['root_lv_percent'] / 100
            if available_root < root_bytes * 1.15 + GIB:
                raise ValueError('Target disk too small for data, boot partitions, filesystem overhead and VG reserve')
            header_file = layout['luks'].get('header_file', 'luks-header.img')
            if config['luks_header'] == 'restore':
                if header_file != Path(header_file).name or not (Path(temporary) / header_file).is_file():
                    raise ValueError('Selected metadata has no usable LUKS header backup')
                header_uuid = run('cryptsetup', 'luksUUID', Path(temporary) / header_file, capture=True)
                if header_uuid.lower() != originals['luks_uuid'].lower():
                    raise ValueError('LUKS header UUID disagrees with selected metadata')
            identity = {key: target.get(key) for key in ('path', 'serial', 'wwn', 'size', 'model')}
            plan = dict(selection=selection, target=identity, identifiers=ids, root_bytes=root_bytes,
                        header_file=header_file, originals=originals, home=layout.get('home', {}))
            if args.resume and plan != old_state['plan']:
                raise ValueError('Resume disk identity or selected backup changed')
            print(json.dumps(plan, indent=2, ensure_ascii=False), flush=True)
            print('LUKS header mode:', config['luks_header'])
            print('Bootloader: target ESP + fallback loader; host firmware entries unchanged.')
            print('Separate /home is NOT restored by this system restore; reconnect or restore it separately.')
            if args.dry_run:
                print('Dry-run completed. No target disk changes or restore state written.')
                return
            phrase = 'ERASE ' + target['serial'].strip()
            if input(f'All data on {target["path"]} will be lost. Type "{phrase}" to continue: ') != phrase:
                raise ValueError('Restore cancelled before disk changes')
            # Recheck current hardware and collisions immediately before first mutation.
            fresh_devices, fresh_names = inventory()
            fresh_target = check_target(config, fresh_devices, resume=args.resume)
            if any(fresh_target.get(key) != identity[key] for key in identity):
                raise ValueError('Target disk identity changed after confirmation')
            check_conflicts(ids, fresh_devices, fresh_names, fresh_target, resume=args.resume)
            state = old_state if args.resume else dict(config_hash=config_hash(config), plan=plan, completed=[])
            atomic_json(state_file, state)
            executor = Executor(config, plan, state_file, state, repository, temporary)
            try:
                executor.execute()
            finally:
                clean = executor.cleanup()
            if not clean:
                raise ValueError('Restore finished but resource cleanup failed; inspect mounts/LVM before reboot')
            state['finished'] = True
            atomic_json(state_file, state)
            print('Restore completed. Boot the target disk to validate recovery. Backup timer on the restored OS is disabled.')


if __name__ == '__main__':
    def interrupted(signum, frame):
        raise KeyboardInterrupt('Termination requested; cleaning up owned restore resources')
    signal.signal(signal.SIGTERM, interrupted)
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError, subprocess.CalledProcessError, EOFError, KeyboardInterrupt) as exc:
        print(f'Restore stopped: {exc}', file=sys.stderr)
        sys.exit(1)
