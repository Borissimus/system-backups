"""Verify installed backups work after removing the source checkout."""
import importlib.util
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('install_service_config', ROOT / 'scripts/install-service-config.py')
INSTALL = importlib.util.module_from_spec(spec)
spec.loader.exec_module(INSTALL)


class InstallTests(unittest.TestCase):
    def config(self, root):
        result = INSTALL.helper('service-config').load(str(ROOT / 'configs/examples/service-config.jsonc'))
        result.update(code_dir=str(root / 'checkout'), backup_profile='', notice_user='',
                      backup_mount=str(root / 'mount'), backup_dir=str(root / 'mount/storage'),
                      restic_password_file=str(root / 'etc/restic.pass'), min_repository_free_gib=0)
        return result

    def test_config_copy_defaults_permissions_and_reinstall(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'service.json'
            profile = root / 'profile.json'
            profile.write_text('{"schema_version": 1, "home": {"mode": "exclude"}}')
            data = self.config(root)
            data['backup_profile'] = str(profile)
            source.write_text(json.dumps(data))
            installed = root / 'etc/service.json'
            runtime = root / 'lib'
            INSTALL.install_config(source, installed, runtime)
            actual = json.loads(installed.read_text())
            self.assertEqual(actual['backup_profile'], str(root / 'etc/backup.json'))
            self.assertEqual(actual['code_dir'], str(runtime))
            self.assertEqual(json.loads((root / 'etc/backup.json').read_text())['home']['mode'], 'exclude')
            for file in (installed, root / 'etc/backup.json'):
                self.assertEqual(file.stat().st_mode & 0o777, 0o600)
            self.assertEqual(json.loads(source.read_text()), data)
            profile.unlink()
            source.unlink()
            INSTALL.install_config(installed, installed, runtime)
            self.assertEqual(json.loads(installed.read_text()), actual)
            # Explicit empty profile materializes safe defaults, replacing old settings.
            source.write_text(json.dumps(self.config(root)))
            INSTALL.install_config(source, installed, runtime)
            self.assertEqual(json.loads((root / 'etc/backup.json').read_text())['home']['mode'], 'auto')

    def test_missing_legacy_profile_uses_relocated_user_config(self):
        for old_path in ('backup-config.json', 'configs/backup-config.json', 'configs/backup-config.jsonc'):
            with self.subTest(old_path=old_path), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                config = self.config(root)
                checkout = Path(config['code_dir'])
                relocated = checkout / 'configs/user' / Path(old_path).name
                relocated.parent.mkdir(parents=True)
                relocated.write_text('{"schema_version": 1, "home": {"mode": "exclude"}}')
                config['backup_profile'] = str(checkout / old_path)
                source = root / 'service.json'
                source.write_text(json.dumps(config))
                installed = root / 'etc/service.json'
                INSTALL.install_config(source, installed, root / 'lib')
                self.assertEqual(json.loads((root / 'etc/backup.json').read_text())['home']['mode'], 'exclude')
                self.assertEqual(json.loads(installed.read_text())['backup_profile'], str(root / 'etc/backup.json'))

    def test_invalid_source_does_not_replace_installed_configs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'service.json'
            source.write_text(json.dumps(self.config(root)))
            installed = root / 'etc/service.json'
            INSTALL.install_config(source, installed, root / 'lib')
            original = installed.read_bytes(), (root / 'etc/backup.json').read_bytes()
            data = self.config(root)
            data['backup_profile'] = str(root / 'missing.json')
            source.write_text(json.dumps(data))
            with self.assertRaises(ValueError):
                INSTALL.install_config(source, installed, root / 'lib')
            self.assertEqual((installed.read_bytes(), (root / 'etc/backup.json').read_bytes()), original)

    def test_actual_installer_and_wrapper_without_checkout(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            checkout, runtime = root / 'checkout', root / 'lib'
            config_dir, units, binary = root / 'etc', root / 'units', root / 'bin'
            for path in (checkout / 'scripts', config_dir, units, binary):
                path.mkdir(parents=True)
            for file in (ROOT / 'scripts').glob('*'):
                if file.is_file():
                    shutil.copy2(file, checkout / 'scripts' / file.name)
            shutil.copytree(ROOT / 'systemd', checkout / 'systemd')
            checkout_backup = checkout / 'backup-system.sh'
            checkout_backup.write_text('''#!/bin/bash
set -eu
[[ "$1" == --prune && "$2" == --backup-dir && "$4" == --config ]]
[[ "$5" == "$MOCK_PROFILE" ]]
python3 "$(dirname "$0")/scripts/backup-config.py" validate --config "$5"
echo 'ts=test status=success step=done' >> "$3/backup-history.log"
''')
            checkout_backup.chmod(0o755)
            data = self.config(root)
            profile = checkout / 'profile.json'
            profile.write_text('{"schema_version": 1, "home": {"mode": "exclude"}}')
            data['backup_profile'] = str(profile)
            data['success_callback'] = str(runtime / 'after-success')
            source = checkout / 'service.json'
            source.write_text(json.dumps(data))
            (config_dir / 'restic.pass').write_text('temporary-test-password')
            storage = Path(data['backup_dir'])
            (storage / 'restic').mkdir(parents=True)
            (storage / 'restic/config').write_text('mock-repository')
            mappings = {'/usr/local/lib/system-backup': str(runtime),
                        '/etc/system-backup': str(config_dir),
                        '/etc/systemd/system': str(units),
                        '/usr/local/bin/system-backupctl': str(binary / 'system-backupctl'),
                        '/var/lib/system-backup': str(root / 'state'),
                        '/var/cache/system-backup/restic': str(root / 'cache')}
            for name in ('install-system-backup.sh', 'system-backup-run.sh'):
                file = checkout / 'scripts' / name
                text = file.read_text().replace('[[ $EUID -ne 0 ]]', 'false').replace('[[ $EUID -eq 0 ]]', 'true')
                for old, new in mappings.items():
                    text = text.replace(old, new)
                file.write_text(text)
            commands = {'systemctl': 'exit 0', 'mountpoint': 'exit 0',
                        'findmnt': 'case "$*" in *SOURCE*) echo /dev/mock ;; *) echo "$MOCK_MOUNT" ;; esac',
                        'blkid': 'echo PUT-BACKUP-DISK-UUID-HERE',
                        'df': "printf 'Avail\\n99999999999\\n'"}
            for name, body in commands.items():
                file = binary / name
                file.write_text('#!/bin/bash\n' + body + '\n')
                file.chmod(0o755)
            env = dict(os.environ, PATH=f"{binary}:{os.environ['PATH']}", SUDO_USER='',
                       MOCK_MOUNT=data['backup_mount'], MOCK_PROFILE=str(config_dir / 'backup.json'))
            result = subprocess.run(['bash', str(checkout / 'scripts/install-system-backup.sh'),
                                     '--config', str(source)], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('Wants=', (units / 'system-backup.service.d/config.conf').read_text())
            self.assertNotIn('Requires=', (units / 'system-backup.service.d/config.conf').read_text())
            installed = config_dir / 'service.json'
            actual = json.loads(installed.read_text())
            self.assertEqual(actual['code_dir'], str(runtime))
            self.assertEqual(actual['backup_profile'], str(config_dir / 'backup.json'))
            for filename in (installed, config_dir / 'backup.json'):
                self.assertEqual(filename.stat().st_mode & 0o777, 0o600)
            profile.unlink()
            # An update without --config must preserve active settings, even
            # when the original input profile no longer exists.
            result = subprocess.run(['bash', str(checkout / 'scripts/install-system-backup.sh')],
                                    env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(installed.read_text()), actual)
            shutil.rmtree(checkout)
            result = subprocess.run(['bash', str(runtime / 'run')], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('backup succeeded', result.stdout)
            # Execute the real metadata writer, not just the fake backup command.
            # It imports another runtime helper when saving service settings.
            backup_source = (ROOT / 'backup-system.sh').read_text()
            marker = "python3 - \"$META/layout.json\" \"$SCRIPT_DIR/scripts/service-config.py\" <<'PY'\n"
            metadata_script = backup_source.split(marker, 1)[1].split('\nPY\n', 1)[0]
            metadata_dir = storage / 'recovery-metadata'
            metadata_dir.mkdir()
            metadata_env = dict(env)
            for key in re.findall(r'os.environ\["([A-Z_]+)"\]', metadata_script):
                metadata_env[key] = '0'
            for key in re.findall(r'yes\("([A-Z_]+)"\)', metadata_script):
                metadata_env[key] = '0'
            metadata_env['BACKUP_PROFILE_JSON'] = (config_dir / 'backup.json').read_text()
            metadata_env['SYSTEM_BACKUP_SERVICE_CONFIG_JSON'] = installed.read_text()
            result = subprocess.run(['python3', '-', str(metadata_dir / 'layout.json'),
                                     str(runtime / 'scripts/service-config.py')],
                                    input=metadata_script, env=metadata_env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            saved_service = json.loads((metadata_dir / 'service-config.json').read_text())
            self.assertEqual(saved_service, actual)
            self.assertIn('status=success', (storage / 'backup-history.log').read_text())
