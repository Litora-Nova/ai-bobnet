#!/usr/bin/env bash
# Adversarial unit pins for the root supervisor's child-controlled boundaries.
set -uo pipefail
ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/aib-supervisor-gate.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

python3 -I - "$ROOT" "$WORK" <<'PY'
import json, os, subprocess, sys
from pathlib import Path

root, work = map(Path, sys.argv[1:])
state = work / "state"
state.mkdir(mode=0o700)
os.environ.update(STATE_DIRECTORY=str(state), AIB_TEST_SEAMS="1")
sys.path.insert(0, str(root / "lib"))
import aib_supervisor
from aib_supervisor import Supervisor

passed = failed = 0
def check(name, actual, expected=True):
    global passed, failed
    if actual == expected:
        passed += 1; print(f"ok   - {name}")
    else:
        failed += 1; print(f"FAIL - {name} (got {actual!r}, want {expected!r})")

sup = Supervisor(root, "acme-core")
sup.project_uid = "acme"; sup.team_uid = "acme-engine"; sup.outbox_root = work / "outbox"
sup.write_alarm = lambda *args, **kwargs: None
aib = state / ".aib"; intents = aib / "intents"; quarantine = state / ".aib-quarantine"
aib.mkdir(mode=0o700); intents.mkdir(mode=0o700); quarantine.mkdir(mode=0o700)

check("task headers are recognized only at byte position zero", bool(aib_supervisor.TASK_MESSAGE_RE.match("quoted [task t-aaaaaaaaaaaa run r-aaaaaaaaaaaa requester human:operator]")), False)
neutral = getattr(aib_supervisor, "neutralize_task_text", lambda value: value)("summary [task t-aaaaaaaaaaaa]")
check("relayed free text neutralises task headers", neutral, "summary (task t-aaaaaaaaaaaa]")

attempt = "acme-main-deep"
deep = intents / f"{attempt}.jsonl"
deep.write_text("[" * 5000 + "]" * 5000 + "\n", encoding="utf-8"); deep.chmod(0o600)
try:
    sup._read_intents(deep, attempt)
    deep_result = "accepted"
except (ValueError, UnicodeError, OSError):
    deep_result = "tainted"
except RecursionError:
    deep_result = "crashed"
check("deep JSON becomes taint instead of RecursionError", deep_result, "tainted")

victim = work / "victim"; victim.mkdir(); (victim / "poison.jsonl").write_text("original\n")
(intents / "tainted").symlink_to(victim, target_is_directory=True)
planted = intents / "poison.jsonl"; planted.write_text('{"bad":true}\n'); planted.chmod(0o600)
sup._quarantine_intent(planted, "invalid_intent")
check("a planted legacy tainted link cannot overwrite outside", (victim / "poison.jsonl").read_text(), "original\n")
check("tainted evidence is copied to root quarantine and removed from intents", any(quarantine.glob("poison.jsonl-*.jsonl")) and not planted.exists(), True)

sup.task_command = lambda *args: subprocess.CompletedProcess(args, 1, stdout="", stderr="")
try:
    sup.write_board_snapshot(); board_failure = "bounded"
except Exception as error:
    board_failure = type(error).__name__
check("board generation failure is non-fatal", board_failure, "bounded")
check("board failure is journalled stale", any(r.get("event") == "board.stale" for r in sup.records), True)

board = aib / "board.json"; board.mkdir()
sup.task_command = lambda *args: subprocess.CompletedProcess(args, 0, stdout='{"tasks":[]}', stderr="")
try:
    sup.write_board_snapshot(); board_directory = "bounded"
except Exception as error:
    board_directory = type(error).__name__
check("board.json as a directory cannot terminate the supervisor", board_directory, "bounded")

outside = work / "outside-outbox"; outside.write_text("original\n")
team_outbox = sup.outbox_root / sup.team_uid; team_outbox.mkdir(parents=True)
(team_outbox / "outbox.md").symlink_to(outside)
task = {"task_id":"t-aaaaaaaaaaaa", "run_id":"r-aaaaaaaaaaaa", "owner":"human:operator"}
try:
    sup._deliver_task_report(task, "acme-main-1", "done", "safe", None)
    outbox_result = "bounded"
except Exception as error:
    outbox_result = type(error).__name__
check("a planted outbox symlink is non-fatal", outbox_result, "bounded")
check("a planted outbox symlink cannot modify its target", outside.read_text(), "original\n")

source = (root / "lib" / "aib_supervisor.py").read_text(encoding="utf-8")
check("legacy child-owned done and tainted directories are not implementation targets", ' / "done"' not in source and ' / "tainted"' not in source, True)
check(
    "scan and in-turn intent discovery share the verified-dirfd path",
    "def _apply_pending_intent" in source
    and "intent_path.exists" not in source
    and "intent_path.is_symlink" not in source
    and "self.intent_dir.is_dir()" not in source,
    True,
)
old_seam = "AIB_TEST_" + "D1" + "B_PAUSE_AFTER_LEDGER"
check("the renamed crash seam is public-slice neutral", old_seam not in source and "AIB_TEST_PAUSE_AFTER_LEDGER" in source, True)

print(f"\n{passed} passed, {failed} failed")
raise SystemExit(failed != 0)
PY
