import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / f'{name}.py')
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


BACKUP = module('backup-config')
SERVICE = module('service-config')
GENERATOR = module('configure-system-backup')


class ConfigurationTests(unittest.TestCase):
    def service(self):
        config = SERVICE.load(str(ROOT / 'configs/service-config.example.jsonc'))
        config['code_dir'] = str(ROOT)
        return config

    def test_commented_examples_and_literal_slashes(self):
        profile, _ = BACKUP.load(str(ROOT / 'configs/backup-config.example.jsonc'))
        self.assertEqual(profile['root']['snapshot_mode'], 'auto')
        with tempfile.TemporaryDirectory() as directory:
            filename = Path(directory) / 'profile.jsonc'
            filename.write_text('// explanation\n{ "home": { "path": "/home//literal" } }\n')
            profile, _ = BACKUP.load(str(filename))
            self.assertEqual(profile['home']['path'], '/home//literal')

    def test_invalid_backup_values_raise_config_error(self):
        for section, key, value in [('root', 'snapshot_mode', []), ('home', 'mode', {}),
                                    ('home', 'path', '/home\nother'), ('home', 'path', '/'),
                                    ('home', 'path', '/home/../etc')]:
            with self.subTest(value=value):
                config = copy.deepcopy(BACKUP.DEFAULT)
                config[section][key] = value
                with self.assertRaises(BACKUP.ConfigError):
                    BACKUP.validate(config)

    def test_service_rejects_unsafe_paths_and_empty_retention(self):
        for key, value in [('backup_dir', '/media/USER/backup_disk/../root'),
                           ('backup_mount', '/media/USER/backup_disk\n[Service]'),
                           ('retention', dict(daily=0, weekly=0, monthly=0)),
                           ('schema_version', True)]:
            with self.subTest(key=key):
                config = self.service()
                config[key] = value
                with self.assertRaises(SERVICE.ConfigError):
                    SERVICE.validate(config)

    def test_legacy_service_uses_backup_directory_for_code(self):
        config = self.service()
        del config['code_dir']
        stream = io.StringIO()
        with contextlib.redirect_stdout(stream):
            SERVICE.export(config)
        self.assertIn(f"CODE_DIR\t{config['backup_dir']}\n", stream.getvalue())

    def test_generator_profiles_home_choices_and_no_overwrite(self):
        for profile in ['auto', 'lvm-luks-uefi', 'lvm-plain', 'partition-luks', 'partition-plain']:
            for home in ['restic', 'exclude']:
                with self.subTest(profile=profile, home=home), tempfile.TemporaryDirectory() as directory:
                    args = ['configure', '--profile', profile, '--home', home,
                            '--backup-mount', '/backup', '--backup-dir', '/backup/system',
                            '--output-dir', directory]
                    with patch('sys.argv', args), patch.object(GENERATOR.subprocess, 'check_output',
                            side_effect=['/dev/sdb1\n', 'test-uuid\n', '/home\n']), contextlib.redirect_stdout(io.StringIO()):
                        GENERATOR.main()
                    backup, _ = BACKUP.load(str(Path(directory) / 'backup-config.json'))
                    service = SERVICE.load(str(Path(directory) / 'service-config.json'))
                    self.assertEqual(backup['home']['mode'], home)
                    self.assertEqual(service['code_dir'], str(ROOT))
                    self.assertEqual(service['backup_dir'], '/backup/system')
                    before = (Path(directory) / 'backup-config.json').read_bytes()
                    with patch('sys.argv', args), patch.object(GENERATOR.subprocess, 'check_output',
                            side_effect=['/dev/sdb1\n', 'test-uuid\n', '/home\n']), contextlib.redirect_stderr(io.StringIO()):
                        with self.assertRaises(SystemExit):
                            GENERATOR.main()
                    self.assertEqual((Path(directory) / 'backup-config.json').read_bytes(), before)

    def test_generator_requires_choice_for_separate_home(self):
        with tempfile.TemporaryDirectory() as directory:
            args = ['configure', '--profile', 'lvm-luks-uefi', '--backup-mount', '/backup',
                    '--backup-dir', '/backup/system', '--output-dir', directory]
            with patch('sys.argv', args), patch.object(GENERATOR.subprocess, 'check_output',
                    side_effect=['/dev/sdb1\n', 'test-uuid\n', '/home\n']), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit):
                    GENERATOR.main()
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_plan_without_repository_or_writes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'scripts').mkdir()
            helper = root / 'scripts' / 'backup-config.py'
            helper.write_bytes((ROOT / 'scripts' / 'backup-config.py').read_bytes())
            helper.chmod(0o755)
            # Exercise orchestration with simulated block devices, without root privileges.
            script = (ROOT / 'backup-system.sh').read_text().replace('if [[ $EUID -ne 0 ]]; then', 'if false; then', 1)
            (root / 'backup-system.sh').write_text(script)
            binary = root / 'bin'
            binary.mkdir()
            commands = {
                'findmnt': '''case "$*" in
*"SOURCE /") echo /dev/mockroot ;;
*"SOURCE --target /boot") echo /dev/mockroot ;;
*"-M /boot/efi"*) exit 1 ;;
*"TARGET --target /home") echo /home ;;
*"SOURCE --target /home") echo /dev/mockhome ;;
*) exit 1 ;;
esac''',
                'lvs': 'exit 1',
                'cryptsetup': 'exit 1',
                'lsblk': 'echo mockdisk',
            }
            for name, body in commands.items():
                executable = binary / name
                executable.write_text('#!/bin/bash\n' + body + '\n')
                executable.chmod(0o755)
            env = dict(os.environ, PATH=f"{binary}:{os.environ['PATH']}")
            destination = root / 'uncreated-storage'
            result = subprocess.run(['bash', str(root / 'backup-system.sh'), '--print-plan',
                                     '--backup-dir', str(destination)], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('root: live-filesystem', result.stdout)
            self.assertIn('home: auto', result.stdout)
            self.assertFalse(destination.exists())
            self.assertFalse((root / '.backup.lock').exists())
            invalid = root / 'invalid.json'
            invalid.write_text('{"home":{"path":"/home\\nunsafe"}}')
            result = subprocess.run(['bash', str(root / 'backup-system.sh'), '--print-plan',
                                     '--config', str(invalid)], env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((root / 'backup-history.log').exists())

    def test_separate_home_backup_uses_same_repository_or_is_skipped(self):
        for home in ['restic', 'exclude']:
            with self.subTest(home=home), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / 'scripts').mkdir()
                helper = root / 'scripts' / 'backup-config.py'
                helper.write_bytes((ROOT / 'scripts' / 'backup-config.py').read_bytes())
                helper.chmod(0o755)
                script = (ROOT / 'backup-system.sh').read_text().replace('if [[ $EUID -ne 0 ]]; then', 'if false; then', 1)
                (root / 'backup-system.sh').write_text(script)
                storage = root / 'storage'
                (storage / 'restic').mkdir(parents=True)
                (storage / 'restic' / 'config').write_text('{}')
                config = copy.deepcopy(BACKUP.DEFAULT)
                config['home']['mode'] = home
                (root / 'profile.json').write_text(json.dumps(config))
                binary = root / 'bin'
                binary.mkdir()
                commands = {
                    'findmnt': """case "$*" in
*"SOURCE /") echo /dev/mockroot ;;
*"SOURCE --target /boot") echo /dev/mockboot ;;
*"-M /boot/efi"*) exit 1 ;;
*"-M /boot"*) exit 0 ;;
*"TARGET --target /home") echo /home ;;
*"SOURCE --target /home") echo /dev/mockhome ;;
*"FSTYPE"*) echo ext4 ;;
*) exit 1 ;;
esac""",
                    'lvs': 'case "$*" in *"-a "*) echo mock-lvs ;; *) exit 1 ;; esac',
                    'cryptsetup': 'exit 1',
                    'lsblk': 'case "$*" in *PTTYPE*) exit 0 ;; */dev/mockhome) echo home-disk ;; *) echo mockdisk ;; esac',
                    'pvs': 'echo mock-pvs',
                    'vgs': 'echo mock-vgs',
                    'sgdisk': 'exit 0',
                    'sfdisk': 'echo Unexpected partition dump >&2; exit 99',
                    'blkid': 'echo mock-uuid',
                    'restic': """printf '%s\\n' "$*" >> "$MOCK_RESTIC_LOG"
case "$*" in
*" backup "*) echo '{"message_type":"summary","data_added":1,"snapshot_id":"mock-snapshot"}' ;;
*) echo '[]' ;;
esac""",
                }
                for name, body in commands.items():
                    executable = binary / name
                    executable.write_text('#!/bin/bash\n' + body + '\n')
                    executable.chmod(0o755)
                command_log = root / 'restic-commands'
                env = dict(os.environ, PATH=f"{binary}:{os.environ['PATH']}",
                           RESTIC_PASSWORD='mock-password', MOCK_RESTIC_LOG=str(command_log))
                result = subprocess.run(['bash', str(root / 'backup-system.sh'), '--config',
                                         str(root / 'profile.json'), '--backup-dir', str(storage), '--prune'],
                                        env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                calls = command_log.read_text().splitlines()
                home_calls = [call for call in calls if ' backup /home ' in call]
                self.assertEqual(len(home_calls), 1 if home == 'restic' else 0)
                if home_calls:
                    self.assertIn(f'-r {storage}/restic ', home_calls[0])
                    self.assertIn('--tag system-home', home_calls[0])
                layout = json.loads((storage / 'recovery-metadata' / 'layout.json').read_text())
                self.assertEqual(layout['home']['backed_up'], home == 'restic')
                self.assertEqual(layout['root']['filesystem_uuid'], 'mock-uuid')
                self.assertIsNone(layout['home']['sfdisk_file'])
                self.assertIsNone(layout['home']['gpt_file'])
                self.assertIsNone(layout['disk']['sfdisk_file'])
                self.assertIn('status=success', (storage / 'backup-history.log').read_text())

    def test_restore_rejects_unsupported_layout_before_tools_or_disk_changes(self):
        for root_path, fs_type, boot_mode in [('/', 'ext4', 'auto'),
                                              ('/mnt/root-backup-snapshot', 'xfs', 'auto'),
                                              ('/mnt/root-backup-snapshot', 'ext4', 'none')]:
            with self.subTest(root_path=root_path, fs_type=fs_type, boot_mode=boot_mode), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                storage = root / 'storage'
                (storage / 'restic').mkdir(parents=True)
                (storage / 'restic' / 'config').write_text('{}')
                (storage / 'recovery-metadata').mkdir()
                layout = {'profile': {'recovery_profile': 'lvm-luks-uefi', 'boot_mode': boot_mode},
                          'root': {'backup_path': root_path, 'filesystem_type': fs_type}}
                (storage / 'recovery-metadata' / 'layout.json').write_text(json.dumps(layout))
                script = (ROOT / 'restore-system.sh').read_text().replace('if [[ $EUID -ne 0 ]]; then', 'if false; then', 1)
                (root / 'restore-system.sh').write_text(script)
                result = subprocess.run(['bash', str(root / 'restore-system.sh'), '--backup-dir',
                                         str(storage), '--dry-run'], capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('unsupported-backup-layout', result.stderr)
                self.assertNotIn('Перевірка необхідних утиліт', result.stdout)


class SetupMountTests(unittest.TestCase):
    def test_fstab_append_is_idempotent_and_preserves_backup(self):
        helper = module('setup-backup-mount')
        with tempfile.TemporaryDirectory() as directory:
            fstab = Path(directory) / 'fstab'
            original = 'UUID=root / ext4 defaults 0 1\n'
            fstab.write_text(original)
            self.assertTrue(helper.prepare_fstab(fstab, '/backup/system disk', 'backup-uuid', 'ext4'))
            self.assertIn(r'/backup/system\040disk', fstab.read_text())
            self.assertEqual(fstab.with_name('fstab.before-system-backup').read_text(), original)
            before = fstab.read_text()
            self.assertFalse(helper.prepare_fstab(fstab, '/backup/system disk', 'backup-uuid', 'ext4'))
            self.assertEqual(fstab.read_text(), before)

    def test_fstab_conflict_is_not_modified(self):
        helper = module('setup-backup-mount')
        with tempfile.TemporaryDirectory() as directory:
            fstab = Path(directory) / 'fstab'
            original = 'UUID=other /backup/system ext4 defaults 0 2\n'
            fstab.write_text(original)
            with self.assertRaises(ValueError):
                helper.prepare_fstab(fstab, '/backup/system', 'backup-uuid', 'ext4')
            self.assertEqual(fstab.read_text(), original)
            self.assertFalse(fstab.with_name('fstab.before-system-backup').exists())


if __name__ == '__main__':
    unittest.main()
