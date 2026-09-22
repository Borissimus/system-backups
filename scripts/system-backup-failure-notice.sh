#!/usr/bin/env bash
# Root-only OnFailure handler. The generated notice is intentionally readable
# by the desktop user and survives reboots until it is acknowledged.
set -euo pipefail

CONFIG=/etc/system-backup/system-backup.conf
STATE_DIR=/var/lib/system-backup
NOTICE="$STATE_DIR/failure-notice"

mkdir -p -m 0755 "$STATE_DIR"

backup_dir="(конфіг ще не доступний)"
if [[ -r "$CONFIG" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG"
  backup_dir="${BACKUP_DIR:-$backup_dir}"
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
  echo "Журнал backup:"
  echo "  tail -n 20 $backup_dir/backup-history.log"
  if [[ -r "$backup_dir/backup-history.log" ]]; then
    echo
    echo "Останній запис:"
    tail -n 1 "$backup_dir/backup-history.log"
  fi
  echo
  echo "Після перегляду приберіть це повідомлення:"
  echo "  system-backupctl acknowledge"
} > "$tmp"
chmod 0644 "$tmp"
mv -f "$tmp" "$NOTICE"
