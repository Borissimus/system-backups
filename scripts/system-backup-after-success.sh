#!/usr/bin/env bash
# Hook for a future OpenWrt/RTC/Wake-on-LAN integration.
# It is called only after a complete successful backup and retention pass.
set -euo pipefail

echo "system-backup callback: backup succeeded; Wake-on-LAN/RTC is not configured yet."
