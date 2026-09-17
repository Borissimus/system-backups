#!/usr/bin/env bash
#
# restore-system.sh — full system restore from the restic repository in this
# directory (system-backups/) onto a target disk, following the "512 GB test
# scenario" procedure from RECOVERY.md, generalized to any target disk size.
#
# Run from a UEFI Ubuntu Live USB with the backup medium mounted (this script
# must live inside system-backups/ next to restic/ and recovery-metadata/).
#
#   sudo bash restore-system.sh --dry-run          # verify everything, touch nothing
#   sudo bash restore-system.sh                    # perform the real restore
#   sudo bash restore-system.sh --status           # show which steps are done
#   sudo bash restore-system.sh --reset            # forget all progress, start over
#   sudo bash restore-system.sh --retry-step=NAME  # redo one step (and everything after it)
#
# Progress journal: every destructive/expensive step is recorded in
# .restore-progress next to this script. If the script is interrupted (bad
# password, transient error, etc.), fix the problem and re-run the exact same
# command — already-completed steps are skipped automatically, only the
# failed step (and anything after it) runs again.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Setup / self-location
# ---------------------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
  exec sudo -E bash "$0" "$@"
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO="$SCRIPT_DIR/restic"
META="$SCRIPT_DIR/recovery-metadata"
STATE_FILE="$SCRIPT_DIR/.restore-progress"

DRY_RUN=0
STATUS_ONLY=0
RESET=0
RETRY_STEP=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --status) STATUS_ONLY=1 ;;
    --reset) RESET=1 ;;
    --retry-step=*) RETRY_STEP="${arg#--retry-step=}" ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

MNT_TARGET=/mnt/target
# Проміжна тека лише для /boot (кілька сотень MB) — навмисно НЕ на
# overlay Live-сесії (той на цій машині обмежений ~63G і забивається
# вщент навіть на /boot, не кажучи вже про корінь), а на диску бекапу
# поруч зі скриптом — там завжди є достатньо вільного місця для такого
# малого об'єму. Корінь (275G) відновлюється окремо, без проміжної
# теки взагалі — див. крок restore_root.
MNT_RESTORE="$SCRIPT_DIR/.restic-restore-tmp"
VG_NAME=ubuntu-vg
LV_NAME=ubuntu-lv
CRYPT_NAME=cryptroot

log()  { echo -e "\n=== $* ==="; }
die()  { echo "ПОМИЛКА: $*" >&2; exit 1; }

# Перевірка вільного місця НАПЕРЕД, перш ніж щось писати у $2 (шлях) —
# щоб дізнатись про нестачу місця з чіткою помилкою до того, як
# restic/rsync намолотять тисячі "no space left on device" посеред
# багатогодинного відновлення.
require_free_space_gib() {
  local need_gib="$1" path="$2"
  local avail_kib avail_gib
  avail_kib=$(df --output=avail -k "$path" 2>/dev/null | tail -1 | tr -d ' ')
  avail_gib=$(( avail_kib / 1024 / 1024 ))
  [[ $avail_gib -ge $need_gib ]] || die "Недостатньо вільного місця на $path: потрібно ~${need_gib}G, вільно лише ${avail_gib}G"
  echo "OK: на $path вільно ${avail_gib}G (потрібно ~${need_gib}G)"
}

# ---------------------------------------------------------------------------
# Progress journal — lets a failed run be resumed without repeating already
# completed (and often slow/destructive) steps.
# ---------------------------------------------------------------------------

step_done() { [[ -f "$STATE_FILE" ]] && grep -qxF "$1" "$STATE_FILE"; }
mark_done() { echo "$1" >> "$STATE_FILE"; }
forget_from() {
  [[ -f "$STATE_FILE" ]] || return 0
  sed -i "/^$1\$/,\$d" "$STATE_FILE"
}

# Small key=value cache (separate from the step journal above) for results
# that are expensive to recompute but cheap to invalidate correctly, e.g.
# "restic stats" over a multi-hundred-GiB snapshot.
CACHE_FILE="$SCRIPT_DIR/.restore-cache"
# Завжди повертає 0, незалежно від того, чи знайдено ключ — інакше
# "VAR=$(cache_get ...)" при відсутньому кеші (не 0 tut) миттєво вбиває
# скрипт через set -e ще ДО будь-якого виводу (перевірено репродукцією:
# голе "VAR=$(false)" без ||/if — фатальне під set -e, навіть якщо саме
# значення нікому "не потрібне" як умова). Відсутність значення й так
# сигналізується порожнім виводом — виклики перевіряють через -n "$VAR".
cache_get() { [[ -f "$CACHE_FILE" ]] && grep -m1 "^$1=" "$CACHE_FILE" | cut -d= -f2-; true; }
cache_set() {
  local key="$1" val="$2"
  touch "$CACHE_FILE"
  grep -v "^$key=" "$CACHE_FILE" > "$CACHE_FILE.tmp" 2>/dev/null || true
  mv "$CACHE_FILE.tmp" "$CACHE_FILE"
  echo "$key=$val" >> "$CACHE_FILE"
}
# Skip a step already marked done in the journal, but only if a live check
# confirms the disk still matches — guards against the journal going stale
# because someone fixed things by hand between runs.
step_done_verified() {
  local name="$1" check="$2"
  step_done "$name" || return 1
  if eval "$check" >/dev/null 2>&1; then
    return 0
  fi
  echo "Журнал каже, що крок «$name» виконано, але реальний стан диска не відповідає — повторюю цей крок і все після нього."
  forget_from "$name"
  return 1
}

if [[ $STATUS_ONLY -eq 1 ]]; then
  echo "Журнал прогресу: $STATE_FILE"
  if [[ -s "$STATE_FILE" ]]; then
    echo "Виконані кроки:"
    nl -ba "$STATE_FILE"
  else
    echo "(порожньо — жодного кроку ще не виконано)"
  fi
  exit 0
fi

if [[ $RESET -eq 1 ]]; then
  rm -f "$STATE_FILE" "$CACHE_FILE"
  echo "Журнал прогресу і кеш скинуто. Наступний звичайний запуск почне все з нуля (включно з очищенням диска)."
  exit 0
fi

if [[ -n "$RETRY_STEP" ]]; then
  forget_from "$RETRY_STEP"
  echo "Журнал відкочено до кроку «$RETRY_STEP» — він і все після нього виконаються знову."
fi

CURRENT_STEP=""
declare -A STEP_HINTS=(
  [wipe_partition]="Диск не вдалося очистити/розбити — ймовірно він 'зайнятий' (LVM/LUKS з попередньої спроби автоактивувались, або щось змонтовано). Скрипт уже намагався розчистити це сам; якщо не вийшло — перевірте вручну: dmsetup ls, lsblk -f, findmnt, ps aux | grep subiquity. Виправте і перезапустіть той самий командний рядок — журнал сам пропустить пройдені кроки."
  [luks_header_restore]="cryptsetup питає підтвердження і приймає ЛИШЕ 'YES' великими літерами (не 'yes', не 'Yes'). Просто перезапустіть той самий командний рядок — цей крок повториться."
  [luks_open]="Найімовірніше введено невірний пароль LUKS. Перезапустіть той самий командний рядок — крок повториться (журнал не позначив його виконаним)."
  [lvm_create]="Не вдалося створити PV/VG/LV на /dev/mapper/$CRYPT_NAME. Перевірте pvs/vgs/lvs — можливо, стара VG з такою назвою вже існує. Виправте і перезапустіть той самий командний рядок."
  [format_filesystems]="Форматування ESP/boot/root не вдалося. Перевірте recovery-metadata/blkid.txt (UUID мають бути валідними) і що розділи існують (lsblk). Перезапустіть той самий командний рядок."
  [mount_targets]="Монтування цільових файлових систем не вдалося. Перевірте findmnt /mnt/target та dmesg | tail. За потреби розмонтуйте вручну (umount -R /mnt/target) і перезапустіть той самий командний рядок."
  [restore_root]="restic restore/rsync кореня перервались (мережа, місце на диску, Ctrl+C?). Це найдовший крок. Перевірте вільне місце (df -h /mnt/target) і перезапустіть той самий командний рядок — крок повториться повністю."
  [restore_boot]="restic restore/rsync /boot перервались. Перевірте вільне місце й доступ до носія бекапу, потім перезапустіть той самий командний рядок."
  [fstab_fixup]="Виправлення /etc/fstab на цілі не вдалося — ймовірно $MNT_TARGET/etc/fstab відсутній (крок restore_root не завершився як слід). Перевірте --retry-step=restore_root."
  [chroot_grub]="update-initramfs / grub-install / update-grub впали всередині chroot. Прогляньте вивід вище (типово: немає мережі для постскриптів пакетів, або невірний EFI-розділ). Перезапустіть той самий командний рядок — initramfs/grub безпечно перегенерувати ще раз."
)

cleanup() {
  local ec=$?
  set +e
  # Захисне розмонтування bind-mount для restore_root, якщо скрипт
  # перервався (Ctrl+C, сигнал) точно між mount --bind і umount.
  findmnt -M /mnt/root-backup-snapshot >/dev/null 2>&1 && umount /mnt/root-backup-snapshot 2>/dev/null
  unset RESTIC_PASSWORD
  if [[ $ec -ne 0 ]]; then
    echo -e "\nСкрипт перервано (код $ec) на кроці: ${CURRENT_STEP:-<до початку основних кроків>}" >&2
    if [[ -n "$CURRENT_STEP" && -n "${STEP_HINTS[$CURRENT_STEP]:-}" ]]; then
      echo "Підказка: ${STEP_HINTS[$CURRENT_STEP]}" >&2
    fi
    echo "Стан диска/LVM/LUKS може бути частковим. Перевірте: findmnt, lsblk -f, vgs, lvs, cryptsetup status $CRYPT_NAME" >&2
    echo "Прогрес збережено в $STATE_FILE — після виправлення просто перезапустіть той самий командний рядок; вже пройдені кроки не повторюватимуться." >&2
    echo "Переглянути прогрес:  sudo bash $0 --status" >&2
    echo "Примусово повторити конкретний крок:  sudo bash $0 --retry-step=<назва>" >&2
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. Verify backup structure
# ---------------------------------------------------------------------------

log "Перевірка структури бекапу в $SCRIPT_DIR"
[[ -d "$REPO" ]] || die "Не знайдено restic репозиторій: $REPO"
[[ -f "$REPO/config" ]] || die "У $REPO немає config — це не restic репозиторій"
for f in blkid.txt nvme0n1.sfdisk nvme0n1p3-luks-header.img; do
  [[ -e "$META/$f" ]] || die "Відсутній файл метаданих: $META/$f"
done
echo "OK: restic/ та recovery-metadata/ на місці"

# ---------------------------------------------------------------------------
# 2. Tool check
# ---------------------------------------------------------------------------

log "Перевірка необхідних утиліт"
REQUIRED_TOOLS=(restic sgdisk cryptsetup pvcreate vgcreate lvcreate mkfs.fat mkfs.ext4 rsync grub-install efibootmgr update-grub partprobe udevadm wipefs)
MISSING=()
for t in "${REQUIRED_TOOLS[@]}"; do
  command -v "$t" >/dev/null 2>&1 || MISSING+=("$t")
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "Відсутні утиліти: ${MISSING[*]}"
  echo "Спроба встановити (потрібна мережа)..."
  apt update -qq
  apt install -y restic lvm2 cryptsetup rsync gdisk dosfstools grub-efi-amd64 efibootmgr
fi
echo "OK: усі утиліти доступні"

# ---------------------------------------------------------------------------
# 3. Restic password + repo sanity check
# ---------------------------------------------------------------------------

log "Пароль репозиторію restic"
RESTIC_ATTEMPTS=3
for ((attempt = 1; attempt <= RESTIC_ATTEMPTS; attempt++)); do
  echo "Введіть пароль restic-репозиторію (нікуди не зберігається, тільки для цього запуску):"
  read -rs -p "Restic password: " RESTIC_PASSWORD
  echo
  export RESTIC_PASSWORD
  if restic -r "$REPO" snapshots >/tmp/restic-snapshots.out 2>&1; then
    break
  fi
  unset RESTIC_PASSWORD
  if [[ $attempt -eq $RESTIC_ATTEMPTS ]]; then
    cat /tmp/restic-snapshots.out >&2
    die "Не вдалося прочитати restic snapshots після $RESTIC_ATTEMPTS спроб (невірний пароль або пошкоджений репозиторій)"
  fi
  echo "Не вдалося прочитати репозиторій (невірний пароль?). Спроба $((attempt + 1)) з $RESTIC_ATTEMPTS."
done
cat /tmp/restic-snapshots.out

for tag in system-root system-boot; do
  restic -r "$REPO" snapshots --tag "$tag" --latest 1 --json > "/tmp/restic-$tag.json"
  [[ -s "/tmp/restic-$tag.json" && "$(cat /tmp/restic-$tag.json)" != "[]" ]] \
    || die "Немає жодного snapshot з тегом $tag"
done

ROOT_TIME=$(python3 -c "import json;print(json.load(open('/tmp/restic-system-root.json'))[0]['time'])")
BOOT_TIME=$(python3 -c "import json;print(json.load(open('/tmp/restic-system-boot.json'))[0]['time'])")
echo "Останній snapshot system-root: $ROOT_TIME"
echo "Останній snapshot system-boot: $BOOT_TIME"

ROOT_EPOCH=$(date -d "$ROOT_TIME" +%s)
BOOT_EPOCH=$(date -d "$BOOT_TIME" +%s)
DIFF=$(( ROOT_EPOCH > BOOT_EPOCH ? ROOT_EPOCH - BOOT_EPOCH : BOOT_EPOCH - ROOT_EPOCH ))
if [[ $DIFF -gt 3600 ]]; then
  echo "УВАГА: root і boot snapshot відрізняються за часом більш ніж на годину ($((DIFF/60)) хв)."
  echo "Якщо між ними оновлювалось ядро/GRUB/LUKS/LVM — відновлена система може не завантажитись."
  read -rp "Продовжити попри це? [yes/NO]: " ans
  [[ "$ans" == "yes" ]] || die "Скасовано користувачем"
fi

# restic stats --mode restore-size обходить усе дерево метаданих snapshot'у
# і на ~270 GiB реально займає хвилину чи більше — не рахуємо його заново
# на кожному повторному запуску, а кешуємо результат прив'язаним до
# конкретного snapshot'у (ROOT_TIME); якщо з'явиться новіший snapshot,
# кеш сам стане невалідним і порахується заново.
CACHED_FOR=$(cache_get restore_size_for_snapshot)
CACHED_GIB=$(cache_get restore_size_gib)
if [[ "$CACHED_FOR" == "$ROOT_TIME" && -n "$CACHED_GIB" ]]; then
  RESTORE_SIZE_GIB="$CACHED_GIB"
  echo "Розмір даних (кеш для snapshot $ROOT_TIME): ~${RESTORE_SIZE_GIB} GiB"
else
  log "Розмір даних для відновлення (restic stats) — може зайняти хвилину-дві"
  RESTORE_SIZE_BYTES=$(restic -r "$REPO" stats latest --tag system-root --mode restore-size --json | python3 -c "import json,sys;print(json.load(sys.stdin)['total_size'])")
  RESTORE_SIZE_GIB=$(( RESTORE_SIZE_BYTES / 1024 / 1024 / 1024 ))
  echo "Потрібно під корінь системи: ~${RESTORE_SIZE_GIB} GiB"
  cache_set restore_size_for_snapshot "$ROOT_TIME"
  cache_set restore_size_gib "$RESTORE_SIZE_GIB"
fi

# ---------------------------------------------------------------------------
# 4. Target disk selection
# ---------------------------------------------------------------------------

log "Пошук кандидатів на цільовий диск"

BACKUP_SRC_DISK=""
BACKUP_MOUNT_SRC=$(findmnt -no SOURCE --target "$SCRIPT_DIR" || true)
if [[ -n "$BACKUP_MOUNT_SRC" ]]; then
  BACKUP_SRC_DISK=$(lsblk -no PKNAME "$BACKUP_MOUNT_SRC" 2>/dev/null || true)
fi

CDROM_SRC_DISK=""
CDROM_MOUNT_SRC=$(findmnt -no SOURCE /cdrom 2>/dev/null || true)
if [[ -n "$CDROM_MOUNT_SRC" ]]; then
  CDROM_SRC_DISK=$(lsblk -no PKNAME "$CDROM_MOUNT_SRC" 2>/dev/null || true)
fi

mapfile -t ALL_DISKS < <(lsblk -dn -o NAME,TYPE | awk '$2=="disk"{print $1}')
CANDIDATES=()
for d in "${ALL_DISKS[@]}"; do
  [[ -n "$BACKUP_SRC_DISK" && "$d" == "$BACKUP_SRC_DISK" ]] && continue
  [[ -n "$CDROM_SRC_DISK" && "$d" == "$CDROM_SRC_DISK" ]] && continue
  CANDIDATES+=("$d")
done

[[ ${#CANDIDATES[@]} -gt 0 ]] || die "Не знайдено жодного придатного цільового диска (все виключено як джерело бекапу/Live USB)"

echo "Диск бекапу (виключено): ${BACKUP_SRC_DISK:-невідомо}"
echo "Live USB (виключено): ${CDROM_SRC_DISK:-невідомо}"
echo
echo "Кандидати на цільовий диск:"
printf "%-10s %-10s %-30s %-20s %s\n" "NAME" "SIZE" "MODEL" "SERIAL" "TRAN"
for d in "${CANDIDATES[@]}"; do
  lsblk -dn -o NAME,SIZE,MODEL,SERIAL,TRAN "/dev/$d" | awk -v n="$d" '{printf "%-10s %-10s %-30s %-20s %s\n",$1,$2,$3,$4,$5}'
done
echo

if [[ ${#CANDIDATES[@]} -eq 1 ]]; then
  SUGGESTED="${CANDIDATES[0]}"
  echo "Єдиний кандидат: /dev/$SUGGESTED"
else
  SUGGESTED=""
  echo "Знайдено декілька можливих цільових дисків — виберіть один вручну."
fi

read -rp "Введіть ім'я цільового диска (наприклад nvme0n1)${SUGGESTED:+ [$SUGGESTED]}: " DISK_NAME
DISK_NAME="${DISK_NAME:-$SUGGESTED}"
[[ -n "$DISK_NAME" ]] || die "Диск не вказано"
printf '%s\n' "${CANDIDATES[@]}" | grep -qx "$DISK_NAME" || die "«$DISK_NAME» немає серед перевірених кандидатів"

DISK="/dev/$DISK_NAME"
[[ -b "$DISK" ]] || die "$DISK не є блоковим пристроєм"

case "$DISK_NAME" in
  *[0-9]) PSEP=p ;;
  *) PSEP="" ;;
esac
ESP="${DISK}${PSEP}1"
BOOT="${DISK}${PSEP}2"
LUKS="${DISK}${PSEP}3"

TARGET_SIZE=$(blockdev --getsize64 "$DISK")
TARGET_SIZE_GIB=$(( TARGET_SIZE / 1024 / 1024 / 1024 ))
# || true: якщо диск не звітує ID_MODEL/ID_SERIAL (буває на деяких
# контролерах) — це не привід валити весь скрипт, лишити поле порожнім.
MODEL=$(udevadm info --query=property --name="$DISK" | grep '^ID_MODEL=' | cut -d= -f2- || true)
SERIAL=$(udevadm info --query=property --name="$DISK" | grep '^ID_SERIAL=' | cut -d= -f2- || true)

REQUIRED_MIN_GIB=$(( RESTORE_SIZE_GIB + 3 + 10 ))  # +ESP/BOOT overhead +headroom
echo
echo "Ціль: $DISK  ($TARGET_SIZE_GIB GiB, модель: $MODEL, серійний: $SERIAL)"
if [[ $TARGET_SIZE_GIB -lt $REQUIRED_MIN_GIB ]]; then
  die "Диск замалий: $TARGET_SIZE_GIB GiB < мінімум $REQUIRED_MIN_GIB GiB"
fi
echo "OK: розміру достатньо (потрібно мінімум ~$REQUIRED_MIN_GIB GiB)"

if [[ $DRY_RUN -eq 1 ]]; then
  log "--dry-run: перевірку завершено, диск НЕ змінювався"
  exit 0
fi

# ---------------------------------------------------------------------------
# 5. Final destructive confirmation
# ---------------------------------------------------------------------------

echo
echo "############################################################"
echo "# УВАГА: наступні кроки ЗНИЩАТЬ УСІ ДАНІ на $DISK"
echo "# Модель: $MODEL   Серійний: $SERIAL   Розмір: $TARGET_SIZE_GIB GiB"
echo "############################################################"
read -rp "Щоб продовжити, введіть точний шлях диска ($DISK): " CONFIRM
[[ "$CONFIRM" == "$DISK" ]] || die "Підтвердження не збіглося — скасовано"

LUKS_PART_NAME="$(basename "$LUKS")"

# ---------------------------------------------------------------------------
# 6. Wipe + partition
# ---------------------------------------------------------------------------

if step_done_verified wipe_partition '[[ -b "$ESP" && -b "$BOOT" && -b "$LUKS" ]]'; then
  log "Крок wipe_partition вже виконано — пропускаю"
else
  CURRENT_STEP=wipe_partition

  # На Ubuntu Desktop Live USB у фоні працює subiquity-server (сервіс
  # інсталятора, snap ubuntu-desktop-bootstrap) — він постійно пробує диски
  # і автоматично реактивує будь-яку знайдену LVM/LUKS через секунду після
  # нашої деактивації (класична гонка: dmsetup ls одразу після деактивації
  # показує "чисто", а через ~1с розділ знову зайнятий). Без цього кроку
  # wipefs/sgdisk/cryptsetup close нижче можуть впасти з "Device or
  # resource busy" навіть якщо на вигляд нічого не тримає диск.
  if command -v snap >/dev/null 2>&1; then
    snap stop ubuntu-desktop-bootstrap.subiquity-server 2>/dev/null || true
  fi

  log "Розмонтування розділів $DISK (якщо є) та очищення старих LVM/LUKS"
  for part in "$DISK"?*; do
    [[ -b "$part" ]] || continue
    mountpoint_list=$(findmnt -rno TARGET -S "$part" || true)
    for mp in $mountpoint_list; do
      echo "umount $mp"
      umount -R "$mp" 2>/dev/null || {
        echo "Звичайний umount не вдався (щось тримає $mp зайнятим) — пробую lazy unmount"
        umount -l "$mp"
      }
    done
  done

  # Порядок важливий: спершу деактивувати VG (звільняє LV, що сидить на
  # cryptroot), і лише потім закривати LUKS-мапінг — навпаки cryptsetup
  # close мовчки провалюється (device busy, LV ще тримає його), LUKS
  # лишається відкритим і тримає весь диск зайнятим для wipefs/sgdisk.
  # На Live USB щось може автоактивувати VG назад, тому повторюємо в циклі
  # й примусово прибираємо dm-мапінги як останній крок.
  TEARDOWN_ATTEMPTS=5
  for ((attempt = 1; attempt <= TEARDOWN_ATTEMPTS; attempt++)); do
    vgchange -an "$VG_NAME" 2>/dev/null || true
    cryptsetup close "$CRYPT_NAME" 2>/dev/null || true
    udevadm settle
    HOLDERS=$(ls "/sys/class/block/$LUKS_PART_NAME/holders" 2>/dev/null || true)
    [[ -z "$HOLDERS" ]] && break
    if [[ $attempt -eq $TEARDOWN_ATTEMPTS ]]; then
      echo "Диск досі зайнятий ($HOLDERS) після $TEARDOWN_ATTEMPTS спроб — примусово видаляю dm-мапінги"
      dmsetup remove -f "${VG_NAME//-/--}-${LV_NAME//-/--}" 2>/dev/null || true
      dmsetup remove -f "$CRYPT_NAME" 2>/dev/null || true
      udevadm settle
    else
      sleep 1
    fi
  done
  HOLDERS=$(ls "/sys/class/block/$LUKS_PART_NAME/holders" 2>/dev/null || true)
  [[ -z "$HOLDERS" ]] || die "Не вдалося звільнити $LUKS від старих LVM/LUKS (holders: $HOLDERS) — перевірте вручну: dmsetup ls, lsblk -f"

  log "Створення нової GPT-таблиці на $DISK (ESP 1G, /boot 2G, LVM решта)"
  wipefs -a "$DISK"
  sgdisk --zap-all "$DISK"
  sgdisk --new=1:0:+1G  --typecode=1:ef00 \
         --new=2:0:+2G  --typecode=2:8300 \
         --new=3:0:0    --typecode=3:8300 "$DISK"
  partprobe "$DISK"
  udevadm settle

  mark_done wipe_partition
  CURRENT_STEP=""
fi

# ---------------------------------------------------------------------------
# 7. LUKS + LVM
# ---------------------------------------------------------------------------

if step_done_verified luks_header_restore 'cryptsetup isLuks "$LUKS"'; then
  log "Крок luks_header_restore вже виконано — пропускаю"
else
  CURRENT_STEP=luks_header_restore
  log "Відновлення LUKS header на $LUKS"
  LUKS_ATTEMPTS=3
  attempt=1
  until cryptsetup luksHeaderRestore "$LUKS" --header-backup-file "$META/nvme0n1p3-luks-header.img"; do
    if [[ $attempt -eq $LUKS_ATTEMPTS ]]; then
      die "Не вдалося відновити LUKS header після $LUKS_ATTEMPTS спроб"
    fi
    echo "Не вдалося відновити LUKS header (перевірте, що на запит підтвердження вводите саме YES великими літерами). Спроба $((attempt + 1)) з $LUKS_ATTEMPTS."
    ((attempt++))
  done
  cryptsetup luksDump "$LUKS" >/dev/null
  mark_done luks_header_restore
  CURRENT_STEP=""
fi

if step_done_verified luks_open 'cryptsetup status "$CRYPT_NAME"'; then
  log "Крок luks_open вже виконано (LUKS вже відкритий) — пропускаю"
else
  CURRENT_STEP=luks_open
  echo "Введіть пароль LUKS (той самий, яким шифрувалась оригінальна система):"
  attempt=1
  LUKS_ATTEMPTS=3
  until cryptsetup open "$LUKS" "$CRYPT_NAME"; do
    if [[ $attempt -eq $LUKS_ATTEMPTS ]]; then
      die "Не вдалося відкрити LUKS-розділ після $LUKS_ATTEMPTS спроб (невірний пароль?)"
    fi
    echo "Не вдалося відкрити LUKS-розділ (невірний пароль?). Спроба $((attempt + 1)) з $LUKS_ATTEMPTS."
    ((attempt++))
    echo "Введіть пароль LUKS (той самий, яким шифрувалась оригінальна система):"
  done
  mark_done luks_open
  CURRENT_STEP=""
fi

if step_done_verified lvm_create "lvs '$VG_NAME/$LV_NAME'"; then
  log "Крок lvm_create вже виконано — пропускаю"
  lvs -o lv_name,lv_size,vg_name,lv_attr
else
  CURRENT_STEP=lvm_create
  log "Створення LVM (PV/VG/LV, LV = 90% вільного місця у VG)"
  pvcreate -ff -y "/dev/mapper/$CRYPT_NAME"
  vgcreate "$VG_NAME" "/dev/mapper/$CRYPT_NAME"
  lvcreate -l 90%FREE -n "$LV_NAME" "$VG_NAME"
  lvs -o lv_name,lv_size,vg_name,lv_attr
  mark_done lvm_create
  CURRENT_STEP=""
fi

ROOT_LV="/dev/mapper/${VG_NAME//-/--}-${LV_NAME//-/--}"

# ---------------------------------------------------------------------------
# 8. Filesystems
# ---------------------------------------------------------------------------

log "Читання UUID з recovery-metadata/blkid.txt"
# (?<!PART) виключає PARTUUID="..." — інакше "UUID=" матчиться і всередині
# "PARTUUID=" (це підрядок), і в ESP_UUID/BOOT_UUID потрапляють обидва
# значення одразу (багаторядково), що ламає mkfs.fat -i / mkfs.ext4 -U.
# || true: якщо grep нічого не знайде (malformed blkid.txt), пайплайн
# поверне 1, і без цього голе "VAR=$(...)" під set -e вб'є скрипт МОВЧКИ
# ще до того, як спрацює наступний явний die() з людяним повідомленням.
ESP_UUID=$(grep 'nvme0n1p1:' "$META/blkid.txt" | grep -oP '(?<!PART)UUID="\K[^"]+' || true)
BOOT_UUID=$(grep 'nvme0n1p2:' "$META/blkid.txt" | grep -oP '(?<!PART)UUID="\K[^"]+' || true)
ROOT_UUID=$(grep 'ubuntu--vg-ubuntu--lv:' "$META/blkid.txt" | grep -oP '(?<!PART)UUID="\K[^"]+' || true)
[[ -n "$ESP_UUID" && -n "$BOOT_UUID" && -n "$ROOT_UUID" ]] || die "Не вдалося прочитати UUID з blkid.txt"
ESP_UUID_NODASH=$(echo "$ESP_UUID" | tr -d '-' | tr '[:lower:]' '[:upper:]')

FORMAT_CHECK='[[ "$(blkid -s TYPE -o value "$ESP" 2>/dev/null)" == "vfat" \
  && "$(blkid -s TYPE -o value "$BOOT" 2>/dev/null)" == "ext4" \
  && "$(blkid -s TYPE -o value "$ROOT_LV" 2>/dev/null)" == "ext4" ]]'
if step_done_verified format_filesystems "$FORMAT_CHECK"; then
  log "Крок format_filesystems вже виконано — пропускаю"
else
  CURRENT_STEP=format_filesystems
  log "Форматування розділів"
  mkfs.fat -F 32 -i "$ESP_UUID_NODASH" "$ESP"
  mkfs.ext4 -F -U "$BOOT_UUID" "$BOOT"
  mkfs.ext4 -F -U "$ROOT_UUID" "$ROOT_LV"
  mark_done format_filesystems
  CURRENT_STEP=""
fi

# ---------------------------------------------------------------------------
# 9. Mount + restic restore
# ---------------------------------------------------------------------------

MOUNT_CHECK='findmnt -M "$MNT_TARGET" >/dev/null && findmnt -M "$MNT_TARGET/boot" >/dev/null && findmnt -M "$MNT_TARGET/boot/efi" >/dev/null'
if step_done_verified mount_targets "$MOUNT_CHECK"; then
  log "Крок mount_targets вже виконано (усе змонтовано) — пропускаю"
else
  CURRENT_STEP=mount_targets
  log "Монтування цільових файлових систем"
  mkdir -p "$MNT_TARGET"
  findmnt -M "$MNT_TARGET" >/dev/null || mount "$ROOT_LV" "$MNT_TARGET"
  # /boot/efi має бути створений ПІСЛЯ монтування /boot: /boot — окрема
  # щойно відформатована (порожня) файлова система, і будь-який каталог,
  # створений під /mnt/target/boot до її монтування, після монтування
  # ховається під новим mount-точкою — mount ESP туди впаде з "mount
  # point does not exist".
  mkdir -p "$MNT_TARGET/boot"
  findmnt -M "$MNT_TARGET/boot" >/dev/null || mount "$BOOT" "$MNT_TARGET/boot"
  mkdir -p "$MNT_TARGET/boot/efi"
  findmnt -M "$MNT_TARGET/boot/efi" >/dev/null || mount "$ESP" "$MNT_TARGET/boot/efi"
  mark_done mount_targets
  CURRENT_STEP=""
fi

if step_done_verified restore_root '[[ -f "$MNT_TARGET/etc/fstab" ]]'; then
  log "Крок restore_root вже виконано — пропускаю"
else
  CURRENT_STEP=restore_root
  # restic записав шлях бекапу як /mnt/root-backup-snapshot (оригінальна
  # точка монтування LVM-снепшоту під час бекапу — restic завжди
  # відтворює повний абсолютний шлях під --target). Замість
  # відновлення у проміжну теку (275G — не влазить у обмежений overlay
  # Live-сесії, звідси й "no space left on device" у попередній спробі)
  # бінд-монтуємо ціль ТУДИ Ж і відновлюємо з --target / — restic пише
  # напряму на цільовий диск через цей бінд, в один прохід, без
  # подвійного запису і без проміжної теки взагалі.
  log "Відновлення system-root через restic (напряму на ціль через bind-mount /mnt/root-backup-snapshot)"
  require_free_space_gib "$RESTORE_SIZE_GIB" "$MNT_TARGET"
  mkdir -p /mnt/root-backup-snapshot
  findmnt -M /mnt/root-backup-snapshot >/dev/null 2>&1 || mount --bind "$MNT_TARGET" /mnt/root-backup-snapshot
  RESTORE_RC=0
  restic -r "$REPO" restore latest --tag system-root --target / --sparse --verify || RESTORE_RC=$?
  umount /mnt/root-backup-snapshot
  [[ $RESTORE_RC -eq 0 ]] || die "restic restore (system-root) завершився з помилкою (код $RESTORE_RC)"
  mark_done restore_root
  CURRENT_STEP=""
fi

if step_done_verified restore_boot '[[ -d "$MNT_TARGET/boot/grub" ]]'; then
  log "Крок restore_boot вже виконано — пропускаю"
else
  CURRENT_STEP=restore_boot
  log "Відновлення system-boot через restic"
  # /boot — кілька сотень MB, проміжна тека тут безпечна; кладемо її на
  # диск бекапу (SCRIPT_DIR), а не на overlay Live-сесії, і перевіряємо
  # місце наперед — так само, як і для кореня.
  require_free_space_gib 3 "$SCRIPT_DIR"
  mkdir -p "$MNT_RESTORE"
  restic -r "$REPO" restore latest --tag system-boot --target "$MNT_RESTORE" --sparse --verify
  rsync -aHAX --numeric-ids "$MNT_RESTORE/boot/" "$MNT_TARGET/boot/"
  rm -rf "${MNT_RESTORE:?}"/*
  mark_done restore_boot
  CURRENT_STEP=""
fi

# ---------------------------------------------------------------------------
# 10. fstab fixup
# ---------------------------------------------------------------------------

FSTAB_CHECK="grep -qF '/dev/mapper/${VG_NAME//-/--}-${LV_NAME//-/--} / ext4 ' '$MNT_TARGET/etc/fstab'"
if step_done_verified fstab_fixup "$FSTAB_CHECK"; then
  log "Крок fstab_fixup вже виконано — пропускаю"
else
  CURRENT_STEP=fstab_fixup
  log "Виправлення /etc/fstab (новий LVM UUID)"
  [[ -f "$MNT_TARGET/etc/fstab.pre-restore.bak" ]] || cp "$MNT_TARGET/etc/fstab" "$MNT_TARGET/etc/fstab.pre-restore.bak"
  sed -i \
    "s|^/dev/disk/by-id/dm-uuid-LVM-.* / ext4 |/dev/mapper/${VG_NAME//-/--}-${LV_NAME//-/--} / ext4 |" \
    "$MNT_TARGET/etc/fstab"
  mark_done fstab_fixup
  CURRENT_STEP=""
fi

echo "--- fstab ---"; cat "$MNT_TARGET/etc/fstab"
echo "--- crypttab ---"; cat "$MNT_TARGET/etc/crypttab" 2>/dev/null || true
echo "--- blkid цілі ---"; blkid "$ESP" "$BOOT" "$ROOT_LV"
echo "--- findmnt ---"; findmnt -R "$MNT_TARGET"

# ---------------------------------------------------------------------------
# 11. chroot: initramfs + GRUB
# ---------------------------------------------------------------------------

if step_done chroot_grub; then
  log "Крок chroot_grub вже виконано — пропускаю (щоб повторити примусово: --retry-step=chroot_grub)"
else
  CURRENT_STEP=chroot_grub
  log "chroot: update-initramfs + grub-install + update-grub"
  for i in /dev /dev/pts /proc /sys /run; do
    findmnt -M "$MNT_TARGET$i" >/dev/null 2>&1 || mount --bind "$i" "$MNT_TARGET$i"
  done
  # /sys/firmware/efi/efivars — ОКРЕМА змонтована файлова система
  # (efivarfs), яку звичайний "mount --bind /sys" не підхоплює (bind без
  # -r не тягне вкладені монтування). Без неї efibootmgr всередині
  # chroot падає з "EFI variables are not supported on this system".
  if [[ -d /sys/firmware/efi/efivars ]]; then
    findmnt -M "$MNT_TARGET/sys/firmware/efi/efivars" >/dev/null 2>&1 || \
      mount --bind /sys/firmware/efi/efivars "$MNT_TARGET/sys/firmware/efi/efivars"
  fi

  chroot "$MNT_TARGET" /bin/bash -eux <<'CHROOT_EOF'
update-initramfs -u -k all
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --recheck
update-grub
efibootmgr -v
CHROOT_EOF

  if ! chroot "$MNT_TARGET" efibootmgr -v | grep -qi ubuntu; then
    echo "efibootmgr не показав запис Ubuntu — встановлюю fallback removable loader"
    chroot "$MNT_TARGET" grub-install --target=x86_64-efi --efi-directory=/boot/efi \
      --boot-directory=/boot --removable --recheck
  fi

  sync
  mark_done chroot_grub
  CURRENT_STEP=""
fi

# ---------------------------------------------------------------------------
# 12. Unmount everything
# ---------------------------------------------------------------------------

log "Розмонтування та закриття LUKS"
# efivars — перед /sys (нащадок має розмонтуватись до батька).
for i in /run /sys/firmware/efi/efivars /sys /proc /dev/pts /dev; do
  umount "$MNT_TARGET$i" 2>/dev/null || true
done
umount -R "$MNT_TARGET"
vgchange -an "$VG_NAME" || true
cryptsetup close "$CRYPT_NAME" || true

log "Готово"
echo "Систему відновлено на $DISK. Вимкніть Live USB, завантажтеся з $DISK."
echo "Після першого завантаження перевірте: findmnt, lsblk -f, vgs, lvs."
