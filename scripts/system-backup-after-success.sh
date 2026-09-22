#!/usr/bin/env bash
# Hook for a future OpenWrt/RTC/Wake-on-LAN integration.
# It is called only after a complete successful backup and retention pass.
set -euo pipefail

echo "system-backup callback: backup успішний; Wake-on-LAN/RTC ще не налаштовано."
