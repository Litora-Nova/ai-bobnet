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


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


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
            groups = {grp.getgrgid(account.pw_gid).gr_name}
            groups.update(entry.gr_name for entry in grp.getgrall() if account.pw_name in entry.gr_mem)
            if account.pw_name in ("aib-gw", "aib-gateway") or "aib-gateway" in groups:
                return f"gateway:{account.pw_name}"
            if account.pw_name.startswith("aib-"):
                return f"role:{account.pw_name}"
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
