#!/usr/bin/env python3
"""Relay broker chunks and translate its terminal frame into launcher status."""

from __future__ import annotations

import io
import os
import re
import stat
import sys
from pathlib import Path


SIGNALS = {"HUP": 129, "INT": 130, "KILL": 137, "TERM": 143}
ATTEMPT_RE = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*\Z", re.ASCII)


def persist_attempt(value: str) -> bool:
    path = os.environ.get("AIB_ATTEMPT_META_PATH")
    if path is None:
        return True
    if ATTEMPT_RE.fullmatch(value) is None:
        return False
    fd = -1
    try:
        fd = os.open(path, os.O_WRONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o600:
            return False
        os.ftruncate(fd, 0)
        encoded = (value + "\n").encode()
        view = memoryview(encoded)
        while view:
            view = view[os.write(fd, view):]
        os.fsync(fd)
        return True
    except OSError:
        return False
    finally:
        if fd >= 0:
            os.close(fd)


def parse(path: Path) -> int:
    data = path.read_bytes()
    if not data:
        return 69
    stream = io.BytesIO(data)
    fields: dict[str, str] = {}
    saw_terminal = False
    while True:
        raw = stream.readline()
        if not raw:
            break
        if raw.startswith(b"chunk_bytes="):
            try:
                size = int(raw.removeprefix(b"chunk_bytes=").strip())
            except ValueError:
                return 69
            if stream.readline() != b"\n":
                return 69
            payload = stream.read(size)
            if len(payload) != size:
                return 69
            if size:
                sys.stdout.buffer.write(payload)
            continue
        try:
            line = raw.decode("utf-8").rstrip("\n")
        except UnicodeDecodeError:
            return 69
        key, separator, value = line.partition("=")
        if separator:
            fields[key] = value
            if key == "end":
                saw_terminal = True
    if not saw_terminal:
        return 69
    if fields.get("reason") == "over_capacity":
        return 75
    if fields.get("end") != "ok":
        return 69
    if not persist_attempt(fields.get("attempt_id", "")):
        return 69
    if fields.get("exit_class") == "ok":
        return 0
    code = fields.get("exit_code")
    if code and code.isdigit():
        return min(int(code), 255)
    named_signal = fields.get("signal", "")
    if named_signal in SIGNALS:
        return SIGNALS[named_signal]
    if named_signal.startswith("SIGNAL-") and named_signal[7:].isdigit():
        return min(128 + int(named_signal[7:]), 255)
    return 69


def main() -> int:
    if len(sys.argv) != 2:
        return 69
    try:
        return parse(Path(sys.argv[1]))
    except OSError:
        return 69


if __name__ == "__main__":
    raise SystemExit(main())
