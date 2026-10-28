#!/usr/bin/env python3
"""Confined worker client for per-attempt task intents and board snapshots."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import stat
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
from attempts_fold import unique_pairs  # noqa: E402
from task_ledger import TASK_RE, TOKEN_RE, safe_display_text  # noqa: E402

MAX_LINE = 8 * 1024
MAX_FILE = 64 * 1024
MAX_INTENTS = 10
REF_RE = re.compile(r"(?:msg|git|file):[!-~]{1,255}\Z", re.ASCII)
REPORT_KEYS = {"attempt_id", "verb", "task_id", "state", "summary", "result_ref", "reason"}
CONTINUE_KEYS = {"attempt_id", "verb", "task_id", "summary"}
DELEGATE_KEYS = {"attempt_id", "verb", "run_id", "to", "title", "body", "source_msg_id"}


def fail(code: int, message: str) -> int:
    print(f"task-intent: {message}", file=sys.stderr)
    return code


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(prog="task-intent")
    subs = root.add_subparsers(dest="command", required=True)
    report = subs.add_parser("report")
    report.add_argument("task_id")
    report.add_argument("state", choices=("progress", "done", "failed", "blocked"))
    report.add_argument("--result")
    report.add_argument("--reason")
    report.add_argument("summary")
    progress = subs.add_parser("progress")
    progress.add_argument("task_id")
    progress.add_argument("summary")
    cont = subs.add_parser("continue")
    cont.add_argument("task_id")
    cont.add_argument("summary", nargs="?", default="")
    subs.add_parser("list")
    return root


def _directory(home: Path) -> tuple[int, int, int]:
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    home_fd = aib_fd = intents_fd = -1
    try:
        home_fd = os.open(home, flags)
        aib_fd = os.open(".aib", flags, dir_fd=home_fd)
        intents_fd = os.open("intents", flags, dir_fd=aib_fd)
        for fd in (aib_fd, intents_fd):
            info = os.fstat(fd)
            if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o700:
                raise OSError("unsafe .aib directory ownership or mode")
        return home_fd, aib_fd, intents_fd
    except Exception:
        for fd in (intents_fd, aib_fd, home_fd):
            if fd >= 0:
                os.close(fd)
        raise


def _validate_summary(value: str) -> None:
    if len(value.encode("utf-8")) > 2048 or not safe_display_text(value):
        raise ValueError("summary must be safe single-line UTF-8 of at most 2048 bytes")


def _safe_text(value: Any, name: str, limit: int) -> str:
    if not isinstance(value, str):
        raise TypeError(f"{name} must be a string")
    if len(value.encode("utf-8")) > limit or not safe_display_text(value):
        raise ValueError(f"invalid {name}")
    return value


def validate_intent_records(
    records: list[dict[str, Any]], attempt: str, task_id: str | None = None
) -> list[dict[str, Any]]:
    """Validate a complete intent file before the supervisor applies any row."""
    if not records or len(records) > MAX_INTENTS:
        raise ValueError("invalid intent count")
    if TOKEN_RE.fullmatch(attempt) is None:
        raise ValueError("invalid attempt id")
    for record in records:
        if not isinstance(record, dict) or record.get("attempt_id") != attempt:
            raise ValueError("foreign attempt id")
        verb = record.get("verb")
        if verb == "delegate":
            if set(record) != DELEGATE_KEYS:
                raise ValueError("invalid delegate schema")
            for name in ("run_id", "to", "title", "body", "source_msg_id"):
                _safe_text(record.get(name), name, MAX_LINE)
            continue
        if verb == "continue":
            if set(record) != CONTINUE_KEYS:
                raise ValueError("invalid continue schema")
        elif verb == "report":
            if not CONTINUE_KEYS <= set(record) or set(record) - REPORT_KEYS:
                raise ValueError("invalid report schema")
            if record.get("state") not in {"progress", "done", "failed", "blocked"}:
                raise ValueError("invalid report state")
            result_ref = record.get("result_ref")
            if result_ref is not None and (not isinstance(result_ref, str) or REF_RE.fullmatch(result_ref) is None):
                raise ValueError("invalid result ref")
            reason = record.get("reason")
            if reason is not None:
                _safe_text(reason, "reason", 512)
        else:
            raise ValueError("invalid intent verb")
        record_task = record.get("task_id")
        if not isinstance(record_task, str) or TASK_RE.fullmatch(record_task) is None:
            raise ValueError("invalid task id")
        if task_id is not None and record_task != task_id:
            raise ValueError("task mismatch")
        _safe_text(record.get("summary"), "summary", 2048)
    return records


def append_intent(home: Path, attempt: str, record: dict[str, Any]) -> None:
    encoded = (json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")
    if len(encoded) > MAX_LINE:
        raise ValueError("intent line exceeds 8192 bytes")
    home_fd = aib_fd = intents_fd = file_fd = -1
    try:
        home_fd, aib_fd, intents_fd = _directory(home)
        file_fd = os.open(
            f"{attempt}.jsonl",
            os.O_RDWR | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC,
            0o600,
            dir_fd=intents_fd,
        )
        fcntl.flock(file_fd, fcntl.LOCK_EX)
        info = os.fstat(file_fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_nlink != 1:
            raise OSError("unsafe intent file")
        os.fchmod(file_fd, 0o600)
        if info.st_size + len(encoded) > MAX_FILE:
            raise ValueError("intent file exceeds 65536 bytes")
        os.lseek(file_fd, 0, os.SEEK_SET)
        existing = os.read(file_fd, MAX_FILE) if info.st_size else b""
        if existing.count(b"\n") >= MAX_INTENTS:
            raise ValueError("at most 10 intents are allowed per turn")
        os.lseek(file_fd, 0, os.SEEK_END)
        os.write(file_fd, encoded)
        os.fsync(file_fd)
    finally:
        for fd in (file_fd, intents_fd, aib_fd, home_fd):
            if fd >= 0:
                os.close(fd)


def show_board(home: Path) -> None:
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK
    home_fd = aib_fd = board_fd = -1
    try:
        home_fd = os.open(home, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
        aib_fd = os.open(".aib", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=home_fd)
        board_fd = os.open("board.json", flags, dir_fd=aib_fd)
        info = os.fstat(board_fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > MAX_FILE:
            raise OSError("unsafe board snapshot")
        data = os.read(board_fd, MAX_FILE + 1)
        value = json.loads(data.decode("utf-8"), object_pairs_hook=unique_pairs)
        if not isinstance(value, dict):
            raise ValueError("board snapshot is not an object")
        print(json.dumps(value, ensure_ascii=False, separators=(",", ":")))
    finally:
        for fd in (board_fd, aib_fd, home_fd):
            if fd >= 0:
                os.close(fd)


def main(argv: list[str]) -> int:
    try:
        args = parser().parse_args(argv)
        home_raw = os.environ.get("HOME", "")
        if not home_raw or not Path(home_raw).is_absolute():
            return fail(78, "HOME is unavailable")
        home = Path(home_raw)
        if args.command == "list":
            show_board(home)
            return 0
        attempt = os.environ.get("AIB_ATTEMPT_ID", "")
        if TOKEN_RE.fullmatch(attempt) is None:
            return fail(78, "AIB_ATTEMPT_ID is unavailable or invalid")
        if TASK_RE.fullmatch(args.task_id) is None:
            return fail(64, "invalid task id")
        _validate_summary(args.summary)
        if args.command == "progress":
            record = {"attempt_id": attempt, "verb": "report", "task_id": args.task_id, "state": "progress", "summary": args.summary}
        elif args.command == "continue":
            record = {"attempt_id": attempt, "verb": "continue", "task_id": args.task_id, "summary": args.summary}
        else:
            if args.result is not None and REF_RE.fullmatch(args.result) is None:
                return fail(64, "invalid result ref")
            if args.reason is not None and (len(args.reason) > 512 or not safe_display_text(args.reason)):
                return fail(64, "invalid reason")
            record = {"attempt_id": attempt, "verb": "report", "task_id": args.task_id, "state": args.state, "summary": args.summary}
            if args.result is not None:
                record["result_ref"] = args.result
            if args.reason is not None:
                record["reason"] = args.reason
        validate_intent_records([record], attempt, args.task_id)
        append_intent(home, attempt, record)
        print("intent queued for supervisor apply")
        return 0
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as error:
        return fail(78, str(error))


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
