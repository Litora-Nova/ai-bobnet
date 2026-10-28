#!/usr/bin/env bash
# D1b supervisor integration: task pickup, intent apply, crash recovery,
# report/continue budgets, taint alarms, and root-only ledger relay.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/fixtures/sup_harness.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/aib-supervisor-d1b.XXXXXX")
if [ -z "${AIB_KEEP_TEST_TMP:-}" ]; then
  trap sup_cleanup EXIT
else
  printf 'D1b fixture retained at %s\n' "$WORK" >&2
fi
TASK_ROOT="$WORK/tasks"

task_world(){
  local tag=$1
  sup_world "$tag"
  TASK_ROOT="$W/tasks"; mkdir -p "$TASK_ROOT/acme/bodies" "$STATE/.aib/intents"
  chmod 2750 "$TASK_ROOT/acme" "$TASK_ROOT/acme/bodies"; chmod 700 "$STATE/.aib" "$STATE/.aib/intents"
  : > "$TASK_ROOT/acme/tasks.events"; : > "$TASK_ROOT/acme/tasks.events.lock"
  chmod 640 "$TASK_ROOT/acme/tasks.events" "$TASK_ROOT/acme/tasks.events.lock"
  git -C "$HOMEDIR" init -q -b main
  git -C "$HOMEDIR" -c user.name=Fixture -c user.email=fixture@example.invalid commit --allow-empty -qm base
  cat > "$ENGINE/registry.json" <<JSON
{ "schema_version": 5,
  "providers": { "acme": { "adapter": "$SRC_ROOT/adapters/codex", "cap_sandbox": "workspace-write", "cap_tier": "t2", "cap_effort": "high", "cap_timeout": "30" } },
  "projects": { "acme": { "home": "$HOMEDIR", "standup_dir": "$STANDUP", "mux_session": "acme", "data_class": "internal", "provider": "acme", "model": "example", "effort": "low", "base_branch": "main" } },
  "teams": { "acme-engine": { "project": "acme", "model": "example" } },
  "agents": {
    "acme-lead": { "mode":"supervised", "lead":"true", "project":"acme", "team_uid":"acme-engine", "profile":"lead", "clearance":"t2" },
    "acme-core": { "mode":"supervised", "project":"acme", "team_uid":"acme-engine", "profile":"worker", "clearance":"t2" },
    "acme-sib": { "mode":"supervised", "project":"acme", "team_uid":"acme-engine", "profile":"worker", "clearance":"t2" }
  } }
JSON
  cat > "$W/fakes/launch-agent" <<'FAKE'
#!/usr/bin/env bash
w=$(cd -P "$(dirname "$0")/.." && pwd); n=$(($(cat "$w/calls.n" 2>/dev/null || echo 0)+1)); echo "$n" > "$w/calls.n"
while [ $# -gt 0 ]; do case "$1" in --as) uid=$2; shift 2;; --cwd) cwd=$2; shift 2;; --session) shift 2;; --supervised|-) shift;; *) shift;; esac; done
cat > "$w/prompts/$n"
attempt="acme-main-$n"; printf '%s\n' "$attempt" > "${AIB_ATTEMPT_META_PATH:?}"
action=$(sed -n "${n}p" "$w/actions" 2>/dev/null); [ -n "$action" ] || action=none
task=$(sed -n 's/.*\[task \(t-[0-9a-f]*\) .*/\1/p' "$w/prompts/$n" | head -1)
run=$(sed -n 's/.* run \(r-[0-9a-f]*\) .*/\1/p' "$w/prompts/$n" | head -1)
case "$action" in
  done)
    branch="aib/acme-engine/$task"; sha=$(git -C "$cwd" rev-parse HEAD)
    HOME="$w/state/$uid" PATH="$w/engine/bin:$PATH" AIB_ATTEMPT_ID="$attempt" task-intent report "$task" done --result "git:$branch@$sha" -- 'done' ;;
  badref)
    sha=$(git -C "$cwd" rev-parse HEAD)
    HOME="$w/state/$uid" PATH="$w/engine/bin:$PATH" AIB_ATTEMPT_ID="$attempt" task-intent report "$task" done --result "git:aib/acme-engine/t-aaaaaaaaaaaa@$sha" -- 'forged' ;;
  orphan)
    branch="aib/acme-engine/$task"; sha=$(git -C "$cwd" rev-parse HEAD)
    HOME="$w/state/$uid" PATH="$w/engine/bin:$PATH" AIB_ATTEMPT_ID="$attempt" task-intent report "$task" done --result "git:$branch@$sha" -- 'orphan result'
    echo $$ > "$w/orphan.pid"; : > "$w/orphan.ready"; sleep 30 ;;
  continue) HOME="$w/state/$uid" PATH="$w/engine/bin:$PATH" AIB_ATTEMPT_ID="$attempt" task-intent continue "$task" -- 'continue' ;;
  delegate)
    printf '{"attempt_id":"%s","verb":"delegate","run_id":"%s","to":"acme-sib","title":"forged child","body":"do it","source_msg_id":"%s"}\n' "$attempt" "$run" "msg-$n" > "$w/state/$uid/.aib/intents/$attempt.jsonl"
    chmod 600 "$w/state/$uid/.aib/intents/$attempt.jsonl" ;;
  turnfail) printf 'provider failed\n'; exit 1 ;;
esac
printf 'turn %s\n' "$n"
FAKE
  chmod +x "$W/fakes/launch-agent"
  printf '#!/usr/bin/env bash\nprintf "root:root\\n"\n' > "$W/fakes/task-identity"
  chmod +x "$W/fakes/task-identity"
  : > "$W/actions"
}

tcmd(){ env AIB_TEST_SEAMS=1 AIB_TASK_ROOT="$TASK_ROOT" AIBOBNET_REGISTRY="$ENGINE/registry.json" AIB_IDENTITY_CMD="$W/fakes/task-identity" "$ENGINE/bin/task" "$@"; }
new_run(){ tcmd run-create --project acme --team acme-engine --actor-type human --actor-id operator --via ctl:1 --requester human:operator --causation-id "$1-run" --run-id "$2" >/dev/null; }
new_task(){
  local key=$1 run=$2; printf 'body\n' > "$W/body-$key"
  TASK=$(tcmd create --project acme --team acme-engine --actor-type human --actor-id operator --via ctl:2 --requester human:operator \
    --causation-id "$key-create" --run-id "$run" --intent-n 1 --source-msg-id "msg-$key" --assignee acme-core \
    --title "$key" --body-ref "msg:$key" --body-file "$W/body-$key" | sed -n 's/^task_id=//p')
}
task_json(){ tcmd show --project acme "$1" 2>/dev/null; }
task_state(){ task_json "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])'; }
task_is(){ [ "$(task_state "$1")" = "$2" ]; }
send_task(){ m_send "$1" "[task $2 run $3 requester human:operator] $4"; }
start_d1b(){ start_sup acme-core AIB_TEST_SEAMS=1 AIB_TASK_ROOT="$TASK_ROOT" AIB_IDENTITY_CMD="$W/fakes/task-identity" AIB_OUTBOX_ROOT="$W/outbox" AIB_TEST_D1B_PAUSE_AFTER_LEDGER="${1:-}"; }
event_count(){ python3 -I - "$TASK_ROOT/acme/tasks.events" "$1" <<'PY'
import json,sys
from pathlib import Path
sys.path.insert(0, str(Path.cwd()/"lib"))
from attempts_fold import scan
_, rows=scan(Path(sys.argv[1])); print(sum(json.loads(raw).get("event_type")==sys.argv[2] for _,raw in rows))
PY
}
event_ge(){ [ "$(event_count "$1")" -ge "$2" ]; }
journal_ge(){ [ "$(jcount "$1")" -ge "$2" ]; }
outbox_has(){ grep -q "$1" "$W/outbox/acme-engine/outbox.md" 2>/dev/null; }
fail_message(){ env -i PATH="$PATH" HOME="$W" "$ENGINE4/bin/run-agent" acme-core -- "$ENGINE4/bin/message" fail "$1" 'wakeup exhausted after 5 attempts' >/dev/null; }

# A ledger-bound task is the worker lane ahead of unrelated peer mail.
task_world lanes; new_run lanes r-999999999999; new_task lanes r-999999999999
printf 'done\n' > "$W/actions"; m_send ordinary-peer 'ordinary peer mail'; send_task task-lane "$TASK" r-999999999999 build
start_d1b; wait_for 12 test -s "$W/prompts/1"; first_prompt=$(cat "$W/prompts/1"); stop_sup
has 'the ledger-bound worker task lane precedes unrelated peer mail' "$first_prompt" "[task $TASK"

# End-to-end human override: service starts, agent reports a branch-contained SHA,
# and the human requester receives one outbox result.
task_world done; new_run done r-111111111111; new_task done r-111111111111
printf 'done\n' > "$W/actions"; send_task task-done "$TASK" r-111111111111 build
start_d1b; wait_for 12 task_is "$TASK" DONE; done_state=$(task_state "$TASK"); stop_sup
eq 'human override reaches DONE with a git result' "$done_state" DONE
has 'human requester gets a persisted outbox report' "$(cat "$W/outbox/acme-engine/outbox.md" 2>/dev/null)" "task-report $TASK state done"
seqs=$(awk '{print $1}' "$TASK_ROOT/acme/tasks.events" | paste -sd, -)
eq 'every task-stream line has a contiguous seq' "$seqs" '1,2,3,4'
eq 'supervisor records the broker attempt then applies it' "$(jcount turn.attempt)|$(jcount intents.applied)" '1|1'

# Kill -9 after the ledger append but before notification. Startup scan finishes
# the same intent and the idempotent delivery id yields exactly one report.
task_world crash; new_run crash r-222222222222; new_task crash r-222222222222
printf 'done\n' > "$W/actions"; send_task task-crash "$TASK" r-222222222222 build
PAUSE="$W/after-ledger"; start_d1b "$PAUSE"; wait_for 12 test -e "$PAUSE"; crash_sup
eq 'fault point was reached after the report ledger append' "$(task_state "$TASK")" DONE
start_d1b; wait_for 12 outbox_has "task-report $TASK state done"; stop_sup
eq 'restart sends exactly one requester report' "$(grep -c "task-report $TASK state done" "$W/outbox/acme-engine/outbox.md")" 1
eq 'crash recovery does not append a second task.reported' "$(event_count task.reported)" 1

task_world orphan; new_run orphan r-121212121212; new_task orphan r-121212121212
printf 'orphan\n' > "$W/actions"; send_task task-orphan "$TASK" r-121212121212 build
start_d1b; wait_for 12 test -e "$W/orphan.ready"; crash_sup; kill -9 "$(cat "$W/orphan.pid")" 2>/dev/null || true
start_d1b; wait_for 12 task_is "$TASK" DONE; state=$(task_state "$TASK"); stop_sup
eq 'orphan recovery applies the broker-bound pending intent' "$state|$(jcount intents.applied)|$(grep -c '"class":"orphan_gone"' "$JOURNAL")" 'DONE|1|1'

# Authority and taint: the worker cannot delegate, and a file not tied to its own
# terminal attempt is quarantined and alarmed.
task_world reject; new_run reject r-333333333333; new_task reject r-333333333333
printf 'delegate\n' > "$W/actions"; send_task task-reject "$TASK" r-333333333333 build
printf '{"attempt_id":"foreign-main-1","verb":"continue","task_id":"%s","summary":"x"}\n' "$TASK" > "$STATE/.aib/intents/foreign-main-1.jsonl"
start_d1b; wait_for 12 event_ge task.rejected 1; wait_for 12 journal_ge intents.tainted 1; stop_sup
has 'worker delegate is durably rejected as not_lead' "$(tcmd list --project acme --all)" '"reason":"not_lead"'
eq 'foreign intent is tainted once' "$(jcount intents.tainted)" 1
has 'foreign intent raises an outbox alarm' "$(cat "$W/outbox/acme-engine/outbox.md" 2>/dev/null)" 'alarm:intents_tainted'

task_world badref; new_run badref r-888888888888; new_task badref r-888888888888
printf 'badref\n' > "$W/actions"; send_task task-badref "$TASK" r-888888888888 build
start_d1b; wait_for 12 event_ge task.rejected 1; stop_sup
has 'a forged result ref is durably rejected' "$(tcmd list --project acme --all)" '"reason":"invalid_result_ref"'

# Two reportless turns block no_report. Continue is persisted, progress alone
# consumes turns, and the ninth request becomes service-blocked turn_budget.
task_world noreport; new_run noreport r-444444444444; new_task noreport r-444444444444
printf 'none\nnone\n' > "$W/actions"; send_task task-none "$TASK" r-444444444444 build
start_d1b; wait_for 15 task_is "$TASK" BLOCKED; state=$(task_state "$TASK"); reason=$(task_json "$TASK" | python3 -c 'import json,sys; print(json.load(sys.stdin)["last_reason"])'); stop_sup
eq 'two missing reports become BLOCKED no_report' "$state|$reason" 'BLOCKED|no_report'
has 'the first missing report is a persisted self nudge' "$(cat "$INBOX")" "id:$TASK.n1"

task_world turnfail; new_run turnfail r-666666666666; new_task turnfail r-666666666666
printf 'turnfail\nturnfail\nturnfail\n' > "$W/actions"; send_task task-turnfail "$TASK" r-666666666666 build
start_d1b; wait_for 15 task_is "$TASK" FAILED; state=$(task_state "$TASK"); reason=$(task_json "$TASK" | python3 -c 'import json,sys; print(json.load(sys.stdin)["last_reason"])'); msg_state=$(m_state task-turnfail); stop_sup
eq 'three provider failures dead-letter the message and fail the task' "$state|$reason|$msg_state" 'FAILED|turn_failed|FAILED'

task_world delivery; new_run delivery r-777777777777; new_task delivery r-777777777777
send_task task-delivery "$TASK" r-777777777777 build; fail_message task-delivery
start_d1b; wait_for 12 task_is "$TASK" CANCELLED; state=$(task_state "$TASK"); reason=$(task_json "$TASK" | python3 -c 'import json,sys; print(json.load(sys.stdin)["last_reason"])'); stop_sup
eq 'assignment DLQ becomes service-owned delivery_failed cancellation' "$state|$reason" 'CANCELLED|delivery_failed'
has 'delivery failure raises the durable team alarm' "$(cat "$W/outbox/acme-engine/outbox.md" 2>/dev/null)" 'alarm:task_delivery_failed'

task_world budget; new_run budget r-555555555555; new_task budget r-555555555555
for _ in $(seq 1 9); do printf 'continue\n' >> "$W/actions"; done
send_task task-budget "$TASK" r-555555555555 build
start_d1b; wait_for 20 task_is "$TASK" BLOCKED; json=$(task_json "$TASK"); stop_sup
eq 'ninth continue becomes BLOCKED turn_budget after eight progress turns' "$(printf '%s' "$json" | python3 -c 'import json,sys; x=json.load(sys.stdin); print("{}|{}|{}".format(x["state"],x["last_reason"],x["turns"]))')" 'BLOCKED|turn_budget|8'
eq 'continue messages are persisted and bounded' "$(grep -c "id:$TASK.c.*state:PERSISTED" "$INBOX")" 8

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
