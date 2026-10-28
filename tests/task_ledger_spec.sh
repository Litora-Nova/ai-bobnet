#!/usr/bin/env bash
# ai-bobnet — authoritative task ledger contract.
#
# Writes are serialized as one transaction: fold -> authority -> transition ->
# aib_event_commit(tasks). Domain refusals are durable task.rejected events and rc
# 77. Boundary-format failures are rc 64 and never reach the stream. The caller is
# kernel-derived; --actor-* is only the claim it attests next to.
set -uo pipefail

ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/aib-task-ledger.XXXXXX")
case "$WORK" in /*) ;; *) printf 'FAIL - mktemp did not return an absolute path\n' >&2; exit 1;; esac
trap 'rm -rf "$WORK"' EXIT
pass=0 fail=0
ok(){ pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
no(){ fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; }
eq(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2' want '$3')"; fi; }
has(){ case "$2" in *"$3"*) ok "$1";; *) no "$1 ('$2' lacks '$3')";; esac; }

TASK_ROOT="$WORK/tasks"
[ -n "$TASK_ROOT" ] && case "$TASK_ROOT" in /*) ;; *) printf 'FAIL - task root must be absolute\n' >&2; exit 1;; esac
REG="$WORK/registry.json"
ID="$WORK/identity"
cat > "$REG" <<JSON
{"schema_version":5,
 "projects":{"acme":{"home":"$WORK/project","standup_dir":"$WORK/standup","mux_session":"acme","provider":"stub","model":"m","effort":"low"}},
 "teams":{
   "acme-engine":{"project":"acme","delegation":{"max_open":"2","max_new_per_turn":"4","max_tasks_per_run":"20","max_assignments_per_task":"4","max_depth":"1","task_deadline_s":"14400","max_turns_per_task":"8"}},
   "acme-other":{"project":"acme","delegation":{"max_open":"2","max_new_per_turn":"4","max_tasks_per_run":"20","max_assignments_per_task":"4","max_depth":"1","task_deadline_s":"14400","max_turns_per_task":"8"}}
 },
 "agents":{
   "acme-lead":{"project":"acme","team_uid":"acme-engine","mode":"supervised","lead":"true","profile":"lead","clearance":"t2"},
   "acme-dev1":{"project":"acme","team_uid":"acme-engine","mode":"supervised","lead":"false","profile":"dev","clearance":"t2"},
   "acme-dev2":{"project":"acme","team_uid":"acme-engine","mode":"supervised","lead":"false","profile":"dev","clearance":"t2"},
   "acme-other-lead":{"project":"acme","team_uid":"acme-other","mode":"supervised","lead":"true","profile":"lead","clearance":"t2"},
   "acme-other":{"project":"acme","team_uid":"acme-other","mode":"supervised","lead":"false","profile":"dev","clearance":"t2"}
 }}
JSON
cat > "$ID" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${TASK_CALLER:-root:root}"
SH
chmod +x "$ID"
mkdir -p "$TASK_ROOT/acme/bodies"
chmod 2750 "$TASK_ROOT/acme" "$TASK_ROOT/acme/bodies"
: > "$TASK_ROOT/acme/tasks.events"; : > "$TASK_ROOT/acme/tasks.events.lock"
chmod 640 "$TASK_ROOT/acme/tasks.events" "$TASK_ROOT/acme/tasks.events.lock"
EVENTS="$TASK_ROOT/acme/tasks.events"
FX="$ROOT/tests/fixtures/task_events.py"
export AIB_TEST_SEAMS=1 AIBOBNET_REGISTRY="$REG" AIB_TASK_ROOT="$TASK_ROOT" AIB_IDENTITY_CMD="$ID"
export TASK_CALLER=root:root

run(){ RC=0; OUT=$("$ROOT/bin/task" "$@" 2>"$WORK/err") || RC=$?; ERR=$(cat "$WORK/err"); }
run_timeout(){ RC=0; OUT=$(timeout 2 "$ROOT/bin/task" "$@" 2>"$WORK/err") || RC=$?; ERR=$(cat "$WORK/err"); }
write_for(){
  local team=$1 verb=$2 actor_type=$3 actor_id=$4 cause=$5 requester
  shift 5
  case "$actor_type" in
    agent) run "$verb" --project acme --team "$team" --actor-type "$actor_type" --actor-id "$actor_id" --via "intent:$cause" --causation-id "$cause" "$@" ;;
    human)
      requester="human:$actor_id"; case "$actor_id" in gateway:*) requester="$actor_id";; esac
      run "$verb" --project acme --team "$team" --actor-type "$actor_type" --actor-id "$actor_id" --via ctl:1 --requester "$requester" --causation-id "$cause" "$@"
      ;;
    *) run "$verb" --project acme --team "$team" --actor-type "$actor_type" --actor-id "$actor_id" --causation-id "$cause" "$@" ;;
  esac
}
write(){ local verb=$1 actor_type=$2 actor_id=$3 cause=$4; shift 4; write_for acme-engine "$verb" "$actor_type" "$actor_id" "$cause" "$@"; }
count(){ python3 -I "$FX" count "$EVENTS" "$1"; }
field(){ python3 -I "$FX" field "$EVENTS" "$1" "$2" "$3"; }
state(){ run show --project acme "$1"; python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])' <<<"$OUT"; }
json_field(){ python3 -c 'import json,sys; value=json.load(sys.stdin); exec("\n".join("value = value[%r]" % p for p in sys.argv[1].split("."))); print(json.dumps(value,separators=(",",":")) if isinstance(value,(dict,list)) else value)' "$1" <<<"$2"; }

# The installed writer is root-only. Human and gateway authority is relayed from
# a kernel-attested control request; agent authority is relayed from an intent.
RC=0; ERR=$(env -u AIB_TEST_SEAMS "$ROOT/bin/task" run-create --project acme --team acme-engine --actor-type human --actor-id operator --causation-id euid-gate --run-id malformed 2>&1) || RC=$?
eq 'the production euid gate runs before malformed request validation' "$RC|$ERR" '77|ai-bobnet: caller_unauthorized'
write run-create human operator ctl-run-1 --run-id r-000000000001
eq 'root relays a human control request that creates a queued run' "$RC|$(count run.requested)|$(state r-000000000001)" '0|1|QUEUED'

before=$(wc -l < "$EVENTS")
export TASK_CALLER=role:acme-dev1
run run-create --project acme --team acme-engine --actor-type agent --actor-id acme-lead --via intent:role-spoof --causation-id role-spoof --run-id r-000000000002
eq 'a role caller cannot claim the lead or grow rejection noise' "$RC|$ERR|$(wc -l < "$EVENTS")" "77|ai-bobnet: caller_unauthorized|$before"
export TASK_CALLER=human:operator
run run-create --project acme --team acme-engine --actor-type human --actor-id operator --via ctl:2 --requester human:operator --causation-id direct-human --run-id r-000000000003
eq 'a direct human caller cannot write the root-owned ledger' "$RC|$ERR|$(wc -l < "$EVENTS")" "77|ai-bobnet: caller_unauthorized|$before"

export TASK_CALLER=root:root
run run-create --project acme --team acme-engine --actor-type human --actor-id operator --causation-id missing-relay --run-id r-000000000003
eq 'root cannot claim a human without a control relay' "$RC|$(field task.rejected -1 payload.reason)" '77|caller_actor_mismatch'
write run-create human gateway:gw ctl-run-gw --run-id r-000000000004
eq 'root relays a gateway control request only with the bound requester' "$RC" 0

BODY="$WORK/body.md"; printf 'Implement the parser.\nSecond paragraph.\n' > "$BODY"
write create agent acme-lead attempt-11 --run-id r-000000000001 --intent-n 1 --source-msg-id msg-source-1 --assignee acme-dev1 --title 'Parser' --body-ref msg:delivery-1 --body-file "$BODY"
T1=${OUT#task_id=}
eq 'team lead creates an assigned task with deterministic id' "$RC|$T1|$(state "$T1")" "0|$T1|ASSIGNED"
eq 'task id is the documented token form' "$(expr "$T1" : 't-[0-9a-f]\{12\}$')" 14
eq 'sidecar is stable content with safe mode' "$(cat "$TASK_ROOT/acme/bodies/$T1.md")|$(stat -c %a "$TASK_ROOT/acme/bodies/$T1.md")" "$(cat "$BODY")|640"
eq 'payload records root caller, intent relay, and claimed actor' "$(field task.created 0 payload.caller)|$(field task.created 0 payload.via)|$(field task.created 0 actor_id)" 'root:root|intent:attempt-11|acme-lead'

created_before=$(count task.created)
run create --project acme --team acme-engine --actor-type agent --actor-id acme-lead --causation-id relay-agent --run-id r-000000000001 --intent-n 2 --source-msg-id msg-relay-agent --assignee acme-dev2 --title Relay --body-ref msg:relay-agent --body-file "$BODY"
eq 'an agent claim without an intent relay is refused without creating a task' "$RC|$(field task.rejected -1 payload.reason)|$(count task.created)" "77|caller_actor_mismatch|$created_before"
run cancel --project acme --team acme-engine --actor-type human --actor-id operator --requester human:operator --causation-id relay-human --run-id r-000000000001 --task-id "$T1" --reason forged
eq 'a human claim without a control relay is refused without changing task state' "$RC|$(field task.rejected -1 payload.reason)|$(state "$T1")" '77|caller_actor_mismatch|ASSIGNED'
run start --project acme --team acme-engine --actor-type service --actor-id supervisor:acme-dev1 --via ctl:3 --causation-id relay-service --run-id r-000000000001 --task-id "$T1"
eq 'a service claim carrying relay fields is refused without changing task state' "$RC|$(field task.rejected -1 payload.reason)|$(state "$T1")" '77|caller_actor_mismatch|ASSIGNED'
run cancel --project acme --team acme-engine --actor-type human --actor-id gateway:gw --via ctl:4 --requester gateway:other --causation-id relay-gateway --run-id r-000000000001 --task-id "$T1" --reason forged
eq 'a gateway claim with a foreign requester is refused without changing task state' "$RC|$(field task.rejected -1 payload.reason)|$(state "$T1")" '77|caller_actor_mismatch|ASSIGNED'

write create agent acme-lead attempt-11 --run-id r-000000000001 --intent-n 1 --source-msg-id msg-source-1 --assignee acme-dev1 --title 'Parser' --body-ref msg:delivery-1 --body-file "$BODY"
eq 'same attempt and intent derives the same id and dedupes source+assignee visibly' "$RC|${OUT#task_id=}|$(field task.rejected -1 payload.reason)" "77|$T1|duplicate"

write create agent acme-dev1 attempt-worker --run-id r-000000000001 --intent-n 2 --source-msg-id msg-worker --assignee acme-dev2 --title 'No' --body-ref msg:no --body-file "$BODY"
eq 'worker cannot delegate' "$RC|$(field task.rejected -1 payload.reason)" '77|not_lead'
write create human operator ctl-human-create --run-id r-000000000001 --intent-n 3 --source-msg-id msg-human --assignee acme-dev2 --title 'Override' --body-ref msg:human --body-file "$BODY"
T2=${OUT#task_id=}; eq 'human override can create' "$RC|$(state "$T2")" '0|ASSIGNED'

# Service start, assignee reports, engine reasons, and every state transition.
export TASK_CALLER=root:root
write start service supervisor:acme-dev1 turn-1 --run-id r-000000000001 --task-id "$T1"
eq 'assignee supervisor starts ASSIGNED task' "$RC|$(state "$T1")" '0|IN_PROGRESS'
write report agent acme-dev2 turn-spoof --run-id r-000000000001 --task-id "$T1" --state done --result-ref msg:bad
eq 'non-assignee report is refused' "$RC|$(field task.rejected -1 payload.reason)" '77|not_assignee'
write report agent acme-dev1 turn-2 --run-id r-000000000001 --task-id "$T1" --state progress --reason working
eq 'progress is an IN_PROGRESS self-transition' "$RC|$(state "$T1")" '0|IN_PROGRESS'
write report agent acme-dev1 turn-3 --run-id r-000000000001 --task-id "$T1" --state blocked --reason dependency
eq 'assignee can report BLOCKED' "$RC|$(state "$T1")" '0|BLOCKED'

export TASK_CALLER=root:root
write reopen agent acme-lead attempt-reopen --run-id r-000000000001 --task-id "$T1" --assignee acme-dev1
eq 'lead reopens BLOCKED to ASSIGNED' "$RC|$(state "$T1")" '0|ASSIGNED'
export TASK_CALLER=root:root
write start service supervisor:acme-dev1 turn-4 --run-id r-000000000001 --task-id "$T1"
write report service supervisor:acme-dev1 turn-5 --run-id r-000000000001 --task-id "$T1" --state failed --reason turn_failed
eq 'assignee service may report an engine FAILED reason' "$RC|$(state "$T1")" '0|FAILED'
export TASK_CALLER=root:root
write reopen human operator ctl-reopen --run-id r-000000000001 --task-id "$T1" --assignee acme-dev1
eq 'human override reopens FAILED while assignment budget remains' "$RC|$(state "$T1")" '0|ASSIGNED'

# Gate/depth checks run with spare capacity so their reasons cannot be masked by
# the team-open limit.
write cancel human operator ctl-cancel-2 --run-id r-000000000001 --task-id "$T2" --reason superseded
eq 'human cancels any nonterminal task' "$RC|$(state "$T2")" '0|CANCELLED'
write create human operator ctl-gated --run-id r-000000000001 --intent-n 4 --source-msg-id msg-gated --assignee acme-dev1 --title Gate --body-ref msg:gate --body-file "$BODY" --gate code
eq 'the current writer refuses task.created gate != none' "$RC|$(field task.rejected -1 payload.reason)" '77|gate_not_available'
write create human operator ctl-deep --run-id r-000000000001 --intent-n 5 --source-msg-id msg-deep --assignee acme-dev1 --title Deep --body-ref msg:deep --body-file "$BODY" --depth 2
eq 'depth above one is refused' "$RC|$(field task.rejected -1 payload.reason)" '77|max_depth'

# Limits are registry-overridable: fill the open-team cap after the isolated
# gate/depth checks; per-run total and per-task assignment caps remain folded facts.
write create human operator ctl-fill-open --run-id r-000000000001 --intent-n 6 --source-msg-id msg-fill --assignee acme-dev2 --title Fill --body-ref msg:fill --body-file "$BODY"
T3=${OUT#task_id=}; eq 'a valid task fills the spare open slot' "$RC|$(state "$T3")" '0|ASSIGNED'
write create human operator ctl-over-open --run-id r-000000000001 --intent-n 6 --source-msg-id msg-over --assignee acme-dev1 --title Over --body-ref msg:over --body-file "$BODY"
eq 'team max_open override is enforced' "$RC|$(field task.rejected -1 payload.reason)" '77|max_open'
write cancel human operator ctl-cancel-3 --run-id r-000000000001 --task-id "$T3" --reason superseded

# Planted sidecar links are refused and never followed.
TARGET="$WORK/target"; printf sentinel > "$TARGET"
DERIVED=$(printf '%s' 'attempt-symlink:7' | sha256sum | cut -c1-12)
ln -s "$TARGET" "$TASK_ROOT/acme/bodies/t-$DERIVED.md"
write create human operator attempt-symlink --run-id r-000000000001 --intent-n 7 --source-msg-id msg-link --assignee acme-dev2 --title Link --body-ref msg:link --body-file "$BODY"
eq 'planted sidecar symlink is visibly refused without touching target' "$RC|$(cat "$TARGET")|$(field task.rejected -1 payload.reason)" '77|sentinel|unsafe_body_sidecar'

# Identifier validation is pre-commit, including causation IDs.
before=$(wc -l < "$EVENTS")
for tuple in 'run-create --run-id ../bad --causation-id ctl-x' 'cancel --run-id r-000000000001 --task-id ../bad --causation-id ctl-x' 'cancel --run-id r-000000000001 --task-id t-000000000001 --causation-id ../bad'; do
  # shellcheck disable=SC2086
  run $tuple --project acme --team acme-engine --actor-type human --actor-id operator
  [ "$RC" -eq 64 ] || no "invalid identifier '$tuple' is rc 64"
done
eq 'invalid ids never reach aib_event_commit' "$(wc -l < "$EVENTS")" "$before"

# Lock decision: after BLOCKED, concurrent cancel/reassign yields one transition
# and one rejection; a stale request cannot become a second transition.
export TASK_CALLER=root:root
write start service supervisor:acme-dev1 turn-race-1 --run-id r-000000000001 --task-id "$T1"
write report agent acme-dev1 turn-race-2 --run-id r-000000000001 --task-id "$T1" --state blocked --reason wait
export TASK_CALLER=root:root
exec 9>>"$TASK_ROOT/acme/tasks.events.lock"
flock -x 9
run show --project acme "$T1"; EXPECTED_STATE_SEQ=$(json_field state_seq "$OUT")
race_transitions_before=$(( $(count task.cancelled) + $(count task.reassigned) ))
( write cancel human operator ctl-race-c --run-id r-000000000001 --task-id "$T1" --expect-seq "$EXPECTED_STATE_SEQ" --reason race; printf '%s\n' "$RC" > "$WORK/race-c" ) & p1=$!
( write assign human operator ctl-race-a --run-id r-000000000001 --task-id "$T1" --expect-seq "$EXPECTED_STATE_SEQ" --assignee acme-dev2; printf '%s\n' "$RC" > "$WORK/race-a" ) & p2=$!
sleep 0.2
flock -u 9
exec 9>&-
wait "$p1" "$p2"
race_rc="$(cat "$WORK/race-c") $(cat "$WORK/race-a")"
case "$race_rc" in '0 76'|'76 0') ok 'cancel versus reassign has exactly one winner under lock';; *) no "cancel versus reassign rc ($race_rc)";; esac
eq 'race emits one accepted transition and one visible refusal' "$(( $(count task.cancelled) + $(count task.reassigned) - race_transitions_before ))|$(field task.rejected -1 payload.reason)" '1|concurrent_update'

# Fold rejects an injected semantically invalid event but retains deterministic
# state. list/show are both fresh replays, not a status store.
cat > "$WORK/invalid.json" <<JSON
{"event_id":"acme-tasks-999","event_type":"task.reported","occurred_at":"2026-10-27T12:00:00Z","actor_type":"agent","actor_id":"acme-dev2","project_uid":"acme","team_uid":"acme-engine","agent_uid":"acme-dev2","session_id":null,"run_id":"r-000000000001","task_id":"$T2","gate_id":null,"grant_id":null,"effect_id":null,"attempt_id":null,"correlation_id":"r-000000000001","causation_id":"injected-1","schema_version":2,"payload":{"caller":"root:root","via":"intent:injected-1","state":"done","result_ref":"msg:forged","reason":null}}
JSON
python3 -I "$FX" append "$EVENTS" "$WORK/invalid.json" 999
run list --project acme --all
eq 'fold exposes the exact semantically invalid record count' "$(json_field invalid "$OUT")|$(json_field invalid_events "$OUT")" '1|[{"reason":"invalid_report","seq":999}]'
snapshot=$OUT
run list --project acme --all
eq 'fold replay is deterministic and equals live read' "$OUT" "$snapshot"
rejection_summary=$(json_field rejections "$OUT" | python3 -c 'import json,sys; rows=json.load(sys.stdin); print("%s|%s|%s" % (len(rows), rows[-1]["reason"], rows[-1]["requested_type"]))')
case "$rejection_summary" in "$(count task.rejected)|concurrent_update|task.cancelled"|"$(count task.rejected)|concurrent_update|task.reassigned") ok 'task.rejected events remain exactly visible in list output';; *) no "task.rejected visibility summary ($rejection_summary)";; esac

# The future gate fixture is isolated because current creation blocks it.
GATE_ROOT="$WORK/gate/tasks"; mkdir -p "$GATE_ROOT/acme/bodies"; : > "$GATE_ROOT/acme/tasks.events"; : > "$GATE_ROOT/acme/tasks.events.lock"
chmod 2750 "$GATE_ROOT/acme" "$GATE_ROOT/acme/bodies"; chmod 640 "$GATE_ROOT/acme/tasks.events" "$GATE_ROOT/acme/tasks.events.lock"
GATE_EVENTS="$GATE_ROOT/acme/tasks.events"
python3 -I "$ROOT/lib/task_ledger.py" fixture-gated "$GATE_EVENTS" "$REG"
AIB_TASK_ROOT="$GATE_ROOT" run show --project acme t-aaaaaaaaaaaa
eq 'future gate seam folds reported done to REVIEW' "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])' <<<"$OUT")" REVIEW

# Isolated ledger exercises the remaining closed transitions and limits without
# coupling their setup to the lock-race corpus above.
LIMIT_ROOT="$WORK/limits/tasks"; mkdir -p "$LIMIT_ROOT/acme/bodies"; : > "$LIMIT_ROOT/acme/tasks.events"; : > "$LIMIT_ROOT/acme/tasks.events.lock"
chmod 2750 "$LIMIT_ROOT/acme" "$LIMIT_ROOT/acme/bodies"; chmod 640 "$LIMIT_ROOT/acme/tasks.events" "$LIMIT_ROOT/acme/tasks.events.lock"
export AIB_TASK_ROOT="$LIMIT_ROOT"; EVENTS="$LIMIT_ROOT/acme/tasks.events"
export TASK_CALLER=root:root
python3 - "$REG" <<'PY'
import json,sys
p=sys.argv[1]; r=json.load(open(p)); r['teams']['acme-engine']['delegation']['max_tasks_per_run']='3'
with open(p,'w') as f: json.dump(r,f,separators=(',',':'))
PY
write run-create human operator ctl-limit-run --run-id r-100000000001
write create human operator limit-create-1 --run-id r-100000000001 --intent-n 1 --source-msg-id msg-limit-1 --assignee acme-dev1 --title Done --body-ref msg:limit-1 --body-file "$BODY"; LDONE=${OUT#task_id=}
export TASK_CALLER=root:root
write start service supervisor:acme-dev1 limit-start-1 --run-id r-100000000001 --task-id "$LDONE"
write report agent acme-dev1 limit-report-1 --run-id r-100000000001 --task-id "$LDONE" --state done --result-ref msg:done
eq 'reported done reaches DONE when gate is none' "$RC|$(state "$LDONE")" '0|DONE'
export TASK_CALLER=root:root
for n in 2 3; do
  write create human operator "limit-create-$n" --run-id r-100000000001 --intent-n "$n" --source-msg-id "msg-limit-$n" --assignee acme-dev1 --title "Limit $n" --body-ref "msg:limit-$n" --body-file "$BODY"
  lid=${OUT#task_id=}; write cancel human operator "limit-cancel-$n" --run-id r-100000000001 --task-id "$lid" --reason limit
done
write create human operator limit-create-4 --run-id r-100000000001 --intent-n 4 --source-msg-id msg-limit-4 --assignee acme-dev1 --title 'Limit 4' --body-ref msg:limit-4 --body-file "$BODY"
eq 'per-run task limit override counts terminal tasks too' "$RC|$(field task.rejected -1 payload.reason)" '77|max_tasks_per_run'

# This run needs room to isolate the lower per-task assignment cap. The prior
# assertion has already pinned the per-run override and its terminal accounting.
python3 - "$REG" <<'PY'
import json,sys
p=sys.argv[1]; r=json.load(open(p)); r['teams']['acme-engine']['delegation']['max_tasks_per_run']='20'
with open(p,'w') as f: json.dump(r,f,separators=(',',':'))
PY

write run-create human operator ctl-assign-run --run-id r-100000000002
write create human operator assign-create --run-id r-100000000002 --intent-n 1 --source-msg-id msg-assign --assignee acme-dev1 --title Assign --body-ref msg:assign --body-file "$BODY"; LA=${OUT#task_id=}
for round in 1 2 3; do
  assignee=acme-dev1; [ "$round" -eq 2 ] && assignee=acme-dev2
  export TASK_CALLER=root:root
  write start service "supervisor:$assignee" "assign-start-$round" --run-id r-100000000002 --task-id "$LA"
  write report agent "$assignee" "assign-block-$round" --run-id r-100000000002 --task-id "$LA" --state blocked --reason wait
  if [ "$round" -eq 1 ]; then
    eq 'a run with only a blocked active frontier derives BLOCKED' "$(state r-100000000002)" BLOCKED
  fi
  export TASK_CALLER=root:root
  next=acme-dev2; [ "$assignee" = acme-dev2 ] && next=acme-dev1
  write assign human operator "assign-$round" --run-id r-100000000002 --task-id "$LA" --assignee "$next"
done
export TASK_CALLER=root:root
write start service supervisor:acme-dev2 assign-start-4 --run-id r-100000000002 --task-id "$LA"
write report agent acme-dev2 assign-block-4 --run-id r-100000000002 --task-id "$LA" --state blocked --reason wait
export TASK_CALLER=root:root
write assign human operator assign-over --run-id r-100000000002 --task-id "$LA" --assignee acme-dev1
eq 'per-task assignment limit override is enforced' "$RC|$(field task.rejected -1 payload.reason)" '77|max_assignments_per_task'

write run-create human operator ctl-service-run --run-id r-100000000003
write create human operator delivery-create --run-id r-100000000003 --intent-n 1 --source-msg-id msg-delivery --assignee acme-dev1 --title Delivery --body-ref msg:delivery --body-file "$BODY"; LS=${OUT#task_id=}
export TASK_CALLER=root:root
write overdue service supervisor:acme-lead overdue-1 --run-id r-100000000003 --task-id "$LS"
eq 'lead supervisor may mark a nonterminal task overdue without changing work state' "$RC|$(state "$LS")" '0|ASSIGNED'
export TASK_CALLER=root:root
write cancel service supervisor:acme-dev1 delivery-failed-1 --run-id r-100000000003 --task-id "$LS" --reason delivery_failed
eq 'assignee supervisor may cancel ASSIGNED after delivery failure' "$RC|$(state "$LS")" '0|CANCELLED'
export TASK_CALLER=root:root
write run-close agent acme-lead close-run-1 --run-id r-100000000003 --outcome completed --summary-ref msg:summary
eq 'current team lead may close a run' "$RC|$(state r-100000000003)" '0|COMPLETED'

# Registry authority is read after lock acquisition: an old lead waiting on the
# lock must be rejected if the lead flag moves before the commit snapshot.
export TASK_CALLER=root:root
write run-create human operator ctl-switch-run --run-id r-100000000004
write create human operator switch-create --run-id r-100000000004 --intent-n 1 --source-msg-id msg-switch --assignee acme-dev1 --title Switch --body-ref msg:switch --body-file "$BODY"; LSW=${OUT#task_id=}
export TASK_CALLER=root:root
write start service supervisor:acme-dev1 switch-start --run-id r-100000000004 --task-id "$LSW"
write report agent acme-dev1 switch-block --run-id r-100000000004 --task-id "$LSW" --state blocked --reason wait
exec 9>>"$LIMIT_ROOT/acme/tasks.events.lock"
flock -x 9
( write assign agent acme-lead old-lead --run-id r-100000000004 --task-id "$LSW" --assignee acme-dev1; printf '%s|%s\n' "$RC" "$ERR" > "$WORK/old-lead" ) & old_lead_pid=$!
sleep 0.2
python3 - "$REG" <<'PY'
import json,sys
p=sys.argv[1]; r=json.load(open(p)); r['agents']['acme-lead']['lead']='false'; r['agents']['acme-dev2']['lead']='true'
with open(p,'w') as f: json.dump(r,f,separators=(',',':'))
PY
flock -u 9
exec 9>&-
wait "$old_lead_pid"
eq 'waiting old lead is refused from the commit-time registry snapshot' "$(cut -d'|' -f1 "$WORK/old-lead")|$(field task.rejected -1 payload.reason)" '77|not_lead'
write assign agent acme-dev2 new-lead --run-id r-100000000004 --task-id "$LSW" --assignee acme-dev1
eq 'new lead is authorized from the commit-time registry snapshot' "$RC|$(state "$LSW")" '0|ASSIGNED'
python3 - "$REG" <<'PY'
import json,sys
p=sys.argv[1]; r=json.load(open(p)); r['agents']['acme-lead']['lead']='true'; r['agents']['acme-dev2']['lead']='false'
with open(p,'w') as f: json.dump(r,f,separators=(',',':'))
PY

# Isolate audit regressions from the transition corpus above. Every task root is
# an absolute child of mktemp, so a missing seam can never provision the repo.
AUDIT_ROOT="$WORK/audit/tasks"
case "$AUDIT_ROOT" in /*) ;; *) no 'audit task root is absolute'; exit 1;; esac
mkdir -p "$AUDIT_ROOT/acme/bodies"
chmod 2750 "$AUDIT_ROOT/acme" "$AUDIT_ROOT/acme/bodies"
: > "$AUDIT_ROOT/acme/tasks.events"; : > "$AUDIT_ROOT/acme/tasks.events.lock"
chmod 640 "$AUDIT_ROOT/acme/tasks.events" "$AUDIT_ROOT/acme/tasks.events.lock"
export AIB_TASK_ROOT="$AUDIT_ROOT" TASK_CALLER=root:root
EVENTS="$AUDIT_ROOT/acme/tasks.events"
python3 - "$REG" <<'PY'
import json,sys
p=sys.argv[1]; r=json.load(open(p)); d=r['teams']['acme-engine']['delegation']; d['max_open']='20'; d['max_tasks_per_run']='30'; d['max_turns_per_task']='2'
with open(p,'w') as f: json.dump(r,f,separators=(',',':'))
PY

# Retry dedupe pins both keys and the assignee dimension. Terminal source rows no
# longer block fan-out, while replay of the deterministic terminal id still does.
write run-create human operator ctl-audit-run --run-id r-200000000001
write create agent acme-lead dedupe-first --run-id r-200000000001 --intent-n 1 --source-msg-id msg-dedupe --assignee acme-dev1 --title Dedupe --body-ref msg:dedupe --body-file "$BODY"; D1=${OUT#task_id=}
write create agent acme-lead dedupe-retry --run-id r-200000000001 --intent-n 1 --source-msg-id msg-dedupe --assignee acme-dev1 --title Dedupe --body-ref msg:dedupe --body-file "$BODY"
eq 'source and assignee dedupe rejects a new deterministic id' "$RC|${OUT#task_id=}|$(field task.rejected -1 payload.reason)" "77|t-$(printf '%s' 'dedupe-retry:1' | sha256sum | cut -c1-12)|duplicate"
write create agent acme-lead dedupe-fanout --run-id r-200000000001 --intent-n 1 --source-msg-id msg-dedupe --assignee acme-dev2 --title Fanout --body-ref msg:fanout --body-file "$BODY"; D2=${OUT#task_id=}
eq 'the same source may fan out to a different assignee' "$RC|$(state "$D2")" '0|ASSIGNED'
write start service supervisor:acme-dev1 dedupe-start --run-id r-200000000001 --task-id "$D1"
write report agent acme-dev1 dedupe-done --run-id r-200000000001 --task-id "$D1" --state done --result-ref msg:done
invalid_before=$(run list --project acme --all; json_field invalid "$OUT")
write create agent acme-lead dedupe-first --run-id r-200000000001 --intent-n 1 --source-msg-id msg-dedupe --assignee acme-dev1 --title Dedupe --body-ref msg:dedupe --body-file "$BODY"
replay_rc=$RC; replay_reason=$(field task.rejected -1 payload.reason)
run list --project acme --all; invalid_after=$(json_field invalid "$OUT")
eq 'terminal deterministic-id replay is rejected without poisoning the fold' "$replay_rc|$replay_reason|$invalid_before|$invalid_after" '77|duplicate|0|0'
write create agent acme-lead dedupe-after-terminal --run-id r-200000000001 --intent-n 1 --source-msg-id msg-dedupe --assignee acme-dev1 --title Again --body-ref msg:again --body-file "$BODY"
eq 'source dedupe expires after the matching task is terminal' "$RC" 0

# Boundary files are opened no-follow/nonblocking, required to be regular, and
# bounded to one byte beyond the public cap. Keep adversarial values in their own
# ledger so a vulnerable build cannot pollute later transition scenarios.
BOUNDARY_ROOT="$WORK/boundary/tasks"; mkdir -p "$BOUNDARY_ROOT/acme/bodies"; : > "$BOUNDARY_ROOT/acme/tasks.events"; : > "$BOUNDARY_ROOT/acme/tasks.events.lock"
chmod 2750 "$BOUNDARY_ROOT/acme" "$BOUNDARY_ROOT/acme/bodies"; chmod 640 "$BOUNDARY_ROOT/acme/tasks.events" "$BOUNDARY_ROOT/acme/tasks.events.lock"
export AIB_TASK_ROOT="$BOUNDARY_ROOT"; EVENTS="$BOUNDARY_ROOT/acme/tasks.events"
python3 - "$REG" <<'PY'
import json,sys
p=sys.argv[1]; r=json.load(open(p)); r['teams']['acme-engine']['delegation']['max_open']='100'
with open(p,'w') as f: json.dump(r,f,separators=(',',':'))
PY
write run-create human operator boundary-run --run-id r-200000000001
BODY_LINK="$WORK/body-link"; ln -s "$BODY" "$BODY_LINK"
before=$(count task.created)
run_timeout create --project acme --team acme-engine --actor-type human --actor-id operator --via ctl:2 --requester human:operator --causation-id body-link --run-id r-200000000001 --intent-n 1 --source-msg-id msg-body-link --assignee acme-dev1 --title Body --body-ref msg:body-link --body-file "$BODY_LINK"
eq 'body-file symlinks are refused before commit' "$RC|$(count task.created)" "64|$before"
mkdir "$WORK/body-real-dir"; cp "$BODY" "$WORK/body-real-dir/body.md"; ln -s "$WORK/body-real-dir" "$WORK/body-mid-link"
run_timeout create --project acme --team acme-engine --actor-type human --actor-id operator --via ctl:22 --requester human:operator --causation-id body-mid-link --run-id r-200000000001 --intent-n 1 --source-msg-id msg-body-mid-link --assignee acme-dev1 --title Body --body-ref msg:body-mid-link --body-file "$WORK/body-mid-link/body.md"
eq 'body-file intermediate symlinks are refused before commit' "$RC|$(count task.created)" "64|$before"
mkfifo "$WORK/body-fifo"
run_timeout create --project acme --team acme-engine --actor-type human --actor-id operator --via ctl:3 --requester human:operator --causation-id body-fifo --run-id r-200000000001 --intent-n 1 --source-msg-id msg-body-fifo --assignee acme-dev1 --title Body --body-ref msg:body-fifo --body-file "$WORK/body-fifo"
eq 'body-file FIFOs are refused without blocking' "$RC" 64
mkdir "$WORK/body-dir"
run_timeout create --project acme --team acme-engine --actor-type human --actor-id operator --via ctl:4 --requester human:operator --causation-id body-dir --run-id r-200000000001 --intent-n 1 --source-msg-id msg-body-dir --assignee acme-dev1 --title Body --body-ref msg:body-dir --body-file "$WORK/body-dir"
eq 'body-file directories are refused' "$RC" 64
head -c 8193 /dev/zero > "$WORK/body-large"
run_timeout create --project acme --team acme-engine --actor-type human --actor-id operator --via ctl:5 --requester human:operator --causation-id body-large --run-id r-200000000001 --intent-n 1 --source-msg-id msg-body-large --assignee acme-dev1 --title Body --body-ref msg:body-large --body-file "$WORK/body-large"
eq 'body-file reads are capped at 8192 bytes' "$RC" 64
write create human operator unicode-title --run-id r-200000000001 --intent-n 1 --source-msg-id msg-unicode --assignee acme-dev1 --title $'bad\u2028title' --body-ref msg:unicode --body-file "$BODY"
eq 'Unicode line separators are rejected in titles' "$RC" 64
write create human operator bidi-title --run-id r-200000000001 --intent-n 1 --source-msg-id msg-bidi --assignee acme-dev1 --title $'bad\u2066title' --body-ref msg:bidi --body-file "$BODY"
eq 'bidi controls are rejected in titles' "$RC" 64
display_case=0; display_refused=1
for unsafe_title in $'bad\ttitle' $'bad\x7ftitle' $'bad\u009btitle' $'bad\u200btitle' $'bad\u200ftitle' $'bad\u202etitle' $'bad\u2060title' $'bad\u2064title' $'bad\u2069title' $'bad\ufefftitle' $'bad\U000e0000title' $'bad\U000e007ftitle'; do
  display_case=$((display_case+1))
  write create human operator "display-$display_case" --run-id r-200000000001 --intent-n 1 --source-msg-id "msg-display-$display_case" --assignee acme-dev1 --title "$unsafe_title" --body-ref "msg:display-$display_case" --body-file "$BODY"
  [ "$RC" -eq 64 ] || display_refused=0
done
eq 'C0, DEL, C1, format/zero-width, and tag characters are rejected in titles' "$display_refused" 1
display_range_check=$(python3 - "$ROOT" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]) / 'lib'))
from task_ledger import safe_display_text
points = [*range(0x00, 0x20), *range(0x7f, 0xa0), *range(0x200b, 0x2010), *range(0x2028, 0x202f), *range(0x2060, 0x2065), *range(0x2066, 0x206a), 0xfeff, *range(0xe0000, 0xe0080)]
print(all(not safe_display_text(chr(point)) for point in points))
PY
)
eq 'the display filter rejects every required control/format/tag code point' "$display_range_check" True
category_range_check=$(python3 - "$ROOT" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]) / 'lib'))
from task_ledger import safe_display_text
print(all(not safe_display_text(chr(point)) for point in (0xd800, 0xe000)))
PY
)
eq 'the display filter rejects surrogate and private-use code points' "$category_range_check" True
write create human operator unicode-version-title --run-id r-200000000001 --intent-n 1 --source-msg-id msg-unicode-version --assignee acme-dev1 --title $'Unicode 15 \U0001fae8' --body-ref msg:unicode-version --body-file "$BODY"
UNICODE_VERSION_TASK=${OUT#task_id=}
run show --project acme "$UNICODE_VERSION_TASK"
eq 'code points assigned by newer Unicode versions remain foldable' "$RC|$(json_field title "$OUT")" $'0|Unicode 15 \U0001fae8'
before=$(wc -l < "$EVENTS")
write create human operator invalid-byte-title --run-id r-200000000001 --intent-n 1 --source-msg-id msg-invalid-byte-title --assignee acme-dev1 --title $'bad\xfftitle' --body-ref msg:invalid-byte-title --body-file "$BODY"
eq 'an invalid UTF-8 title is refused by the CLI gate before append' "$RC|$ERR|$(wc -l < "$EVENTS")" "64|ai-bobnet: invalid UTF-8 in title|$before"
write cancel human operator invalid-byte-reason --run-id r-200000000001 --task-id "$D2" --reason $'bad\xfcreason'
eq 'an invalid UTF-8 reason is rc 64 and appends nothing' "$RC|$(wc -l < "$EVENTS")" "64|$before"
run list --project acme --all
eq 'the ledger remains readable after invalid argv bytes are refused' "$RC" 0
write create human operator utf8-ok-title --run-id r-200000000001 --intent-n 1 --source-msg-id msg-utf8-ok --assignee acme-dev1 --title 'Prüfung' --body-ref msg:utf8-ok --body-file "$BODY" --deadline-at 2026-10-28T00:00:00Z
UTF8_OK=${OUT#task_id=}
run show --project acme "$UTF8_OK"
raw_utf8_count=$(python3 - "$EVENTS" <<'PY'
import sys
print(open(sys.argv[1], "rb").read().count("Prüfung".encode("utf-8")))
PY
)
eq 'valid non-ASCII titles round-trip and are stored as raw UTF-8 bytes' "$(json_field title "$OUT")|$(json_field deadline_at "$OUT")|$raw_utf8_count" 'Prüfung|2026-10-28T00:00:00Z|1'
eq 'show on a ledger without invalid records prints no warning' "$RC|$ERR" '0|'
unicode_table_independent=$(python3 - "$ROOT" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]) / 'lib'))
import task_ledger
if hasattr(task_ledger, "unicodedata"):
    task_ledger.unicodedata.category = lambda _char: "Cc"
print(task_ledger.safe_display_text("Prüfung") and not task_ledger.safe_display_text("bad\u2066text"))
PY
)
eq 'the display filter does not consult interpreter Unicode categories' "$unicode_table_independent" True
deadline_before=$(wc -l < "$EVENTS"); deadline_refused=1
for invalid_deadline in '2026-1-2T3:4:5Z' '٢٠٢٦-10-28T00:00:00Z' '2026-02-30T00:00:00Z' '2026-10-28T24:00:00Z'; do
  write create human operator invalid-deadline --run-id r-200000000001 --intent-n 1 --source-msg-id msg-invalid-deadline --assignee acme-dev1 --title Deadline --body-ref msg:invalid-deadline --body-file "$BODY" --deadline-at "$invalid_deadline"
  [ "$RC" -eq 64 ] || deadline_refused=0
done
eq 'deadline_at accepts only canonical ASCII UTC timestamps without appending refusals' "$deadline_refused|$(wc -l < "$EVENTS")" "1|$deadline_before"
write create human operator unsafe-ref --run-id r-200000000001 --intent-n 1 --source-msg-id msg-ref --assignee acme-dev1 --title Ref --body-ref msg:ref --body-file "$BODY" --context-ref file:../../outside
eq 'file context refs cannot traverse above their root' "$RC" 64
ref_case=0; refs_refused=1
for unsafe_ref in 'git:--upload-pack=x' 'git:refs/heads/a..b' 'git:refs/heads/.hidden' 'git:refs/heads/x.lock' 'git:@' 'git:refs/heads/x.' 'git:@{bad' 'file:-option' $'file:a\x1bb' $'file:a\u202eb' "file:$(printf '%0256d' 0)"; do
  ref_case=$((ref_case+1))
  write create human operator "unsafe-ref-$ref_case" --run-id r-200000000001 --intent-n 1 --source-msg-id "msg-unsafe-ref-$ref_case" --assignee acme-dev1 --title Ref --body-ref "msg:unsafe-ref-$ref_case" --body-file "$BODY" --context-ref "$unsafe_ref"
  [ "$RC" -eq 64 ] || refs_refused=0
done
eq 'refs reject option-like, control, non-ASCII, overlong, and invalid git forms' "$refs_refused" 1
long_msg_ref="msg:$(printf '%0256d' 0)"
write create human operator long-body-ref --run-id r-200000000001 --intent-n 1 --source-msg-id msg-long-body-ref --assignee acme-dev1 --title Ref --body-ref "$long_msg_ref" --body-file "$BODY"
eq 'body_ref uses the same sane reference length bound' "$RC" 64
write create human operator wrong-body-ref-prefix --run-id r-200000000001 --intent-n 1 --source-msg-id msg-wrong-body-ref --assignee acme-dev1 --title Ref --body-ref git:main --body-file "$BODY"
eq 'body_ref requires the msg prefix' "$RC" 64
write create human operator bad-msg-token --run-id r-200000000001 --intent-n 1 --source-msg-id msg-bad-token --assignee acme-dev1 --title Ref --body-ref msg:bad-token --body-file "$BODY" --context-ref msg:Bad.Ref
eq 'msg context refs require TOKEN form' "$RC" 64
run run-create --project acme --team acme-engine --actor-type human --actor-id operator --via ctl:23 --requester human:operator --causation-id unsafe-ticket --run-id r-200000000010 --ticket-ref 'git:--upload-pack=x'
eq 'ticket_ref uses the common reference validator' "$RC" 64
run run-close --project acme --team acme-engine --actor-type human --actor-id operator --via ctl:24 --requester human:operator --causation-id unsafe-summary --run-id r-200000000001 --outcome completed --summary-ref $'file:a\x1bb'
eq 'summary_ref uses the common reference validator' "$RC" 64

export AIB_TASK_ROOT="$AUDIT_ROOT"; EVENTS="$AUDIT_ROOT/acme/tasks.events"
python3 - "$REG" <<'PY'
import json,sys
p=sys.argv[1]; r=json.load(open(p)); r['teams']['acme-engine']['delegation']['max_open']='20'
with open(p,'w') as f: json.dump(r,f,separators=(',',':'))
PY

# Only progress consumes the current-attempt turn budget. Final agent reports and
# the engine turn-budget report remain available; reassignment resets current
# turns while preserving total progress and incrementing attempts.
write run-create human operator ctl-budget-run --run-id r-200000000002
write create human operator budget-create --run-id r-200000000002 --intent-n 1 --source-msg-id msg-budget --assignee acme-dev1 --title Budget --body-ref msg:budget --body-file "$BODY"; BT=${OUT#task_id=}
write start service supervisor:acme-dev1 budget-start --run-id r-200000000002 --task-id "$BT"
run show --project acme "$BT"; start_state_seq=$(json_field state_seq "$OUT")
write report agent acme-dev1 budget-progress-1 --run-id r-200000000002 --task-id "$BT" --state progress --reason one
write report agent acme-dev1 budget-progress-2 --run-id r-200000000002 --task-id "$BT" --state progress --reason two
run show --project acme "$BT"; progress_state_seq=$(json_field state_seq "$OUT")
eq 'progress leaves state_seq unchanged while consuming turns' "$start_state_seq|$progress_state_seq|$(json_field turns "$OUT")|$(json_field turns_total "$OUT")" "$start_state_seq|$start_state_seq|2|2"
write report agent acme-dev1 budget-progress-3 --run-id r-200000000002 --task-id "$BT" --state progress --reason three
eq 'registry turn budget rejects only excess progress' "$RC|$(field task.rejected -1 payload.reason)" '77|max_turns_per_task'
write report service supervisor:acme-dev1 budget-stop --run-id r-200000000002 --task-id "$BT" --state blocked --reason turn_budget
eq 'service can close an exhausted attempt as blocked' "$RC|$(state "$BT")" '0|BLOCKED'
write assign agent acme-lead budget-assign --run-id r-200000000002 --task-id "$BT" --assignee acme-dev2
run show --project acme "$BT"
eq 'reassignment resets turns and increments total attempts' "$(json_field turns "$OUT")|$(json_field turns_total "$OUT")|$(json_field attempts "$OUT")" '0|2|2'
write start service supervisor:acme-dev2 budget-start-2 --run-id r-200000000002 --task-id "$BT"
write report agent acme-dev2 budget-done --run-id r-200000000002 --task-id "$BT" --state done --result-ref msg:budget-done
eq 'final agent report remains allowed after a prior exhausted attempt' "$RC|$(state "$BT")" '0|DONE'

# Optimistic tokens bind state_seq, not last_seq: a progress event between read
# and write is harmless, while a token from before start remains stale.
write run-create human operator ctl-state-seq-run --run-id r-200000000009
write create human operator state-seq-create --run-id r-200000000009 --intent-n 1 --source-msg-id msg-state-seq --assignee acme-dev1 --title Token --body-ref msg:state-seq --body-file "$BODY"; ST=${OUT#task_id=}
run show --project acme "$ST"; created_state_seq=$(json_field state_seq "$OUT")
write start service supervisor:acme-dev1 state-seq-start --run-id r-200000000009 --task-id "$ST"
run show --project acme "$ST"; started_state_seq=$(json_field state_seq "$OUT")
write report agent acme-dev1 state-seq-progress --run-id r-200000000009 --task-id "$ST" --state progress --reason working
write cancel agent acme-lead state-seq-stale --run-id r-200000000009 --task-id "$ST" --expect-seq "$created_state_seq" --reason stale
eq 'a token from before a state transition remains stale after progress' "$RC|$(field task.rejected -1 payload.reason)|$(state "$ST")" '76|concurrent_update|IN_PROGRESS'
write cancel agent acme-lead state-seq-current --run-id r-200000000009 --task-id "$ST" --expect-seq "$started_state_seq" --reason current
eq 'progress between read and write does not invalidate a state_seq token' "$RC|$(state "$ST")" '0|CANCELLED'

# Reassign/reopen allocations count against the per-run total, not only initial
# task creation.
python3 - "$REG" <<'PY'
import json,sys
p=sys.argv[1]; r=json.load(open(p)); r['teams']['acme-engine']['delegation']['max_tasks_per_run']='2'
with open(p,'w') as f: json.dump(r,f,separators=(',',':'))
PY
write run-create human operator ctl-reassign-limit --run-id r-200000000008
write create human operator reassign-limit-create --run-id r-200000000008 --intent-n 1 --source-msg-id msg-reassign-limit --assignee acme-dev1 --title Limit --body-ref msg:limit --body-file "$BODY"; RLT=${OUT#task_id=}
write start service supervisor:acme-dev1 reassign-limit-start-1 --run-id r-200000000008 --task-id "$RLT"
write report agent acme-dev1 reassign-limit-block-1 --run-id r-200000000008 --task-id "$RLT" --state blocked --reason wait
write assign agent acme-lead reassign-limit-1 --run-id r-200000000008 --task-id "$RLT" --assignee acme-dev2
eq 'first reassignment consumes the remaining per-run allocation' "$RC" 0
write start service supervisor:acme-dev2 reassign-limit-start-2 --run-id r-200000000008 --task-id "$RLT"
write report agent acme-dev2 reassign-limit-block-2 --run-id r-200000000008 --task-id "$RLT" --state blocked --reason wait
write assign agent acme-lead reassign-limit-2 --run-id r-200000000008 --task-id "$RLT" --assignee acme-dev1
eq 'per-run allocation limit rejects a later reassignment' "$RC|$(field task.rejected -1 payload.reason)" '77|max_tasks_per_run'
python3 - "$REG" <<'PY'
import json,sys
p=sys.argv[1]; r=json.load(open(p)); r['teams']['acme-engine']['delegation']['max_tasks_per_run']='30'
with open(p,'w') as f: json.dump(r,f,separators=(',',':'))
PY

# Run closure is terminal. Completed runs require an empty active frontier;
# failed/cancelled closures cascade task cancellations under the same lock.
write run-create human operator ctl-close-run --run-id r-200000000003
write create human operator close-create-1 --run-id r-200000000003 --intent-n 1 --source-msg-id msg-close-1 --assignee acme-dev1 --title Close --body-ref msg:close-1 --body-file "$BODY"; C1=${OUT#task_id=}
write create human operator close-create-2 --run-id r-200000000003 --intent-n 2 --source-msg-id msg-close-2 --assignee acme-dev2 --title Close --body-ref msg:close-2 --body-file "$BODY"; C2=${OUT#task_id=}
write run-close agent acme-dev1 close-worker --run-id r-200000000003 --outcome cancelled
eq 'a worker cannot close a run or cascade its tasks' "$RC|$(field task.rejected -1 payload.reason)|$(state "$C1")|$(state "$C2")|$(state r-200000000003)" '77|not_lead|ASSIGNED|ASSIGNED|RUNNING'
write run-close agent acme-lead close-completed-open --run-id r-200000000003 --outcome completed --summary-ref msg:summary
eq 'completed run closure refuses open tasks' "$RC|$(field task.rejected -1 payload.reason)" '77|open_tasks'
cancel_before=$(count task.cancelled)
close_lines_before=$(wc -l < "$EVENTS")
write run-close human operator close-cancelled --run-id r-200000000003 --outcome cancelled --summary-ref msg:summary
eq 'one run.closed atomically derives cancellation of every open task' "$RC|$(state "$C1")|$(state "$C2")|$(( $(count task.cancelled) - cancel_before ))|$(( $(wc -l < "$EVENTS") - close_lines_before ))|$(state r-200000000003)" '0|CANCELLED|CANCELLED|0|1|CANCELLED'
run show --project acme "$C1"; cascade_last_reason=$(json_field last_reason "$OUT"); cascade_state_seq=$(json_field state_seq "$OUT")
eq 'the run-close cascade records run_closed and the close sequence as state_seq' "$cascade_last_reason|$cascade_state_seq" "run_closed|$(field run.closed -1 event_id | sed 's/.*-//')"
write run-close human operator close-again --run-id r-200000000003 --outcome cancelled
eq 'a terminal run cannot be closed twice' "$RC|$(field task.rejected -1 payload.reason)" '77|run_closed'

write create human operator after-close-create --run-id r-200000000003 --intent-n 3 --source-msg-id msg-after-close --assignee acme-dev1 --title Closed --body-ref msg:closed --body-file "$BODY"
eq 'task.created is rejected under a closed run' "$RC|$(field task.rejected -1 payload.reason)" '77|run_closed'
write start service supervisor:acme-dev1 after-close-start --run-id r-200000000003 --task-id "$C1"
eq 'task.started is rejected under a closed run' "$RC|$(field task.rejected -1 payload.reason)" '77|run_closed'
write report agent acme-dev1 after-close-report --run-id r-200000000003 --task-id "$C1" --state done --result-ref msg:late
eq 'task.reported is rejected under a closed run' "$RC|$(field task.rejected -1 payload.reason)" '77|run_closed'
write cancel human operator after-close-cancel --run-id r-200000000003 --task-id "$C1" --reason late
eq 'task.cancelled is rejected under a closed run' "$RC|$(field task.rejected -1 payload.reason)" '77|run_closed'
write assign agent acme-lead after-close-assign --run-id r-200000000003 --task-id "$C1" --assignee acme-dev2
eq 'task.reassigned is rejected under a closed run' "$RC|$(field task.rejected -1 payload.reason)" '77|run_closed'
write reopen agent acme-lead after-close-reopen --run-id r-200000000003 --task-id "$C1" --assignee acme-dev2
eq 'task.reopened is rejected under a closed run' "$RC|$(field task.rejected -1 payload.reason)" '77|run_closed'
write overdue service supervisor:acme-lead after-close-overdue --run-id r-200000000003 --task-id "$C1"
eq 'task.overdue is rejected under a closed run' "$RC|$(field task.rejected -1 payload.reason)" '77|run_closed'

write run-create human operator ctl-failed-run --run-id r-200000000004
write create human operator failed-create --run-id r-200000000004 --intent-n 1 --source-msg-id msg-failed-close --assignee acme-dev1 --title Failed --body-ref msg:failed-close --body-file "$BODY"; CF=${OUT#task_id=}
write run-close agent acme-lead failed-close --run-id r-200000000004 --outcome failed
eq 'failed run closure also cascades open tasks' "$RC|$(state "$CF")|$(state r-200000000004)" '0|CANCELLED|FAILED'

# Every accepted verb is team-bound before actor/transition checks. Cross-team
# requests remain visible as rejections and cannot mutate the foreign objects.
write_for acme-other run-create human operator other-run --run-id r-200000000005
write_for acme-other create human operator other-create --run-id r-200000000005 --intent-n 1 --source-msg-id msg-other --assignee acme-other --title Other --body-ref msg:other --body-file "$BODY"; OT=${OUT#task_id=}
write run-close agent acme-lead cross-close --run-id r-200000000005 --outcome cancelled
eq 'run.closed is team-bound' "$RC|$(field task.rejected -1 payload.reason)" '77|cross_team'
write create agent acme-lead cross-create --run-id r-200000000005 --intent-n 1 --source-msg-id msg-cross-create --assignee acme-dev1 --title Cross --body-ref msg:cross --body-file "$BODY"
eq 'task.created is team-bound to its run' "$RC|$(field task.rejected -1 payload.reason)" '77|cross_team'
write start service supervisor:acme-dev1 cross-start --run-id r-200000000005 --task-id "$OT"
eq 'task.started is team-bound' "$RC|$(field task.rejected -1 payload.reason)" '77|cross_team'
write report agent acme-dev1 cross-report --run-id r-200000000005 --task-id "$OT" --state done --result-ref msg:cross
eq 'task.reported is team-bound' "$RC|$(field task.rejected -1 payload.reason)" '77|cross_team'
write cancel agent acme-lead cross-cancel --run-id r-200000000005 --task-id "$OT" --reason cross
eq 'task.cancelled is team-bound' "$RC|$(field task.rejected -1 payload.reason)" '77|cross_team'
write assign agent acme-lead cross-assign --run-id r-200000000005 --task-id "$OT" --assignee acme-dev1
eq 'task.reassigned is team-bound' "$RC|$(field task.rejected -1 payload.reason)" '77|cross_team'
write reopen agent acme-lead cross-reopen --run-id r-200000000005 --task-id "$OT" --assignee acme-dev1
eq 'task.reopened is team-bound' "$RC|$(field task.rejected -1 payload.reason)" '77|cross_team'
write overdue service supervisor:acme-lead cross-overdue --run-id r-200000000005 --task-id "$OT"
eq 'task.overdue is team-bound' "$RC|$(field task.rejected -1 payload.reason)|$(state "$OT")" '77|cross_team|ASSIGNED'

# Assignee validation is closed on creation and on later allocation attempts.
write run-create human operator ctl-assignee-run --run-id r-200000000006
write create human operator assignee-cross --run-id r-200000000006 --intent-n 1 --source-msg-id msg-assignee-cross --assignee acme-other --title Cross --body-ref msg:cross --body-file "$BODY"
eq 'creation rejects a cross-team assignee' "$RC|$(field task.rejected -1 payload.reason)" '77|cross_team'
write create human operator assignee-unknown-create --run-id r-200000000006 --intent-n 2 --source-msg-id msg-assignee-unknown --assignee acme-ghost --title Unknown --body-ref msg:unknown --body-file "$BODY"
eq 'creation rejects an unknown assignee' "$RC|$(field task.rejected -1 payload.reason)" '77|unknown_assignee'
write create human operator assignee-lead-create --run-id r-200000000006 --intent-n 3 --source-msg-id msg-assignee-lead --assignee acme-lead --title Lead --body-ref msg:lead --body-file "$BODY"
eq 'creation rejects the team lead as an assignee' "$RC|$(field task.rejected -1 payload.reason)" '77|invalid_assignee'
write create human operator assignee-valid --run-id r-200000000006 --intent-n 4 --source-msg-id msg-assignee-valid --assignee acme-dev1 --title Valid --body-ref msg:valid --body-file "$BODY"; AV=${OUT#task_id=}
write start service supervisor:acme-dev1 assignee-start --run-id r-200000000006 --task-id "$AV"
write report agent acme-dev1 assignee-block --run-id r-200000000006 --task-id "$AV" --state blocked --reason wait
write assign agent acme-lead assignee-unknown --run-id r-200000000006 --task-id "$AV" --assignee acme-ghost
eq 'reassign rejects an unknown assignee' "$RC|$(field task.rejected -1 payload.reason)" '77|unknown_assignee'
write reopen agent acme-lead assignee-lead --run-id r-200000000006 --task-id "$AV" --assignee acme-lead
eq 'reopen rejects a lead assignee' "$RC|$(field task.rejected -1 payload.reason)" '77|invalid_assignee'
write overdue service supervisor:acme-dev1 overdue-worker --run-id r-200000000006 --task-id "$AV"
eq 'only the lead supervisor may mark overdue' "$RC|$(field task.rejected -1 payload.reason)" '77|not_lead'
write overdue agent acme-lead overdue-agent --run-id r-200000000006 --task-id "$AV"
eq 'an agent claim cannot mark overdue even when it is the lead' "$RC|$(field task.rejected -1 payload.reason)" '77|not_lead'
run cancel --project acme --team acme-engine --actor-type service --actor-id supervisor:acme-dev1 --causation-id engine-token --run-id r-200000000006 --task-id "$AV" --expect-seq 1 --reason delivery_failed
eq 'engine events cannot carry an optimistic state token' "$RC" 64

write cancel human operator bad-reason-1 --run-id r-200000000006 --task-id "$AV" --reason $'bad\u0085reason'
eq 'Unicode next-line is rejected in reasons' "$RC" 64
write cancel human operator bad-reason-2 --run-id r-200000000006 --task-id "$AV" --reason $'bad\u202ereason'
eq 'bidi controls are rejected in reasons' "$RC" 64
write cancel human operator bad-reason-3 --run-id r-200000000006 --task-id "$AV" --reason $'bad\x1breason'
eq 'C0 controls are rejected in reasons' "$RC" 64
write cancel human operator bad-reason-4 --run-id r-200000000006 --task-id "$AV" --reason $'bad\U000e0001reason'
eq 'tag characters are rejected in reasons' "$RC" 64
write report agent acme-dev1 bad-result-ref --run-id r-200000000006 --task-id "$AV" --state done --result-ref file:../../outside
eq 'file result refs cannot traverse above their root' "$RC" 64

before=$(wc -l < "$EVENTS")
export TASK_CALLER=role:acme-dev1
run cancel --project acme --team acme-engine --actor-type human --actor-id operator --via ctl:9 --requester human:operator --causation-id role-human --run-id r-200000000006 --task-id "$AV" --reason forged
eq 'a role caller cannot claim human authority or append a rejection' "$RC|$ERR|$(wc -l < "$EVENTS")" "77|ai-bobnet: caller_unauthorized|$before"
export TASK_CALLER=root:root
run cancel --project acme --team acme-engine --actor-type human --actor-id operator --via ctl:9 --requester human:alice --causation-id human-mismatch --run-id r-200000000006 --task-id "$AV" --reason forged
eq 'human authority is bound to the kernel-attested requester' "$RC|$(field task.rejected -1 payload.reason)" '77|caller_actor_mismatch'

# Reassignment must consume both team-open capacity and the per-run allocation
# budget. The latter is separately exercised above; this pins the open frontier.
python3 - "$REG" <<'PY'
import json,sys
p=sys.argv[1]; r=json.load(open(p)); r['teams']['acme-engine']['delegation']['max_open']='1'
with open(p,'w') as f: json.dump(r,f,separators=(',',':'))
PY
write assign agent acme-lead open-reassign --run-id r-200000000006 --task-id "$AV" --assignee acme-dev2
eq 'reassign cannot exceed the team open-task limit' "$RC|$(field task.rejected -1 payload.reason)" '77|max_open'
python3 - "$REG" <<'PY'
import json,sys
p=sys.argv[1]; r=json.load(open(p)); r['teams']['acme-engine']['delegation']['max_open']='20'; r['teams']['acme-engine']['delegation']['typo_limit']='9'
with open(p,'w') as f: json.dump(r,f,separators=(',',':'))
PY
before=$(wc -l < "$EVENTS")
write run-create human operator bad-delegation-key --run-id r-200000000007
eq 'unknown delegation keys fail closed without an event' "$RC|$ERR|$(wc -l < "$EVENTS")" "64|ai-bobnet: invalid_delegation_limits|$before"
python3 - "$REG" <<'PY'
import json,sys
p=sys.argv[1]; r=json.load(open(p)); del r['teams']['acme-engine']['delegation']['typo_limit']
with open(p,'w') as f: json.dump(r,f,separators=(',',':'))
PY

# Runtime bodies replacement and deterministic hardlinks are refused. The
# symlink target remains empty, and an existing sidecar must have one link.
mv "$AUDIT_ROOT/acme/bodies" "$AUDIT_ROOT/acme/bodies-real"
mkdir "$WORK/body-target-dir"
ln -s "$WORK/body-target-dir" "$AUDIT_ROOT/acme/bodies"
write create human operator bodies-symlink --run-id r-200000000001 --intent-n 1 --source-msg-id msg-bodies-link --assignee acme-dev1 --title Link --body-ref msg:bodies-link --body-file "$BODY"
eq 'runtime bodies directory symlinks are visibly refused' "$RC|$(field task.rejected -1 payload.reason)|$(find "$WORK/body-target-dir" -mindepth 1 -print -quit)" '77|unsafe_body_sidecar|'
rm "$AUDIT_ROOT/acme/bodies"; mv "$AUDIT_ROOT/acme/bodies-real" "$AUDIT_ROOT/acme/bodies"
HARD_CAUSE=hard-sidecar; HARD_ID="t-$(printf '%s' "$HARD_CAUSE:1" | sha256sum | cut -c1-12)"
cp "$BODY" "$WORK/hard-source"; chmod 640 "$WORK/hard-source"
ln "$WORK/hard-source" "$AUDIT_ROOT/acme/bodies/$HARD_ID.md"
write create human operator "$HARD_CAUSE" --run-id r-200000000001 --intent-n 1 --source-msg-id msg-hard --assignee acme-dev1 --title Hard --body-ref msg:hard --body-file "$BODY"
eq 'hardlinked existing sidecars are visibly refused' "$RC|$(field task.rejected -1 payload.reason)|$(stat -c %h "$WORK/hard-source")" '77|unsafe_body_sidecar|2'
MODE_CAUSE=mode-sidecar; MODE_ID="t-$(printf '%s' "$MODE_CAUSE:1" | sha256sum | cut -c1-12)"
cp "$BODY" "$AUDIT_ROOT/acme/bodies/$MODE_ID.md"; chmod 644 "$AUDIT_ROOT/acme/bodies/$MODE_ID.md"
write create human operator "$MODE_CAUSE" --run-id r-200000000001 --intent-n 1 --source-msg-id msg-mode --assignee acme-dev1 --title Mode --body-ref msg:mode --body-file "$BODY"
eq 'existing sidecars with a permissive mode are visibly refused' "$RC|$(field task.rejected -1 payload.reason)|$(stat -c %a "$AUDIT_ROOT/acme/bodies/$MODE_ID.md")" '77|unsafe_body_sidecar|644'
OWNER_ID=t-ffffffffffff; cp "$BODY" "$AUDIT_ROOT/acme/bodies/$OWNER_ID.md"; chmod 640 "$AUDIT_ROOT/acme/bodies/$OWNER_ID.md"
owner_check=$(python3 - "$ROOT" "$AUDIT_ROOT/acme/bodies" "$OWNER_ID" "$BODY" <<'PY'
import os, stat, sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]) / 'lib'))
import task_ledger
real_fstat = os.fstat
def wrong_owner(fd):
    info = real_fstat(fd)
    if stat.S_ISREG(info.st_mode):
        values = list(info)
        values[4] = info.st_uid + 1
        return os.stat_result(values)
    return info
task_ledger.os.fstat = wrong_owner
print(task_ledger._write_body(Path(sys.argv[2]), sys.argv[3], Path(sys.argv[4]).read_bytes()))
PY
)
eq 'existing sidecars with a non-writer owner are refused' "$owner_check" False
GID_ID=t-eeeeeeeeeeee; cp "$BODY" "$AUDIT_ROOT/acme/bodies/$GID_ID.md"; chmod 640 "$AUDIT_ROOT/acme/bodies/$GID_ID.md"
gid_check=$(python3 - "$ROOT" "$AUDIT_ROOT/acme/bodies" "$GID_ID" "$BODY" <<'PY'
import os, stat, sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]) / 'lib'))
import task_ledger
real_fstat = os.fstat
sidecar = Path(sys.argv[2], f'{sys.argv[3]}.md').stat()
def wrong_gid(fd):
    info = real_fstat(fd)
    if stat.S_ISREG(info.st_mode) and (info.st_dev, info.st_ino) == (sidecar.st_dev, sidecar.st_ino):
        values = list(info); values[5] = info.st_gid + 1
        return os.stat_result(values)
    return info
task_ledger.os.fstat = wrong_gid
print(task_ledger._write_body(Path(sys.argv[2]), sys.argv[3], Path(sys.argv[4]).read_bytes()))
PY
)
eq 'existing sidecars with a foreign group are refused' "$gid_check" False

# Fold defence-in-depth independently rejects actor-class, team, caller, terminal,
# and closed-run violations even if a forged framed record reaches the stream.
FOLD_ROOT="$WORK/fold/tasks"
mkdir -p "$FOLD_ROOT/acme/bodies"; chmod 2750 "$FOLD_ROOT/acme" "$FOLD_ROOT/acme/bodies"
: > "$FOLD_ROOT/acme/tasks.events"; : > "$FOLD_ROOT/acme/tasks.events.lock"; chmod 640 "$FOLD_ROOT/acme/tasks.events" "$FOLD_ROOT/acme/tasks.events.lock"
export AIB_TASK_ROOT="$FOLD_ROOT"; EVENTS="$FOLD_ROOT/acme/tasks.events"
write run-create human operator fold-run --run-id r-300000000001
write create human operator fold-task-1 --run-id r-300000000001 --intent-n 1 --source-msg-id msg-fold-1 --assignee acme-dev1 --title Fold --body-ref msg:fold-1 --body-file "$BODY"; F1=${OUT#task_id=}
write start service supervisor:acme-dev1 fold-start-1 --run-id r-300000000001 --task-id "$F1"
write report agent acme-dev1 fold-block-1 --run-id r-300000000001 --task-id "$F1" --state blocked --reason wait
write create human operator fold-task-2 --run-id r-300000000001 --intent-n 2 --source-msg-id msg-fold-2 --assignee acme-dev2 --title Fold --body-ref msg:fold-2 --body-file "$BODY"; F2=${OUT#task_id=}
write start service supervisor:acme-dev2 fold-start-2 --run-id r-300000000001 --task-id "$F2"
write report agent acme-dev2 fold-done-2 --run-id r-300000000001 --task-id "$F2" --state done --result-ref msg:done
write create human operator fold-task-3 --run-id r-300000000001 --intent-n 3 --source-msg-id msg-fold-3 --assignee acme-dev2 --title Fold --body-ref msg:fold-3 --body-file "$BODY"; F3=${OUT#task_id=}
write start service supervisor:acme-dev2 fold-start-3 --run-id r-300000000001 --task-id "$F3"
python3 -I "$FX" inject "$EVENTS" task.cancelled service supervisor:acme-dev1 acme acme-engine r-300000000001 "$F1" forged-cancel '{"caller":"root:root","reason":"forged"}'
python3 -I "$FX" inject "$EVENTS" task.reassigned service supervisor:acme-dev1 acme acme-engine r-300000000001 "$F1" forged-assign '{"caller":"root:root","assignee":"acme-dev2"}'
python3 -I "$FX" inject "$EVENTS" task.reopened service supervisor:acme-dev1 acme acme-engine r-300000000001 "$F1" forged-reopen '{"caller":"root:root","assignee":"acme-dev2"}'
python3 -I "$FX" inject "$EVENTS" run.closed service supervisor:acme-lead acme acme-engine r-300000000001 - forged-close '{"caller":"root:root","outcome":"cancelled","summary_ref":null}'
python3 -I "$FX" inject "$EVENTS" task.cancelled agent acme-lead acme acme-other r-300000000001 "$F1" forged-team '{"caller":"root:root","via":"intent:forged-team","reason":"forged"}'
python3 -I "$FX" inject "$EVENTS" task.cancelled agent acme-lead acme acme-engine r-300000000001 "$F1" forged-role '{"caller":"role:acme-lead","via":"intent:forged-role","reason":"forged"}'
python3 -I "$FX" inject "$EVENTS" task.cancelled human operator acme acme-engine r-300000000001 "$F2" forged-terminal '{"caller":"root:root","via":"ctl:1","requester":"human:operator","reason":"forged"}'
python3 -I "$FX" inject "$EVENTS" run.closed human operator acme acme-engine r-300000000001 - forged-open-close '{"caller":"root:root","via":"ctl:2","requester":"human:operator","outcome":"completed","summary_ref":null}'
python3 -I "$FX" inject "$EVENTS" task.rejected human operator acme acme-engine r-300000000001 - forged-rejection '{"caller":"role:acme-dev1","requested_type":"task.cancelled","reason":"forged"}'
python3 -I "$FX" inject "$EVENTS" task.created human operator acme acme-engine r-300000000001 t-bbbbbbbbbbbb forged-title '{"caller":"root:root","via":"ctl:3","requester":"human:operator","parent":"r-300000000001","depth":1,"source_msg_id":"msg-forged-title","owner":"human:operator","assignee":"acme-dev1","title":"bad\u001btitle","body_ref":"msg:forged-title","deadline_at":"2026-10-28T00:00:00Z","budget":{"max_turns":8,"max_attempts":3},"gate":"none","context_refs":[]}'
python3 -I "$FX" inject "$EVENTS" task.created human operator acme acme-engine r-300000000001 t-dddddddddddd forged-deadline '{"caller":"root:root","via":"ctl:31","requester":"human:operator","parent":"r-300000000001","depth":1,"source_msg_id":"msg-forged-deadline","owner":"human:operator","assignee":"acme-dev1","title":"Bad deadline","body_ref":"msg:forged-deadline","deadline_at":"2026-1-2T3:4:5Z","budget":{"max_turns":8,"max_attempts":3},"gate":"none","context_refs":[]}'
python3 -I "$FX" inject "$EVENTS" task.cancelled human operator acme acme-engine r-300000000001 "$F1" forged-reason-cancel '{"caller":"root:root","via":"ctl:30","requester":"human:operator","reason":"bad\u202ereason"}'
python3 -I "$FX" inject "$EVENTS" task.reported agent acme-dev2 acme acme-engine r-300000000001 "$F3" forged-reason-report '{"caller":"root:root","via":"intent:forged-reason-report","state":"failed","result_ref":null,"reason":"bad\u202ereason"}'
run list --project acme --all
eq 'fold rejects all forged actor/team/caller/terminal/display/deadline records exactly' "$(json_field invalid "$OUT")|$(state "$F1")|$(state "$F2")|$(state "$F3")" '13|BLOCKED|DONE|IN_PROGRESS'
for fold_reason in invalid_cancel_actor invalid_reassignment_actor invalid_run_close_actor cross_team caller_actor_mismatch invalid_cancel open_tasks invalid_rejection invalid_title invalid_deadline_at invalid_reason; do
  has "fold reports $fold_reason" "$(json_field invalid_events "$OUT")" "\"reason\":\"$fold_reason\""
done

write run-close human operator fold-close --run-id r-300000000001 --outcome cancelled
python3 -I "$FX" inject "$EVENTS" task.started service supervisor:acme-dev1 acme acme-engine r-300000000001 "$F1" forged-after-close '{"caller":"root:root"}'
python3 -I "$FX" inject "$EVENTS" task.created human operator acme acme-engine r-300000000001 t-cccccccccccc forged-created-after-close '{"caller":"root:root","via":"ctl:4","requester":"human:operator","parent":"r-300000000001","depth":1,"source_msg_id":"msg-after-close","owner":"human:operator","assignee":"acme-dev1","title":"Late","body_ref":"msg:late","deadline_at":"2026-10-28T00:00:00Z","budget":{"max_turns":8,"max_attempts":3},"gate":"none","context_refs":[]}'
python3 -I "$FX" inject "$EVENTS" run.closed human operator acme acme-engine r-300000000001 - forged-second-close '{"caller":"root:root","via":"ctl:5","requester":"human:operator","outcome":"cancelled","summary_ref":null}'
run list --project acme --all
eq 'fold counts every injected post-close event as invalid' "$(json_field invalid "$OUT")" 16
has 'fold labels the injected post-close event run_closed' "$(json_field invalid_events "$OUT")" '"reason":"run_closed"'
has 'fold labels a second close invalid_run_close' "$(json_field invalid_events "$OUT")" '"reason":"invalid_run_close"'

# A correctly framed legacy poison record is a record-level anomaly, not a
# permanent availability failure. The fold skips it and the stop lever can append.
POISON_ROOT="$WORK/poison/tasks"
mkdir -p "$POISON_ROOT/acme/bodies"; chmod 2750 "$POISON_ROOT/acme" "$POISON_ROOT/acme/bodies"
: > "$POISON_ROOT/acme/tasks.events"; : > "$POISON_ROOT/acme/tasks.events.lock"; chmod 640 "$POISON_ROOT/acme/tasks.events" "$POISON_ROOT/acme/tasks.events.lock"
export AIB_TASK_ROOT="$POISON_ROOT"; EVENTS="$POISON_ROOT/acme/tasks.events"
write run-create human operator poison-run --run-id r-400000000001
write create human operator poison-task --run-id r-400000000001 --intent-n 1 --source-msg-id msg-poison --assignee acme-dev1 --title Poison --body-ref msg:poison --body-file "$BODY"; POISON_TASK=${OUT#task_id=}
python3 -I "$FX" inject-invalid-utf8 "$EVENTS" acme acme-engine r-400000000001 "$POISON_TASK"
run list --project acme --all
eq 'a pre-existing invalid UTF-8 record is counted while the fold continues' "$RC|$(json_field invalid "$OUT")|$(json_field invalid_events "$OUT")" '0|1|[{"reason":"invalid_utf8","seq":3}]'
run show --project acme "$POISON_TASK"
eq 'show surfaces the invalid-record counter without changing its JSON result' "$RC|$ERR|$(json_field state "$OUT")" '0|ai-bobnet: warning: 1 invalid task events (see list)|ASSIGNED'
write run-close human operator poison-close --run-id r-400000000001 --outcome cancelled
poison_close_rc=$RC
run list --project acme --all; poison_invalid=$(json_field invalid "$OUT")
eq 'run-close still works after a pre-existing invalid UTF-8 record' "$poison_close_rc|$poison_invalid|$(state "$POISON_TASK")|$(state r-400000000001)|$(wc -l < "$EVENTS")" '0|1|CANCELLED|CANCELLED|4'
python3 -I - "$EVENTS" <<'PY'
import subprocess, sys
path = sys.argv[1]
def frame(data, seq):
    crc, length, *_ = subprocess.check_output(["cksum"], input=data).split()
    return str(seq).encode() + b" " + crc + b" " + length + b" " + data + b"\n"
with open(path, "ab") as stream:
    stream.write(frame(b'{"event_id":"acme-tasks-5","event_id":"acme-tasks-5"}', 5))
PY
run list --project acme --all
eq 'duplicate-key records are counted and skipped' "$RC|$(json_field invalid_events "$OUT")" '0|[{"reason":"invalid_utf8","seq":3},{"reason":"invalid_json","seq":5}]'

REASON_ROOT="$WORK/reason/tasks"
mkdir -p "$REASON_ROOT/acme/bodies"; chmod 2750 "$REASON_ROOT/acme" "$REASON_ROOT/acme/bodies"
: > "$REASON_ROOT/acme/tasks.events"; : > "$REASON_ROOT/acme/tasks.events.lock"; chmod 640 "$REASON_ROOT/acme/tasks.events" "$REASON_ROOT/acme/tasks.events.lock"
export AIB_TASK_ROOT="$REASON_ROOT"; EVENTS="$REASON_ROOT/acme/tasks.events"
write run-create human operator poison-run-2 --run-id r-400000000002
write create human operator poison-task-2 --run-id r-400000000002 --intent-n 1 --source-msg-id msg-poison-2 --assignee acme-dev1 --title Poison --body-ref msg:poison-2 --body-file "$BODY"; POISON_TASK2=${OUT#task_id=}
long_reason=$(printf 'x%.0s' $(seq 513))
python3 -I "$FX" inject "$EVENTS" task.cancelled human operator acme acme-engine r-400000000002 "$POISON_TASK2" forged-long-reason '{"caller":"root:root","via":"ctl:40","requester":"human:operator","reason":"'"$long_reason"'"}'
python3 -I "$FX" inject "$EVENTS" task.cancelled human operator acme acme-engine r-400000000002 "$POISON_TASK2" forged-int-reason '{"caller":"root:root","via":"ctl:41","requester":"human:operator","reason":5}'
run list --project acme --all
eq 'fold rejects overlong and non-string reasons' "$(state "$POISON_TASK2")|$(json_field invalid "$OUT")|$(json_field invalid_events "$OUT" | grep -o invalid_reason | wc -l)" 'ASSIGNED|2|2'
eq 'list reports invalid records in JSON only, without a stderr warning' "$ERR" ''
python3 -I "$FX" inject "$EVENTS" task.created human operator acme acme-engine r-400000000002 t-eeeeeeeeeeee forged-null-deadline '{"caller":"root:root","via":"ctl:42","requester":"human:operator","parent":"r-400000000002","depth":1,"source_msg_id":"msg-null-deadline","owner":"human:operator","assignee":"acme-dev1","title":"Null deadline","body_ref":"msg:null-deadline","deadline_at":null,"budget":{"max_turns":8,"max_attempts":3},"gate":"none","context_refs":[]}'
run list --project acme --all
eq 'fold rejects a stored null deadline' "$(json_field invalid "$OUT")|$(json_field invalid_events "$OUT" | grep -o invalid_deadline_at | wc -l)" '3|1'

# Directory/file modes are a provisioning responsibility; the commit primitive
# merely requires them to exist.
PRIMARY_GROUP=$(id -gn)
TASK_TEST_GROUP=$PRIMARY_GROUP
GROUP_PROBE="$WORK/group-probe"; : > "$GROUP_PROBE"
for candidate in $(id -Gn); do
  if [ "$candidate" != "$PRIMARY_GROUP" ] && chgrp "$candidate" "$GROUP_PROBE" 2>/dev/null; then TASK_TEST_GROUP=$candidate; break; fi
done
rm "$GROUP_PROBE"
PROV="$WORK/provisioned"; rm -rf "$PROV"
RC=0; AIB_TASK_ROOT="$PROV" AIB_TASK_GROUP="$TASK_TEST_GROUP" "$ROOT/bin/aib-task-dirs" acme || RC=$?
eq 'task provisioning creates project/body dirs and stream files with root-writer modes' "$RC|$(stat -c %a "$PROV/acme")|$(stat -c %a "$PROV/acme/bodies")|$(stat -c %a "$PROV/acme/tasks.events")|$(stat -c %a "$PROV/acme/tasks.events.lock")" '0|2750|2750|640|640'
eq 'task provisioning assigns the configured reader group everywhere' "$(stat -c %G "$PROV/acme")|$(stat -c %G "$PROV/acme/bodies")|$(stat -c %G "$PROV/acme/tasks.events")|$(stat -c %G "$PROV/acme/tasks.events.lock")" "$TASK_TEST_GROUP|$TASK_TEST_GROUP|$TASK_TEST_GROUP|$TASK_TEST_GROUP"
group_call_check=$(python3 - "$ROOT/bin/aib-task-dirs" "$PROV/acme" <<'PY'
import importlib.machinery, importlib.util, os, sys
loader = importlib.machinery.SourceFileLoader('task_dirs_under_test', sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
module = importlib.util.module_from_spec(spec); loader.exec_module(module)
calls = []
module.os.fchown = lambda fd, uid, gid: calls.append(gid)
directory_fd = os.open(sys.argv[2], os.O_RDONLY | os.O_DIRECTORY)
try:
    directory_ok = module.set_dir(directory_fd, 0o2750, 4242)
    file_ok = module.real_file(directory_fd, 'group-call-check', 4242)
finally:
    os.close(directory_fd)
print(f'{directory_ok}|{file_ok}|{calls}')
PY
)
eq 'directory and file provisioning apply the requested group by fd' "$group_call_check" 'True|True|[4242, 4242]'
owner_takeover_check=$(python3 - "$ROOT/bin/aib-task-dirs" "$WORK/provision-owner" <<'PY'
import importlib.machinery, importlib.util, os, stat, sys
from pathlib import Path
loader = importlib.machinery.SourceFileLoader('task_dirs_owner_test', sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
module = importlib.util.module_from_spec(spec); loader.exec_module(module)
base = Path(sys.argv[2]); base.mkdir(); root = base / 'root'; root.mkdir(); child = root / 'child'; child.mkdir(); stream = root / 'stream'; stream.write_text('sentinel')
targets = {(p.stat().st_dev, p.stat().st_ino) for p in (root, child, stream)}
real_fstat = os.fstat; calls = []
def wrong_owner(fd):
    info = real_fstat(fd)
    if (info.st_dev, info.st_ino) in targets:
        values = list(info); values[4] = info.st_uid + 1
        return os.stat_result(values)
    return info
module.os.fstat = wrong_owner
module.os.fchown = lambda fd, uid, gid: calls.append((uid, gid))
root_result = module.root_dir(root, 0o755, os.getgid())
if root_result >= 0: os.close(root_result)
parent_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
try:
    dir_result = module.real_dir(parent_fd, 'child', 0o2750, os.getgid())
    if dir_result >= 0: os.close(dir_result)
    file_result = module.real_file(parent_fd, 'stream', os.getgid())
finally:
    os.close(parent_fd)
print(f'{root_result}|{dir_result}|{file_result}|{calls}')
PY
)
eq 're-provisioning refuses to take over existing foreign-owned dirs and files' "$owner_takeover_check" '-1|-1|False|[]'
rm -rf "$PROV/acme/bodies"; printf sentinel > "$WORK/prov-target"; ln -s "$WORK/prov-target" "$PROV/acme/bodies"
RC=0; AIB_TASK_ROOT="$PROV" AIB_TASK_GROUP="$TASK_TEST_GROUP" "$ROOT/bin/aib-task-dirs" acme || RC=$?
eq 'task provisioning refuses a planted directory symlink' "$RC|$(cat "$WORK/prov-target")" '78|sentinel'

EMPTY_CWD="$WORK/empty-root-cwd"; mkdir "$EMPTY_CWD"
RC=0; (cd "$EMPTY_CWD" && AIB_TASK_ROOT='' AIB_TASK_GROUP="$TASK_TEST_GROUP" "$ROOT/bin/aib-task-dirs" acme) || RC=$?
eq 'task provisioning fails fast on an empty task root' "$RC|$(find "$EMPTY_CWD" -mindepth 1 -print -quit)" '78|'
RC=0; (cd "$EMPTY_CWD" && AIB_TASK_ROOT=relative AIB_TASK_GROUP="$TASK_TEST_GROUP" "$ROOT/bin/aib-task-dirs" acme) || RC=$?
eq 'task provisioning refuses a relative task root' "$RC|$(find "$EMPTY_CWD" -mindepth 1 -print -quit)" '78|'
RC=0; AIB_TASK_ROOT="$WORK/prov-invalid" AIB_TASK_GROUP="$TASK_TEST_GROUP" "$ROOT/bin/aib-task-dirs" ../x || RC=$?
eq 'task provisioning refuses path traversal project ids' "$RC" 64
mkdir "$WORK/prov-elsewhere"; ln -s "$WORK/prov-elsewhere" "$WORK/prov-link"
RC=0; AIB_TASK_ROOT="$WORK/prov-link/tasks" AIB_TASK_GROUP="$TASK_TEST_GROUP" "$ROOT/bin/aib-task-dirs" acme || RC=$?
eq 'task provisioning refuses an intermediate symlink in the task root walk' "$RC|$(find "$WORK/prov-elsewhere" -mindepth 1 -print -quit)" '78|'

PROV_FILES="$WORK/provisioned-files"
AIB_TASK_ROOT="$PROV_FILES" AIB_TASK_GROUP="$TASK_TEST_GROUP" "$ROOT/bin/aib-task-dirs" acme
eq 'task provisioning leaves the shared root non-writable' "$(stat -c %a "$PROV_FILES")" 755
printf sentinel > "$WORK/prov-file-target"; chmod 600 "$WORK/prov-file-target"
rm "$PROV_FILES/acme/tasks.events"; ln "$WORK/prov-file-target" "$PROV_FILES/acme/tasks.events"
RC=0; AIB_TASK_ROOT="$PROV_FILES" AIB_TASK_GROUP="$TASK_TEST_GROUP" "$ROOT/bin/aib-task-dirs" acme || RC=$?
eq 'task provisioning refuses a hardlinked stream without changing its target' "$RC|$(stat -c %a "$WORK/prov-file-target")|$(cat "$WORK/prov-file-target")" '78|600|sentinel'
rm "$PROV_FILES/acme/tasks.events"; : > "$PROV_FILES/acme/tasks.events"; chmod 640 "$PROV_FILES/acme/tasks.events"
rm "$PROV_FILES/acme/tasks.events"; ln -s "$WORK/prov-file-target" "$PROV_FILES/acme/tasks.events"
RC=0; AIB_TASK_ROOT="$PROV_FILES" AIB_TASK_GROUP="$TASK_TEST_GROUP" "$ROOT/bin/aib-task-dirs" acme || RC=$?
eq 'task provisioning refuses a tasks.events symlink without changing its target' "$RC|$(stat -c %a "$WORK/prov-file-target")|$(cat "$WORK/prov-file-target")" '78|600|sentinel'
rm "$PROV_FILES/acme/tasks.events"; : > "$PROV_FILES/acme/tasks.events"; chmod 640 "$PROV_FILES/acme/tasks.events"
rm "$PROV_FILES/acme/tasks.events.lock"; ln -s "$WORK/prov-file-target" "$PROV_FILES/acme/tasks.events.lock"
RC=0; AIB_TASK_ROOT="$PROV_FILES" AIB_TASK_GROUP="$TASK_TEST_GROUP" "$ROOT/bin/aib-task-dirs" acme || RC=$?
eq 'task provisioning refuses a lock symlink without changing its target' "$RC|$(stat -c %a "$WORK/prov-file-target")|$(cat "$WORK/prov-file-target")" '78|600|sentinel'

printf '\ntask_ledger_spec: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
