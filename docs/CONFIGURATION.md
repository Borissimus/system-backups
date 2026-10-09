# Configuring another machine

Run all command examples from the repository root.

A profile describes system requirements; the script checks them against the
actual storage layout. Disk, repository, and schedule settings are stored
separately from the code. User configs live in `configs/` and are ignored by
Git. Only annotated `*.example.jsonc` files are versioned.

Both plain JSON and `//` comments on separate lines are supported. Inline
comments and `/* ... */` blocks are not supported. The generator writes plain
JSON into `configs/` by default; use `--output-dir` to choose another directory.

Working configuration files:

- `configs/backup-config.json`: what to include in a system backup and how
  to handle root, LUKS, boot, and `/home`.
- `/etc/system-backup/service.json`: backup disk location, schedule,
  retention, and systemd wrapper settings.

For disk preparation, dependencies, config generation, repository
initialization, and the first backup, see
[BACKUP.md](BACKUP.md#3-setting-up-a-new-machine).
Python uses only the standard library; no virtual environment or pip packages
are required.

The generator and field reference are below. Alternatively, copy
`configs/backup-config.example.jsonc` and `configs/service-config.example.jsonc`,
edit them for your machine, and run the corresponding `validate` commands.

## Creating configuration files

The generator creates and validates two JSON files and detects the UUID of an
already mounted backup disk. It does not install the service, initialize a
restic repository, or overwrite existing configuration files.

```bash
python3 scripts/configure-system-backup.py \
  --profile lvm-luks-uefi \
  --home exclude \
  --backup-mount /mnt/backup \
  --backup-dir /mnt/backup/system-backups \
  --output-dir "$PWD/configs" \
  --schedule 20:00 \
  --notice-user "$USER"
```

Replace `/mnt/backup` with your disk's mount point. The code can stay in your
working directory: `code_dir` and `backup_dir` are independent. The storage
directory contains `restic/`, `recovery-metadata/`, the lock, and the history log.

Profiles: `auto`, `lvm-luks-uefi`, `lvm-plain`, `partition-luks`, and
`partition-plain`. They provide initial requirements that you can edit in JSON:
LVM profiles require snapshots, partition profiles use live backups, `luks`
requires encryption, and `plain` requires its absence. The UEFI profile
requires a mounted ESP. RAID, VGs with multiple PVs, and complex multi-disk
root layouts are not currently supported.

When `/home` is a separate mount, the generator requires an explicit choice:

- `--home restic`: copy `/home` into **the same repository** as a separate
  snapshot tagged `system-home` and with the shared run tag; retention also
  applies to it.
- `--home exclude`: skip the separate `/home`.
- `--home external`: skip it and record that it is backed up separately.
- `--home auto`: include `/home` only when it belongs to the root filesystem.

If `/home` is on the root filesystem, select `auto`: it is already included
in the root backup. The filesystem boundary matters, not the physical disk;
a separate `/home` partition on the same disk also requires a choice.

You can inspect the plan before initializing restic, without a repository
password. Backup plan and dry-run modes do not create a lock or history entry:

```bash
sudo bash backup-system.sh --config configs/backup-config.json \
  --backup-dir /mnt/backup/system-backups --print-plan
```

Complete setup from the generated configs takes one command:

```bash
sudo bash scripts/setup-system-backup.sh --config "$PWD/configs/service-config.json"
```

It installs missing dependencies, configures `fstab` by UUID, mounts the disk,
installs the service, prepares the password and repository, and performs a
dry-run and backup. The timer is enabled only after a newly recorded successful
backup. Add `--no-enable` to leave it disabled. Existing passwords and
repositories are preserved; matching `fstab` entries are made optional with
`nofail` and bounded timeouts. Repeated setup runs another backup. The disk is
not formatted. Details and the manual alternative are in [BACKUP.md](BACKUP.md).

To update only service files, use `scripts/install-system-backup.sh`.
`--config FILE` applies that service config even during reinstallation.
Without `--config`, the installed `/etc` config is preserved. A new timer is
not enabled automatically; an already enabled timer is not disabled. The
profile remains at `backup_profile`, so that file and `code_dir` must remain
accessible to the service.

## `backup-config.json`

`root.snapshot_mode`:

- `auto`: use a read-only LVM snapshot when `/` is an LVM LV; otherwise back
  up the live filesystem.
- `lvm`: require an LVM snapshot and fail if root is not on LVM.
- `live`: do not create an LVM snapshot, even for LVM root.

Live backup without LVM works for ordinary systems but is not an atomic
snapshot: files changing while being read may be captured in an intermediate
state. Databases and VMs need their own dump/stop hooks or LVM/ZFS/Btrfs snapshots.

`encryption.mode`:

- `auto`: save the LUKS header if LUKS is detected beneath root.
- `required`: refuse to run if LUKS is not detected.
- `none`: refuse to run if LUKS is detected. This guards against the wrong
  profile; it does not disable encryption.

`boot.mode`:

- `auto`: back up `/boot` separately and include `/boot/efi` when available.
- `required`: require a mounted ESP at `/boot/efi`.
- `none`: deliberately omit the separate boot snapshot. Use only when
  `/boot` is guaranteed to be part of the root backup or you have another
  recovery procedure for it.

`home`:

- `auto`: `/home` on the root filesystem is included in `system-root`; a
  separate mount is not copied separately.
- `restic`: allowed only for a separately mounted `/home`; creates a live
  `system-home` snapshot.
- `external`: `/home` is excluded because the user backs it up with another
  backup or synchronization system.
- `exclude`: the same exclusion, without claiming another backup exists.

For `external` and `exclude`, the script refuses to run if `/home` is on the
same filesystem as `/`, preventing an accidental omission of data.
`home.snapshot_mode` currently supports only `live`.

Each run saves the detected topology, selected profile, generic GPT/sfdisk/
LUKS/LVM metadata, and whether separate `/home` was backed up in
`recovery-metadata/layout.json`. If `/home` is on another ordinary block disk
and included with `restic`, its partition table is saved as `home-disk.sfdisk`
and, for GPT, `home-disk.gpt`. A filesystem directly on a whole disk has no
partition table; the manifest records that explicitly without fake GPT files.
An excluded home's partition table is not saved. For an LV or network mount,
the manifest records the source, but the underlying storage needs a separate
recovery procedure.

## Configuration files inside backups

Every new backup saves these files in `recovery-metadata/`:

- `backup-config.json`: the effective profile, including applied defaults;
  saved even when running without `--config`.
- `service-config.json`: the config loaded by the service for that run.
  Direct manual backup does not create this file and removes any stale local
  copy.
- `layout.json`: detected topology, shared `run_tag`, references to saved
  configs in `configuration`, actual retention, and the prune flag.

These files are included in the encrypted `recovery-metadata` snapshot in the
same restic repository. JSONC is normalized to plain JSON without comments.
Values loaded before backup are saved, so editing the config during a run
does not change that run's metadata. Passwords, password-file contents, and
other environment variables are not copied. The service config stores only
the path to its password file.

This applies to new snapshots; existing backups are not modified. After
updating the code, reinstall service files so the wrapper passes its loaded
config, then run a new backup:

```bash
sudo bash scripts/install-system-backup.sh --config "$PWD/configs/service-config.json"
sudo systemctl start system-backup.service
```

Recovery reads these configs from the metadata snapshot of the selected run.
They describe the source machine and service; the target disk and identifiers
are configured separately. Restore validates the archived backup config
against the layout. It does not automatically apply the source service config
to the restored OS.

## `service.json`

See `configs/service-config.example.jsonc`. It contains no password; the
password is stored in a root-only file referenced by `restic_password_file`.
Important fields:

- `backup_mount` and `backup_disk_uuid`: the service verifies that the expected
  disk is mounted, preventing writes into an empty local directory.
- `backup_dir`: backup storage directory within that mount.
- `code_dir`: code directory; defaults to `backup_dir` for compatibility with
  earlier configs.
- `backup_profile`: path to `backup-config.json`; an empty string uses the
  built-in safe `auto` defaults.
- `schedule`: local time in `HH:MM` format.
- `retention`: daily, weekly, and monthly snapshot counts.
- `min_repository_free_gib`: minimum free space required before backup starts.

After editing `service.json`:

```bash
sudo bash scripts/install-system-backup.sh
system-backupctl timer
```

Before initial installation, you can prepare an ignored local
`configs/service-config.json` beside the example. The installer validates and
copies it to `/etc/system-backup/service.json`. After installation, the `/etc`
file is the active copy. Reinstallation preserves it and the password but
regenerates mount dependencies (`Wants`/`After`) and the timer schedule. The
backup disk must still have a UUID-based `fstab` entry with `nofail`.

Do not use the example unchanged: replace every `USER`, mount path, and
`PUT-BACKUP-DISK-UUID-HERE`, then validate it:

```bash
cp configs/service-config.example.jsonc configs/service-config.jsonc
# Edit configs/service-config.jsonc for this machine.
python3 scripts/service-config.py validate --config configs/service-config.jsonc
sudo bash scripts/setup-system-backup.sh --config "$PWD/configs/service-config.jsonc"
```

## Recovery configuration

Restore uses a separate `configs/restore-config.json` or `.jsonc`. See
`configs/restore-config.example.jsonc` and [RECOVERY.md](RECOVERY.md) for
instructions and current limitations.

Create a config interactively after connecting the target disk. For each UUID
and name, choose `original`, `generate`, or an explicit value. Recovery beside
a running source system requires identifiers that do not conflict. The target
is selected independently from archived backup/service configs. Metadata is
read from a snapshot of one complete run, never from the mutable local copy.
Ubuntu x86_64 with LVM/LUKS/ext4/UEFI is supported. Recovery onto a physical disk
and booting the restored OS were verified on 2026-10-09 with generated
identifiers, a new LUKS header, and dracut; other modes still require testing.
