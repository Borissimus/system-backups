#!/usr/bin/env bash
# Sourced by ~/.bashrc. Message text is generated dynamically by the failure
# handler, therefore this file contains no failure-specific hardcoding.
NOTICE=/var/lib/system-backup/failure-notice
[[ -r "$NOTICE" ]] && cat "$NOTICE"
