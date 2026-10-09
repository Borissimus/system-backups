# System recovery from restic

Run all command examples from the repository root.

This is the guide for `restore-system.sh`. The current implementation restores
**Ubuntu x86_64, UEFI, ext4 root on LVM inside LUKS, a separate ext4 `/boot`,
and FAT32 EFI**. Recovery targets an explicitly selected whole disk.
All data on that disk is erased after confirmation.

Validation status: on 2026-10-09, backup `run-20261008-230002` was restored onto
a PLEXTOR PX-256M6S+ 256 GB disk from a running Ubuntu system. After disconnecting
the original system disk, the restored OS booted successfully: root on the new
LUKS/LVM, boot/EFI on PLEXTOR, and external home connected. There were no failed
units; the backup timer was disabled/inactive. Tested settings: all identifiers
`generate`, `luks_header=new`, dracut, Secure Boot disabled.
Live USB recovery, original identifiers, and restoring an old LUKS header have
not yet been tested on hardware. Run dry-run and review the plan before each restore.

## Where to run recovery

You can prepare a new disk from the running Ubuntu system while keeping the
original system online, provided UUIDs and VG/mapping names do not conflict.
Alternatively, use an Ubuntu Live USB. For the first boot of the restored disk,
disconnect the original system disk. Leave a separate `/home` connected if the
restored OS needs it.

Restore does not reuse the host's `/mnt/root-backup-snapshot`, deactivate
unrelated VGs, or remove unrelated mappings. A target disk with any mount,
swap, or active storage mapping is rejected. GRUB is installed only on the
target ESP using `--no-nvram` and the fallback loader `EFI/BOOT/BOOTX64.EFI`.
Existing firmware entries and boot order remain unchanged. Secure Boot must
be disabled for this recovery path; the script rejects a host whose Secure
Boot flag is enabled.

## What to prepare

- A connected disk containing the restic repository, mounted for example at
  `/backup/system`, with storage at `/backup/system/system-backups`.
- This project's code, accessible from the Live USB if using one.
- The restic password, available separately from the encrypted repository.
- A target disk and its exact serial. Its size may differ from the source;
  the plan checks data size, boot partitions, filesystem overhead, and VG reserve.

Host dependencies are not installed automatically:

```bash
sudo apt update
sudo apt install python3 restic lvm2 cryptsetup gdisk dosfstools util-linux
```

The restored Ubuntu must contain dracut or `initramfs-tools` with
`cryptsetup-initramfs`, plus GRUB EFI. The script runs them inside chroot after
restoring files.

Inspect disks and storage:

```bash
lsblk -o NAME,TYPE,SIZE,FSTYPE,UUID,MOUNTPOINTS,MODEL,SERIAL
ls -l /dev/disk/by-id/
findmnt --mountpoint /backup/system
```

## Creating a recovery configuration

The backup config describes the source system. The target, its identifiers,
and LUKS header mode belong to a **separate** recovery config in `configs/`,
ignored by Git. See the annotated
[configs/restore-config.example.jsonc](../configs/restore-config.example.jsonc).
Plain JSON and separate-line `//` comments are supported.

The interactive wizard only creates a config; it does not change disks:

```bash
sudo bash restore-system.sh --interactive \
  --backup-dir /backup/system/system-backups \
  --config "$PWD/configs/restore-config.json"
```

It lists unmounted targets and asks for a disk, identifier mode, LUKS header
mode, backup host/run, and password-file path. The disk serial is saved in the
config. Existing configs are not overwritten. Since the wizard runs with sudo,
the file is root-owned with mode 0600; use `sudoedit` to edit it.

Alternatively, copy and edit the example:

```bash
cp configs/restore-config.example.jsonc configs/restore-config.jsonc
nano configs/restore-config.jsonc
python3 scripts/restore-config.py validate --config configs/restore-config.jsonc
```

Set `target.device` and the exact `target.serial`. Prefer a stable
`/dev/disk/by-id/...` link to the **whole disk**, not `...-part1`. Every run
checks serial, device type, size, WWN, and whether the target is in use.

## Identifiers

Each field in `identifiers` accepts:

| Value | Behavior |
|-------|----------|
| `original` | Use metadata from the selected backup run; the default |
| `generate` | Generate a new value and save it in the recovery journal |
| Explicit value | Use it after format and conflict checks |

Fields cover LUKS, root, boot, and EFI UUIDs, plus VG, LV, and open LUKS mapping
names. EFI UUID is a FAT volume ID such as `A1B2-C3D4`, not a 128-bit UUID.
LVM itself creates fresh internal PV/VG/LV UUIDs. `vg_name` and `lv_name`
control names, not internal LVM UUIDs.

**For recovery beside the running source system, select `generate` for all
fields.** An LV can reuse its old name in another VG, but new names are also
supported. `original` is intended for replacement with the original disk
disconnected. Conflicts are not ignored: UUIDs are checked on all visible block
devices, including unmounted ones; VGs are checked through LVM, and mappings
through `/dev/mapper`. Identifiers inside closed unrelated LUKS containers
are inaccessible. If the original LUKS disk is connected, its old VG name
cannot be reused even when hidden behind a closed container.

## Passwords and LUKS headers

The restic password opens the repository. Set `restic_password_file` or leave
it empty to be prompted. Native `RESTIC_PASSWORD*` variables are also supported.
Passwords are never saved in the recovery config or journal.

`luks_header`:

- `new` (default): create a new LUKS2 container and prompt for a new passphrase.
- `restore`: use the header from the metadata snapshot, preserving the original
  keys and passphrase. This is optional for file restoration.

In both modes, `identifiers.luks_uuid` determines the target LUKS UUID. After
creating or restoring the header, the script asks again for the LUKS passphrase
to open the container. `restore` requires the source's old passphrase.

## Dry-run and backup selection

```bash
sudo bash restore-system.sh \
  --config "$PWD/configs/restore-config.json" --dry-run
```

Use `configs/restore-config.jsonc` instead if you edited the JSONC example.
Dry-run reads the repository, extracts metadata into a temporary directory,
and validates the plan. **The target disk is unchanged** and no recovery
journal is created. `.backup.lock` is held during checks and recovery to block
concurrent local backup runs. Do not prune the repository from other machines
during recovery.

`backup_run=latest` selects the latest **complete, coherent run** containing
exactly one root, boot, and metadata snapshot with the same host/run tag.
Newer incomplete runs are skipped; independently selected latest root and
boot snapshots are never mixed. Set `backup_host` when there are multiple
hosts, or specify `run-YYYYMMDD-HHMMSS` to select one exact run.

Metadata, including backup/service configs, comes **from that run's snapshot**,
not the mutable local `recovery-metadata/` directory. Older snapshots without
archived configs can work if `layout.json` includes the required topology,
UUIDs, and filesystem fields. Backups without `layout.json` are not supported.

The plan shows exact snapshot IDs, target/serial/WWN/size, resolved identifiers,
root data size, and separate `/home` status. Confirm that the target is the
intended recovery disk, not root, home, swap, or the backup disk.

## Running recovery

After a successful dry-run:

```bash
sudo bash restore-system.sh --config "$PWD/configs/restore-config.json"
```

Before any changes, enter **`ERASE <serial>`**. Disk identity and conflicts are
then checked again. The script performs:

1. New GPT: 1 GiB ESP, 2 GiB `/boot`, and LUKS in the remaining space.
2. LUKS, PV/VG, and root LV; the LV uses 90% of free VG space by default.
3. FAT32 ESP and ext4 boot/root with selected UUIDs.
4. Restore pinned root/boot snapshots with restic `--verify`. Subfolder restore
   writes directly to the target without a second root copy.
5. Replace target root/boot/EFI `fstab` entries, create target `crypttab` with
   `luks,initramfs`, and update explicit kernel/EFI config references. External
   home/swap mount entries are preserved; their devices must be available separately.
6. Remove stale LVM device/cache bindings and resume settings.
7. Regenerate initramfs and verify the embedded target crypttab UUID; install
   GRUB on the target ESP without NVRAM changes. Disable os-prober in the restored OS.
8. Unmount only mounts created by this run, deactivate only the target VG,
   and close only the target mapping.

The backup timer **in the restored OS** stays disabled. After its first boot,
review service/backup configs and run setup separately. The host OS timer is
not reconfigured; backup attempts during recovery are skipped through the lock.

## Journal and resume

The journal is `<backup_dir>/.restore-state.json`, mode 0600. It binds the
config hash, disk identity, exact snapshot IDs, and resolved identifiers.
Generated UUIDs remain unchanged during resume.

```bash
sudo bash restore-system.sh --config "$PWD/configs/restore-config.json" --status
sudo bash restore-system.sh --config "$PWD/configs/restore-config.json" --resume --dry-run
sudo bash restore-system.sh --config "$PWD/configs/restore-config.json" --resume
```

After a failure, use `--resume`, not a fresh run. Completed partition/LUKS/LVM/
filesystem steps are checked; mismatches stop recovery instead of triggering
another erase. An interrupted file-copy step is repeated on the prepared target.
After SIGKILL or power loss, mappings/mounts may remain. Inspect and close them
manually; the script does not force teardown.

For another target or a new config, archive the old journal manually only
after inspecting the disk. There is no automatic destructive `--reset`.

## First hardware test

1. Connect the target disk and verify model/serial/size.
2. Create a config with all identifiers `generate` and `luks_header=new`.
3. Run dry-run and review the plan before proceeding.
4. Run recovery and inspect the final status and cleanup.
5. Shut down, disconnect the original system disk, and boot the restored disk
   using the firmware boot menu. Leave external `/home` connected.
6. Check the LUKS prompt, boot, login, `findmnt`, `lsblk -f`, `vgs`, and
   `journalctl -b -p err`. These checks confirm end-to-end recovery.

A separate `/home`, even if a `system-home` snapshot exists in the same
repository, other LVs, and other separate filesystems are not restored by this
process. They need a separate target/procedure. Secure Boot, TPM unlock, RAID,
and other root layouts are not supported by this recovery implementation.

### Initramfs with dracut

For Ubuntu using dracut, recovery builds a generic initramfs without capturing
the running host's command line. It includes crypt/LVM and the target crypttab,
and sets target `rd.luks.uuid` and `rd.lvm.lv` for GRUB. UUID verification
supports both dracut `etc/crypttab` and initramfs-tools `cryptroot/crypttab`.
After a bootloader-step failure, use the unchanged config with `--resume`;
completed partition/format/root/boot steps are not repeated.
