#!/usr/bin/env python3
"""Task-stream fold and domain decision engine.

The files are the only state.  ``bin/task`` holds the stream lock before calling
``decide`` and keeps it through the shared ``aib_event_commit`` append.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import unicodedata
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
from attempts_fold import scan, unique_pairs

RUN_RE = re.compile(r"r-[0-9a-f]{12}\Z", re.ASCII)
TASK_RE = re.compile(r"t-[0-9a-f]{12}\Z", re.ASCII)
TOKEN_RE = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*\Z", re.ASCII)
UID_RE = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)+\Z", re.ASCII)
TERMINAL = {"DONE", "FAILED", "CANCELLED"}
NONTERMINAL = {"QUEUED", "ASSIGNED", "IN_PROGRESS", "BLOCKED", "REVIEW"}
OPEN_LIMIT = {"QUEUED", "ASSIGNED"}
ENGINE_REASONS = {"turn_failed", "turn_budget", "no_report"}
CLOSED_RUN = {"COMPLETED", "FAILED", "CANCELLED"}
EVENT_TYPES = {
    "run.requested", "run.started", "run.closed", "task.created", "task.started",
    "task.reported", "task.cancelled", "task.reassigned", "task.reopened",
    "task.overdue", "task.rejected", "task.review_passed", "task.review_failed",
}
DEFAULT_LIMITS = {
    "max_open": 8,
    "max_new_per_turn": 4,
    "max_tasks_per_run": 20,
    "max_assignments_per_task": 3,
    "max_depth": 1,
    "task_deadline_s": 14400,
    "max_turns_per_task": 8,
}


class LedgerError(ValueError):
    pass


def load_json(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as stream:
        value = json.load(stream, object_pairs_hook=unique_pairs)
    if not isinstance(value, dict):
        raise LedgerError(f"not a JSON object: {path}")
    return value


def task_id(causation_id: str, intent_n: int) -> str:
    digest = hashlib.sha256(f"{causation_id}:{intent_n}".encode()).hexdigest()[:12]
    return f"t-{digest}"


def safe_display_text(value: str) -> bool:
    """Return whether single-line display text contains no control/format chars."""
    return not any(
        unicodedata.category(char) in {"Cc", "Cf", "Cs", "Co", "Cn", "Zl", "Zp"}
        or 0xE0000 <= ord(char) <= 0xE007F
        for char in value
    )


def _text(value: Any, name: str, *, optional: bool = False) -> str | None:
    if value is None and optional:
        return None
    if not isinstance(value, str) or any(char in value for char in "\x00\r\n"):
        raise LedgerError(f"invalid {name}")
    return value


def _caller_matches(record: dict[str, Any]) -> bool:
    caller = record.get("payload", {}).get("caller")
    payload = record.get("payload", {})
    actor_type, actor_id = record.get("actor_type"), record.get("actor_id")
    if caller != "root:root":
        return False
    via, requester = payload.get("via"), payload.get("requester")
    if actor_type == "service":
        return isinstance(actor_id, str) and actor_id.startswith("supervisor:") and via is None and requester is None
    if actor_type == "agent":
        return isinstance(via, str) and re.fullmatch(r"intent:[a-z0-9]+(?:-[a-z0-9]+)*", via, re.ASCII) is not None and requester is None
    if actor_type == "human" and isinstance(via, str) and re.fullmatch(r"ctl:[0-9]+", via, re.ASCII):
        if isinstance(actor_id, str) and actor_id.startswith("gateway:"):
            return requester == actor_id
        return isinstance(actor_id, str) and requester == f"human:{actor_id}"
    return False


def read_events(path: Path) -> tuple[dict[str, Any], list[tuple[int, dict[str, Any]]], list[dict[str, Any]]]:
    metadata, raw_records = scan(path)
    if metadata["status"] == "corrupt":
        raise LedgerError(metadata["reason"])
    records: list[tuple[int, dict[str, Any]]] = []
    invalid_records: list[dict[str, Any]] = []
    for raw_seq, raw in raw_records:
        seq = int(raw_seq)
        try:
            record = json.loads(raw.decode("utf-8"), object_pairs_hook=unique_pairs)
        except UnicodeError:
            invalid_records.append({"seq": seq, "reason": "invalid_utf8"})
            continue
        except ValueError:
            invalid_records.append({"seq": seq, "reason": "invalid_json"})
            continue
        if not isinstance(record, dict):
            invalid_records.append({"seq": seq, "reason": "invalid_shape"})
            continue
        records.append((seq, record))
    return metadata, records, invalid_records


def _base_task(record: dict[str, Any], payload: dict[str, Any]) -> dict[str, Any]:
    run_id = _text(record.get("run_id"), "run_id")
    ident = _text(record.get("task_id"), "task_id")
    if not RUN_RE.fullmatch(run_id or "") or not TASK_RE.fullmatch(ident or ""):
        raise LedgerError("invalid task identity")
    depth = payload.get("depth")
    if depth != 1 or payload.get("parent") != run_id:
        raise LedgerError("invalid task parent/depth")
    assignee = _text(payload.get("assignee"), "assignee")
    source = _text(payload.get("source_msg_id"), "source_msg_id")
    gate = _text(payload.get("gate"), "gate")
    title = _text(payload.get("title"), "title")
    if not UID_RE.fullmatch(assignee or "") or not TOKEN_RE.fullmatch(source or ""):
        raise LedgerError("invalid task assignee/source")
    if gate not in {"none", "code", "compliance", "gatekeeper"}:
        raise LedgerError("invalid task gate")
    if not title or len(title) > 120 or not safe_display_text(title):
        raise LedgerError("invalid_title")
    return {
        "task_id": ident,
        "run_id": run_id,
        "team_uid": record.get("team_uid"),
        "parent": payload["parent"],
        "depth": depth,
        "source_msg_id": source,
        "owner": payload.get("owner"),
        "assignee": assignee,
        "title": title,
        "body_ref": payload.get("body_ref"),
        "deadline_at": payload.get("deadline_at"),
        "budget": payload.get("budget"),
        "gate": gate,
        "context_refs": payload.get("context_refs", []),
        "state": "ASSIGNED",
        "assignments": 1,
        "attempts": 1,
        "turns": 0,
        "turns_total": 0,
        "result_ref": None,
        "last_reason": None,
        "created_seq": None,
        "last_seq": None,
        "state_seq": None,
    }


def fold(path: Path) -> dict[str, Any]:
    metadata, events, invalid_records = read_events(path)
    runs: dict[str, dict[str, Any]] = {}
    tasks: dict[str, dict[str, Any]] = {}
    rejections: list[dict[str, Any]] = []
    invalid_events = list(invalid_records)
    stream_project: str | None = None

    def invalid(seq: int, reason: str) -> None:
        invalid_events.append({"seq": seq, "reason": reason})

    for seq, record in events:
        kind = record.get("event_type")
        payload = record.get("payload")
        project = record.get("project_uid")
        run_id, ident = record.get("run_id"), record.get("task_id")
        causation = record.get("causation_id")
        if not isinstance(kind, str) or kind not in EVENT_TYPES or not isinstance(payload, dict):
            invalid(seq, "invalid_shape")
            continue
        if not isinstance(project, str) or TOKEN_RE.fullmatch(project) is None or record.get("event_id") != f"{project}-tasks-{seq}":
            invalid(seq, "invalid_envelope_identity")
            continue
        if stream_project is None:
            stream_project = project
        if project != stream_project or record.get("attempt_id") is not None or record.get("correlation_id") != run_id:
            invalid(seq, "invalid_envelope_identity")
            continue
        if not isinstance(run_id, str) or RUN_RE.fullmatch(run_id) is None or not isinstance(causation, str) or TOKEN_RE.fullmatch(causation) is None:
            invalid(seq, "invalid_envelope_identity")
            continue
        team_uid = record.get("team_uid")
        if not isinstance(team_uid, str) or not team_uid.startswith(f"{project}-") or UID_RE.fullmatch(team_uid) is None:
            invalid(seq, "invalid_envelope_identity")
            continue
        if kind.startswith("task.") and kind != "task.rejected" and (not isinstance(ident, str) or TASK_RE.fullmatch(ident) is None):
            invalid(seq, "invalid_envelope_identity")
            continue
        if kind == "task.rejected" and ident is not None and (not isinstance(ident, str) or TASK_RE.fullmatch(ident) is None):
            invalid(seq, "invalid_envelope_identity")
            continue
        if kind == "task.rejected":
            reason = payload.get("reason")
            requested = payload.get("requested_type")
            caller = payload.get("caller")
            if isinstance(reason, str) and isinstance(requested, str) and caller == "root:root":
                rejections.append({"seq": seq, "task_id": record.get("task_id"), "run_id": record.get("run_id"), "requested_type": requested, "reason": reason})
            else:
                invalid(seq, "invalid_rejection")
            continue
        if not _caller_matches(record):
            invalid(seq, "caller_actor_mismatch")
            continue
        try:
            if kind == "run.requested":
                if run_id in runs or record.get("actor_type") != "human":
                    raise LedgerError("invalid_run_request")
                runs[run_id] = {"run_id": run_id, "team_uid": record.get("team_uid"), "state": "QUEUED", "created_seq": seq, "outcome": None}
            elif kind == "run.started":
                if run_id not in runs or runs[run_id]["state"] != "QUEUED":
                    raise LedgerError("invalid_run_start")
                if runs[run_id]["team_uid"] != team_uid:
                    raise LedgerError("cross_team")
                if record.get("actor_type") != "service":
                    raise LedgerError("invalid_run_start_actor")
                runs[run_id]["state"] = "RUNNING"
            elif kind == "run.closed":
                if run_id not in runs or runs[run_id]["state"] in CLOSED_RUN:
                    raise LedgerError("invalid_run_close")
                if runs[run_id]["team_uid"] != team_uid:
                    raise LedgerError("cross_team")
                if record.get("actor_type") not in {"human", "agent"}:
                    raise LedgerError("invalid_run_close_actor")
                outcome = payload.get("outcome")
                if outcome not in {"completed", "failed", "cancelled"}:
                    raise LedgerError("invalid_run_outcome")
                open_tasks = [task for task in tasks.values() if task["run_id"] == run_id and task["state"] in NONTERMINAL]
                if open_tasks and outcome == "completed":
                    raise LedgerError("open_tasks")
                # failed/cancelled run closure is one durable event. The fold
                # derives its child cancellation cascade from that event so a
                # crash can never expose a partially-cancelled open run.
                for task in open_tasks:
                    task["state"] = "CANCELLED"
                    task["last_reason"] = "run_closed"
                    task["last_seq"] = seq
                    task["state_seq"] = seq
                runs[run_id]["state"] = outcome.upper()
                runs[run_id]["outcome"] = outcome
            elif kind == "task.created":
                if run_id not in runs or ident in tasks:
                    raise LedgerError("invalid_task_create")
                if runs[run_id]["team_uid"] != team_uid:
                    raise LedgerError("cross_team")
                if runs[run_id]["state"] in CLOSED_RUN:
                    raise LedgerError("run_closed")
                task = _base_task(record, payload)
                if record.get("actor_type") == "agent" and record.get("actor_id") != task["owner"]:
                    raise LedgerError("invalid_creator")
                if record.get("actor_type") not in {"agent", "human"}:
                    raise LedgerError("invalid_creator")
                task["created_seq"] = seq
                task["last_seq"] = seq
                task["state_seq"] = seq
                tasks[ident] = task
                if runs[run_id]["state"] == "QUEUED":
                    runs[run_id]["state"] = "RUNNING"
            else:
                if not isinstance(ident, str) or ident not in tasks or tasks[ident]["run_id"] != run_id:
                    raise LedgerError("unknown_task")
                task = tasks[ident]
                if task["team_uid"] != team_uid:
                    raise LedgerError("cross_team")
                run = runs.get(run_id)
                if run is None or run["team_uid"] != task["team_uid"]:
                    raise LedgerError("invalid_task_run")
                if run["state"] in CLOSED_RUN:
                    raise LedgerError("run_closed")
                state = task["state"]
                old_state, old_assignee = state, task["assignee"]
                if kind == "task.started":
                    if state != "ASSIGNED" or record.get("actor_type") != "service" or record.get("actor_id") != f"supervisor:{task['assignee']}":
                        raise LedgerError("invalid_start")
                    task["state"] = "IN_PROGRESS"
                elif kind == "task.reported":
                    report = payload.get("state")
                    reason = payload.get("reason")
                    if reason is not None and (not isinstance(reason, str) or len(reason) > 512 or not safe_display_text(reason)):
                        raise LedgerError("invalid_reason")
                    actor_ok = record.get("actor_type") == "agent" and record.get("actor_id") == task["assignee"]
                    service_ok = (record.get("actor_type") == "service" and record.get("actor_id") == f"supervisor:{task['assignee']}" and report in {"failed", "blocked"} and reason in ENGINE_REASONS)
                    if state != "IN_PROGRESS" or not (actor_ok or service_ok) or report not in {"progress", "done", "failed", "blocked"}:
                        raise LedgerError("invalid_report")
                    if report == "progress":
                        task["turns"] += 1
                        task["turns_total"] += 1
                    task["result_ref"] = payload.get("result_ref")
                    task["last_reason"] = reason
                    task["state"] = {"progress": "IN_PROGRESS", "done": "REVIEW" if task["gate"] != "none" else "DONE", "failed": "FAILED", "blocked": "BLOCKED"}[report]
                elif kind == "task.cancelled":
                    if state in TERMINAL:
                        raise LedgerError("invalid_cancel")
                    reason = payload.get("reason")
                    if reason is not None and (not isinstance(reason, str) or len(reason) > 512 or not safe_display_text(reason)):
                        raise LedgerError("invalid_reason")
                    delivery = record.get("actor_type") == "service" and record.get("actor_id") == f"supervisor:{task['assignee']}" and reason == "delivery_failed" and state == "ASSIGNED"
                    if record.get("actor_type") not in {"human", "agent"} and not delivery:
                        raise LedgerError("invalid_cancel_actor")
                    task["state"] = "CANCELLED"
                    task["last_reason"] = reason
                elif kind in {"task.reassigned", "task.reopened"}:
                    if record.get("actor_type") not in {"human", "agent"}:
                        raise LedgerError("invalid_reassignment_actor")
                    allowed = state == "BLOCKED" or (kind == "task.reopened" and state == "FAILED")
                    if not allowed:
                        raise LedgerError("invalid_reassignment")
                    assignee = payload.get("assignee")
                    if not isinstance(assignee, str) or UID_RE.fullmatch(assignee) is None:
                        raise LedgerError("invalid_assignee")
                    task["assignee"] = assignee
                    task["assignments"] += 1
                    task["attempts"] += 1
                    task["turns"] = 0
                    task["state"] = "ASSIGNED"
                elif kind == "task.overdue":
                    if state in TERMINAL or record.get("actor_type") != "service" or not str(record.get("actor_id", "")).startswith("supervisor:"):
                        raise LedgerError("invalid_overdue")
                    task["last_reason"] = "overdue"
                elif kind in {"task.review_passed", "task.review_failed"}:
                    # Reserved events do not yet acquire transition semantics.
                    raise LedgerError("reserved_event")
                else:
                    raise LedgerError("unknown_event")
                task["last_seq"] = seq
                if task["state"] != old_state or task["assignee"] != old_assignee:
                    task["state_seq"] = seq
        except LedgerError as error:
            invalid(seq, str(error))

    # Run state is derived from its task fold, never cached separately. Closed
    # run events remain terminal; otherwise a wholly blocked active frontier is
    # BLOCKED, any task means RUNNING, and no task means QUEUED.
    for folded_run_id, run in runs.items():
        if run["state"] in CLOSED_RUN:
            continue
        children = [task for task in tasks.values() if task["run_id"] == folded_run_id]
        active = [task for task in children if task["state"] in NONTERMINAL]
        if active and all(task["state"] == "BLOCKED" for task in active):
            run["state"] = "BLOCKED"
        elif children:
            run["state"] = "RUNNING"
        else:
            run["state"] = "QUEUED"

    invalid_events.sort(key=lambda item: item["seq"])
    return {
        "stream_status": metadata["status"],
        "highest_seq": metadata["highest"],
        "invalid": len(invalid_events),
        "invalid_events": invalid_events,
        "runs": runs,
        "tasks": tasks,
        "rejections": rejections,
    }


def limits(registry: dict[str, Any], team_uid: str) -> dict[str, int]:
    teams = registry.get("teams")
    if not isinstance(teams, dict) or not isinstance(teams.get(team_uid), dict):
        raise LedgerError("unknown_team")
    delegation = teams[team_uid].get("delegation", {})
    if not isinstance(delegation, dict):
        raise LedgerError("invalid_delegation_limits")
    if set(delegation) - set(DEFAULT_LIMITS):
        raise LedgerError("invalid_delegation_limits")
    result = dict(DEFAULT_LIMITS)
    for name, default in DEFAULT_LIMITS.items():
        value = delegation.get(name, default)
        if isinstance(value, str) and value.isdecimal():
            value = int(value)
        if not isinstance(value, int) or isinstance(value, bool) or value < 1:
            raise LedgerError(f"invalid_{name}")
        result[name] = value
    if result["max_depth"] > 1:
        raise LedgerError("invalid_max_depth")
    return result


def validate_registry_scope(registry: dict[str, Any], project_uid: str, team_uid: str) -> None:
    if registry.get("schema_version") != 5:
        raise LedgerError("task ledger requires registry schema_version 5")
    projects, teams = registry.get("projects"), registry.get("teams")
    if not isinstance(projects, dict) or not isinstance(projects.get(project_uid), dict):
        raise LedgerError("unknown_project")
    if not isinstance(teams, dict) or not isinstance(teams.get(team_uid), dict):
        raise LedgerError("unknown_team")
    if teams[team_uid].get("project") != project_uid or not team_uid.startswith(f"{project_uid}-"):
        raise LedgerError("team_project_mismatch")
    team_lead(registry, team_uid)


def _agent(registry: dict[str, Any], uid: str) -> dict[str, Any] | None:
    agents = registry.get("agents", {})
    value = agents.get(uid) if isinstance(agents, dict) else None
    return value if isinstance(value, dict) else None


def team_lead(registry: dict[str, Any], team: str) -> str:
    agents = registry.get("agents")
    if not isinstance(agents, dict):
        raise LedgerError("invalid_agents_registry")
    found = [uid for uid, value in agents.items() if isinstance(value, dict) and value.get("team_uid") == team and value.get("lead") == "true"]
    if len(found) != 1:
        raise LedgerError("team must have exactly one lead")
    return found[0]


def _valid_assignee(registry: dict[str, Any], uid: str, team: str) -> str | None:
    value = _agent(registry, uid)
    if not value:
        return "unknown_assignee"
    if value.get("team_uid") != team:
        return "cross_team"
    if value.get("mode") != "supervised" or value.get("lead") == "true":
        return "invalid_assignee"
    return None


def caller_actor_reason(caller: str, actor_type: str, actor_id: str, payload: dict[str, Any]) -> str | None:
    if caller != "root:root":
        return "caller_unauthorized"
    record = {"actor_type": actor_type, "actor_id": actor_id, "payload": payload}
    return None if _caller_matches(record) else "caller_actor_mismatch"


def _write_body(body_dir: Path, ident: str, body: bytes) -> bool:
    if len(body) > 8192 or b"\0" in body:
        return False
    parent_fd = bodies_fd = file_fd = -1
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    try:
        parent_fd = os.open(body_dir.parent, flags)
        bodies_fd = os.open(body_dir.name, flags, dir_fd=parent_fd)
        name = f"{ident}.md"
        try:
            file_fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o640, dir_fd=bodies_fd)
            os.fchmod(file_fd, 0o640)
            view = memoryview(body)
            while view:
                written = os.write(file_fd, view)
                view = view[written:]
            os.fsync(file_fd)
        except FileExistsError:
            file_fd = os.open(name, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=bodies_fd)
            info = os.fstat(file_fd)
            bodies_info = os.fstat(bodies_fd)
            test_seam = os.environ.get("AIB_TEST_SEAMS") == "1" and not (Path(__file__).resolve().parent.parent / ".aib-installed").exists()
            expected_uid = os.geteuid() if test_seam else 0
            if not stat.S_ISREG(info.st_mode) or info.st_uid != expected_uid or info.st_gid != bodies_info.st_gid or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o640:
                return False
            chunks: list[bytes] = []
            total = 0
            while True:
                chunk = os.read(file_fd, 8193 - total)
                if not chunk:
                    break
                chunks.append(chunk)
                total += len(chunk)
                if total > 8192:
                    return False
            return b"".join(chunks) == body
        return True
    except OSError:
        return False
    finally:
        for fd in (file_fd, bodies_fd, parent_fd):
            if fd >= 0:
                os.close(fd)


def rejection(request: dict[str, Any], reason: str) -> tuple[str, dict[str, Any], bool, str]:
    return "task.rejected", {"caller": request["caller"], "requested_type": request["event_type"], "reason": reason}, False, reason


def decide(request: dict[str, Any], current: dict[str, Any], registry: dict[str, Any], body_dir: Path, body: bytes | None) -> tuple[str, dict[str, Any], bool, str]:
    kind = request["event_type"]
    payload = dict(request["payload"])
    actor_type, actor_id, caller = request["actor_type"], request["actor_id"], request["caller"]
    team, run_id, ident = request["team_uid"], request["run_id"], request.get("task_id")
    payload["caller"] = caller
    mismatch = caller_actor_reason(caller, actor_type, actor_id, payload)
    if mismatch:
        return rejection(request, mismatch)
    team_limits = limits(registry, team)
    runs, tasks = current["runs"], current["tasks"]
    requester = payload.get("requester")
    is_human = actor_type == "human" and isinstance(requester, str) and requester.startswith("human:")
    is_gateway = actor_type == "human" and isinstance(requester, str) and requester.startswith("gateway:")
    lead_uid = team_lead(registry, team)
    is_lead = actor_type == "agent" and actor_id == lead_uid
    is_service = actor_type == "service"

    if kind == "run.requested":
        if not (is_human or is_gateway):
            return rejection(request, "unauthorized")
        if run_id in runs:
            return rejection(request, "duplicate")
    elif kind == "run.closed":
        run = runs.get(run_id)
        if run is None:
            return rejection(request, "unknown_run")
        if run["team_uid"] != team:
            return rejection(request, "cross_team")
        if run["state"] in CLOSED_RUN:
            return rejection(request, "run_closed")
        if not (is_human or is_lead):
            return rejection(request, "not_lead")
        if payload.get("outcome") == "completed" and any(task["run_id"] == run_id and task["state"] in NONTERMINAL for task in tasks.values()):
            return rejection(request, "open_tasks")
    elif kind == "task.created":
        if not (is_human or is_lead):
            return rejection(request, "not_lead")
        run = runs.get(run_id)
        if run is None:
            return rejection(request, "unknown_run")
        if run["team_uid"] != team:
            return rejection(request, "cross_team")
        if run["state"] in CLOSED_RUN:
            return rejection(request, "run_closed")
        if ident in tasks:
            return rejection(request, "duplicate")
        if payload.get("gate") != "none":
            return rejection(request, "gate_not_available")
        if payload.get("depth") != 1 or payload["depth"] > team_limits["max_depth"]:
            return rejection(request, "max_depth")
        assignee_reason = _valid_assignee(registry, payload.get("assignee", ""), team)
        if assignee_reason:
            return rejection(request, assignee_reason)
        if any(task["state"] in NONTERMINAL and task["source_msg_id"] == payload.get("source_msg_id") and task["assignee"] == payload.get("assignee") for task in tasks.values()):
            return rejection(request, "duplicate")
        if sum(task["state"] in OPEN_LIMIT and task["team_uid"] == team for task in tasks.values()) >= team_limits["max_open"]:
            return rejection(request, "max_open")
        if sum(task["assignments"] for task in tasks.values() if task["run_id"] == run_id) >= team_limits["max_tasks_per_run"]:
            return rejection(request, "max_tasks_per_run")
        if payload.get("deadline_at") is None:
            payload["deadline_at"] = (datetime.now(timezone.utc) + timedelta(seconds=team_limits["task_deadline_s"])).replace(microsecond=0).isoformat().replace("+00:00", "Z")
        payload["budget"] = {"max_turns": team_limits["max_turns_per_task"], "max_attempts": team_limits["max_assignments_per_task"]}
        if body is None or not _write_body(body_dir, ident, body):
            return rejection(request, "unsafe_body_sidecar")
    else:
        task = tasks.get(ident)
        if not task or task["run_id"] != run_id:
            return rejection(request, "unknown_task")
        if task["team_uid"] != team:
            return rejection(request, "cross_team")
        run = runs.get(run_id)
        if run is None or run["team_uid"] != task["team_uid"]:
            return rejection(request, "unknown_run")
        if run["state"] in CLOSED_RUN:
            return rejection(request, "run_closed")
        state = task["state"]
        expected_seq = request.get("expected_task_seq")
        if kind in {"task.reassigned", "task.reopened", "task.cancelled"} and (is_human or is_gateway or is_lead) and expected_seq is not None and task["state_seq"] != expected_seq:
            return rejection(request, "concurrent_update")
        if kind == "task.started":
            if not (is_service and actor_id == f"supervisor:{task['assignee']}"):
                return rejection(request, "not_assignee")
            if state != "ASSIGNED":
                return rejection(request, "invalid_transition")
        elif kind == "task.reported":
            report = payload.get("state")
            agent_ok = actor_type == "agent" and actor_id == task["assignee"]
            service_ok = is_service and actor_id == f"supervisor:{task['assignee']}" and report in {"failed", "blocked"} and payload.get("reason") in ENGINE_REASONS
            if not (agent_ok or service_ok):
                return rejection(request, "not_assignee" if not is_service else "unauthorized_reason")
            if state != "IN_PROGRESS":
                return rejection(request, "invalid_transition")
            if report == "progress" and task["turns"] >= team_limits["max_turns_per_task"]:
                return rejection(request, "max_turns_per_task")
        elif kind == "task.cancelled":
            delivery = is_service and actor_id == f"supervisor:{task['assignee']}" and payload.get("reason") == "delivery_failed" and state == "ASSIGNED"
            if not (is_human or is_gateway or is_lead or delivery):
                return rejection(request, "unauthorized")
            if state in TERMINAL:
                return rejection(request, "invalid_transition")
        elif kind in {"task.reassigned", "task.reopened"}:
            if not (is_human or is_lead):
                return rejection(request, "not_lead")
            allowed = state == "BLOCKED" or (kind == "task.reopened" and state == "FAILED")
            if not allowed:
                return rejection(request, "invalid_transition")
            assignee_reason = _valid_assignee(registry, payload.get("assignee", ""), team)
            if assignee_reason:
                return rejection(request, assignee_reason)
            if task["assignments"] >= team_limits["max_assignments_per_task"]:
                return rejection(request, "max_assignments_per_task")
            if sum(item["state"] in OPEN_LIMIT and item["team_uid"] == team for item in tasks.values()) >= team_limits["max_open"]:
                return rejection(request, "max_open")
            if sum(item["assignments"] for item in tasks.values() if item["run_id"] == run_id) >= team_limits["max_tasks_per_run"]:
                return rejection(request, "max_tasks_per_run")
        elif kind == "task.overdue":
            if not (is_service and actor_id == f"supervisor:{lead_uid}"):
                return rejection(request, "not_lead")
            if state in TERMINAL:
                return rejection(request, "invalid_transition")
        else:
            return rejection(request, "unsupported_event")
    return kind, payload, True, "accepted"


def list_view(current: dict[str, Any], *, team: str | None = None, run_id: str | None = None, include_all: bool = False) -> dict[str, Any]:
    tasks = [task for task in current["tasks"].values() if (team is None or task["team_uid"] == team) and (run_id is None or task["run_id"] == run_id) and (include_all or task["state"] not in TERMINAL)]
    runs = [run for run in current["runs"].values() if (team is None or run["team_uid"] == team) and (run_id is None or run["run_id"] == run_id)]
    return {
        "highest_seq": current["highest_seq"],
        "invalid": current["invalid"],
        "invalid_events": current["invalid_events"],
        "rejections": current["rejections"],
        "runs": sorted(runs, key=lambda row: row["run_id"]),
        "stream_status": current["stream_status"],
        "tasks": sorted(tasks, key=lambda row: row["task_id"]),
    }


def _fixture_gated(path: Path) -> None:
    events = [
        ("run.requested", None, {"caller": "root:root", "via": "ctl:1", "requester": "human:operator"}, "human", "operator"),
        ("task.created", "t-aaaaaaaaaaaa", {"caller": "root:root", "via": "ctl:2", "requester": "human:operator", "parent": "r-aaaaaaaaaaaa", "depth": 1, "source_msg_id": "msg-gate", "owner": "human:operator", "assignee": "acme-dev1", "title": "Gate", "body_ref": "msg:gate", "deadline_at": "2026-10-28T00:00:00Z", "budget": {"max_turns": 8, "max_attempts": 3}, "gate": "code", "context_refs": []}, "human", "operator"),
        ("task.started", "t-aaaaaaaaaaaa", {"caller": "root:root"}, "service", "supervisor:acme-dev1"),
        ("task.reported", "t-aaaaaaaaaaaa", {"caller": "root:root", "via": "intent:fixture-4", "state": "done", "result_ref": "msg:result", "reason": None}, "agent", "acme-dev1"),
    ]
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as stream:
        for seq, (kind, ident, payload, actor_type, actor_id) in enumerate(events, 1):
            record = {"event_id": f"acme-tasks-{seq}", "event_type": kind, "occurred_at": "2026-10-27T12:00:00Z", "actor_type": actor_type, "actor_id": actor_id, "project_uid": "acme", "team_uid": "acme-engine", "agent_uid": actor_id if actor_type == "agent" else None, "session_id": None, "run_id": "r-aaaaaaaaaaaa", "task_id": ident, "gate_id": None, "grant_id": None, "effect_id": None, "attempt_id": None, "correlation_id": "r-aaaaaaaaaaaa", "causation_id": f"fixture-{seq}", "schema_version": 2, "payload": payload}
            data = json.dumps(record, separators=(",", ":")).encode()
            crc, length, *_ = subprocess.check_output(["cksum"], input=data).split()
            stream.write(str(seq).encode() + b" " + crc + b" " + length + b" " + data + b"\n")


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "fixture-gated":
        _fixture_gated(Path(sys.argv[2]))
    else:
        raise SystemExit("task_ledger.py is an internal module")
