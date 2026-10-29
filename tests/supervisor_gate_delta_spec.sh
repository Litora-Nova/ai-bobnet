#!/usr/bin/env bash
# Adversarial unit pins for the root supervisor's child-controlled boundaries.
set -uo pipefail
ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/aib-supervisor-gate.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

python3 -I - "$ROOT" "$WORK" <<'PY'
import hashlib, json, os, stat, subprocess, sys
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
outbox.unlink()
fchown_calls = []
real_fchown = aib_supervisor.os.fchown
def recording_fchown(fd, uid, gid):
    fchown_calls.append((uid, gid))
    return real_fchown(fd, uid, gid)
aib_supervisor.os.fchown = recording_fchown
try:
    recreated = sup._append_outbox_line(b"safe line\n")
finally:
    aib_supervisor.os.fchown = real_fchown
check("a supervisor-created outbox inherits the directory group explicitly", (recreated, fchown_calls), (True, [(-1, team_outbox.stat().st_gid)]))

team_outbox.chmod(0o2770)
before_setgid = len(outbox.read_text(encoding="utf-8").splitlines())
sup.write_alarm("setgid_outbox")
check("a provisioned setgid team outbox accepts supervisor alarms", len(outbox.read_text(encoding="utf-8").splitlines()) - before_setgid, 1)
team_outbox.chmod(0o770)
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
check("the first rate-cap suppression is visible in the human outbox", "alarm:alarm_suppressed" in outbox.read_text(encoding="utf-8") and "kind:rate_probe" in outbox.read_text(encoding="utf-8"), True)

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
link_target = work / "intent-link-target"
link_target.write_text(json.dumps({"attempt_id":"acme-main-link","verb":"continue","task_id":task["task_id"],"summary":"must not follow"}) + "\n", encoding="utf-8")
link_target.chmod(0o600)
(intents / "acme-main-link.jsonl").symlink_to(link_target)
sup.apply_intent_file(intents / "acme-main-link.jsonl", invalid_context)
check("a symlinked intent is tainted without touching its valid target", "must not follow" in link_target.read_text(encoding="utf-8"), True)
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
for record in sup.records:
    if record.get("event") == "report.retry" and record.get("task_id") == pending_task["task_id"]:
        record["retry_at"] = "1970-01-01T00:00:00Z"
sup.scan_intents()
pending_text = (team_outbox / "outbox.md").read_text(encoding="utf-8") if (team_outbox / "outbox.md").exists() else ""
check("a failed report delivery remains pending and is retried by the scan", "task-report t-bbbbbbbbbbbb state done" in pending_text, True)
check("a retried report delivery is journalled complete", any(r.get("event") == "report.delivered" and r.get("task_id") == "t-bbbbbbbbbbbb" for r in sup.records), True)

bounded_task = {"task_id":"t-cccccccccccc", "run_id":"r-cccccccccccc", "owner":"human:operator"}
team_outbox.chmod(0o750)
before_attention = sum(r.get("event") == "attention" and r.get("message_id") == "task-report-t-cccccccccccc-acme-main-bounded" for r in sup.records)
sup._deliver_task_report(bounded_task, "acme-main-bounded", "done", "bounded retry", None)
for _ in range(20):
    sup.scan_intents()
after_attention = sum(r.get("event") == "attention" and r.get("message_id") == "task-report-t-cccccccccccc-acme-main-bounded" for r in sup.records)
retry_states = sum(r.get("event") == "report.retry" and r.get("message_id") == "task-report-t-cccccccccccc-acme-main-bounded" for r in sup.records)
check("twenty polls of an unsafe outbox record one bounded delivery failure", (after_attention - before_attention, retry_states), (1, 1))
alarm_status = []
sup.notify = lambda value: alarm_status.append(value)
sup.write_alarm("outbox_probe")
check("an alarm delivery failure records attention and a status notification", (
    sum(r.get("event") == "attention" and r.get("reason") == "alarm_failed" and r.get("kind") == "outbox_probe" for r in sup.records),
    alarm_status,
), (1, ["STATUS=alarm delivery failed: outbox_probe"]))
sup.notify = Supervisor.notify.__get__(sup, Supervisor)
team_outbox.chmod(0o770)

entry = intents / "odd-entry.jsonl"
entry.mkdir(); (entry / "keeps-directory-nonempty").write_text("x", encoding="utf-8")
sup.scan_intents(); sup.scan_intents(); sup.scan_intents()
check("a non-empty non-regular intent entry stays contained", entry.exists(), True)
check(
    "an unchanged non-regular intent entry is classified only once",
    sum(r.get("event") in {"intents.tainted", "intents.tainted_replay"} and r.get("attempt_id") == "odd-entry" for r in sup.records),
    1,
)

hidden_intents = aib / "intents-hidden"
intents.rename(hidden_intents)
outside_intents = work / "outside-intents"; outside_intents.mkdir(mode=0o700)
outside_attempt = outside_intents / "acme-main-outside.jsonl"
outside_attempt.write_text(json.dumps({"attempt_id":"acme-main-outside","verb":"continue","task_id":task["task_id"],"summary":"must stay outside"}) + "\n", encoding="utf-8"); outside_attempt.chmod(0o600)
intents.symlink_to(outside_intents, target_is_directory=True)
before_unsafe = sum(r.get("event") == "fs.unsafe" for r in sup.records)
sup.scan_intents(); sup.scan_intents()
check("a symlinked intents directory is journalled unsafe once", sum(r.get("event") == "fs.unsafe" for r in sup.records) - before_unsafe, 1)
check(
    "the supervisor does not access through a symlinked intents directory",
    "must stay outside" in outside_attempt.read_text(encoding="utf-8")
    and not any(r.get("attempt_id") == "acme-main-outside" for r in sup.records),
    True,
)
fs_alarm = outbox.read_text(encoding="utf-8")
check("the fixed intents path remains visible in an fs_unsafe alarm", "alarm:fs_unsafe" in fs_alarm and "path:.aib/intents" in fs_alarm, True)
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
sup._intent_retry = lambda path, attempt_id, reason, **kwargs: retry_calls.append((attempt_id, reason)) or False
lookup_path = intents / "acme-main-retry.jsonl"
lookup_path.write_text(json.dumps({"attempt_id":"acme-main-retry","verb":"continue","task_id":task["task_id"],"summary":"retry"}) + "\n", encoding="utf-8"); lookup_path.chmod(0o600)
check("a transient task lookup failure stays pending rather than counting as handled", sup.apply_intent_file(lookup_path, {"attempt_id":"acme-main-retry", "task_id":task["task_id"], "run_id":task["run_id"]}), False)
check("transient task lookup is not quarantined as context mismatch", retry_calls, [("acme-main-retry", "task_lookup")])

continuations = []
current_task = {
    **task, "team_uid":"acme-engine", "assignee":"acme-core", "state":"IN_PROGRESS",
    "owner":"human:operator", "budget":{"max_turns":8}, "assignments":2,
}
sup.task_show = lambda task_id: current_task
sup.validate_result_ref = lambda value, task_value: True
sup.task_event = lambda *args, **kwargs: subprocess.CompletedProcess(args, 0, stdout="", stderr="")
sup._persist_self_task_message = lambda task_value, ident, summary: continuations.append(ident) or True
sup._unlink_intent = lambda name: None
for attempt_id in ("acme-main-cont-one", "acme-main-cont-two"):
    candidate = intents / f"{attempt_id}.jsonl"
    candidate.write_text(json.dumps({"attempt_id":attempt_id,"verb":"continue","task_id":task["task_id"],"summary":"more"}) + "\n", encoding="utf-8"); candidate.chmod(0o600)
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
sup._apply_pending_intent = lambda *args, **kwargs: (_ for _ in ()).throw(OSError("git helper failed"))
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
retry_bytes = (json.dumps({
    "attempt_id":retry_attempt, "verb":"report", "task_id":task["task_id"],
    "state":"failed", "summary":"retry", "reason":"temporary",
}) + "\n").encode()
retry_path.write_bytes(retry_bytes); retry_path.chmod(0o600)
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
retry_path.write_bytes(retry_bytes); retry_path.chmod(0o600)
sup.scan_intents()
check("identical re-planted tainted bytes are discarded without a second alarm", sum(r.get("event") == "alarm.sent" and r.get("kind") == "intent_apply_exhausted" and r.get("attempt_id") == retry_attempt for r in sup.records), 1)
check("re-planted tainted bytes are journalled once as replay", sum(r.get("event") == "intents.tainted_replay" and r.get("attempt_id") == retry_attempt for r in sup.records), 1)

os.close(sup.lock_fd); os.close(sup.state_dir_fd)
hard_state = work / "hardening-state"; hard_state.mkdir(mode=0o700)
os.environ["STATE_DIRECTORY"] = str(hard_state)
hard = Supervisor(root, "acme-core")
hard.project_uid = "acme"; hard.team_uid = "acme-engine"; hard.uid = "acme-core"
hard.registry = {"projects":{"acme":{"mux_session":"acme"}}}
hard.outbox_root = work / "hardening-outbox"; hard.outbox_root.mkdir(mode=0o755)
hard_aib = hard_state / ".aib"; hard_intents = hard_aib / "intents"
hard_aib.mkdir(mode=0o700); hard_intents.mkdir(mode=0o700); (hard_state / ".aib-quarantine").mkdir(mode=0o700)
hard_task = {
    "task_id":"t-dddddddddddd", "run_id":"r-dddddddddddd", "team_uid":"acme-engine",
    "assignee":"acme-core", "state":"IN_PROGRESS", "owner":"human:operator",
    "budget":{"max_turns":8}, "assignments":1,
}
hard.task_show = lambda task_id: dict(hard_task)
hard.validate_result_ref = lambda value, task_value: True
hard._persist_self_task_message = lambda *args: True
hard_events = []
hard.task_event = lambda *args, **kwargs: hard_events.append((args, kwargs)) or subprocess.CompletedProcess(args, 0, stdout="", stderr="")

resolved_task = {**hard_task, "task_id":"t-111111111111", "run_id":"r-111111111111"}
exhausted_task = {**hard_task, "task_id":"t-222222222222", "run_id":"r-222222222222"}
retry_tasks = {resolved_task["task_id"]: resolved_task, exhausted_task["task_id"]: exhausted_task}
retry_nudges = []
hard.task_show = lambda task_id: dict(retry_tasks[task_id])
hard._persist_self_task_message = lambda task_value, ident, summary: retry_nudges.append((task_value["task_id"], ident, summary)) or True

resolved_attempt = "acme-retry-resolved"
resolved_path = hard_intents / f"{resolved_attempt}.jsonl"
resolved_path.write_text(json.dumps({
    "attempt_id":resolved_attempt, "verb":"report", "task_id":resolved_task["task_id"],
    "state":"done", "summary":"invalid reference", "result_ref":"file:missing",
}) + "\n", encoding="utf-8"); resolved_path.chmod(0o600)
hard.records.append({"event":"turn.attempt", "attempt_id":resolved_attempt, "task_id":resolved_task["task_id"], "run_id":resolved_task["run_id"], "requester":"human:operator"})
hard.records.append({"event":"intent.retry", "attempt_id":resolved_attempt, "n":1, "reason":"task_lookup"})
hard.validate_result_ref = lambda value, task_value: False
hard.task_event = lambda *args, **kwargs: subprocess.CompletedProcess(args, 0, stdout="", stderr="")
hard.scan_intents()
check("a reject-only retry resolution rechecks the missing report exactly once", (
    sum(task_id == resolved_task["task_id"] for task_id, _ident, _summary in retry_nudges),
    any(task_id == resolved_task["task_id"] and ident.endswith(".n.a1") and "invalid_result_ref" in summary for task_id, ident, summary in retry_nudges),
), (1, True))

exhausted_attempt = "acme-retry-exhausted"
exhausted_retry_path = hard_intents / f"{exhausted_attempt}.jsonl"
exhausted_retry_path.write_text(json.dumps({
    "attempt_id":exhausted_attempt, "verb":"continue", "task_id":exhausted_task["task_id"], "summary":"retry",
}) + "\n", encoding="utf-8"); exhausted_retry_path.chmod(0o600)
hard.records.append({"event":"turn.attempt", "attempt_id":exhausted_attempt, "task_id":exhausted_task["task_id"], "run_id":exhausted_task["run_id"], "requester":"human:operator"})
for n in range(1, 5):
    hard.records.append({"event":"intent.retry", "attempt_id":exhausted_attempt, "n":n, "reason":"stream_lock"})
hard.validate_result_ref = lambda value, task_value: True
hard.task_event = lambda *args, **kwargs: subprocess.CompletedProcess(args, 75, stdout="", stderr="")
hard.scan_intents()
check("an exhausted retry rechecks the missing report exactly once", sum(task_id == exhausted_task["task_id"] for task_id, _ident, _summary in retry_nudges), 1)

hard.task_show = lambda task_id: dict(hard_task)
hard.validate_result_ref = lambda value, task_value: True
hard._persist_self_task_message = lambda *args: True
hard.task_event = lambda *args, **kwargs: hard_events.append((args, kwargs)) or subprocess.CompletedProcess(args, 0, stdout="", stderr="")

many_pending = [f"acme-bulk-{n:04d}" for n in range(600)]
bulk_unfinished = {
    "ts":"2026-01-01T00:00:00Z", "sid":"provider-session", "msg_id":"task-bulk",
    "task_id":hard_task["task_id"], "run_id":hard_task["run_id"], "requester":"human:operator",
}
hard._pending_orphan_intents = lambda: list(many_pending)
hard._attempt_bindings = lambda: None
hard._adopt_orphan_attempt(bulk_unfinished, "local-bulk-record")
bulk_record = next(r for r in reversed(hard.records) if r.get("event") == "orphan.deferred" and r.get("local_attempt") == "local-bulk-record")
bulk_digest = hashlib.sha256("\n".join(many_pending).encode()).hexdigest()
check("an orphan deferral stores a bounded pending summary", (
    bulk_record.get("pending") == many_pending[:100], len(bulk_record.get("pending", [])),
    bulk_record.get("pending_count"), bulk_record.get("pending_sha256"),
), (True, 100, 600, bulk_digest))
hard.journal("orphan.exhausted", local_attempt="local-bulk-record")

remaining_pending = set(many_pending)
exhaustion_quarantine = []
hard._pending_orphan_intents = lambda: sorted(remaining_pending)
def bounded_quarantine(path, reason, alarm="security", **kwargs):
    exhaustion_quarantine.append(path.stem)
    remaining_pending.discard(path.stem)
hard._quarantine_intent = bounded_quarantine
hard._adopt_orphan_attempt(bulk_unfinished, "local-bulk-exhaustion", retry_n=4)
first_exhaustion_poll = len(exhaustion_quarantine)
hard._adopt_orphan_attempt(bulk_unfinished, "local-bulk-exhaustion", retry_n=5)
check("orphan exhaustion quarantines no more than the scan cap per poll", (
    first_exhaustion_poll, len(exhaustion_quarantine),
    sum(r.get("event") == "orphan.exhausted" and r.get("local_attempt") == "local-bulk-exhaustion" for r in hard.records),
), (500, 600, 1))

remaining_pending = set(many_pending)
exhaustion_quarantine.clear()
budget_record_count = len(hard.records)
hard._active_orphan_deferrals = lambda: {
    "local-bulk-a": {**bulk_unfinished, "n": 4},
    "local-bulk-b": {**bulk_unfinished, "n": 4},
}
hard._retry_deferred_orphans()
check("orphan exhaustion shares one scan cap across due deferrals", len(exhaustion_quarantine), 500)
del hard.records[budget_record_count:]
hard._active_orphan_deferrals = Supervisor._active_orphan_deferrals.__get__(hard, Supervisor)
hard._quarantine_intent = Supervisor._quarantine_intent.__get__(hard, Supervisor)
hard._pending_orphan_intents = Supervisor._pending_orphan_intents.__get__(hard, Supervisor)

deferred_attempt = "acme-deferred-one"
deferred_path = hard_intents / f"{deferred_attempt}.jsonl"
deferred_path.write_text(json.dumps({
    "attempt_id":deferred_attempt, "verb":"continue", "task_id":hard_task["task_id"], "summary":"resume safely",
}) + "\n", encoding="utf-8"); deferred_path.chmod(0o600)
bindings_ready = False; binding_calls = []
def deferred_bindings():
    binding_calls.append(bindings_ready)
    if not bindings_ready:
        return None
    return [{
        "attempt_id":deferred_attempt, "agent_uid":"acme-core", "session_id":"acme",
        "decided_at":hard.started_at, "decision":"allow", "running":False,
    }]
hard._attempt_bindings = deferred_bindings
unfinished = {
    "ts":"2026-01-01T00:00:00Z", "sid":"provider-session", "msg_id":"task-deferred",
    "task_id":hard_task["task_id"], "run_id":hard_task["run_id"], "requester":"human:operator",
}
hard._adopt_orphan_attempt(unfinished, "local-deferred")
hard.scan_intents(); hard.scan_intents()
check("a deferred orphan survives two polls without a foreign-attempt alarm", deferred_path.exists() and not any(r.get("event") == "intents.tainted" and r.get("attempt_id") == deferred_attempt for r in hard.records), True)
check("deferred orphan retry observes its persisted backoff", len(binding_calls), 1)
check("orphan deferral persists the local attempt and pending names", any(r.get("event") == "orphan.deferred" and r.get("local_attempt") == "local-deferred" and deferred_attempt in r.get("pending", []) for r in hard.records), True)
bindings_ready = True
for record in reversed(hard.records):
    if record.get("event") == "orphan.deferred" and record.get("local_attempt") == "local-deferred":
        record["retry_at"] = "1970-01-01T00:00:00Z"; break
hard.scan_intents()
check("a deferred orphan is later adopted and applied exactly once", (deferred_path.exists(), sum(r.get("event") == "intents.applied" and r.get("attempt_id") == deferred_attempt for r in hard.records)), (False, 1))
check("a recovered orphan never raises an intents-tainted alarm", sum(r.get("event") == "alarm.sent" and r.get("kind") == "intents_tainted" and r.get("attempt_id") == deferred_attempt for r in hard.records), 0)
check("adopted orphan bytes are closed before application", any(r.get("event") == "intents.closed" and r.get("attempt_id") == deferred_attempt and r.get("present") is True and len(str(r.get("sha256", ""))) == 64 for r in hard.records), True)

exhausted_attempt = "acme-deferred-exhausted"
exhausted_path = hard_intents / f"{exhausted_attempt}.jsonl"
exhausted_path.write_text(json.dumps({
    "attempt_id":exhausted_attempt, "verb":"continue", "task_id":hard_task["task_id"], "summary":"never bound",
}) + "\n", encoding="utf-8"); exhausted_path.chmod(0o600)
bindings_ready = False
hard._adopt_orphan_attempt(unfinished, "local-exhausted")
for _ in range(4):
    for record in reversed(hard.records):
        if record.get("event") == "orphan.deferred" and record.get("local_attempt") == "local-exhausted":
            record["retry_at"] = "1970-01-01T00:00:00Z"; break
    hard.scan_intents()
check("five failed orphan-binding attempts end as one keyed unbound attempt", not exhausted_path.exists() and any(r.get("event") == "attention" and r.get("reason") == "unbound_attempt" and r.get("local_attempt") == "local-exhausted" for r in hard.records), True)
check("an exhausted deferral is never relabelled foreign_attempt", any(r.get("event") == "intents.tainted" and r.get("attempt_id") == exhausted_attempt and r.get("reason") == "foreign_attempt" for r in hard.records), False)

mode_attempt = "acme-mode-replay"
mode_path = hard_intents / f"{mode_attempt}.jsonl"
mode_bytes = (json.dumps({"attempt_id":mode_attempt,"verb":"continue","task_id":hard_task["task_id"],"summary":"mode replay"}) + "\n").encode()
mode_path.write_bytes(mode_bytes); mode_path.chmod(0o644)
hard.records.append({"event":"turn.attempt", "attempt_id":mode_attempt, "task_id":hard_task["task_id"], "run_id":hard_task["run_id"], "requester":"human:operator"})
mode_present, mode_digest = hard._intent_snapshot(mode_attempt)
before_mode_events = len(hard_events)
hard.apply_intent_file(mode_path, hard.records[-1])
hard._close_intent_attempt(mode_attempt, mode_present, mode_digest)
mode_path.write_bytes(mode_bytes); mode_path.chmod(0o600)
hard.scan_intents()
check("an unsafe-mode attempt cannot be revived after close", len(hard_events) - before_mode_events, 0)
check("a replay of a tainted attempt is removed without a second security alarm", not mode_path.exists() and sum(r.get("event") == "alarm.sent" and r.get("kind") == "intents_tainted" and r.get("attempt_id") == mode_attempt for r in hard.records) == 1, True)

crash_attempt = "acme-crash-window"
crash_path = hard_intents / f"{crash_attempt}.jsonl"
crash_original = (json.dumps({"attempt_id":crash_attempt,"verb":"continue","task_id":hard_task["task_id"],"summary":"before crash"}) + "\n").encode()
crash_changed = (json.dumps({"attempt_id":crash_attempt,"verb":"continue","task_id":hard_task["task_id"],"summary":"after crash"}) + "\n").encode()
crash_path.write_bytes(crash_original); crash_path.chmod(0o600)
hard.records.append({"event":"turn.attempt", "attempt_id":crash_attempt, "task_id":hard_task["task_id"], "run_id":hard_task["run_id"], "requester":"human:operator"})
close_unfinished = getattr(hard, "_close_unclosed_attempts", None)
if close_unfinished is not None:
    close_unfinished()
crash_path.write_bytes(crash_changed); crash_path.chmod(0o600)
before_crash_events = len(hard_events)
hard.scan_intents()
check("startup closes a turn attempt left open by a crash", any(r.get("event") == "intents.closed" and r.get("attempt_id") == crash_attempt for r in hard.records), True)
check("bytes planted after the crash window are not applied", len(hard_events) - before_crash_events, 0)

swap_attempt = "acme-swap-window"
swap_path = hard_intents / f"{swap_attempt}.jsonl"
swap_original = (json.dumps({"attempt_id":swap_attempt,"verb":"continue","task_id":hard_task["task_id"],"summary":"ORIGINAL"}) + "\n").encode()
swap_changed = (json.dumps({"attempt_id":swap_attempt,"verb":"continue","task_id":hard_task["task_id"],"summary":"SWAPPED"}) + "\n").encode()
swap_path.write_bytes(swap_original); swap_path.chmod(0o600)
hard.records.append({"event":"turn.attempt", "attempt_id":swap_attempt, "task_id":hard_task["task_id"], "run_id":hard_task["run_id"], "requester":"human:operator"})
swap_present, swap_digest = hard._intent_snapshot(swap_attempt); hard._close_intent_attempt(swap_attempt, swap_present, swap_digest)
real_task_show = hard.task_show; swapped = False
def swapping_task_show(task_id):
    global swapped
    if not swapped:
        replacement = hard_intents / ".swap-replacement"
        replacement.write_bytes(swap_changed); replacement.chmod(0o600); replacement.replace(swap_path)
        swapped = True
    return real_task_show(task_id)
hard.task_show = swapping_task_show
before_swap_records = len(hard.records)
hard.scan_intents()
swap_summaries = [record.get("summary") for record in hard.records[before_swap_records:] if record.get("event") == "intent.ledger"]
check("the bytes hashed at apply are the same bytes passed to the ledger", ("ORIGINAL" in swap_summaries, "SWAPPED" in swap_summaries), (True, False))
hard.task_show = real_task_show

close_attempt = "acme-close-before-apply"
close_path = hard_intents / f"{close_attempt}.jsonl"
close_path.write_text(json.dumps({
    "attempt_id":close_attempt, "verb":"continue", "task_id":hard_task["task_id"], "summary":"close first",
}) + "\n", encoding="utf-8"); close_path.chmod(0o600)
close_context = {"event":"turn.attempt", "attempt_id":close_attempt, "task_id":hard_task["task_id"], "run_id":hard_task["run_id"], "requester":"human:operator"}
hard.records.append(close_context)
before_close_apply = len(hard.records)
hard._apply_pending_intent(close_attempt, close_context, close_attempt=True)
close_events = hard.records[before_close_apply:]
closed_index = next((n for n, record in enumerate(close_events) if record.get("event") == "intents.closed"), None)
ledger_index = next((n for n, record in enumerate(close_events) if record.get("event") == "intent.ledger"), None)
check("turn-end intent bytes are closed before the first ledger apply", closed_index is not None and ledger_index is not None and closed_index < ledger_index, True)

without_task_attempt = "acme-without-task"
without_task_path = hard_intents / f"{without_task_attempt}.jsonl"
without_task_path.write_text(json.dumps({
    "attempt_id":without_task_attempt, "verb":"continue", "task_id":hard_task["task_id"], "summary":"unbound",
}) + "\n", encoding="utf-8"); without_task_path.chmod(0o600)
hard.records.append({"event":"turn.attempt", "attempt_id":without_task_attempt, "run_id":hard_task["run_id"], "requester":"human:operator"})
before_without_task_alarms = sum(r.get("event") == "alarm.sent" for r in hard.records)
before_without_task_retries = sum(r.get("event") == "intent.retry" for r in hard.records)
hard.scan_intents()
check("an intent without task context is attention-only and never retried", (
    sum(r.get("event") == "intents.tainted" and r.get("attempt_id") == without_task_attempt and r.get("reason") == "intent_without_task" for r in hard.records),
    sum(r.get("event") == "attention" and r.get("attempt_id") == without_task_attempt and r.get("reason") == "intent_without_task" for r in hard.records),
    sum(r.get("event") == "alarm.sent" for r in hard.records) - before_without_task_alarms,
    sum(r.get("event") == "intent.retry" for r in hard.records) - before_without_task_retries,
), (1, 1, 0, 0))

undeliverable_task = {"task_id":"t-eeeeeeeeeeee", "run_id":"r-eeeeeeeeeeee", "owner":"human:operator"}
hard_team_outbox = hard.outbox_root / hard.team_uid
hard_team_outbox.chmod(0o750)
hard._deliver_task_report(undeliverable_task, "acme-undeliverable", "done", "cannot deliver", None)
undeliverable_id = "task-report-t-eeeeeeeeeeee-acme-undeliverable"
for _ in range(9):
    for record in reversed(hard.records):
        if record.get("event") == "report.retry" and record.get("message_id") == undeliverable_id:
            record["retry_at"] = "1970-01-01T00:00:00Z"; break
    hard._retry_pending_reports()
for _ in range(3):
    hard._retry_pending_reports()
server_path = hard.outbox_root / "_server" / "outbox.md"
server_text = server_path.read_text(encoding="utf-8") if server_path.exists() else ""
check("ten report failures stop retrying and emit one server alarm", (
    sum(r.get("event") == "report.undeliverable" and r.get("message_id") == undeliverable_id for r in hard.records),
    server_text.count("alarm:task_delivery_failed"),
    sum(r.get("event") == "attention" and r.get("message_id") == undeliverable_id and r.get("reason") == "outbox_unsafe" for r in hard.records),
), (1, 1, 1))
hard_team_outbox.chmod(0o770)

waiting_message = "task-report-t-dddddddddddd-acme-waiting"
hard.records.append({
    "event":"report.pending", "message_id":waiting_message, "task_id":hard_task["task_id"],
    "run_id":hard_task["run_id"], "requester":"human:operator", "attempt_id":"acme-waiting",
    "state":"done", "summary":"waiting", "result_ref":None,
})
hard.records.append({"event":"report.retry", "message_id":waiting_message, "n":1, "reason":"outbox_unsafe", "retry_at":"2999-01-01T00:00:00Z"})
hard.task_command = lambda *args: subprocess.CompletedProcess(args, 0, stdout=json.dumps({"tasks":[hard_task]}), stderr="")
hard.open_messages = lambda: []
before_missing = sum(r.get("event") == "task.no_report" and r.get("task_id") == hard_task["task_id"] for r in hard.records)
hard.sweep_missing_reports()
check("a report waiting for its delivery retry is not treated as missing", sum(r.get("event") == "task.no_report" and r.get("task_id") == hard_task["task_id"] for r in hard.records) - before_missing, 0)

cap_calls = []
real_quarantine = hard._quarantine_intent
def count_quarantine(path, reason, alarm="security", **kwargs):
    cap_calls.append(path.name)
    path.unlink(missing_ok=True)
hard._quarantine_intent = count_quarantine
for n in range(501):
    (hard_intents / f"junk!{n:03d}").write_text("x", encoding="utf-8")
hard.scan_intents()
first_poll = len(cap_calls)
hard.scan_intents()
check("intent scanning processes at most five hundred entries per poll and resumes next poll", (first_poll, len(cap_calls)), (500, 501))
hard._quarantine_intent = real_quarantine

taint_index_builder = getattr(hard, "_tainted_intent_index", None)
if taint_index_builder is None:
    check("one taint index is built for an intent scan", False, True)
else:
    taint_index_builds = []
    def counting_taint_index():
        taint_index_builds.append(True)
        return taint_index_builder()
    hard._tainted_intent_index = counting_taint_index
    for name in ("bad-index-one", "bad-index-two"):
        (hard_intents / name).write_text("x", encoding="utf-8")
    hard.scan_intents()
    check("one taint index is built for an intent scan", len(taint_index_builds), 1)
    hard._tainted_intent_index = taint_index_builder

source = (root / "lib" / "aib_supervisor.py").read_text(encoding="utf-8")
board_replace = next(line for line in source.splitlines() if "os.replace(temporary, \"board.json\"" in line)
check("board replacement is descriptor-relative on both sides", "src_dir_fd=" in board_replace and "dst_dir_fd=" in board_replace, True)
append_body = source.split("def _append_outbox_line", 1)[1].split("\n    def ", 1)[0]
check("outbox files are authorized by exact mode and provisioned group, not writer uid", "0o660" in append_body and "info.st_gid" in append_body and "or info.st_uid" not in append_body, True)
run_body = source.split("def run(self)", 1)[1].split("\n    def ", 1)[0]
close_startup_index = run_body.find("self._close_unclosed_attempts()")
scan_startup_index = run_body.find("self.scan_intents()")
check("startup closes unfinished attempts before scanning intents", close_startup_index >= 0 and scan_startup_index >= 0 and close_startup_index < scan_startup_index, True)

negative_quarantine = []
hard._quarantine_intent = lambda path, reason, alarm="security", **kwargs: negative_quarantine.append((path.stem, reason, alarm))
hard._pending_orphan_intents = lambda: ["acme-running"]
hard._attempt_bindings = lambda: [
    {"attempt_id":"acme-running", "agent_uid":"acme-core", "session_id":"acme", "decided_at":hard.started_at, "decision":"allow", "running":True},
]
hard._adopt_orphan_attempt(unfinished, "local-running-binding")
hard._pending_orphan_intents = lambda: ["acme-other-session"]
hard._attempt_bindings = lambda: [
    {"attempt_id":"acme-other-session", "agent_uid":"acme-core", "session_id":"other", "decided_at":hard.started_at, "decision":"allow", "running":False},
]
hard._adopt_orphan_attempt(unfinished, "local-foreign-session-binding")
check("running and foreign-session orphan bindings remain unbound", sorted(negative_quarantine), [("acme-other-session", "unbound_attempt", "attention"), ("acme-running", "unbound_attempt", "attention")])

print(f"\n{passed} passed, {failed} failed")
raise SystemExit(failed != 0)
PY
