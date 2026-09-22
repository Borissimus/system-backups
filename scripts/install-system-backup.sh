#!/usr/bin/env bash
# Install or update the systemd automation. By default it installs files but
# does NOT enable the 20:00 timer; add --enable only after manual service test.
set -euo pipefail

ENABLE=0
case "${1:-}" in
  "") ;;
  --enable) ENABLE=1 ;;
  -h|--help)
    cat <<'EOF'
Usage: sudo bash scripts/install-system-backup.sh [--enable]

Installs/updates the systemd units and helpers. It asks once for the Restic
password if /etc/system-backup/restic.pass does not exist. Without --enable,
the timer remains disabled; test with: system-backupctl run
EOF
    exit 0 ;;
  *) echo "Невідомий параметр: $1" >&2; exit 2 ;;
esac

[[ $EUID -eq 0 ]] || exec sudo bash "$0" "$@"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
LIB_DIR=/usr/local/lib/system-backup
CONFIG_DIR=/etc/system-backup
CONFIG="$CONFIG_DIR/system-backup.conf"
PASSWORD_FILE="$CONFIG_DIR/restic.pass"
STATE_DIR=/var/lib/system-backup

install -d -m 0755 "$LIB_DIR" "$CONFIG_DIR" "$STATE_DIR"
install -m 0755 "$SCRIPT_DIR/system-backup-run.sh" "$LIB_DIR/run"
install -m 0755 "$SCRIPT_DIR/system-backup-after-success.sh" "$LIB_DIR/after-success"
install -m 0755 "$SCRIPT_DIR/system-backup-failure-notice.sh" "$LIB_DIR/failure-notice"
install -m 0755 "$SCRIPT_DIR/system-backupctl.sh" /usr/local/bin/system-backupctl
install -m 0644 "$REPO_DIR/systemd/system-backup.service" /etc/systemd/system/system-backup.service
install -m 0644 "$REPO_DIR/systemd/system-backup.timer" /etc/systemd/system/system-backup.timer
install -m 0644 "$REPO_DIR/systemd/system-backup-failure.service" /etc/systemd/system/system-backup-failure.service

if [[ ! -e "$CONFIG" ]]; then
  sed "s|^BACKUP_DIR=.*|BACKUP_DIR=$REPO_DIR|" \
    "$REPO_DIR/system-backup.conf.example" > "$CONFIG"
  chmod 0600 "$CONFIG"
  echo "Створено $CONFIG"
else
  echo "Зберігаю наявний конфіг $CONFIG"
fi

if [[ ! -e "$PASSWORD_FILE" ]]; then
  [[ -t 0 ]] || { echo "Потрібен інтерактивний ввід для Restic-пароля" >&2; exit 1; }
  read -r -s -p "Restic password (буде збережено root-only): " password
  echo
  [[ -n "$password" ]] || { echo "Порожній пароль не прийнято" >&2; exit 1; }
  umask 077
  printf '%s\n' "$password" > "$PASSWORD_FILE"
  unset password
  chmod 0600 "$PASSWORD_FILE"
  echo "Створено root-only файл пароля $PASSWORD_FILE"
else
  echo "Зберігаю наявний файл пароля $PASSWORD_FILE"
fi

# The one persistent ~/.bashrc line only sources a generic display helper;
# actual message content is written dynamically by the failure handler.
target_user=${SUDO_USER:-}
if [[ -n "$target_user" && "$target_user" != root ]]; then
  target_home=$(getent passwd "$target_user" | cut -d: -f6)
  target_bashrc="$target_home/.bashrc"
  target_notice_dir="$target_home/.config/system-backup"
  install -d -m 0755 -o "$target_user" -g "$(id -gn "$target_user")" "$target_notice_dir"
  install -m 0644 -o "$target_user" -g "$(id -gn "$target_user")" \
    "$SCRIPT_DIR/system-backup-shell-notice.sh" "$target_notice_dir/shell-notice.sh"
  marker='# system-backup failure notice'
  if ! grep -Fqx "$marker" "$target_bashrc" 2>/dev/null; then
    {
      echo
      echo "$marker"
      echo '[ -r "$HOME/.config/system-backup/shell-notice.sh" ] && . "$HOME/.config/system-backup/shell-notice.sh"'
    } >> "$target_bashrc"
    chown "$target_user:$(id -gn "$target_user")" "$target_bashrc"
    echo "Додано універсальний failure-notice hook до $target_bashrc"
  fi
else
  echo "SUDO_USER не визначено: shell-notice hook не додано до ~/.bashrc"
fi

systemctl daemon-reload
if (( ENABLE )); then
  systemctl enable --now system-backup.timer
  echo "Таймер увімкнено: щодня о 20:00. Перевірка: system-backupctl status"
else
  echo "Встановлено без увімкнення таймера. Спершу: system-backupctl run"
  echo "Потім: system-backupctl enable"
fi
