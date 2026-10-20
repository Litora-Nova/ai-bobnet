"""Shared helpers for the broker-owned subscription login store."""

from __future__ import annotations

import base64
import datetime as dt
import json
import os
import re
import stat
import tempfile
from pathlib import Path
from typing import Any

PROVIDERS = {
    "claude-code": ".credentials.json",
    "codex": "auth.json",
}


def engine_root() -> Path:
    return Path(__file__).resolve().parent.parent


def test_seams_enabled() -> bool:
    root = engine_root()
    return os.environ.get("AIB_TEST_SEAMS") == "1" and not (root / ".aib-installed").exists()


def setting(name: str, default: str) -> str:
    if test_seams_enabled() and name in os.environ and os.environ[name] != "":
        return os.environ[name]
    return default


def integer(name: str, default: int) -> int:
    try:
        value = int(setting(name, str(default)))
    except ValueError:
        return default
    return value if value >= 0 else default


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
