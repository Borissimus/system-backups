import copy
import contextlib
import io
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / (name + '.py'))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


RESTORE = module('restore-system')
CONFIG = RESTORE.CONFIG
ORIGINAL = dict(luks_uuid='11111111-1111-4111-8111-111111111111', root_uuid='22222222-2222-4222-8222-222222222222',
                boot_uuid='33333333-3333-4333-8333-333333333333', efi_uuid='1234-ABCD',
                vg_name='source-vg', lv_name='root', crypt_name='source-crypt')


def snapshots(tag='run-20261008-211621', host='machine', time='2026-10-08T21:16:35+03:00'):
    return [dict(id=str(number) * 64, time=time, hostname=host, tags=[kind, tag], paths=paths)
            for number, kind, paths in [(1, 'system-root', ['/mnt/root-backup-snapshot']),
                                       (2, 'system-boot', ['/boot', '/boot/efi']),
                                       (3, 'recovery-metadata', ['/storage/recovery-metadata'])]]


def layout():
    return dict(run_tag='run-20261008-211621', profile=dict(recovery_profile='lvm-luks-uefi', boot_mode='required'),
                root=dict(backup_path='/mnt/root-backup-snapshot', snapshot='lvm', filesystem_type='ext4',
                          filesystem_uuid=ORIGINAL['root_uuid'], vg_name='source-vg', lv_name='root'),
                boot=dict(filesystem_type='ext4', separate_mount=True, efi=True,
                          filesystem_uuid=ORIGINAL['boot_uuid'], esp_uuid=ORIGINAL['efi_uuid']),
                luks=dict(uuid=ORIGINAL['luks_uuid'], mapping='source-crypt', device='/dev/source3', header_file='luks-header.img'),
                home=dict(mode='exclude', separate_mount=True))


def disk(path='/dev/restore-test', serial='TEST-SERIAL', children=None):
    return dict(path=path, type='disk', size=100 * RESTORE.GIB, serial=serial, wwn='test-wwn', model='Test SSD',
                uuid=None, mountpoints=[], children=children or [])


class RestoreTests(unittest.TestCase):
    def config(self):
        config = copy.deepcopy(CONFIG.DEFAULT)
        config['target'] = dict(device='/dev/restore-test', serial='TEST-SERIAL')
        return config

    def test_documented_example_is_valid(self):
        result = CONFIG.load(ROOT / 'configs/examples/restore-config.jsonc')
        self.assertEqual(result['identifiers'], CONFIG.DEFAULT['identifiers'])

    def test_original_generate_and_explicit_identifiers(self):
        config = self.config()
        self.assertEqual(CONFIG.resolve_ids(config, ORIGINAL), ORIGINAL)
        config['identifiers'] = {key: 'generate' for key in ORIGINAL}
        generated = CONFIG.resolve_ids(config, ORIGINAL)
        self.assertTrue(all(generated[key] != ORIGINAL[key] for key in ORIGINAL))
        generated['vg_name'] = 'custom-vg'
        generated['efi_uuid'] = 'aabb-ccdd'
        config['identifiers'] = generated
        result = CONFIG.resolve_ids(config, ORIGINAL)
        self.assertEqual(result['vg_name'], 'custom-vg')
        self.assertEqual(result['efi_uuid'], 'AABB-CCDD')

    def test_bad_fields_paths_identifiers_and_duplicate_uuids(self):
        for key, value in [('mount_dir', '/'), ('mount_dir', '/backup/system/system-backups/target'),
                           ('root_lv_percent', 100), ('luks_header', 'unknown')]:
            with self.subTest(key=key):
                config = self.config()
                config[key] = value
                with self.assertRaises(ValueError):
                    CONFIG.validate(config)
        config = self.config()
        config['identifiers']['efi_uuid'] = 'not-a-fat-id'
        with self.assertRaises(ValueError):
            CONFIG.validate(config)
        config = self.config()
        config['identifiers']['boot_uuid'] = ORIGINAL['root_uuid']
        with self.assertRaises(ValueError):
            CONFIG.resolve_ids(config, ORIGINAL)

    def test_select_latest_complete_run_without_mixing_incomplete_run(self):
        items = snapshots()
        items += snapshots('run-20261009-230000', time='2026-10-09T23:00:00+03:00')[:2]
        self.assertEqual(RESTORE.select_run(items, self.config())['run_tag'], 'run-20261008-211621')
        with self.assertRaises(ValueError):
            RESTORE.select_run(items[-2:], self.config())
        with self.assertRaises(ValueError):
            RESTORE.select_run(items + [items[0]], self.config())

    def test_multiple_hosts_require_explicit_choice(self):
        items = snapshots() + snapshots(host='other-machine')
        with self.assertRaises(ValueError):
            RESTORE.select_run(items, self.config())
        config = self.config()
        config['backup_host'] = 'other-machine'
        self.assertEqual(RESTORE.select_run(items, config)['host'], 'other-machine')

    def test_layout_run_path_and_filesystem_guards(self):
        selected = RESTORE.select_run(snapshots(), self.config())
        RESTORE.supported_layout(layout(), selected)
        for section, key, value in [('root', 'filesystem_type', 'xfs'), ('root', 'snapshot', 'live'),
                                    ('boot', 'separate_mount', False), ('profile', 'boot_mode', 'none')]:
            with self.subTest(key=key):
                manifest = layout()
                manifest[section][key] = value
                with self.assertRaises(ValueError):
                    RESTORE.supported_layout(manifest, selected)
        manifest = layout()
        manifest['run_tag'] = 'wrong'
        with self.assertRaises(ValueError):
            RESTORE.supported_layout(manifest, selected)

    def test_target_rejects_serial_mounted_swap_and_active_mapping(self):
        config = self.config()
        self.assertEqual(RESTORE.check_target(config, [disk()])['serial'], 'TEST-SERIAL')
        with self.assertRaises(ValueError):
            RESTORE.check_target(config, [disk(serial='WRONG')])
        for child in [dict(path='/dev/restore-test1', type='part', mountpoints=['/']),
                      dict(path='/dev/restore-test1', type='part', mountpoints=['[SWAP]']),
                      dict(path='/dev/mapper/active', type='crypt', mountpoints=[])]:
            with self.subTest(child=child), self.assertRaises(ValueError):
                RESTORE.check_target(config, [disk(children=[child])])

    def test_uuid_and_vg_conflicts_include_unmounted_devices(self):
        target = disk()
        original = disk('/dev/original', 'OLD', [dict(path='/dev/original1', type='part', uuid=ORIGINAL['root_uuid'], mountpoints=[])])
        with self.assertRaises(ValueError):
            RESTORE.check_conflicts(ORIGINAL, [original, target], set(), target)
        with self.assertRaises(ValueError):
            RESTORE.check_conflicts(ORIGINAL, [target], {'source-vg'}, target)
        config = self.config()
        config['identifiers'] = {key: 'generate' for key in ORIGINAL}
        RESTORE.check_conflicts(CONFIG.resolve_ids(config, ORIGINAL), [original, target], {'source-vg'}, target)

    def test_fstab_crypttab_kernel_refs_and_timer_are_fixed_only_in_target(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory)
            etc = target / 'etc'
            (etc / 'default').mkdir(parents=True)
            (etc / 'initramfs-tools/conf.d').mkdir(parents=True)
            (etc / 'systemd/system/timers.target.wants').mkdir(parents=True)
            (etc / 'fstab').write_text('UUID=old / ext4 defaults 0 1\nUUID=boot /boot ext4 defaults 0 2\nUUID=efi /boot/efi vfat defaults 0 2\nUUID=external /home ext4 defaults 0 2\n')
            (etc / 'crypttab').write_text(f"another-name UUID={ORIGINAL['luks_uuid']} none luks\nexternal UUID=external none luks\n")
            (etc / 'default/grub').write_text(f"GRUB_CMDLINE_LINUX='cryptdevice=UUID={ORIGINAL['luks_uuid']}:source-crypt'\n")
            timer = etc / 'systemd/system/timers.target.wants/system-backup.timer'
            timer.symlink_to('/etc/systemd/system/system-backup.timer')
            config = self.config()
            config['identifiers'] = {key: 'generate' for key in ORIGINAL}
            identifiers = CONFIG.resolve_ids(config, ORIGINAL)
            RESTORE.fix_system_files(target, identifiers, ORIGINAL)
            fstab = (etc / 'fstab').read_text()
            self.assertEqual(sum(line.split()[1] == '/' for line in fstab.splitlines()), 1)
            self.assertIn('UUID=external /home', fstab)
            self.assertIn(identifiers['root_uuid'], fstab)
            self.assertNotIn(ORIGINAL['luks_uuid'], (etc / 'crypttab').read_text())
            self.assertIn('luks,initramfs', (etc / 'crypttab').read_text())
            self.assertIn(identifiers['luks_uuid'], (etc / 'default/grub').read_text())
            self.assertFalse(timer.is_symlink())
            self.assertEqual((etc / 'initramfs-tools/conf.d/resume').read_text(), 'RESUME=none\n')

    def test_resume_journal_refuses_mismatched_completed_step(self):
        with tempfile.TemporaryDirectory() as directory:
            state = dict(completed=['partition'])
            plan = dict(identifiers=ORIGINAL, target=disk())
            executor = RESTORE.Executor(self.config(), plan, Path(directory) / 'state', state, None, directory)
            with self.assertRaises(ValueError):
                executor.step('partition', lambda: self.fail('must not repeat disk wipe'), lambda: False)

    def test_missing_pinned_snapshot_stops_resume(self):
        repository = RESTORE.Repository.__new__(RESTORE.Repository)
        selected = RESTORE.select_run(snapshots(), self.config())
        with patch.object(repository, 'command', return_value=json.dumps(snapshots()[1:])):
            with self.assertRaises(ValueError):
                repository.ensure_selection(selected)

    def test_main_dry_run_never_constructs_executor_or_prompts_for_erase(self):
        with tempfile.TemporaryDirectory() as directory:
            config = self.config()
            config['backup_dir'] = directory
            config['identifiers'] = {key: 'generate' for key in ORIGINAL}
            (Path(directory) / 'restic').mkdir()
            (Path(directory) / 'restic/config').write_text('{}')
            filename = Path(directory) / 'restore.json'
            filename.write_text(json.dumps(config))
            selected = RESTORE.select_run(snapshots(), config)
            with patch('sys.argv', ['restore', '--config', str(filename), '--dry-run']), \
                    patch.object(RESTORE.os, 'geteuid', return_value=0), \
                    patch.object(RESTORE, 'check_tools'), \
                    patch.object(RESTORE, 'inventory', return_value=([disk()], set())), \
                    patch.object(RESTORE.Repository, '__init__', return_value=None), \
                    patch.object(RESTORE.Repository, 'selection', return_value=selected), \
                    patch.object(RESTORE.Repository, 'ensure_selection'), \
                    patch.object(RESTORE.Repository, 'metadata', return_value=(layout(), ORIGINAL)), \
                    patch.object(RESTORE.Repository, 'command', side_effect=['ID=ubuntu', None, '{"total_size": 1024}']), \
                    patch.object(RESTORE, 'Executor') as executor, \
                    patch('builtins.input', side_effect=AssertionError('dry-run must not prompt for erasing')), \
                    contextlib.redirect_stdout(io.StringIO()):
                RESTORE.main()
                executor.assert_not_called()
            self.assertFalse((Path(directory) / '.restore-state.json').exists())

    def test_executor_complete_sequence_with_all_device_operations_simulated(self):
        with tempfile.TemporaryDirectory() as directory:
            config = self.config()
            config['mount_dir'] = str(Path(directory) / 'target')
            config['identifiers'] = {key: 'generate' for key in ORIGINAL}
            ids = CONFIG.resolve_ids(config, ORIGINAL)
            plan = dict(identifiers=ids, target=disk(), root_bytes=1024,
                        selection=RESTORE.select_run(snapshots(), config), originals=ORIGINAL)
            state = dict(completed=[])
            calls = []
            def fake_run(*args, **kwargs):
                calls.append(tuple(str(arg) for arg in args))
                if args[0] == 'blockdev':
                    return str(10 * RESTORE.GIB)
                if args[0] == 'pvs':
                    return '/dev/mapper/' + ids['crypt_name']
                return ''
            class FakeRepo:
                def command(self, *args):
                    destination = Path(args[args.index('--target') + 1])
                    if args[1].startswith('1'):
                        (destination / 'etc').mkdir(parents=True)
                        (destination / 'etc/fstab').write_text('UUID=old / ext4 defaults 0 1\n')
                    else:
                        (destination / 'grub').mkdir(parents=True)
                        (destination / 'efi/EFI').mkdir(parents=True)
            executor = RESTORE.Executor(config, plan, Path(directory) / 'state.json', state, FakeRepo(), directory)
            with patch.object(RESTORE, 'run', side_effect=fake_run), \
                    patch.object(executor, 'verify_partitions', return_value=True), \
                    patch.object(executor, 'verify_lvm', return_value=True), \
                    patch.object(executor, 'verify_filesystems', return_value=True), \
                    patch.object(executor, 'uuid_of', return_value=ids['luks_uuid']), \
                    patch.object(RESTORE.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, stdout='')), \
                    contextlib.redirect_stdout(io.StringIO()):
                executor.execute()
                self.assertTrue(executor.cleanup())
            self.assertEqual(state['completed'], ['partition', 'luks', 'lvm', 'format', 'root_files', 'boot_files', 'system_files', 'bootloader'])
            self.assertTrue(any(call[:2] == ('wipefs', '-a') and call[-1] == '/dev/restore-test' for call in calls))
            self.assertFalse(any('/mnt/root-backup-snapshot' in call for call in calls if call[0] == 'mount'))
            self.assertIn(ids['root_uuid'], (Path(config['mount_dir']) / 'etc/fstab').read_text())

    @unittest.skipUnless(shutil.which('restic'), 'restic not installed')
    def test_real_restic_subfolder_restore_in_temporary_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repo = root / 'repo'
            source = root / 'source' / 'mnt/root-backup-snapshot'
            (source / 'etc').mkdir(parents=True)
            (source / 'etc/fstab').write_text('fixture data only')
            config = self.config()
            config['backup_dir'] = str(root)
            repository = RESTORE.Repository.__new__(RESTORE.Repository)
            repository.env = dict(os.environ, RESTIC_PASSWORD='temporary-test-password')
            repository.path = repo
            repository.command('init', capture=True)
            repository.command('backup', source, '--tag', 'test', capture=True)
            snapshot = json.loads(repository.command('snapshots', '--json', capture=True))[0]
            destination = root / 'output'
            repository.command('restore', snapshot['id'] + ':' + str(source), '--target', destination, '--verify', capture=True)
            self.assertEqual((destination / 'etc/fstab').read_text(), 'fixture data only')
            self.assertFalse((destination / 'mnt').exists())


if __name__ == '__main__':
    unittest.main()
