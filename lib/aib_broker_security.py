#!/usr/bin/env python3
"""Kernel-backed broker peer and confined-group policy checks."""

from __future__ import annotations

import grp
import os
import re
import socket
import stat
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TEST_SEAMS = os.environ.get("AIB_TEST_SEAMS") == "1" and not (ROOT / ".aib-installed").exists()
if not TEST_SEAMS:
    for name in ("AIB_TEST_PEER_UID", "AIB_TEST_SHARED_GID", "AIB_IDENTITY_CMD"):
        os.environ.pop(name, None)

sys.path.insert(0, str(ROOT / "lib"))
from aib_control import configured_role_uids, identity_for  # noqa: E402

UID_RE = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)+\Z", re.ASCII)
GROUPS_RE = re.compile(r"[0-9]+(?:,[0-9]+)*\Z", re.ASCII)


def peer_uid() -> int:
    fake = os.environ.get("AIB_TEST_PEER_UID") if TEST_SEAMS else None
    if fake is not None:
        if not fake.isdecimal():
            raise ValueError("invalid test peer uid")
        return int(fake)
    duplicate = os.dup(0)
    connection = socket.socket(fileno=duplicate)
    try:
        raw = connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
        _pid, uid, _gid = struct.unpack("3i", raw)
        return uid
    finally:
        connection.close()


def target_owner(target: str) -> int | None:
    state_root = Path(os.environ.get("AIB_SUP_STATE_ROOT", "/var/lib/aib-sup"))
    try:
        target_info = (state_root / target).lstat()
        if not stat.S_ISDIR(target_info.st_mode) or target_info.st_uid < 1000:
            return None
        return target_info.st_uid
    except OSError:
        return None


def peer_agent(target: str) -> int:
    if UID_RE.fullmatch(target) is None:
        return 2
    try:
        uid = peer_uid()
    except (OSError, ValueError, struct.error):
        print("authorization=deny")
        print("reason=peer_credentials_unavailable")
        print("stage=peer")
        print("caller=unknown:peer")
        print("peer_uid=-1")
        return 0
    caller = "root:root" if uid == 0 else identity_for(uid)
    role_config_unavailable = (
        uid != 0 and caller.startswith("unknown:") and configured_role_uids() is None
    )
    target_uid = target_owner(target) if "AIB_SUP_STATE_ROOT" in os.environ else None
    role_uid_raw = os.environ.get("AIB_ROLE_UID", "")
    role_uid = int(role_uid_raw) if role_uid_raw.isdecimal() else None
    authorization = "deny"
    reason = "role_config_unavailable" if role_config_unavailable else "peer_unauthorized"
    stage = "peer"
    if uid == 0:
        authorization, reason = "allow", "root_supervisor"
    elif caller.startswith("human:"):
        authorization, reason = "allow", "human_operator"
    if authorization == "allow" and "AIB_SUP_STATE_ROOT" in os.environ:
        if target_uid is None or role_uid is None or role_uid < 1000:
            authorization, reason, stage = "deny", "target_role_unavailable", "confine"
        elif target_uid != role_uid:
            authorization, reason, stage = "deny", "target_role_mismatch", "confine"
    print(f"authorization={authorization}")
    print(f"reason={reason}")
    print(f"stage={stage}")
    print(f"caller={caller}")
    print(f"peer_uid={uid}")
    print(f"target_uid={target_uid if target_uid is not None else -1}")
    print(f"role_uid={role_uid if role_uid is not None else -1}")
    return 0


def shared_gid() -> int | None:
    try:
        return grp.getgrnam("aib-shared").gr_gid
    except KeyError:
        fake = os.environ.get("AIB_TEST_SHARED_GID") if TEST_SEAMS else None
        if fake is not None and fake.isdecimal():
            return int(fake)
        return None


def groups_safe(raw: str, primary: str) -> int:
    if raw and GROUPS_RE.fullmatch(raw) is None:
        return 2
    if not primary.isdecimal():
        return 2
    groups = {int(primary)}
    if raw:
        groups.update(int(item) for item in raw.split(","))
    forbidden = shared_gid()
    if forbidden is None:
        return 4
    return 3 if forbidden in groups else 0


def main(argv: list[str]) -> int:
    if len(argv) == 2 and argv[0] == "peer-agent":
        return peer_agent(argv[1])
    if len(argv) == 3 and argv[0] == "groups-safe":
        return groups_safe(argv[1], argv[2])
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
