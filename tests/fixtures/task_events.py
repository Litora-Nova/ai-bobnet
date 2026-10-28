#!/usr/bin/env python3
"""Small task-ledger spec helper: inspect or append a correctly framed event."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path


def frame(record: dict, seq: int) -> bytes:
    data = json.dumps(record, separators=(",", ":"), sort_keys=False).encode()
    return frame_bytes(data, seq)


def frame_bytes(data: bytes, seq: int) -> bytes:
    crc, length, *_ = subprocess.check_output(["cksum"], input=data).split()
    return str(seq).encode() + b" " + crc + b" " + length + b" " + data + b"\n"


def records(path: Path) -> list[dict]:
    result = []
    if not path.exists():
        return result
    for raw in path.read_bytes().splitlines():
        result.append(json.loads(raw.split(b" ", 3)[3]))
    return result


def main() -> int:
    command, path = sys.argv[1], Path(sys.argv[2])
    if command == "count":
        kind = sys.argv[3]
        print(sum(row.get("event_type") == kind for row in records(path)))
        return 0
    if command == "field":
        kind, occurrence, dotted = sys.argv[3], int(sys.argv[4]), sys.argv[5]
        rows = [row for row in records(path) if row.get("event_type") == kind]
        value: object = rows[occurrence]
        for part in dotted.split("."):
            value = value[part]  # type: ignore[index]
        if isinstance(value, (dict, list)):
            print(json.dumps(value, separators=(",", ":"), sort_keys=True))
        elif value is not None:
            print(str(value).lower() if isinstance(value, bool) else value)
        return 0
    if command == "append":
        record = json.loads(Path(sys.argv[3]).read_text(encoding="utf-8"))
        rows = records(path)
        seq = int(sys.argv[4]) if len(sys.argv) > 4 else len(rows) + 1
        with path.open("ab") as stream:
            stream.write(frame(record, seq))
        return 0
    if command == "inject":
        kind, actor_type, actor_id, project, team, run_id, task_id, causation, payload_json = sys.argv[3:12]
        seq = len(records(path)) + 1
        record = {
            "event_id": f"{project}-tasks-{seq}",
            "event_type": kind,
            "occurred_at": "2026-10-27T12:00:00Z",
            "actor_type": actor_type,
            "actor_id": actor_id,
            "project_uid": project,
            "team_uid": team,
            "agent_uid": actor_id if actor_type == "agent" else None,
            "session_id": None,
            "run_id": run_id,
            "task_id": None if task_id == "-" else task_id,
            "gate_id": None,
            "grant_id": None,
            "effect_id": None,
            "attempt_id": None,
            "correlation_id": run_id,
            "causation_id": causation,
            "schema_version": 2,
            "payload": json.loads(payload_json),
        }
        with path.open("ab") as stream:
            stream.write(frame(record, seq))
        return 0
    if command == "inject-invalid-utf8":
        project, team, run_id, task_id = sys.argv[3:7]
        seq = len(records(path)) + 1
        record = {
            "event_id": f"{project}-tasks-{seq}",
            "event_type": "task.cancelled",
            "occurred_at": "2026-10-27T12:00:00Z",
            "actor_type": "human",
            "actor_id": "operator",
            "project_uid": project,
            "team_uid": team,
            "agent_uid": None,
            "session_id": None,
            "run_id": run_id,
            "task_id": task_id,
            "gate_id": None,
            "grant_id": None,
            "effect_id": None,
            "attempt_id": None,
            "correlation_id": run_id,
            "causation_id": "invalid-utf8",
            "schema_version": 2,
            "payload": {"caller": "root:root", "via": "ctl:99", "requester": "human:operator", "reason": "INVALID_UTF8_SENTINEL"},
        }
        data = json.dumps(record, separators=(",", ":"), sort_keys=False).encode()
        data = data.replace(b"INVALID_UTF8_SENTINEL", b"bad-\xff-reason")
        with path.open("ab") as stream:
            stream.write(frame_bytes(data, seq))
        return 0
    raise SystemExit("usage: task_events.py <count|field|append|inject|inject-invalid-utf8> ...")


if __name__ == "__main__":
    raise SystemExit(main())
