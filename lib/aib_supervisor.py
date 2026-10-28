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
import stat
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
from aib_control import append_record, identity_for, registry_path, requested_record
from aib_deployment import deployment_allows, load_deployment
from aib_login import login_max_turn_seconds
from task_ledger import TASK_RE, TOKEN_RE


MAX_LIVE_STATE_BYTES = 64 * 1024
MAX_TURN_OUTPUT_BYTES = 8 * 1024 * 1024
MAX_INTENT_BYTES = 64 * 1024
TASK_MESSAGE_RE = re.compile(
    r"\[task (t-[0-9a-f]{12}) run (r-[0-9a-f]{12}) requester "
    r"((?:human|gateway):[a-z0-9][a-z0-9_-]*|[a-z0-9]+(?:-[a-z0-9]+)+)\]"
)


class JournalCorruptError(ValueError):
    """The durable journal cannot be trusted without operator repair."""


class SupervisorLockError(OSError):
    """Another supervisor already owns this agent's state directory."""


class SupervisorStateError(OSError):
    """The supervisor state directory contains an unsafe filesystem object."""


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
        self.registry_path = registry_path(root)
        state_root = Path(os.environ.get("AIB_SUP_STATE_ROOT", "/var/lib/aib-sup"))
        self.state_dir = Path(os.environ.get("STATE_DIRECTORY", state_root / uid))
        try:
            self.state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
            self.state_dir_fd = os.open(
                self.state_dir,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
            )
        except OSError as error:
            raise SupervisorStateError(f"unsafe supervisor state directory {self.state_dir}") from error
        self.lock_path = self.state_dir / "supervisor.lock"
        self.lock_fd = self._acquire_lock()
        self.journal_path = self.state_dir / "journal.jsonl"
        self.live_path = self.state_dir / "live.json"
        self.records, dropped_bytes = self._load_records()
        self.journal_seq = max((r.get("seq", 0) for r in self.records), default=0)
        self.inbox_unavailable = next(
            (
                record.get("event") == "inbox.unavailable"
                for record in reversed(self.records)
                if record.get("event") in ("inbox.unavailable", "inbox.recovered")
            ),
            False,
        )
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
        self.task_cli = root / "bin/task"

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
        self.provider_uid = ""
        self.team_uid = ""
        self.data_class = "customer"
        self.protected = ""
        self.base_branch = "main"
        self.active_cwd = ""
        self.deployment: dict[str, Any] = {}
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
        self.session_loss_counts: dict[str, int] = {}
        self.persistence_failure_streak = 0
        self.persistence_episode: str | None = None
        self.off_duty = False
        self.consumed: set[int] = set()

        self.process: subprocess.Popen[bytes] | None = None
        self.output_file: Any = None
        self.output_path: Path | None = None
        self.attempt: dict[str, Any] | None = None
        self.work: dict[str, Any] | None = None
        self.retry_at = 0.0
        self.infra_since: float | None = None
        self.infra_episode: str | None = None
        self.infra_login_hint = False
        self.last_heartbeat: str | None = None
        self.stop_requested = False
        self.reexec_requested = False
        self.exit_code = 0
        self.next_tick = time.monotonic()
        self.next_poll = time.monotonic()

    @property
    def intent_dir(self) -> Path:
        return self.state_dir / ".aib" / "intents"

    def _configured_interval(self, name: str, default: float) -> float:
        try:
            return interval(name, default)
        except (TypeError, ValueError):
            self.config_invalid = True
            return default

    def _open_state_file(
        self,
        name: str,
        flags: int,
        mode: int = 0o600,
        *,
        single_link: bool = False,
    ) -> int:
        try:
            fd = os.open(
                name,
                flags | os.O_NOFOLLOW | os.O_NONBLOCK,
                mode,
                dir_fd=self.state_dir_fd,
            )
        except FileNotFoundError:
            raise
        except OSError as error:
            raise SupervisorStateError(f"refusing unsafe supervisor state file {name}") from error
        try:
            status = os.fstat(fd)
            if not stat.S_ISREG(status.st_mode):
                raise SupervisorStateError(f"refusing non-regular supervisor state file {name}")
            if single_link and status.st_nlink != 1:
                raise SupervisorStateError(f"refusing multiply-linked supervisor state file {name}")
            return fd
        except Exception:
            os.close(fd)
            raise

    def _acquire_lock(self) -> int:
        inherited = os.environ.get("AIB_SUP_LOCK_FD") if os.environ.get("AIB_SUP_REEXEC") == "1" else None
        if inherited is not None:
            try:
                lock_fd = int(inherited)
                lock_status = os.fstat(lock_fd)
                path_status = os.stat(
                    self.lock_path.name,
                    dir_fd=self.state_dir_fd,
                    follow_symlinks=False,
                )
                if (
                    lock_fd < 0
                    or not stat.S_ISREG(lock_status.st_mode)
                    or not stat.S_ISREG(path_status.st_mode)
                    or not os.path.samestat(lock_status, path_status)
                ):
                    raise ValueError
            except (OSError, ValueError) as error:
                raise SupervisorLockError("invalid inherited supervisor lock") from error
        else:
            lock_fd = self._open_state_file(
                self.lock_path.name,
                os.O_RDWR | os.O_CREAT,
                0o600,
            )
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

    def _read_state_text(self, name: str, max_bytes: int, *, errors: str = "strict") -> str:
        state_fd = self._open_state_file(name, os.O_RDONLY)
        try:
            with os.fdopen(state_fd, "rb") as stream:
                data = stream.read(max_bytes + 1)
        except OSError as error:
            raise SupervisorStateError(f"refusing unreadable supervisor state file {name}") from error
        if len(data) > max_bytes:
            raise SupervisorStateError(f"refusing oversized supervisor state file {name}")
        return data.decode("utf-8", errors=errors)

    def _load_records(self) -> tuple[list[dict[str, Any]], int]:
        records: list[dict[str, Any]] = []
        try:
            journal_fd = self._open_state_file(
                self.journal_path.name,
                os.O_RDWR,
                single_link=True,
            )
        except FileNotFoundError:
            return records, 0

        with os.fdopen(journal_fd, "r+b") as stream:
            data = stream.read()
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
                stream.truncate(len(complete))
                stream.flush()
                os.fsync(stream.fileno())
        return records, dropped_bytes

    def _old_tick_seq(self) -> int:
        try:
            value = json.loads(
                self._read_state_text(self.live_path.name, MAX_LIVE_STATE_BYTES)
            ).get("seq", 0)
            return value if isinstance(value, int) and not isinstance(value, bool) else 0
        except FileNotFoundError:
            return 0
        except SupervisorStateError:
            raise
        except (UnicodeDecodeError, json.JSONDecodeError, OSError):
            return 0

    def journal(self, event: str, **fields: Any) -> dict[str, Any]:
        self.journal_seq += 1
        record = {"seq": self.journal_seq, "ts": utc_now(), "event": event, **fields}
        journal_fd = self._open_state_file(
            self.journal_path.name,
            os.O_WRONLY | os.O_APPEND | os.O_CREAT,
            0o644,
            single_link=True,
        )
        with os.fdopen(journal_fd, "a", encoding="utf-8") as stream:
            os.fchmod(stream.fileno(), 0o644)
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
        temporary = f".live.{os.getpid()}.tmp"
        try:
            os.unlink(temporary, dir_fd=self.state_dir_fd)
        except FileNotFoundError:
            pass
        except OSError as error:
            raise SupervisorStateError(f"refusing unsafe supervisor state file {temporary}") from error
        live_fd = self._open_state_file(
            temporary,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL,
            0o644,
        )
        with os.fdopen(live_fd, "w", encoding="utf-8") as stream:
            os.fchmod(stream.fileno(), 0o644)
            stream.write(json.dumps(live, separators=(",", ":")) + "\n")
        os.replace(
            temporary,
            self.live_path.name,
            src_dir_fd=self.state_dir_fd,
            dst_dir_fd=self.state_dir_fd,
        )

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
            team_uid = agent["team_uid"]
            team = registry["teams"][team_uid]
            if "provider" in agent:
                provider_uid = agent["provider"]
            elif "provider" in team:
                provider_uid = team["provider"]
            else:
                provider_uid = project["provider"]
            provider = registry["providers"][provider_uid]
            self.project_home = project["home"]
            self.standup = Path(project["standup_dir"])
            self.project_uid = project_uid
            self.provider_uid = provider_uid
            self.team_uid = team_uid
            self.data_class = project.get("data_class", "customer")
            self.protected = agent.get("protected", "")
            self.base_branch = project.get("base_branch", "main")
            if not all(isinstance(v, str) and v for v in (project_uid, self.project_home, str(self.standup), provider_uid)):
                raise ValueError
            if not isinstance(self.base_branch, str) or not self.base_branch or self.base_branch.startswith("-"):
                raise ValueError
            self.cap_timeout = positive_int(provider.get("cap_timeout"), 900)
            deployment_path = Path(os.environ.get("AIB_DEPLOYMENT_CONFIG", "/etc/aib/deployment.json"))
            deployment = load_deployment(deployment_path, self.root)
            self.deployment = deployment or {}
            account = (
                deployment.get("accounts", {}).get(provider_uid, {}) if deployment is not None else {}
            )
            credential_mode = account.get("credential_mode", "file") if isinstance(account, dict) else "file"
            credential_source = (
                account.get("credential_source", "login") if isinstance(account, dict) else "login"
            )
            if credential_mode == "shared" or (
                credential_mode == "fd" and credential_source == "login"
            ):
                self.cap_timeout = min(self.cap_timeout, login_max_turn_seconds())
            self.session_max_turns = positive_int(agent.get("session_max_turns"), 200)
            self.brake_burst = positive_int(agent.get("restart_burst"), 5)
            positive_int(agent.get("restart_interval_s"), 900)
            configured_cap = positive_int(agent.get("restart_turn_backoff_cap_s"), 600)
            self.backoff_cap = interval("AIB_SUP_BACKOFF_CAP_S", float(configured_cap))
        except (KeyError, TypeError, ValueError):
            return "config_invalid"
        self.inbox = self.standup / "inbox" / f"{self.uid}.md"
        self.transcript = self.standup / "transcripts" / f"{self.uid}.log"
        self.active_cwd = self.project_home
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
                    self.infra_episode = None
                    self.infra_login_hint = False
                elif record.get("class") == "session_lost" and isinstance(msg_id, str):
                    self.session_loss_counts[msg_id] = self.session_loss_counts.get(msg_id, 0) + 1
                elif record.get("class") == "infra":
                    if self.infra_episode is None:
                        attempt_id = record.get("attempt_id")
                        if isinstance(attempt_id, str):
                            self.infra_episode = attempt_id
                    if record.get("login_hint") is True:
                        self.infra_login_hint = True
                elif record.get("class") == "ok":
                    self.infra_episode = None
                    self.infra_login_hint = False
                    if record.get("sid") == self.session_id:
                        self.turns_in_session += 1
                    if isinstance(msg_id, str):
                        self.message_failures.pop(msg_id, None)
                        self.session_loss_counts.pop(msg_id, None)
            elif event == "duty.off":
                self.off_duty = True
            elif event == "duty.on":
                self.off_duty = False
            elif event == "brake.reset":
                self.brake_consecutive = 0
                self.brake_tripped_at = None
                self.message_failures.clear()
                self.session_loss_counts.clear()
                self.persistence_failure_streak = 0
                self.persistence_episode = None
            elif event == "session.rotated" and record.get("reason") == "fresh":
                self.session_id = None
                self.session_cwd = None
                self.turns_in_session = 0
                self.session_new = False
            elif event == "session.persistence_failed":
                streak = record.get("streak")
                self.persistence_failure_streak = (
                    streak
                    if isinstance(streak, int) and not isinstance(streak, bool) and streak > 0
                    else self.persistence_failure_streak + 1
                )
                episode = record.get("episode")
                if isinstance(episode, str) and episode:
                    self.persistence_episode = episode
                elif self.persistence_episode is None:
                    self.persistence_episode = str(record.get("ts", "legacy"))
                msg_id = record.get("msg_id")
                if isinstance(msg_id, str):
                    self.message_failures.pop(msg_id, None)
                    self.session_loss_counts.pop(msg_id, None)
                if record.get("sid") == self.session_id:
                    self.session_id = None
                    self.session_cwd = None
                    self.turns_in_session = 0
                    self.session_new = False
            elif event == "session.persistence_restored":
                self.persistence_failure_streak = 0
                self.persistence_episode = None
            elif event == "ctl.consumed" and isinstance(record.get("req"), int):
                self.consumed.add(record["req"])
        if self.brake_consecutive >= self.brake_burst and self.brake_tripped_at is None:
            self.brake_tripped_at = utc_now()
        return latest_start if latest_start is not None and latest_start_index > latest_end_index else None

    def write_alarm(self, kind: str, **details: Any) -> None:
        tripped_at = self.brake_tripped_at if kind == "brake_tripped" else None
        episode = (
            self.infra_episode
            if kind == "infra_blocked"
            else self.persistence_episode
            if kind == "session_persistence_failed"
            else None
        )
        if any(
            record.get("event") == "alarm.sent"
            and record.get("kind") == kind
            and (kind != "brake_tripped" or record.get("tripped_at") == tripped_at)
            and (kind != "infra_blocked" or record.get("episode") == episode)
            and (kind != "session_persistence_failed" or record.get("episode") == episode)
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
            if episode is not None:
                fields["episode"] = episode
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
        if (
            self.brake_consecutive
            or self.brake_tripped_at
            or self.message_failures
            or self.session_loss_counts
            or self.persistence_failure_streak
        ):
            self.journal("brake.reset", previous=self.brake_consecutive)
        self.brake_consecutive = 0
        self.brake_tripped_at = None
        self.message_failures.clear()
        self.session_loss_counts.clear()
        self.persistence_failure_streak = 0
        self.persistence_episode = None
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
        output, refusal_reason = self._read_turn_output()
        self._discard_turn_output()
        if refusal_reason is None:
            self.append_transcript(output)
            self.end_turn(work, attempt_id, "cancelled", 137)
        else:
            self.end_turn(work, attempt_id, "provider_failure", 137, reason=refusal_reason)
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
            if not self.inbox_unavailable:
                self.journal("inbox.unavailable", rc=result.returncode)
                self.inbox_unavailable = True
            return []
        if self.inbox_unavailable:
            self.journal("inbox.recovered")
            self.inbox_unavailable = False
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
                priority = 3
                match = TASK_MESSAGE_RE.search(message["body"])
                if match is not None:
                    task = self.task_show(match.group(1))
                    lead = next(
                        (
                            agent_uid for agent_uid, agent in self.registry.get("agents", {}).items()
                            if isinstance(agent, dict)
                            and agent.get("team_uid") == self.team_uid
                            and agent.get("lead") == "true"
                        ),
                        None,
                    )
                    if (
                        task is not None
                        and task.get("run_id") == match.group(2)
                        and task.get("owner") == match.group(3)
                        and task.get("assignee") == self.uid
                        and (message["from"] == lead or str(task.get("owner", "")).startswith(("human:", "gateway:")))
                    ):
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
        task_note = ""
        if isinstance(work.get("task"), dict):
            task_note = (
                "Use task-intent to report progress, completion, failure, or a requested "
                "continuation before ending this turn.\n\n"
            )
        return f"{preamble}{task_note}Message {work['id']} from {work['from']}:\n{work['body']}"

    def task_command(self, *args: str) -> subprocess.CompletedProcess[str]:
        return self.run_helper([str(self.task_cli), *args], capture=True)

    def task_show(self, task_id: str) -> dict[str, Any] | None:
        result = self.task_command("show", "--project", self.project_uid, task_id)
        if result.returncode != 0:
            return None
        try:
            value = json.loads(result.stdout)
        except json.JSONDecodeError:
            return None
        return value if isinstance(value, dict) else None

    def task_event(
        self,
        command: str,
        task: dict[str, Any],
        causation: str,
        *,
        actor_type: str,
        actor_id: str,
        via: str | None = None,
        state: str | None = None,
        result_ref: str | None = None,
        reason: str | None = None,
        requested_type: str | None = None,
    ) -> subprocess.CompletedProcess[str]:
        argv = [
            command,
            "--project", self.project_uid,
            "--team", self.team_uid,
            "--actor-type", actor_type,
            "--actor-id", actor_id,
            "--causation-id", causation,
            "--run-id", str(task["run_id"]),
        ]
        if task.get("task_id") is not None:
            argv.extend(("--task-id", str(task["task_id"])))
        if via is not None:
            argv.extend(("--via", via))
        if command == "report":
            assert state is not None
            argv.extend(("--state", state))
            if result_ref is not None:
                argv.extend(("--result-ref", result_ref))
            if reason is not None:
                argv.extend(("--reason", reason))
        elif command == "cancel" and reason is not None:
            argv.extend(("--reason", reason))
        elif command == "reject":
            assert requested_type is not None and reason is not None
            argv.extend(("--requested-type", requested_type, "--reason", reason))
        return self.task_command(*argv)

    def write_board_snapshot(self) -> None:
        """Publish the root-owned ledger projection into the role-owned private state."""
        aib_dir = self.state_dir / ".aib"
        if not aib_dir.is_dir() or aib_dir.is_symlink():
            return
        result = self.task_command("list", "--project", self.project_uid, "--team", self.team_uid)
        if result.returncode != 0:
            raise OSError("cannot build task board snapshot")
        value = json.loads(result.stdout)
        encoded = (json.dumps(value, separators=(",", ":"), sort_keys=True) + "\n").encode()
        if len(encoded) > MAX_INTENT_BYTES:
            raise OSError("task board snapshot is too large")
        owner = aib_dir.stat()
        temporary = aib_dir / f".board.{os.getpid()}.tmp"
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            os.write(fd, encoded)
            os.fsync(fd)
            os.fchown(fd, owner.st_uid, owner.st_gid)
        finally:
            os.close(fd)
        os.replace(temporary, aib_dir / "board.json")

    def prepare_task_work(self, work: dict[str, Any]) -> None:
        if work.get("synthetic") or isinstance(work.get("task"), dict):
            return
        match = TASK_MESSAGE_RE.search(str(work.get("body", "")))
        if match is None:
            return
        task = self.task_show(match.group(1))
        if (
            task is None
            or task.get("run_id") != match.group(2)
            or task.get("owner") != match.group(3)
            or task.get("assignee") != self.uid
            or task.get("team_uid") != self.team_uid
            or task.get("state") not in {"ASSIGNED", "IN_PROGRESS"}
        ):
            raise ValueError("task message does not match the authoritative ledger")
        worktree = self.activate_task_worktree(task)
        task["worktree"] = str(worktree)
        work["task"] = task
        if task["state"] == "ASSIGNED":
            result = self.task_event(
                "start", task, f"start-{task['task_id']}",
                actor_type="service", actor_id=f"supervisor:{self.uid}",
            )
            if result.returncode != 0:
                raise OSError("cannot start assigned task")
            task["state"] = "IN_PROGRESS"
        self.check_cwd_binding()

    @staticmethod
    def _strict_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        value: dict[str, Any] = {}
        for key, item in pairs:
            if key in value:
                raise ValueError("duplicate intent key")
            value[key] = item
        return value

    def _attempt_contexts(self) -> dict[str, dict[str, Any]]:
        contexts: dict[str, dict[str, Any]] = {}
        for record in self.records:
            if record.get("event") == "turn.attempt" and isinstance(record.get("attempt_id"), str):
                contexts[record["attempt_id"]] = record
        return contexts

    def _intent_applied(self, attempt_id: str) -> bool:
        return any(
            record.get("event") == "intents.applied" and record.get("attempt_id") == attempt_id
            for record in self.records
        )

    def _intent_ledger_record(self, attempt_id: str, index: int) -> dict[str, Any] | None:
        return next(
            (
                record for record in reversed(self.records)
                if record.get("event") == "intent.ledger"
                and record.get("attempt_id") == attempt_id
                and record.get("index") == index
            ),
            None,
        )

    def _quarantine_intent(self, path: Path, reason: str) -> None:
        attempt_id = path.name.removesuffix(".jsonl")
        if any(record.get("event") == "intents.tainted" and record.get("attempt_id") == attempt_id for record in self.records):
            return
        target_dir = self.intent_dir / "tainted"
        target_dir.mkdir(mode=0o700, exist_ok=True)
        target = target_dir / path.name
        try:
            os.replace(path, target)
        except OSError:
            pass
        self.journal("intents.tainted", attempt_id=attempt_id, reason=reason)
        self.write_alarm("intents_tainted", attempt_id=attempt_id)

    def _read_intents(self, path: Path, attempt_id: str) -> list[dict[str, Any]]:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW | os.O_CLOEXEC)
        try:
            info = os.fstat(fd)
            directory = self.intent_dir.stat()
            if (
                not stat.S_ISREG(info.st_mode)
                or info.st_nlink != 1
                or info.st_uid != directory.st_uid
                or info.st_gid != directory.st_gid
                or stat.S_IMODE(info.st_mode) != 0o600
                or info.st_size > MAX_INTENT_BYTES
            ):
                raise ValueError("unsafe intent file")
            data = os.read(fd, MAX_INTENT_BYTES + 1)
        finally:
            os.close(fd)
        records: list[dict[str, Any]] = []
        for raw in data.splitlines():
            if not raw or len(raw) > 8192 or len(records) >= 10:
                raise ValueError("invalid intent bounds")
            value = json.loads(raw, object_pairs_hook=self._strict_object)
            if not isinstance(value, dict) or value.get("attempt_id") != attempt_id:
                raise ValueError("foreign attempt id")
            records.append(value)
        if not records:
            raise ValueError("empty intent file")
        return records

    def _persist_self_task_message(self, task: dict[str, Any], suffix: str, summary: str) -> None:
        ident = f"{task['task_id']}.{suffix}"
        requester = str(task["owner"])
        body = (
            f"[task {task['task_id']} run {task['run_id']} requester {requester}] "
            f"continue task; previous worker summary: {summary or 'none'}"
        )
        result = self.message_command("send", self.uid, body, "--id", ident)
        if result.returncode != 0:
            raise OSError("cannot persist task continuation")

    def _deliver_task_report(
        self,
        task: dict[str, Any],
        attempt_id: str,
        state: str,
        summary: str,
        result_ref: str | None,
    ) -> None:
        message_id = f"task-report-{task['task_id']}-{attempt_id}"
        body = f"task-report {task['task_id']} state {state}"
        if result_ref:
            body += f" result {result_ref}"
        if summary:
            body += f" summary {summary}"
        body = body.replace("\r", " ").replace("\n", " ").replace("|", "%7C")
        requester = str(task.get("owner", ""))
        if requester.startswith(("human:", "gateway:")):
            destination = self.outbox_root / self.team_uid / "outbox.md"
            destination.parent.mkdir(parents=True, exist_ok=True)
            existing = destination.read_text(encoding="utf-8") if destination.exists() else ""
            if f"id:{message_id} |" not in existing:
                with destination.open("a", encoding="utf-8") as stream:
                    stream.write(
                        f"{utc_now()} | id:{message_id} | from:{self.uid} | to:{requester} | "
                        f"state:PERSISTED | {body}\n"
                    )
                    stream.flush()
                    os.fsync(stream.fileno())
        else:
            result = self.message_command("send", requester, body, "--id", message_id)
            if result.returncode != 0:
                raise OSError("cannot deliver task report")

    def _service_block(self, task: dict[str, Any], attempt_id: str, reason: str) -> None:
        result = self.task_event(
            "report", task, f"block-{attempt_id}-{reason.replace('_', '-')}",
            actor_type="service", actor_id=f"supervisor:{self.uid}",
            state="blocked", reason=reason,
        )
        if result.returncode != 0:
            raise OSError(f"cannot block task: {reason}")
        self._deliver_task_report(task, attempt_id, "blocked", reason, None)

    def _service_fail(self, task: dict[str, Any], attempt_id: str, reason: str) -> None:
        result = self.task_event(
            "report", task, f"fail-{attempt_id}-{reason.replace('_', '-')}",
            actor_type="service", actor_id=f"supervisor:{self.uid}",
            state="failed", reason=reason,
        )
        if result.returncode != 0:
            raise OSError(f"cannot fail task: {reason}")
        self._deliver_task_report(task, attempt_id, "failed", reason, None)

    def apply_intent_file(self, path: Path, context: dict[str, Any]) -> bool:
        attempt_id = str(context["attempt_id"])
        task_id = context.get("task_id")
        task = self.task_show(str(task_id)) if isinstance(task_id, str) else None
        if task is None or task.get("assignee") != self.uid or task.get("run_id") != context.get("run_id"):
            self._quarantine_intent(path, "context_mismatch")
            return False
        try:
            intents = self._read_intents(path, attempt_id)
        except (OSError, UnicodeError, ValueError, json.JSONDecodeError):
            self._quarantine_intent(path, "invalid_intent")
            return False
        handled = False
        for index, intent in enumerate(intents, 1):
            verb = intent.get("verb")
            if verb != "delegate" and intent.get("task_id") != task["task_id"]:
                self._quarantine_intent(path, "task_mismatch")
                return False
            prior = self._intent_ledger_record(attempt_id, index)
            state = str(intent.get("state", ""))
            summary = intent.get("summary", "")
            result_ref = intent.get("result_ref")
            reason = intent.get("reason")
            if verb == "delegate":
                allowed = {"attempt_id", "verb", "run_id", "to", "title", "body", "source_msg_id"}
                if set(intent) != allowed or intent.get("run_id") != task["run_id"]:
                    self._quarantine_intent(path, "invalid_delegate")
                    return False
                result = self.task_event(
                    "reject", task, f"reject-{attempt_id}-{index}",
                    actor_type="service", actor_id=f"supervisor:{self.uid}",
                    requested_type="task.created", reason="not_lead",
                )
                if result.returncode not in {0, 77}:
                    raise OSError("cannot persist delegation rejection")
                self.journal("intent.ledger", attempt_id=attempt_id, index=index, task_id=task["task_id"], action="rejected", state="not_lead")
                handled = True
                continue
            allowed = {"attempt_id", "verb", "task_id", "summary"}
            if verb == "report":
                allowed |= {"state", "result_ref", "reason"}
            if set(intent) - allowed or not isinstance(summary, str) or len(summary.encode()) > 2048:
                self._quarantine_intent(path, "invalid_schema")
                return False
            if prior is None:
                if verb not in {"report", "continue"}:
                    self._quarantine_intent(path, "invalid_verb")
                    return False
                report_state = "progress" if verb == "continue" else state
                if report_state not in {"progress", "done", "failed", "blocked"}:
                    self._quarantine_intent(path, "invalid_state")
                    return False
                if not self.validate_result_ref(result_ref, {**task, "worktree": str(self._worktree_path())}):
                    result = self.task_event(
                        "reject", task, f"reject-ref-{attempt_id}-{index}",
                        actor_type="service", actor_id=f"supervisor:{self.uid}",
                        requested_type="task.reported", reason="invalid_result_ref",
                    )
                    if result.returncode == 75:
                        self.journal("intent.retry", attempt_id=attempt_id, index=index, reason="stream_lock")
                        return True
                    if result.returncode not in {0, 77}:
                        raise OSError("cannot persist result-ref rejection")
                    self.journal("intent.ledger", attempt_id=attempt_id, index=index, task_id=task["task_id"], action="rejected", state="invalid_result_ref")
                    handled = True
                    continue
                result = self.task_event(
                    "report", task, f"intent-{attempt_id}-{index}",
                    actor_type="agent", actor_id=self.uid, via=f"intent:{attempt_id}",
                    state=report_state, result_ref=result_ref, reason=reason,
                )
                if result.returncode == 75:
                    self.journal("intent.retry", attempt_id=attempt_id, index=index, reason="stream_lock")
                    return True
                if result.returncode != 0:
                    current = self.task_show(task["task_id"])
                    budget = task.get("budget", {}).get("max_turns", 8)
                    if verb == "continue" and current is not None and current.get("turns", 0) >= budget:
                        self._service_block(task, attempt_id, "turn_budget")
                        self.journal("intent.ledger", attempt_id=attempt_id, index=index, task_id=task["task_id"], action="blocked", state="turn_budget")
                        handled = True
                        continue
                    raise OSError("task intent ledger apply failed")
                self.journal("intent.ledger", attempt_id=attempt_id, index=index, task_id=task["task_id"], action=verb, state=report_state, summary=summary, result_ref=result_ref)
                prior = self.records[-1]
                if os.environ.get("AIB_TEST_D1B_PAUSE_AFTER_LEDGER") and os.environ.get("AIB_TEST_SEAMS") == "1" and not (self.root / ".aib-installed").exists():
                    marker = Path(os.environ["AIB_TEST_D1B_PAUSE_AFTER_LEDGER"])
                    marker.touch()
                    while marker.exists():
                        time.sleep(0.05)
            action = prior.get("action") if prior else verb
            recorded_state = str(prior.get("state", state)) if prior else state
            if action == "continue":
                fresh = self.task_show(task["task_id"]) or task
                self._persist_self_task_message(fresh, f"c{fresh.get('turns', 0)}", str(prior.get("summary", summary)))
            elif action == "report" and recorded_state != "progress":
                self._deliver_task_report(task, attempt_id, recorded_state, str(prior.get("summary", summary)), prior.get("result_ref"))
            handled = True
        self.journal("intents.applied", attempt_id=attempt_id, task_id=task["task_id"], count=len(intents))
        done_dir = self.intent_dir / "done"
        done_dir.mkdir(mode=0o700, exist_ok=True)
        try:
            os.replace(path, done_dir / path.name)
        except OSError:
            pass
        msg_id = context.get("msg_id")
        if isinstance(msg_id, str) and msg_id and not msg_id.startswith("handover-"):
            self.message_command("done", msg_id)
        return handled

    def scan_intents(self) -> None:
        if not self.intent_dir.is_dir() or self.intent_dir.is_symlink():
            return
        contexts = self._attempt_contexts()
        for path in sorted(self.intent_dir.glob("*.jsonl")):
            attempt_id = path.name.removesuffix(".jsonl")
            context = contexts.get(attempt_id)
            if context is None:
                self._quarantine_intent(path, "foreign_attempt")
            elif self._intent_applied(attempt_id):
                done_dir = self.intent_dir / "done"
                done_dir.mkdir(mode=0o700, exist_ok=True)
                try:
                    os.replace(path, done_dir / path.name)
                except OSError:
                    pass
            else:
                self.apply_intent_file(path, context)

    def scan_task_dlq(self) -> None:
        """Translate exhausted assignment delivery into the service-owned terminal event."""
        if not self.intent_dir.is_dir():
            return
        result = self.message_command("dlq", capture=True)
        if result.returncode != 0:
            return
        for line in result.stdout.splitlines():
            match = TASK_MESSAGE_RE.search(line)
            if match is None:
                continue
            task = self.task_show(match.group(1))
            if (
                task is None
                or task.get("run_id") != match.group(2)
                or task.get("owner") != match.group(3)
                or task.get("assignee") != self.uid
                or task.get("state") != "ASSIGNED"
            ):
                continue
            event = self.task_event(
                "cancel", task, f"delivery-{task['task_id']}",
                actor_type="service", actor_id=f"supervisor:{self.uid}",
                reason="delivery_failed",
            )
            if event.returncode == 0:
                self.journal("task.delivery_failed", task_id=task["task_id"])
                self._deliver_task_report(task, "delivery-failed", "cancelled", "delivery failed after five wakeup attempts", None)
                self.write_alarm("task_delivery_failed", task_id=task["task_id"])

    def handle_missing_report(self, task: dict[str, Any], attempt_id: str) -> None:
        count = sum(
            record.get("event") == "task.no_report" and record.get("task_id") == task["task_id"]
            for record in self.records
        ) + 1
        self.journal("task.no_report", task_id=task["task_id"], attempt_id=attempt_id, count=count)
        if count >= 2:
            self._service_block(task, attempt_id, "no_report")
        else:
            self._persist_self_task_message(task, "n1", "no report received")

    def _git(self, cwd: Path, *args: str, check: bool = True, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(
            ["git", "-C", str(cwd), *args],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            timeout=self.call_timeout,
        )
        if check and result.returncode != 0:
            raise OSError(result.stderr.strip() or "git command failed")
        return result

    def _commit_identity(self) -> tuple[str, str]:
        configured = self.deployment.get("commit_identity", {})
        if not isinstance(configured, dict):
            configured = {}
        template = configured.get("name_template", "{display_name} ({team})")
        email = configured.get("email", "agents@example.invalid")
        display = self.agent.get("display_name", self.uid)
        return template.format(display_name=display, team=self.team_uid), email

    def _worktree_path(self) -> Path:
        return Path(self.project_home) / ".aib" / "wt" / self.uid

    def activate_task_worktree(self, task: dict[str, Any]) -> Path:
        """Create the agent worktree and switch it to the task's closed branch."""
        task_id, team = task.get("task_id"), task.get("team_uid")
        if not isinstance(task_id, str) or TASK_RE.fullmatch(task_id) is None or team != self.team_uid:
            raise ValueError("invalid task worktree binding")
        repo = Path(self.project_home).resolve(strict=True)
        if self._git(repo, "rev-parse", "--is-inside-work-tree").stdout.strip() != "true":
            raise OSError("project home is not a git worktree")
        if self._git(repo, "check-ref-format", "--branch", self.base_branch, check=False).returncode != 0:
            raise ValueError("invalid base branch")
        self._git(repo, "config", "core.sharedRepository", "group")
        aib_dir, parent, worktree = repo / ".aib", repo / ".aib" / "wt", self._worktree_path()
        for directory in (aib_dir, parent):
            if directory.exists() and (directory.is_symlink() or not directory.is_dir()):
                raise OSError("unsafe worktree directory")
            directory.mkdir(mode=0o2770, exist_ok=True)
            directory.chmod(0o2770)
        if not worktree.exists():
            self._git(repo, "worktree", "add", "--detach", str(worktree), self.base_branch)
        elif worktree.is_symlink() or not worktree.is_dir():
            raise OSError("unsafe agent worktree")
        desired = f"aib/{team}/{task_id}"
        current = self._git(worktree, "branch", "--show-current").stdout.strip()
        if current != desired:
            if self._git(worktree, "status", "--porcelain").stdout:
                self._git(worktree, "add", "-A")
                name, email = self._commit_identity()
                commit_env = dict(os.environ)
                commit_env.update(
                    GIT_AUTHOR_NAME=name,
                    GIT_COMMITTER_NAME=name,
                    GIT_AUTHOR_EMAIL=email,
                    GIT_COMMITTER_EMAIL=email,
                )
                self._git(worktree, "commit", "-m", f"WIP before {task_id}", env=commit_env)
            exists = self._git(repo, "show-ref", "--verify", f"refs/heads/{desired}", check=False).returncode == 0
            if exists:
                self._git(worktree, "switch", desired)
            else:
                self._git(worktree, "switch", "-c", desired, self.base_branch)
        role_home = self.state_dir / ".aib"
        if os.geteuid() == 0 and role_home.is_dir() and not role_home.is_symlink():
            role_uid = role_home.stat().st_uid
            project_gid = repo.stat().st_gid
            for directory, names, files in os.walk(worktree, followlinks=False):
                os.chown(directory, role_uid, project_gid, follow_symlinks=False)
                for name in (*names, *files):
                    os.chown(Path(directory) / name, role_uid, project_gid, follow_symlinks=False)
        self.active_cwd = str(worktree)
        return worktree

    def validate_result_ref(self, value: str | None, task: dict[str, Any]) -> bool:
        if value is None:
            return True
        if not isinstance(value, str) or not value.isascii() or len(value) > 260:
            return False
        task_id, team = task.get("task_id"), task.get("team_uid", self.team_uid)
        worktree = Path(task.get("worktree", self._worktree_path()))
        if value.startswith("msg:"):
            return TOKEN_RE.fullmatch(value[4:]) is not None
        if value.startswith("git:"):
            match = re.fullmatch(r"git:(aib/[a-z0-9]+(?:-[a-z0-9]+)+/(t-[0-9a-f]{12}))@([0-9a-f]{40})", value, re.ASCII)
            if match is None or match.group(1) != f"aib/{team}/{task_id}" or not worktree.is_dir():
                return False
            return self._git(worktree, "merge-base", "--is-ancestor", match.group(3), match.group(1), check=False).returncode == 0
        if value.startswith("file:"):
            relative = value[5:]
            if not relative or relative.startswith(("/", "-")) or any(part in {"", ".", ".."} for part in relative.split("/")):
                return False
            try:
                root = worktree.resolve(strict=True)
                target = (root / relative).resolve(strict=True)
                target.relative_to(root)
                info = target.stat()
            except (OSError, ValueError):
                return False
            return stat.S_ISREG(info.st_mode) and info.st_size <= 1024 * 1024
        return False

    def bind_session(self, rebound_from: str | None = None, rebound: bool = False) -> None:
        sid = str(uuid.uuid4())
        if rebound:
            self.journal("session.rebound", sid=sid, prev_sid=rebound_from, cwd=self.active_cwd)
        self.session_id = sid
        self.session_cwd = self.active_cwd
        self.session_new = True
        self.turns_in_session = 0
        self.journal("session.bound", agent=self.uid, sid=sid, cwd=self.active_cwd)

    def add_handover_note(self, reason: str, previous: str | None) -> None:
        if any(
            message["from"] == self.uid and message["body"].startswith("kind:handover;")
            for message in self.open_messages()
        ):
            return
        note_id = f"handover-{uuid.uuid4().hex}"
        body = f"kind:handover; reason:{reason}; previous_session:{previous or 'none'}; establish context before continuing queued work"
        if self.message_command("send", self.uid, body, "--id", note_id).returncode != 0:
            raise OSError("cannot persist handover note")

    def rotate_with_note(self, reason: str) -> None:
        previous = self.session_id
        self.add_handover_note(reason, previous)
        self.journal("session.rotated", reason=reason, prev_sid=previous)
        self.bind_session()

    def begin_session_loss_handover(self, queued: dict[str, Any]) -> None:
        previous = self.session_id
        self.journal("session.rotated", reason="unknown_sid", prev_sid=previous)
        self.bind_session()
        self.work = {
            "id": f"handover-session-loss-{uuid.uuid4().hex[:8]}",
            "from": self.uid,
            "body": "Re-establish context after the provider lost the previous session before retrying the control routine.",
            "retry": False,
            "synthetic": True,
            "resume_after_handover": queued,
        }

    def check_cwd_binding(self) -> None:
        if self.session_id and self.session_cwd != self.active_cwd:
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
        local_attempt = unfinished.get("attempt_id", unfinished.get("attempt"))
        if isinstance(local_attempt, str) and TOKEN_RE.fullmatch(local_attempt):
            task = None
            if isinstance(unfinished.get("task_id"), str):
                task = {
                    "task_id": unfinished.get("task_id"),
                    "run_id": unfinished.get("run_id"),
                    "owner": unfinished.get("requester"),
                }
            orphan_work: dict[str, Any] = {"id": unfinished.get("msg_id")}
            if task is not None:
                orphan_work["task"] = task
            self._record_turn_attempt(
                orphan_work,
                local_attempt,
                f".turn-{local_attempt}.attempt",
            )
        self.journal(
            "turn.ended",
            msg_id=unfinished.get("msg_id"),
            sid=unfinished.get("sid"),
            attempt_id=unfinished.get("attempt_id", unfinished.get("attempt")),
            **{"class": "orphan_gone", "rc": 0, "brake": self.brake_consecutive},
        )
        self.set_state(
            "READY",
            "session_persistence_unavailable" if self.persistence_failure_streak else "",
        )
        return True

    def start_turn(self, work: dict[str, Any]) -> None:
        self.prepare_task_work(work)
        self.write_board_snapshot()
        if self.session_id is None:
            self.bind_session()
        assert self.session_id is not None
        session_arg = f"new:{self.session_id}" if self.session_new else self.session_id
        attempt_id = str(uuid.uuid4())
        started_at = utc_now()
        self.current_turn = {"msg_id": work["id"], "started_at": started_at, "attempt_id": attempt_id}
        if self.persistence_failure_streak:
            state_reason = "session_persistence_unavailable"
        else:
            state_reason = "infra" if self.infra_since is not None else ""
        self.set_state("WORKING", state_reason)
        if self.last_heartbeat != "blocked":
            self.heartbeat("busy", f"supervised turn {work['id']}")
        task = work.get("task") if isinstance(work.get("task"), dict) else {}
        self.journal(
            "turn.started",
            msg_id=work["id"],
            sid=self.session_id,
            attempt_id=attempt_id,
            task_id=task.get("task_id"),
            run_id=task.get("run_id"),
            requester=task.get("owner"),
        )
        self.session_new = False
        self.write_live()
        prompt = self.prompt_for(work)
        self.output_path = self.state_dir / f".turn-{attempt_id}.out"
        output_fd = self._open_state_file(
            self.output_path.name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL,
            0o600,
        )
        self.output_file = os.fdopen(output_fd, "wb")
        attempt_meta_name = f".turn-{attempt_id}.attempt"
        attempt_meta_fd = self._open_state_file(
            attempt_meta_name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL,
            0o600,
        )
        os.close(attempt_meta_fd)
        command = [*self.launcher, "--as", self.uid, "--supervised", "--session", session_arg, "--cwd", self.active_cwd, "-"]
        try:
            launch_env = os.environ.copy()
            launch_env["AIB_ATTEMPT_META_PATH"] = str(self.state_dir / attempt_meta_name)
            self.process = subprocess.Popen(
                command,
                stdin=subprocess.PIPE,
                stdout=self.output_file,
                stderr=subprocess.STDOUT,
                env=launch_env,
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
            output, refusal_reason = self._read_turn_output()
            self._discard_turn_output()
            self.output_file = None
            self.output_path = None
            self._record_turn_attempt(work, attempt_id, attempt_meta_name)
            self._finish_result(69, output, work, session_arg, attempt_id, refusal_reason)
            return
        self.attempt = {"work": work, "session_arg": session_arg, "attempt_id": attempt_id, "attempt_meta_name": attempt_meta_name}

    def _record_turn_attempt(self, work: dict[str, Any], local_attempt: str, meta_name: str) -> str:
        broker_attempt = local_attempt
        try:
            candidate = self._read_state_text(meta_name, 256).strip()
            if candidate and TOKEN_RE.fullmatch(candidate):
                broker_attempt = candidate
        except (FileNotFoundError, SupervisorStateError, UnicodeError, OSError):
            pass
        try:
            os.unlink(meta_name, dir_fd=self.state_dir_fd)
        except OSError:
            pass
        task = work.get("task") if isinstance(work.get("task"), dict) else {}
        self.journal(
            "turn.attempt",
            attempt_id=broker_attempt,
            local_attempt_id=local_attempt,
            msg_id=work.get("id"),
            task_id=task.get("task_id"),
            run_id=task.get("run_id"),
            requester=task.get("owner"),
        )
        work["broker_attempt_id"] = broker_attempt
        return broker_attempt

    def _read_turn_output(self) -> tuple[str, str | None]:
        assert self.output_path is not None
        try:
            return (
                self._read_state_text(
                    self.output_path.name,
                    MAX_TURN_OUTPUT_BYTES,
                    errors="replace",
                ),
                None,
            )
        except (FileNotFoundError, SupervisorStateError, OSError):
            return "", "unsafe_turn_output"

    def _discard_turn_output(self) -> None:
        assert self.output_path is not None
        try:
            os.unlink(self.output_path.name, dir_fd=self.state_dir_fd)
        except OSError:
            pass

    def collect_turn(self) -> None:
        assert self.process is not None and self.attempt is not None and self.output_path is not None
        rc = self.process.poll()
        if rc is None:
            return
        self.output_file.close()
        output, refusal_reason = self._read_turn_output()
        self._discard_turn_output()
        work = self.attempt["work"]
        session_arg = self.attempt["session_arg"]
        attempt_id = self.attempt["attempt_id"]
        attempt_meta_name = self.attempt["attempt_meta_name"]
        self.process = None
        self.attempt = None
        self.output_file = None
        self.output_path = None
        self._record_turn_attempt(work, attempt_id, attempt_meta_name)
        self._finish_result(rc, output, work, session_arg, attempt_id, refusal_reason)

    def append_transcript(self, output: str) -> None:
        if not output:
            return
        with self.transcript.open("a", encoding="utf-8") as stream:
            stream.write(output)
            if not output.endswith("\n"):
                stream.write("\n")
        self.transcript.chmod(0o640)

    def end_turn(
        self,
        work: dict[str, Any],
        attempt_id: str,
        result_class: str,
        rc: int,
        *,
        login_hint: bool = False,
        reason: str | None = None,
    ) -> None:
        self.journal(
            "turn.ended",
            msg_id=work["id"],
            sid=self.session_id,
            attempt_id=attempt_id,
            **{"class": result_class, "rc": rc, "brake": self.brake_consecutive, "tripped_at": self.brake_tripped_at},
            **({"login_hint": True} if login_hint else {}),
            **({"reason": reason} if reason is not None else {}),
        )

    def _finish_result(
        self,
        rc: int,
        output: str,
        work: dict[str, Any],
        session_arg: str,
        attempt_id: str,
        refusal_reason: str | None = None,
    ) -> None:
        self.append_transcript(output)
        self.current_turn = None
        lowered = output.lower()
        login_hint = rc == 78 and "hint:login" in lowered
        if refusal_reason is None and rc != 0 and session_arg.startswith("new:") and "already in use" in lowered:
            self.end_turn(work, attempt_id, "session_in_use", rc)
            self.retry_at = time.monotonic()
            return
        if refusal_reason is None and rc != 0 and not session_arg.startswith("new:") and "no conversation found" in lowered:
            losses = self.session_loss_counts.get(work["id"], 0) + 1
            self.session_loss_counts[work["id"]] = losses
            if losses >= 2:
                self.infra_since = None
                self.infra_episode = None
                self.infra_login_hint = False
                self.persistence_failure_streak += 1
                if self.persistence_episode is None:
                    self.persistence_episode = attempt_id
                self.brake_consecutive += 1
                if self.brake_consecutive >= self.brake_burst:
                    self.brake_tripped_at = utc_now()
                reason = "session_persistence_unavailable"
                self.end_turn(work, attempt_id, "provider_failure", rc, reason=reason)
                failed_sid = self.session_id
                self.journal(
                    "session.persistence_failed",
                    msg_id=work["id"],
                    sid=failed_sid,
                    reason=reason,
                    brake=self.brake_consecutive,
                    tripped_at=self.brake_tripped_at,
                    streak=self.persistence_failure_streak,
                    episode=self.persistence_episode,
                )
                self.session_loss_counts.pop(work["id"], None)
                self.session_id = None
                self.session_cwd = None
                self.turns_in_session = 0
                self.session_new = False
                self.write_alarm(
                    "session_persistence_failed",
                    consecutive=self.persistence_failure_streak,
                )
                if work.get("control"):
                    self.done_control(work["control"], reason)
                elif not work.get("synthetic"):
                    self.message_command("fail", work["id"], reason)
                self.work = None
                now = time.monotonic()
                if self.brake_tripped_at is not None:
                    self.write_alarm("brake_tripped", consecutive=self.brake_consecutive)
                    self.set_state("FAILED", "brake")
                    self.heartbeat("blocked", "supervisor provider-failure brake tripped")
                    self.retry_at = float("inf")
                else:
                    delay = min(self.backoff_cap, self.backoff_base * (2 ** (self.brake_consecutive - 1)))
                    self.set_state("WAITING", reason)
                    self.retry_at = now + delay
                return
            self.end_turn(work, attempt_id, "session_lost", rc)
            if work.get("control"):
                self.begin_session_loss_handover(work)
            else:
                self.rotate_with_note("unknown_sid")
                self.work = None
            self.retry_at = time.monotonic()
            return

        if refusal_reason is not None:
            result_class = "provider_failure"
        elif rc == 0 and output:
            result_class = "ok"
        elif rc in (75, 78, 69) or (rc == 0 and not output) or login_hint:
            result_class = "infra"
        else:
            result_class = "provider_failure"

        now = time.monotonic()
        if result_class == "ok":
            successful_resume = not session_arg.startswith("new:")
            restored_streak = 0
            if self.persistence_failure_streak and successful_resume:
                restored_streak = self.persistence_failure_streak
                self.brake_consecutive = 0
                self.brake_tripped_at = None
                self.persistence_failure_streak = 0
                self.persistence_episode = None
            elif not self.persistence_failure_streak:
                self.brake_consecutive = 0
                self.brake_tripped_at = None
            self.infra_since = None
            self.infra_episode = None
            self.infra_login_hint = False
            self.turns_in_session += 1
            self.end_turn(work, attempt_id, result_class, rc)
            if isinstance(work.get("task"), dict):
                task = work["task"]
                broker_attempt = str(work.get("broker_attempt_id", attempt_id))
                intent_path = self.intent_dir / f"{broker_attempt}.jsonl"
                handled = False
                if intent_path.exists() or intent_path.is_symlink():
                    context = {
                        "attempt_id": broker_attempt,
                        "msg_id": work.get("id"),
                        "task_id": task.get("task_id"),
                        "run_id": task.get("run_id"),
                        "requester": task.get("owner"),
                    }
                    handled = self.apply_intent_file(intent_path, context)
                if not handled:
                    current_task = self.task_show(str(task["task_id"])) or task
                    if current_task.get("state") == "IN_PROGRESS":
                        self.handle_missing_report(current_task, broker_attempt)
            if restored_streak:
                self.journal(
                    "session.persistence_restored",
                    sid=self.session_id,
                    previous=restored_streak,
                )
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
                self.set_state(
                    "READY",
                    "session_persistence_unavailable" if self.persistence_failure_streak else "",
                )
                self.done_control(work["control"], "ready")
                self.retry_at = now
                return
            if work.get("resume_after_handover"):
                self.work = work["resume_after_handover"]
                self.set_state(
                    "READY",
                    "session_persistence_unavailable" if self.persistence_failure_streak else "",
                )
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
                self.set_state(
                    "READY",
                    "session_persistence_unavailable" if self.persistence_failure_streak else "",
                )
                self.heartbeat("idle", "supervisor ready")
            self.retry_at = now
            return

        if result_class == "infra":
            if self.infra_since is None:
                self.infra_since = now
            if self.infra_episode is None:
                self.infra_episode = attempt_id
            self.infra_login_hint = self.infra_login_hint or login_hint
            self.end_turn(work, attempt_id, result_class, rc, login_hint=login_hint)
            reason = "capacity" if rc == 75 else "infra"
            self.set_state("WAITING", reason)
            if now - self.infra_since >= self.blocked_after:
                self.heartbeat("blocked", f"supervisor waiting on {reason}")
                alarm_details: dict[str, str] = {"provider": self.provider_uid}
                if self.infra_login_hint:
                    alarm_details["hint"] = "login"
                self.write_alarm("infra_blocked", **alarm_details)
            self.retry_at = now + random.uniform(self.infra_min, self.infra_max)
            return

        self.infra_since = None
        self.infra_episode = None
        self.infra_login_hint = False
        self.brake_consecutive += 1
        failures = self.message_failures.get(work["id"], 0) + 1
        self.message_failures[work["id"]] = failures
        if self.brake_consecutive >= self.brake_burst:
            self.brake_tripped_at = utc_now()
        self.end_turn(work, attempt_id, result_class, rc, reason=refusal_reason)
        if self.brake_tripped_at is not None:
            self.write_alarm("brake_tripped", consecutive=self.brake_consecutive)
            self.set_state("FAILED", "brake")
            self.heartbeat("blocked", "supervisor provider-failure brake tripped")
            self.retry_at = float("inf")
            return
        if failures >= 3 and not work.get("synthetic"):
            detail = f"provider failure rc={rc}"
            if refusal_reason is not None:
                detail += f" reason={refusal_reason}"
            self.message_command("fail", work["id"], detail)
            if isinstance(work.get("task"), dict):
                task = self.task_show(str(work["task"]["task_id"]))
                if task is not None and task.get("state") == "IN_PROGRESS":
                    self._service_fail(task, str(work.get("broker_attempt_id", attempt_id)), "turn_failed")
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
            self.write_alarm("brake_tripped", consecutive=self.brake_consecutive)
            self.set_state("FAILED", "brake")
            self.heartbeat("blocked", "supervisor provider-failure brake tripped")
        elif self.off_duty:
            self.set_state("WAITING", "off_duty")
            self.heartbeat("done", "supervisor off duty")
        else:
            self.set_state(
                "READY",
                "session_persistence_unavailable" if self.persistence_failure_streak else "",
            )
            self.heartbeat("idle", "supervisor ready")
        if self.persistence_failure_streak:
            self.write_alarm(
                "session_persistence_failed",
                consecutive=self.persistence_failure_streak,
            )
        self.write_live()
        self.next_tick = time.monotonic() + self.tick_s
        self.notify("READY=1")
        if unfinished is not None:
            self.handle_orphan(unfinished)
        self.scan_intents()
        self.scan_task_dlq()

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
                self.scan_intents()
                self.scan_task_dlq()
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
    except (JournalCorruptError, SupervisorLockError, SupervisorStateError) as error:
        print(f"aib-supervisor: {error}", file=sys.stderr)
        return 78
    except (ValueError, OSError) as error:
        print(f"aib-supervisor: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
