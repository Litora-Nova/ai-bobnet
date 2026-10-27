#!/usr/bin/env python3
"""Authoritative D1a run/task ledger CLI (supervisor/agentctl side only)."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
if os.environ.get("AIB_TEST_SEAMS") != "1" or (ROOT / ".aib-installed").exists():
    for name in ("AIBOBNET_REGISTRY", "AIB_TASK_ROOT", "AIB_IDENTITY_CMD", "AIB_EVENT_HELD_LOCK_FD"):
        os.environ.pop(name, None)
sys.path.insert(0, str(ROOT / "lib"))
from aib_control import identity_for, registry_path  # noqa: E402
from task_ledger import (  # noqa: E402
    RUN_RE,
    TASK_RE,
    TOKEN_RE,
    LedgerError,
    decide,
    fold,
    list_view,
    load_json,
    task_id as derive_task_id,
    validate_registry_scope,
)

COMMAND_EVENT = {
    "run-create": "run.requested",
    "run-close": "run.closed",
    "create": "task.created",
    "start": "task.started",
    "assign": "task.reassigned",
    "report": "task.reported",
    "cancel": "task.cancelled",
    "reopen": "task.reopened",
    "overdue": "task.overdue",
}
REF_RE = re.compile(r"(?:msg:[a-z0-9]+(?:-[a-z0-9]+)*|git:[^\s]+|file:[^\s]+)\Z", re.ASCII)


def fail(code: int, message: str) -> int:
    print(f"ai-bobnet: {message}", file=sys.stderr)
    return code


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(prog="task")
    subs = root.add_subparsers(dest="command", required=True)
    for name in COMMAND_EVENT:
        sub = subs.add_parser(name)
        sub.add_argument("--project", required=True)
        sub.add_argument("--team", required=True)
        sub.add_argument("--actor-type", choices=("human", "agent", "service", "provider"), required=True)
        sub.add_argument("--actor-id", required=True)
        sub.add_argument("--causation-id", required=True)
        sub.add_argument("--run-id", required=True)
        if name not in {"run-create", "run-close", "create"}:
            sub.add_argument("--task-id", required=True)
        if name == "run-create":
            sub.add_argument("--ticket-ref")
        elif name == "run-close":
            sub.add_argument("--outcome", choices=("completed", "failed", "cancelled"), required=True)
            sub.add_argument("--summary-ref")
        elif name == "create":
            sub.add_argument("--intent-n", type=int, required=True)
            sub.add_argument("--source-msg-id", required=True)
            sub.add_argument("--assignee", required=True)
            sub.add_argument("--title", required=True)
            sub.add_argument("--body-ref", required=True)
            sub.add_argument("--body-file", required=True)
            sub.add_argument("--deadline-at")
            sub.add_argument("--depth", type=int, default=1)
            sub.add_argument("--gate", default="none")
            sub.add_argument("--context-ref", action="append", default=[])
        elif name in {"assign", "reopen"}:
            sub.add_argument("--assignee", required=True)
        elif name == "report":
            sub.add_argument("--state", choices=("progress", "done", "failed", "blocked"), required=True)
            sub.add_argument("--result-ref")
            sub.add_argument("--reason")
        elif name == "cancel":
            sub.add_argument("--reason")
    listing = subs.add_parser("list")
    listing.add_argument("--project", required=True)
    listing.add_argument("--team")
    listing.add_argument("--run")
    listing.add_argument("--all", action="store_true")
    show = subs.add_parser("show")
    show.add_argument("--project", required=True)
    show.add_argument("id")
    return root


def stream_paths(project: str) -> tuple[Path, Path, Path]:
    script = '. "$1/lib/aibobnet.sh"; aib_task_event_stream_paths "$2"; printf "%s\\n%s\\n%s\\n" "$AIB_TASK_EVENT_DIR" "$AIB_TASK_EVENT_FILE" "$AIB_TASK_EVENT_LOCK"'
    result = subprocess.run(["bash", "-c", script, "_", str(ROOT), project], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=os.environ, check=False)
    if result.returncode:
        raise LedgerError(result.stderr.strip() or "cannot derive task stream paths")
    lines = result.stdout.splitlines()
    if len(lines) != 3:
        raise LedgerError("incomplete task stream path response")
    return Path(lines[0]), Path(lines[1]), Path(lines[2])


def validate_common(args: argparse.Namespace) -> None:
    if TOKEN_RE.fullmatch(args.project) is None or re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)+", args.team) is None:
        raise LedgerError("invalid project/team id")
    if RUN_RE.fullmatch(args.run_id) is None:
        raise LedgerError("invalid run_id (expected r-<12 hex>)")
    if hasattr(args, "task_id") and TASK_RE.fullmatch(args.task_id) is None:
        raise LedgerError("invalid task_id (expected t-<12 hex>)")
    if TOKEN_RE.fullmatch(args.causation_id) is None:
        raise LedgerError("invalid causation_id token")
    if any(char in args.actor_id for char in "\x00\r\n") or not args.actor_id:
        raise LedgerError("invalid actor_id")
    patterns = {
        "human": r"(?:[a-z0-9][a-z0-9_-]*|gateway:[a-z0-9][a-z0-9_-]*)",
        "agent": r"[a-z0-9]+(?:-[a-z0-9]+)+",
        "service": r"supervisor:[a-z0-9]+(?:-[a-z0-9]+)+",
        "provider": r"[a-z0-9]+(?:-[a-z0-9]+)*",
    }
    if re.fullmatch(patterns[args.actor_type], args.actor_id) is None:
        raise LedgerError("invalid actor_id for actor_type")


def payload_for(args: argparse.Namespace, caller: str) -> tuple[dict[str, object], str | None, bytes | None]:
    ident = getattr(args, "task_id", None)
    body = None
    if args.command == "run-create":
        payload: dict[str, object] = {"ticket_ref": args.ticket_ref}
    elif args.command == "run-close":
        payload = {"outcome": args.outcome, "summary_ref": args.summary_ref}
    elif args.command == "create":
        if args.intent_n < 1 or args.intent_n > 10:
            raise LedgerError("intent_n must be in 1..10")
        ident = derive_task_id(args.causation_id, args.intent_n)
        if TOKEN_RE.fullmatch(args.source_msg_id) is None:
            raise LedgerError("invalid source_msg_id token")
        if len(args.title) > 120 or not args.title or any(char in args.title for char in "\x00\r\n"):
            raise LedgerError("title must be one line of 1..120 characters")
        if re.fullmatch(r"msg:[a-z0-9]+(?:-[a-z0-9]+)*", args.body_ref) is None:
            raise LedgerError("invalid body_ref")
        if len(args.context_ref) > 5 or any(REF_RE.fullmatch(ref) is None for ref in args.context_ref):
            raise LedgerError("invalid context_refs")
        try:
            body_path = Path(args.body_file)
            if body_path.stat().st_size > 8192:
                raise LedgerError("task body exceeds 8192-byte limit")
            body = body_path.read_bytes()
        except OSError as error:
            raise LedgerError(f"cannot read body file: {error}") from error
        deadline = args.deadline_at
        if deadline is not None:
            try:
                from datetime import datetime
                datetime.strptime(deadline, "%Y-%m-%dT%H:%M:%SZ")
            except ValueError as error:
                raise LedgerError("invalid deadline_at (expected UTC YYYY-MM-DDTHH:MM:SSZ)") from error
        owner = args.actor_id if args.actor_type == "agent" else f"human:{args.actor_id}"
        payload = {"parent": args.run_id, "depth": args.depth, "source_msg_id": args.source_msg_id, "owner": owner, "assignee": args.assignee, "title": args.title, "body_ref": args.body_ref, "deadline_at": deadline, "budget": {"max_turns": 8, "max_attempts": 3}, "gate": args.gate, "context_refs": args.context_ref}
    elif args.command in {"assign", "reopen"}:
        payload = {"assignee": args.assignee}
    elif args.command == "report":
        if args.result_ref is not None and REF_RE.fullmatch(args.result_ref) is None:
            raise LedgerError("invalid result_ref")
        if args.reason is not None and (len(args.reason) > 512 or any(char in args.reason for char in "\x00\r\n")):
            raise LedgerError("reason must be one line of at most 512 characters")
        payload = {"state": args.state, "result_ref": args.result_ref, "reason": args.reason}
    elif args.command == "cancel":
        if args.reason is not None and (len(args.reason) > 512 or any(char in args.reason for char in "\x00\r\n")):
            raise LedgerError("reason must be one line of at most 512 characters")
        payload = {"reason": args.reason}
    else:
        payload = {}
    payload["caller"] = caller
    return payload, ident, body


def acquire(lock_path: Path) -> int:
    try:
        fd = os.open(lock_path, os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError as error:
        raise LedgerError(f"cannot open pre-provisioned task lock: {error}") from error
    timeout = float(os.environ.get("AIBOBNET_EVENT_LOCK_TIMEOUT", "10"))
    deadline = time.monotonic() + timeout
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fd
        except BlockingIOError:
            if time.monotonic() >= deadline:
                os.close(fd)
                raise TimeoutError
            time.sleep(0.02)


def commit(events: Path, lock: Path, lock_fd: int, request: dict[str, object], kind: str, payload: dict[str, object]) -> tuple[str, str]:
    envelope = "\n".join(
        f"{key}={value}"
        for key, value in (
            ("project_uid", request["project_uid"]),
            ("actor_type", request["actor_type"]),
            ("actor_id", request["actor_id"]),
            ("agent_uid", request["actor_id"] if request["actor_type"] == "agent" else ""),
            ("team_uid", request["team_uid"]),
            ("run_id", request["run_id"]),
            ("task_id", request.get("task_id") or ""),
            ("causation_id", request["causation_id"]),
        )
        if value != ""
    )
    script = '. "$1/lib/aibobnet.sh"; aib_event_commit "$2" "$3" tasks "$4" "$5" "$6"; printf "%s\\t%s\\n" "$AIB_EVENT_COMMIT_EVENT_ID" "$AIB_EVENT_COMMIT_SEQ"'
    env = dict(os.environ)
    env["AIB_EVENT_HELD_LOCK_FD"] = str(lock_fd)
    result = subprocess.run(["bash", "-c", script, "_", str(ROOT), str(events), str(lock), kind, envelope, json.dumps(payload, separators=(",", ":"), ensure_ascii=False)], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, pass_fds=(lock_fd,), check=False)
    if result.returncode:
        if result.stderr:
            print(result.stderr, end="", file=sys.stderr)
        raise SystemExit(result.returncode)
    event_id, seq = result.stdout.rstrip("\n").split("\t", 1)
    return event_id, seq


def main(argv: list[str]) -> int:
    try:
        args = parser().parse_args(argv)
        directory, events, lock = stream_paths(args.project)
        if args.command in {"list", "show"}:
            current = fold(events)
            if args.command == "list":
                if args.run and RUN_RE.fullmatch(args.run) is None:
                    return fail(64, "invalid run id")
                output = list_view(current, team=args.team, run_id=args.run, include_all=args.all)
            elif RUN_RE.fullmatch(args.id):
                output = current["runs"].get(args.id)
            elif TASK_RE.fullmatch(args.id):
                output = current["tasks"].get(args.id)
            else:
                return fail(64, "show expects r-<12 hex> or t-<12 hex>")
            if output is None:
                return fail(66, "ledger object not found")
            print(json.dumps(output, separators=(",", ":"), sort_keys=True))
            return 0

        validate_common(args)
        caller = identity_for(os.geteuid())
        payload, ident, body = payload_for(args, caller)
        request: dict[str, object] = {"event_type": COMMAND_EVENT[args.command], "project_uid": args.project, "team_uid": args.team, "run_id": args.run_id, "task_id": ident, "causation_id": args.causation_id, "actor_type": args.actor_type, "actor_id": args.actor_id, "caller": caller, "payload": payload}
        # Capture the task version before waiting for the stream lock.  The
        # authoritative fold/decision still happens under the lock; this token
        # makes two already-issued requests against the same state conflict
        # instead of silently becoming a different valid serial sequence.
        observed = fold(events)
        if ident in observed["tasks"]:
            request["expected_task_seq"] = observed["tasks"][ident]["last_seq"]
        try:
            lock_fd = acquire(lock)
        except TimeoutError:
            return fail(75, f"task stream lock not acquired within timeout: {lock}")
        try:
            # Registry authority is mutable; take its one decision snapshot only
            # after the stream lock is held so lead changes cannot race commit.
            registry = load_json(registry_path(ROOT))
            validate_registry_scope(registry, args.project, args.team)
            current = fold(events)
            actual_kind, actual_payload, accepted, reason = decide(request, current, registry, directory / "bodies", body)
            event_id, _ = commit(events, lock, lock_fd, request, actual_kind, actual_payload)
        finally:
            os.close(lock_fd)
        if ident:
            print(f"task_id={ident}")
        else:
            print(f"event_id={event_id}")
        if not accepted:
            print(f"ai-bobnet: task request rejected: {reason}", file=sys.stderr)
            return 77
        return 0
    except LedgerError as error:
        return fail(64, str(error))
    except (OSError, ValueError, json.JSONDecodeError) as error:
        return fail(65, str(error))


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
