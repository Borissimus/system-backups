#!/usr/bin/env bash
# Install or update the systemd automation. By default it installs files but
# does NOT enable the configured daily timer; add --enable only after a manual service test.
set -euo pipefail

ENABLE=0
SERVICE_CONFIG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --enable) ENABLE=1 ;;
    --config)
      shift
      [[ $# -gt 0 ]] || { echo "--config requires a file" >&2; exit 2; }
      SERVICE_CONFIG=$(realpath -- "$1")
      ;;
    -h|--help)
      echo "Usage: sudo bash scripts/install-system-backup.sh [--config FILE] [--enable]"
      exit 0 ;;
    *) echo "Невідомий параметр: $1" >&2; exit 2 ;;
  esac
  shift
done

if [[ $EUID -ne 0 ]]; then
  args=()
  [[ -z "$SERVICE_CONFIG" ]] || args+=(--config "$SERVICE_CONFIG")
  (( ENABLE == 0 )) || args+=(--enable)
  exec sudo bash "$0" "${args[@]}"
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
LIB_DIR=/usr/local/lib/system-backup
CONFIG_DIR=/etc/system-backup
CONFIG="$CONFIG_DIR/service.json"
LEGACY_CONFIG="$CONFIG_DIR/system-backup.conf"
REPO_SERVICE_CONFIG="${SERVICE_CONFIG:-$REPO_DIR/configs/service-config.json}"
if [[ -n "$SERVICE_CONFIG" ]]; then
  python3 "$SCRIPT_DIR/service-config.py" validate --config "$SERVICE_CONFIG"
fi
PASSWORD_FILE="$CONFIG_DIR/restic.pass"
STATE_DIR=/var/lib/system-backup

install -d -m 0755 "$LIB_DIR" "$CONFIG_DIR" "$STATE_DIR"
install -m 0755 "$SCRIPT_DIR/system-backup-run.sh" "$LIB_DIR/run"
install -m 0755 "$SCRIPT_DIR/service-config.py" "$LIB_DIR/service-config.py"
install -m 0755 "$SCRIPT_DIR/system-backup-after-success.sh" "$LIB_DIR/after-success"
install -m 0755 "$SCRIPT_DIR/system-backup-failure-notice.sh" "$LIB_DIR/failure-notice"
install -m 0755 "$SCRIPT_DIR/system-backupctl.sh" /usr/local/bin/system-backupctl
install -m 0644 "$REPO_DIR/systemd/system-backup.service" /etc/systemd/system/system-backup.service
install -m 0644 "$REPO_DIR/systemd/system-backup.timer" /etc/systemd/system/system-backup.timer
install -m 0644 "$REPO_DIR/systemd/system-backup-failure.service" /etc/systemd/system/system-backup-failure.service

# Keep the backup profile next to the backup code and repository. It contains
# no password and is deliberately ignored by Git: each machine owns its
# storage-layout decisions. The initial profile is safe auto-detection.
if [[ -z "$SERVICE_CONFIG" && ! -e "$REPO_DIR/configs/backup-config.json" ]]; then
  install -d -m 0755 "$REPO_DIR/configs"
  python3 - "$REPO_DIR/configs/backup-config.example.jsonc" "$REPO_DIR/configs/backup-config.json" <<'PYPROFILE'
import json, sys
from pathlib import Path
lines = Path(sys.argv[1]).read_text().splitlines()
profile = json.loads("\n".join(line for line in lines if not line.lstrip().startswith("//")))
Path(sys.argv[2]).write_text(json.dumps(profile, indent=2) + "\n")
PYPROFILE
  chmod 0644 "$REPO_DIR/configs/backup-config.json"
  echo "Створено $REPO_DIR/configs/backup-config.json"
else
  echo "Використовую backup profile з service-конфігурації"
fi

if [[ -n "$SERVICE_CONFIG" && "$SERVICE_CONFIG" != "$CONFIG" ]]; then
  install -m 0600 "$SERVICE_CONFIG" "$CONFIG"
fi
if [[ ! -e "$CONFIG" ]]; then
  if [[ -e "$REPO_SERVICE_CONFIG" ]]; then
    python3 "$LIB_DIR/service-config.py" validate --config "$REPO_SERVICE_CONFIG"
    install -m 0600 "$REPO_SERVICE_CONFIG" "$CONFIG"
    echo "Скопійовано підготовлений $REPO_SERVICE_CONFIG до $CONFIG"
  else
    backup_mount=$(findmnt -no TARGET --target "$REPO_DIR") || {
      echo "Не вдалося визначити mount backup-репозиторію $REPO_DIR" >&2; exit 1;
    }
    mounted_source=$(findmnt -no SOURCE --target "$backup_mount") || {
      echo "Не вдалося визначити пристрій mount $backup_mount" >&2; exit 1;
    }
    backup_uuid=$(blkid -s UUID -o value "$mounted_source" 2>/dev/null || true)
    [[ -n "$backup_uuid" ]] || {
      echo "Не вдалося визначити UUID backup-диска $mounted_source" >&2; exit 1;
    }

    # A prior version used a root-only shell config. Read only its simple
    # assignment values for a one-way migration; do not execute it as code.
    legacy_value() {
      sed -n "s/^$1=//p" "$LEGACY_CONFIG" 2>/dev/null | tail -n 1
    }
    password_path="$PASSWORD_FILE"
    retention_daily=7
    retention_weekly=4
    retention_monthly=6
    minimum_free=20
    callback=/usr/local/lib/system-backup/after-success
    if [[ -r "$LEGACY_CONFIG" ]]; then
      password_path="$(legacy_value RESTIC_PASSWORD_FILE || true)"; password_path="${password_path:-$PASSWORD_FILE}"
      retention_daily="$(legacy_value KEEP_DAILY || true)"; retention_daily="${retention_daily:-7}"
      retention_weekly="$(legacy_value KEEP_WEEKLY || true)"; retention_weekly="${retention_weekly:-4}"
      retention_monthly="$(legacy_value KEEP_MONTHLY || true)"; retention_monthly="${retention_monthly:-6}"
      minimum_free="$(legacy_value MIN_REPOSITORY_FREE_GIB || true)"; minimum_free="${minimum_free:-20}"
      callback="$(legacy_value SUCCESS_CALLBACK || true)"; callback="${callback:-/usr/local/lib/system-backup/after-success}"
      echo "Переношу параметри зі старого $LEGACY_CONFIG до JSON (старий файл не видаляю)."
    fi
    python3 - "$CONFIG" "$REPO_DIR" "$backup_mount" "$backup_uuid" "$REPO_DIR/configs/backup-config.json" \
      "$retention_daily" "$retention_weekly" "$retention_monthly" "$minimum_free" "$password_path" "$callback" "${SUDO_USER:-}" <<'PY'
import json, sys
(
    output, backup_dir, backup_mount, backup_uuid, profile,
    daily, weekly, monthly, minimum, password_file, callback, notice_user,
) = sys.argv[1:]
data = {
    "schema_version": 1,
    "backup_dir": backup_dir,
    "backup_mount": backup_mount,
    "backup_disk_uuid": backup_uuid,
    "backup_profile": profile,
    "schedule": "20:00",
    "retention": {"daily": int(daily), "weekly": int(weekly), "monthly": int(monthly)},
    "min_repository_free_gib": int(minimum),
    "restic_password_file": password_file,
    "success_callback": callback,
    "notice_user": notice_user,
}
with open(output, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, sort_keys=True)
    f.write("\n")
PY
    chmod 0600 "$CONFIG"
    echo "Створено $CONFIG"
  fi
else
  echo "Зберігаю наявний конфіг $CONFIG"
fi

# Systemd cannot read JSON itself. Generate mount dependencies and the
# local schedule before ExecStart.
config_values=$(python3 "$LIB_DIR/service-config.py" export --config "$CONFIG") || exit 2
while IFS=$'\t' read -r key value; do
  case "$key" in
    CODE_DIR) code_dir="$value" ;;
    BACKUP_PROFILE) backup_profile="$value" ;;
    BACKUP_MOUNT) backup_mount="$value" ;;
    SCHEDULE) schedule="$value" ;;
    RESTIC_PASSWORD_FILE) password_path="$value" ;;
    NOTICE_USER) notice_user="$value" ;;
  esac
done <<< "$config_values"
: "${backup_mount:?service.json does not provide BACKUP_MOUNT}"
: "${schedule:?service.json does not provide SCHEDULE}"
: "${password_path:?service.json does not provide RESTIC_PASSWORD_FILE}"
[[ -x "$code_dir/backup-system.sh" ]] || { echo "Не знайдено код у $code_dir" >&2; exit 2; }
if [[ -n "$backup_profile" ]]; then
  python3 "$code_dir/scripts/backup-config.py" validate --config "$backup_profile"
fi
install -d -m 0755 /etc/systemd/system/system-backup.service.d /etc/systemd/system/system-backup.timer.d
escaped_mount=$(systemd-escape --path "$backup_mount")
mount_unit="$escaped_mount.mount"
# Unit values have their own escape rules and systemd percent specifiers.
mount_unit=$(python3 - "$mount_unit" <<'PYUNIT'
import sys
print(sys.argv[1].replace('\\', '\\\\').replace('%', '%%').replace('"', '\\"'))
PYUNIT
)
printf '[Unit]\nRequires=%s\nAfter=%s\n' "$mount_unit" "$mount_unit" \
  > /etc/systemd/system/system-backup.service.d/config.conf
printf '[Timer]\nOnCalendar=\nOnCalendar=*-*-* %s:00\n' "$schedule" \
  > /etc/systemd/system/system-backup.timer.d/config.conf
chmod 0644 /etc/systemd/system/system-backup.service.d/config.conf /etc/systemd/system/system-backup.timer.d/config.conf

if [[ ! -e "$password_path" ]]; then
  [[ -t 0 ]] || { echo "Потрібен інтерактивний ввід для Restic-пароля" >&2; exit 1; }
  read -r -s -p "Restic password (буде збережено root-only): " password
  echo
  [[ -n "$password" ]] || { echo "Порожній пароль не прийнято" >&2; exit 1; }
  install -d -m 0700 "$(dirname -- "$password_path")"
  umask 077
  printf '%s\n' "$password" > "$password_path"
  unset password
  chmod 0600 "$password_path"
  echo "Створено root-only файл пароля $password_path"
else
  echo "Зберігаю наявний файл пароля $password_path"
fi

# The one persistent ~/.bashrc line only sources a generic display helper;
# actual message content is written dynamically by the failure handler.
target_user=${notice_user:-${SUDO_USER:-}}
if [[ -n "$target_user" && "$target_user" != root ]]; then
  target_home=$(getent passwd "$target_user" | cut -d: -f6)
  [[ -n "$target_home" ]] || {
    echo "Користувача для notice_user не знайдено: $target_user" >&2; exit 1;
  }
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
  echo "Таймер увімкнено: щодня о $schedule. Перевірка: system-backupctl status"
else
  echo "Встановлено без увімкнення таймера. Спершу: system-backupctl run"
  echo "Потім: system-backupctl enable"
fi
