#!/usr/bin/env python3
"""Validate the non-secret backup profile and export safe scalar values.

The backup shell script intentionally delegates JSON parsing here instead of
sourcing a configuration file as shell code. Python 3 is already required by
the backup workflow, so this adds no package dependency.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

DEFAULT = {
    "schema_version": 1,
    "root": {"snapshot_mode": "auto"},
    "encryption": {"mode": "auto"},
    "boot": {"mode": "auto"},
    "home": {"mode": "auto", "path": "/home", "snapshot_mode": "live"},
}

ALLOWED_TOP = {"schema_version", "root", "encryption", "boot", "home"}
ALLOWED = {
    "root": {"snapshot_mode"},
    "encryption": {"mode"},
    "boot": {"mode"},
    "home": {"mode", "path", "snapshot_mode"},
}


class ConfigError(ValueError):
    pass


def merge(default: dict, override: dict) -> dict:
    result = {k: (v.copy() if isinstance(v, dict) else v) for k, v in default.items()}
    for key, value in override.items():
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key].update(value)
        else:
            result[key] = value
    return result


def load(path: str | None) -> tuple[dict, str]:
    if path is None:
        return DEFAULT, "built-in defaults (no config file)"
    file = Path(path)
    if not file.is_file():
        raise ConfigError(f"config file not found: {file}")
    try:
        raw = json.loads("\n".join(
            "" if line.lstrip().startswith("//") else line
            for line in file.read_text(encoding="utf-8").splitlines()
        ))
    except json.JSONDecodeError as exc:
        raise ConfigError(f"invalid JSON in {file}: {exc}") from exc
    if not isinstance(raw, dict):
        raise ConfigError("top-level JSON value must be an object")
    unknown = set(raw) - ALLOWED_TOP
    if unknown:
        raise ConfigError(f"unknown top-level keys: {', '.join(sorted(unknown))}")
    for section, allowed in ALLOWED.items():
        if section in raw:
            if not isinstance(raw[section], dict):
                raise ConfigError(f"{section} must be an object")
            unknown = set(raw[section]) - allowed
            if unknown:
                raise ConfigError(f"unknown {section} keys: {', '.join(sorted(unknown))}")
    config = merge(DEFAULT, raw)
    validate(config)
    return config, str(file)


def validate(config: dict) -> None:
    if type(config.get("schema_version")) is not int or config.get("schema_version") != 1:
        raise ConfigError("only schema_version 1 is supported")
    if not isinstance(config["root"]["snapshot_mode"], str) or config["root"]["snapshot_mode"] not in {"auto", "lvm", "live"}:
        raise ConfigError("root.snapshot_mode must be auto, lvm, or live")
    if not isinstance(config["encryption"]["mode"], str) or config["encryption"]["mode"] not in {"auto", "required", "none"}:
        raise ConfigError("encryption.mode must be auto, required, or none")
    if not isinstance(config["boot"]["mode"], str) or config["boot"]["mode"] not in {"auto", "required", "none"}:
        raise ConfigError("boot.mode must be auto, required, or none")
    if not isinstance(config["home"]["mode"], str) or config["home"]["mode"] not in {"auto", "restic", "external", "exclude"}:
        raise ConfigError("home.mode must be auto, restic, external, or exclude")
    home_path = config["home"]["path"]
    if not isinstance(home_path, str) or not home_path.startswith("/") or any(ord(c) < 32 or ord(c) == 127 for c in home_path) or ".." in Path(home_path).parts or home_path == "/" or home_path.endswith("/"):
        raise ConfigError("home.path must be an absolute path")
    if config["home"]["snapshot_mode"] != "live":
        raise ConfigError("home.snapshot_mode currently supports only live")


def export(config: dict) -> None:
    values = {
        "ROOT_SNAPSHOT_MODE": config["root"]["snapshot_mode"],
        "ENCRYPTION_MODE": config["encryption"]["mode"],
        "BOOT_MODE": config["boot"]["mode"],
        "HOME_MODE": config["home"]["mode"],
        "HOME_PATH": config["home"]["path"],
        "HOME_SNAPSHOT_MODE": config["home"]["snapshot_mode"],
    }
    for key, value in values.items():
        if "\t" in value or "\n" in value:
            raise ConfigError(f"{key} contains a control character")
        print(f"{key}\t{value}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("validate", "export"))
    parser.add_argument("--config", metavar="FILE")
    args = parser.parse_args()
    try:
        config, source = load(args.config)
        if args.command == "validate":
            print(f"OK: backup profile: {source}")
        else:
            export(config)
    except ConfigError as exc:
        print(f"backup config error: {exc}", file=sys.stderr)
        raise SystemExit(2)


if __name__ == "__main__":
    main()
