# Automated backups with systemd

The service runs a daily unattended backup (20:00 by default). Suspend,
Wake-on-LAN, and BIOS RTC wakeup are intentionally not implemented; they
will be added only after separate hardware wakeup tests.

## Components

- `system-backup.service` runs `backup-system.sh --prune` as root.
- `system-backup.timer` uses the time configured in `service.json` and does
  not catch up on missed runs.
- `system-backup-failure.service` creates `/var/lib/system-backup/failure-notice`.
- `scripts/system-backup-after-success.sh` is a safe callback placeholder.
- `scripts/system-backupctl.sh` handles installation, manual runs, and control.

## Complete setup

After creating the configuration files:

```bash
sudo bash scripts/setup-system-backup.sh --config "$PWD/configs/service-config.json"
```

The script prepares the mount, dependencies, service, password, and restic
repository, runs the first backup, and enables the timer only after success.
Add `--no-enable` to leave the timer disabled. Repeated setup preserves the
existing password and repository and runs another backup. See
[BACKUP.md](BACKUP.md#34-setup-with-one-script).

## Manual activation

Preparing a new machine and running `restic init` / `--dry-run` are described
in [BACKUP.md](BACKUP.md#3-setting-up-a-new-machine).

```bash
# 0. Mount the backup disk by UUID using /etc/fstab.
#    Create the configs and prepare the restic repository as in BACKUP.md.

# 1. Install the files and root-only password without enabling the timer.
#    For a new repository, run restic init after installation; see BACKUP.md.
scripts/system-backupctl.sh install --config "$PWD/configs/service-config.json"

# 2. Run the service once and inspect its journal.
scripts/system-backupctl.sh run
scripts/system-backupctl.sh logs

# 3. Enable the timer only after a successful backup.
scripts/system-backupctl.sh enable
scripts/system-backupctl.sh timer
```

After editing `/etc/system-backup/service.json`, run
`scripts/system-backupctl.sh install` again. It preserves the JSON and
password but regenerates the mount dependencies and schedule.

Retention, schedule, backup disk UUID/mount, and profile path are configured
in `/etc/system-backup/service.json`. The default retention keeps 7 daily,
4 weekly, and 6 monthly snapshots. Each backup runs `prune`, which frees only
data no longer referenced by any retained snapshot.

If the service fails, a generic source hook in `~/.bashrc` displays the
saved `failure-notice` in the next interactive Bash session. The notice
includes recent systemd journal entries, so the failure reason remains
available even when the backup disk is disconnected and `backup-history.log`
cannot be read. After reviewing it:

```bash
scripts/system-backupctl.sh acknowledge
```

## Mounting the backup disk

Use systemd mounts from `/etc/fstab`, rather than relying solely on a file
manager (udisks). Use a UUID instead of an unstable `/dev/sdX` name, and
`nofail` so a missing backup disk does not block OS startup:

```fstab
UUID=<backup_disk_uuid> <backup_mount> ext4 defaults,nosuid,nodev,nofail,x-systemd.device-timeout=10s,x-systemd.mount-timeout=30s 0 2
```

The installer generates `Wants` and `After` for the mount unit derived from
`backup_mount` in JSON, escaping the path with `systemd-escape`.
The service attempts to mount a disk connected after boot before starting
the backup. If the disk is missing, the wrapper fails and creates the usual
failure notice rather than writing into an empty directory on the system disk.
