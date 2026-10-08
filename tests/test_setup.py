"""Exercise setup orchestration with all privileged operations simulated."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import importlib.util
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SetupTests(unittest.TestCase):
    def run_setup(self, directory, *, existing=False, outcome='success', no_enable=False):
        root = Path(directory)
        scripts = root / 'scripts'
        scripts.mkdir()
        binary = root / 'bin'
        binary.mkdir()
        storage = root / 'mount' / 'storage'
        storage.mkdir(parents=True)
        password = root / 'password'
        password.write_text('mock-secret')
        spec = importlib.util.spec_from_file_location('service_config', ROOT / 'scripts/service-config.py')
        helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(helper)
        config = helper.load(str(ROOT / 'configs/service-config.example.jsonc'))
        config.update(code_dir=str(root), backup_mount=str(root / 'mount'),
                      backup_dir=str(storage), backup_disk_uuid='mock-uuid', backup_profile='',
                      restic_password_file=str(password), min_repository_free_gib=0)
        config_file = root / 'service.json'
        config_file.write_text(json.dumps(config))
        (scripts / 'service-config.py').write_bytes((ROOT / 'scripts' / 'service-config.py').read_bytes())
        (scripts / 'setup-backup-mount.py').write_text("print('Simulated fstab setup')\n")
        setup = (ROOT / 'scripts' / 'setup-system-backup.sh').read_text()
        setup = setup.replace('if [[ $EUID -ne 0 ]]; then', 'if false; then', 1)
        setup = setup.replace('[[ -b "$backup_device" ]]', '[[ -n "$backup_device" ]]', 1)
        (scripts / 'setup-system-backup.sh').write_text(setup)
        (scripts / 'install-system-backup.sh').write_text('echo install >> "$MOCK_CALLS"\n')
        backup = root / 'backup-system.sh'
        backup.write_text('#!/bin/bash\necho "backup $*" >> "$MOCK_CALLS"\n')
        backup.chmod(0o755)
        if existing:
            (storage / 'restic').mkdir()
            (storage / 'restic' / 'config').write_text('existing repository')
        commands = {
            'blkid': 'echo ext4',
            'mountpoint': 'exit 0',
            'findmnt': 'case "$*" in *UUID*) echo mock-uuid ;; *) echo "$MOCK_MOUNT" ;; esac',
            'df': "printf 'Avail\\n99999999999\\n'",
            'systemctl': '''echo "systemctl $*" >> "$MOCK_CALLS"
case "$*" in
  'start system-backup.service')
    if [[ "$MOCK_OUTCOME" == failure ]]; then exit 1; fi
    echo "ts=new status=$MOCK_OUTCOME step=done" >> "$MOCK_STORAGE/backup-history.log" ;;
esac''',
            'restic': '''echo "restic $*" >> "$MOCK_CALLS"
mkdir -p "$MOCK_STORAGE/restic"
echo new-repository > "$MOCK_STORAGE/restic/config"''',
        }
        for name in ['lvs', 'pvs', 'vgs', 'lvcreate', 'lvremove', 'vgcfgbackup', 'cryptsetup', 'sgdisk', 'sfdisk', 'flock', 'lsblk']:
            commands[name] = 'exit 0'
        for name, body in commands.items():
            executable = binary / name
            executable.write_text('#!/bin/bash\n' + body + '\n')
            executable.chmod(0o755)
        calls = root / 'calls'
        env = dict(os.environ, PATH=f"{binary}:{os.environ['PATH']}", MOCK_CALLS=str(calls),
                   MOCK_STORAGE=str(storage), MOCK_MOUNT=str(root / 'mount'), MOCK_OUTCOME=outcome)
        args = ['bash', str(scripts / 'setup-system-backup.sh'), '--config', str(config_file)]
        if no_enable:
            args.append('--no-enable')
        result = subprocess.run(args, env=env, capture_output=True, text=True)
        return result, calls.read_text(), storage

    def test_new_repository_backup_then_enable(self):
        with tempfile.TemporaryDirectory() as directory:
            result, calls, _ = self.run_setup(directory)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(' init\n', calls)
            self.assertLess(calls.index('start system-backup.service'), calls.index('enable --now'))
            self.assertIn('--print-plan', calls)
            self.assertIn('--dry-run', calls)

    def test_existing_repository_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            result, calls, storage = self.run_setup(directory, existing=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn(' init\n', calls)
            self.assertEqual((storage / 'restic' / 'config').read_text(), 'existing repository')

    def test_failure_or_skip_never_enables_timer(self):
        for outcome in ['failure', 'skipped']:
            with self.subTest(outcome=outcome), tempfile.TemporaryDirectory() as directory:
                result, calls, _ = self.run_setup(directory, outcome=outcome)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('systemctl enable', calls)
                self.assertIn('disable --now system-backup.timer', calls)

    def test_no_enable_after_success(self):
        with tempfile.TemporaryDirectory() as directory:
            result, calls, _ = self.run_setup(directory, no_enable=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn('systemctl enable', calls)
