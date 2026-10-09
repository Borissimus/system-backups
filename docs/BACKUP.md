# system-backups — backup and recovery

Run all command examples from the repository root.

This directory is a self-contained toolkit for system backups with
[restic](https://restic.net/). `backup-system.sh` supports LVM-on-LUKS and
simpler root layouts. Recovery for the tested LVM-on-LUKS UEFI profile is
described in [RECOVERY.md](RECOVERY.md). This document covers configuration
and setup on a new machine. See [CONFIGURATION.md](CONFIGURATION.md) for
profile fields and [AUTOMATION.md](AUTOMATION.md) for service management.

Recovery supports Ubuntu x86_64 with LVM-on-LUKS/UEFI, an LVM snapshot,
a separate `/boot`, and ext4 root/boot. Other supported layouts can be backed
up but require their own recovery procedure. A separate `/home` must also be
restored separately with restic. Physical-disk recovery with new UUIDs and a
new LUKS header, followed by successful OS boot with dracut, was verified on
2026-10-09. Live USB, original UUIDs, and old-header recovery have not yet
been tested on hardware.

## Project contents

| File/directory | Purpose |
|----------------|---------|
| `restic/` | Encrypted, content-addressed restic repository |
| `recovery-metadata/` | Source GPT/LUKS header/LVM config, refreshed with each backup |
| `backup-system.sh` | Create a new backup; documented here |
| `restore-system.sh` | Full recovery onto a target disk |
| `scripts/setup-system-backup.sh` | Complete setup from prepared configs and first backup |
| `scripts/configure-system-backup.py` | Generate matching backup/service configs |
| `configs/examples/backup-config.jsonc` | Annotated root/LUKS/boot/home profile example |
| `configs/examples/service-config.jsonc` | Systemd service settings example without secrets |
| `backup-history.log` | Run history, created automatically |
| `.backup.lock` | Lock against concurrent runs, created automatically |
| `.restore-state.json` | Recovery journal bound to a target and snapshot IDs |
| `configs/examples/restore-config.jsonc` | Recovery target, identifiers, and LUKS header settings |

Code and storage can be separate. `restic/`, `recovery-metadata/`, history,
lock, and recovery state are created in `backup_dir`; without `--backup-dir`,
they are created beside the script. Local configs in `configs/user/` and repository
data are ignored by Git. Only annotated `*.jsonc` files are versioned
in `configs/examples/`. Validators and scripts accept plain JSON and `//` comments on
separate lines; inline comments and `/* ... */` are not supported.
The installed service config is `/etc/system-backup/service.json`.

## Recovery onto a new disk

After connecting the target, create a separate recovery config:

```bash
sudo bash restore-system.sh --interactive \
  --backup-dir /backup/system/system-backups \
  --config "$PWD/configs/user/restore-config.json"
sudo bash restore-system.sh --config "$PWD/configs/user/restore-config.json" --dry-run
```

For recovery beside the running source system, select `generate` for all
identifiers. The `original` defaults suit replacement with the original disk
disconnected. The script reads metadata from one complete backup run, checks
serial/UUID/VG conflicts, and requires confirmation before erasing the target.
Commands, resume, limitations, and the first-test procedure are in
[RECOVERY.md](RECOVERY.md).

## 1. What `backup-system.sh` does

Run it **on an installed, running system**, not from a Live USB; use
`restore-system.sh` for recovery. Each run:

1. Detects the storage layout: `/`, optional VG/LV and LUKS, physical disk,
   `/boot`, and `/boot/efi`. Device names are not hardcoded. The profile in
   `backup-config.json` can require or disallow individual components.
2. Calculates a safe temporary LVM snapshot size:
   `min(free VG space - 1G, 20% of LV size)`, at least 5G. If space is
   insufficient, it reports the shortage and fails.
3. Refreshes `recovery-metadata/`: GPT, sfdisk, blkid, optional LVM config,
   LUKS header, and metadata for an included separate home disk. Recovery
   therefore uses current metadata rather than the first backup's layout.
4. If root is on LVM and the profile does not request `live`, creates a
   snapshot named `root-backup-snapshot-YYYYMMDD-HHMMSS`. This provides a
   **consistent point in time**, not a full copy, and is mounted read-only
   at the stable `/mnt/root-backup-snapshot` path.
5. Runs `restic backup` for root, `/boot`, refreshed metadata, and optionally
   separate `/home`. Tags are `system-root`, `system-boot`, `recovery-metadata`,
   and `system-home`, with a shared unique `run-<timestamp>` tag. Metadata
   includes the effective backup profile and, for service runs, the service
   config. Password contents are never copied into those config snapshots.
6. Removes the temporary snapshot, optionally applies retention (`--prune`),
   and runs a quick repository check (`restic check`, without reading all data).

## 2. Why each run does not duplicate all data

- **Restic is content-addressed.** Each data chunk is stored once by its
  content hash, regardless of the file or snapshot it came from. Existing
  chunks are not uploaded again even if a parent snapshot cannot be found.
- **Automatic parent snapshots.** `restic backup <path>` finds the latest
  snapshot for the same host/path and uses it to identify changed files
  quickly from metadata, avoiding a full reread of unchanged files. The LVM
  snapshot mount path stays `/mnt/root-backup-snapshot` regardless of the
  temporary LV name.
- **LVM snapshots are not full copies.** They use copy-on-write storage for
  consistency during the backup. Space usage depends on data changed during
  the run, which explains the dynamic sizing instead of a fixed allocation
  of hundreds of gigabytes.

## 3. Setting up a new machine

Run commands from the Git project root. The example uses `/backup/system`
as the backup mount and `/backup/system/system-backups` as storage. Substitute
your own paths. Resolve a failed step before proceeding.

### 3.1 Dependencies and system layout

For Ubuntu/Debian:

```bash
sudo apt update
sudo apt install restic lvm2 cryptsetup gdisk fdisk python3 util-linux
lsblk -o NAME,TYPE,SIZE,FSTYPE,UUID,MOUNTPOINTS
findmnt --target /
findmnt --target /home
```

`setup-system-backup.sh` installs missing dependencies itself. To run the
config generator beforehand, install `python3` and util-linux. Python uses
only the standard library; neither `venv` nor `pip install` is needed. The
service uses the system `python3`.

### 3.2 Backup disk

Use a prepared disk with an existing filesystem. Find its UUID with `lsblk`
and add an `/etc/fstab` entry using **your disk's UUID**:

```bash
sudo mkdir -p /backup/system
sudo cp -n /etc/fstab /etc/fstab.before-system-backup
sudoedit /etc/fstab
```

```fstab
UUID=<UUID_BACKUP_DISK> /backup/system ext4 defaults,nosuid,nodev,nofail,x-systemd.device-timeout=10s,x-systemd.mount-timeout=30s 0 2
```

This example assumes ext4. After editing:

```bash
sudo systemctl daemon-reload
sudo mount /backup/system
findmnt --mountpoint /backup/system
df -h /backup/system
```

Verify the source and UUID against the selected disk. The service also checks
the UUID before every run.

### 3.3 Creating system configuration files

Choose an initial profile for the actual root layout:

| `--profile` | Root backup | Encryption beneath root | Boot |
|-------------|-------------|-------------------------|------|
| `lvm-luks-uefi` | LVM snapshot | LUKS required | ESP required |
| `lvm-plain` | LVM snapshot | LUKS must be absent | auto |
| `partition-luks` | Live filesystem | LUKS required | auto |
| `partition-plain` | Live filesystem | LUKS must be absent | auto |
| `auto` | LVM snapshot when available, otherwise live | Auto-detect | auto |

The profile defines requirements checked before backup. Live backup is not an
atomic snapshot of actively changing data. Storage limitations and mode
details are in [CONFIGURATION.md](CONFIGURATION.md).

For `/home`, choose:

- `--home auto` when it is on the root filesystem and already included.
- `--home restic` to include a separate `/home` in **the same restic repository**
  as a `system-home` snapshot.
- `--home exclude` to skip a separately mounted `/home`.
- `--home external` when another system backs up the separate `/home`.

The filesystem boundary matters: a separate `/home` partition on the same
physical disk also requires a choice. For a separate home mount, the generator
requires an explicit `--home` and will not create configs without it.

Example: LVM root inside LUKS, UEFI, and a separate `/home` excluded:

```bash
python3 scripts/configure-system-backup.py \
  --profile lvm-luks-uefi \
  --home exclude \
  --backup-mount /backup/system \
  --backup-dir /backup/system/system-backups \
  --output-dir "$PWD/configs/user" \
  --schedule 20:00 \
  --notice-user "$USER"

python3 scripts/backup-config.py validate --config configs/user/backup-config.json
python3 scripts/service-config.py validate --config configs/user/service-config.json
cat configs/user/backup-config.json
cat configs/user/service-config.json
```

The generator detects the mounted disk UUID and creates:

- `backup-config.json`: root/LUKS/boot/home settings.
- `service-config.json`: code path, storage, UUID, schedule, and retention.

Existing configs are not overwritten. For another configuration, choose a
different `--output-dir` or edit the JSON and validate it again. Code can stay
in your working directory. The generator does not initialize restic or install
the service.

### 3.4 Setup with one script

After creating and validating configs:

```bash
sudo bash scripts/setup-system-backup.sh --config "$PWD/configs/user/service-config.json"
```

This is the primary installation method. It:

1. Installs missing dependencies with `apt-get` on Ubuntu/Debian.
2. Checks configs, device, and UUID; adds an `/etc/fstab` entry when missing
   and mounts the disk. Matching existing entries become optional (`nofail`)
   with bounded timeouts. It saves `/etc/fstab.before-system-backup` before
   changing fstab and refuses to replace conflicting entries.
3. Checks free space and the backup plan.
4. Disables the timer during setup and installs runtime files under
   `/usr/local/lib/system-backup`, the service config and effective backup
   profile under `/etc/system-backup`, and a root-only password file. It
   prompts for a password if none exists.
5. Initializes a new restic repository or preserves an existing one. A
   nonempty directory without restic `config` requires manual inspection.
6. Runs `--dry-run`, the first service backup, and checks for a newly recorded
   `status=success` in the history log.
7. Enables the daily timer using `schedule` only after success.

No formatting or partitioning is performed. The connected backup disk must
already contain ext4, XFS, or Btrfs. Config generation requires a mounted disk;
a mount created by a file manager can be used in the config, and setup adds it
to fstab. A stable path as in section 3.2 is more convenient for the service.

Repeated setup applies the supplied service config, preserves the password
and repository, runs another backup, and does not duplicate the fstab entry.
If setup fails after disabling the timer, it stays disabled; fix the cause
and repeat the command. Conflicting mounts or fstab entries require review.

To install and run the first backup without enabling the schedule:

```bash
sudo bash scripts/setup-system-backup.sh \
  --config "$PWD/configs/user/service-config.json" --no-enable
```

Follow the journal from another terminal during backup:

```bash
sudo journalctl -u system-backup.service -f
```

After success, proceed to section 3.7. The next two sections describe the
manual equivalent for troubleshooting.

### 3.5 Manual setup: plan, password, and repository

Inspect the plan before backup, without a repository password:

```bash
sudo bash backup-system.sh \
  --config "$PWD/configs/user/backup-config.json" \
  --backup-dir /backup/system/system-backups \
  --print-plan
```

Prepare storage and install the service without enabling the timer:

```bash
sudo install -d -m 0700 /backup/system/system-backups
sudo bash scripts/install-system-backup.sh --config "$PWD/configs/user/service-config.json"
```

The installer asks for the restic password and saves it in the root-only
`/etc/system-backup/restic.pass`. An existing password file is preserved.
Keep the password available for recovery as well. The installer adds a
failure-notice hook to interactive Bash for `notice_user`.

Run this only for a **new** restic repository:

```bash
sudo restic --password-file /etc/system-backup/restic.pass \
  -r /backup/system/system-backups/restic init
```

For an existing repository, skip `init` and use its password. If you change
`restic_password_file` in the service config, substitute that path in the
restic commands below.

### 3.6 Manual setup: validation and first backup

```bash
sudo env RESTIC_PASSWORD_FILE=/etc/system-backup/restic.pass \
  bash backup-system.sh \
  --config "$PWD/configs/user/backup-config.json" \
  --backup-dir /backup/system/system-backups \
  --dry-run

sudo systemctl start system-backup.service
```

Backup `--print-plan` and `--dry-run` do not create a lock or history entries.
Dry-run also checks the password and repository availability.
`systemctl start` waits for the backup to finish. In another terminal:

```bash
sudo journalctl -u system-backup.service -f
```

After completion, check `status=success` and snapshots:

```bash
sudo tail -n 1 /backup/system/system-backups/backup-history.log
sudo restic --password-file /etc/system-backup/restic.pass \
  -r /backup/system/system-backups/restic snapshots
```

Expected tags: `system-root`, `system-boot`, `recovery-metadata`, and
`system-home` when `home.mode=restic`. All snapshots from a run share one
`run-<timestamp>` tag.

### 3.7 Daily schedule and further checks

After the first successful backup:

```bash
sudo systemctl enable --now system-backup.timer
systemctl list-timers system-backup.timer --all --no-pager
```

`schedule` specifies local time. Missed runs are not caught up
(`Persistent=false`). `inactive (dead)` after a successful run is normal for
a `Type=oneshot` service.

To verify all data in addition to the usual `restic check`:

```bash
sudo restic --password-file /etc/system-backup/restic.pass \
  -r /backup/system/system-backups/restic check --read-data
```

Repository checks do not replace a recovery test on another disk. After
reviewing a previous failure notice, remove it with
`scripts/system-backupctl.sh acknowledge`.

### 3.8 Editing configuration files

The service reads its installed `/etc/system-backup/backup.json` on every run.
Local profiles in `configs/user/` are installation inputs. After editing a
local profile, validate it, inspect `--print-plan`, and reinstall with the
local service config to copy the changes into `/etc`. Without `--config`,
a direct manual backup uses built-in `auto` defaults even if a local config exists.

Apply an edited local service config explicitly:

```bash
python3 scripts/service-config.py validate --config configs/user/service-config.json
sudo bash scripts/install-system-backup.sh --config "$PWD/configs/user/service-config.json"
systemctl list-timers system-backup.timer --all --no-pager
```

The active service config is `/etc/system-backup/service.json`. If editing
it directly, reinstall without `--config`:

```bash
sudoedit /etc/system-backup/service.json
sudo bash scripts/install-system-backup.sh
```

Installation without `--enable` does not enable a new timer; an already
enabled timer stays enabled. Installed backups use their runtime under
`/usr/local/lib/system-backup` and private configs under `/etc/system-backup`.
The checkout and local user configs can be moved after installation.
Custom password files and custom success callbacks must remain available at
their configured paths.

### Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `KEEP_DAILY` | `7` | Daily snapshots retained with `--prune` |
| `KEEP_WEEKLY` | `4` | Weekly snapshots retained |
| `KEEP_MONTHLY` | `6` | Monthly snapshots retained |
| `RESTIC_PASSWORD` | — | Direct repository password; avoid embedding in unit files |
| `RESTIC_PASSWORD_FILE` | — | Password-file path; recommended for unattended runs |
| `RESTIC_PASSWORD_COMMAND` | — | Command that outputs the password; secret-manager integration |

If none of the three `RESTIC_PASSWORD*` variables is set, the script prompts
interactively with `read -rs`. If one is set, the prompt is skipped, allowing
unattended service operation.

## 4. Concurrent runs and locking

Before repository checks in a real backup, the script acquires an exclusive
`flock -n` on `.backup.lock`. If another run holds the lock:

- No backup is performed and storage devices are unchanged.
- A history entry records `status=skipped reason=already_running`.
- The script exits with **0**. This is an expected skip; the next scheduled
  trigger can try again.

This prevents overlapping cron/manual runs or a new timer run while the
previous backup is still active.

If power fails and leaves an LV named `root-backup-snapshot-YYYYMMDD-HHMMSS`,
the next run stops before creating another snapshot. Inspect and remove the
stale LV manually; automatic deletion could destroy a useful consistent copy.
An older LV with a different name is not touched.

## 5. Run history (`backup-history.log`)

An append-only `key=value` text format records one event per line. It can be
read without dependencies using `grep`, `awk`, or `cut`, or parsed in Python.

**Common fields:** `ts` (ISO-8601), `tag` (the run tag, or `-` before it exists),
`status` (`success`/`failed`/`skipped`), `duration_s` (seconds since script start),
and `step` (the current step, including the failure location).

**Additional fields by status:**

- `success`: `root_added`, `home_added`, `boot_added`, `meta_added`,
  `total_added` (bytes), `root_snapshot`, `home_snapshot`, `boot_snapshot`,
  `meta_snapshot`, `home_mode`, and `pruned` (`yes`/`no`).
- `failed`: `exit_code`.
- `skipped`: `reason=already_running`.

Examples:

```text
ts=2026-09-17T06:15:32+03:00 tag=run-20260917-061532 status=success duration_s=142 step=done root_added=47185920 home_added=0 boot_added=2048 meta_added=8192 total_added=47196160 root_snapshot=abcd1234 home_snapshot=- boot_snapshot=ef567890 meta_snapshot=12ab34cd home_mode=auto pruned=no
ts=2026-09-18T03:00:05+03:00 tag=- status=skipped duration_s=0 step=verify_repo reason=already_running
ts=2026-09-19T03:00:12+03:00 tag=run-20260919-030012 status=failed duration_s=18 step=create_snapshot exit_code=1
```

Possible failure steps: `verify_repo`, `detect_layout`, `snapshot_sizing`,
`restic_password`, `refresh_metadata`, `create_snapshot`, `backup_root`,
`backup_home`, `backup_boot`, `backup_metadata`, `remove_snapshot`, `prune`,
and `check_repo`.

Useful queries for monitoring:

```bash
# Latest event of any status.
tail -1 backup-history.log

# Latest successful backup.
grep 'status=success' backup-history.log | tail -1

# Failures during the last week.
awk -v since="$(date -d '7 days ago' -Iseconds)" '$1 > "ts="since' backup-history.log | grep -c 'status=failed'
```

## 6. Unattended operation with systemd

The service, timer, root-only password, and failure notice are implemented.
Section 3 covers disk preparation, configs, repository initialization, and
first backup. Manage the installed service as described in
[AUTOMATION.md](AUTOMATION.md).

The timer does not catch up on missed runs (`Persistent=false`). `OnFailure`
creates a message for the next interactive Bash session. The wrapper verifies
the expected disk UUID and will not back up into an empty local directory.
See `AUTOMATION.md` and `CONFIGURATION.md` for control commands and details.

A complete `check --read-data`, described in section 3.7, is not automatically
run after each backup.

## 7. Snapshot sizing and free VG space

The dynamic calculation, `min(free space - 1G, 20% of LV size)` with a 5G
minimum, is conservative. A snapshot only needs space for changes made
**during the backup**, typically minutes, rather than the entire LV.
With approximately 200 GiB free in the VG, the formula generally allocates
20% of LV size, leaving much of the free space untouched. When space becomes
too low (`< 6G`), the script reports the shortage and fails instead of
creating an undersized snapshot that could overflow and break consistency.

Missing backup disks do not block OS startup when their fstab entries use
`nofail`. The service attempts the mount through `Wants`/`After`; if unavailable,
the wrapper reports that the backup could not be created, fails, and triggers
the failure notice. Mount and UUID checks prevent writing into the system
disk directory in place of the missing repository.

### Migrating an existing installed service

To update runtime files and migrate a checkout profile reference while
preserving active settings and the repository password:

```bash
sudo bash scripts/install-system-backup.sh
sudo python3 - <<'PY'
import json
from pathlib import Path
config = json.loads(Path('/etc/system-backup/service.json').read_text())
print('code_dir:', config['code_dir'])
print('backup_profile:', config['backup_profile'])
PY
systemctl cat system-backup.service
```

Expect `/usr/local/lib/system-backup`, `/etc/system-backup/backup.json`, and
`Wants=backup-system.mount` for the example mount. Installation does not run
a backup. Only after verifying the active paths may you remove old local
`backup-config.json` symlinks. Reinstallation without `--config` preserves
installed profile edits; passing a local service config explicitly reapplies
that config and its referenced profile.

If an older installed config references a missing `backup-config.json` in the
checkout root or directly under `configs/`, the installer checks its relocated
counterpart under `configs/user/`. This migration is limited to known old paths;
unrelated missing profiles still fail instead of falling back to defaults.
