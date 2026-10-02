#!/usr/bin/env bash
# Root-only OnFailure handler. The generated notice is intentionally readable
# by the desktop user and survives reboots until it is acknowledged.
set -euo pipefail

CONFIG=/etc/system-backup/service.json
CONFIG_HELPER=/usr/local/lib/system-backup/service-config.py
STATE_DIR=/var/lib/system-backup
NOTICE="$STATE_DIR/failure-notice"

mkdir -p -m 0755 "$STATE_DIR"

backup_dir="(конфіг ще не доступний)"
if [[ -r "$CONFIG" && -x "$CONFIG_HELPER" ]]; then
  while IFS=$'\t' read -r key value; do
    [[ "$key" == BACKUP_DIR ]] && backup_dir="$value"
  done < <(python3 "$CONFIG_HELPER" export --config "$CONFIG" 2>/dev/null || true)
fi

tmp=$(mktemp "$STATE_DIR/.failure-notice.XXXXXX")
{
  echo "⚠️  Останній автоматичний system backup завершився з помилкою."
  echo "Час фіксації: $(date -Iseconds)"
  echo
  echo "Стан служби:"
  echo "  sudo systemctl status system-backup.service --no-pager"
  echo "Журнал служби:"
  echo "  sudo journalctl -u system-backup.service -e --no-pager"
  echo
  echo "Останні рядки systemd journal (доступні без backup-диску):"
  journalctl -u system-backup.service -n 16 --no-pager --output=short-iso 2>&1 || \
    echo "  Не вдалося прочитати journal. Див. команду вище."
  echo
  if [[ -r "$backup_dir/backup-history.log" ]]; then
    echo "Журнал backup:"
    echo "  tail -n 20 $backup_dir/backup-history.log"
    echo
    echo "Останній запис:"
    tail -n 1 "$backup_dir/backup-history.log"
  else
    echo "backup-history.log недоступний: backup-диск не змонтований або шлях відсутній."
    echo "Після повернення диска:"
    echo "  tail -n 20 $backup_dir/backup-history.log"
  fi
  echo
  echo "Після перегляду приберіть це повідомлення:"
  echo "  system-backupctl acknowledge"
} > "$tmp"
chmod 0644 "$tmp"
mv -f "$tmp" "$NOTICE"
