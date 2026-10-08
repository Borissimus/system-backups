#!/usr/bin/env bash
#
# backup-system.sh — run ON THE LIVE INSTALLED SYSTEM (not from Live USB) to
# add a new incremental backup to the same restic repository used by
# restore-system.sh. Restic itself is content-addressed / deduplicated, so
# each run only uploads data that changed since the previous snapshot —
# there is nothing extra to do to make it "incremental"; this script's job
# is just to capture a consistent point-in-time copy (via an LVM snapshot)
# and push root + /boot + fresh recovery metadata to restic in one run.
#
#   sudo bash backup-system.sh --dry-run                 # validate only
#   sudo bash backup-system.sh --config backup-config.json
#   sudo bash backup-system.sh --print-plan               # no repository write
#   sudo bash backup-system.sh --prune                    # apply retention
#   Add --backup-dir /mnt/backup/system-backups for storage separate from code.
#
# Concurrency: a flock-based lock (.backup.lock) makes a second, overlapping
# invocation (e.g. cron + a manual run) exit immediately instead of racing
# for the same LVM snapshot name / restic repo lock.
#
# History: every real run (success, failure, or skipped-due-to-lock) appends
# one line to backup-history.log — see README.md in this directory for the
# exact format. Meant to be machine-parsed by a future monitoring/systemd
# layer, not just human-read.
#
set -euo pipefail

# flock використовує додатковий FD, а LVM за замовчуванням попереджає про
# будь-який успадкований нестандартний FD. Це штатна ситуація для скрипта;
# lock лишається активним, а діагностичний шум прибираємо документованою
# змінною LVM.
export LVM_SUPPRESS_FD_WARNINGS=1

if [[ $EUID -ne 0 ]]; then
  exec sudo -E bash "$0" "$@"
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
BACKUP_DIR="$SCRIPT_DIR"
CONFIG_HELPER="$SCRIPT_DIR/scripts/backup-config.py"

DRY_RUN=0
PRUNE=0
PRINT_PLAN=0
BACKUP_CONFIG="${BACKUP_CONFIG:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --prune)   PRUNE=1 ;;
    --print-plan) PRINT_PLAN=1 ;;
    --backup-dir)
      shift
      [[ $# -gt 0 && "$1" == /* ]] || { echo "--backup-dir requires an absolute path" >&2; exit 2; }
      BACKUP_DIR=$(realpath -m -- "$1")
      [[ "$BACKUP_DIR" != / ]] || { echo "--backup-dir must not be /" >&2; exit 2; }
      ;;
    --config)
      shift
      [[ $# -gt 0 ]] || { echo "--config requires a file path" >&2; exit 2; }
      BACKUP_CONFIG="$1"
      ;;
    --config=*) BACKUP_CONFIG="${1#--config=}" ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

REPO="$BACKUP_DIR/restic"
META="$BACKUP_DIR/recovery-metadata"
LOCK_FILE="$BACKUP_DIR/.backup.lock"
HISTORY_FILE="$BACKUP_DIR/backup-history.log"

SNAP_MOUNT=/mnt/root-backup-snapshot
SNAP_LV_NAME=""
KEEP_DAILY=${KEEP_DAILY:-7}
KEEP_WEEKLY=${KEEP_WEEKLY:-4}
KEEP_MONTHLY=${KEEP_MONTHLY:-6}
ROOT_SNAPSHOT_MODE=""
ENCRYPTION_MODE=""
BOOT_MODE=""
HOME_MODE=""
HOME_PATH=""
HOME_SNAPSHOT_MODE=""
ROOT_IS_LVM=0
HAVE_LVM_TOOLS=0
LUKS_ENABLED=0
HAS_ESP=0
HOME_SEPARATE=0
HOME_BACKED_UP=0
ROOT_SOURCE=""
HOME_SOURCE=""
HOME_DISK=""
ROOT_BACKUP_PATH=""
VG_NAME=""
LV_NAME=""
PV_NAME=""
CRYPT_NAME=""
LUKS_PART=""
DISK=""

log() { echo -e "\n=== $* ==="; }
die() { echo "ПОМИЛКА: $*" >&2; exit 1; }

START_TS=$(date +%s)
CURRENT_STEP="init"
RUN_TAG=""

# Один рядок в backup-history.log на подію: ts/tag/status/duration завжди,
# плюс довільні key=value для деталей (розмір доданих даних, snapshot id
# тощо). Формат — простий, щоб майбутній сервіс/моніторинг міг парсити
# без залежностей (не JSON, щоб можна було читати grep/awk).
history_log() {
  local status="$1"; shift
  local duration=$(( $(date +%s) - START_TS ))
  {
    printf 'ts=%s tag=%s status=%s duration_s=%s step=%s' \
      "$(date -Iseconds)" "${RUN_TAG:--}" "$status" "$duration" "$CURRENT_STEP"
    for kv in "$@"; do printf ' %s' "$kv"; done
    printf '\n'
  } >> "$HISTORY_FILE"
}

# Дістає з summary-рядка `restic backup --json` (останній рядок потоку)
# розмір реально доданих даних, кількість нових/змінених файлів і snapshot
# id. Захищено try/except: якщо схема JSON колись зміниться, повертає нулі
# замість падіння — сам бекап на той момент уже завершився успішно.
summarize_backup() {
  python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        lines = [l for l in f if l.strip()]
    s = json.loads(lines[-1])
    print(s.get('data_added', 0), s.get('files_new', 0), s.get('files_changed', 0), s.get('snapshot_id', '-'))
except Exception:
    print(0, 0, 0, '-')
" "$1"
}

human_bytes() { numfmt --to=iec-i --suffix=B "$1" 2>/dev/null || echo "${1}B"; }

load_profile() {
  [[ -x "$CONFIG_HELPER" ]] || die "Відсутній JSON config helper: $CONFIG_HELPER"
  local key value config_values
  local -a config_args=()
  [[ -n "$BACKUP_CONFIG" ]] && config_args=(--config "$BACKUP_CONFIG")
  config_values=$(python3 "$CONFIG_HELPER" export --include-json "${config_args[@]}") || die "Не вдалося завантажити backup profile"
  while IFS=$'\t' read -r key value; do
    case "$key" in
      BACKUP_PROFILE_JSON|ROOT_SNAPSHOT_MODE|ENCRYPTION_MODE|BOOT_MODE|HOME_MODE|HOME_PATH|HOME_SNAPSHOT_MODE)
        printf -v "$key" '%s' "$value"
        ;;
      *) die "Невідомий ключ з JSON config helper: $key" ;;
    esac
  done <<< "$config_values"
  [[ -n "$ROOT_SNAPSHOT_MODE" && -n "$HOME_MODE" ]] || die "Не вдалося завантажити backup profile"
}

SNAP_CREATED=0
TMP_JSON_FILES=()
cleanup() {
  local ec=$?
  set +e
  if [[ $SNAP_CREATED -eq 1 ]]; then
    echo "Прибирання: розмонтування та видалення тимчасового LVM snapshot"
    umount "$SNAP_MOUNT" 2>/dev/null
    [[ -n "$VG_NAME" && -n "$SNAP_LV_NAME" ]] && lvremove -f "/dev/$VG_NAME/$SNAP_LV_NAME" 2>/dev/null
  fi
  [[ ${#TMP_JSON_FILES[@]} -gt 0 ]] && rm -f "${TMP_JSON_FILES[@]}"
  unset RESTIC_PASSWORD
  if [[ $ec -ne 0 ]]; then
    echo "Скрипт завершився з помилкою (код $ec) на кроці: $CURRENT_STEP" >&2
    [[ $PRINT_PLAN -eq 1 || $DRY_RUN -eq 1 ]] || history_log failed "exit_code=$ec"
  fi
  exit $ec
}
trap cleanup EXIT

# Не давати двом копіям скрипта (напр. cron + ручний запуск) працювати
# одночасно — інакше обидва спробують створити той самий LVM snapshot і
# зіткнуться в restic-локах репозиторію. Не блокуємось в очікуванні:
# просто виходимо, наступний тригер (за розкладом) спробує пізніше.
if [[ $PRINT_PLAN -eq 0 && $DRY_RUN -eq 0 ]]; then
  exec 200>"$LOCK_FILE"
  if ! flock -n 200; then
    echo "Інший запуск backup-system.sh вже триває — пропускаю цей запуск." >&2
    history_log skipped "reason=already_running"
    exit 0
  fi
fi

# Унікальне ім'я не перетинається зі старим ручним snapshot'ом і дає змогу
# безпечно відмовитися від запуску після аварійного вимкнення замість
# автоматичного видалення чужого LV.
RUN_TAG="run-$(date +%Y%m%d-%H%M%S)"
SNAP_LV_NAME="root-backup-snapshot-${RUN_TAG#run-}"
# Ім'я LV має бути унікальним, але mount path — сталим: restic використовує
# шлях разом з hostname, щоб знайти parent snapshot і не читати незмінені
# файли повторно. Старий LV з іменем root-backup-snapshot не зачіпається.
SNAP_MOUNT="/mnt/root-backup-snapshot"

CURRENT_STEP="verify_repo"
if [[ $PRINT_PLAN -eq 0 ]]; then
  [[ -d "$REPO" && -f "$REPO/config" ]] || die "Не знайдено restic репозиторій: $REPO"
fi
load_profile
echo "Backup profile: ${BACKUP_CONFIG:-built-in defaults}"

# ---------------------------------------------------------------------------
# 1. Detect the storage layout selected by the profile
# ---------------------------------------------------------------------------

CURRENT_STEP="detect_layout"
log "Визначення поточної storage-конфігурації"
ROOT_SRC=$(findmnt -no SOURCE /) || die "Не вдалося визначити пристрій /"
ROOT_SRC_RESOLVED=$(readlink -f "$ROOT_SRC")
ROOT_SOURCE="$ROOT_SRC_RESOLVED"

if command -v lvs >/dev/null 2>&1; then
  HAVE_LVM_TOOLS=1
  if read -r VG_NAME LV_NAME < <(lvs --noheadings -o vg_name,lv_name "$ROOT_SRC" 2>/dev/null | awk '{print $1,$2}'); then
    [[ -n "$VG_NAME" && -n "$LV_NAME" ]] && ROOT_IS_LVM=1
  fi
fi

if [[ "$ROOT_SNAPSHOT_MODE" == lvm && $ROOT_IS_LVM -ne 1 ]]; then
  die "root.snapshot_mode=lvm, але / не є LVM logical volume"
fi

if (( ROOT_IS_LVM )); then
  PV_NAME=$(pvs --noheadings -o pv_name --select "vg_name=$VG_NAME" | head -1 | tr -d ' ')
  PV_COUNT=$(pvs --noheadings -o pv_name --select "vg_name=$VG_NAME" | awk 'NF {n++} END {print n+0}')
  [[ "$PV_COUNT" -eq 1 ]] || die "VG $VG_NAME містить кілька PV; цей storage layout поки не підтримується"
  [[ -n "$PV_NAME" ]] || die "Не вдалося визначити PV для VG $VG_NAME"
  BACKING_SOURCE="$PV_NAME"
else
  BACKING_SOURCE="$ROOT_SRC"
fi

# A LUKS mapping is optional. Plain LVM and a direct root partition are both
# supported; the profile can require or forbid encryption explicitly.
CRYPT_CANDIDATE=$(basename "$BACKING_SOURCE")
if command -v cryptsetup >/dev/null 2>&1 && cryptsetup status "$CRYPT_CANDIDATE" >/dev/null 2>&1; then
  LUKS_PART=$(cryptsetup status "$CRYPT_CANDIDATE" | awk '/device:/{print $2}')
  [[ -n "$LUKS_PART" ]] || die "cryptsetup не повернув backing device для $CRYPT_CANDIDATE"
  CRYPT_NAME="$CRYPT_CANDIDATE"
  LUKS_ENABLED=1
  DISK_SOURCE="$LUKS_PART"
else
  DISK_SOURCE="$BACKING_SOURCE"
fi
if [[ "$ENCRYPTION_MODE" == required && $LUKS_ENABLED -ne 1 ]]; then
  die "encryption.mode=required, але LUKS під root не знайдено"
fi
if [[ "$ENCRYPTION_MODE" == none && $LUKS_ENABLED -eq 1 ]]; then
  die "encryption.mode=none, але root знаходиться під LUKS"
fi

DISK=$(lsblk -no PKNAME -d "$DISK_SOURCE" 2>/dev/null | head -1)
if [[ -z "$DISK" ]]; then
  # Root may be mounted directly from a whole-disk filesystem.
  [[ "$(lsblk -no TYPE "$DISK_SOURCE" 2>/dev/null)" == disk ]] && DISK=$(basename "$DISK_SOURCE")
fi
[[ -n "$DISK" ]] || die "Не вдалося визначити фізичний диск під $DISK_SOURCE"

BOOT_SRC=$(findmnt -no SOURCE --target /boot) || die "Не вдалося визначити пристрій /boot"
ESP_SRC=""
if findmnt -M /boot/efi >/dev/null 2>&1; then
  ESP_SRC=$(findmnt -no SOURCE /boot/efi)
  HAS_ESP=1
fi
if [[ "$BOOT_MODE" == required && $HAS_ESP -ne 1 ]]; then
  die "boot.mode=required, але /boot/efi не змонтовано"
fi

HOME_MOUNT=$(findmnt -no TARGET --target "$HOME_PATH" 2>/dev/null || true)
HOME_SOURCE=$(findmnt -no SOURCE --target "$HOME_PATH" 2>/dev/null || true)
[[ "$HOME_MOUNT" == "$HOME_PATH" ]] && HOME_SEPARATE=1
case "$HOME_MODE" in
  restic|external|exclude)
    (( HOME_SEPARATE )) || die "home.mode=$HOME_MODE потребує окремо змонтований $HOME_PATH; інакше /home уже входить у root backup"
    ;;
esac
if (( HOME_SEPARATE )); then
  HOME_DISK=$(lsblk -no PKNAME -d "$HOME_SOURCE" 2>/dev/null | head -1 || true)
  if [[ -z "$HOME_DISK" && "$(lsblk -no TYPE "$HOME_SOURCE" 2>/dev/null || true)" == disk ]]; then
    HOME_DISK=$(basename "$HOME_SOURCE")
  fi
fi

echo "Root source: $ROOT_SRC_RESOLVED"
(( ROOT_IS_LVM )) && echo "Root LV:    $VG_NAME/$LV_NAME"
(( LUKS_ENABLED )) && echo "LUKS:       $LUKS_PART -> $CRYPT_NAME" || echo "LUKS:       немає"
echo "Диск:       /dev/$DISK"
echo "/boot:      $BOOT_SRC"
(( HAS_ESP )) && echo "/boot/efi:  $ESP_SRC" || echo "/boot/efi:  немає окремого ESP mount"
echo "/home:      mode=$HOME_MODE path=$HOME_PATH separate=$HOME_SEPARATE"
[[ -n "$HOME_DISK" && "$HOME_DISK" != "$DISK" ]] && echo "/home disk: /dev/$HOME_DISK"

# ---------------------------------------------------------------------------
# 2. Root snapshot sizing (only when LVM is available and selected)
# ---------------------------------------------------------------------------

USE_LVM_SNAPSHOT=0
if (( ROOT_IS_LVM )) && [[ "$ROOT_SNAPSHOT_MODE" != live ]]; then
  USE_LVM_SNAPSHOT=1
fi
if (( USE_LVM_SNAPSHOT )); then
  CURRENT_STEP="snapshot_sizing"
  log "Розрахунок розміру LVM snapshot"
  VG_FREE_G=$(LC_ALL=C vgs --noheadings --units g -o vg_free "$VG_NAME" | tr -d ' g<>')
  LV_SIZE_G=$(LC_ALL=C lvs --noheadings --units g -o lv_size "$VG_NAME/$LV_NAME" | tr -d ' g<>')
  SNAP_SIZE_G=$(python3 -c "
free=$VG_FREE_G; lv=$LV_SIZE_G
want=max(5.0, lv*0.2)
print(int(min(free-1, want)))
")
  [[ $SNAP_SIZE_G -ge 5 ]] || die "Недостатньо вільного місця у VG для snapshot (вільно ${VG_FREE_G}G, потрібно мінімум 5G)"
  echo "VG вільно: ${VG_FREE_G}G, LV: ${LV_SIZE_G}G -> snapshot: ${SNAP_SIZE_G}G"

  STALE_SNAPSHOTS=$(lvs --noheadings -o lv_name "$VG_NAME" 2>/dev/null \
    | awk '/^ *root-backup-snapshot-[0-9]{8}-[0-9]{6} *$/ {print $1}')
  [[ -z "$STALE_SNAPSHOTS" ]] || die \
    "Знайдено snapshot від перерваного запуску: $STALE_SNAPSHOTS. Перевірте його вручну перед новим backup."
else
  echo "Root backup: live filesystem mode (LVM snapshot не використовується)"
fi

if [[ $PRINT_PLAN -eq 1 ]]; then
  log "Backup plan (нічого не змінено)"
  echo "repository: $REPO"
  echo "root: $([[ $USE_LVM_SNAPSHOT -eq 1 ]] && echo lvm-snapshot || echo live-filesystem)"
  echo "encryption: $([[ $LUKS_ENABLED -eq 1 ]] && echo luks || echo none)"
  echo "boot: mode=$BOOT_MODE, esp=$HAS_ESP"
  if (( HOME_SEPARATE )); then
    echo "home: $HOME_MODE ($HOME_PATH on $HOME_SOURCE)"
  else
    echo "home: included in root filesystem (mode=auto)"
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# 3. Restic password
# ---------------------------------------------------------------------------

CURRENT_STEP="restic_password"
# Для майбутнього автономного сервісу: якщо пароль уже заданий ззовні
# (RESTIC_PASSWORD / RESTIC_PASSWORD_FILE / RESTIC_PASSWORD_COMMAND — усі
# три нативно розуміються самим restic), інтерактивний запит пропускаємо.
# Без цього скрипт ніколи не зміг би працювати з systemd-таймера.
if [[ -n "${RESTIC_PASSWORD:-}" || -n "${RESTIC_PASSWORD_FILE:-}" || -n "${RESTIC_PASSWORD_COMMAND:-}" ]]; then
  log "Пароль restic узято з середовища — без інтерактивного запиту"
else
  log "Пароль репозиторію restic"
  read -rs -p "Restic password: " RESTIC_PASSWORD
  echo
  export RESTIC_PASSWORD
fi
restic -r "$REPO" snapshots --latest 1 >/dev/null || die "Невірний пароль або пошкоджений репозиторій"
echo "OK: репозиторій доступний"

if [[ $DRY_RUN -eq 1 ]]; then
  log "--dry-run: перевірку завершено, нічого не змінено і не забекаплено"
  exit 0
fi

# ---------------------------------------------------------------------------
# 4. Refresh recovery-metadata
# ---------------------------------------------------------------------------

CURRENT_STEP="refresh_metadata"
log "Оновлення recovery-metadata"
mkdir -p "$META"
command -v sgdisk >/dev/null 2>&1 || die "Потрібна команда sgdisk для recovery-metadata"
command -v sfdisk >/dev/null 2>&1 || die "Потрібна команда sfdisk для recovery-metadata"
# Whole-device filesystems legitimately have no partition table. Do not
# manufacture an empty GPT backup or run sfdisk against such a device.
ROOT_TABLE_TYPE=$(lsblk -dn -o PTTYPE "/dev/$DISK")
HOME_TABLE_TYPE=""
rm -f "$META/disk.gpt" "$META/disk.sfdisk" "$META/home-disk.gpt" "$META/home-disk.sfdisk"
if [[ -n "$ROOT_TABLE_TYPE" ]]; then
  [[ "$ROOT_TABLE_TYPE" != gpt ]] || sgdisk --backup="$META/disk.gpt" "/dev/$DISK"
  sfdisk -d "/dev/$DISK" > "$META/disk.sfdisk"
fi
if [[ "$HOME_MODE" == restic && -n "$HOME_DISK" && "$HOME_DISK" != "$DISK" ]]; then
  HOME_TABLE_TYPE=$(lsblk -dn -o PTTYPE "/dev/$HOME_DISK")
  if [[ -n "$HOME_TABLE_TYPE" ]]; then
    [[ "$HOME_TABLE_TYPE" != gpt ]] || sgdisk --backup="$META/home-disk.gpt" "/dev/$HOME_DISK"
    sfdisk -d "/dev/$HOME_DISK" > "$META/home-disk.sfdisk"
  fi
fi
export ROOT_TABLE_TYPE HOME_TABLE_TYPE
blkid > "$META/blkid.txt"
lsblk > "$META/lsblk.txt"
if (( HAVE_LVM_TOOLS )); then
  pvs > "$META/pvs.txt"
  vgs > "$META/vgs.txt"
  lvs -a -o lv_name,lv_size,pool_lv,origin,data_percent,vg_name,lv_attr > "$META/lvs.txt"
else
  printf 'LVM tools are not installed; root is not LVM.\n' > "$META/pvs.txt"
  cp "$META/pvs.txt" "$META/vgs.txt"
  cp "$META/pvs.txt" "$META/lvs.txt"
fi
if (( ROOT_IS_LVM )); then
  command -v vgcfgbackup >/dev/null 2>&1 || die "Потрібна команда vgcfgbackup для LVM root"
  vgcfgbackup -f "$META/lvm-vg.conf" "$VG_NAME"
  chmod 600 "$META/lvm-vg.conf"
else
  rm -f "$META/lvm-vg.conf"
fi
if (( LUKS_ENABLED )); then
  command -v cryptsetup >/dev/null 2>&1 || die "Потрібна команда cryptsetup для LUKS root"
  cryptsetup luksHeaderBackup "$LUKS_PART" --header-backup-file "$META/luks-header.img.new"
  mv "$META/luks-header.img.new" "$META/luks-header.img"
  chmod 600 "$META/luks-header.img"
else
  rm -f "$META/luks-header.img"
fi
# Keep legacy names only for the already verified LVM-on-LUKS UEFI recovery
# procedure. Other topologies must be restored from layout.json + the generic
# names, rather than accidentally being treated as this machine's NVMe layout.
if (( ROOT_IS_LVM && LUKS_ENABLED && HAS_ESP )) && [[ "$ROOT_TABLE_TYPE" == gpt ]]; then
  cp "$META/disk.gpt" "$META/nvme0n1.gpt"
  cp "$META/disk.sfdisk" "$META/nvme0n1.sfdisk"
  cp "$META/lvm-vg.conf" "$META/ubuntu-vg.conf"
  cp "$META/luks-header.img" "$META/nvme0n1p3-luks-header.img"
else
  rm -f "$META/nvme0n1.gpt" "$META/nvme0n1.sfdisk" \
    "$META/ubuntu-vg.conf" "$META/nvme0n1p3-luks-header.img"
fi
ROOT_BACKUP_PATH=$([[ $USE_LVM_SNAPSHOT -eq 1 ]] && printf '%s' "$SNAP_MOUNT" || printf '/')
ROOT_FS_TYPE=$(findmnt -no FSTYPE /)
BOOT_FS_TYPE=$(findmnt -no FSTYPE --target /boot)
BOOT_SEPARATE=0
findmnt -M /boot >/dev/null 2>&1 && BOOT_SEPARATE=1
export ROOT_FS_TYPE BOOT_FS_TYPE BOOT_SEPARATE
ROOT_FS_UUID=$(blkid -s UUID -o value "$ROOT_SRC")
BOOT_FS_UUID=$(blkid -s UUID -o value "$BOOT_SRC")
ESP_FS_UUID=""
(( HAS_ESP == 0 )) || ESP_FS_UUID=$(blkid -s UUID -o value "$ESP_SRC")
export ROOT_FS_UUID BOOT_FS_UUID ESP_FS_UUID
export ROOT_IS_LVM LUKS_ENABLED HAS_ESP HOME_SEPARATE USE_LVM_SNAPSHOT
export ROOT_SOURCE ROOT_BACKUP_PATH VG_NAME LV_NAME PV_NAME CRYPT_NAME LUKS_PART DISK BOOT_SRC ESP_SRC HOME_MODE HOME_PATH HOME_SOURCE HOME_DISK
export ROOT_SNAPSHOT_MODE ENCRYPTION_MODE BOOT_MODE HOME_SNAPSHOT_MODE RUN_TAG BACKUP_PROFILE_JSON
export KEEP_DAILY KEEP_WEEKLY KEEP_MONTHLY PRUNE
python3 - "$META/layout.json" "$SCRIPT_DIR/scripts/service-config.py" <<'PY'
import json, os, sys
import importlib.util
from pathlib import Path

# Only save the validated configs, never the password or the whole environment.
metadata = Path(sys.argv[1]).parent
backup_config = json.loads(os.environ["BACKUP_PROFILE_JSON"])
service_json = os.environ.get("SYSTEM_BACKUP_SERVICE_CONFIG_JSON", "")
service_config = json.loads(service_json) if service_json else None
if service_config is not None:
    spec = importlib.util.spec_from_file_location("service_config", sys.argv[2])
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    if not isinstance(service_config, dict) or set(service_config) - helper.ALLOWED:
        raise ValueError("Service metadata contains unsupported config fields")
    helper.validate(service_config)
for filename, config in (("backup-config.json", backup_config), ("service-config.json", service_config)):
    target = metadata / filename
    if config is None:
        target.unlink(missing_ok=True)  # manual run must not keep a prior service config
    else:
        target.write_text(json.dumps(config, indent=2, sort_keys=True) + "\n")
        target.chmod(0o600)

def yes(name): return os.environ[name] == "1"
data = {
  "schema_version": 1,
  "run_tag": os.environ["RUN_TAG"],
  "profile": {
    "recovery_profile": (
      "lvm-luks-uefi" if yes("ROOT_IS_LVM") and yes("LUKS_ENABLED") and yes("HAS_ESP")
      else "lvm-luks" if yes("ROOT_IS_LVM") and yes("LUKS_ENABLED")
      else "lvm-plain" if yes("ROOT_IS_LVM")
      else "partition-luks" if yes("LUKS_ENABLED")
      else "partition-plain"
    ),
    "root_snapshot_mode": os.environ["ROOT_SNAPSHOT_MODE"],
    "encryption_mode": os.environ["ENCRYPTION_MODE"],
    "boot_mode": os.environ["BOOT_MODE"],
  },
  "root": {
    "source": os.environ["ROOT_SOURCE"],
    "filesystem_uuid": os.environ["ROOT_FS_UUID"],
    "filesystem_type": os.environ["ROOT_FS_TYPE"],
    "backup_path": os.environ["ROOT_BACKUP_PATH"],
    "lvm": yes("ROOT_IS_LVM"),
    "vg_name": os.environ["VG_NAME"] or None,
    "lv_name": os.environ["LV_NAME"] or None,
    "snapshot": "lvm" if yes("USE_LVM_SNAPSHOT") else "live",
  },
  "luks": {
    "enabled": yes("LUKS_ENABLED"),
    "mapping": os.environ["CRYPT_NAME"] or None,
    "device": os.environ["LUKS_PART"] or None,
    "header_file": "luks-header.img" if yes("LUKS_ENABLED") else None,
  },
  "disk": {"source_disk": "/dev/" + os.environ["DISK"], "partition_table": os.environ["ROOT_TABLE_TYPE"] or None,
           "sfdisk_file": "disk.sfdisk" if os.environ["ROOT_TABLE_TYPE"] else None,
           "gpt_file": "disk.gpt" if os.environ["ROOT_TABLE_TYPE"] == "gpt" else None},
  "boot": {"source": os.environ["BOOT_SRC"], "esp_source": os.environ["ESP_SRC"] or None, "efi": yes("HAS_ESP"),
           "filesystem_uuid": os.environ["BOOT_FS_UUID"], "esp_uuid": os.environ["ESP_FS_UUID"] or None,
           "filesystem_type": os.environ["BOOT_FS_TYPE"], "separate_mount": yes("BOOT_SEPARATE")},
  "home": {
    "mode": os.environ["HOME_MODE"], "path": os.environ["HOME_PATH"],
    "source": os.environ["HOME_SOURCE"] or None, "separate_mount": yes("HOME_SEPARATE"),
    "source_disk": "/dev/" + os.environ["HOME_DISK"] if os.environ["HOME_DISK"] else None,
    "partition_table": os.environ["HOME_TABLE_TYPE"] or None,
    "sfdisk_file": "home-disk.sfdisk" if os.environ["HOME_TABLE_TYPE"] else None,
    "gpt_file": "home-disk.gpt" if os.environ["HOME_TABLE_TYPE"] == "gpt" else None,
    "snapshot": os.environ["HOME_SNAPSHOT_MODE"],
  },
  "configuration": {
    "backup_file": "backup-config.json",
    "service_file": "service-config.json" if service_config is not None else None,
    "retention": {"daily": int(os.environ["KEEP_DAILY"]), "weekly": int(os.environ["KEEP_WEEKLY"]), "monthly": int(os.environ["KEEP_MONTHLY"])},
    "prune_requested": yes("PRUNE"),
  },
  "files": {"lvm_config": "lvm-vg.conf" if yes("ROOT_IS_LVM") else None},
}
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, sort_keys=True)
    f.write("\n")
PY
echo "OK: recovery-metadata оновлено"

# ---------------------------------------------------------------------------
# 5. LVM snapshot + mount
# ---------------------------------------------------------------------------

if (( USE_LVM_SNAPSHOT )); then
  CURRENT_STEP="create_snapshot"
  log "Створення LVM snapshot кореня (для консистентної точки в часі)"
  lvcreate --size "${SNAP_SIZE_G}G" --snapshot --name "$SNAP_LV_NAME" "$VG_NAME/$LV_NAME"
  SNAP_CREATED=1
  mkdir -p "$SNAP_MOUNT"
  mount -o ro "/dev/$VG_NAME/$SNAP_LV_NAME" "$SNAP_MOUNT"
  ROOT_BACKUP_PATH="$SNAP_MOUNT"
else
  ROOT_BACKUP_PATH=/
fi

# ---------------------------------------------------------------------------
# 6. Restic backup — root, optional separate home, boot and metadata
# ---------------------------------------------------------------------------

CURRENT_STEP="backup_root"
log "restic backup: system-root ($ROOT_BACKUP_PATH) — без живого прогресу (--json), може виглядати як пауза"
ROOT_JSON=$(mktemp); TMP_JSON_FILES+=("$ROOT_JSON")
if (( USE_LVM_SNAPSHOT )); then
  restic -r "$REPO" backup "$ROOT_BACKUP_PATH" --exclude "$SNAP_MOUNT$BACKUP_DIR" --tag system-root --tag "$RUN_TAG" --json > "$ROOT_JSON"
else
  # Do not cross into separately mounted filesystems. A separate /home is
  # either backed up below (mode=restic) or deliberately left external.
  restic -r "$REPO" backup / --exclude "$BACKUP_DIR" --one-file-system --tag system-root --tag "$RUN_TAG" --json > "$ROOT_JSON"
fi
read -r ROOT_ADDED ROOT_FILES_NEW ROOT_FILES_CHANGED ROOT_SNAPID < <(summarize_backup "$ROOT_JSON")
echo "system-root: +$(human_bytes "$ROOT_ADDED") нових даних, нових/змінених файлів: $ROOT_FILES_NEW/$ROOT_FILES_CHANGED, snapshot $ROOT_SNAPID"

HOME_ADDED=0
HOME_SNAPID="-"
if [[ "$HOME_MODE" == restic ]]; then
  CURRENT_STEP="backup_home"
  log "restic backup: system-home ($HOME_PATH, live filesystem)"
  HOME_JSON=$(mktemp); TMP_JSON_FILES+=("$HOME_JSON")
  restic -r "$REPO" backup "$HOME_PATH" --exclude "$BACKUP_DIR" --one-file-system \
    --tag system-home --tag "$RUN_TAG" --json > "$HOME_JSON"
  read -r HOME_ADDED HOME_FILES_NEW HOME_FILES_CHANGED HOME_SNAPID < <(summarize_backup "$HOME_JSON")
  HOME_BACKED_UP=1
  echo "system-home: +$(human_bytes "$HOME_ADDED") нових даних, нових/змінених файлів: $HOME_FILES_NEW/$HOME_FILES_CHANGED, snapshot $HOME_SNAPID"
elif (( HOME_SEPARATE )); then
  echo "system-home: не створюється (mode=$HOME_MODE; $HOME_PATH поза root backup)"
fi

BOOT_ADDED=0
BOOT_SNAPID="-"
if [[ "$BOOT_MODE" != none ]]; then
  CURRENT_STEP="backup_boot"
  if (( HAS_ESP )); then
    log "restic backup: system-boot (/boot і /boot/efi окремими файловими системами)"
    BOOT_JSON=$(mktemp); TMP_JSON_FILES+=("$BOOT_JSON")
    restic -r "$REPO" backup /boot /boot/efi --one-file-system \
      --tag system-boot --tag "$RUN_TAG" --json > "$BOOT_JSON"
  else
    log "restic backup: system-boot (/boot; окремий ESP не змонтовано)"
    BOOT_JSON=$(mktemp); TMP_JSON_FILES+=("$BOOT_JSON")
    restic -r "$REPO" backup /boot --one-file-system \
      --tag system-boot --tag "$RUN_TAG" --json > "$BOOT_JSON"
  fi
  read -r BOOT_ADDED BOOT_FILES_NEW BOOT_FILES_CHANGED BOOT_SNAPID < <(summarize_backup "$BOOT_JSON")
  echo "system-boot: +$(human_bytes "$BOOT_ADDED") нових даних, нових/змінених файлів: $BOOT_FILES_NEW/$BOOT_FILES_CHANGED, snapshot $BOOT_SNAPID"
else
  echo "system-boot: не створюється (boot.mode=none)"
fi

# The manifest is itself backed up in the following step, so record whether a
# separately mounted home was actually included in this run before that.
export HOME_BACKED_UP
python3 - "$META/layout.json" <<'PY'
import json, os, sys
with open(sys.argv[1], encoding="utf-8") as f:
    layout = json.load(f)
layout["home"]["backed_up"] = os.environ["HOME_BACKED_UP"] == "1"
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(layout, f, indent=2, sort_keys=True)
    f.write("\n")
PY

CURRENT_STEP="backup_metadata"
log "restic backup: recovery-metadata"
META_JSON=$(mktemp); TMP_JSON_FILES+=("$META_JSON")
restic -r "$REPO" backup "$META" --tag recovery-metadata --tag "$RUN_TAG" --json > "$META_JSON"
read -r META_ADDED _ _ META_SNAPID < <(summarize_backup "$META_JSON")
echo "recovery-metadata: +$(human_bytes "$META_ADDED") нових даних, snapshot $META_SNAPID"

# ---------------------------------------------------------------------------
# 7. Cleanup snapshot (also handled by trap, done explicitly here for order)
# ---------------------------------------------------------------------------

if (( SNAP_CREATED )); then
  CURRENT_STEP="remove_snapshot"
  log "Видалення тимчасового LVM snapshot"
  umount "$SNAP_MOUNT"
  lvremove -f "$VG_NAME/$SNAP_LV_NAME"
  SNAP_CREATED=0
fi

# ---------------------------------------------------------------------------
# 8. Optional retention + integrity check
# ---------------------------------------------------------------------------

if [[ $PRUNE -eq 1 ]]; then
  CURRENT_STEP="prune"
  log "Застосування retention policy (daily=$KEEP_DAILY weekly=$KEEP_WEEKLY monthly=$KEEP_MONTHLY)"
  for tag in system-root system-boot recovery-metadata; do
    # Кожен тип backup уже відфільтрований власним сталим тегом. Групуємо
    # лише за host, щоб одноразова зміна mount path (наприклад, тестовий
    # snapshot) не створила окрему групу, яку restic мусить зберігати як
    # її єдиний "oldest" snapshot назавжди.
    restic -r "$REPO" forget --tag "$tag" \
      --group-by host \
      --keep-daily "$KEEP_DAILY" --keep-weekly "$KEEP_WEEKLY" --keep-monthly "$KEEP_MONTHLY"
  done
  # A machine may later switch a separate /home from restic to external or
  # exclude. Retain and eventually prune its already-created system-home
  # snapshots too; otherwise they would be orphaned from the retention policy.
  HOME_SNAPSHOT_COUNT=$(restic -r "$REPO" snapshots --tag system-home --json | python3 -c 'import json, sys; print(len(json.load(sys.stdin)))')
  if [[ "$HOME_SNAPSHOT_COUNT" -gt 0 ]]; then
    restic -r "$REPO" forget --tag system-home \
      --group-by host \
      --keep-daily "$KEEP_DAILY" --keep-weekly "$KEEP_WEEKLY" --keep-monthly "$KEEP_MONTHLY"
  fi
  restic -r "$REPO" prune
fi

CURRENT_STEP="check_repo"
log "Перевірка репозиторію (без читання даних, швидко)"
restic -r "$REPO" check

CURRENT_STEP="done"
log "Готово"
restic -r "$REPO" snapshots --tag "$RUN_TAG"
echo "Новий backup завершено з тегом $RUN_TAG"

TOTAL_ADDED=$(( ROOT_ADDED + HOME_ADDED + BOOT_ADDED + META_ADDED ))
history_log success \
  "root_added=$ROOT_ADDED" "home_added=$HOME_ADDED" "boot_added=$BOOT_ADDED" "meta_added=$META_ADDED" "total_added=$TOTAL_ADDED" \
  "root_snapshot=$ROOT_SNAPID" "home_snapshot=$HOME_SNAPID" "boot_snapshot=$BOOT_SNAPID" "meta_snapshot=$META_SNAPID" \
  "home_mode=$HOME_MODE" \
  "pruned=$([[ $PRUNE -eq 1 ]] && echo yes || echo no)"
echo "Усього додано за цей запуск: $(human_bytes "$TOTAL_ADDED")"
