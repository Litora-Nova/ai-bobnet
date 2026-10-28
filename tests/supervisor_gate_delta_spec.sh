#!/usr/bin/env bash
# Adversarial unit pins for the root supervisor's child-controlled boundaries.
set -uo pipefail
ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/aib-supervisor-gate.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

python3 -I - "$ROOT" "$WORK" <<'PY'
import json, os, stat, subprocess, sys
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
sup.uid = "acme-core"
sup.outbox_root.mkdir(mode=0o755)
aib = state / ".aib"; intents = aib / "intents"; quarantine = state / ".aib-quarantine"
aib.mkdir(mode=0o700); intents.mkdir(mode=0o700); quarantine.mkdir(mode=0o700)

task = {"task_id":"t-aaaaaaaaaaaa", "run_id":"r-aaaaaaaaaaaa", "owner":"human:operator"}
saved_seam = os.environ.pop("AIB_TEST_SEAMS")
sup._deliver_task_report(task, "acme-main-production", "done", "safe", None)
os.environ["AIB_TEST_SEAMS"] = saved_seam
team_outbox = sup.outbox_root / sup.team_uid
check("production outbox creation fixes the team directory to 0770", stat.S_IMODE(team_outbox.stat().st_mode), 0o770)
check("production outbox delivery is durable without test seams", any(r.get("event") == "report.delivered" for r in sup.records), True)

outbox = team_outbox / "outbox.md"
outbox.write_text("", encoding="utf-8")
unsafe = "bad\nname|\u202e"
sup.write_alarm("unsafe_detail", attempt_id=unsafe)
alarm_text = outbox.read_text(encoding="utf-8")
check("unsafe alarm values cannot inject another outbox line", len(alarm_text.splitlines()), 1)
check("unsafe alarm values are replaced rather than copied", unsafe not in alarm_text and "bad" not in alarm_text and "\u202e" not in alarm_text, True)

before = len(outbox.read_text(encoding="utf-8").splitlines())
sup.write_alarm("intents_tainted", attempt_id="acme-main-one")
sup.write_alarm("intents_tainted", attempt_id="acme-main-two")
sup.write_alarm("intents_tainted", attempt_id="acme-main-one")
after = len(outbox.read_text(encoding="utf-8").splitlines())
check("alarms deduplicate by kind and attempt episode", after - before, 2)

before_sent = sum(r.get("event") == "alarm.sent" and r.get("kind") == "rate_probe" for r in sup.records)
for n in range(12):
    sup.write_alarm("rate_probe", attempt_id=f"acme-rate-{n}")
rate_sent = sum(r.get("event") == "alarm.sent" and r.get("kind") == "rate_probe" for r in sup.records) - before_sent
rate_suppressed = sum(r.get("event") == "alarm.suppressed" and r.get("kind") == "rate_probe" for r in sup.records)
check("per-kind alarms are capped at ten per hour with one suppression record", (rate_sent, rate_suppressed), (10, 1))

weird_name = "bad\nname|\u202e"
weird = intents / weird_name
weird.write_text("{}\n", encoding="utf-8"); weird.chmod(0o600)
before_lines = len(outbox.read_text(encoding="utf-8").splitlines())
sup.scan_intents()
after_text = outbox.read_text(encoding="utf-8")
invalid_record = next(r for r in reversed(sup.records) if r.get("event") == "intents.tainted")
check("an invalid child filename produces exactly one outbox line", len(after_text.splitlines()) - before_lines, 1)
check("an invalid child filename is represented only by a 16-hex digest and length", len(str(invalid_record.get("name_sha256", ""))) == 16 and invalid_record.get("name_length") == len(weird_name) and weird_name not in after_text, True)

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

sup.task_show = lambda task_id: {
    "task_id":"t-aaaaaaaaaaaa", "run_id":"r-aaaaaaaaaaaa", "team_uid":"acme-engine",
    "assignee":"acme-core", "state":"IN_PROGRESS", "owner":"human:operator",
}
invalid_context = {"attempt_id":"acme-main-link", "task_id":"t-aaaaaaaaaaaa", "run_id":"r-aaaaaaaaaaaa"}
link_target = work / "intent-link-target"; link_target.write_text("original\n", encoding="utf-8")
(intents / "acme-main-link.jsonl").symlink_to(link_target)
sup.apply_intent_file(intents / "acme-main-link.jsonl", invalid_context)
check("a symlinked intent is tainted without touching its target", link_target.read_text(encoding="utf-8"), "original\n")
check("a symlinked intent is classified invalid_intent", any(r.get("event") == "intents.tainted" and r.get("attempt_id") == "acme-main-link" and r.get("reason") == "invalid_intent" for r in sup.records), True)

large_attempt = "acme-main-large"; large = intents / f"{large_attempt}.jsonl"
large.write_bytes(b"x" * (64 * 1024 + 1)); large.chmod(0o600)
sup.apply_intent_file(large, {**invalid_context, "attempt_id":large_attempt})
check("an oversized intent is classified invalid_intent", any(r.get("event") == "intents.tainted" and r.get("attempt_id") == large_attempt and r.get("reason") == "invalid_intent" for r in sup.records), True)

lines_attempt = "acme-main-lines"; lines = intents / f"{lines_attempt}.jsonl"
lines.write_text("".join(json.dumps({"attempt_id":lines_attempt,"verb":"continue","task_id":"t-aaaaaaaaaaaa","summary":"x"}) + "\n" for _ in range(11)), encoding="utf-8"); lines.chmod(0o600)
sup.apply_intent_file(lines, {**invalid_context, "attempt_id":lines_attempt})
check("an intent over ten lines is classified invalid_intent", any(r.get("event") == "intents.tainted" and r.get("attempt_id") == lines_attempt and r.get("reason") == "invalid_intent" for r in sup.records), True)

mixed_attempt = "acme-main-mixed"; mixed = intents / f"{mixed_attempt}.jsonl"
mixed.write_text(
    json.dumps({"attempt_id":mixed_attempt,"verb":"continue","task_id":"t-aaaaaaaaaaaa","summary":"valid"}) + "\n" +
    json.dumps({"attempt_id":mixed_attempt,"verb":"report","task_id":"t-aaaaaaaaaaaa","state":"failed","summary":"bad","reason":[]}) + "\n",
    encoding="utf-8",
); mixed.chmod(0o600)
applied_events = []
sup.task_event = lambda *args, **kwargs: applied_events.append((args, kwargs)) or subprocess.CompletedProcess(args, 0, stdout="", stderr="")
sup.apply_intent_file(mixed, {**invalid_context, "attempt_id":mixed_attempt})
check("whole-file validation prevents partial application before a bad typed reason", applied_events, [])
check("a mixed valid and invalid file is tainted as one unit", any(r.get("event") == "intents.tainted" and r.get("attempt_id") == mixed_attempt for r in sup.records), True)

victim = work / "victim"; victim.mkdir(); (victim / "poison.jsonl").write_text("original\n")
(intents / "tainted").symlink_to(victim, target_is_directory=True)
planted = intents / "poison.jsonl"; planted.write_text('{"bad":true}\n'); planted.chmod(0o600)
sup._quarantine_intent(planted, "invalid_intent")
check("a planted legacy tainted link cannot overwrite outside", (victim / "poison.jsonl").read_text(), "original\n")
check("tainted evidence is copied to root quarantine and removed from intents", any(quarantine.glob("poison-*.jsonl")) and not planted.exists(), True)

for item in quarantine.iterdir():
    item.unlink()
for n in range(101):
    candidate = intents / f"overflow!{n}"
    candidate.write_text("x", encoding="utf-8"); candidate.chmod(0o600)
    sup._quarantine_intent(candidate, "invalid_name")
check("quarantine retains no more than one hundred files", len(list(quarantine.iterdir())) <= 100, True)
check("the first file beyond quarantine capacity raises attention", any(r.get("event") == "attention" and r.get("reason") == "quarantine_capacity" for r in sup.records), True)

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

board.rmdir()
board_target = work / "board-target"; board_target.write_text("original\n", encoding="utf-8")
board.symlink_to(board_target)
sup.write_board_snapshot()
check("a planted board symlink cannot modify its target", board_target.read_text(encoding="utf-8"), "original\n")

board.unlink()
sup.task_command = lambda *args: subprocess.CompletedProcess(
    args, 0,
    stdout=json.dumps({"tasks":[{"task_id":task["task_id"], "title":"visible task"}]}),
    stderr="",
)
sup.write_board_snapshot()
board_value = json.loads(board.read_text(encoding="utf-8"))
check(
    "the end-to-end board is private, role-owned, and contains the task",
    (stat.S_IMODE(board.stat().st_mode), board.stat().st_uid, board_value["tasks"][0]["task_id"]),
    (0o600, os.getuid(), task["task_id"]),
)

outside = work / "outside-outbox"; outside.write_text("original\n")
outbox.unlink()
(team_outbox / "outbox.md").symlink_to(outside)
try:
    sup._deliver_task_report(task, "acme-main-1", "done", "safe", None)
    outbox_result = "bounded"
except Exception as error:
    outbox_result = type(error).__name__
check("a planted outbox symlink is non-fatal", outbox_result, "bounded")
check("a planted outbox symlink cannot modify its target", outside.read_text(), "original\n")

pending_task = {"task_id":"t-bbbbbbbbbbbb", "run_id":"r-bbbbbbbbbbbb", "owner":"human:operator"}
sup._deliver_task_report(pending_task, "acme-main-pending", "done", "retry me", None)
(team_outbox / "outbox.md").unlink()
sup.scan_intents()
pending_text = (team_outbox / "outbox.md").read_text(encoding="utf-8") if (team_outbox / "outbox.md").exists() else ""
check("a failed report delivery remains pending and is retried by the scan", "task-report t-bbbbbbbbbbbb state done" in pending_text, True)
check("a retried report delivery is journalled complete", any(r.get("event") == "report.delivered" and r.get("task_id") == "t-bbbbbbbbbbbb" for r in sup.records), True)

entry = intents / "odd-entry.jsonl"
entry.mkdir()
sup.scan_intents(); sup.scan_intents()
check("an empty non-regular intent entry is removed", entry.exists(), False)
check(
    "an unchanged non-regular intent entry is classified only once",
    sum(r.get("event") in {"intents.tainted", "intents.tainted_replay"} and r.get("attempt_id") == "odd-entry" for r in sup.records),
    1,
)

hidden_intents = aib / "intents-hidden"
intents.rename(hidden_intents)
outside_intents = work / "outside-intents"; outside_intents.mkdir()
outside_attempt = outside_intents / "acme-main-outside.jsonl"
outside_attempt.write_text("{}\n", encoding="utf-8"); outside_attempt.chmod(0o600)
intents.symlink_to(outside_intents, target_is_directory=True)
before_unsafe = sum(r.get("event") == "fs.unsafe" for r in sup.records)
sup.scan_intents(); sup.scan_intents()
check("a symlinked intents directory is journalled unsafe once", sum(r.get("event") == "fs.unsafe" for r in sup.records) - before_unsafe, 1)
check(
    "the supervisor does not access through a symlinked intents directory",
    outside_attempt.read_text(encoding="utf-8") == "{}\n"
    and not any(r.get("attempt_id") == "acme-main-outside" for r in sup.records),
    True,
)
intents.unlink()
hidden_intents.rename(intents)
sup.scan_intents()

captured = []
sup.task_event = Supervisor.task_event.__get__(sup, Supervisor)
sup.task_command = lambda *args: captured.append(args) or subprocess.CompletedProcess(args, 0, stdout="", stderr="")
sup.task_event(
    "report", task, "intent-acme-main-1-1", actor_type="agent", actor_id="acme-core",
    via="intent:acme-main-1", state="failed", reason="-option-like",
)
check("option-like report reasons remain one argv value", "--reason=-option-like" in captured[-1], True)

retry_calls = []
sup.task_show = lambda task_id: None
sup._intent_retry = lambda path, attempt_id, reason: retry_calls.append((attempt_id, reason)) or False
check("a transient task lookup failure stays pending rather than counting as handled", sup.apply_intent_file(intents / "acme-main-retry.jsonl", {"attempt_id":"acme-main-retry", "task_id":task["task_id"], "run_id":task["run_id"]}), False)
check("transient task lookup is not quarantined as context mismatch", retry_calls, [("acme-main-retry", "task_lookup")])

continuations = []
current_task = {
    **task, "team_uid":"acme-engine", "assignee":"acme-core", "state":"IN_PROGRESS",
    "owner":"human:operator", "budget":{"max_turns":8}, "assignments":2,
}
sup.task_show = lambda task_id: current_task
sup._read_intents = lambda path, attempt_id: [{
    "attempt_id":attempt_id, "verb":"continue", "task_id":task["task_id"], "summary":"more",
}]
sup.validate_result_ref = lambda value, task_value: True
sup.task_event = lambda *args, **kwargs: subprocess.CompletedProcess(args, 0, stdout="", stderr="")
sup._persist_self_task_message = lambda task_value, ident, summary: continuations.append(ident) or True
sup._unlink_intent = lambda name: None
sup.apply_intent_file(intents / "acme-main-cont-one.jsonl", {"attempt_id":"acme-main-cont-one", "task_id":task["task_id"], "run_id":task["run_id"]})
sup.apply_intent_file(intents / "acme-main-cont-two.jsonl", {"attempt_id":"acme-main-cont-two", "task_id":task["task_id"], "run_id":task["run_id"]})
check("continuations to the same worker get new ids per terminal attempt", len(continuations) == 2 and continuations[0] != continuations[1], True)

nudge_ids = []
blocked = []
sup._persist_self_task_message = lambda task_value, ident, summary: nudge_ids.append(ident) or True
sup._service_block = lambda *args, **kwargs: blocked.append((args, kwargs)) or True
sup.handle_missing_report(current_task, "acme-main-assignment-two")
check("the first miss after reassignment to the same worker is a new assignment nudge", (nudge_ids[-1], blocked), (f"{task['task_id']}.n.a2", []))

retry_calls.clear()
sup._apply_pending_intent = lambda *args: (_ for _ in ()).throw(OSError("git helper failed"))
sup.task_show = lambda task_id: {**task, "state":"IN_PROGRESS"}
sup.transcript = work / "transcript.log"
work_item = {"id":"task-message", "task":{**task, "state":"IN_PROGRESS"}, "broker_attempt_id":"acme-main-finish"}
finish_result = "bounded"
try:
    sup._finish_result(1, "provider failed", work_item, "new:session", "local-attempt")
except Exception as error:
    finish_result = type(error).__name__
check("in-turn intent exceptions do not escape the turn boundary", finish_result, "bounded")
check("in-turn intent exceptions enter the persisted retry path", retry_calls, [("acme-main-finish", "OSError")])
check("in-turn intent exceptions still close the provider turn", any(r.get("event") == "turn.ended" and r.get("attempt_id") == "local-attempt" for r in sup.records), True)

sup._apply_pending_intent = Supervisor._apply_pending_intent.__get__(sup, Supervisor)
sup._intent_retry = Supervisor._intent_retry.__get__(sup, Supervisor)

sup.task_show = lambda task_id: {**task, "state":"ASSIGNED", "assignee":"acme-core", "body_ref":"msg:assignment", "owner":"human:operator"}
sup.message_command = lambda *args, **kwargs: subprocess.CompletedProcess(
    args, 0,
    stdout=f"id:peer-copy | state:FAILED | from:acme-sib | reason:wakeup | [task {task['task_id']} run {task['run_id']} requester human:operator] build\n",
    stderr="",
)
dlq_events = []
sup.task_event = lambda *args, **kwargs: dlq_events.append((args, kwargs)) or subprocess.CompletedProcess(args, 0, stdout="", stderr="")
sup.scan_task_dlq()
check("a DLQ peer copy cannot cancel the assignment", dlq_events, [])
check("a DLQ message id mismatch is recorded as unbound", any(r.get("event") == "task.dlq_processed" and r.get("message_id") == "peer-copy" and r.get("outcome") == "unbound" for r in sup.records), True)

quarantined = []
sup._pending_orphan_intents = lambda: ["claimed-attempt", "new-attempt"]
sup.records.append({"event":"turn.attempt", "attempt_id":"claimed-attempt"})
sup._attempt_bindings = lambda: None
adopt_result = "bounded"
try:
    sup._adopt_orphan_attempt({"ts":"2026-10-28T10:00:00.100Z", "sid":"provider-session"}, "local-failed-bindings")
except Exception as error:
    adopt_result = type(error).__name__
check("a failed attempts query defers orphan adoption", adopt_result, "bounded")
check("a failed attempts query records one attention episode", any(r.get("event") == "attention" and r.get("reason") == "attempt_bindings_unavailable" for r in sup.records), True)

sup._attempt_bindings = lambda: []
sup._quarantine_intent = lambda path, reason, alarm="security": quarantined.append((path.stem, reason, alarm))
sup._adopt_orphan_attempt({"ts":"2026-10-28T10:00:00.100Z", "sid":"provider-session"}, "local-no-match")
check("orphan no-match quarantines only pending attempts that are not already claimed", quarantined, [("new-attempt", "unbound_attempt", "attention")])

sup.registry = {"projects":{"acme":{"mux_session":"acme"}}}
sup.started_at = "2026-10-28T11:00:00.000Z"
sup._pending_orphan_intents = lambda: ["broker-attempt"]
sup._attempt_bindings = lambda: [{
    "attempt_id":"broker-attempt", "agent_uid":"acme-core", "session_id":"acme",
    "decided_at":"2026-10-28T10:00:00.100500000Z", "decision":"allow", "running":False,
}]
sup._adopt_orphan_attempt(
    {"ts":"2026-10-28T10:00:00.100Z", "sid":"provider-session", "task_id":task["task_id"], "run_id":task["run_id"]},
    "local-real-binding",
)
check(
    "orphan adoption binds the mux session with parsed timestamps and a stopped launch",
    any(r.get("event") == "turn.attempt" and r.get("attempt_id") == "broker-attempt" and r.get("adopted") is True for r in sup.records),
    True,
)

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
check("the crash seam retains its descriptive public name", "AIB_TEST_PAUSE_AFTER_LEDGER" in source, True)
check("the agent unit configures the confinement helper", "Environment=AIB_CONFINE_BIN=/opt/aib/engine/libexec/landlock-exec" in (root / "deploy/systemd/aib-agent@.service").read_text(encoding="utf-8"), True)
check("reports and alarms share one fd-based outbox writer", source.count("def _append_outbox_line") == 1 and "destination.open(\"a\"" not in source, True)
check("the wakeup retry budget remains three by default", '${AIBOBNET_WAKEUP_MAX_ATTEMPTS:-3}' in (root / "bin/wakeup").read_text(encoding="utf-8"), True)

sup._quarantine_intent = Supervisor._quarantine_intent.__get__(sup, Supervisor)
sup._read_intents = Supervisor._read_intents.__get__(sup, Supervisor)
sup._unlink_intent = Supervisor._unlink_intent.__get__(sup, Supervisor)
retry_attempt = "acme-main-exhaust"
retry_path = intents / f"{retry_attempt}.jsonl"
retry_path.write_text(json.dumps({
    "attempt_id":retry_attempt, "verb":"report", "task_id":task["task_id"],
    "state":"failed", "summary":"retry", "reason":"temporary",
}) + "\n", encoding="utf-8"); retry_path.chmod(0o600)
retry_task = {
    **task, "team_uid":"acme-engine", "assignee":"acme-core", "state":"IN_PROGRESS",
    "owner":"human:operator", "budget":{"max_turns":8},
}
sup.task_show = lambda task_id: retry_task
sup.validate_result_ref = lambda value, task_value: True
sup.task_event = lambda *args, **kwargs: subprocess.CompletedProcess(args, 75, stdout="", stderr="")
for _ in range(4):
    sup.apply_intent_file(retry_path, {"attempt_id":retry_attempt, "task_id":task["task_id"], "run_id":task["run_id"]})
check("four transient apply failures remain pending", retry_path.exists() and sum(r.get("event") == "intent.retry" and r.get("attempt_id") == retry_attempt for r in sup.records) == 4, True)

os.close(sup.lock_fd); os.close(sup.state_dir_fd)
sup = Supervisor(root, "acme-core")
sup.project_uid = "acme"; sup.team_uid = "acme-engine"; sup.outbox_root = work / "outbox"
sup.task_show = lambda task_id: retry_task
sup.validate_result_ref = lambda value, task_value: True
sup.task_event = lambda *args, **kwargs: subprocess.CompletedProcess(args, 75, stdout="", stderr="")
sup.apply_intent_file(retry_path, {"attempt_id":retry_attempt, "task_id":task["task_id"], "run_id":task["run_id"]})
check("the fifth transient failure across restart becomes apply_exhausted", any(r.get("event") == "intents.tainted" and r.get("attempt_id") == retry_attempt and r.get("reason") == "apply_exhausted" for r in sup.records), True)
check("apply exhaustion raises one engine alarm", sum(r.get("event") == "alarm.sent" and r.get("kind") == "intent_apply_exhausted" and r.get("attempt_id") == retry_attempt for r in sup.records), 1)
retry_path.write_text("changed\n", encoding="utf-8"); retry_path.chmod(0o600)
sup.scan_intents()
check("re-planted tainted bytes are discarded without a second alarm", sum(r.get("event") == "alarm.sent" and r.get("kind") == "intent_apply_exhausted" and r.get("attempt_id") == retry_attempt for r in sup.records), 1)
check("re-planted tainted bytes are journalled once as replay", sum(r.get("event") == "intents.tainted_replay" and r.get("attempt_id") == retry_attempt for r in sup.records), 1)

print(f"\n{passed} passed, {failed} failed")
raise SystemExit(failed != 0)
PY
