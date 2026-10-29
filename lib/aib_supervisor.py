#!/usr/bin/env python3
"""Single-writer supervisor loop for resumable provider turns."""

from __future__ import annotations

import errno
import fcntl
import hashlib
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
from task_intent import MAX_FILE as MAX_INTENT_BYTES, validate_intent_records
from task_ledger import LedgerError, TASK_RE, TOKEN_RE, read_body_sidecar, safe_display_text


MAX_LIVE_STATE_BYTES = 64 * 1024
MAX_TURN_OUTPUT_BYTES = 8 * 1024 * 1024
INTENT_SCAN_LIMIT = 500
DEFERRED_PENDING_LIMIT = 100
TASK_MESSAGE_RE = re.compile(
    r"^\[task (t-[0-9a-f]{12}) run (r-[0-9a-f]{12}) requester "
    r"((?:human|gateway):[a-z0-9][a-z0-9_-]*|[a-z0-9]+(?:-[a-z0-9]+)+)\]"
)
RESULT_FILE_CHECK = """\
import os
import stat
import sys

flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
fd = os.open(sys.argv[1], flags)
parts = sys.argv[2].split("/")
for component in parts[:-1]:
    child = os.open(component, flags, dir_fd=fd)
    os.close(fd)
    fd = child
info = os.stat(parts[-1], dir_fd=fd, follow_symlinks=False)
raise SystemExit(0 if stat.S_ISREG(info.st_mode) and info.st_size <= 1024 * 1024 else 1)
"""
STALE_LOCK_CLEANUP = """\
import os
import stat
import sys
import time

path, minimum_age = sys.argv[1], float(sys.argv[2])
try:
    info = os.lstat(path)
except FileNotFoundError:
    raise SystemExit(0)
if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
    raise SystemExit(1)
if time.time() - info.st_mtime <= minimum_age:
    raise SystemExit(0)
os.unlink(path)
"""


def neutralize_task_text(value: str) -> str:
    return value.replace("[task", "(task")


class JournalCorruptError(ValueError):
    """The durable journal cannot be trusted without operator repair."""


class SupervisorLockError(OSError):
    """Another supervisor already owns this agent's state directory."""


class SupervisorStateError(OSError):
    """The supervisor state directory contains an unsafe filesystem object."""


class IntentReadError(ValueError):
    """An intent candidate failed metadata or content validation."""

    def __init__(self, message: str, evidence: bytes = b"") -> None:
        super().__init__(message)
        self.evidence = evidence


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def parse_timestamp(value: Any) -> datetime | None:
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return parsed if parsed.tzinfo is not None else parsed.replace(tzinfo=timezone.utc)


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
        self.git_timeout = self._configured_interval("AIB_SUP_GIT_TIMEOUT_S", 45.0)
        self.activation_timeout = self._configured_interval("AIB_SUP_ACTIVATION_TIMEOUT_S", 60.0)
        self.git_poll_interval = 1.0
        if self.infra_max < self.infra_min:
            self.config_invalid = True

        self.launcher = shlex.split(os.environ.get("AIB_LAUNCH_AGENT", str(root / "bin/launch-agent")))
        self.broker_client = shlex.split(os.environ.get("AIB_BROKER_CLIENT", str(root / "bin/aib-broker-client")))
        self.run_agent = root / "bin/run-agent"
        self.message = root / "bin/message"
        self.task_cli = root / "bin/task"
        self.attempts_cli = root / "bin/attempts"

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
        self.role_uid = -1
        self.role_gid = -1
        self.role_groups: set[int] = set()
        self.cancel_grace = self._configured_interval("AIB_SUP_CANCEL_GRACE_S", 30.0)
        self.activation_deadline: float | None = None
        self.intent_scan_cursor = ""

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
        self.started_at = utc_now()

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
            test_seam = os.environ.get("AIB_TEST_SEAMS") == "1" and not (self.root / ".aib-installed").exists()
            role_uid_raw = os.environ.get("AIB_ROLE_UID")
            role_gid_raw = os.environ.get("AIB_ROLE_GID")
            if role_uid_raw is None or role_gid_raw is None:
                if not test_seam:
                    raise ValueError
                self.role_uid, self.role_gid = os.geteuid(), os.getegid()
            elif not role_uid_raw.isdecimal() or not role_gid_raw.isdecimal():
                raise ValueError
            else:
                self.role_uid, self.role_gid = int(role_uid_raw), int(role_gid_raw)
            raw_groups = os.environ.get("AIB_ROLE_GROUPS", "")
            if raw_groups:
                if any(not part.isdecimal() for part in raw_groups.split(",")):
                    raise ValueError
                self.role_groups = {int(part) for part in raw_groups.split(",")}
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

    def _append_outbox_line(self, line: bytes, directory: str | None = None) -> bool:
        root_fd = team_fd = file_fd = -1
        try:
            test_seam = (
                os.environ.get("AIB_TEST_SEAMS") == "1"
                and not (self.root / ".aib-installed").exists()
            )
            if test_seam:
                self.outbox_root.mkdir(mode=0o755, exist_ok=True)
            root_fd = os.open(
                self.outbox_root,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
            )
            root_info = os.fstat(root_fd)
            expected_owner = os.geteuid()
            if (
                not stat.S_ISDIR(root_info.st_mode)
                or root_info.st_uid != expected_owner
                or stat.S_IMODE(root_info.st_mode) & 0o002
            ):
                raise OSError("unsafe outbox root")
            destination = directory or self.team_uid
            expected_mode = 0o750 if destination == "_server" else 0o770
            created = False
            try:
                os.mkdir(destination, expected_mode, dir_fd=root_fd)
                created = True
            except FileExistsError:
                pass
            team_fd = os.open(
                destination,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                dir_fd=root_fd,
            )
            if created:
                os.fchmod(team_fd, expected_mode)
            team_info = os.fstat(team_fd)
            if (
                not stat.S_ISDIR(team_info.st_mode)
                or team_info.st_uid != expected_owner
                or stat.S_IMODE(team_info.st_mode) & 0o777 != expected_mode
            ):
                raise OSError("unsafe team outbox")
            file_created = False
            try:
                file_fd = os.open(
                    "outbox.md",
                    os.O_WRONLY | os.O_APPEND | os.O_NOFOLLOW
                    | os.O_NONBLOCK | os.O_CLOEXEC,
                    dir_fd=team_fd,
                )
            except FileNotFoundError:
                file_fd = os.open(
                    "outbox.md",
                    os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
                    | os.O_NONBLOCK | os.O_CLOEXEC,
                    0o660,
                    dir_fd=team_fd,
                )
                file_created = True
            if file_created:
                os.fchmod(file_fd, 0o660)
                os.fchown(file_fd, -1, team_info.st_gid)
            info = os.fstat(file_fd)
            if (
                not stat.S_ISREG(info.st_mode)
                or info.st_nlink != 1
                or stat.S_IMODE(info.st_mode) & 0o777 != 0o660
                or info.st_gid != team_info.st_gid
            ):
                raise OSError("unsafe outbox")
            written = 0
            while written < len(line):
                count = os.write(file_fd, line[written:])
                if count <= 0:
                    raise OSError("short outbox write")
                written += count
            os.fsync(file_fd)
            return True
        except (OSError, UnicodeError):
            return False
        finally:
            for fd in (file_fd, team_fd, root_fd):
                if fd >= 0:
                    os.close(fd)

    @staticmethod
    def _safe_alarm_details(details: dict[str, Any]) -> dict[str, str | int]:
        safe: dict[str, str | int] = {}
        for key, raw in details.items():
            value = str(raw)
            if re.fullmatch(r"[A-Za-z0-9._:-]+", value, re.ASCII) or (
                key == "path" and value in {".aib/intents", "project_home"}
            ):
                safe[key] = value
            else:
                safe[f"{key}_sha256"] = hashlib.sha256(value.encode("utf-8", errors="surrogatepass")).hexdigest()[:16]
                safe[f"{key}_length"] = len(value)
        return safe

    def write_alarm(self, kind: str, **details: Any) -> None:
        tripped_at = self.brake_tripped_at if kind == "brake_tripped" else None
        special_episode = (
            self.infra_episode
            if kind == "infra_blocked"
            else self.persistence_episode
            if kind == "session_persistence_failed"
            else None
        )
        safe_details = self._safe_alarm_details(details)
        episode = (
            special_episode
            or safe_details.get("episode")
            or safe_details.get("attempt_id")
            or safe_details.get("task_id")
            or safe_details.get("name_sha256")
        )
        if any(
            record.get("event") == "alarm.sent"
            and record.get("kind") == kind
            and record.get("episode") == episode
            and (kind != "brake_tripped" or record.get("tripped_at") == tripped_at)
            for record in self.records
        ):
            return
        now = datetime.now(timezone.utc)
        recent = [
            record for record in self.records
            if record.get("event") == "alarm.sent"
            and record.get("kind") == kind
            and (stamp := parse_timestamp(record.get("ts"))) is not None
            and (now - stamp).total_seconds() < 3600
        ]
        if len(recent) >= 10:
            if not any(
                record.get("event") == "alarm.suppressed"
                and record.get("kind") == kind
                and (stamp := parse_timestamp(record.get("ts"))) is not None
                and (now - stamp).total_seconds() < 3600
                for record in self.records
            ):
                self.journal("alarm.suppressed", kind=kind, limit=10, window_s=3600)
                line = (
                    f"{utc_now()} | id:alarm-{uuid.uuid4().hex} | from:{self.uid} | "
                    f"to:human:{self.team_uid} | state:PERSISTED | "
                    f"alarm:alarm_suppressed agent:{self.uid} kind:{kind}\n"
                ).encode("utf-8")
                if self._append_outbox_line(line):
                    self.journal("alarm.suppression_notified", kind=kind)
            return
        body = f"alarm:{kind} agent:{self.uid}"
        for key, value in safe_details.items():
            body += f" {key}:{value}"
        line = (
            f"{utc_now()} | id:alarm-{uuid.uuid4().hex} | from:{self.uid} | "
            f"to:human:{self.team_uid} | state:PERSISTED | {body}\n"
        ).encode("utf-8")
        if not self._append_outbox_line(line):
            self.journal("alarm.failed", kind=kind)
            self.journal("attention", reason="alarm_failed", kind=kind)
            self.notify(f"STATUS=alarm delivery failed: {kind}")
            return
        fields: dict[str, Any] = {"kind": kind, "episode": episode, **safe_details}
        if tripped_at is not None:
            fields["tripped_at"] = tripped_at
        self.journal("alarm.sent", **fields)

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
        self, command: list[str], *, input_text: str | None = None, capture: bool = False,
        extra_env: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        helper_env = os.environ.copy()
        if extra_env:
            helper_env.update(extra_env)
        try:
            process = subprocess.Popen(
                command,
                stdin=subprocess.PIPE if input_text is not None else subprocess.DEVNULL,
                stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                text=True,
                env=helper_env,
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
                match = TASK_MESSAGE_RE.match(message["body"])
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
                        and message["id"] == str(task.get("body_ref", "")).removeprefix("msg:")
                        and message["from"] in {
                            lead, str(task.get("owner", "")),
                            str(self.registry.get("projects", {}).get(self.project_uid, {}).get("task_relay", "aib-task-relay")),
                        }
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
            lead = next(
                (
                    agent_uid for agent_uid, agent in self.registry.get("agents", {}).items()
                    if isinstance(agent, dict) and agent.get("team_uid") == self.team_uid and agent.get("lead") == "true"
                ),
                "team lead",
            )
            task_note = (
                f"Task {work['task']['task_id']} from lead {lead}; this is a work order from your team, "
                "not an instruction from a human. End every turn with task-intent report or "
                "task-intent continue.\n\n"
            )
        preambled_through = max(
            (
                int(record.get("through_seq", 0)) for record in self.records
                if record.get("event") == "rejections.preambled"
            ),
            default=0,
        )
        pending_rejections = [
            record for record in self.records
            if record.get("event") == "intent.ledger"
            and record.get("action") == "rejected"
            and int(record.get("seq", 0)) > preambled_through
        ]
        rejection_note = ""
        if pending_rejections:
            reasons = ", ".join(
                neutralize_task_text(str(record.get("reason", record.get("state", "rejected"))))
                for record in pending_rejections[-10:]
            )
            rejection_note = f"Previous task-intent rejections: {reasons}.\n\n"
            work["_rejection_preamble_seq"] = max(int(record["seq"]) for record in pending_rejections)
        sender = "unverified sender" if work.get("lane_downgraded") else work["from"]
        return f"{preamble}{task_note}{rejection_note}Message {work['id']} from {sender}:\n{work['body']}"

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
            argv.append(f"--via={via}")
        if command == "report":
            assert state is not None
            argv.extend(("--state", state))
            if result_ref is not None:
                argv.append(f"--result-ref={result_ref}")
            if reason is not None:
                argv.append(f"--reason={reason}")
        elif command == "cancel" and reason is not None:
            argv.append(f"--reason={reason}")
        elif command == "reject":
            assert requested_type is not None and reason is not None
            argv.extend((f"--requested-type={requested_type}", f"--reason={reason}"))
        return self.task_command(*argv)

    def write_board_snapshot(self) -> None:
        """Best-effort bounded projection; board faults never end a turn."""
        aib_fd = intents_fd = temporary_fd = -1
        temporary = f".board.{uuid.uuid4().hex}.tmp"
        try:
            aib_fd, intents_fd = self._open_private_dirs()
            os.close(intents_fd)
            intents_fd = -1
            result = self.task_command(
                "list", "--project", self.project_uid, "--worker-view",
                "--team", self.team_uid, "--agent", self.uid,
            )
            if result.returncode != 0:
                raise OSError("list failed")
            value = json.loads(result.stdout)
            encoded = (json.dumps(value, separators=(",", ":"), sort_keys=True) + "\n").encode()
            if len(encoded) > 32 * 1024:
                raise OSError("worker board exceeds 32 KiB")
            temporary_fd = os.open(
                temporary,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                0o600,
                dir_fd=aib_fd,
            )
            os.write(temporary_fd, encoded)
            os.fsync(temporary_fd)
            expected_uid = self.role_uid if self.role_uid >= 0 else os.geteuid()
            expected_gid = self.role_gid if self.role_gid >= 0 else os.getegid()
            os.fchown(temporary_fd, expected_uid, expected_gid)
            os.close(temporary_fd)
            temporary_fd = -1
            os.replace(temporary, "board.json", src_dir_fd=aib_fd, dst_dir_fd=aib_fd)
        except (OSError, ValueError, UnicodeError, json.JSONDecodeError):
            self.journal("board.stale")
            self.journal("attention", reason="board_stale")
        finally:
            if temporary_fd >= 0:
                os.close(temporary_fd)
            if aib_fd >= 0:
                try:
                    os.unlink(temporary, dir_fd=aib_fd)
                except OSError:
                    pass
            for fd in (intents_fd, aib_fd):
                if fd >= 0:
                    os.close(fd)

    def _unmatched_preparations(self, message_id: str) -> int:
        preparing = 0
        for record in self.records:
            if record.get("msg_id") != message_id:
                continue
            if record.get("event") == "message.preparing":
                preparing += 1
            elif record.get("event") in {"message.prepared", "message.preparation_failed"} and preparing:
                preparing -= 1
        return preparing

    def prepare_task_work(self, work: dict[str, Any]) -> bool:
        if work.get("synthetic") or isinstance(work.get("task"), dict):
            return True
        body = str(work.get("body", ""))
        match = TASK_MESSAGE_RE.match(body)
        if match is None:
            if "[task" in body:
                work["body"] = neutralize_task_text(body)
                work["lane_downgraded"] = True
                self.journal("lane.downgraded", msg_id=work.get("id"), reason="task_binding")
            return True
        task = self.task_show(match.group(1))
        body_ref_id = str(task.get("body_ref", "")).removeprefix("msg:") if task else ""
        own_engine_id = bool(
            task and work.get("from") == self.uid
            and re.fullmatch(rf"{re.escape(str(task.get('task_id')))}\.(?:c\.[A-Za-z0-9.-]+|n\.a[0-9]+|r\.[A-Za-z0-9.-]+)", str(work.get("id", "")))
        )
        id_form = bool(task and (work.get("id") == body_ref_id or own_engine_id))
        stale = bool(
            task and id_form and (
                task.get("assignee") != self.uid or task.get("team_uid") != self.team_uid
                or task.get("state") not in {"ASSIGNED", "IN_PROGRESS"}
            )
        )
        if stale:
            self.message_command("done", str(work.get("id")))
            self.journal("task.stale_message", msg_id=work.get("id"), task_id=task.get("task_id"))
            self.work = None
            return False
        lead = next(
            (
                agent_uid for agent_uid, agent in self.registry.get("agents", {}).items()
                if isinstance(agent, dict) and agent.get("team_uid") == self.team_uid and agent.get("lead") == "true"
            ),
            None,
        )
        relay = str(self.registry.get("projects", {}).get(self.project_uid, {}).get("task_relay", "aib-task-relay"))
        sender_ok = bool(task and (work.get("from") in {lead, task.get("owner"), relay} or own_engine_id))
        matches = bool(
            task and task.get("run_id") == match.group(2) and task.get("owner") == match.group(3)
            and task.get("assignee") == self.uid and task.get("team_uid") == self.team_uid
            and task.get("state") in {"ASSIGNED", "IN_PROGRESS"} and id_form and sender_ok
        )
        if not matches:
            work["body"] = neutralize_task_text(body)
            work["lane_downgraded"] = True
            self.journal("lane.downgraded", msg_id=work.get("id"), reason="task_binding")
            return True
        assert task is not None
        try:
            body_root = Path(os.environ.get("AIB_TASK_ROOT", "/var/lib/aib/tasks")) / self.project_uid / "bodies"
            sidecar = read_body_sidecar(body_root, str(task["task_id"]))
        except LedgerError:
            self.journal("attention", reason="unsafe_body_sidecar", task_id=task.get("task_id"))
            self.message_command("fail", str(work.get("id")), "unsafe_body_sidecar")
            self.work = None
            return False
        work["body"] = f"[task {task['task_id']} run {task['run_id']} requester {task['owner']}]\n{sidecar}"
        if self._unmatched_preparations(str(work.get("id", ""))) >= 2:
            self._message_engine_error(work, OSError("worktree_unavailable"))
            return False
        self.journal(
            "message.preparing", msg_id=work.get("id"), task_id=task.get("task_id")
        )
        try:
            worktree = self.activate_task_worktree(task)
        except (OSError, ValueError) as error:
            self.journal(
                "message.preparation_failed", msg_id=work.get("id"),
                task_id=task.get("task_id"),
            )
            self.journal("attention", reason="worktree_unavailable", task_id=task.get("task_id"))
            raise OSError("worktree_unavailable") from error
        self.journal(
            "message.prepared", msg_id=work.get("id"), task_id=task.get("task_id")
        )
        task["worktree"] = str(worktree)
        work["task"] = task
        if task["state"] == "ASSIGNED":
            result = self.task_event(
                "start", task, f"start-{task['task_id']}-a{task.get('assignments', 1)}",
                actor_type="service", actor_id=f"supervisor:{self.uid}",
            )
            if result.returncode != 0:
                raise OSError("cannot start assigned task")
            task["state"] = "IN_PROGRESS"
        self.check_cwd_binding()
        return True

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

    def _open_private_dirs(self) -> tuple[int, int]:
        """Open role-owned .aib/intents from the verified supervisor state fd."""
        flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
        aib_fd = intents_fd = -1
        try:
            aib_fd = os.open(".aib", flags, dir_fd=self.state_dir_fd)
            intents_fd = os.open("intents", flags, dir_fd=aib_fd)
            expected_uid = self.role_uid if self.role_uid >= 0 else os.geteuid()
            expected_gid = self.role_gid if self.role_gid >= 0 else os.getegid()
            for fd in (aib_fd, intents_fd):
                info = os.fstat(fd)
                if (
                    not stat.S_ISDIR(info.st_mode)
                    or info.st_uid != expected_uid
                    or info.st_gid != expected_gid
                    or stat.S_IMODE(info.st_mode) != 0o700
                ):
                    raise OSError("role_mismatch")
            return aib_fd, intents_fd
        except Exception:
            for fd in (intents_fd, aib_fd):
                if fd >= 0:
                    os.close(fd)
            raise

    def _unlink_intent(self, name: str) -> None:
        aib_fd = intents_fd = -1
        try:
            aib_fd, intents_fd = self._open_private_dirs()
            os.unlink(name, dir_fd=intents_fd)
        except OSError:
            pass
        finally:
            for fd in (intents_fd, aib_fd):
                if fd >= 0:
                    os.close(fd)

    @staticmethod
    def _intent_identity(name: str, *, invalid_name: bool = False) -> dict[str, Any]:
        attempt_id = name.removesuffix(".jsonl")
        if not invalid_name and TOKEN_RE.fullmatch(attempt_id):
            return {"attempt_id": attempt_id}
        return {
            "name_sha256": hashlib.sha256(name.encode("utf-8", errors="surrogatepass")).hexdigest()[:16],
            "name_length": len(name),
        }

    @staticmethod
    def _taint_key(identity: dict[str, Any]) -> tuple[Any, ...]:
        if isinstance(identity.get("attempt_id"), str):
            return ("attempt_id", identity["attempt_id"])
        return ("name", identity.get("name_sha256"), identity.get("name_length"))

    def _tainted_intent_index(self) -> set[tuple[Any, ...]]:
        return {
            self._taint_key(record)
            for record in self.records
            if record.get("event") == "intents.tainted"
        }

    def _taint_seen(
        self, identity: dict[str, Any], tainted: set[tuple[Any, ...]] | None = None
    ) -> bool:
        index = self._tainted_intent_index() if tainted is None else tainted
        return self._taint_key(identity) in index

    def _quarantine_intent(
        self, path: Path, reason: str, alarm: str = "security", *,
        evidence: bytes | None = None,
        tainted: set[tuple[Any, ...]] | None = None,
    ) -> None:
        invalid_name = reason == "invalid_name" or not path.name.endswith(".jsonl") or TOKEN_RE.fullmatch(path.name[:-6]) is None
        identity = self._intent_identity(path.name, invalid_name=invalid_name)
        if self._taint_seen(identity, tainted):
            self._unlink_intent(path.name)
            if not any(
                record.get("event") == "intents.tainted_replay"
                and all(record.get(key) == value for key, value in identity.items())
                for record in self.records
            ):
                self.journal("intents.tainted_replay", **identity)
            return
        aib_fd = intents_fd = quarantine_fd = source_fd = target_fd = -1
        data = evidence if evidence is not None else b""
        stored = False
        try:
            aib_fd, intents_fd = self._open_private_dirs()
            if evidence is None:
                source_fd = os.open(
                    path.name,
                    os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW | os.O_CLOEXEC,
                    dir_fd=intents_fd,
                )
                info = os.fstat(source_fd)
                if stat.S_ISREG(info.st_mode) and info.st_nlink == 1:
                    data = os.read(source_fd, MAX_INTENT_BYTES + 1)
            quarantine_fd = os.open(
                ".aib-quarantine",
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                dir_fd=self.state_dir_fd,
            )
            quarantine_info = os.fstat(quarantine_fd)
            if (
                not stat.S_ISDIR(quarantine_info.st_mode)
                or quarantine_info.st_uid != os.geteuid()
                or quarantine_info.st_gid != os.getegid()
                or stat.S_IMODE(quarantine_info.st_mode) != 0o700
            ):
                raise OSError("unsafe quarantine directory")
            entries = os.listdir(quarantine_fd)
            total = 0
            for name in entries:
                try:
                    item = os.stat(name, dir_fd=quarantine_fd, follow_symlinks=False)
                except OSError:
                    continue
                if stat.S_ISREG(item.st_mode):
                    total += item.st_size
            if len(entries) < 100 and total + len(data) <= 10 * 1024 * 1024:
                target_stem = str(identity.get("attempt_id") or identity["name_sha256"])
                target_name = f"{target_stem}-{uuid.uuid4().hex}.jsonl"
                target_fd = os.open(
                    target_name,
                    os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                    0o600,
                    dir_fd=quarantine_fd,
                )
                os.write(target_fd, data)
                os.fsync(target_fd)
                stored = True
        except OSError:
            pass
        finally:
            for fd in (target_fd, source_fd, quarantine_fd):
                if fd >= 0:
                    os.close(fd)
            if intents_fd >= 0:
                try:
                    os.unlink(path.name, dir_fd=intents_fd)
                except OSError:
                    pass
            for fd in (intents_fd, aib_fd):
                if fd >= 0:
                    os.close(fd)
        self.journal("intents.tainted", reason=reason, **identity)
        if tainted is not None:
            tainted.add(self._taint_key(identity))
        if not stored:
            self.journal(
                "attention", reason="quarantine_capacity", size=len(data),
                sha256=hashlib.sha256(data).hexdigest(), **identity,
            )
        if alarm == "security":
            self.write_alarm("intents_tainted", **identity)
        elif alarm == "engine":
            self.write_alarm("intent_apply_exhausted", **identity)
        else:
            self.journal("attention", reason=reason, **identity)

    def _intent_retry(
        self, path: Path, attempt_id: str, reason: str, *,
        tainted: set[tuple[Any, ...]] | None = None,
    ) -> bool:
        count = 1 + sum(
            record.get("event") == "intent.retry" and record.get("attempt_id") == attempt_id
            for record in self.records
        )
        self.journal("intent.retry", attempt_id=attempt_id, n=count, reason=reason)
        if count >= 5:
            self._quarantine_intent(path, "apply_exhausted", alarm="engine", tainted=tainted)
            return False
        return False

    def _intent_retry_pending(self, attempt_id: str) -> bool:
        if not any(
            record.get("event") == "intent.retry"
            and record.get("attempt_id") == attempt_id
            for record in self.records
        ):
            return False
        return not any(
            record.get("attempt_id") == attempt_id
            and record.get("event") in {"intents.applied", "intents.tainted"}
            for record in self.records
        )

    def _intent_snapshot(self, attempt_id: str) -> tuple[bool, str]:
        if TOKEN_RE.fullmatch(attempt_id) is None:
            return False, ""
        name = f"{attempt_id}.jsonl"
        aib_fd = intents_fd = -1
        try:
            aib_fd, intents_fd = self._open_private_dirs()
            try:
                os.stat(name, dir_fd=intents_fd, follow_symlinks=False)
            except FileNotFoundError:
                return False, ""
            try:
                _data, digest = self._read_intent_bytes(self.intent_dir / name, attempt_id)
            except (IntentReadError, OSError, UnicodeError):
                return True, ""
            return True, digest
        except OSError:
            return False, ""
        finally:
            for item in (intents_fd, aib_fd):
                if item >= 0:
                    os.close(item)

    def _closed_intent(self, attempt_id: str) -> dict[str, Any] | None:
        return next(
            (
                record for record in reversed(self.records)
                if record.get("event") == "intents.closed" and record.get("attempt_id") == attempt_id
            ),
            None,
        )

    def _close_intent_attempt(self, attempt_id: str, present: bool, digest: str) -> None:
        if self._closed_intent(attempt_id) is None:
            self.journal("intents.closed", attempt_id=attempt_id, present=present, sha256=digest)

    def _close_unclosed_attempts(self) -> None:
        for attempt_id in self._attempt_contexts():
            if self._closed_intent(attempt_id) is None:
                present, digest = self._intent_snapshot(attempt_id)
                self._close_intent_attempt(attempt_id, present, digest)

    def _journal_fs_unsafe(self, path: str, reason: str) -> None:
        last = next(
            (
                record for record in reversed(self.records)
                if record.get("event") in {"fs.unsafe", "fs.safe"} and record.get("path") == path
            ),
            None,
        )
        if last is not None and last.get("event") == "fs.unsafe" and last.get("reason") == reason:
            return
        self.journal("fs.unsafe", path=path, reason=reason)
        self.write_alarm("fs_unsafe", path=path, episode=str(self.journal_seq))

    def _journal_fs_safe(self, path: str) -> None:
        last = next(
            (
                record for record in reversed(self.records)
                if record.get("event") in {"fs.unsafe", "fs.safe"} and record.get("path") == path
            ),
            None,
        )
        if last is not None and last.get("event") == "fs.unsafe":
            self.journal("fs.safe", path=path)

    def _latest_rejection_reason(self, task_id: str) -> str:
        result = self.task_command("list", "--project", self.project_uid, "--all")
        if result.returncode == 0:
            try:
                value = json.loads(result.stdout)
                for row in reversed(value.get("rejections", [])):
                    if isinstance(row, dict) and row.get("task_id") == task_id and isinstance(row.get("reason"), str):
                        return row["reason"]
            except (AttributeError, ValueError, json.JSONDecodeError):
                pass
        return "rejected"

    def _read_intent_bytes(self, path: Path, attempt_id: str) -> tuple[bytes, str]:
        aib_fd = intents_fd = fd = -1
        try:
            aib_fd, intents_fd = self._open_private_dirs()
            fd = os.open(
                path.name,
                os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW | os.O_CLOEXEC,
                dir_fd=intents_fd,
            )
            info = os.fstat(fd)
            directory = os.fstat(intents_fd)
            if (
                not stat.S_ISREG(info.st_mode)
                or info.st_nlink != 1
                or info.st_uid != directory.st_uid
                or info.st_gid != directory.st_gid
                or stat.S_IMODE(info.st_mode) != 0o600
                or info.st_size > MAX_INTENT_BYTES
            ):
                evidence = b""
                if stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_size <= MAX_INTENT_BYTES:
                    evidence = os.read(fd, MAX_INTENT_BYTES + 1)
                raise IntentReadError("unsafe intent file", evidence)
            data = os.read(fd, MAX_INTENT_BYTES + 1)
        finally:
            for item in (fd, intents_fd, aib_fd):
                if item >= 0:
                    os.close(item)
        return data, hashlib.sha256(data).hexdigest()

    def _parse_intents(self, data: bytes, attempt_id: str) -> list[dict[str, Any]]:
        records: list[dict[str, Any]] = []
        for raw in data.splitlines():
            if not raw or len(raw) > 8192 or len(records) >= 10:
                raise ValueError("invalid intent bounds")
            try:
                value = json.loads(raw, object_pairs_hook=self._strict_object)
            except RecursionError as error:
                raise ValueError("deep intent JSON") from error
            if not isinstance(value, dict) or value.get("attempt_id") != attempt_id:
                raise ValueError("foreign attempt id")
            records.append(value)
        if not records:
            raise ValueError("empty intent file")
        return records

    def _read_intents(self, path: Path, attempt_id: str) -> list[dict[str, Any]]:
        data, _digest = self._read_intent_bytes(path, attempt_id)
        return self._parse_intents(data, attempt_id)

    def _apply_pending_intent(
        self, attempt_id: str, context: dict[str, Any], *, close_attempt: bool = False,
        tainted: set[tuple[Any, ...]] | None = None,
    ) -> bool:
        """Discover and apply one intent file through the verified intents dirfd."""
        if TOKEN_RE.fullmatch(attempt_id) is None:
            return False
        name = f"{attempt_id}.jsonl"
        aib_fd = intents_fd = -1
        try:
            aib_fd, intents_fd = self._open_private_dirs()
            try:
                os.stat(name, dir_fd=intents_fd, follow_symlinks=False)
            except FileNotFoundError:
                if close_attempt:
                    self._close_intent_attempt(attempt_id, False, "")
                return False
        finally:
            for fd in (intents_fd, aib_fd):
                if fd >= 0:
                    os.close(fd)
        return self.apply_intent_file(
            self.intent_dir / name, context, close_attempt=close_attempt, tainted=tainted
        )

    def _persist_self_task_message(self, task: dict[str, Any], ident: str, summary: str) -> bool:
        requester = str(task["owner"])
        if not isinstance(summary, str) or not safe_display_text(summary):
            self.journal("attention", reason="unsafe_self_message", message_id=ident)
            return False
        summary = neutralize_task_text(summary)
        body = (
            f"[task {task['task_id']} run {task['run_id']} requester {requester}] "
            f"continue task; previous worker summary: {summary or 'none'}"
        )
        result = self.message_command("send", self.uid, body, "--id", ident)
        if result.returncode != 0:
            self.journal("attention", reason="self_message_failed", message_id=ident)
            return False
        return True

    def _deliver_task_report(
        self,
        task: dict[str, Any],
        attempt_id: str,
        state: str,
        summary: str,
        result_ref: str | None,
        *,
        record_pending: bool = True,
    ) -> bool:
        message_id = f"task-report-{task['task_id']}-{attempt_id}"
        if any(
            record.get("event") == "report.delivered" and record.get("message_id") == message_id
            for record in self.records
        ):
            return True
        if not isinstance(summary, str) or not safe_display_text(summary):
            self.journal("attention", reason="unsafe_report_text", message_id=message_id)
            return False
        summary = neutralize_task_text(summary)
        body = f"task-report {task['task_id']} state {state}"
        if result_ref:
            body += f" result {result_ref}"
        if summary:
            body += f" summary {summary}"
        body = body.replace("\r", " ").replace("\n", " ").replace("|", "%7C")
        requester = str(task.get("owner", ""))
        if record_pending and not any(
            record.get("event") == "report.pending" and record.get("message_id") == message_id
            for record in self.records
        ):
            self.journal(
                "report.pending",
                message_id=message_id,
                task_id=task["task_id"],
                run_id=task.get("run_id"),
                requester=requester,
                attempt_id=attempt_id,
                state=state,
                summary=summary,
                result_ref=result_ref,
            )
        if requester.startswith(("human:", "gateway:")):
            line = (
                f"{utc_now()} | id:{message_id} | from:{self.uid} | to:{requester} | "
                f"state:PERSISTED | {body}\n"
            ).encode("utf-8")
            if not self._append_outbox_line(line):
                self._record_report_failure(
                    message_id, "outbox_unsafe", task_id=str(task["task_id"])
                )
                return False
        else:
            result = self.message_command("send", requester, body, "--id", message_id)
            if result.returncode != 0:
                self._record_report_failure(
                    message_id, "report_delivery_failed", task_id=str(task["task_id"])
                )
                return False
        self.journal("report.delivered", message_id=message_id, task_id=task["task_id"])
        return True

    def _latest_report_retry(self, message_id: str) -> dict[str, Any] | None:
        return next(
            (
                record for record in reversed(self.records)
                if record.get("event") == "report.retry"
                and record.get("message_id") == message_id
            ),
            None,
        )

    def _record_report_failure(self, message_id: str, reason: str, *, task_id: str) -> None:
        previous = self._latest_report_retry(message_id)
        count = int(previous.get("n", 0)) + 1 if previous is not None else 1
        if previous is None or previous.get("reason") != reason:
            self.journal("attention", reason=reason, message_id=message_id)
        if count >= 10:
            if not any(
                record.get("event") == "report.undeliverable"
                and record.get("message_id") == message_id
                for record in self.records
            ):
                self.journal(
                    "report.undeliverable", message_id=message_id,
                    task_id=task_id, n=count, reason=reason,
                )
                line = (
                    f"{utc_now()} | id:alarm-{uuid.uuid4().hex} | from:{self.uid} | "
                    "to:human:ops | state:PERSISTED | "
                    f"alarm:task_delivery_failed agent:{self.uid} "
                    f"message_id:{message_id} task_id:{task_id}\n"
                ).encode("utf-8")
                if self._append_outbox_line(line, directory="_server"):
                    self.journal(
                        "alarm.sent", kind="task_delivery_failed",
                        episode=message_id, message_id=message_id, task_id=task_id,
                    )
                else:
                    self.journal("alarm.failed", kind="task_delivery_failed")
                    self.journal(
                        "attention", reason="alarm_failed",
                        kind="task_delivery_failed", message_id=message_id,
                    )
                    self.notify("STATUS=alarm delivery failed: task_delivery_failed")
            return
        delay = min(300.0, self.poll_s * (2 ** (count - 1)))
        retry_at = datetime.fromtimestamp(
            time.time() + delay, timezone.utc
        ).isoformat(timespec="milliseconds").replace("+00:00", "Z")
        self.journal(
            "report.retry", message_id=message_id, task_id=task_id,
            n=count, reason=reason, retry_at=retry_at,
        )

    def _report_waiting_for_task(self, task_id: str) -> bool:
        delivered = {
            record.get("message_id") for record in self.records
            if record.get("event") in {"report.delivered", "report.undeliverable"}
        }
        return any(
            record.get("event") == "report.pending"
            and record.get("task_id") == task_id
            and record.get("message_id") not in delivered
            for record in self.records
        )

    def _retry_pending_reports(self) -> None:
        delivered = {
            record.get("message_id") for record in self.records
            if record.get("event") in {"report.delivered", "report.undeliverable"}
        }
        pending: dict[str, dict[str, Any]] = {}
        for record in self.records:
            message_id = record.get("message_id")
            if record.get("event") == "report.pending" and isinstance(message_id, str):
                pending[message_id] = record
        for message_id, record in pending.items():
            if message_id in delivered:
                continue
            retry = self._latest_report_retry(message_id)
            if retry is not None:
                retry_at = parse_timestamp(retry.get("retry_at"))
                if retry_at is not None and retry_at > datetime.now(timezone.utc):
                    continue
            values = (
                record.get("task_id"), record.get("run_id"), record.get("requester"),
                record.get("attempt_id"), record.get("state"), record.get("summary"),
            )
            if not all(isinstance(value, str) for value in values):
                continue
            self._deliver_task_report(
                {"task_id": values[0], "run_id": values[1], "owner": values[2]},
                values[3], values[4], values[5],
                record.get("result_ref") if isinstance(record.get("result_ref"), str) else None,
                record_pending=False,
            )

    def _service_block(
        self, task: dict[str, Any], attempt_id: str, reason: str, causation: str | None = None
    ) -> bool:
        result = self.task_event(
            "report", task, causation or f"block-{attempt_id}-{reason.replace('_', '-')}",
            actor_type="service", actor_id=f"supervisor:{self.uid}",
            state="blocked", reason=reason,
        )
        if result.returncode == 77:
            self.journal("service.terminal", task_id=task["task_id"], action="block", reason=reason)
            return True
        if result.returncode != 0:
            self.journal("service.retry", task_id=task["task_id"], action="block", reason=reason, rc=result.returncode)
            self.journal("attention", reason="service_apply_failed", task_id=task["task_id"])
            return False
        self._deliver_task_report(task, attempt_id, "blocked", reason, None)
        return True

    def _service_fail(self, task: dict[str, Any], attempt_id: str, reason: str) -> bool:
        result = self.task_event(
            "report", task, f"fail-{attempt_id}-{reason.replace('_', '-')}",
            actor_type="service", actor_id=f"supervisor:{self.uid}",
            state="failed", reason=reason,
        )
        if result.returncode == 77:
            self.journal("service.terminal", task_id=task["task_id"], action="fail", reason=reason)
            return True
        if result.returncode != 0:
            self.journal("service.retry", task_id=task["task_id"], action="fail", reason=reason, rc=result.returncode)
            self.journal("attention", reason="service_apply_failed", task_id=task["task_id"])
            return False
        self._deliver_task_report(task, attempt_id, "failed", reason, None)
        return True

    def apply_intent_file(
        self, path: Path, context: dict[str, Any], *, close_attempt: bool = False,
        tainted: set[tuple[Any, ...]] | None = None,
    ) -> bool:
        attempt_id = str(context["attempt_id"])
        try:
            data, digest = self._read_intent_bytes(path, attempt_id)
        except FileNotFoundError:
            if close_attempt:
                self._close_intent_attempt(attempt_id, False, "")
            return False
        except IntentReadError as error:
            if close_attempt:
                self._close_intent_attempt(attempt_id, True, "")
            self._quarantine_intent(path, "invalid_intent", evidence=error.evidence, tainted=tainted)
            return False
        except (OSError, UnicodeError):
            if close_attempt:
                self._close_intent_attempt(attempt_id, True, "")
            self._quarantine_intent(path, "invalid_intent", evidence=b"", tainted=tainted)
            return False
        if close_attempt:
            self._close_intent_attempt(attempt_id, True, digest)
        closed = self._closed_intent(attempt_id)
        identity = self._intent_identity(path.name)
        if self._taint_seen(identity, tainted):
            self._quarantine_intent(path, "tainted_replay", evidence=data, tainted=tainted)
            return False
        if closed is not None and (
            closed.get("present") is not True
            or not isinstance(closed.get("sha256"), str)
            or not closed.get("sha256")
            or closed.get("sha256") != digest
        ):
            self._quarantine_intent(path, "stale_attempt", evidence=data, tainted=tainted)
            return False
        if self._intent_applied(attempt_id):
            self._unlink_intent(path.name)
            return False
        try:
            intents = self._parse_intents(data, attempt_id)
        except (UnicodeError, ValueError, TypeError, RecursionError, json.JSONDecodeError):
            self._quarantine_intent(path, "invalid_intent", evidence=data, tainted=tainted)
            return False
        task_id = context.get("task_id")
        task = self.task_show(str(task_id)) if isinstance(task_id, str) else None
        if task is None:
            return self._intent_retry(path, attempt_id, "task_lookup", tainted=tainted)
        if task.get("run_id") != context.get("run_id"):
            self._quarantine_intent(path, "context_mismatch", evidence=data, tainted=tainted)
            return False
        try:
            validate_intent_records(intents, attempt_id, str(task["task_id"]))
        except (UnicodeError, ValueError, TypeError, RecursionError, json.JSONDecodeError):
            self._quarantine_intent(path, "invalid_intent", evidence=data, tainted=tainted)
            return False
        handled = False
        rejections: list[str] = []
        continuation: tuple[str, str] | None = None
        final_reports: list[tuple[str, str, str | None]] = []
        for index, intent in enumerate(intents, 1):
            verb = intent.get("verb")
            if verb != "delegate" and intent.get("task_id") != task["task_id"]:
                self._quarantine_intent(path, "task_mismatch", evidence=data, tainted=tainted)
                return False
            prior = self._intent_ledger_record(attempt_id, index)
            state = str(intent.get("state", ""))
            summary = intent.get("summary", "")
            result_ref = intent.get("result_ref")
            reason = intent.get("reason")
            if verb == "delegate":
                if prior is not None:
                    if prior.get("action") == "rejected":
                        rejections.append(str(prior.get("reason", prior.get("state", "not_lead"))))
                    continue
                allowed = {"attempt_id", "verb", "run_id", "to", "title", "body", "source_msg_id"}
                if set(intent) != allowed or intent.get("run_id") != task["run_id"]:
                    self._quarantine_intent(path, "invalid_delegate", evidence=data, tainted=tainted)
                    return False
                result = self.task_event(
                    "reject", task, f"reject-{attempt_id}-{index}",
                    actor_type="service", actor_id=f"supervisor:{self.uid}",
                    requested_type="task.created", reason="not_lead",
                )
                if result.returncode == 75:
                    return self._intent_retry(path, attempt_id, "stream_lock", tainted=tainted)
                if result.returncode not in {0, 77}:
                    return self._intent_retry(path, attempt_id, f"delegate_reject_rc_{result.returncode}", tainted=tainted)
                if os.environ.get("AIB_TEST_PAUSE_AFTER_LEDGER") and os.environ.get("AIB_TEST_SEAMS") == "1" and not (self.root / ".aib-installed").exists():
                    marker = Path(os.environ["AIB_TEST_PAUSE_AFTER_LEDGER"])
                    marker.touch()
                    while marker.exists():
                        time.sleep(0.05)
                self.journal(
                    "intent.ledger", attempt_id=attempt_id, index=index,
                    task_id=task["task_id"], action="rejected", reason="not_lead",
                )
                rejections.append("not_lead")
                continue
            allowed = {"attempt_id", "verb", "task_id", "summary"}
            if verb == "report":
                allowed |= {"state", "result_ref", "reason"}
            if set(intent) - allowed or not isinstance(summary, str) or len(summary.encode()) > 2048:
                self._quarantine_intent(path, "invalid_schema", evidence=data, tainted=tainted)
                return False
            if prior is None:
                if verb not in {"report", "continue"}:
                    self._quarantine_intent(path, "invalid_verb", evidence=data, tainted=tainted)
                    return False
                report_state = "progress" if verb == "continue" else state
                if report_state not in {"progress", "done", "failed", "blocked"}:
                    self._quarantine_intent(path, "invalid_state", evidence=data, tainted=tainted)
                    return False
                if not self.validate_result_ref(result_ref, {**task, "worktree": str(self._worktree_path())}):
                    result = self.task_event(
                        "reject", task, f"reject-ref-{attempt_id}-{index}",
                        actor_type="service", actor_id=f"supervisor:{self.uid}",
                        requested_type="task.reported", reason="invalid_result_ref",
                    )
                    if result.returncode == 75:
                        return self._intent_retry(path, attempt_id, "stream_lock", tainted=tainted)
                    if result.returncode not in {0, 77}:
                        return self._intent_retry(path, attempt_id, f"reject_ref_rc_{result.returncode}", tainted=tainted)
                    self.journal("intent.ledger", attempt_id=attempt_id, index=index, task_id=task["task_id"], action="rejected", reason="invalid_result_ref")
                    rejections.append("invalid_result_ref")
                    continue
                result = self.task_event(
                    "report", task, f"intent-{attempt_id}-{index}",
                    actor_type="agent", actor_id=self.uid, via=f"intent:{attempt_id}",
                    state=report_state, result_ref=result_ref, reason=reason,
                )
                if result.returncode == 75:
                    return self._intent_retry(path, attempt_id, "stream_lock", tainted=tainted)
                if result.returncode != 0:
                    current = self.task_show(task["task_id"])
                    budget = task.get("budget", {}).get("max_turns", 8)
                    if verb == "continue" and current is not None and current.get("turns", 0) >= budget:
                        if not self._service_block(task, attempt_id, "turn_budget"):
                            return self._intent_retry(path, attempt_id, "service_block", tainted=tainted)
                        self.journal("intent.ledger", attempt_id=attempt_id, index=index, task_id=task["task_id"], action="blocked", state="turn_budget")
                        handled = True
                        continue
                    if result.returncode in {76, 77, 64}:
                        rejection_reason = (
                            "concurrent_update" if result.returncode == 76
                            else "invalid_argument" if result.returncode == 64
                            else self._latest_rejection_reason(str(task["task_id"]))
                        )
                        self.journal(
                            "intent.ledger", attempt_id=attempt_id, index=index,
                            task_id=task["task_id"], action="rejected", reason=rejection_reason,
                        )
                        if result.returncode == 64:
                            self.journal("attention", reason="invalid_argument", attempt_id=attempt_id)
                        rejections.append(rejection_reason)
                        continue
                    return self._intent_retry(path, attempt_id, f"apply_rc_{result.returncode}", tainted=tainted)
                message_id = (
                    f"{task['task_id']}.c.{attempt_id}.{index}"
                    if verb == "continue" else f"task-report-{task['task_id']}-{attempt_id}"
                )
                if os.environ.get("AIB_TEST_PAUSE_AFTER_LEDGER") and os.environ.get("AIB_TEST_SEAMS") == "1" and not (self.root / ".aib-installed").exists():
                    marker = Path(os.environ["AIB_TEST_PAUSE_AFTER_LEDGER"])
                    marker.touch()
                    while marker.exists():
                        time.sleep(0.05)
                self.journal(
                    "intent.ledger", attempt_id=attempt_id, index=index, task_id=task["task_id"],
                    action=verb, state=report_state, summary=summary, result_ref=result_ref,
                    message_id=message_id,
                )
                prior = self.records[-1]
            action = prior.get("action") if prior else verb
            recorded_state = str(
                prior.get("reason", prior.get("state", state))
            ) if prior else state
            if action == "continue":
                continuation = (
                    str(prior.get("message_id", f"{task['task_id']}.c.{attempt_id}.{index}")),
                    str(prior.get("summary", summary)),
                )
                handled = True
            elif action == "report" and recorded_state != "progress":
                final_reports.append((recorded_state, str(prior.get("summary", summary)), prior.get("result_ref")))
                handled = True
            elif action == "report":
                handled = True
            elif action == "rejected":
                rejections.append(recorded_state)
        fresh = self.task_show(task["task_id"]) or task
        synthetic_ids: list[str] = []
        if final_reports:
            state, report_summary, report_ref = final_reports[-1]
            self._deliver_task_report(fresh, attempt_id, state, report_summary, report_ref)
        if fresh.get("state") == "IN_PROGRESS":
            if handled and rejections:
                receipt_id = f"{task['task_id']}.r.{attempt_id}"
                if self._persist_self_task_message(fresh, receipt_id, "rejected: " + ", ".join(rejections)):
                    synthetic_ids.append(receipt_id)
            elif continuation is not None:
                continuation_id, continuation_summary = continuation
                if self._persist_self_task_message(fresh, continuation_id, continuation_summary):
                    synthetic_ids.append(continuation_id)
        self.journal(
            "intents.applied", attempt_id=attempt_id, task_id=task["task_id"], count=len(intents),
            message_ids=synthetic_ids,
        )
        self._unlink_intent(path.name)
        msg_id = context.get("msg_id")
        if isinstance(msg_id, str) and msg_id and not msg_id.startswith("handover-"):
            self.message_command("done", msg_id)
        return handled

    def _recheck_missing_report_after_retry(
        self, attempt_id: str, context: dict[str, Any], handled: bool
    ) -> None:
        task_id = context.get("task_id")
        if handled or not isinstance(task_id, str):
            return
        task = self.task_show(task_id)
        if (
            task is not None
            and task.get("state") == "IN_PROGRESS"
            and not self._report_waiting_for_task(task_id)
        ):
            self.handle_missing_report(task, attempt_id)

    def scan_intents(self) -> None:
        self._retry_pending_reports()
        self._retry_deferred_orphans()
        tainted = self._tainted_intent_index()
        aib_fd = intents_fd = -1
        try:
            aib_fd, intents_fd = self._open_private_dirs()
            entries: list[tuple[str, os.stat_result]] = []
            names = sorted(os.listdir(intents_fd))
            if len(names) > INTENT_SCAN_LIMIT:
                start = next(
                    (index for index, name in enumerate(names) if name > self.intent_scan_cursor),
                    0,
                )
                names = (names[start:] + names[:start])[:INTENT_SCAN_LIMIT]
                self.intent_scan_cursor = names[-1]
            else:
                self.intent_scan_cursor = ""
            for name in names:
                try:
                    entries.append((name, os.stat(name, dir_fd=intents_fd, follow_symlinks=False)))
                except OSError:
                    continue
            self._journal_fs_safe(".aib/intents")
        except OSError as error:
            self._journal_fs_unsafe(".aib/intents", str(error))
            return
        finally:
            for fd in (intents_fd, aib_fd):
                if fd >= 0:
                    os.close(fd)
        contexts = self._attempt_contexts()
        deferred = self._deferred_intent_names()
        for name, info in entries:
            if not stat.S_ISREG(info.st_mode):
                identity = self._intent_identity(
                    name,
                    invalid_name=not name.endswith(".jsonl") or TOKEN_RE.fullmatch(name[:-6]) is None,
                )
                seen = any(
                    record.get("event") == "intents.tainted"
                    and record.get("reason") == "non_regular"
                    and record.get("inode") == info.st_ino
                    and all(record.get(key) == value for key, value in identity.items())
                    for record in self.records
                )
                if not seen:
                    self.journal("intents.tainted", reason="non_regular", inode=info.st_ino, **identity)
                    self.write_alarm("intents_tainted", **identity)
                aib_fd = intents_fd = -1
                try:
                    aib_fd, intents_fd = self._open_private_dirs()
                    if stat.S_ISDIR(info.st_mode):
                        os.rmdir(name, dir_fd=intents_fd)
                    else:
                        os.unlink(name, dir_fd=intents_fd)
                except OSError:
                    pass
                finally:
                    for fd in (intents_fd, aib_fd):
                        if fd >= 0:
                            os.close(fd)
                continue
            if not name.endswith(".jsonl") or TOKEN_RE.fullmatch(name[:-6]) is None:
                self._quarantine_intent(self.intent_dir / name, "invalid_name", tainted=tainted)
                continue
            path = self.intent_dir / name
            attempt_id = name.removesuffix(".jsonl")
            if attempt_id in deferred:
                continue
            context = contexts.get(attempt_id)
            if context is None:
                self._quarantine_intent(path, "foreign_attempt", tainted=tainted)
            elif not isinstance(context.get("task_id"), str):
                self._quarantine_intent(path, "intent_without_task", alarm="attention", tainted=tainted)
            else:
                retry_was_pending = self._intent_retry_pending(attempt_id)
                handled = False
                try:
                    handled = self._apply_pending_intent(attempt_id, context, tainted=tainted)
                except Exception as error:
                    self._intent_retry(path, attempt_id, type(error).__name__, tainted=tainted)
                if retry_was_pending and not self._intent_retry_pending(attempt_id):
                    self._recheck_missing_report_after_retry(attempt_id, context, handled)

    def scan_task_dlq(self) -> None:
        """Translate exhausted assignment delivery into the service-owned terminal event."""
        aib_fd = intents_fd = -1
        try:
            aib_fd, intents_fd = self._open_private_dirs()
        except OSError:
            return
        finally:
            for fd in (intents_fd, aib_fd):
                if fd >= 0:
                    os.close(fd)
        result = self.message_command("dlq", capture=True)
        if result.returncode != 0:
            return
        for line in result.stdout.splitlines():
            id_match = re.match(r"^id:([A-Za-z0-9._-]+) ", line)
            if id_match is None:
                continue
            message_id = id_match.group(1)
            if any(
                record.get("event") == "task.dlq_processed"
                and record.get("message_id") == message_id
                for record in self.records
            ):
                continue
            body = line.split(" | ", 4)[-1]
            match = TASK_MESSAGE_RE.match(body)
            if match is None:
                self.journal("task.dlq_processed", message_id=message_id, outcome="not_task")
                continue
            task = self.task_show(match.group(1))
            sender_match = re.search(r"(?:^| \| )from:([^ |]+)", line)
            sender = sender_match.group(1) if sender_match is not None else ""
            lead = next(
                (
                    agent_uid for agent_uid, agent in self.registry.get("agents", {}).items()
                    if isinstance(agent, dict)
                    and agent.get("team_uid") == self.team_uid
                    and agent.get("lead") == "true"
                ),
                None,
            )
            relay = str(
                self.registry.get("projects", {}).get(self.project_uid, {}).get(
                    "task_relay", "aib-task-relay"
                )
            )
            if task is not None and (
                message_id != str(task.get("body_ref", "")).removeprefix("msg:")
                or sender not in {lead, task.get("owner"), relay}
            ):
                self.journal("task.dlq_processed", message_id=message_id, outcome="unbound")
                continue
            if (
                task is None
                or task.get("run_id") != match.group(2)
                or task.get("owner") != match.group(3)
                or task.get("assignee") != self.uid
                or task.get("state") != "ASSIGNED"
            ):
                self.journal("task.dlq_processed", message_id=message_id, outcome="stale")
                continue
            event = self.task_event(
                "cancel", task, f"delivery-{task['task_id']}",
                actor_type="service", actor_id=f"supervisor:{self.uid}",
                reason="delivery_failed",
            )
            if event.returncode == 0:
                self.journal("task.delivery_failed", task_id=task["task_id"], message_id=message_id)
                self._deliver_task_report(task, "delivery-failed", "cancelled", "delivery attempts exhausted", None)
                self.write_alarm("task_delivery_failed", task_id=task["task_id"])
                outcome = "cancelled"
            else:
                outcome = f"task_rc_{event.returncode}"
            self.journal("task.dlq_processed", message_id=message_id, outcome=outcome)

    def handle_missing_report(self, task: dict[str, Any], attempt_id: str) -> None:
        assignment = int(task.get("assignments", 1))
        count = sum(
            record.get("event") == "task.no_report"
            and record.get("task_id") == task["task_id"]
            and record.get("assignment") == assignment
            for record in self.records
        ) + 1
        if count >= 2:
            self._service_block(
                task, attempt_id, "no_report",
                causation=f"noreport-{task['task_id']}-a{assignment}",
            )
        else:
            nudge_id = f"{task['task_id']}.n.a{assignment}"
            rejected = [
                str(record.get("reason", record.get("state"))) for record in self.records
                if record.get("event") == "intent.ledger"
                and record.get("attempt_id") == attempt_id
                and record.get("action") == "rejected"
            ]
            detail = "no report received"
            if rejected:
                detail += "; rejected: " + ", ".join(rejected)
            self._persist_self_task_message(task, nudge_id, detail)
        self.journal(
            "task.no_report", task_id=task["task_id"], attempt_id=attempt_id,
            assignment=assignment, count=count,
        )

    def sweep_missing_reports(self) -> None:
        result = self.task_command("list", "--project", self.project_uid, "--team", self.team_uid, "--all")
        if result.returncode != 0:
            return
        try:
            tasks = json.loads(result.stdout).get("tasks", [])
        except (AttributeError, ValueError, json.JSONDecodeError):
            return
        messages = self.open_messages()
        for task in tasks:
            if (
                not isinstance(task, dict) or task.get("assignee") != self.uid
                or task.get("state") != "IN_PROGRESS"
            ):
                continue
            task_id = str(task.get("task_id", ""))
            if self._report_waiting_for_task(task_id):
                continue
            if any(
                message.get("id", "").startswith(f"{task_id}.")
                or TASK_MESSAGE_RE.match(str(message.get("body", ""))) is not None
                and TASK_MESSAGE_RE.match(str(message.get("body", ""))).group(1) == task_id
                for message in messages
            ):
                continue
            assignment = int(task.get("assignments", 1))
            prior = [
                record for record in self.records
                if record.get("event") == "task.no_report"
                and record.get("task_id") == task_id
                and record.get("assignment") == assignment
            ]
            attempt_id = str(prior[-1].get("attempt_id", f"startup-{task_id}")) if prior else f"startup-{task_id}"
            self.handle_missing_report(task, attempt_id)

    def _open_project_home(self) -> tuple[Path, int]:
        """Verify the absolute project-home chain without following child-controlled links."""
        repo = Path(self.project_home)
        if not repo.is_absolute() or any(part in {"", ".", ".."} for part in repo.parts[1:]):
            raise OSError("unsafe project home")
        flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
        fd = os.open("/", flags)
        try:
            for component in repo.parts[1:]:
                child = os.open(component, flags, dir_fd=fd)
                os.close(fd)
                fd = child
            info = os.fstat(fd)
            test_seam = os.environ.get("AIB_TEST_SEAMS") == "1" and not (self.root / ".aib-installed").exists()
            if not test_seam and (
                info.st_uid != 0 or stat.S_IMODE(info.st_mode) != 0o2770
            ):
                raise OSError("unsafe project home ownership or mode")
            return repo, info.st_gid
        except OSError as error:
            self.journal("fs.unsafe", path="project_home", reason=str(error))
            raise
        finally:
            os.close(fd)

    def _write_git_config(self, repo: Path) -> Path:
        test_seam = os.environ.get("AIB_TEST_SEAMS") == "1" and not (self.root / ".aib-installed").exists()
        if test_seam:
            config_root = self.state_dir / ".git-config"
            config_root.mkdir(mode=0o700, exist_ok=True)
        else:
            config_root = Path("/run/aib/git")
        root_fd = os.open(config_root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
        try:
            root_info = os.fstat(root_fd)
            if not test_seam and (root_info.st_uid != 0 or stat.S_IMODE(root_info.st_mode) != 0o755):
                raise OSError("unsafe git config directory")
            name = f"{self.uid}.gitconfig"
            temporary = f".{name}.{uuid.uuid4().hex}.tmp"
            fd = os.open(
                temporary,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                0o644,
                dir_fd=root_fd,
            )
            try:
                safe_paths = [repo, self._worktree_path()]
                body = "".join(f"[safe]\n\tdirectory = {path}\n" for path in safe_paths).encode("utf-8")
                os.write(fd, body)
                os.fsync(fd)
                os.fchmod(fd, 0o644)
                if os.geteuid() == 0:
                    os.fchown(fd, 0, 0)
            finally:
                os.close(fd)
            os.replace(temporary, name, src_dir_fd=root_fd, dst_dir_fd=root_fd)
            return config_root / name
        finally:
            os.close(root_fd)

    def _run_as_role(
        self,
        repo: Path,
        project_gid: int,
        argv: list[str],
        *,
        check: bool = True,
        env: dict[str, str] | None = None,
        timeout: float | None = None,
    ) -> subprocess.CompletedProcess[str]:
        test_seam = os.environ.get("AIB_TEST_SEAMS") == "1" and not (self.root / ".aib-installed").exists()
        config = self._write_git_config(repo)
        inner_env = [
            "PATH=/usr/bin:/bin", "HOME=/nonexistent", "LANG=C",
            "GIT_CONFIG_NOSYSTEM=1", "GIT_ATTR_NOSYSTEM=1", "GIT_TERMINAL_PROMPT=0",
            f"GIT_CONFIG_GLOBAL={config}",
        ]
        if env:
            for key in ("GIT_AUTHOR_NAME", "GIT_COMMITTER_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_EMAIL"):
                if key in env:
                    inner_env.append(f"{key}={env[key]}")
        confine = os.environ.get("AIB_CONFINE_BIN", "")
        if test_seam and not confine:
            command = ["/usr/bin/env", "-i", *inner_env, "/bin/sh", "-c", 'umask 002; exec "$@"', "sh", *argv]
            process_env = None
        else:
            if not confine or not Path(confine).is_file():
                raise OSError("worktree_unavailable")
            if project_gid not in self.role_groups:
                raise OSError("worktree_unavailable")
            command = [
                confine, "--uid", str(self.role_uid), "--gid", str(self.role_gid),
                "--groups", str(project_gid), "/usr/bin/env", "-i", *inner_env,
                "/bin/sh", "-c", 'umask 002; exec "$@"', "sh", *argv,
            ]
            process_env = {
                "PATH": "/usr/bin:/bin",
                "LL_RO": "/",
                "LL_RW": f"/tmp:/var/tmp:/dev:{repo}",
                "AIB_ROLE_UIDS": str(self.role_uid),
                "AIB_ROLE_GROUPS": str(project_gid),
            }
        limit = self.call_timeout if timeout is None else timeout
        process = subprocess.Popen(
            command,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=process_env,
            start_new_session=True,
        )

        def communicate_until(stop_at: float) -> tuple[str, str]:
            while True:
                remaining = stop_at - time.monotonic()
                if remaining <= 0:
                    raise subprocess.TimeoutExpired(argv, limit)
                self.notify("WATCHDOG=1")
                try:
                    return process.communicate(
                        timeout=min(self.git_poll_interval, remaining)
                    )
                except subprocess.TimeoutExpired:
                    continue

        deadline = time.monotonic() + limit
        try:
            stdout, stderr = communicate_until(deadline)
        except subprocess.TimeoutExpired:
            self.terminate_group(process, signal.SIGTERM)
            terminate_deadline = time.monotonic() + 1.0
            try:
                stdout, stderr = communicate_until(terminate_deadline)
            except subprocess.TimeoutExpired:
                self.terminate_group(process, signal.SIGKILL)
                kill_deadline = time.monotonic() + 1.0
                try:
                    stdout, stderr = communicate_until(kill_deadline)
                except subprocess.TimeoutExpired as drain_error:
                    stdout = drain_error.output if isinstance(drain_error.output, str) else ""
                    stderr = drain_error.stderr if isinstance(drain_error.stderr, str) else ""
                    for stream in (process.stdout, process.stderr):
                        if stream is not None and not stream.closed:
                            stream.close()
                    if process.poll() is None:
                        self.notify("WATCHDOG=1")
                        try:
                            process.wait(timeout=max(0.01, kill_deadline - time.monotonic()))
                        except subprocess.TimeoutExpired:
                            pass
            raise subprocess.TimeoutExpired(argv, limit, output=stdout, stderr=stderr)
        result = subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
        if check and result.returncode != 0:
            raise OSError(result.stderr.strip() or "git command failed")
        return result

    def _git_as_role(
        self, cwd: Path, *args: str, check: bool = True, env: dict[str, str] | None = None
    ) -> subprocess.CompletedProcess[str]:
        repo, project_gid = self._open_project_home()
        lexical_cwd = Path(os.path.normpath(str(cwd)))
        try:
            lexical_cwd.relative_to(repo)
        except ValueError as error:
            raise OSError("worktree_unavailable") from error
        hardening = [
            "-c", "core.hooksPath=/dev/null",
            "-c", "core.fsmonitor=false",
            "-c", "core.untrackedCache=false",
            "-c", "core.pager=cat",
            "-c", "commit.gpgSign=false",
            "-c", "credential.helper=",
            "-c", "protocol.allow=never",
            "-c", "gc.auto=0",
            "-c", "maintenance.auto=false",
            "--no-replace-objects",
        ]
        git_argv = ["git", *hardening, "-C", str(lexical_cwd), *args]
        timeout = self.git_timeout
        if self.activation_deadline is not None:
            timeout = min(timeout, self.activation_deadline - time.monotonic())
            if timeout <= 0:
                raise OSError("worktree_unavailable")
        try:
            return self._run_as_role(
                repo, project_gid, git_argv, check=check, env=env, timeout=timeout
            )
        except subprocess.TimeoutExpired as error:
            raise OSError("worktree_unavailable") from error

    def _validate_file_ref_as_role(self, worktree: Path, relative: str) -> bool:
        repo, project_gid = self._open_project_home()
        if Path(os.path.normpath(str(worktree))) != self._worktree_path():
            return False
        result = self._run_as_role(
            repo,
            project_gid,
            ["/usr/bin/python3", "-I", "-c", RESULT_FILE_CHECK, str(worktree), relative],
            check=False,
        )
        return result.returncode == 0

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

    def _remove_stale_index_lock(self, cwd: Path) -> None:
        repo, project_gid = self._open_project_home()
        try:
            if cwd.resolve(strict=True) != self._worktree_path().resolve(strict=True):
                return
        except OSError:
            return
        result = self._git_as_role(cwd, "rev-parse", "--git-path", "index.lock", check=False)
        if result.returncode != 0 or not result.stdout.strip():
            return
        candidate = Path(result.stdout.strip())
        if not candidate.is_absolute():
            candidate = Path(os.path.normpath(str(cwd / candidate)))
        git_dir_result = self._git_as_role(cwd, "rev-parse", "--absolute-git-dir", check=False)
        common_dir_result = self._git_as_role(repo, "rev-parse", "--git-common-dir", check=False)
        if git_dir_result.returncode != 0 or common_dir_result.returncode != 0:
            return
        git_dir = Path(git_dir_result.stdout.strip())
        common_dir = Path(common_dir_result.stdout.strip())
        if not common_dir.is_absolute():
            common_dir = repo / common_dir
        try:
            resolved_candidate = candidate.resolve(strict=False)
            resolved_git_dir = git_dir.resolve(strict=True)
            resolved_common_dir = common_dir.resolve(strict=True)
            resolved_git_dir.relative_to(resolved_common_dir / "worktrees")
            if resolved_candidate != resolved_git_dir / "index.lock":
                return
        except (OSError, ValueError):
            return
        timeout = self.git_timeout
        if self.activation_deadline is not None:
            timeout = min(timeout, self.activation_deadline - time.monotonic())
        if timeout <= 0:
            raise OSError("worktree_unavailable")
        try:
            self._run_as_role(
                repo, project_gid,
                [
                    "/usr/bin/python3", "-I", "-c", STALE_LOCK_CLEANUP,
                    str(resolved_candidate), str(self.activation_timeout),
                ],
                check=False, timeout=timeout,
            )
        except subprocess.TimeoutExpired as error:
            raise OSError("worktree_unavailable") from error

    def activate_task_worktree(self, task: dict[str, Any]) -> Path:
        previous_deadline = self.activation_deadline
        self.activation_deadline = time.monotonic() + self.activation_timeout
        try:
            return self._activate_task_worktree(task)
        finally:
            self.activation_deadline = previous_deadline

    def _activate_task_worktree(self, task: dict[str, Any]) -> Path:
        """Create the agent worktree and switch it to the task's closed branch."""
        task_id, team = task.get("task_id"), task.get("team_uid")
        if not isinstance(task_id, str) or TASK_RE.fullmatch(task_id) is None or team != self.team_uid:
            raise ValueError("invalid task worktree binding")
        repo, _project_gid = self._open_project_home()
        if self._git_as_role(repo, "rev-parse", "--is-inside-work-tree").stdout.strip() != "true":
            raise OSError("project home is not a git worktree")
        if self._git_as_role(repo, "check-ref-format", "--branch", self.base_branch, check=False).returncode != 0:
            raise ValueError("invalid base branch")
        shared = self._git_as_role(repo, "config", "--get", "core.sharedRepository", check=False)
        if shared.returncode != 0 or shared.stdout.strip() != "group":
            self.journal("attention", reason="shared_repository_unprovisioned")
        parent, worktree = repo / ".aib" / "wt", self._worktree_path()
        test_seam = os.environ.get("AIB_TEST_SEAMS") == "1" and not (self.root / ".aib-installed").exists()
        if test_seam:
            parent.mkdir(mode=0o2770, parents=True, exist_ok=True)
            parent.chmod(0o2770)
        registered = {
            os.path.normpath(line.removeprefix("worktree "))
            for line in self._git_as_role(repo, "worktree", "list", "--porcelain").stdout.splitlines()
            if line.startswith("worktree ")
        }
        if os.path.normpath(str(worktree)) not in registered:
            self._git_as_role(repo, "worktree", "add", "--detach", str(worktree), self.base_branch)
        self._remove_stale_index_lock(worktree)
        desired = f"aib/{team}/{task_id}"
        current = self._git_as_role(worktree, "branch", "--show-current").stdout.strip()
        if current != desired:
            if self._git_as_role(worktree, "status", "--porcelain").stdout:
                self._git_as_role(worktree, "add", "-A", "--", ".", ":(exclude).aib")
                name, email = self._commit_identity()
                commit_env = dict(os.environ)
                commit_env.update(
                    GIT_AUTHOR_NAME=name,
                    GIT_COMMITTER_NAME=name,
                    GIT_AUTHOR_EMAIL=email,
                    GIT_COMMITTER_EMAIL=email,
                )
                self._git_as_role(worktree, "commit", "--no-verify", "--no-gpg-sign", "-m", f"WIP before {task_id}", env=commit_env)
            exists = self._git_as_role(repo, "show-ref", "--verify", f"refs/heads/{desired}", check=False).returncode == 0
            if exists:
                self._git_as_role(worktree, "switch", desired)
            else:
                self._git_as_role(worktree, "switch", "-c", desired, self.base_branch)
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
            if match is None or match.group(1) != f"aib/{team}/{task_id}":
                return False
            on_task = self._git_as_role(worktree, "merge-base", "--is-ancestor", match.group(3), match.group(1), check=False).returncode == 0
            on_base = self._git_as_role(worktree, "merge-base", "--is-ancestor", match.group(3), self.base_branch, check=False).returncode == 0
            return on_task and not on_base
        if value.startswith("file:"):
            relative = value[5:]
            if not relative or relative.startswith(("/", "-")) or any(part in {"", ".", ".."} for part in relative.split("/")):
                return False
            try:
                return self._validate_file_ref_as_role(worktree, relative)
            except OSError:
                return False
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
            self._adopt_orphan_attempt(unfinished, local_attempt)
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

    def _pending_orphan_intents(self) -> list[str]:
        aib_fd = intents_fd = -1
        try:
            aib_fd, intents_fd = self._open_private_dirs()
            return [
                name[:-6] for name in sorted(os.listdir(intents_fd))
                if name.endswith(".jsonl")
                and TOKEN_RE.fullmatch(name[:-6])
                and not self._intent_applied(name[:-6])
            ]
        except OSError as error:
            self._journal_fs_unsafe(".aib/intents", str(error))
            return []
        finally:
            for fd in (intents_fd, aib_fd):
                if fd >= 0:
                    os.close(fd)

    def _attempt_bindings(self) -> list[dict[str, Any]] | None:
        result = self.run_helper(
            [str(self.attempts_cli), self.uid], capture=True,
            extra_env={"AIB_ATTEMPTS_BINDINGS": "1"},
        )
        if result.returncode != 0:
            return None
        bindings: list[dict[str, Any]] = []
        try:
            for line in result.stdout.splitlines():
                value = json.loads(line)
                if isinstance(value, dict):
                    bindings.append(value)
        except (json.JSONDecodeError, RecursionError):
            return None
        return bindings

    def _active_orphan_deferrals(self) -> dict[str, dict[str, Any]]:
        active: dict[str, dict[str, Any]] = {}
        for record in self.records:
            local_attempt = record.get("local_attempt")
            if not isinstance(local_attempt, str):
                continue
            if record.get("event") == "orphan.deferred":
                active[local_attempt] = record
            elif record.get("event") in {"orphan.resolved", "orphan.exhausted"}:
                active.pop(local_attempt, None)
        return active

    @staticmethod
    def _pending_intent_summary(pending: set[str]) -> tuple[list[str], int, str]:
        ordered = sorted(pending)
        digest = hashlib.sha256("\n".join(ordered).encode("utf-8")).hexdigest()
        return ordered[:DEFERRED_PENDING_LIMIT], len(ordered), digest

    def _journal_orphan_deferral(
        self, unfinished: dict[str, Any], local_attempt: str, pending: set[str],
        count: int, retry_at: str,
    ) -> None:
        names, pending_count, pending_sha256 = self._pending_intent_summary(pending)
        self.journal(
            "orphan.deferred", local_attempt=local_attempt,
            pending=names, pending_count=pending_count, pending_sha256=pending_sha256,
            n=count, retry_at=retry_at,
            started_at=unfinished.get("ts"), sid=unfinished.get("sid"),
            msg_id=unfinished.get("msg_id"), task_id=unfinished.get("task_id"),
            run_id=unfinished.get("run_id"), requester=unfinished.get("requester"),
        )

    def _deferred_intent_names(self) -> set[str]:
        names: set[str] = set()
        truncated = False
        for record in self._active_orphan_deferrals().values():
            pending = record.get("pending")
            if isinstance(pending, list):
                names.update(name for name in pending if isinstance(name, str))
                pending_count = record.get("pending_count")
                if isinstance(pending_count, int) and pending_count > len(pending):
                    truncated = True
        if truncated:
            names.update(self._pending_orphan_intents())
        return names

    def _retry_deferred_orphans(self) -> None:
        now = datetime.now(timezone.utc)
        quarantine_budget = [INTENT_SCAN_LIMIT]
        for local_attempt, record in self._active_orphan_deferrals().items():
            retry_at = parse_timestamp(record.get("retry_at"))
            if retry_at is not None and retry_at > now:
                continue
            unfinished = {
                "ts": record.get("started_at"), "sid": record.get("sid"),
                "msg_id": record.get("msg_id"), "task_id": record.get("task_id"),
                "run_id": record.get("run_id"), "requester": record.get("requester"),
            }
            self._adopt_orphan_attempt(
                unfinished, local_attempt, retry_n=int(record.get("n", 1)),
                quarantine_budget=quarantine_budget,
            )

    def _adopt_orphan_attempt(
        self, unfinished: dict[str, Any], local_attempt: str, *, retry_n: int = 0,
        quarantine_budget: list[int] | None = None,
    ) -> str:
        existing = next(
            (
                record for record in reversed(self.records)
                if record.get("event") == "turn.attempt"
                and record.get("local_attempt_id") == local_attempt
            ),
            None,
        )
        if existing is not None:
            attempt_id = existing.get("attempt_id")
            if isinstance(attempt_id, str) and self._closed_intent(attempt_id) is None:
                present, digest = self._intent_snapshot(attempt_id)
                self._close_intent_attempt(attempt_id, present, digest)
            self.journal("orphan.resolved", local_attempt=local_attempt)
            return "resolved"
        pending = set(self._pending_orphan_intents())
        claimed = {
            record.get("attempt_id") for record in self.records
            if record.get("event") == "turn.attempt"
        }
        bindings = self._attempt_bindings()
        if bindings is None:
            count = retry_n + 1
            unclaimed = pending - claimed
            if count >= 5:
                ordered = sorted(unclaimed)
                limit = INTENT_SCAN_LIMIT
                if quarantine_budget is not None:
                    limit = min(limit, max(0, quarantine_budget[0]))
                batch = ordered[:limit]
                for attempt_id in batch:
                    self._quarantine_intent(
                        self.intent_dir / f"{attempt_id}.jsonl",
                        "unbound_attempt", alarm="attention",
                    )
                if quarantine_budget is not None:
                    quarantine_budget[0] -= len(batch)
                remaining = set(ordered[len(batch):])
                if remaining:
                    self._journal_orphan_deferral(
                        unfinished, local_attempt, remaining, count, utc_now()
                    )
                    return "deferred"
                self.journal(
                    "attention", reason="unbound_attempt", local_attempt=local_attempt
                )
                self.journal("orphan.exhausted", local_attempt=local_attempt, n=count)
                return "resolved"
            if not any(
                record.get("event") == "attention"
                and record.get("reason") == "attempt_bindings_unavailable"
                and record.get("local_attempt") == local_attempt
                for record in self.records
            ):
                self.journal(
                    "attention", reason="attempt_bindings_unavailable",
                    local_attempt=local_attempt,
                )
            delay = min(300.0, self.poll_s * (2 ** (count - 1)))
            retry_at = datetime.fromtimestamp(
                time.time() + delay, timezone.utc
            ).isoformat(timespec="milliseconds").replace("+00:00", "Z")
            self._journal_orphan_deferral(
                unfinished, local_attempt, unclaimed, count, retry_at
            )
            return "deferred"
        started_at = parse_timestamp(unfinished.get("ts"))
        restarted_at = parse_timestamp(self.started_at)
        mux_session = str(
            self.registry.get("projects", {}).get(self.project_uid, {}).get("mux_session", "")
        )
        matches = [
            binding for binding in bindings
            if binding.get("attempt_id") in pending
            and binding.get("attempt_id") not in claimed
            and binding.get("agent_uid") == self.uid
            and binding.get("decision") == "allow"
            and binding.get("session_id") == mux_session
            and binding.get("running") is False
            and started_at is not None
            and restarted_at is not None
            and (decided_at := parse_timestamp(binding.get("decided_at"))) is not None
            and started_at <= decided_at <= restarted_at
        ]
        try:
            os.unlink(f".turn-{local_attempt}.attempt", dir_fd=self.state_dir_fd)
        except OSError:
            pass
        if len(matches) == 1:
            broker_attempt = str(matches[0]["attempt_id"])
            self.journal(
                "turn.attempt", attempt_id=broker_attempt,
                local_attempt_id=local_attempt, msg_id=unfinished.get("msg_id"),
                task_id=unfinished.get("task_id"), run_id=unfinished.get("run_id"),
                requester=unfinished.get("requester"), adopted=True,
            )
            present, digest = self._intent_snapshot(broker_attempt)
            self._close_intent_attempt(broker_attempt, present, digest)
            self.journal("orphan.resolved", local_attempt=local_attempt)
            return "resolved"
        for attempt_id in pending - claimed:
            self._quarantine_intent(
                self.intent_dir / f"{attempt_id}.jsonl", "unbound_attempt", alarm="attention"
            )
        self.journal("orphan.resolved", local_attempt=local_attempt)
        return "resolved"

    def start_turn(self, work: dict[str, Any]) -> None:
        if not self.prepare_task_work(work):
            return
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
            rejection_seq = work.pop("_rejection_preamble_seq", None)
            if isinstance(rejection_seq, int):
                self.journal("rejections.preambled", through_seq=rejection_seq, msg_id=work.get("id"))
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

    def _message_engine_error(self, work: dict[str, Any], error: Exception) -> None:
        message_id = str(work.get("id", "unknown"))
        count = 1 + self._unmatched_preparations(message_id) + sum(
            record.get("event") == "message.engine_error" and record.get("msg_id") == message_id
            for record in self.records
        )
        self.journal(
            "message.engine_error", msg_id=message_id, n=count,
            detail=type(error).__name__,
        )
        if count >= 3:
            if not work.get("synthetic"):
                self.message_command("fail", message_id, "engine_error")
            self.journal("attention", reason="message_engine_error", msg_id=message_id)
            self.work = None
        else:
            self.work = work
            self.retry_at = time.monotonic() + self.backoff_base

    def guarded_start_turn(self, work: dict[str, Any]) -> None:
        try:
            self.start_turn(work)
        except Exception as error:
            self._message_engine_error(work, error)

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
        broker_attempt = self._record_turn_attempt(work, attempt_id, attempt_meta_name)
        try:
            self._finish_result(rc, output, work, session_arg, attempt_id, refusal_reason)
        finally:
            if isinstance(work.get("task"), dict) and self._closed_intent(broker_attempt) is None:
                present, digest = self._intent_snapshot(broker_attempt)
                self._close_intent_attempt(broker_attempt, present, digest)

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
        intents_handled = False
        if isinstance(work.get("task"), dict):
            task = work["task"]
            broker_attempt = str(work.get("broker_attempt_id", attempt_id))
            context = {
                "attempt_id": broker_attempt,
                "msg_id": work.get("id"),
                "task_id": task.get("task_id"),
                "run_id": task.get("run_id"),
                "requester": task.get("owner"),
            }
            try:
                intents_handled = self._apply_pending_intent(
                    broker_attempt, context, close_attempt=True
                )
            except Exception as error:
                self._intent_retry(
                    self.intent_dir / f"{broker_attempt}.jsonl",
                    broker_attempt,
                    type(error).__name__,
                )
                intents_handled = False
            current_task = self.task_show(str(task["task_id"])) or task
            if intents_handled and current_task.get("state") not in {"ASSIGNED", "IN_PROGRESS"}:
                rc = 0
                if not output:
                    output = "task intent applied"
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
                handled = intents_handled
                if not handled and not self._intent_retry_pending(broker_attempt):
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
        self.guarded_start_turn(synthetic)

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
        self._close_unclosed_attempts()
        self.scan_intents()
        self.sweep_missing_reports()
        self.scan_task_dlq()

        while not self.stop_requested:
            now = time.monotonic()
            if now >= self.next_tick:
                self.tick()
            self.process_controls()
            if self.stop_requested:
                break
            if self.process is not None:
                active_work = self.attempt["work"] if self.attempt is not None else (self.work or {"id": "unknown"})
                try:
                    self.collect_turn()
                except Exception as error:
                    self.process = None
                    self.attempt = None
                    self._message_engine_error(active_work, error)
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
                        self.guarded_start_turn(self.work)
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
