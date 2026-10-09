# system-backups

Configurable system backups with restic and system recovery for Ubuntu.
Backup profiles describe root, encryption, boot, and home handling; service
configs define storage, retention, and the daily schedule.

## Features

- Incremental, encrypted restic backups with optional LVM snapshots.
- Separate boot/EFI and optional home snapshots in the same repository.
- Systemd scheduling and persistent failure notices in interactive Bash.
- Recovery with original, generated, or explicit UUIDs and storage names.
- Recovery dry-run, disk identity/conflict checks, and resumable execution.

Recovery currently supports Ubuntu x86_64 UEFI with ext4 root on LVM inside
LUKS, separate ext4 boot, and FAT32 EFI. Recovery with generated identifiers,
a new LUKS header, and dracut was tested on a physical disk through successful
OS boot. See the [recovery guide](docs/RECOVERY.md) for limits and other modes.

## Quick start

Run commands from the repository root. Prepare and mount a backup disk first;
replace these example paths and select the profile and home mode for your system.

```bash
python3 scripts/configure-system-backup.py \
  --profile lvm-luks-uefi \
  --home exclude \
  --backup-mount /backup/system \
  --backup-dir /backup/system/system-backups \
  --schedule 23:00 \
  --notice-user "$USER"

sudo bash scripts/setup-system-backup.sh \
  --config "$PWD/configs/user/service-config.json"
```

Setup installs missing dependencies, prepares the service and repository,
runs the first backup, and enables the timer only after success. Add
`--no-enable` to leave the timer disabled. User configs in `configs/user/` are
ignored by Git; annotated `*.jsonc` files are provided in `configs/examples/`. Python uses
only the standard library, with no virtual environment or pip packages required.

## Documentation

- [Backup setup and manual operation](docs/BACKUP.md)
- [Recovery procedure and verification](docs/RECOVERY.md)
- [Configuration generator and field reference](docs/CONFIGURATION.md)
- [Systemd scheduling and failure notices](docs/AUTOMATION.md)

Configuration files are separated by purpose:

```text
configs/
├── examples/   # Versioned, annotated JSONC templates
└── user/       # Local configuration files, ignored by Git
```
