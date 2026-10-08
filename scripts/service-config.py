#!/usr/bin/env python3
"""Validate the non-secret configuration used by the systemd wrapper.

The JSON file is data, never shell code.  The installer and wrapper consume
the same validated values, so a copied backup project can be configured for a
new machine without editing scripts or unit files.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


ALLOWED = {
    "schema_version",
    "backup_dir",
    "code_dir",
    "backup_mount",
    "backup_disk_uuid",
    "backup_profile",
    "schedule",
    "retention",
    "min_repository_free_gib",
    "restic_password_file",
    "success_callback",
    "notice_user",
}
RETENTION_ALLOWED = {"daily", "weekly", "monthly"}
SCHEDULE = re.compile(r"^(?:[01][0-9]|2[0-3]):[0-5][0-9]$")


class ConfigError(ValueError):
    pass


def path(value: object, name: str, *, allow_empty: bool = False) -> str:
    if allow_empty and value == "":
        return ""
    if not isinstance(value, str) or not value.startswith("/") or any(ord(c) < 32 or ord(c) == 127 for c in value) or ".." in Path(value).parts:
        raise ConfigError(f"{name} must be an absolute path")
    if value != (value.rstrip("/") or "/"):
        raise ConfigError(f"{name} must not have a trailing slash")
    return value


def load(filename: str) -> dict:
    file = Path(filename)
    if not file.is_file():
        raise ConfigError(f"service config file not found: {file}")
    try:
        config = json.loads("\n".join(
            "" if line.lstrip().startswith("//") else line
            for line in file.read_text(encoding="utf-8").splitlines()
        ))
    except json.JSONDecodeError as exc:
        raise ConfigError(f"invalid JSON in {file}: {exc}") from exc
    if not isinstance(config, dict):
        raise ConfigError("top-level JSON value must be an object")
    unknown = set(config) - ALLOWED
    if unknown:
        raise ConfigError(f"unknown keys: {', '.join(sorted(unknown))}")
    validate(config)
    return config


def validate(config: dict) -> None:
    required = ALLOWED - {"backup_profile", "code_dir"}
    missing = required - set(config)
    if missing:
        raise ConfigError(f"missing keys: {', '.join(sorted(missing))}")
    if type(config["schema_version"]) is not int or config["schema_version"] != 1:
        raise ConfigError("only schema_version 1 is supported")
    backup_dir = path(config["backup_dir"], "backup_dir")
    backup_mount = path(config["backup_mount"], "backup_mount")
    if backup_dir != backup_mount and not backup_dir.startswith(backup_mount.rstrip("/") + "/"):
        raise ConfigError("backup_dir must be inside backup_mount")
    uuid = config["backup_disk_uuid"]
    if not isinstance(uuid, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]*", uuid):
        raise ConfigError("backup_disk_uuid must be a non-empty single-line UUID")
    path(config.get("code_dir", backup_dir), "code_dir")
    profile = config.get("backup_profile", "")
    path(profile, "backup_profile", allow_empty=True)
    if not isinstance(config["schedule"], str) or not SCHEDULE.fullmatch(config["schedule"]):
        raise ConfigError("schedule must be HH:MM in 24-hour local time")
    retention = config["retention"]
    if not isinstance(retention, dict) or set(retention) != RETENTION_ALLOWED:
        raise ConfigError("retention must contain exactly daily, weekly, monthly")
    for key, value in retention.items():
        if not isinstance(value, int) or isinstance(value, bool) or value < 0:
            raise ConfigError(f"retention.{key} must be a non-negative integer")
    if not any(retention.values()):
        raise ConfigError("at least one retention count must be positive")
    free = config["min_repository_free_gib"]
    if not isinstance(free, int) or isinstance(free, bool) or free < 0:
        raise ConfigError("min_repository_free_gib must be a non-negative integer")
    path(config["restic_password_file"], "restic_password_file")
    path(config["success_callback"], "success_callback")
    if not isinstance(config["notice_user"], str) or any(c in config["notice_user"] for c in "\t\n\x00"):
        raise ConfigError("notice_user must be a single-line string")


def export(config: dict, *, include_json: bool = False) -> None:
    values = {
        "CODE_DIR": config.get("code_dir", config["backup_dir"]),
        "BACKUP_DIR": config["backup_dir"],
        "BACKUP_MOUNT": config["backup_mount"],
        "BACKUP_DISK_UUID": config["backup_disk_uuid"],
        "BACKUP_PROFILE": config.get("backup_profile", ""),
        "SCHEDULE": config["schedule"],
        "KEEP_DAILY": str(config["retention"]["daily"]),
        "KEEP_WEEKLY": str(config["retention"]["weekly"]),
        "KEEP_MONTHLY": str(config["retention"]["monthly"]),
        "MIN_REPOSITORY_FREE_GIB": str(config["min_repository_free_gib"]),
        "RESTIC_PASSWORD_FILE": config["restic_password_file"],
        "SUCCESS_CALLBACK": config["success_callback"],
        "NOTICE_USER": config["notice_user"],
    }
    if include_json:
        values["SERVICE_CONFIG_JSON"] = json.dumps(config, ensure_ascii=True, separators=(",", ":"))
    for key, value in values.items():
        if "\t" in value or "\n" in value:
            raise ConfigError(f"{key} contains a control character")
        print(f"{key}\t{value}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("validate", "export"))
    parser.add_argument("--config", required=True, metavar="FILE")
    parser.add_argument("--include-json", action="store_true", help="include the validated config in export")
    args = parser.parse_args()
    try:
        config = load(args.config)
        if args.command == "validate":
            print(f"OK: service configuration: {args.config}")
        else:
            export(config, include_json=args.include_json)
    except ConfigError as exc:
        print(f"service config error: {exc}", file=sys.stderr)
        raise SystemExit(2)


if __name__ == "__main__":
    main()
