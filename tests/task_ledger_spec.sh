#!/usr/bin/env bash
# ai-bobnet D1a — authoritative task ledger contract.
#
# Writes are serialized as one transaction: fold -> authority -> transition ->
# aib_event_commit(tasks). Domain refusals are durable task.rejected events and rc
# 77. Boundary-format failures are rc 64 and never reach the stream. The caller is
# kernel-derived; --actor-* is only the claim it attests next to.
set -uo pipefail

ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/aib-task-ledger.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
pass=0 fail=0
ok(){ pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
no(){ fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; }
eq(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2' want '$3')"; fi; }
has(){ case "$2" in *"$3"*) ok "$1";; *) no "$1 ('$2' lacks '$3')";; esac; }

TASK_ROOT="$WORK/tasks"
REG="$WORK/registry.json"
ID="$WORK/identity"
cat > "$REG" <<JSON
{"schema_version":5,
 "projects":{"acme":{"home":"$WORK/project","standup_dir":"$WORK/standup","mux_session":"acme","provider":"stub","model":"m","effort":"low"}},
 "teams":{"acme-engine":{"project":"acme","delegation":{"max_open":"2","max_tasks_per_run":"20","max_assignments_per_task":"4","max_depth":"1","task_deadline_s":"14400","max_turns_per_task":"8"}}},
 "agents":{
   "acme-lead":{"project":"acme","team_uid":"acme-engine","mode":"supervised","lead":"true","profile":"lead","clearance":"t2"},
   "acme-dev1":{"project":"acme","team_uid":"acme-engine","mode":"supervised","lead":"false","profile":"dev","clearance":"t2"},
   "acme-dev2":{"project":"acme","team_uid":"acme-engine","mode":"supervised","lead":"false","profile":"dev","clearance":"t2"},
   "acme-other":{"project":"acme","team_uid":"acme-other","mode":"supervised","lead":"false","profile":"dev","clearance":"t2"}
 }}
JSON
cat > "$ID" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${TASK_CALLER:-unknown:$1}"
SH
chmod +x "$ID"
mkdir -p "$TASK_ROOT/acme/bodies"
chmod 2770 "$TASK_ROOT/acme" "$TASK_ROOT/acme/bodies"
: > "$TASK_ROOT/acme/tasks.events"; : > "$TASK_ROOT/acme/tasks.events.lock"
chmod 660 "$TASK_ROOT/acme/tasks.events" "$TASK_ROOT/acme/tasks.events.lock"
EVENTS="$TASK_ROOT/acme/tasks.events"
FX="$ROOT/tests/fixtures/task_events.py"
export AIB_TEST_SEAMS=1 AIBOBNET_REGISTRY="$REG" AIB_TASK_ROOT="$TASK_ROOT" AIB_IDENTITY_CMD="$ID"
export TASK_CALLER=human:operator

run(){ RC=0; OUT=$("$ROOT/bin/task" "$@" 2>"$WORK/err") || RC=$?; ERR=$(cat "$WORK/err"); }
write(){ local verb=$1 actor_type=$2 actor_id=$3 cause=$4; shift 4; run "$verb" --project acme --team acme-engine --actor-type "$actor_type" --actor-id "$actor_id" --causation-id "$cause" "$@"; }
count(){ python3 -I "$FX" count "$EVENTS" "$1"; }
field(){ python3 -I "$FX" field "$EVENTS" "$1" "$2" "$3"; }
state(){ run show --project acme "$1"; python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])' <<<"$OUT"; }

# Authority matrix: humans/gateways can open runs; agents cannot. Lead and human
# may create; worker/service may not. The refused requests stay visible.
write run-create human operator ctl-run-1 --run-id r-000000000001
eq 'human can create a queued run' "$RC|$(count run.requested)|$(state r-000000000001)" '0|1|QUEUED'
export TASK_CALLER=gateway:gw
write run-create human operator ctl-run-spoof --run-id r-000000000002
eq 'kernel caller cannot be replaced by a human actor claim' "$RC|$(field task.rejected -1 payload.reason)" '77|caller_actor_mismatch'
export TASK_CALLER=role:acme-dev1
write run-create service supervisor:acme-dev1 ctl-run-svc --run-id r-000000000003
eq 'service cannot create a run' "$RC|$(field task.rejected -1 payload.reason)" '77|unauthorized'
export TASK_CALLER=gateway:gw
write run-create human gateway:gw ctl-run-gw --run-id r-000000000004
eq 'gateway caller can create a run only with a gateway claim' "$RC" 0

export TASK_CALLER=role:acme-lead
BODY="$WORK/body.md"; printf 'Implement the parser.\nSecond paragraph.\n' > "$BODY"
write create agent acme-lead attempt-11 --run-id r-000000000001 --intent-n 1 --source-msg-id msg-source-1 --assignee acme-dev1 --title 'Parser' --body-ref msg:delivery-1 --body-file "$BODY"
T1=${OUT#task_id=}
eq 'team lead creates an assigned task with deterministic id' "$RC|$T1|$(state "$T1")" "0|$T1|ASSIGNED"
eq 'task id is the documented token form' "$(expr "$T1" : 't-[0-9a-f]\{12\}$')" 14
eq 'sidecar is stable content with safe mode' "$(cat "$TASK_ROOT/acme/bodies/$T1.md")|$(stat -c %a "$TASK_ROOT/acme/bodies/$T1.md")" "$(cat "$BODY")|640"
eq 'payload records kernel caller next to claimed actor' "$(field task.created 0 payload.caller)|$(field task.created 0 actor_id)" 'role:acme-lead|acme-lead'

write create agent acme-lead attempt-11 --run-id r-000000000001 --intent-n 1 --source-msg-id msg-source-1 --assignee acme-dev1 --title 'Parser' --body-ref msg:delivery-1 --body-file "$BODY"
eq 'same attempt and intent derives the same id and dedupes source+assignee visibly' "$RC|${OUT#task_id=}|$(field task.rejected -1 payload.reason)" "77|$T1|duplicate"

export TASK_CALLER=role:acme-dev1
write create agent acme-dev1 attempt-worker --run-id r-000000000001 --intent-n 2 --source-msg-id msg-worker --assignee acme-dev2 --title 'No' --body-ref msg:no --body-file "$BODY"
eq 'worker cannot delegate' "$RC|$(field task.rejected -1 payload.reason)" '77|not_lead'
export TASK_CALLER=human:operator
write create human operator ctl-human-create --run-id r-000000000001 --intent-n 3 --source-msg-id msg-human --assignee acme-dev2 --title 'Override' --body-ref msg:human --body-file "$BODY"
T2=${OUT#task_id=}; eq 'human override can create' "$RC|$(state "$T2")" '0|ASSIGNED'

# Service start, assignee reports, engine reasons, and every state transition.
export TASK_CALLER=role:acme-dev1
write start service supervisor:acme-dev1 turn-1 --run-id r-000000000001 --task-id "$T1"
eq 'assignee supervisor starts ASSIGNED task' "$RC|$(state "$T1")" '0|IN_PROGRESS'
write report agent acme-dev2 turn-spoof --run-id r-000000000001 --task-id "$T1" --state done --result-ref msg:bad
eq 'non-assignee report is refused' "$RC|$(field task.rejected -1 payload.reason)" '77|not_assignee'
write report agent acme-dev1 turn-2 --run-id r-000000000001 --task-id "$T1" --state progress --reason working
eq 'progress is an IN_PROGRESS self-transition' "$RC|$(state "$T1")" '0|IN_PROGRESS'
write report agent acme-dev1 turn-3 --run-id r-000000000001 --task-id "$T1" --state blocked --reason dependency
eq 'assignee can report BLOCKED' "$RC|$(state "$T1")" '0|BLOCKED'

export TASK_CALLER=role:acme-lead
write reopen agent acme-lead attempt-reopen --run-id r-000000000001 --task-id "$T1" --assignee acme-dev1
eq 'lead reopens BLOCKED to ASSIGNED' "$RC|$(state "$T1")" '0|ASSIGNED'
export TASK_CALLER=role:acme-dev1
write start service supervisor:acme-dev1 turn-4 --run-id r-000000000001 --task-id "$T1"
write report service supervisor:acme-dev1 turn-5 --run-id r-000000000001 --task-id "$T1" --state failed --reason turn_failed
eq 'assignee service may report an engine FAILED reason' "$RC|$(state "$T1")" '0|FAILED'
export TASK_CALLER=human:operator
write reopen human operator ctl-reopen --run-id r-000000000001 --task-id "$T1" --assignee acme-dev1
eq 'human override reopens FAILED while assignment budget remains' "$RC|$(state "$T1")" '0|ASSIGNED'

# Gate hook: production creation refuses non-none, while a directly replayed
# future-valid gate task folds reported done to REVIEW.
write create human operator ctl-gated --run-id r-000000000001 --intent-n 4 --source-msg-id msg-gated --assignee acme-dev1 --title Gate --body-ref msg:gate --body-file "$BODY" --gate code
eq 'D1a refuses task.created gate != none' "$RC|$(field task.rejected -1 payload.reason)" '77|gate_not_available'
write create human operator ctl-deep --run-id r-000000000001 --intent-n 5 --source-msg-id msg-deep --assignee acme-dev1 --title Deep --body-ref msg:deep --body-file "$BODY" --depth 2
eq 'depth above one is refused' "$RC|$(field task.rejected -1 payload.reason)" '77|max_depth'

# Limits are registry-overridable: open team cap is already full, then cancelling
# releases one slot; per-run total and per-task assignment caps remain folded facts.
write create human operator ctl-over-open --run-id r-000000000001 --intent-n 6 --source-msg-id msg-over --assignee acme-dev1 --title Over --body-ref msg:over --body-file "$BODY"
eq 'team max_open override is enforced' "$RC|$(field task.rejected -1 payload.reason)" '77|max_open'
write cancel human operator ctl-cancel-2 --run-id r-000000000001 --task-id "$T2" --reason superseded
eq 'human cancels any nonterminal task' "$RC|$(state "$T2")" '0|CANCELLED'

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
export TASK_CALLER=role:acme-dev1
write start service supervisor:acme-dev1 turn-race-1 --run-id r-000000000001 --task-id "$T1"
write report agent acme-dev1 turn-race-2 --run-id r-000000000001 --task-id "$T1" --state blocked --reason wait
export TASK_CALLER=human:operator
exec 9>>"$TASK_ROOT/acme/tasks.events.lock"
flock -x 9
( write cancel human operator ctl-race-c --run-id r-000000000001 --task-id "$T1" --reason race; printf '%s\n' "$RC" > "$WORK/race-c" ) & p1=$!
( write assign human operator ctl-race-a --run-id r-000000000001 --task-id "$T1" --assignee acme-dev2; printf '%s\n' "$RC" > "$WORK/race-a" ) & p2=$!
sleep 0.2
flock -u 9
exec 9>&-
wait "$p1" "$p2"
race_rc="$(cat "$WORK/race-c") $(cat "$WORK/race-a")"
case "$race_rc" in '0 77'|'77 0') ok 'cancel versus reassign has exactly one winner under lock';; *) no "cancel versus reassign rc ($race_rc)";; esac
eq 'race emits one accepted transition and one visible refusal' "$(( $(count task.cancelled) + $(count task.reassigned) ))|$(field task.rejected -1 payload.reason)" '2|concurrent_update'

# Fold rejects an injected semantically invalid event but retains deterministic
# state. list/show are both fresh replays, not a status store.
cat > "$WORK/invalid.json" <<JSON
{"event_id":"acme-tasks-999","event_type":"task.reported","occurred_at":"2026-10-27T12:00:00Z","actor_type":"agent","actor_id":"acme-dev2","project_uid":"acme","team_uid":"acme-engine","agent_uid":"acme-dev2","session_id":null,"run_id":"r-000000000001","task_id":"$T2","gate_id":null,"grant_id":null,"effect_id":null,"attempt_id":null,"correlation_id":"r-000000000001","causation_id":"injected-1","schema_version":2,"payload":{"caller":"role:acme-dev2","state":"done","result_ref":"msg:forged","reason":null}}
JSON
python3 -I "$FX" append "$EVENTS" "$WORK/invalid.json" 999
run list --project acme --all
has 'fold exposes semantically invalid injected records' "$OUT" '"invalid":1'
snapshot=$OUT
run list --project acme --all
eq 'fold replay is deterministic and equals live read' "$OUT" "$snapshot"
has 'task.rejected events are visible in list output' "$OUT" '"rejections":'

# Future gate fixture is isolated because D1a creation correctly blocks it.
GATE_ROOT="$WORK/gate/tasks"; mkdir -p "$GATE_ROOT/acme/bodies"; : > "$GATE_ROOT/acme/tasks.events"; : > "$GATE_ROOT/acme/tasks.events.lock"
chmod 2770 "$GATE_ROOT/acme" "$GATE_ROOT/acme/bodies"; chmod 660 "$GATE_ROOT/acme/tasks.events" "$GATE_ROOT/acme/tasks.events.lock"
GATE_EVENTS="$GATE_ROOT/acme/tasks.events"
python3 -I "$ROOT/lib/task_ledger.py" fixture-gated "$GATE_EVENTS" "$REG"
AIB_TASK_ROOT="$GATE_ROOT" run show --project acme t-aaaaaaaaaaaa
eq 'future gate seam folds reported done to REVIEW' "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])' <<<"$OUT")" REVIEW

# Isolated ledger exercises the remaining closed transitions and limits without
# coupling their setup to the lock-race corpus above.
LIMIT_ROOT="$WORK/limits/tasks"; mkdir -p "$LIMIT_ROOT/acme/bodies"; : > "$LIMIT_ROOT/acme/tasks.events"; : > "$LIMIT_ROOT/acme/tasks.events.lock"
chmod 2770 "$LIMIT_ROOT/acme" "$LIMIT_ROOT/acme/bodies"; chmod 660 "$LIMIT_ROOT/acme/tasks.events" "$LIMIT_ROOT/acme/tasks.events.lock"
export AIB_TASK_ROOT="$LIMIT_ROOT"; EVENTS="$LIMIT_ROOT/acme/tasks.events"
export TASK_CALLER=human:operator
python3 - "$REG" <<'PY'
import json,sys
p=sys.argv[1]; r=json.load(open(p)); r['teams']['acme-engine']['delegation']['max_tasks_per_run']='3'
with open(p,'w') as f: json.dump(r,f,separators=(',',':'))
PY
write run-create human operator ctl-limit-run --run-id r-100000000001
write create human operator limit-create-1 --run-id r-100000000001 --intent-n 1 --source-msg-id msg-limit-1 --assignee acme-dev1 --title Done --body-ref msg:limit-1 --body-file "$BODY"; LDONE=${OUT#task_id=}
export TASK_CALLER=role:acme-dev1
write start service supervisor:acme-dev1 limit-start-1 --run-id r-100000000001 --task-id "$LDONE"
write report agent acme-dev1 limit-report-1 --run-id r-100000000001 --task-id "$LDONE" --state done --result-ref msg:done
eq 'reported done reaches DONE when gate is none' "$RC|$(state "$LDONE")" '0|DONE'
export TASK_CALLER=human:operator
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
  export TASK_CALLER="role:$assignee"
  write start service "supervisor:$assignee" "assign-start-$round" --run-id r-100000000002 --task-id "$LA"
  write report agent "$assignee" "assign-block-$round" --run-id r-100000000002 --task-id "$LA" --state blocked --reason wait
  if [ "$round" -eq 1 ]; then
    eq 'a run with only a blocked active frontier derives BLOCKED' "$(state r-100000000002)" BLOCKED
  fi
  export TASK_CALLER=human:operator
  next=acme-dev2; [ "$assignee" = acme-dev2 ] && next=acme-dev1
  write assign human operator "assign-$round" --run-id r-100000000002 --task-id "$LA" --assignee "$next"
done
export TASK_CALLER=role:acme-dev2
write start service supervisor:acme-dev2 assign-start-4 --run-id r-100000000002 --task-id "$LA"
write report agent acme-dev2 assign-block-4 --run-id r-100000000002 --task-id "$LA" --state blocked --reason wait
export TASK_CALLER=human:operator
write assign human operator assign-over --run-id r-100000000002 --task-id "$LA" --assignee acme-dev1
eq 'per-task assignment limit override is enforced' "$RC|$(field task.rejected -1 payload.reason)" '77|max_assignments_per_task'

write run-create human operator ctl-service-run --run-id r-100000000003
write create human operator delivery-create --run-id r-100000000003 --intent-n 1 --source-msg-id msg-delivery --assignee acme-dev1 --title Delivery --body-ref msg:delivery --body-file "$BODY"; LS=${OUT#task_id=}
export TASK_CALLER=role:acme-lead
write overdue service supervisor:acme-lead overdue-1 --run-id r-100000000003 --task-id "$LS"
eq 'lead supervisor may mark a nonterminal task overdue without changing work state' "$RC|$(state "$LS")" '0|ASSIGNED'
export TASK_CALLER=role:acme-dev1
write cancel service supervisor:acme-dev1 delivery-failed-1 --run-id r-100000000003 --task-id "$LS" --reason delivery_failed
eq 'assignee supervisor may cancel ASSIGNED after delivery failure' "$RC|$(state "$LS")" '0|CANCELLED'
export TASK_CALLER=role:acme-lead
write run-close agent acme-lead close-run-1 --run-id r-100000000003 --outcome completed --summary-ref msg:summary
eq 'current team lead may close a run' "$RC|$(state r-100000000003)" '0|COMPLETED'

# Registry authority is read at commit time: after a lead flag move, the old
# lead is rejected and the new lead can perform the same transition.
export TASK_CALLER=human:operator
write run-create human operator ctl-switch-run --run-id r-100000000004
write create human operator switch-create --run-id r-100000000004 --intent-n 1 --source-msg-id msg-switch --assignee acme-dev1 --title Switch --body-ref msg:switch --body-file "$BODY"; LSW=${OUT#task_id=}
export TASK_CALLER=role:acme-dev1
write start service supervisor:acme-dev1 switch-start --run-id r-100000000004 --task-id "$LSW"
write report agent acme-dev1 switch-block --run-id r-100000000004 --task-id "$LSW" --state blocked --reason wait
python3 - "$REG" <<'PY'
import json,sys
p=sys.argv[1]; r=json.load(open(p)); r['agents']['acme-lead']['lead']='false'; r['agents']['acme-dev2']['lead']='true'
with open(p,'w') as f: json.dump(r,f,separators=(',',':'))
PY
export TASK_CALLER=role:acme-lead
write assign agent acme-lead old-lead --run-id r-100000000004 --task-id "$LSW" --assignee acme-dev1
eq 'old lead is refused after lead flag moves' "$RC|$(field task.rejected -1 payload.reason)" '77|not_lead'
export TASK_CALLER=role:acme-dev2
write assign agent acme-dev2 new-lead --run-id r-100000000004 --task-id "$LSW" --assignee acme-dev1
eq 'new lead is authorized from the commit-time registry snapshot' "$RC|$(state "$LSW")" '0|ASSIGNED'

# Directory/file modes are a provisioning responsibility; the commit primitive
# merely requires them to exist.
PROV="$WORK/provisioned"; rm -rf "$PROV"
RC=0; AIB_TASK_ROOT="$PROV" AIB_TASK_GROUP="$(id -gn)" "$ROOT/bin/aib-task-dirs" acme || RC=$?
eq 'task provisioning creates project/body dirs and stream files with safe modes' "$RC|$(stat -c %a "$PROV/acme")|$(stat -c %a "$PROV/acme/bodies")|$(stat -c %a "$PROV/acme/tasks.events")|$(stat -c %a "$PROV/acme/tasks.events.lock")" '0|2770|2770|660|660'
rm -rf "$PROV/acme/bodies"; printf sentinel > "$WORK/prov-target"; ln -s "$WORK/prov-target" "$PROV/acme/bodies"
RC=0; AIB_TASK_ROOT="$PROV" AIB_TASK_GROUP="$(id -gn)" "$ROOT/bin/aib-task-dirs" acme || RC=$?
eq 'task provisioning refuses a planted directory symlink' "$RC|$(cat "$WORK/prov-target")" '78|sentinel'

printf '\ntask_ledger_spec: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
