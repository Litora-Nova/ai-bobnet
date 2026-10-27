"""Shared helpers for the broker-owned subscription login store."""

from __future__ import annotations

import base64
import contextlib
import datetime as dt
import fcntl
import grp
import json
import os
import pwd
import re
import stat
import tempfile
from pathlib import Path
from typing import Any

PROVIDERS = {
    "claude-code": ".credentials.json",
    "codex": "auth.json",
}

DEFAULT_ACCESS_LIFETIME_S = 3600
DEFAULT_LOGIN_MARGIN_S = 300
DEFAULT_LOGIN_SLACK_S = 600


def engine_root() -> Path:
    return Path(__file__).resolve().parent.parent


def test_seams_enabled() -> bool:
    root = engine_root()
    return os.environ.get("AIB_TEST_SEAMS") == "1" and not (root / ".aib-installed").exists()


# The same installed CLI locations the provider adapters default to (adapters/claude-code, adapters/codex).
CLAUDE_BIN = "/opt/aib/claude-code/current/claude"
CODEX_BIN = "/opt/aib/codex/current/codex"


def setting(name: str, default: str) -> str:
    if test_seams_enabled() and name in os.environ and os.environ[name] != "":
        return os.environ[name]
    return default


def runtime_integer(name: str, default: int) -> int:
    """A per-run input set by the caller (the broker), read on installed engines too.

    Unlike setting()/integer(), which honour the environment only as test seams,
    this is for values the production caller passes on purpose. A missing or
    malformed value yields the default.
    """
    value = os.environ.get(name, "")
    return int(value) if re.fullmatch(r"-?[0-9]{1,9}", value) else default


def integer(name: str, default: int) -> int:
    try:
        value = int(setting(name, str(default)))
    except ValueError:
        return default
    return value if value >= 0 else default


def login_margin_seconds() -> int:
    return integer("AIB_LOGIN_MARGIN_S", DEFAULT_LOGIN_MARGIN_S)


def login_slack_seconds() -> int:
    return integer("AIB_LOGIN_SLACK_S", DEFAULT_LOGIN_SLACK_S)


def refresh_cadence_seconds() -> int:
    return max(1, integer("AIB_LOGIN_ACCESS_LIFETIME_S", DEFAULT_ACCESS_LIFETIME_S) // 2 - 1)


def login_max_turn_seconds() -> int:
    """Longest turn that fits between worst-case refresh polls and token margins."""
    lifetime = integer("AIB_LOGIN_ACCESS_LIFETIME_S", DEFAULT_ACCESS_LIFETIME_S)
    derived = max(
        1,
        lifetime - refresh_cadence_seconds() - login_margin_seconds() - login_slack_seconds() - 1,
    )
    return integer("AIB_LOGIN_MAX_TURN_S", derived)


def now() -> int:
    return integer("AIB_LOGIN_NOW", int(dt.datetime.now(dt.timezone.utc).timestamp()))


def iso(epoch: int | float) -> str:
    return dt.datetime.fromtimestamp(epoch, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def login_root() -> Path:
    return Path(setting("AIB_LOGIN_ROOT", "/var/lib/aib/login"))


def credential_path(provider: str, root: Path | None = None) -> Path:
    return (root or login_root()) / provider / PROVIDERS[provider]


def read_object(path: Path) -> dict[str, Any] | None:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


def _account_id(value: str, *, group: bool) -> int | None:
    if value.isdecimal():
        return int(value)
    try:
        return grp.getgrnam(value).gr_gid if group else pwd.getpwnam(value).pw_uid
    except KeyError:
        return None


def expected_store_ids() -> tuple[int | None, int | None]:
    """Resolve the configured owner/group for broker-owned credential files."""
    if test_seams_enabled():
        owner_default = str(os.geteuid())
        group_default = str(os.getegid())
    else:
        owner_default = "aib-broker"
        group_default = "aib-login"
    owner = _account_id(setting("AIB_LOGIN_STORE_OWNER", owner_default), group=False)
    group = _account_id(setting("AIB_LOGIN_STORE_GROUP", group_default), group=True)
    return owner, group


def trusted_store_file(path: Path, mode: int = 0o640) -> bool:
    try:
        info = path.lstat()
    except OSError:
        return False
    owner, group = expected_store_ids()
    return (
        owner is not None
        and group is not None
        and stat.S_ISREG(info.st_mode)
        and stat.S_IMODE(info.st_mode) == mode
        and info.st_uid == owner
        and info.st_gid == group
    )


@contextlib.contextmanager
def store_lock():
    """Serialize store publishers without following an attacker-supplied lock symlink."""
    root = login_root()
    root.mkdir(parents=True, exist_ok=True)
    flags = os.O_RDWR | os.O_CREAT | os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(root / ".lock", flags, 0o600)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid():
            raise PermissionError("unsafe login-store lock")
        os.fchmod(descriptor, 0o600)
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        os.close(descriptor)


def jwt_exp(token: Any) -> int | None:
    if not isinstance(token, str):
        return None
    parts = token.split(".")
    if len(parts) != 3:
        return None
    try:
        raw = parts[1] + "=" * (-len(parts[1]) % 4)
        payload = json.loads(base64.urlsafe_b64decode(raw).decode("utf-8"))
        value = payload.get("exp")
    except (ValueError, UnicodeError, json.JSONDecodeError):
        return None
    return value if type(value) is int else None


def access_expiry(provider: str, data: dict[str, Any]) -> int | None:
    if provider == "claude-code":
        oauth = data.get("claudeAiOauth")
        value = oauth.get("expiresAt") if isinstance(oauth, dict) else None
        return value // 1000 if type(value) is int else None
    tokens = data.get("tokens")
    return jwt_exp(tokens.get("access_token")) if isinstance(tokens, dict) else None


def atomic_json(path: Path, value: dict[str, Any], mode: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, raw = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    tmp = Path(raw)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, separators=(",", ":"), ensure_ascii=False)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    finally:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass


def regular_mode(path: Path, mode: int | None = None) -> bool:
    try:
        info = path.lstat()
    except OSError:
        return False
    return stat.S_ISREG(info.st_mode) and (mode is None or stat.S_IMODE(info.st_mode) == mode)


def provider_valid(value: str) -> bool:
    return value in PROVIDERS and re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", value) is not None


def write_alarm(outbox_root: Path, source: str, body: str, epoch: int | None = None) -> bool:
    target = outbox_root / "_server"
    try:
        target.mkdir(parents=True, exist_ok=True)
        if target.is_symlink() or not target.is_dir():
            return False
        stamp = iso(now() if epoch is None else epoch)
        alarm_id = f"alarm-{os.getpid()}-{int(dt.datetime.now().timestamp() * 1000000)}"
        with (target / "outbox.md").open("a", encoding="utf-8") as stream:
            stream.write(f"{stamp} | id:{alarm_id} | from:{source} | to:human:ops | state:PERSISTED | {body}\n")
        return True
    except OSError:
        return False
