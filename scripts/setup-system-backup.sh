#!/usr/bin/env bash
# Complete setup from an existing service config. No formatting or partitioning.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: sudo bash scripts/setup-system-backup.sh --config FILE [--no-enable]

Installs missing Ubuntu/Debian dependencies, configures the backup mount in
fstab, installs the service, prepares its password, initializes a new Restic
repository if needed, validates the backup plan, runs one backup, and enables
the timer only after a recorded success. Existing passwords/repositories are
preserved. --no-enable leaves the timer disabled after the backup.
EOF
}

CONFIG=""
ENABLE=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      shift
      [[ $# -gt 0 ]] || { echo '--config requires a file' >&2; exit 2; }
      CONFIG=$(realpath -- "$1") ;;
    --no-enable) ENABLE=0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done
[[ -n "$CONFIG" ]] || { usage >&2; exit 2; }
if [[ $EUID -ne 0 ]]; then
  args=(--config "$CONFIG")
  (( ENABLE == 1 )) || args+=(--no-enable)
  exec sudo bash "$0" "${args[@]}"
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STEP=dependencies
fail() { echo "system-backup setup: $*" >&2; exit 1; }
trap 'ec=$?; echo "Setup failed at step: $STEP (exit $ec). Timer was not enabled by this run." >&2; exit "$ec"' ERR

# Install only when a required command is missing. Python needs no pip packages.
missing=0
for tool in python3 restic lvs pvs vgs lvcreate lvremove vgcfgbackup cryptsetup sgdisk sfdisk findmnt mountpoint flock blkid lsblk; do
  command -v "$tool" >/dev/null 2>&1 || missing=1
done
if (( missing )); then
  command -v apt-get >/dev/null 2>&1 || fail 'Install python3, restic, lvm2, cryptsetup, gdisk, fdisk and util-linux for your distribution first.'
  apt-get update
  apt-get install -y python3 restic lvm2 cryptsetup gdisk fdisk util-linux
fi
command -v systemctl >/dev/null 2>&1 || fail 'systemd is required.'

STEP=configuration
config_values=$(python3 "$SCRIPT_DIR/service-config.py" export --config "$CONFIG")
while IFS=$'\t' read -r key value; do
  case "$key" in
    CODE_DIR|BACKUP_DIR|BACKUP_MOUNT|BACKUP_DISK_UUID|BACKUP_PROFILE|RESTIC_PASSWORD_FILE|SCHEDULE|MIN_REPOSITORY_FREE_GIB)
      printf -v "$key" '%s' "$value" ;;
  esac
done <<< "$config_values"
[[ "$BACKUP_MOUNT" != / && "$BACKUP_DIR" != / ]] || fail 'Choose a separate backup disk mount, not /.'
[[ -x "$CODE_DIR/backup-system.sh" ]] || fail "Backup code unavailable at $CODE_DIR"
profile_args=()
if [[ -n "$BACKUP_PROFILE" ]]; then
  python3 "$CODE_DIR/scripts/backup-config.py" validate --config "$BACKUP_PROFILE"
  profile_args=(--config "$BACKUP_PROFILE")
fi

STEP=mount
backup_device="/dev/disk/by-uuid/$BACKUP_DISK_UUID"
[[ -b "$backup_device" ]] || fail "Connect the backup disk with UUID=$BACKUP_DISK_UUID."
filesystem=$(blkid -s TYPE -o value "$backup_device")
case "$filesystem" in
  ext4|xfs|btrfs) ;;
  *) fail "Unsupported backup filesystem: $filesystem" ;;
esac
if mountpoint -q "$BACKUP_MOUNT"; then
  mounted_uuid=$(findmnt -n -o UUID --mountpoint "$BACKUP_MOUNT")
  [[ "$mounted_uuid" == "$BACKUP_DISK_UUID" ]] || fail "Another disk is mounted at $BACKUP_MOUNT."
fi
python3 "$SCRIPT_DIR/setup-backup-mount.py" --config "$CONFIG" --filesystem "$filesystem"
mkdir -p -- "$BACKUP_MOUNT"
systemctl daemon-reload
if ! mountpoint -q "$BACKUP_MOUNT"; then
  mount -- "$BACKUP_MOUNT"
fi
mounted_uuid=$(findmnt -n -o UUID --mountpoint "$BACKUP_MOUNT")
[[ "$mounted_uuid" == "$BACKUP_DISK_UUID" ]] || fail 'Mounted UUID does not match the config.'
mkdir -p -- "$BACKUP_DIR"
actual_mount=$(findmnt -n -o TARGET --target "$BACKUP_DIR")
[[ "$actual_mount" == "$BACKUP_MOUNT" ]] || fail 'Backup directory is outside the expected mount.'
available_bytes=$(df --output=avail -B1 "$BACKUP_DIR" | awk 'NR==2 {print $1}')
[[ "$available_bytes" =~ ^[0-9]+$ ]] || fail 'Cannot determine free space.'
(( available_bytes >= MIN_REPOSITORY_FREE_GIB * 1024 * 1024 * 1024 )) || fail 'Insufficient free space on the backup disk.'

STEP=plan
bash "$CODE_DIR/backup-system.sh" "${profile_args[@]}" --backup-dir "$BACKUP_DIR" --print-plan

STEP=service
# Pause scheduled runs during setup. A failed setup leaves the timer disabled.
systemctl disable --now system-backup.timer 2>/dev/null || true
bash "$SCRIPT_DIR/install-system-backup.sh" --config "$CONFIG"

STEP=repository
[[ -r "$RESTIC_PASSWORD_FILE" ]] || fail 'Restic password file is not readable.'
if [[ ! -f "$BACKUP_DIR/restic/config" ]]; then
  # Do not initialize over partial or unrelated contents.
  if [[ -e "$BACKUP_DIR/restic" ]]; then
    [[ -d "$BACKUP_DIR/restic" ]] || fail 'Restic path exists and is not a directory.'
    [[ -z "$(find "$BACKUP_DIR/restic" -mindepth 1 -maxdepth 1 -print -quit)" ]] || fail 'Restic directory is non-empty but lacks config; inspect it manually.'
  fi
  env -u RESTIC_PASSWORD -u RESTIC_PASSWORD_COMMAND \
    restic --password-file "$RESTIC_PASSWORD_FILE" -r "$BACKUP_DIR/restic" init
else
  echo 'Existing Restic repository preserved.'
fi

STEP=dry_run
env -u RESTIC_PASSWORD -u RESTIC_PASSWORD_COMMAND RESTIC_PASSWORD_FILE="$RESTIC_PASSWORD_FILE" \
  bash "$CODE_DIR/backup-system.sh" "${profile_args[@]}" --backup-dir "$BACKUP_DIR" --dry-run

STEP=first_backup
before=$(tail -n 1 "$BACKUP_DIR/backup-history.log" 2>/dev/null || true)
systemctl start system-backup.service
record=$(tail -n 1 "$BACKUP_DIR/backup-history.log")
[[ "$record" != "$before" && " $record " == *' status=success '* ]] || fail 'No new successful backup recorded; timer remains disabled.'
echo "$record"

STEP=timer
if (( ENABLE )); then
  systemctl enable --now system-backup.timer
  systemctl list-timers system-backup.timer --all --no-pager
  echo "Setup complete. Daily backup at $SCHEDULE local time."
else
  echo 'Setup complete. Backup succeeded; timer remains disabled (--no-enable).'
fi
