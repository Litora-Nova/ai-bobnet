"""Shared control-plane identity and durable audit helpers."""

from __future__ import annotations

import fcntl
import grp
import json
import os
import pwd
import re
import shlex
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
ROLE_UIDS_RE = re.compile(r"[0-9]+(?:,[0-9]+)*\Z", re.ASCII)


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def configured_role_uids() -> set[int] | None:
    path = Path("/etc/aib/role.env")
    if os.environ.get("AIB_TEST_SEAMS") == "1" and not (ROOT / ".aib-installed").exists():
        path = Path(os.environ.get("AIB_ROLE_ENV_FILE", path))
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except FileNotFoundError:
        return set()
    except (OSError, UnicodeError):
        return None
    value = None
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        key, separator, raw = stripped.partition("=")
        if separator and key == "AIB_ROLE_UIDS":
            value = raw.strip()
    if value is None:
        return set()
    if ROLE_UIDS_RE.fullmatch(value) is None:
        return None
    role_uids = {int(item) for item in value.split(",")}
    return role_uids if all(uid >= 1000 for uid in role_uids) else None


def identity_for(numeric_uid: int) -> str:
    command = shlex.split(os.environ.get("AIB_IDENTITY_CMD", ""))
    if command:
        try:
            result = subprocess.run(
                [*command, str(numeric_uid)],
                check=False,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                timeout=5,
            )
            value = result.stdout.splitlines()[0] if result.returncode == 0 and result.stdout else ""
            if re.fullmatch(r"(?:human|role|gateway):[a-z0-9][a-z0-9_-]*|unknown:[0-9]+", value):
                return value
        except (OSError, subprocess.TimeoutExpired):
            pass
    else:
        try:
            account = pwd.getpwuid(numeric_uid)
            role_uids = configured_role_uids()
            if role_uids is None:
                return f"unknown:{numeric_uid}"
            if numeric_uid in role_uids:
                return f"role:{account.pw_name}"
            if account.pw_name in ("aib-gw", "aib-gateway"):
                return f"gateway:{account.pw_name}"
            groups = {grp.getgrgid(account.pw_gid).gr_name}
            groups.update(entry.gr_name for entry in grp.getgrall() if account.pw_name in entry.gr_mem)
            if groups.intersection(("aib-shared", "aib-ops")):
                return f"human:{account.pw_name}"
        except (KeyError, OSError):
            pass
    return f"unknown:{numeric_uid}"


def append_record(path: Path, event: str, **fields: Any) -> dict[str, Any]:
    lock_path = Path(f"{path}.lock")
    with lock_path.open("a", encoding="utf-8") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        sequence = 0
        try:
            with path.open(encoding="utf-8") as stream:
                for line in stream:
                    if line.strip():
                        record = json.loads(line)
                        sequence = max(sequence, int(record["seq"]))
        except FileNotFoundError:
            pass
        record = {"seq": sequence + 1, "ts": utc_now(), "event": event, **fields}
        with path.open("a", encoding="utf-8") as stream:
            stream.write(json.dumps(record, separators=(",", ":")) + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        return record


def requested_record(path: Path, sequence: int) -> dict[str, Any] | None:
    try:
        with path.open(encoding="utf-8") as stream:
            for line in stream:
                if not line.strip():
                    continue
                record = json.loads(line)
                if record.get("event") == "ctl.requested" and record.get("seq") == sequence:
                    return record
    except (OSError, json.JSONDecodeError, TypeError, ValueError):
        return None
    return None


def terminal_record(path: Path, request_sequence: int) -> dict[str, Any] | None:
    terminal = None
    try:
        with path.open(encoding="utf-8") as stream:
            for line in stream:
                if not line.strip():
                    continue
                record = json.loads(line)
                if record.get("req") == request_sequence and record.get("event") in ("ctl.done", "ctl.rejected"):
                    terminal = record
    except (OSError, json.JSONDecodeError, TypeError, ValueError):
        return None
    return terminal
