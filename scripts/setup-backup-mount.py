#!/usr/bin/env python3
"""Add a backup mount to fstab, preserving existing entries and conflicts."""
from __future__ import annotations

import argparse
import importlib.util
import os
from pathlib import Path
import re
import shutil


def prepare_fstab(filename: Path, mount: str, uuid: str, filesystem: str) -> bool:
    """Return True when an entry was added or made optional; never replace a conflicting one."""
    if filesystem not in {'ext4', 'xfs', 'btrfs'}:
        raise ValueError(f'unsupported backup filesystem: {filesystem}')
    text = filename.read_text()
    device = Path('/dev/disk/by-uuid') / uuid

    def decode(value):
        return re.sub(r'\\([0-7]{3})', lambda match: chr(int(match[1], 8)), value)

    def encode(value):
        return value.replace('\\', r'\134').replace(' ', r'\040')

    lines = text.splitlines(keepends=True)
    for index, line in enumerate(lines):
        fields = line.split()
        if not fields or fields[0].startswith('#') or len(fields) < 3:
            continue
        source, target, existing_fs = map(decode, fields[:3])
        if target != mount:
            continue
        same_device = source == f'UUID={uuid}' or (
            source.startswith('/') and Path(source).resolve() == device.resolve()
        )
        if not same_device or existing_fs != filesystem:
            raise ValueError(f'conflicting fstab entry for {mount}; review it manually')
        if len(fields) < 4:
            raise ValueError(f'missing mount options for {mount}')
        options = fields[3].split(',')
        updated = [option for option in options if option not in {'fail', 'nofail'}
                   and not option.startswith(('x-systemd.device-timeout=', 'x-systemd.mount-timeout='))]
        updated += ['nofail', 'x-systemd.device-timeout=10s', 'x-systemd.mount-timeout=30s']
        if set(options) == set(updated):
            return False
        fields[3] = ','.join(updated)
        lines[index] = ' '.join(fields) + '\n'
        backup = filename.with_name(filename.name + '.before-system-backup')
        if not backup.exists():
            shutil.copy2(filename, backup)
        with filename.open('w') as stream:
            stream.write(''.join(lines))
            stream.flush()
            os.fsync(stream.fileno())
        return True
    backup = filename.with_name(filename.name + '.before-system-backup')
    if not backup.exists():
        shutil.copy2(filename, backup)
    options = 'defaults,nosuid,nodev,nofail,x-systemd.device-timeout=10s,x-systemd.mount-timeout=30s'
    pass_number = 2 if filesystem == 'ext4' else 0
    entry = f'UUID={uuid} {encode(mount)} {filesystem} {options} 0 {pass_number}\n'
    with filename.open('a') as stream:
        if text and not text.endswith('\n'):
            stream.write('\n')
        stream.write(entry)
        stream.flush()
        os.fsync(stream.fileno())
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', required=True)
    parser.add_argument('--filesystem', required=True)
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location('service_config', Path(__file__).with_name('service-config.py'))
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    try:
        config = helper.load(args.config)
        changed = prepare_fstab(Path('/etc/fstab'), config['backup_mount'], config['backup_disk_uuid'], args.filesystem)
        print('Added or updated optional backup mount in /etc/fstab.' if changed else 'Existing fstab entry matches; preserved.')
    except (OSError, ValueError) as exc:
        parser.exit(2, f'mount setup error: {exc}\n')


if __name__ == '__main__':
    main()
