#!/usr/bin/env bash
# ai-bobnet — lead-delegation D0: one commit primitive, stream-specific contracts.
#
# The main-stream fixture was captured from base main 3352c35 before the commit
# primitive was generalized. It pins the complete framed bytes, not only parsed
# fields, so compatibility includes field order, nulls, CRC, and record length.
set -uo pipefail

SRC_ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
# shellcheck source=lib/aibobnet.sh
. "$SRC_ROOT/lib/aibobnet.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-event-streams.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
no() { fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2' want '$3')"; fi; }
zero() { if [ "$2" -eq 0 ]; then ok "$1"; else no "$1 (got rc $2)"; fi; }
nonzero() { if [ "$2" -ne 0 ]; then ok "$1"; else no "$1 (got rc 0)"; fi; }
has() { case "$2" in *"$3"*) ok "$1";; *) no "$1 ('$2' lacks '$3')";; esac; }
missing() { case "$2" in *"$3"*) no "$1 ('$2' contains '$3')";; *) ok "$1";; esac; }

MAIN_ENV=$'project_uid=acme\nactor_type=service\nactor_id=launch-agent\nagent_uid=acme-worker\nteam_uid=acme-core\nsession_id=aib-acme-worker\noccurred_at=2026-10-27T12:34:56.123456789Z'
DECIDED_PAYLOAD='{"decision":"allow","code":0}'
ENDED_PAYLOAD='{"exit":{"class":"ok","stage":"provider","code":null,"signal":null,"group_empty":true}}'

commit_main_pair() {
  local path="$1" explicit="${2:-0}" decided
  if [ "$explicit" -eq 1 ]; then
    aib_event_commit "$path" "$path.lock" main attempt.decided "$MAIN_ENV" "$DECIDED_PAYLOAD"
    decided="$AIB_EVENT_COMMIT_EVENT_ID"
    aib_event_commit "$path" "$path.lock" main attempt.ended "$MAIN_ENV" "$ENDED_PAYLOAD" "$decided"
  else
    # Compatibility call shape used by every existing caller on base main.
    aib_event_commit "$path" "$path.lock" attempt.decided "$MAIN_ENV" "$DECIDED_PAYLOAD"
    decided="$AIB_EVENT_COMMIT_EVENT_ID"
    aib_event_commit "$path" "$path.lock" attempt.ended "$MAIN_ENV" "$ENDED_PAYLOAD" "$decided"
  fi
}

# Legacy callers and the new explicit-main call must both produce the captured bytes.
commit_main_pair "$WORK/legacy-main.events"
cmp -s "$SRC_ROOT/tests/fixtures/event_commit_main.golden" "$WORK/legacy-main.events"
zero 'legacy main commits remain byte-identical to base main' "$?"

commit_main_pair "$WORK/explicit-main.events" 1
cmp -s "$SRC_ROOT/tests/fixtures/event_commit_main.golden" "$WORK/explicit-main.events"
zero 'explicit main commits match the same byte golden' "$?"

# The tasks root is per-project, defaults to /var/lib/aib/tasks, and is test-seam overridable.
task_paths="$({ AIB_TASK_ROOT="$WORK/task-root"; aib_task_event_stream_paths acme; printf '%s\n%s\n' "$AIB_TASK_EVENT_FILE" "$AIB_TASK_EVENT_LOCK"; })"
eq 'tasks stream path uses the seam root and project uid' "$(printf '%s\n' "$task_paths" | sed -n '1p')" "$WORK/task-root/acme/tasks.events"
eq 'tasks lock is beside its stream' "$(printf '%s\n' "$task_paths" | sed -n '2p')" "$WORK/task-root/acme/tasks.events.lock"
default_task_path="$({ unset AIB_TASK_ROOT; aib_task_event_stream_paths acme; printf '%s' "$AIB_TASK_EVENT_FILE"; })"
eq 'tasks stream root defaults to /var/lib/aib/tasks' "$default_task_path" '/var/lib/aib/tasks/acme/tasks.events'

for invalid_project_uid in '../x' 'Acme'; do
  invalid_path_error="$(AIB_TASK_ROOT="$WORK/task-root" aib_task_event_stream_paths "$invalid_project_uid" 2>&1)"
  nonzero "tasks stream path refuses project uid '$invalid_project_uid'" "$?"
done
invalid_path_error="$(AIB_TASK_ROOT="$WORK/task-root" aib_task_event_stream_paths '' 2>&1)"
nonzero 'tasks stream path refuses an empty project uid' "$?"
invalid_path_error="$(AIB_TASK_ROOT=$'bad\nroot' aib_task_event_stream_paths acme 2>&1)"
nonzero 'tasks stream path refuses an AIB_TASK_ROOT line break' "$?"
has 'tasks stream path reports the AIB_TASK_ROOT line-break reason' "$invalid_path_error" 'invalid AIB_TASK_ROOT (contains a line break)'

TASK_ENV=$'project_uid=acme\nactor_type=service\nactor_id=supervisor:acme-dev1\nteam_uid=acme-core\nrun_id=r-0123456789ab\ntask_id=t-abcdef012345\ncausation_id=acme-main-41\noccurred_at=2026-10-27T12:35:00.000000000Z'
TASKS="$WORK/tasks.events"

aib_event_commit "$TASKS" "$TASKS.lock" tasks task.created "$TASK_ENV" '{}'
eq 'tasks event id uses the tasks stream name' "$AIB_EVENT_COMMIT_EVENT_ID" 'acme-tasks-1'
task_json="$(sed -n '1s/^[0-9]* [0-9]* [0-9]* //p' "$TASKS")"
eq 'tasks record keeps caller run_id' "$(aib_event_field "$task_json" run_id)" 'r-0123456789ab'
eq 'tasks record keeps caller task_id' "$(aib_event_field "$task_json" task_id)" 't-abcdef012345'
eq 'tasks record keeps caller causation_id' "$(aib_event_field "$task_json" causation_id)" 'acme-main-41'
eq 'tasks correlation_id is its run_id' "$(aib_event_field "$task_json" correlation_id)" 'r-0123456789ab'
eq 'tasks record has no attempt identity' "$(aib_event_field "$task_json" attempt_id)" ''
has 'tasks record encodes attempt_id as raw JSON null' "$(sed -n '1p' "$TASKS")" '"attempt_id":null'

RUN_ENV="$(printf '%s\n' "$TASK_ENV" | sed '/^task_id=/d')"
aib_event_commit "$WORK/run.events" "$WORK/run.events.lock" tasks run.requested "$RUN_ENV" '{}'
run_json="$(sed -n '1s/^[0-9]* [0-9]* [0-9]* //p' "$WORK/run.events")"
eq 'run events do not require a task_id' "$(aib_event_field "$run_json" task_id)" ''

# Reserve the complete D0 type vocabulary, including the future review gate pair.
reserved_types=(
  run.requested run.started run.closed
  task.created task.started task.reported task.cancelled task.reassigned
  task.reopened task.overdue task.rejected task.review_passed task.review_failed
)
for event_type in "${reserved_types[@]}"; do
  reserve_stream="$WORK/reserved-${event_type//./-}.events"
  aib_event_commit "$reserve_stream" "$reserve_stream.lock" tasks "$event_type" "$TASK_ENV" '{}' >/dev/null 2>&1
  zero "tasks stream reserves $event_type" "$?"
done

( aib_event_commit "$WORK/wrong-tasks.events" "$WORK/wrong-tasks.lock" tasks attempt.decided "$TASK_ENV" '{}' ) >/dev/null 2>&1
nonzero 'tasks stream refuses attempt.* types' "$?"
wrong_main_error="$(aib_event_commit "$WORK/wrong-main.events" "$WORK/wrong-main.lock" main task.created "$TASK_ENV" '{}' 2>&1)"
nonzero 'main stream refuses task.* types' "$?"
has 'main stream refusal reports the stream-type reason' "$wrong_main_error" "event_type 'task.created' is not allowed in stream 'main'"
( aib_event_commit "$WORK/unknown.events" "$WORK/unknown.lock" audit task.created "$TASK_ENV" '{}' ) >/dev/null 2>&1
nonzero 'unknown stream names are refused' "$?"
( aib_event_commit "$WORK/main-causation-id.events" "$WORK/main-causation-id.lock" main attempt.decided "$MAIN_ENV"$'\ncausation_id=forged' '{}' ) >/dev/null 2>&1
nonzero 'main stream refuses a caller-supplied causation_id' "$?"
( aib_event_commit "$WORK/tasks-attempt-id.events" "$WORK/tasks-attempt-id.lock" tasks task.created "$TASK_ENV"$'\nattempt_id=forged' '{}' ) >/dev/null 2>&1
nonzero 'tasks stream refuses a caller-supplied attempt_id' "$?"
( aib_event_commit "$WORK/tasks-correlation-id.events" "$WORK/tasks-correlation-id.lock" tasks task.created "$TASK_ENV"$'\ncorrelation_id=forged' '{}' ) >/dev/null 2>&1
nonzero 'tasks stream refuses a caller-supplied correlation_id' "$?"
( aib_event_commit "$WORK/tasks-decided-id.events" "$WORK/tasks-decided-id.lock" tasks task.created "$TASK_ENV" '{}' 'acme-main-1' ) >/dev/null 2>&1
nonzero 'tasks stream refuses a decided_id argument' "$?"

for required in run_id task_id causation_id; do
  bad_env="$(printf '%s\n' "$TASK_ENV" | sed "/^${required}=/d")"
  ( aib_event_commit "$WORK/missing-$required.events" "$WORK/missing-$required.lock" tasks task.created "$bad_env" '{}' ) >/dev/null 2>&1
  nonzero "task events require caller $required" "$?"
done

# A torn tasks tail is uncommitted: truncate it in place and reuse the next seq.
printf '2 999 999 {"torn":true' >> "$TASKS"
aib_event_commit "$TASKS" "$TASKS.lock" tasks task.started "$TASK_ENV" '{}'
eq 'tasks writer resumes at seq 2 after a torn tail' "$AIB_EVENT_COMMIT_SEQ" '2'
missing 'tasks writer quarantines torn tail bytes' "$(sed -n '1,$p' "$TASKS")" '"torn":true'
aib_event_scan "$TASKS" >/dev/null
eq 'tasks stream is intact after torn-tail quarantine' "$AIB_EVENT_SCAN_STATUS" 'ok'

# Lock contention is a transient infrastructure outcome, never a task rejection.
LOCKED="$WORK/locked-tasks.events"
exec {holdfd}>>"$LOCKED.lock"
flock -x "$holdfd"
( AIBOBNET_EVENT_LOCK_TIMEOUT=0.01 aib_event_commit "$LOCKED" "$LOCKED.lock" tasks task.created "$TASK_ENV" '{}' ) >/dev/null 2>&1
lock_rc=$?
flock -u "$holdfd"
exec {holdfd}>&-
eq 'tasks lock timeout returns the transient rc 75' "$lock_rc" '75'
if [ -e "$LOCKED" ]; then locked_lines="$(wc -l < "$LOCKED")"; else locked_lines=0; fi
eq 'tasks lock timeout writes no event' "$locked_lines" '0'

# The inherited-lock seam is internal to the task transaction writer. It accepts
# only the tasks stream, the exact lock inode, and a descriptor whose exclusive
# lock was already held before the commit primitive was entered.
HELD="$WORK/held-tasks.events"
exec {heldfd}>>"$HELD.lock"
flock -x "$heldfd"
AIB_EVENT_HELD_LOCK_FD="$heldfd" aib_event_commit "$HELD" "$HELD.lock" tasks task.created "$TASK_ENV" '{}'
eq 'held-lock task commit succeeds' "$AIB_EVENT_COMMIT_SEQ" 1
( flock -n "$HELD.lock" -c true ) >/dev/null 2>&1
eq 'held-lock commit leaves the caller lock held' "$?" 1
flock -u "$heldfd"; exec {heldfd}>&-

MAIN_HELD="$WORK/main-held.events"
exec {mainheldfd}>>"$MAIN_HELD.lock"; flock -x "$mainheldfd"
( AIB_EVENT_HELD_LOCK_FD="$mainheldfd" aib_event_commit "$MAIN_HELD" "$MAIN_HELD.lock" main attempt.decided "$MAIN_ENV" "$DECIDED_PAYLOAD" ) >/dev/null 2>&1
eq 'held-lock seam is refused for the main stream' "$?" 2
eq 'refused main held-lock call appends nothing' "$(test -e "$MAIN_HELD" && wc -l < "$MAIN_HELD" || printf 0)" 0
flock -u "$mainheldfd"; exec {mainheldfd}>&-

WRONG_HELD="$WORK/wrong-held.events"; : > "$WORK/unrelated.lock"
exec {wrongfd}>>"$WORK/unrelated.lock"; flock -x "$wrongfd"
( AIB_EVENT_HELD_LOCK_FD="$wrongfd" aib_event_commit "$WRONG_HELD" "$WRONG_HELD.lock" tasks task.created "$TASK_ENV" '{}' ) >/dev/null 2>&1
eq 'held-lock seam refuses a descriptor for another inode' "$?" 2
flock -u "$wrongfd"; exec {wrongfd}>&-

UNHELD="$WORK/unheld-tasks.events"
exec {unheldfd}>>"$UNHELD.lock"
( AIB_EVENT_HELD_LOCK_FD="$unheldfd" aib_event_commit "$UNHELD" "$UNHELD.lock" tasks task.created "$TASK_ENV" '{}' ) >/dev/null 2>&1
eq 'held-lock seam refuses an unlocked matching descriptor' "$?" 2
eq 'unlocked inherited descriptor appends nothing' "$(test -e "$UNHELD" && wc -l < "$UNHELD" || printf 0)" 0
exec {unheldfd}>&-

for bad_fd in nope 99999; do
  BAD_HELD="$WORK/bad-held-$bad_fd.events"
  ( AIB_EVENT_HELD_LOCK_FD="$bad_fd" aib_event_commit "$BAD_HELD" "$BAD_HELD.lock" tasks task.created "$TASK_ENV" '{}' ) >/dev/null 2>&1
  eq "held-lock seam refuses descriptor '$bad_fd'" "$?" 2
done

total=$((pass+fail))
printf '\n%d checks: %d ok / %d fail\n' "$total" "$pass" "$fail"
[ "$fail" -eq 0 ]
