#!/usr/bin/env python3
"""Authoritative run/task ledger CLI for trusted control-plane writers."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import shlex
import stat
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
    FORBIDDEN_DISPLAY,
    NONTERMINAL,
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


def valid_ref(value: str) -> bool:
    if REF_RE.fullmatch(value) is None:
        return False
    if value.startswith("file:"):
        path = value[5:]
        if not path or path.startswith("/") or any(part in {"", ".", ".."} for part in path.split("/")):
            return False
    return True


def safe_display_text(value: str) -> bool:
    return not any(char in FORBIDDEN_DISPLAY or char in "\x00\r\n" for char in value)


def read_body_file(path: str) -> bytes:
    fd = -1
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW | os.O_CLOEXEC)
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise LedgerError("task body file must be a regular file")
        chunks: list[bytes] = []
        total = 0
        while total <= 8192:
            chunk = os.read(fd, 8193 - total)
            if not chunk:
                return b"".join(chunks)
            chunks.append(chunk)
            total += len(chunk)
        raise LedgerError("task body exceeds 8192-byte limit")
    except OSError as error:
        raise LedgerError(f"cannot read body file: {error}") from error
    finally:
        if fd >= 0:
            os.close(fd)


def fail(code: int, message: str) -> int:
    print(f"ai-bobnet: {message}", file=sys.stderr)
    return code


def task_caller(test_seam: bool) -> str:
    if os.geteuid() == 0:
        return "root:root"
    caller = identity_for(os.geteuid())
    if test_seam and os.environ.get("AIB_IDENTITY_CMD"):
        try:
            result = subprocess.run(
                [*shlex.split(os.environ["AIB_IDENTITY_CMD"]), str(os.geteuid())],
                check=False,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                timeout=5,
            )
            value = result.stdout.splitlines()[0] if result.returncode == 0 and result.stdout else ""
            if value == "root:root":
                return value
        except (OSError, subprocess.TimeoutExpired):
            pass
    return caller


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
        sub.add_argument("--via")
        sub.add_argument("--requester")
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
        if name in {"assign", "reopen", "cancel"}:
            sub.add_argument("--expect-seq", type=int)
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
    if args.via is not None and re.fullmatch(r"(?:intent:[a-z0-9]+(?:-[a-z0-9]+)*|ctl:[0-9]+)", args.via, re.ASCII) is None:
        raise LedgerError("invalid relay reference")
    if args.requester is not None and re.fullmatch(r"(?:human:[a-z0-9][a-z0-9_-]*|gateway:[a-z0-9][a-z0-9_-]*)", args.requester, re.ASCII) is None:
        raise LedgerError("invalid requester")
    if getattr(args, "expect_seq", None) is not None and args.expect_seq < 1:
        raise LedgerError("expect-seq must be positive")
    if getattr(args, "expect_seq", None) is not None and args.actor_type not in {"human", "agent"}:
        raise LedgerError("engine events do not accept expect-seq")


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
        if len(args.title) > 120 or not args.title or not safe_display_text(args.title):
            raise LedgerError("title must be one line of 1..120 characters")
        if re.fullmatch(r"msg:[a-z0-9]+(?:-[a-z0-9]+)*", args.body_ref) is None:
            raise LedgerError("invalid body_ref")
        if len(args.context_ref) > 5 or any(not valid_ref(ref) for ref in args.context_ref):
            raise LedgerError("invalid context_refs")
        body = read_body_file(args.body_file)
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
        if args.result_ref is not None and not valid_ref(args.result_ref):
            raise LedgerError("invalid result_ref")
        if args.reason is not None and (len(args.reason) > 512 or not safe_display_text(args.reason)):
            raise LedgerError("reason must be one line of at most 512 characters")
        payload = {"state": args.state, "result_ref": args.result_ref, "reason": args.reason}
    elif args.command == "cancel":
        if args.reason is not None and (len(args.reason) > 512 or not safe_display_text(args.reason)):
            raise LedgerError("reason must be one line of at most 512 characters")
        payload = {"reason": args.reason}
    else:
        payload = {}
    payload["caller"] = caller
    if args.via is not None:
        payload["via"] = args.via
    if args.requester is not None:
        payload["requester"] = args.requester
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

        test_seam = os.environ.get("AIB_TEST_SEAMS") == "1" and not (ROOT / ".aib-installed").exists()
        if os.geteuid() != 0 and not test_seam:
            return fail(77, "caller_unauthorized")
        validate_common(args)
        caller = task_caller(test_seam)
        if caller != "root:root":
            return fail(77, "caller_unauthorized")
        payload, ident, body = payload_for(args, caller)
        request: dict[str, object] = {"event_type": COMMAND_EVENT[args.command], "project_uid": args.project, "team_uid": args.team, "run_id": args.run_id, "task_id": ident, "causation_id": args.causation_id, "actor_type": args.actor_type, "actor_id": args.actor_id, "caller": caller, "payload": payload}
        if getattr(args, "expect_seq", None) is not None:
            request["expected_task_seq"] = args.expect_seq
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
            if accepted and actual_kind == "run.closed" and actual_payload.get("outcome") in {"cancelled", "failed"}:
                for task in sorted(current["tasks"].values(), key=lambda value: value["task_id"]):
                    if task["run_id"] != args.run_id or task["state"] not in NONTERMINAL:
                        continue
                    cancel_request = dict(request)
                    cancel_request["event_type"] = "task.cancelled"
                    cancel_request["task_id"] = task["task_id"]
                    cancel_payload: dict[str, object] = {"caller": caller, "reason": "run_closed"}
                    for key in ("via", "requester"):
                        if key in actual_payload:
                            cancel_payload[key] = actual_payload[key]
                    commit(events, lock, lock_fd, cancel_request, "task.cancelled", cancel_payload)
            event_id, _ = commit(events, lock, lock_fd, request, actual_kind, actual_payload)
        finally:
            os.close(lock_fd)
        if ident:
            print(f"task_id={ident}")
        else:
            print(f"event_id={event_id}")
        if not accepted:
            if reason == "concurrent_update":
                print("ai-bobnet: task request rejected: concurrent_update (task state changed; re-read and retry)", file=sys.stderr)
                return 76
            print(f"ai-bobnet: task request rejected: {reason}", file=sys.stderr)
            return 77
        return 0
    except LedgerError as error:
        return fail(64, str(error))
    except (OSError, ValueError, json.JSONDecodeError) as error:
        return fail(65, str(error))


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
