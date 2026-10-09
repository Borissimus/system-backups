#!/usr/bin/env python3
"""Validated restore settings and identifier resolution; no disk operations."""
from __future__ import annotations
import argparse
import copy
import json
from pathlib import Path
import re
import uuid

DEFAULT = {
    'schema_version': 1,
    'backup_dir': '/backup/system/system-backups',
    'backup_run': 'latest',
    'backup_host': '',
    'restic_password_file': '',
    'target': {'device': '', 'serial': ''},
    'identifiers': dict(luks_uuid='original', root_uuid='original', boot_uuid='original',
                        efi_uuid='original', vg_name='original', lv_name='original', crypt_name='original'),
    'luks_header': 'new',
    'root_lv_percent': 90,
    'bootloader_id': 'system-restored',
    'mount_dir': '/mnt/system-restore',
}
NAME = re.compile(r'^[A-Za-z][A-Za-z0-9_-]{0,63}$')


def load(filename):
    lines = Path(filename).read_text().splitlines()
    raw = json.loads('\n'.join('' if line.lstrip().startswith('//') else line for line in lines))
    if not isinstance(raw, dict) or set(raw) - set(DEFAULT):
        raise ValueError('Unknown restore config fields or non-object config')
    config = copy.deepcopy(DEFAULT)
    for key, value in raw.items():
        if key in ('target', 'identifiers'):
            if not isinstance(value, dict) or set(value) - set(DEFAULT[key]):
                raise ValueError(f'Unknown fields in {key}')
            config[key].update(value)
        else:
            config[key] = value
    validate(config)
    return config


def validate(config):
    if type(config['schema_version']) is not int or config['schema_version'] != 1:
        raise ValueError('Only schema_version 1 is supported')
    for key in ('backup_dir', 'mount_dir'):
        value = config[key]
        if not isinstance(value, str) or not value.startswith('/') or value == '/' or str(Path(value)) != value or '..' in Path(value).parts or any(ord(c) < 32 for c in value):
            raise ValueError(f'{key} must be an absolute normalized path other than /')
    backup, mount = Path(config['backup_dir']), Path(config['mount_dir'])
    if backup == mount or backup in mount.parents or mount in backup.parents:
        raise ValueError('backup_dir and mount_dir must be separate')
    for key in ('device', 'serial'):
        value = config['target'][key]
        if not isinstance(value, str) or any(ord(c) < 32 for c in value):
            raise ValueError(f'Invalid target {key}')
    if config['target']['device'] and not config['target']['device'].startswith('/dev/'):
        raise ValueError('Target device must be under /dev/')
    for key in ('backup_run', 'backup_host', 'restic_password_file', 'luks_header', 'bootloader_id'):
        if not isinstance(config[key], str) or any(ord(c) < 32 for c in config[key]):
            raise ValueError(f'Invalid {key}')
    if config['backup_run'] != 'latest' and not re.fullmatch(r'run-[0-9]{8}-[0-9]{6}', config['backup_run']):
        raise ValueError('backup_run must be latest or run-YYYYMMDD-HHMMSS')
    if config['restic_password_file'] and not config['restic_password_file'].startswith('/'):
        raise ValueError('restic_password_file must be absolute')
    if config['luks_header'] not in ('new', 'restore'):
        raise ValueError('luks_header must be new or restore')
    if type(config['root_lv_percent']) is not int or not 50 <= config['root_lv_percent'] <= 95:
        raise ValueError('root_lv_percent must be 50..95')
    if not NAME.fullmatch(config['bootloader_id']):
        raise ValueError('Invalid bootloader_id')
    for key, value in config['identifiers'].items():
        if not isinstance(value, str):
            raise ValueError(f'Invalid identifier {key}')
        if value in ('original', 'generate'):
            continue
        check_identifier(key, value)


def check_identifier(key, value):
    if key == 'efi_uuid':
        if not re.fullmatch(r'[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}', value):
            raise ValueError('efi_uuid must be XXXX-XXXX')
    elif key.endswith('_uuid'):
        if str(uuid.UUID(value)) != value.lower():
            raise ValueError(f'Invalid UUID: {key}')
    elif not NAME.fullmatch(value) or value in ('snapshot', 'pvmove'):
        raise ValueError(f'Invalid LVM/mapping name: {key}')


def original_ids(layout, luks_uuid):
    result = dict(luks_uuid=luks_uuid, root_uuid=layout['root']['filesystem_uuid'],
                boot_uuid=layout['boot']['filesystem_uuid'], efi_uuid=layout['boot']['esp_uuid'],
                vg_name=layout['root']['vg_name'], lv_name=layout['root']['lv_name'],
                crypt_name=layout['luks']['mapping'])
    for key, value in result.items():
        if not value:
            raise ValueError(f'Original {key} missing from backup metadata')
        check_identifier(key, value)
    return result


def resolve_ids(config, originals):
    result = {}
    suffix = uuid.uuid4().hex[:10]
    for key, selection in config['identifiers'].items():
        if selection == 'original':
            value = originals.get(key)
        elif selection == 'generate':
            if key == 'efi_uuid':
                number = uuid.uuid4().hex[:8].upper()
                value = number[:4] + '-' + number[4:]
            elif key.endswith('_uuid'):
                value = str(uuid.uuid4())
            else:
                value = {'vg_name': 'restore-vg-', 'lv_name': 'root-', 'crypt_name': 'restore-crypt-'}[key] + suffix
        else:
            value = selection
        if not value:
            raise ValueError(f'Original {key} missing from selected backup')
        check_identifier(key, value)
        result[key] = value.upper() if key == 'efi_uuid' else value
    values = [result[k].lower() for k in result if k.endswith('_uuid')]
    if len(set(values)) != len(values):
        raise ValueError('Target UUIDs must be distinct')
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['validate'])
    parser.add_argument('--config', required=True)
    args = parser.parse_args()
    try:
        load(args.config)
        print('OK: restore config')
    except (ValueError, OSError, KeyError, TypeError) as exc:
        parser.exit(2, f'restore config error: {exc}\n')
