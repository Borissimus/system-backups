#!/usr/bin/env python3
"""Create a pair of validated configs without installing or starting services."""
from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path
import subprocess


def helper(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--profile', choices=['auto', 'lvm-luks-uefi', 'lvm-plain', 'partition-luks', 'partition-plain'], required=True)
    parser.add_argument('--home', choices=['auto', 'restic', 'external', 'exclude'], help='restic: include separate /home in the same repository; exclude: skip it; auto: include only when part of root')
    parser.add_argument('--backup-mount', required=True, help='existing mount of the backup disk')
    parser.add_argument('--backup-dir', required=True, help='absolute storage directory inside the mount')
    parser.add_argument('--output-dir', default=str(Path(__file__).resolve().parent.parent / 'configs'),
                        help='directory for user configs (default: project configs/)')
    parser.add_argument('--schedule', default='20:00')
    parser.add_argument('--notice-user', default='')
    args = parser.parse_args()
    backup_helper = helper('backup-config')
    service_helper = helper('service-config')
    try:
        mount = args.backup_mount
        source = subprocess.check_output(['findmnt', '-n', '-o', 'SOURCE', '--mountpoint', mount], text=True).strip()
        uuid = subprocess.check_output(['lsblk', '-dn', '-o', 'UUID', source], text=True).strip()
        if not uuid:
            raise ValueError('cannot determine the backup filesystem UUID')
        output = Path(args.output_dir).absolute()
        code_dir = Path(__file__).resolve().parent.parent
        backup = json.loads(json.dumps(backup_helper.DEFAULT))
        home_mount = subprocess.check_output(['findmnt', '-n', '-o', 'TARGET', '--target', '/home'], text=True).strip()
        if home_mount == '/home' and args.home is None:
            raise ValueError('/home is a separate mount; choose --home restic to include it or --home exclude to skip it')
        backup['home']['mode'] = args.home or 'auto'
        if home_mount != '/home' and backup['home']['mode'] != 'auto':
            raise ValueError('/home is part of root and is already included; choose --home auto')
        if args.profile != 'auto':
            backup['root']['snapshot_mode'] = 'lvm' if args.profile.startswith('lvm-') else 'live'
            backup['encryption']['mode'] = 'required' if 'luks' in args.profile else 'none'
            backup['boot']['mode'] = 'required' if args.profile.endswith('uefi') else 'auto'
        service = {
            'schema_version': 1,
            'code_dir': str(code_dir),
            'backup_dir': args.backup_dir,
            'backup_mount': mount,
            'backup_disk_uuid': uuid,
            'backup_profile': str(output / 'backup-config.json'),
            'schedule': args.schedule,
            'retention': {'daily': 7, 'weekly': 4, 'monthly': 6},
            'min_repository_free_gib': 20,
            'restic_password_file': '/etc/system-backup/restic.pass',
            'success_callback': '/usr/local/lib/system-backup/after-success',
            'notice_user': args.notice_user,
        }
        backup_helper.validate(backup)
        service_helper.validate(service)
        files = [output / 'backup-config.json', output / 'service-config.json']
        if any(p.exists() or p.is_symlink() for p in files):
            raise ValueError('config files already exist; choose another output directory')
        output.mkdir(parents=True, exist_ok=True)
        for file, config in zip(files, [backup, service]):
            with file.open('x', encoding='utf-8') as stream:
                json.dump(config, stream, indent=2, ensure_ascii=False)
                stream.write('\n')
            print(file)
        print('Configs created. No repository, system settings, or services were changed.')
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        parser.exit(2, f'configuration error: {exc}\n')


if __name__ == '__main__':
    main()
