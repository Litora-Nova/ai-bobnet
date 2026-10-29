"""Shared fail-closed validator for deployment.json policy."""

from __future__ import annotations

import json
import os
import re
import stat
import string
import sys
from pathlib import Path
from typing import Any

ALLOW_KEYS = ("customer_code", "comms_secrets")
ACCOUNT_FIELDS = ("label", "credential_mode", "credential_source")
PROVIDER_RE = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*\Z")


def test_seams_enabled(root: Path) -> bool:
    return os.environ.get("AIB_TEST_SEAMS") == "1" and not (root / ".aib-installed").exists()


def required_owner(root: Path) -> int | None:
    raw = os.environ.get("AIB_DEPLOYMENT_OWNER_UID", "0") if test_seams_enabled(root) else "0"
    if not raw.isdigit():
        return None
    return int(raw)


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate deployment key")
        result[key] = value
    return result


def load_deployment(path: Path, root: Path) -> dict[str, Any] | None:
    owner = required_owner(root)
    if owner is None:
        return None
    try:
        info = path.lstat()
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != owner
            or info.st_mode & 0o022
            or not info.st_mode & 0o444
        ):
            return None
        with path.open(encoding="utf-8") as stream:
            value = json.load(stream, object_pairs_hook=_unique_object)
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError):
        return None

    if not isinstance(value, dict):
        return None
    if not isinstance(value.get("deployment_id"), str) or not value["deployment_id"]:
        return None
    allow = value.get("allow")
    if not isinstance(allow, dict) or any(type(allow.get(key)) is not bool for key in ALLOW_KEYS):
        return None
    if "profile" in value and not isinstance(value["profile"], str):
        return None
    if "allowed_projects" in value:
        projects = value["allowed_projects"]
        if not isinstance(projects, list) or any(not isinstance(item, str) for item in projects):
            return None
    if "role_map" in value:
        role_map = value["role_map"]
        if not isinstance(role_map, dict) or any(
            not isinstance(key, str) or not isinstance(item, str) for key, item in role_map.items()
        ):
            return None
    if "commit_identity" in value:
        identity = value["commit_identity"]
        if not isinstance(identity, dict) or set(identity) != {"name_template", "email"}:
            return None
        name_template, email = identity.get("name_template"), identity.get("email")
        if (
            not isinstance(name_template, str)
            or not name_template
            or len(name_template) > 128
            or any(char in name_template for char in "\x00\r\n")
            or not isinstance(email, str)
            or not re.fullmatch(r"[^\s@]+@[^\s@]+", email, re.ASCII)
        ):
            return None
        try:
            fields = list(string.Formatter().parse(name_template))
            if any(
                field not in {None, "display_name", "team"} or conversion is not None or format_spec
                for _, field, format_spec, conversion in fields
            ):
                return None
            name_template.format(display_name="agent", team="team")
        except (KeyError, ValueError):
            return None
    if "accounts" in value:
        accounts = value["accounts"]
        if not isinstance(accounts, dict):
            return None
        for provider, account in accounts.items():
            if not isinstance(provider, str) or not PROVIDER_RE.fullmatch(provider):
                return None
            if not isinstance(account, dict) or any(key not in ACCOUNT_FIELDS for key in account):
                return None
            if "label" in account:
                label = account["label"]
                if not isinstance(label, str) or len(label) > 64 or not label.isprintable():
                    return None
            if account.get("credential_mode", "file") not in ("file", "fd", "shared", "proxy"):
                return None
            if account.get("credential_source", "login") not in ("login", "setup_token"):
                return None
    return value


def deployment_allows(path: Path, key: str, root: Path) -> bool:
    value = load_deployment(path, root)
    return value is not None and value["allow"][key] is True


def main(argv: list[str]) -> int:
    if len(argv) == 5 and argv[2] == "--account":
        root, path, provider, field = Path(argv[0]), Path(argv[1]), argv[3], argv[4]
        if field not in ACCOUNT_FIELDS:
            return 2
        value = load_deployment(path, root)
        account = value.get("accounts", {}).get(provider) if value is not None else None
        if not isinstance(account, dict) or field not in account:
            return 1
        print(account[field])
        return 0
    if len(argv) == 4 and argv[2] == "--account-present":
        root, path, provider = Path(argv[0]), Path(argv[1]), argv[3]
        value = load_deployment(path, root)
        return 0 if value is not None and provider in value.get("accounts", {}) else 1
    if len(argv) != 3 or argv[2] not in ("", *ALLOW_KEYS):
        return 2
    root, path, key = Path(argv[0]), Path(argv[1]), argv[2]
    value = load_deployment(path, root)
    if value is None:
        return 1
    if not key:
        return 0
    return 0 if value["allow"][key] is True else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
