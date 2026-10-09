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
#   sudo bash backup-system.sh --config configs/user/backup-config.json
#   sudo bash backup-system.sh --print-plan               # no repository write
#   sudo bash backup-system.sh --prune                    # apply retention
#   Add --backup-dir /mnt/backup/system-backups for storage separate from code.
#
# Concurrency: a flock-based lock (.backup.lock) makes a second, overlapping
# invocation (e.g. cron + a manual run) exit immediately instead of racing
# for the same LVM snapshot name / restic repo lock.
#
# History: every real run (success, failure, or skipped-due-to-lock) appends
# one line to backup-history.log — see docs/BACKUP.md for the
# exact format. Meant to be machine-parsed by a future monitoring/systemd
# layer, not just human-read.
#
set -euo pipefail

# flock uses an extra file descriptor, which LVM normally warns about when
# inherited. This is expected here: the lock remains held, while the
# documented LVM variable suppresses the diagnostic noise.
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
die() { echo "ERROR: $*" >&2; exit 1; }

START_TS=$(date +%s)
CURRENT_STEP="init"
RUN_TAG=""

# Append one history line per event: common ts/tag/status/duration fields
# plus key=value details such as added bytes and snapshot IDs.
# Plain text allows monitoring without dependencies using grep or awk.
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

# Extract added bytes, new/changed file counts, and snapshot ID from the
# final summary line of restic backup --json. If the JSON schema changes,
# return zeros rather than failing an already successful backup.
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
  [[ -x "$CONFIG_HELPER" ]] || die "Missing JSON config helper: $CONFIG_HELPER"
  local key value config_values
  local -a config_args=()
  [[ -n "$BACKUP_CONFIG" ]] && config_args=(--config "$BACKUP_CONFIG")
  config_values=$(python3 "$CONFIG_HELPER" export --include-json "${config_args[@]}") || die "Failed to load backup profile"
  while IFS=$'\t' read -r key value; do
    case "$key" in
      BACKUP_PROFILE_JSON|ROOT_SNAPSHOT_MODE|ENCRYPTION_MODE|BOOT_MODE|HOME_MODE|HOME_PATH|HOME_SNAPSHOT_MODE)
        printf -v "$key" '%s' "$value"
        ;;
      *) die "Unknown key from JSON config helper: $key" ;;
    esac
  done <<< "$config_values"
  [[ -n "$ROOT_SNAPSHOT_MODE" && -n "$HOME_MODE" ]] || die "Failed to load backup profile"
}

SNAP_CREATED=0
TMP_JSON_FILES=()
cleanup() {
  local ec=$?
  set +e
  if [[ $SNAP_CREATED -eq 1 ]]; then
    echo "Cleanup: unmounting and removing temporary LVM snapshot"
    umount "$SNAP_MOUNT" 2>/dev/null
    [[ -n "$VG_NAME" && -n "$SNAP_LV_NAME" ]] && lvremove -f "/dev/$VG_NAME/$SNAP_LV_NAME" 2>/dev/null
  fi
  [[ ${#TMP_JSON_FILES[@]} -gt 0 ]] && rm -f "${TMP_JSON_FILES[@]}"
  unset RESTIC_PASSWORD
  if [[ $ec -ne 0 ]]; then
    echo "Script failed (exit code $ec) at step: $CURRENT_STEP" >&2
    [[ $PRINT_PLAN -eq 1 || $DRY_RUN -eq 1 ]] || history_log failed "exit_code=$ec"
  fi
  exit $ec
}
trap cleanup EXIT

# Prevent overlapping runs, such as cron and manual invocation, from
# creating conflicting LVM snapshots and repository locks. Do not wait:
# skip this run and let the next scheduled trigger try again.
if [[ $PRINT_PLAN -eq 0 && $DRY_RUN -eq 0 ]]; then
  exec 200>"$LOCK_FILE"
  if ! flock -n 200; then
    echo "Another backup-system.sh run is active; skipping this run." >&2
    history_log skipped "reason=already_running"
    exit 0
  fi
fi

# A unique name avoids the older manual snapshot name and lets us reject
# stale snapshots after a power failure without deleting unrelated LVs.
RUN_TAG="run-$(date +%Y%m%d-%H%M%S)"
SNAP_LV_NAME="root-backup-snapshot-${RUN_TAG#run-}"
# The LV name must be unique, but the mount path stays stable so restic
# finds a parent snapshot by path/hostname without rereading unchanged files.
# An older LV named root-backup-snapshot is left untouched.
SNAP_MOUNT="/mnt/root-backup-snapshot"

CURRENT_STEP="verify_repo"
if [[ $PRINT_PLAN -eq 0 ]]; then
  [[ -d "$REPO" && -f "$REPO/config" ]] || die "Restic repository not found: $REPO"
fi
load_profile
echo "Backup profile: ${BACKUP_CONFIG:-built-in defaults}"

# ---------------------------------------------------------------------------
# 1. Detect the storage layout selected by the profile
# ---------------------------------------------------------------------------

CURRENT_STEP="detect_layout"
log "Detecting current storage layout"
ROOT_SRC=$(findmnt -no SOURCE /) || die "Failed to detect root device"
ROOT_SRC_RESOLVED=$(readlink -f "$ROOT_SRC")
ROOT_SOURCE="$ROOT_SRC_RESOLVED"

if command -v lvs >/dev/null 2>&1; then
  HAVE_LVM_TOOLS=1
  if read -r VG_NAME LV_NAME < <(lvs --noheadings -o vg_name,lv_name "$ROOT_SRC" 2>/dev/null | awk '{print $1,$2}'); then
    [[ -n "$VG_NAME" && -n "$LV_NAME" ]] && ROOT_IS_LVM=1
  fi
fi

if [[ "$ROOT_SNAPSHOT_MODE" == lvm && $ROOT_IS_LVM -ne 1 ]]; then
  die "root.snapshot_mode=lvm, but / is not an LVM logical volume"
fi

if (( ROOT_IS_LVM )); then
  PV_NAME=$(pvs --noheadings -o pv_name --select "vg_name=$VG_NAME" | head -1 | tr -d ' ')
  PV_COUNT=$(pvs --noheadings -o pv_name --select "vg_name=$VG_NAME" | awk 'NF {n++} END {print n+0}')
  [[ "$PV_COUNT" -eq 1 ]] || die "VG $VG_NAME has multiple PVs; this storage layout is not supported"
  [[ -n "$PV_NAME" ]] || die "Failed to detect PV for VG $VG_NAME"
  BACKING_SOURCE="$PV_NAME"
else
  BACKING_SOURCE="$ROOT_SRC"
fi

# A LUKS mapping is optional. Plain LVM and a direct root partition are both
# supported; the profile can require or forbid encryption explicitly.
CRYPT_CANDIDATE=$(basename "$BACKING_SOURCE")
if command -v cryptsetup >/dev/null 2>&1 && cryptsetup status "$CRYPT_CANDIDATE" >/dev/null 2>&1; then
  LUKS_PART=$(cryptsetup status "$CRYPT_CANDIDATE" | awk '/device:/{print $2}')
  [[ -n "$LUKS_PART" ]] || die "cryptsetup did not return a backing device for $CRYPT_CANDIDATE"
  CRYPT_NAME="$CRYPT_CANDIDATE"
  LUKS_ENABLED=1
  DISK_SOURCE="$LUKS_PART"
else
  DISK_SOURCE="$BACKING_SOURCE"
fi
if [[ "$ENCRYPTION_MODE" == required && $LUKS_ENABLED -ne 1 ]]; then
  die "encryption.mode=required, but no LUKS was found beneath root"
fi
if [[ "$ENCRYPTION_MODE" == none && $LUKS_ENABLED -eq 1 ]]; then
  die "encryption.mode=none, but root is encrypted with LUKS"
fi

DISK=$(lsblk -no PKNAME -d "$DISK_SOURCE" 2>/dev/null | head -1)
if [[ -z "$DISK" ]]; then
  # Root may be mounted directly from a whole-disk filesystem.
  [[ "$(lsblk -no TYPE "$DISK_SOURCE" 2>/dev/null)" == disk ]] && DISK=$(basename "$DISK_SOURCE")
fi
[[ -n "$DISK" ]] || die "Failed to detect physical disk beneath $DISK_SOURCE"

BOOT_SRC=$(findmnt -no SOURCE --target /boot) || die "Failed to detect /boot device"
ESP_SRC=""
if findmnt -M /boot/efi >/dev/null 2>&1; then
  ESP_SRC=$(findmnt -no SOURCE /boot/efi)
  HAS_ESP=1
fi
if [[ "$BOOT_MODE" == required && $HAS_ESP -ne 1 ]]; then
  die "boot.mode=required, but /boot/efi is not mounted"
fi

HOME_MOUNT=$(findmnt -no TARGET --target "$HOME_PATH" 2>/dev/null || true)
HOME_SOURCE=$(findmnt -no SOURCE --target "$HOME_PATH" 2>/dev/null || true)
[[ "$HOME_MOUNT" == "$HOME_PATH" ]] && HOME_SEPARATE=1
case "$HOME_MODE" in
  restic|external|exclude)
    (( HOME_SEPARATE )) || die "home.mode=$HOME_MODE requires a separate $HOME_PATH mount; otherwise /home is already in the root backup"
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
(( LUKS_ENABLED )) && echo "LUKS:       $LUKS_PART -> $CRYPT_NAME" || echo "LUKS:       none"
echo "Disk:       /dev/$DISK"
echo "/boot:      $BOOT_SRC"
(( HAS_ESP )) && echo "/boot/efi:  $ESP_SRC" || echo "/boot/efi:  no separate ESP mount"
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
  log "Calculating LVM snapshot size"
  VG_FREE_G=$(LC_ALL=C vgs --noheadings --units g -o vg_free "$VG_NAME" | tr -d ' g<>')
  LV_SIZE_G=$(LC_ALL=C lvs --noheadings --units g -o lv_size "$VG_NAME/$LV_NAME" | tr -d ' g<>')
  SNAP_SIZE_G=$(python3 -c "
free=$VG_FREE_G; lv=$LV_SIZE_G
want=max(5.0, lv*0.2)
print(int(min(free-1, want)))
")
  [[ $SNAP_SIZE_G -ge 5 ]] || die "Insufficient free VG space for snapshot (${VG_FREE_G}G free; at least 5G required)"
  echo "VG free: ${VG_FREE_G}G, LV: ${LV_SIZE_G}G -> snapshot: ${SNAP_SIZE_G}G"

  STALE_SNAPSHOTS=$(lvs --noheadings -o lv_name "$VG_NAME" 2>/dev/null \
    | awk '/^ *root-backup-snapshot-[0-9]{8}-[0-9]{6} *$/ {print $1}')
  [[ -z "$STALE_SNAPSHOTS" ]] || die \
    "Found snapshot from an interrupted run: $STALE_SNAPSHOTS. Inspect it manually before another backup."
else
  echo "Root backup: live filesystem mode (no LVM snapshot)"
fi

if [[ $PRINT_PLAN -eq 1 ]]; then
  log "Backup plan (no changes made)"
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
# Skip the interactive prompt when a password source is provided through
# RESTIC_PASSWORD, RESTIC_PASSWORD_FILE, or RESTIC_PASSWORD_COMMAND.
# Restic supports all three natively, allowing unattended systemd runs.
if [[ -n "${RESTIC_PASSWORD:-}" || -n "${RESTIC_PASSWORD_FILE:-}" || -n "${RESTIC_PASSWORD_COMMAND:-}" ]]; then
  log "Restic password source provided by environment; no interactive prompt"
else
  log "Restic repository password"
  read -rs -p "Restic password: " RESTIC_PASSWORD
  echo
  export RESTIC_PASSWORD
fi
restic -r "$REPO" snapshots --latest 1 >/dev/null || die "Invalid password or damaged repository"
echo "OK: repository is accessible"

if [[ $DRY_RUN -eq 1 ]]; then
  log "--dry-run: checks complete; no changes made and no backup created"
  exit 0
fi

# ---------------------------------------------------------------------------
# 4. Refresh recovery-metadata
# ---------------------------------------------------------------------------

CURRENT_STEP="refresh_metadata"
log "Refreshing recovery metadata"
mkdir -p "$META"
command -v sgdisk >/dev/null 2>&1 || die "sgdisk is required for recovery metadata"
command -v sfdisk >/dev/null 2>&1 || die "sfdisk is required for recovery metadata"
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
  command -v vgcfgbackup >/dev/null 2>&1 || die "vgcfgbackup is required for LVM root"
  vgcfgbackup -f "$META/lvm-vg.conf" "$VG_NAME"
  chmod 600 "$META/lvm-vg.conf"
else
  rm -f "$META/lvm-vg.conf"
fi
if (( LUKS_ENABLED )); then
  command -v cryptsetup >/dev/null 2>&1 || die "cryptsetup is required for LUKS root"
  cryptsetup luksHeaderBackup "$LUKS_PART" --header-backup-file "$META/luks-header.img.new"
  mv "$META/luks-header.img.new" "$META/luks-header.img"
  chmod 600 "$META/luks-header.img"
else
  rm -f "$META/luks-header.img"
fi
# Remove obsolete machine-specific aliases from metadata left by older runs.
# Current recovery uses layout.json and the generic filenames above.
rm -f "$META/nvme0n1.gpt" "$META/nvme0n1.sfdisk" \
  "$META/ubuntu-vg.conf" "$META/nvme0n1p3-luks-header.img"
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
echo "OK: recovery metadata refreshed"

# ---------------------------------------------------------------------------
# 5. LVM snapshot + mount
# ---------------------------------------------------------------------------

if (( USE_LVM_SNAPSHOT )); then
  CURRENT_STEP="create_snapshot"
  log "Creating root LVM snapshot (consistent point in time)"
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
log "restic backup: system-root ($ROOT_BACKUP_PATH) --json output has no live progress; this may look paused"
ROOT_JSON=$(mktemp); TMP_JSON_FILES+=("$ROOT_JSON")
if (( USE_LVM_SNAPSHOT )); then
  restic -r "$REPO" backup "$ROOT_BACKUP_PATH" --exclude "$SNAP_MOUNT$BACKUP_DIR" --tag system-root --tag "$RUN_TAG" --json > "$ROOT_JSON"
else
  # Do not cross into separately mounted filesystems. A separate /home is
  # either backed up below (mode=restic) or deliberately left external.
  restic -r "$REPO" backup / --exclude "$BACKUP_DIR" --one-file-system --tag system-root --tag "$RUN_TAG" --json > "$ROOT_JSON"
fi
read -r ROOT_ADDED ROOT_FILES_NEW ROOT_FILES_CHANGED ROOT_SNAPID < <(summarize_backup "$ROOT_JSON")
echo "system-root: +$(human_bytes "$ROOT_ADDED") new data, new/changed files: $ROOT_FILES_NEW/$ROOT_FILES_CHANGED, snapshot $ROOT_SNAPID"

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
  echo "system-home: +$(human_bytes "$HOME_ADDED") new data, new/changed files: $HOME_FILES_NEW/$HOME_FILES_CHANGED, snapshot $HOME_SNAPID"
elif (( HOME_SEPARATE )); then
  echo "system-home: not created (mode=$HOME_MODE; $HOME_PATH is outside root backup)"
fi

BOOT_ADDED=0
BOOT_SNAPID="-"
if [[ "$BOOT_MODE" != none ]]; then
  CURRENT_STEP="backup_boot"
  if (( HAS_ESP )); then
    log "restic backup: system-boot (/boot and /boot/efi as separate filesystems)"
    BOOT_JSON=$(mktemp); TMP_JSON_FILES+=("$BOOT_JSON")
    restic -r "$REPO" backup /boot /boot/efi --one-file-system \
      --tag system-boot --tag "$RUN_TAG" --json > "$BOOT_JSON"
  else
    log "restic backup: system-boot (/boot; no separate ESP mounted)"
    BOOT_JSON=$(mktemp); TMP_JSON_FILES+=("$BOOT_JSON")
    restic -r "$REPO" backup /boot --one-file-system \
      --tag system-boot --tag "$RUN_TAG" --json > "$BOOT_JSON"
  fi
  read -r BOOT_ADDED BOOT_FILES_NEW BOOT_FILES_CHANGED BOOT_SNAPID < <(summarize_backup "$BOOT_JSON")
  echo "system-boot: +$(human_bytes "$BOOT_ADDED") new data, new/changed files: $BOOT_FILES_NEW/$BOOT_FILES_CHANGED, snapshot $BOOT_SNAPID"
else
  echo "system-boot: not created (boot.mode=none)"
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
echo "recovery-metadata: +$(human_bytes "$META_ADDED") new data, snapshot $META_SNAPID"

# ---------------------------------------------------------------------------
# 7. Cleanup snapshot (also handled by trap, done explicitly here for order)
# ---------------------------------------------------------------------------

if (( SNAP_CREATED )); then
  CURRENT_STEP="remove_snapshot"
  log "Removing temporary LVM snapshot"
  umount "$SNAP_MOUNT"
  lvremove -f "$VG_NAME/$SNAP_LV_NAME"
  SNAP_CREATED=0
fi

# ---------------------------------------------------------------------------
# 8. Optional retention + integrity check
# ---------------------------------------------------------------------------

if [[ $PRUNE -eq 1 ]]; then
  CURRENT_STEP="prune"
  log "Applying retention policy (daily=$KEEP_DAILY weekly=$KEEP_WEEKLY monthly=$KEEP_MONTHLY)"
  for tag in system-root system-boot recovery-metadata; do
    # Each backup type is already filtered by its stable tag. Group only
    # by host so a one-off path change does not create a separate group
    # whose sole oldest snapshot would otherwise be retained indefinitely.
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
log "Checking repository (quick check without reading all data)"
restic -r "$REPO" check

CURRENT_STEP="done"
log "Done"
restic -r "$REPO" snapshots --tag "$RUN_TAG"
echo "New backup completed with tag $RUN_TAG"

TOTAL_ADDED=$(( ROOT_ADDED + HOME_ADDED + BOOT_ADDED + META_ADDED ))
history_log success \
  "root_added=$ROOT_ADDED" "home_added=$HOME_ADDED" "boot_added=$BOOT_ADDED" "meta_added=$META_ADDED" "total_added=$TOTAL_ADDED" \
  "root_snapshot=$ROOT_SNAPID" "home_snapshot=$HOME_SNAPID" "boot_snapshot=$BOOT_SNAPID" "meta_snapshot=$META_SNAPID" \
  "home_mode=$HOME_MODE" \
  "pruned=$([[ $PRUNE -eq 1 ]] && echo yes || echo no)"
echo "Total added in this run: $(human_bytes "$TOTAL_ADDED")"
