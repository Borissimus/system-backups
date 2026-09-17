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
#   sudo bash backup-system.sh --dry-run   # check everything, back up nothing
#   sudo bash backup-system.sh             # take a real backup
#   sudo bash backup-system.sh --prune     # ...and apply retention afterwards
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

if [[ $EUID -ne 0 ]]; then
  exec sudo -E bash "$0" "$@"
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO="$SCRIPT_DIR/restic"
META="$SCRIPT_DIR/recovery-metadata"
LOCK_FILE="$SCRIPT_DIR/.backup.lock"
HISTORY_FILE="$SCRIPT_DIR/backup-history.log"

DRY_RUN=0
PRUNE=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --prune)   PRUNE=1 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

SNAP_MOUNT=/mnt/root-backup-snapshot
SNAP_LV_NAME=root-backup-snapshot
KEEP_DAILY=${KEEP_DAILY:-7}
KEEP_WEEKLY=${KEEP_WEEKLY:-4}
KEEP_MONTHLY=${KEEP_MONTHLY:-6}

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

SNAP_CREATED=0
TMP_JSON_FILES=()
cleanup() {
  local ec=$?
  set +e
  if [[ $SNAP_CREATED -eq 1 ]]; then
    echo "Прибирання: розмонтування та видалення тимчасового LVM snapshot"
    umount "$SNAP_MOUNT" 2>/dev/null
    lvremove -f "/dev/$VG_NAME/$SNAP_LV_NAME" 2>/dev/null
  fi
  [[ ${#TMP_JSON_FILES[@]} -gt 0 ]] && rm -f "${TMP_JSON_FILES[@]}"
  unset RESTIC_PASSWORD
  if [[ $ec -ne 0 ]]; then
    echo "Скрипт завершився з помилкою (код $ec) на кроці: $CURRENT_STEP" >&2
    history_log failed "exit_code=$ec"
  fi
  exit $ec
}
trap cleanup EXIT

# Не давати двом копіям скрипта (напр. cron + ручний запуск) працювати
# одночасно — інакше обидва спробують створити той самий LVM snapshot і
# зіткнуться в restic-локах репозиторію. Не блокуємось в очікуванні:
# просто виходимо, наступний тригер (за розкладом) спробує пізніше.
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
  echo "Інший запуск backup-system.sh вже триває (лок $LOCK_FILE зайнятий) — пропускаю цей запуск." >&2
  history_log skipped "reason=already_running"
  exit 0
fi

CURRENT_STEP="verify_repo"
[[ -d "$REPO" && -f "$REPO/config" ]] || die "Не знайдено restic репозиторій: $REPO"

# ---------------------------------------------------------------------------
# 1. Detect root LVM layout
# ---------------------------------------------------------------------------

CURRENT_STEP="detect_lvm"
log "Визначення поточної LVM-конфігурації"
ROOT_SRC=$(findmnt -no SOURCE /) || die "Не вдалося визначити пристрій /"
ROOT_SRC_RESOLVED=$(readlink -f "$ROOT_SRC")

# lvm повідомляє lv_path у форматі /dev/VG/LV (символічне посилання), а
# readlink -f на нього (чи на /dev/mapper/...) веде до /dev/dm-N — вони
# ніколи не збігаються рядково. lvs натомість сам приймає будь-який шлях
# до пристрою (символічний чи ні) як позиційний аргумент і сам резолвить
# його, тому --select "lv_path=..." тут зайвий і хибний.
read -r VG_NAME LV_NAME < <(lvs --noheadings -o vg_name,lv_name "$ROOT_SRC" 2>/dev/null | awk '{print $1,$2}')
[[ -n "${VG_NAME:-}" && -n "${LV_NAME:-}" ]] || die "/ не на LVM LV — цей скрипт розрахований саме на LVM-on-LUKS шар цієї системи"

PV_NAME=$(pvs --noheadings -o pv_name --select "vg_name=$VG_NAME" | head -1 | tr -d ' ')
CRYPT_NAME=$(basename "$PV_NAME")
LUKS_PART=$(cryptsetup status "$CRYPT_NAME" | awk '/device:/{print $2}')
[[ -n "$LUKS_PART" ]] || die "Не вдалося визначити LUKS-розділ під $CRYPT_NAME"

BOOT_SRC=$(findmnt -no SOURCE /boot) || die "Не вдалося визначити пристрій /boot"
ESP_SRC=$(findmnt -no SOURCE /boot/efi) || die "Не вдалося визначити пристрій /boot/efi"
# -d обов'язковий: без нього lsblk показує весь ланцюжок нащадків
# (partition -> cryptroot -> LV), і DISK стає багаторядковим сміттям
# замість "nvme0n1".
DISK=$(lsblk -no PKNAME -d "$LUKS_PART")
[[ -n "$DISK" ]] || die "Не вдалося визначити диск під $LUKS_PART"

echo "Root LV:    $VG_NAME/$LV_NAME  ($ROOT_SRC_RESOLVED)"
echo "LUKS:       $LUKS_PART -> $CRYPT_NAME"
echo "Диск:       /dev/$DISK"
echo "/boot:      $BOOT_SRC"
echo "/boot/efi:  $ESP_SRC"

# ---------------------------------------------------------------------------
# 2. Snapshot sizing
# ---------------------------------------------------------------------------

CURRENT_STEP="snapshot_sizing"
log "Розрахунок розміру LVM snapshot"
VG_FREE_G=$(LC_ALL=C vgs --noheadings --units g -o vg_free "$VG_NAME" | tr -d ' g')
LV_SIZE_G=$(LC_ALL=C lvs --noheadings --units g -o lv_size "$VG_NAME/$LV_NAME" | tr -d ' g')
# Enough COW space for changes made *during* the backup: min(20% of LV, свободное) but not less than 5G.
SNAP_SIZE_G=$(python3 -c "
free=$VG_FREE_G; lv=$LV_SIZE_G
want=max(5.0, lv*0.2)
print(int(min(free-1, want)))
")
[[ $SNAP_SIZE_G -ge 5 ]] || die "Недостатньо вільного місця у VG для snapshot (вільно ${VG_FREE_G}G, потрібно мінімум 5G)"
echo "VG вільно: ${VG_FREE_G}G, LV: ${LV_SIZE_G}G -> snapshot: ${SNAP_SIZE_G}G"

if lvs "$VG_NAME/$SNAP_LV_NAME" >/dev/null 2>&1; then
  echo "Знайдено старий $SNAP_LV_NAME від попереднього невдалого запуску — видаляю"
  umount "$SNAP_MOUNT" 2>/dev/null || true
  lvremove -f "$VG_NAME/$SNAP_LV_NAME"
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
sgdisk --backup="$META/nvme0n1.gpt" "/dev/$DISK"
sfdisk -d "/dev/$DISK" > "$META/nvme0n1.sfdisk"
blkid > "$META/blkid.txt"
lsblk > "$META/lsblk.txt"
pvs > "$META/pvs.txt"
vgs > "$META/vgs.txt"
lvs -a -o lv_name,lv_size,pool_lv,origin,data_percent,vg_name,lv_attr > "$META/lvs.txt"
vgcfgbackup -f "$META/ubuntu-vg.conf" "$VG_NAME"
cryptsetup luksHeaderBackup "$LUKS_PART" --header-backup-file "$META/nvme0n1p3-luks-header.img.new"
mv "$META/nvme0n1p3-luks-header.img.new" "$META/nvme0n1p3-luks-header.img"
chmod 600 "$META/nvme0n1p3-luks-header.img" "$META/ubuntu-vg.conf"
echo "OK: recovery-metadata оновлено"

# ---------------------------------------------------------------------------
# 5. LVM snapshot + mount
# ---------------------------------------------------------------------------

CURRENT_STEP="create_snapshot"
log "Створення LVM snapshot кореня (для консистентної точки в часі)"
lvcreate --size "${SNAP_SIZE_G}G" --snapshot --name "$SNAP_LV_NAME" "$VG_NAME/$LV_NAME"
SNAP_CREATED=1
mkdir -p "$SNAP_MOUNT"
mount -o ro "/dev/$VG_NAME/$SNAP_LV_NAME" "$SNAP_MOUNT"

# ---------------------------------------------------------------------------
# 6. Restic backup — root, boot, metadata in one run
# ---------------------------------------------------------------------------

RUN_TAG="run-$(date +%Y%m%d-%H%M%S)"

CURRENT_STEP="backup_root"
log "restic backup: system-root ($SNAP_MOUNT) — без живого прогресу (--json), може виглядати як пауза"
ROOT_JSON=$(mktemp); TMP_JSON_FILES+=("$ROOT_JSON")
restic -r "$REPO" backup "$SNAP_MOUNT" --tag system-root --tag "$RUN_TAG" --json > "$ROOT_JSON"
read -r ROOT_ADDED ROOT_FILES_NEW ROOT_FILES_CHANGED ROOT_SNAPID < <(summarize_backup "$ROOT_JSON")
echo "system-root: +$(human_bytes "$ROOT_ADDED") нових даних, нових/змінених файлів: $ROOT_FILES_NEW/$ROOT_FILES_CHANGED, snapshot $ROOT_SNAPID"

CURRENT_STEP="backup_boot"
log "restic backup: system-boot (/boot, /boot/efi)"
BOOT_JSON=$(mktemp); TMP_JSON_FILES+=("$BOOT_JSON")
restic -r "$REPO" backup /boot --tag system-boot --tag "$RUN_TAG" --json > "$BOOT_JSON"
read -r BOOT_ADDED BOOT_FILES_NEW BOOT_FILES_CHANGED BOOT_SNAPID < <(summarize_backup "$BOOT_JSON")
echo "system-boot: +$(human_bytes "$BOOT_ADDED") нових даних, нових/змінених файлів: $BOOT_FILES_NEW/$BOOT_FILES_CHANGED, snapshot $BOOT_SNAPID"

CURRENT_STEP="backup_metadata"
log "restic backup: recovery-metadata"
META_JSON=$(mktemp); TMP_JSON_FILES+=("$META_JSON")
restic -r "$REPO" backup "$META" --tag recovery-metadata --tag "$RUN_TAG" --json > "$META_JSON"
read -r META_ADDED _ _ META_SNAPID < <(summarize_backup "$META_JSON")
echo "recovery-metadata: +$(human_bytes "$META_ADDED") нових даних, snapshot $META_SNAPID"

# ---------------------------------------------------------------------------
# 7. Cleanup snapshot (also handled by trap, done explicitly here for order)
# ---------------------------------------------------------------------------

CURRENT_STEP="remove_snapshot"
log "Видалення тимчасового LVM snapshot"
umount "$SNAP_MOUNT"
lvremove -f "$VG_NAME/$SNAP_LV_NAME"
SNAP_CREATED=0

# ---------------------------------------------------------------------------
# 8. Optional retention + integrity check
# ---------------------------------------------------------------------------

if [[ $PRUNE -eq 1 ]]; then
  CURRENT_STEP="prune"
  log "Застосування retention policy (daily=$KEEP_DAILY weekly=$KEEP_WEEKLY monthly=$KEEP_MONTHLY)"
  for tag in system-root system-boot recovery-metadata; do
    restic -r "$REPO" forget --tag "$tag" \
      --keep-daily "$KEEP_DAILY" --keep-weekly "$KEEP_WEEKLY" --keep-monthly "$KEEP_MONTHLY"
  done
  restic -r "$REPO" prune
fi

CURRENT_STEP="check_repo"
log "Перевірка репозиторію (без читання даних, швидко)"
restic -r "$REPO" check

CURRENT_STEP="done"
log "Готово"
restic -r "$REPO" snapshots --tag "$RUN_TAG"
echo "Новий backup завершено з тегом $RUN_TAG"

TOTAL_ADDED=$(( ROOT_ADDED + BOOT_ADDED + META_ADDED ))
history_log success \
  "root_added=$ROOT_ADDED" "boot_added=$BOOT_ADDED" "meta_added=$META_ADDED" "total_added=$TOTAL_ADDED" \
  "root_snapshot=$ROOT_SNAPID" "boot_snapshot=$BOOT_SNAPID" "meta_snapshot=$META_SNAPID" \
  "pruned=$([[ $PRUNE -eq 1 ]] && echo yes || echo no)"
echo "Усього додано за цей запуск: $(human_bytes "$TOTAL_ADDED")"
