#!/usr/bin/env bash
# User-facing controller for the installed automation.
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
NOTICE=/var/lib/system-backup/failure-notice

usage() {
  cat <<'EOF'
Usage: scripts/system-backupctl.sh COMMAND

Commands:
  install       Install/update files; timer stays disabled
  enable        Enable and start the daily 20:00 timer
  disable       Disable and stop the timer
  run           Start one backup service now; follow it with `logs`
  status        Show service, timer, and unresolved failure notice
  logs          Show the latest service journal
  timer         List the next planned timer activation
  notice        Print the pending failure notice, if any
  acknowledge   Remove the pending failure notice after review
EOF
}

command=${1:-}
case "$command" in
  install) exec sudo bash "$REPO_DIR/scripts/install-system-backup.sh" ;;
  enable) sudo systemctl enable --now system-backup.timer ;;
  disable) sudo systemctl disable --now system-backup.timer ;;
  run) sudo systemctl start system-backup.service ;;
  status)
    systemctl status system-backup.timer system-backup.service --no-pager || true
    [[ -r "$NOTICE" ]] && { echo; cat "$NOTICE"; }
    ;;
  logs) sudo journalctl -u system-backup.service -u system-backup-failure.service -e --no-pager ;;
  timer) systemctl list-timers system-backup.timer --all --no-pager ;;
  notice) [[ -r "$NOTICE" ]] && cat "$NOTICE" || echo "Невирішених backup-помилок немає." ;;
  acknowledge) sudo rm -f "$NOTICE" && echo "Failure notice прибрано." ;;
  -h|--help|help|"") usage ;;
  *) echo "Невідома команда: $command" >&2; usage >&2; exit 2 ;;
esac
