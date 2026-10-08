#!/usr/bin/env bash
# Root-only wrapper run by system-backup.service. It keeps policy and failure
# semantics outside backup-system.sh, so the latter stays usable manually.
set -euo pipefail

CONFIG=/etc/system-backup/service.json
CONFIG_HELPER=/usr/local/lib/system-backup/service-config.py
STATE_DIR=/var/lib/system-backup
CACHE_DIR=/var/cache/system-backup/restic

fail() {
  echo "system-backup: ПОМИЛКА: $*" >&2
  exit 1
}

[[ $EUID -eq 0 ]] || fail "цей wrapper має працювати лише від root"
[[ -r "$CONFIG" ]] || fail "відсутній конфіг $CONFIG; запустіть installer"
[[ -x "$CONFIG_HELPER" ]] || fail "відсутній config helper $CONFIG_HELPER; запустіть installer"

config_values=$(python3 "$CONFIG_HELPER" export --config "$CONFIG") || exit 2
while IFS=$'\t' read -r key value; do
  case "$key" in
    CODE_DIR|BACKUP_DIR|BACKUP_MOUNT|BACKUP_DISK_UUID|BACKUP_PROFILE|SCHEDULE|KEEP_DAILY|KEEP_WEEKLY|KEEP_MONTHLY|MIN_REPOSITORY_FREE_GIB|RESTIC_PASSWORD_FILE|SUCCESS_CALLBACK|NOTICE_USER)
      printf -v "$key" '%s' "$value"
      ;;
    *) fail "невідомий ключ від service config helper: $key" ;;
  esac
done <<< "$config_values"

: "${BACKUP_DIR:?BACKUP_DIR не задано}"
: "${BACKUP_MOUNT:?BACKUP_MOUNT не задано}"
: "${BACKUP_DISK_UUID:?BACKUP_DISK_UUID не задано}"
: "${RESTIC_PASSWORD_FILE:?RESTIC_PASSWORD_FILE не задано}"
: "${KEEP_DAILY:?KEEP_DAILY не задано}"
: "${KEEP_WEEKLY:?KEEP_WEEKLY не задано}"
: "${KEEP_MONTHLY:?KEEP_MONTHLY не задано}"
: "${MIN_REPOSITORY_FREE_GIB:?MIN_REPOSITORY_FREE_GIB не задано}"
: "${SUCCESS_CALLBACK:?SUCCESS_CALLBACK не задано}"

mountpoint -q "$BACKUP_MOUNT" || fail "backup-диск не змонтовано у $BACKUP_MOUNT"
mounted_source=$(findmnt -no SOURCE --target "$BACKUP_MOUNT") || fail "не вдалося визначити source mount $BACKUP_MOUNT"
mounted_uuid=$(blkid -s UUID -o value "$mounted_source" 2>/dev/null || true)
[[ "$mounted_uuid" == "$BACKUP_DISK_UUID" ]] || \
  fail "у $BACKUP_MOUNT змонтовано не очікуваний диск (UUID=${mounted_uuid:-невідомий}, очікувався $BACKUP_DISK_UUID)"
backup_mount_actual=$(findmnt -no TARGET --target "$BACKUP_DIR" 2>/dev/null || true)
[[ "$backup_mount_actual" == "$BACKUP_MOUNT" ]] || \
  fail "BACKUP_DIR=$BACKUP_DIR не лежить на очікуваному mount $BACKUP_MOUNT"
[[ -x "$CODE_DIR/backup-system.sh" ]] || fail "не знайдено $CODE_DIR/backup-system.sh"
[[ -d "$BACKUP_DIR/restic" && -f "$BACKUP_DIR/restic/config" ]] || \
  fail "Restic repository недоступний у $BACKUP_DIR/restic (backup-диск не змонтовано?)"
[[ -r "$RESTIC_PASSWORD_FILE" ]] || fail "файл пароля недоступний: $RESTIC_PASSWORD_FILE"

available_bytes=$(df --output=avail -B1 "$BACKUP_DIR" | awk 'NR==2 {print $1}')
[[ "$available_bytes" =~ ^[0-9]+$ ]] || fail "не вдалося визначити вільне місце для $BACKUP_DIR"
minimum_bytes=$(( MIN_REPOSITORY_FREE_GIB * 1024 * 1024 * 1024 ))
(( available_bytes >= minimum_bytes )) || \
  fail "на backup-диску менше ${MIN_REPOSITORY_FREE_GIB} GiB вільного місця"

mkdir -p "$STATE_DIR"
# systemd services intentionally have no $HOME. Give restic a persistent,
# root-only cache instead of falling back to a warning and a temporary cache.
install -d -m 0700 "$CACHE_DIR"
export XDG_CACHE_HOME="$CACHE_DIR"
echo "system-backup: запускаю backup + retention (daily=$KEEP_DAILY weekly=$KEEP_WEEKLY monthly=$KEEP_MONTHLY)"

export RESTIC_PASSWORD_FILE KEEP_DAILY KEEP_WEEKLY KEEP_MONTHLY
backup_args=(--prune --backup-dir "$BACKUP_DIR")
if [[ -n "$BACKUP_PROFILE" ]]; then
  [[ -r "$BACKUP_PROFILE" ]] || fail "backup profile недоступний: $BACKUP_PROFILE"
  backup_args+=(--config "$BACKUP_PROFILE")
fi
"$CODE_DIR/backup-system.sh" "${backup_args[@]}"

# backup-system.sh intentionally returns 0 for a concurrent-run skip. Only a
# recorded success is allowed to invoke the callback; a skip must never lead
# to a future automatic suspend either.
history="$BACKUP_DIR/backup-history.log"
[[ -r "$history" ]] || fail "backup завершився без доступного журналу $history"
last_record=$(tail -n 1 "$history")
case " $last_record " in
  *" status=success "*)
    echo "system-backup: backup успішний; викликаю after-success callback"
    [[ -x "$SUCCESS_CALLBACK" ]] || fail "callback не виконуваний: $SUCCESS_CALLBACK"
    "$SUCCESS_CALLBACK"
    # Suspend/WOL deliberately do not live here yet. They will be added only
    # after explicit hardware testing and a separate reviewed change.
    echo "system-backup: сон після backup наразі навмисно вимкнено"
    ;;
  *" status=skipped "*)
    echo "system-backup: запуск пропущено через активний backup; callback не викликаю"
    ;;
  *)
    fail "останній рядок backup-history.log не підтверджує success/skip: $last_record"
    ;;
esac
