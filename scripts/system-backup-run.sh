#!/usr/bin/env bash
# Root-only wrapper run by system-backup.service. It keeps policy and failure
# semantics outside backup-system.sh, so the latter stays usable manually.
set -euo pipefail

CONFIG=/etc/system-backup/service.json
CONFIG_HELPER=/usr/local/lib/system-backup/service-config.py
STATE_DIR=/var/lib/system-backup
CACHE_DIR=/var/cache/system-backup/restic

fail() {
  echo "system-backup: ERROR: $*" >&2
  exit 1
}

[[ $EUID -eq 0 ]] || fail "this wrapper must run as root"
[[ -r "$CONFIG" ]] || fail "missing config $CONFIG; run the installer"
[[ -x "$CONFIG_HELPER" ]] || fail "missing config helper $CONFIG_HELPER; run the installer"

config_values=$(python3 "$CONFIG_HELPER" export --include-json --config "$CONFIG") || exit 2
while IFS=$'\t' read -r key value; do
  case "$key" in
    SERVICE_CONFIG_JSON|CODE_DIR|BACKUP_DIR|BACKUP_MOUNT|BACKUP_DISK_UUID|BACKUP_PROFILE|SCHEDULE|KEEP_DAILY|KEEP_WEEKLY|KEEP_MONTHLY|MIN_REPOSITORY_FREE_GIB|RESTIC_PASSWORD_FILE|SUCCESS_CALLBACK|NOTICE_USER)
      printf -v "$key" '%s' "$value"
      ;;
    *) fail "unknown key from service config helper: $key" ;;
  esac
done <<< "$config_values"

: "${BACKUP_DIR:?BACKUP_DIR is not set}"
: "${BACKUP_MOUNT:?BACKUP_MOUNT is not set}"
: "${BACKUP_DISK_UUID:?BACKUP_DISK_UUID is not set}"
: "${RESTIC_PASSWORD_FILE:?RESTIC_PASSWORD_FILE is not set}"
: "${KEEP_DAILY:?KEEP_DAILY is not set}"
: "${KEEP_WEEKLY:?KEEP_WEEKLY is not set}"
: "${KEEP_MONTHLY:?KEEP_MONTHLY is not set}"
: "${MIN_REPOSITORY_FREE_GIB:?MIN_REPOSITORY_FREE_GIB is not set}"
: "${SUCCESS_CALLBACK:?SUCCESS_CALLBACK is not set}"

mountpoint -q "$BACKUP_MOUNT" || fail "Could not create backup: backup disk is disconnected or not mounted at $BACKUP_MOUNT"
mounted_source=$(findmnt -no SOURCE --target "$BACKUP_MOUNT") || fail "failed to detect mount source for $BACKUP_MOUNT"
mounted_uuid=$(blkid -s UUID -o value "$mounted_source" 2>/dev/null || true)
[[ "$mounted_uuid" == "$BACKUP_DISK_UUID" ]] || \
  fail "unexpected disk mounted at $BACKUP_MOUNT (UUID=${mounted_uuid:-unknown}, expected $BACKUP_DISK_UUID)"
backup_mount_actual=$(findmnt -no TARGET --target "$BACKUP_DIR" 2>/dev/null || true)
[[ "$backup_mount_actual" == "$BACKUP_MOUNT" ]] || \
  fail "BACKUP_DIR=$BACKUP_DIR is not on the expected mount $BACKUP_MOUNT"
[[ -x "$CODE_DIR/backup-system.sh" ]] || fail "$CODE_DIR/backup-system.sh not found"
[[ -d "$BACKUP_DIR/restic" && -f "$BACKUP_DIR/restic/config" ]] || \
  fail "Restic repository unavailable at $BACKUP_DIR/restic (backup disk not mounted?)"
[[ -r "$RESTIC_PASSWORD_FILE" ]] || fail "password file unavailable: $RESTIC_PASSWORD_FILE"

available_bytes=$(df --output=avail -B1 "$BACKUP_DIR" | awk 'NR==2 {print $1}')
[[ "$available_bytes" =~ ^[0-9]+$ ]] || fail "failed to determine free space for $BACKUP_DIR"
minimum_bytes=$(( MIN_REPOSITORY_FREE_GIB * 1024 * 1024 * 1024 ))
(( available_bytes >= minimum_bytes )) || \
  fail "backup disk has less than ${MIN_REPOSITORY_FREE_GIB} GiB free"

mkdir -p "$STATE_DIR"
# systemd services intentionally have no $HOME. Give restic a persistent,
# root-only cache instead of falling back to a warning and a temporary cache.
install -d -m 0700 "$CACHE_DIR"
export XDG_CACHE_HOME="$CACHE_DIR"
echo "system-backup: starting backup + retention (daily=$KEEP_DAILY weekly=$KEEP_WEEKLY monthly=$KEEP_MONTHLY)"

export RESTIC_PASSWORD_FILE KEEP_DAILY KEEP_WEEKLY KEEP_MONTHLY
# Capture the exact config loaded above, even if the file changes during backup.
export SYSTEM_BACKUP_SERVICE_CONFIG_JSON="$SERVICE_CONFIG_JSON"
backup_args=(--prune --backup-dir "$BACKUP_DIR")
if [[ -n "$BACKUP_PROFILE" ]]; then
  [[ -r "$BACKUP_PROFILE" ]] || fail "backup profile unavailable: $BACKUP_PROFILE"
  backup_args+=(--config "$BACKUP_PROFILE")
fi
"$CODE_DIR/backup-system.sh" "${backup_args[@]}"

# backup-system.sh intentionally returns 0 for a concurrent-run skip. Only a
# recorded success is allowed to invoke the callback; a skip must never lead
# to a future automatic suspend either.
history="$BACKUP_DIR/backup-history.log"
[[ -r "$history" ]] || fail "backup ended without an accessible history log: $history"
last_record=$(tail -n 1 "$history")
case " $last_record " in
  *" status=success "*)
    echo "system-backup: backup succeeded; running after-success callback"
    [[ -x "$SUCCESS_CALLBACK" ]] || fail "callback is not executable: $SUCCESS_CALLBACK"
    "$SUCCESS_CALLBACK"
    # Suspend/WOL deliberately do not live here yet. They will be added only
    # after explicit hardware testing and a separate reviewed change.
    echo "system-backup: suspend after backup is intentionally disabled"
    ;;
  *" status=skipped "*)
    echo "system-backup: run skipped because another backup is active; callback not invoked"
    ;;
  *)
    fail "latest backup-history.log entry does not confirm success/skip: $last_record"
    ;;
esac
