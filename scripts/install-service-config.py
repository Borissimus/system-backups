#!/usr/bin/env python3
"""Install validated service settings and a private, independent backup profile."""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import tempfile


def helper(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def atomic_json(filename, data):
    filename = Path(filename)
    filename.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix='.' + filename.name + '.', dir=filename.parent)
    try:
        with os.fdopen(descriptor, 'w', encoding='utf-8') as stream:
            json.dump(data, stream, indent=2)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, filename)
    finally:
        if Path(temporary).exists():
            Path(temporary).unlink()


def install_config(source, destination, runtime_dir):
    service_helper, backup_helper = helper('service-config'), helper('backup-config')
    config = service_helper.load(str(source))
    # Read everything before writing: source may already be the installed copy.
    profile_source = config.get('backup_profile') or None
    if profile_source and not Path(profile_source).exists():
        code_dir = Path(config.get('code_dir', config['backup_dir']))
        legacy_paths = {code_dir / 'backup-config.json', code_dir / 'configs/backup-config.json',
                        code_dir / 'configs/backup-config.jsonc'}
        relocated = code_dir / 'configs/user' / Path(profile_source).name
        # Only recover known paths moved by the configs/user migration.
        # Never guess a profile or silently use defaults for a missing file.
        if Path(profile_source) in legacy_paths and relocated.is_file():
            profile_source = str(relocated)
            print('Migrating relocated backup profile:', profile_source)
    profile, _ = backup_helper.load(profile_source)
    destination = Path(destination)
    installed_profile = destination.parent / 'backup.json'
    config['backup_profile'] = str(installed_profile)
    config['code_dir'] = str(runtime_dir)
    service_helper.validate(config)
    atomic_json(installed_profile, profile)
    atomic_json(destination, config)
    return config


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True)
    parser.add_argument('--destination', default='/etc/system-backup/service.json')
    parser.add_argument('--runtime-dir', default='/usr/local/lib/system-backup')
    args = parser.parse_args()
    try:
        install_config(args.source, args.destination, args.runtime_dir)
        print('Installed service configuration:', args.destination)
        print('Installed backup profile:', Path(args.destination).parent / 'backup.json')
    except (OSError, ValueError) as exc:
        parser.exit(2, f'service configuration installation error: {exc}\n')


if __name__ == '__main__':
    main()
