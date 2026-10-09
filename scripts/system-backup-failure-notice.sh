#!/usr/bin/env bash
# Root-only OnFailure handler. The generated notice is intentionally readable
# by the desktop user and survives reboots until it is acknowledged.
set -euo pipefail

CONFIG=/etc/system-backup/service.json
CONFIG_HELPER=/usr/local/lib/system-backup/service-config.py
STATE_DIR=/var/lib/system-backup
NOTICE="$STATE_DIR/failure-notice"

mkdir -p -m 0755 "$STATE_DIR"

backup_dir="(configuration not yet available)"
if [[ -r "$CONFIG" && -x "$CONFIG_HELPER" ]]; then
  while IFS=$'\t' read -r key value; do
    [[ "$key" == BACKUP_DIR ]] && backup_dir="$value"
  done < <(python3 "$CONFIG_HELPER" export --config "$CONFIG" 2>/dev/null || true)
fi

tmp=$(mktemp "$STATE_DIR/.failure-notice.XXXXXX")
{
  echo "⚠️  The last automatic system backup failed."
  echo "Recorded at: $(date -Iseconds)"
  echo
  echo "Service status:"
  echo "  sudo systemctl status system-backup.service --no-pager"
  echo "Service journal:"
  echo "  sudo journalctl -u system-backup.service -e --no-pager"
  echo
  echo "Recent systemd journal entries (available without the backup disk):"
  journalctl -u system-backup.service -n 16 --no-pager --output=short-iso 2>&1 || \
    echo "  Could not read the journal. See the command above."
  echo
  if [[ -r "$backup_dir/backup-history.log" ]]; then
    echo "Backup history:"
    echo "  tail -n 20 $backup_dir/backup-history.log"
    echo
    echo "Latest entry:"
    tail -n 1 "$backup_dir/backup-history.log"
  else
    echo "backup-history.log unavailable: backup disk is not mounted or the path is missing."
    echo "After reconnecting the disk:"
    echo "  tail -n 20 $backup_dir/backup-history.log"
  fi
  echo
  echo "After reviewing, remove this notice:"
  echo "  system-backupctl acknowledge"
} > "$tmp"
chmod 0644 "$tmp"
mv -f "$tmp" "$NOTICE"
