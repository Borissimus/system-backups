#!/usr/bin/env bash
# Restore config wizard, preflight, execution and journal are implemented in Python.
# Read docs/RECOVERY.md before restoring. No automatic disk selection or auto teardown.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/scripts/restore-system.py" "$@"
