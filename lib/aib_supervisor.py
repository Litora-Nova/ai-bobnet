#!/usr/bin/env python3
"""Single-writer supervisor loop for resumable provider turns."""

from __future__ import annotations

import errno
import fcntl
import json
import os
import random
import re
import shlex
import signal
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
from aib_control import append_record, identity_for, requested_record
from aib_deployment import deployment_allows


class JournalCorruptError(ValueError):
    """The durable journal cannot be trusted without operator repair."""


class SupervisorLockError(OSError):
    """Another supervisor already owns this agent's state directory."""


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def positive_int(value: Any, default: int) -> int:
    if value is None:
        return default
    if not isinstance(value, str) or not value.isdigit() or int(value) <= 0:
        raise ValueError("positive integer string required")
    return int(value)


def interval(name: str, default: float) -> float:
    raw = os.environ.get(name)
    if raw is None:
        return default
    value = float(raw)
    if value <= 0:
        raise ValueError(f"{name} must be positive")
    return value


class Supervisor:
    def __init__(self, root: Path, uid: str) -> None:
        self.root = root
        self.uid = uid
        self.registry_path = Path(os.environ.get("AIBOBNET_REGISTRY", root / "registry.json"))
        state_root = Path(os.environ.get("AIB_SUP_STATE_ROOT", "/var/lib/aib-sup"))
        self.state_dir = Path(os.environ.get("STATE_DIRECTORY", state_root / uid))
        self.state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.lock_path = self.state_dir / "supervisor.lock"
        self.lock_fd = self._acquire_lock()
        self.journal_path = self.state_dir / "journal.jsonl"
        self.live_path = self.state_dir / "live.json"
        self.records, dropped_bytes = self._load_records()
        self.journal_seq = max((r.get("seq", 0) for r in self.records), default=0)
        if dropped_bytes:
            self.journal("journal.repaired", dropped_bytes=dropped_bytes)
        self.tick_seq = self._old_tick_seq()

        self.config_invalid = False
        self.tick_s = self._configured_interval("AIB_SUP_TICK_S", 30.0)
        self.poll_s = self._configured_interval("AIB_SUP_POLL_S", 2.0)
        self.backoff_base = self._configured_interval("AIB_SUP_BACKOFF_BASE_S", 10.0)
        self.infra_min = self._configured_interval("AIB_SUP_INFRA_BACKOFF_MIN_S", 5.0)
        self.infra_max = self._configured_interval("AIB_SUP_INFRA_BACKOFF_MAX_S", 120.0)
        self.blocked_after = self._configured_interval("AIB_SUP_BLOCKED_AFTER_S", 600.0)
        self.orphan_poll = self._configured_interval("AIB_SUP_ORPHAN_POLL_S", 10.0)
        self.call_timeout = self._configured_interval("AIB_SUP_CALL_TIMEOUT_S", 30.0)
        if self.infra_max < self.infra_min:
            self.config_invalid = True

        self.launcher = shlex.split(os.environ.get("AIB_LAUNCH_AGENT", str(root / "bin/launch-agent")))
        self.broker_client = shlex.split(os.environ.get("AIB_BROKER_CLIENT", str(root / "bin/aib-broker-client")))
        self.run_agent = root / "bin/run-agent"
        self.message = root / "bin/message"

        self.project_home = ""
        self.standup = Path("/")
        self.inbox = Path("/")
        self.transcript = Path("/")
        self.cap_timeout = 900
        self.session_max_turns = 200
        self.brake_burst = 5
        self.backoff_cap = 600.0
        self.registry: dict[str, Any] = {}
        self.agent: dict[str, Any] = {}
        self.project_uid = ""
        self.team_uid = ""
        self.data_class = "customer"
        self.protected = ""
        self.ctl_dir = Path(os.environ.get("AIB_CTL_DIR", "/run/aib/ctl"))
        self.control_log = Path(os.environ.get("AIB_CONTROL_LOG", "/srv/aib/standup/_control.jsonl"))
        self.outbox_root = Path(os.environ.get("AIB_OUTBOX_ROOT", "/srv/aib/outbox"))
        self.cancel_grace = self._configured_interval("AIB_SUP_CANCEL_GRACE_S", 30.0)

        self.state = "STARTING"
        self.state_reason = ""
        self.current_turn: dict[str, Any] | None = None
        self.session_id: str | None = None
        self.session_cwd: str | None = None
        self.session_new = False
        self.turns_in_session = 0
        self.brake_consecutive = 0
        self.brake_tripped_at: str | None = None
        self.message_failures: dict[str, int] = {}
        self.off_duty = False
        self.consumed: set[int] = set()

        self.process: subprocess.Popen[bytes] | None = None
        self.output_file: Any = None
        self.output_path: Path | None = None
        self.attempt: dict[str, Any] | None = None
        self.work: dict[str, Any] | None = None
        self.retry_at = 0.0
        self.infra_since: float | None = None
        self.last_heartbeat: str | None = None
        self.stop_requested = False
        self.reexec_requested = False
        self.exit_code = 0
        self.next_tick = time.monotonic()
        self.next_poll = time.monotonic()

    def _configured_interval(self, name: str, default: float) -> float:
        try:
            return interval(name, default)
        except (TypeError, ValueError):
            self.config_invalid = True
            return default

    def _acquire_lock(self) -> int:
        inherited = os.environ.get("AIB_SUP_LOCK_FD") if os.environ.get("AIB_SUP_REEXEC") == "1" else None
        if inherited is not None:
            try:
                lock_fd = int(inherited)
                if lock_fd < 0 or not os.path.samestat(os.fstat(lock_fd), os.stat(self.lock_path)):
                    raise ValueError
            except (OSError, ValueError) as error:
                raise SupervisorLockError("invalid inherited supervisor lock") from error
        else:
            lock_fd = os.open(self.lock_path, os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            if inherited is None:
                os.close(lock_fd)
            if error.errno in (errno.EACCES, errno.EAGAIN):
                raise SupervisorLockError("supervisor lock is already held") from error
            raise
        os.set_inheritable(lock_fd, True)
        return lock_fd

    def _load_records(self) -> tuple[list[dict[str, Any]], int]:
        records: list[dict[str, Any]] = []
        try:
            data = self.journal_path.read_bytes()
        except FileNotFoundError:
            return records, 0

        dropped_bytes = 0
        complete = data
        if data and not data.endswith(b"\n"):
            boundary = data.rfind(b"\n") + 1
            complete = data[:boundary]
            dropped_bytes = len(data) - boundary
        try:
            for line in complete.decode("utf-8").splitlines():
                if line.strip():
                    record = json.loads(line)
                    if not isinstance(record, dict):
                        raise ValueError("supervisor journal record is not an object")
                    records.append(record)
        except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
            raise JournalCorruptError("supervisor journal contains a corrupt record") from error
        expected = list(range(1, len(records) + 1))
        if [record.get("seq") for record in records] != expected:
            raise JournalCorruptError("supervisor journal sequence is corrupt")
        if dropped_bytes:
            with self.journal_path.open("r+b") as stream:
                stream.truncate(len(complete))
                stream.flush()
                os.fsync(stream.fileno())
        return records, dropped_bytes

    def _old_tick_seq(self) -> int:
        try:
            value = json.loads(self.live_path.read_text(encoding="utf-8")).get("seq", 0)
            return value if isinstance(value, int) and not isinstance(value, bool) else 0
        except (FileNotFoundError, json.JSONDecodeError, OSError):
            return 0

    def journal(self, event: str, **fields: Any) -> dict[str, Any]:
        self.journal_seq += 1
        record = {"seq": self.journal_seq, "ts": utc_now(), "event": event, **fields}
        with self.journal_path.open("a", encoding="utf-8") as stream:
            stream.write(json.dumps(record, separators=(",", ":")) + "\n")
            stream.flush()
        self.records.append(record)
        return record

    def write_live(self) -> None:
        self.tick_seq += 1
        live = {
            "seq": self.tick_seq,
            "ts": utc_now(),
            "interval_s": self.tick_s,
            "pid": os.getpid(),
            "state": self.state,
            "state_reason": self.state_reason,
            "turn": self.current_turn,
            "brake": {"consecutive": self.brake_consecutive, "tripped_at": self.brake_tripped_at},
            "session_id": self.session_id,
            "turns_in_session": self.turns_in_session,
            "off_duty": self.off_duty,
        }
        temporary = self.state_dir / f".live.{os.getpid()}.tmp"
        temporary.write_text(json.dumps(live, separators=(",", ":")) + "\n", encoding="utf-8")
        os.replace(temporary, self.live_path)

    def notify(self, value: str) -> None:
        if not os.environ.get("NOTIFY_SOCKET"):
            return
        try:
            subprocess.run(["systemd-notify", value], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError:
            pass

    def heartbeat(self, status: str, detail: str) -> None:
        if status == self.last_heartbeat:
            return
        self.last_heartbeat = status
        self.standup.mkdir(parents=True, exist_ok=True)
        clean = detail.replace("\n", " ").replace("\r", " ").replace("|", "%7C")
        with (self.standup / f"{self.uid}.log").open("a", encoding="utf-8") as stream:
            stream.write(f"{utc_now()} | {self.uid} | {status} | {clean}\n")

    def set_state(self, state: str, reason: str = "") -> None:
        self.state = state
        self.state_reason = reason

    def tick(self) -> None:
        self.write_live()
        self.notify("WATCHDOG=1")
        # Keep a fixed cadence. Inbox reads may briefly overrun a deadline; advancing
        # from the previous deadline lets the loop catch up instead of accumulating
        # permanent drift on every poll.
        self.next_tick += self.tick_s

    def refuse(self, reason: str) -> int:
        self.journal("supervisor.refused", reason=reason)
        if reason == "deployment_denied":
            self.write_alarm("deployment_denied")
        return 78

    def deployment_allows(self, key: str) -> bool:
        path = Path(os.environ.get("AIB_DEPLOYMENT_CONFIG", "/etc/aib/deployment.json"))
        return deployment_allows(path, key, self.root)

    def configure(self) -> str | None:
        if self.config_invalid:
            return "config_invalid"
        try:
            registry = json.loads(self.registry_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return "config_invalid"
        if registry.get("schema_version") != 5:
            return "config_invalid"
        agents = registry.get("agents")
        if not isinstance(agents, dict) or self.uid not in agents or not isinstance(agents[self.uid], dict):
            return "unknown_agent"
        agent = agents[self.uid]
        self.registry = registry
        self.agent = agent
        mode = agent.get("mode", "oneshot")
        if mode != "supervised":
            return "not_supervised" if mode in ("oneshot", None) else "config_invalid"
        try:
            project_uid = agent["project"]
            project = registry["projects"][project_uid]
            provider_uid = agent.get("provider", project.get("provider"))
            provider = registry["providers"][provider_uid]
            self.project_home = project["home"]
            self.standup = Path(project["standup_dir"])
            self.project_uid = project_uid
            self.team_uid = agent["team_uid"]
            self.data_class = project.get("data_class", "customer")
            self.protected = agent.get("protected", "")
            if not all(isinstance(v, str) and v for v in (project_uid, self.project_home, str(self.standup), provider_uid)):
                raise ValueError
            self.cap_timeout = positive_int(provider.get("cap_timeout"), 900)
            self.session_max_turns = positive_int(agent.get("session_max_turns"), 200)
            self.brake_burst = positive_int(agent.get("restart_burst"), 5)
            positive_int(agent.get("restart_interval_s"), 900)
            configured_cap = positive_int(agent.get("restart_turn_backoff_cap_s"), 600)
            self.backoff_cap = interval("AIB_SUP_BACKOFF_CAP_S", float(configured_cap))
        except (KeyError, TypeError, ValueError):
            return "config_invalid"
        self.inbox = self.standup / "inbox" / f"{self.uid}.md"
        self.transcript = self.standup / "transcripts" / f"{self.uid}.log"
        self.transcript.parent.mkdir(parents=True, exist_ok=True)
        if self.data_class != "internal" and not self.deployment_allows("customer_code"):
            return "deployment_denied"
        if self.protected == "gateway" and not self.deployment_allows("comms_secrets"):
            return "deployment_denied"
        return None

    def restore(self) -> dict[str, Any] | None:
        latest_start: dict[str, Any] | None = None
        latest_start_index = -1
        latest_end_index = -1
        self.session_id = None
        self.session_cwd = None
        self.turns_in_session = 0
        self.session_new = False
        for index, record in enumerate(self.records):
            event = record.get("event")
            if event == "session.bound":
                self.session_id = record.get("sid")
                self.session_cwd = record.get("cwd")
                self.turns_in_session = 0
                self.session_new = True
            elif event == "turn.started":
                latest_start = record
                latest_start_index = index
                if record.get("sid") == self.session_id:
                    self.session_new = False
            elif event == "turn.ended":
                latest_end_index = index
                brake = record.get("brake")
                if isinstance(brake, int):
                    self.brake_consecutive = brake
                if record.get("tripped_at"):
                    self.brake_tripped_at = record["tripped_at"]
                msg_id = record.get("msg_id")
                if record.get("class") == "provider_failure" and isinstance(msg_id, str):
                    self.message_failures[msg_id] = self.message_failures.get(msg_id, 0) + 1
                elif record.get("class") == "ok":
                    if record.get("sid") == self.session_id:
                        self.turns_in_session += 1
                    if isinstance(msg_id, str):
                        self.message_failures.pop(msg_id, None)
            elif event == "duty.off":
                self.off_duty = True
            elif event == "duty.on":
                self.off_duty = False
            elif event == "brake.reset":
                self.brake_consecutive = 0
                self.brake_tripped_at = None
                self.message_failures.clear()
            elif event == "session.rotated" and record.get("reason") == "fresh":
                self.session_id = None
                self.session_cwd = None
                self.turns_in_session = 0
                self.session_new = False
            elif event == "ctl.consumed" and isinstance(record.get("req"), int):
                self.consumed.add(record["req"])
        if self.brake_consecutive >= self.brake_burst and self.brake_tripped_at is None:
            self.brake_tripped_at = utc_now()
        return latest_start if latest_start is not None and latest_start_index > latest_end_index else None

    def write_alarm(self, kind: str, **details: Any) -> None:
        tripped_at = self.brake_tripped_at if kind == "brake_tripped" else None
        if any(
            record.get("event") == "alarm.sent"
            and record.get("kind") == kind
            and (kind != "brake_tripped" or record.get("tripped_at") == tripped_at)
            for record in self.records
        ):
            return
        body = f"alarm:{kind} agent:{self.uid}"
        for key, value in details.items():
            body += f" {key}:{value}"
        destination = self.outbox_root / self.team_uid / "outbox.md"
        try:
            destination.parent.mkdir(parents=True, exist_ok=True)
            with destination.open("a", encoding="utf-8") as stream:
                stream.write(
                    f"{utc_now()} | id:alarm-{uuid.uuid4().hex} | from:{self.uid} | "
                    f"to:human:{self.team_uid} | state:PERSISTED | {body}\n"
                )
                stream.flush()
                os.fsync(stream.fileno())
            fields = {"kind": kind}
            if tripped_at is not None:
                fields["tripped_at"] = tripped_at
            self.journal("alarm.sent", **fields)
        except OSError:
            self.journal("alarm.failed", kind=kind)

    def control_event(self, event: str, request: dict[str, Any], **fields: Any) -> None:
        values = {"req": request["seq"], "verb": request["verb"], "target": self.uid, **fields}
        self.journal(event, **values)
        append_record(self.control_log, event, **values)

    def reject_control(self, request: dict[str, Any], reason: str, caller: str = "") -> None:
        self.control_event("ctl.rejected", request, caller=caller or request.get("caller", ""), reason=reason)
        self.journal("ctl.consumed", req=request["seq"])
        self.consumed.add(request["seq"])

    def accept_control(self, request: dict[str, Any]) -> None:
        self.control_event("ctl.accepted", request, result="accepted")
        self.journal("ctl.consumed", req=request["seq"])
        self.consumed.add(request["seq"])

    def done_control(self, request: dict[str, Any], result: str) -> None:
        self.control_event("ctl.done", request, result=result)

    def control_authorized(self, request: dict[str, Any]) -> bool:
        caller = request.get("caller", "")
        verb = request.get("verb", "")
        if verb in ("neustart", "feierabend", "standup"):
            if caller.startswith(("human:", "gateway:")):
                return True
            actor = request.get("actor", "")
            claimed = self.registry.get("agents", {}).get(actor, {})
            return caller.startswith("role:") and isinstance(claimed, dict) and claimed.get("lead") == "true"
        if verb in ("abschalten", "reset-brake"):
            return caller.startswith("human:")
        return False

    def clear_brake(self) -> None:
        if self.brake_consecutive or self.brake_tripped_at:
            self.journal("brake.reset", previous=self.brake_consecutive)
        self.brake_consecutive = 0
        self.brake_tripped_at = None
        self.message_failures.clear()
        self.retry_at = time.monotonic()

    def cancel_turn(self) -> None:
        if self.process is None:
            return
        deadline = time.monotonic() + self.cancel_grace
        while self.process.poll() is None and time.monotonic() < deadline:
            now = time.monotonic()
            if now >= self.next_tick:
                self.tick()
            time.sleep(0.02)
        if self.process.poll() is not None:
            self.collect_turn()
            return
        self.terminate_group(self.process)
        self.process.wait()
        assert self.attempt is not None and self.output_path is not None
        if self.output_file is not None:
            self.output_file.close()
        work = self.attempt["work"]
        attempt_id = self.attempt["attempt_id"]
        try:
            output = self.output_path.read_text(encoding="utf-8", errors="replace")
            self.output_path.unlink()
        except OSError:
            output = ""
        self.append_transcript(output)
        self.end_turn(work, attempt_id, "cancelled", 137)
        self.work = {**work, "retry": True}
        self.process = None
        self.attempt = None
        self.output_file = None
        self.output_path = None
        self.current_turn = None
        self.set_state("READY")

    def begin_control_routine(self, request: dict[str, Any], verb: str) -> None:
        self.work = {
            "id": f"control-{verb}-{request['seq']}",
            "from": request["caller"],
            "body": f"routine:{verb}; follow the supervised {verb} checklist",
            "retry": False,
            "synthetic": True,
            "control": request,
            "control_action": verb,
        }
        self.start_turn(self.work)

    def process_controls(self) -> None:
        try:
            candidates = sorted(
                self.ctl_dir.glob(f"{self.uid}.*.*"),
                key=lambda path: int(path.name.split(".", 2)[1]) if path.name.split(".", 2)[1].isdigit() else 2**63,
            )
        except OSError:
            return
        for path in candidates:
            match = re.fullmatch(rf"{re.escape(self.uid)}\.([0-9]+)\.([a-z-]+)", path.name)
            if match is None:
                continue
            sequence = int(match.group(1))
            verb = match.group(2)
            if sequence in self.consumed:
                continue
            try:
                owner = path.stat().st_uid
            except OSError:
                continue
            caller = identity_for(owner)
            request = requested_record(self.control_log, sequence)
            if (
                request is None
                or request.get("target") != self.uid
                or request.get("verb") != verb
                or request.get("caller") != caller
            ):
                request = {"seq": sequence, "verb": verb, "target": self.uid, "caller": caller}
                self.reject_control(request, "unaudited", caller)
                continue
            if verb not in ("neustart", "feierabend", "standup", "abschalten", "reset-brake"):
                self.reject_control(request, "unknown_verb", caller)
                continue
            if not self.control_authorized(request):
                self.reject_control(request, "unauthorized", caller)
                continue
            if verb == "abschalten" and self.protected in ("guardian", "gateway"):
                self.reject_control(request, "protected", caller)
                continue
            busy = verb in ("feierabend", "standup") or (
                verb in ("neustart", "abschalten") and not request.get("force", False)
            )
            if self.process is not None and busy:
                self.reject_control(request, "busy", caller)
                continue

            self.accept_control(request)
            if self.process is not None and request.get("force", False):
                self.cancel_turn()
            if verb == "reset-brake":
                self.clear_brake()
                self.set_state("READY")
                self.done_control(request, "reset")
            elif verb == "neustart":
                self.clear_brake()
                if request.get("fresh", False):
                    previous = self.session_id
                    self.add_handover_note("fresh", previous)
                    self.journal("session.rotated", reason="fresh", prev_sid=previous)
                    self.session_id = None
                    self.session_cwd = None
                    self.turns_in_session = 0
                    self.session_new = False
                self.done_control(request, "restarting")
                if request.get("hard", False):
                    self.exit_code = 75
                    self.stop_requested = True
                else:
                    self.reexec()
            elif verb == "feierabend":
                if self.process is None:
                    self.begin_control_routine(request, verb)
            elif verb == "standup":
                self.off_duty = False
                self.journal("duty.on", req=sequence)
                if self.process is None:
                    self.begin_control_routine(request, verb)
            elif verb == "abschalten":
                self.set_state("STOPPING")
                self.heartbeat("done", f"shut down by {caller}")
                self.done_control(request, "stopping")
                self.stop_requested = True
            break

    @staticmethod
    def terminate_group(process: subprocess.Popen[Any], sig: signal.Signals = signal.SIGKILL) -> None:
        try:
            os.killpg(process.pid, sig)
        except ProcessLookupError:
            pass

    def run_helper(
        self, command: list[str], *, input_text: str | None = None, capture: bool = False
    ) -> subprocess.CompletedProcess[str]:
        try:
            process = subprocess.Popen(
                command,
                stdin=subprocess.PIPE if input_text is not None else subprocess.DEVNULL,
                stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                text=True,
                env=os.environ.copy(),
                start_new_session=True,
            )
            try:
                stdout, _ = process.communicate(input_text, timeout=self.call_timeout)
            except subprocess.TimeoutExpired:
                self.terminate_group(process)
                try:
                    stdout, _ = process.communicate(timeout=1.0)
                except subprocess.TimeoutExpired:
                    if process.stdin is not None and not process.stdin.closed:
                        process.stdin.close()
                    if process.stdout is not None:
                        process.stdout.close()
                    try:
                        process.wait(timeout=1.0)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=1.0)
                    stdout = ""
                return subprocess.CompletedProcess(command, 124, stdout=stdout if capture else None, stderr=None)
            return subprocess.CompletedProcess(command, process.returncode, stdout=stdout if capture else None, stderr=None)
        except OSError:
            return subprocess.CompletedProcess(command, 124, stdout="" if capture else None, stderr=None)

    def message_command(self, *args: str, capture: bool = False) -> subprocess.CompletedProcess[str]:
        command = [str(self.run_agent), self.uid, "--", str(self.message), *args]
        return self.run_helper(command, capture=capture)

    def open_messages(self) -> list[dict[str, str]]:
        result = self.message_command("inbox", capture=True)
        if result.returncode != 0:
            return []
        messages: list[dict[str, str]] = []
        for order, line in enumerate(result.stdout.splitlines()):
            parts = line.split(" | ", 3)
            if len(parts) != 4:
                continue
            fields = {}
            for part in parts[:3]:
                key, _, value = part.partition(":")
                fields[key] = value
            messages.append({"id": fields.get("id", ""), "state": fields.get("state", ""), "from": fields.get("from", ""), "body": parts[3], "order": str(order)})
        return messages

    def choose_message(self) -> dict[str, Any] | None:
        messages = self.open_messages()
        if not messages:
            return None

        def lane(message: dict[str, str]) -> tuple[int, int]:
            if message["from"] == self.uid:
                priority = 0
            elif message["from"].startswith("human:"):
                priority = 1
            else:
                priority = 2
            return priority, int(message["order"])
        selected = min(messages, key=lane)
        retry = selected["state"] == "SEEN"
        if not retry:
            if self.message_command("seen", selected["id"]).returncode != 0:
                return None
        return {**selected, "retry": retry, "synthetic": False}

    def prompt_for(self, work: dict[str, Any]) -> str:
        if work.get("synthetic"):
            return str(work["body"])
        preamble = ""
        if work.get("retry"):
            preamble = (
                f"This session may already contain my handling of message {work['id']}. "
                "Check the previous turn in this session, then git and journal state, before acting.\n\n"
            )
        return f"{preamble}Message {work['id']} from {work['from']}:\n{work['body']}"

    def bind_session(self, rebound_from: str | None = None, rebound: bool = False) -> None:
        sid = str(uuid.uuid4())
        if rebound:
            self.journal("session.rebound", sid=sid, prev_sid=rebound_from, cwd=self.project_home)
        self.session_id = sid
        self.session_cwd = self.project_home
        self.session_new = True
        self.turns_in_session = 0
        self.journal("session.bound", agent=self.uid, sid=sid, cwd=self.project_home)

    def add_handover_note(self, reason: str, previous: str | None) -> None:
        note_id = f"handover-{uuid.uuid4().hex}"
        body = f"kind:handover; reason:{reason}; previous_session:{previous or 'none'}; establish context before continuing queued work"
        if self.message_command("send", self.uid, body, "--id", note_id).returncode != 0:
            raise OSError("cannot persist handover note")

    def rotate_with_note(self, reason: str) -> None:
        previous = self.session_id
        self.add_handover_note(reason, previous)
        self.journal("session.rotated", reason=reason, prev_sid=previous)
        self.bind_session()

    def check_cwd_binding(self) -> None:
        if self.session_id and self.session_cwd != self.project_home:
            previous = self.session_id
            self.add_handover_note("cwd_changed", previous)
            self.bind_session(rebound_from=previous, rebound=True)

    def broker_leases(self) -> int | None:
        frame = f"op=leases\nagent_uid={self.uid}\nprompt_bytes=0\n\n"
        result = self.run_helper(self.broker_client, input_text=frame, capture=True)
        if result.returncode != 0:
            return None
        fields: dict[str, str] = {}
        for line in result.stdout.splitlines():
            key, separator, value = line.partition("=")
            if not separator or not key or key in fields:
                return None
            fields[key] = value
        if set(fields) != {"supervised", "other", "end"} or fields["end"] != "ok":
            return None
        try:
            supervised = int(fields["supervised"])
            other = int(fields["other"])
        except ValueError:
            return None
        if supervised < 0 or other < 0:
            return None
        return supervised

    def handle_orphan(self, unfinished: dict[str, Any]) -> bool:
        started = time.monotonic()
        self.set_state("ORPHANED", "orphan")
        self.current_turn = None
        self.write_live()
        while not self.stop_requested:
            lease_count = self.broker_leases()
            if lease_count == 0:
                break
            now = time.monotonic()
            if now >= self.next_tick:
                self.tick()
            if now - started >= self.cap_timeout:
                self.journal("orphan.timeout", msg_id=unfinished.get("msg_id"), sid=unfinished.get("sid"))
                break
            time.sleep(min(self.orphan_poll, max(0.01, self.next_tick - now)))
        if self.stop_requested:
            return False
        self.journal(
            "turn.ended",
            msg_id=unfinished.get("msg_id"),
            sid=unfinished.get("sid"),
            attempt_id=unfinished.get("attempt_id", unfinished.get("attempt")),
            **{"class": "orphan_gone", "rc": 0, "brake": self.brake_consecutive},
        )
        self.set_state("READY")
        return True

    def start_turn(self, work: dict[str, Any]) -> None:
        if self.session_id is None:
            self.bind_session()
        assert self.session_id is not None
        session_arg = f"new:{self.session_id}" if self.session_new else self.session_id
        attempt_id = str(uuid.uuid4())
        started_at = utc_now()
        self.current_turn = {"msg_id": work["id"], "started_at": started_at, "attempt_id": attempt_id}
        self.set_state("WORKING")
        if self.last_heartbeat != "blocked":
            self.heartbeat("busy", f"supervised turn {work['id']}")
        self.journal("turn.started", msg_id=work["id"], sid=self.session_id, attempt_id=attempt_id)
        self.session_new = False
        self.write_live()
        prompt = self.prompt_for(work)
        self.output_path = self.state_dir / f".turn-{attempt_id}.out"
        self.output_file = self.output_path.open("wb")
        command = [*self.launcher, "--as", self.uid, "--supervised", "--session", session_arg, "--cwd", self.project_home, "-"]
        try:
            self.process = subprocess.Popen(
                command,
                stdin=subprocess.PIPE,
                stdout=self.output_file,
                stderr=subprocess.STDOUT,
                env=os.environ.copy(),
                start_new_session=True,
            )
            assert self.process.stdin is not None
            self.process.stdin.write(prompt.encode())
            self.process.stdin.close()
        except (OSError, ValueError) as error:
            if self.process is not None:
                self.terminate_group(self.process, signal.SIGTERM)
                try:
                    self.process.wait(timeout=min(self.call_timeout, 1.0))
                except subprocess.TimeoutExpired:
                    self.terminate_group(self.process)
                    self.process.wait()
            self.output_file.write(str(error).encode())
            self.output_file.close()
            self.process = None
            self._finish_result(69, self.output_path.read_text(encoding="utf-8", errors="replace"), work, session_arg, attempt_id)
            return
        self.attempt = {"work": work, "session_arg": session_arg, "attempt_id": attempt_id}

    def collect_turn(self) -> None:
        assert self.process is not None and self.attempt is not None and self.output_path is not None
        rc = self.process.poll()
        if rc is None:
            return
        self.output_file.close()
        output = self.output_path.read_text(encoding="utf-8", errors="replace")
        try:
            self.output_path.unlink()
        except OSError:
            pass
        work = self.attempt["work"]
        session_arg = self.attempt["session_arg"]
        attempt_id = self.attempt["attempt_id"]
        self.process = None
        self.attempt = None
        self.output_file = None
        self.output_path = None
        self._finish_result(rc, output, work, session_arg, attempt_id)

    def append_transcript(self, output: str) -> None:
        if not output:
            return
        with self.transcript.open("a", encoding="utf-8") as stream:
            stream.write(output)
            if not output.endswith("\n"):
                stream.write("\n")
        self.transcript.chmod(0o640)

    def end_turn(self, work: dict[str, Any], attempt_id: str, result_class: str, rc: int) -> None:
        self.journal(
            "turn.ended",
            msg_id=work["id"],
            sid=self.session_id,
            attempt_id=attempt_id,
            **{"class": result_class, "rc": rc, "brake": self.brake_consecutive, "tripped_at": self.brake_tripped_at},
        )

    def _finish_result(self, rc: int, output: str, work: dict[str, Any], session_arg: str, attempt_id: str) -> None:
        self.append_transcript(output)
        self.current_turn = None
        lowered = output.lower()
        if rc != 0 and session_arg.startswith("new:") and "already in use" in lowered:
            self.end_turn(work, attempt_id, "session_in_use", rc)
            self.retry_at = time.monotonic()
            return
        if rc != 0 and not session_arg.startswith("new:") and "no conversation found" in lowered:
            self.end_turn(work, attempt_id, "session_lost", rc)
            self.rotate_with_note("unknown_sid")
            self.work = None
            self.retry_at = time.monotonic()
            return

        if rc == 0 and output:
            result_class = "ok"
        elif rc in (75, 78, 69) or (rc == 0 and not output):
            result_class = "infra"
        else:
            result_class = "provider_failure"

        now = time.monotonic()
        if result_class == "ok":
            self.brake_consecutive = 0
            self.brake_tripped_at = None
            self.infra_since = None
            self.turns_in_session += 1
            self.end_turn(work, attempt_id, result_class, rc)
            control_action = work.get("control_action")
            if control_action == "feierabend":
                self.off_duty = True
                self.journal("duty.off", req=work["control"]["seq"])
                self.work = None
                self.set_state("WAITING", "off_duty")
                self.done_control(work["control"], "off_duty")
                self.retry_at = now
                return
            if control_action == "standup":
                self.off_duty = False
                self.work = None
                self.set_state("READY")
                self.done_control(work["control"], "ready")
                self.retry_at = now
                return
            if work.get("rotate_after") == "max_turns":
                previous = self.session_id
                self.journal("session.rotated", reason="max_turns", prev_sid=previous)
                self.bind_session()
                self.work = work["queued"]
            else:
                if not work.get("synthetic"):
                    self.message_command("done", work["id"])
                self.work = None
                self.set_state("READY")
                self.heartbeat("idle", "supervisor ready")
            self.retry_at = now
            return

        if result_class == "infra":
            if self.infra_since is None:
                self.infra_since = now
            self.end_turn(work, attempt_id, result_class, rc)
            reason = "capacity" if rc == 75 else "infra"
            self.set_state("WAITING", reason)
            if now - self.infra_since >= self.blocked_after:
                self.heartbeat("blocked", f"supervisor waiting on {reason}")
                self.write_alarm("infra_blocked")
            self.retry_at = now + random.uniform(self.infra_min, self.infra_max)
            return

        self.infra_since = None
        self.brake_consecutive += 1
        failures = self.message_failures.get(work["id"], 0) + 1
        self.message_failures[work["id"]] = failures
        if self.brake_consecutive >= self.brake_burst:
            self.brake_tripped_at = utc_now()
        self.end_turn(work, attempt_id, result_class, rc)
        if self.brake_tripped_at is not None:
            self.set_state("FAILED", "brake")
            self.heartbeat("blocked", "supervisor provider-failure brake tripped")
            self.write_alarm("brake_tripped", consecutive=self.brake_consecutive)
            self.retry_at = float("inf")
            return
        if failures >= 3 and not work.get("synthetic"):
            self.message_command("fail", work["id"], f"provider failure rc={rc}")
            self.work = None
        else:
            self.work = work
        delay = min(self.backoff_cap, self.backoff_base * (2 ** (self.brake_consecutive - 1)))
        self.set_state("WAITING", "infra")
        self.retry_at = now + delay

    def begin_policy_handover(self, queued: dict[str, Any]) -> None:
        synthetic = {
            "id": f"handover-max-turns-{uuid.uuid4().hex[:8]}",
            "from": self.uid,
            "body": "Prepare a routine handover summary for the next session. Record current work, repository state, and any risks.",
            "retry": False,
            "synthetic": True,
            "rotate_after": "max_turns",
            "queued": queued,
        }
        self.work = synthetic
        self.start_turn(synthetic)

    def install_signals(self) -> None:
        signal.signal(signal.SIGTERM, lambda _s, _f: setattr(self, "stop_requested", True))
        signal.signal(signal.SIGINT, lambda _s, _f: setattr(self, "stop_requested", True))
        signal.signal(signal.SIGUSR1, lambda _s, _f: setattr(self, "reexec_requested", True))

    def reexec(self) -> None:
        environment = os.environ.copy()
        environment["AIB_SUP_REEXEC"] = "1"
        environment["AIB_SUP_LOCK_FD"] = str(self.lock_fd)
        os.execve(sys.executable, [sys.executable, "-I", str(Path(__file__)), str(self.root), self.uid], environment)

    def run(self) -> int:
        refusal = self.configure()
        if refusal:
            return self.refuse(refusal)
        unfinished = self.restore()
        self.check_cwd_binding()
        reexec = os.environ.pop("AIB_SUP_REEXEC", None) == "1"
        self.journal("supervisor.started", pid=os.getpid(), reexec=reexec)
        self.install_signals()
        if self.brake_tripped_at:
            self.set_state("FAILED", "brake")
            self.heartbeat("blocked", "supervisor provider-failure brake tripped")
            self.write_alarm("brake_tripped", consecutive=self.brake_consecutive)
        elif self.off_duty:
            self.set_state("WAITING", "off_duty")
            self.heartbeat("done", "supervisor off duty")
        else:
            self.set_state("READY")
            self.heartbeat("idle", "supervisor ready")
        self.write_live()
        self.next_tick = time.monotonic() + self.tick_s
        self.notify("READY=1")
        if unfinished is not None:
            self.handle_orphan(unfinished)

        while not self.stop_requested:
            now = time.monotonic()
            if now >= self.next_tick:
                self.tick()
            self.process_controls()
            if self.stop_requested:
                break
            if self.process is not None:
                self.collect_turn()
            elif self.reexec_requested:
                self.reexec()
            elif not self.off_duty and self.brake_tripped_at is None and now >= self.retry_at and now >= self.next_poll:
                self.next_poll = now + self.poll_s
                if self.work is None:
                    self.work = self.choose_message()
                if self.work is not None:
                    if self.session_id is not None and self.turns_in_session >= self.session_max_turns:
                        self.begin_policy_handover(self.work)
                    else:
                        self.start_turn(self.work)
            time.sleep(0.02)

        if self.process is not None:
            self.terminate_group(self.process, signal.SIGTERM)
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.terminate_group(self.process)
                self.process.wait()
        self.set_state("STOPPING")
        self.current_turn = None
        self.journal("supervisor.stopping", pid=os.getpid())
        self.write_live()
        self.heartbeat("done", "supervisor stopped")
        return self.exit_code


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: aib-supervisor <agent_uid>", file=sys.stderr)
        return 64
    root = Path(sys.argv[1])
    uid = sys.argv[2]
    if re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)+", uid) is None:
        print("aib-supervisor: invalid agent uid", file=sys.stderr)
        return 64
    try:
        return Supervisor(root, uid).run()
    except (JournalCorruptError, SupervisorLockError) as error:
        print(f"aib-supervisor: {error}", file=sys.stderr)
        return 78
    except (ValueError, OSError) as error:
        print(f"aib-supervisor: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
