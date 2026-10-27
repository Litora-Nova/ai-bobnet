#!/usr/bin/env bash
# ai-bobnet — RED spec for the EXECUTOR side of the control plane: what bin/aib-supervisor does with a request file
# (Supervisor slice S1b; design B10 + v2 amendments F6 "neustart = in-process re-exec" and F8 "executor-side audit").
# The client side is tests/agentctl_spec.sh. Request files and audit records are made BY HAND here, on purpose: the executor must
# not depend on a polite client (F8: "audit before effect is a property of the executor").
#
# WHAT THIS PINS (record shapes + env seams: tests/fixtures/ctl_harness.sh)
#   - the supervisor accepts a request file `<uid>.<seq>.<verb>` only if `_control.jsonl` holds a ctl.requested with the SAME
#     seq, target, verb AND a `caller` equal to the identity of the request file's OWNER (AIB_IDENTITY_CMD <owner uid>);
#     otherwise it appends `ctl.rejected` reason `unaudited` (own journal + audit log) and does nothing else.
#   - it repeats the authorization table (human | gateway | lead-claim for neustart/feierabend/standup; humans only for
#     abschalten/reset-brake) and refuses protected agents (`protected`), WORKING without --force (`busy`), unknown verbs.
#   - every handled seq is journalled `ctl.consumed`; a consumed seq is never re-run (also after a crash + restart).
#   - neustart (soft) = IN-PROCESS re-exec: same PID, `ctl.done` BEFORE the re-exec, READY=1 re-sent, tick/journal seq continue.
#     `hard:true` in the audit record = ctl.done then exit 75. `--force` while WORKING: after AIB_SUP_CANCEL_GRACE_S the turn is
#     cancelled by terminating the launcher's whole PROCESS GROUP; the message stays SEEN, replays with the F10 preamble, and the
#     cancel does NOT count toward the brake. neustart and reset-brake clear a tripped brake (journal `brake.reset`).
#   - feierabend: ONE routine turn (prompt contains `routine:feierabend`), then state WAITING reason off_duty, live.json
#     `off_duty:true`, no further turns, inbox keeps accumulating (PERSISTED), off-duty survives a crash + restart.
#     ctl.done is written once the routine turn has ended. standup clears it and runs the briefing turn
#     (prompt contains `routine:standup`) BEFORE the waiting inbox messages.
#   - abschalten: heartbeat `done` "shut down by <caller>", ctl.done result `stopping`, exit 0. protected => `protected`.
#   - the transcript file is group-readable: mode 0640 (explicit chmod: this spec runs under umask 000).
#
#   Expected on the unbuilt tree: the supervisor never looks at AIB_CTL_DIR, so every request is simply ignored.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/fixtures/ctl_harness.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-supctl.XXXXXX")"
trap sup_cleanup EXIT
umask 000
upid_same() { [ "$(lj pid)" = "$SUP_PID" ]; }
started() { jcount supervisor.started; }
started_is() { [ "$(started)" = "$1" ]; }
boot() { start_sup "${1:-acme-core}" "${CTLENV[@]}"; wait_for 10 lj_is state READY; }

# --- T1 unaudited / mismatching requests are rejected by the executor ---------------------------
ctl_world unaud; as human:operator; boot
drop acme-core 1 neustart
wait_for 10 rej_for 1
eq "T1: a request file with NO audit record => ctl.rejected unaudited" "$(rejreason 1)" unaudited
eq "T1: …also in the supervisor's own journal" "$(jfield ctl.rejected 1 reason)" unaudited
eq "T1: …nothing was executed: same process, no re-exec" "$(rej_for 1 && echo rejected)|$(started)|$(lj pid)" "rejected|1|$SUP_PID"
s="$(audit neustart acme-sib human:operator)"; drop acme-core "$s" neustart
wait_for 10 rej_for "$s"; eq "T1: audit names ANOTHER target => unaudited" "$(rejreason "$s")" unaudited
s="$(audit feierabend acme-core human:operator)"; drop acme-core "$s" neustart
wait_for 10 rej_for "$s"; eq "T1: audit names ANOTHER verb => unaudited" "$(rejreason "$s")" unaudited
s="$(audit neustart acme-core human:root)"; drop acme-core "$s" neustart
wait_for 10 rej_for "$s"; eq "T1: audit caller differs from the file owner's identity => unaudited" "$(rejreason "$s")" unaudited
eq "T1: …still the same process, never re-exec'd, state READY" "$(CL count "$CLOG" ctl.rejected)|$(started)|$(lj pid)|$(lj state)" "4|1|$SUP_PID|READY"
drop acme-sib 99 neustart
sleep 1
eq "T1: a request file for ANOTHER agent is left alone (not consumed, not answered)" "$(ls "$CTL" | grep -c '^acme-sib.99.neustart$')|$(CL count "$CLOG" ctl.rejected)" "1|4"
stop_sup

# --- T2 soft neustart = in-process re-exec; consumed seqs never re-run ----------------------------
ctl_world soft; as human:operator; boot
seq0="$(lj seq)"; pid0="$SUP_PID"
s="$(audit neustart acme-core human:operator)"; drop acme-core "$s" neustart
wait_for 10 done_for "$s"
wait_for 10 lj_is state READY
eq "T2: ctl.done recorded" "$(cf ctl.done -1 req)|$(cf ctl.done -1 verb)|$(cf ctl.done -1 target)" "$s|neustart|acme-core"
eq "T2: …audit order: requested < accepted < done" "$(python3 -I - "$CLOG" "$s" <<'PY'
import json, sys
recs = [json.loads(l) for l in open(sys.argv[1])]
want = int(sys.argv[2])
pos = {r["event"]: r["seq"] for r in recs if r.get("req") == want or r.get("seq") == want}
print("ok" if pos["ctl.requested"] < pos["ctl.accepted"] < pos["ctl.done"] else "bad")
PY
)" ok
eq "T2: SAME PID (in-process re-exec, no systemd restart)" "$(done_for "$s" && echo done)|$(lj pid)" "done|$pid0"
eq "T2: …journalled as a second start with reexec:true" "$(started)|$(jfield supervisor.started 2 reexec)" "2|true"
eq "T2: …READY=1 re-sent" "$(grep -cx 'READY=1' "$W/notify.log")" 2
ge "T2: …tick seq continues (never restarts at 1)" "$(done_for "$s" && dl "$(lj seq)" "$seq0")" 1
eq "T2: …journal seq stays gap-free across the re-exec" "$(python3 -I "$SJ" valid "$JOURNAL")|$(started)" "ok|2"
eq "T2: …ctl.done is journalled BEFORE the re-exec" "$([ "$(python3 -I "$SJ" first "$JOURNAL" ctl.done req "$s")" -lt "$(python3 -I "$SJ" first "$JOURNAL" supervisor.started reexec True)" ] && echo before)" before
eq "T2: …ctl.consumed is journalled for that seq" "$(python3 -I "$SJ" first "$JOURNAL" ctl.consumed req "$s" | grep -c .)" 1
crash_sup; boot
sleep 1
eq "T2: after a crash + restart the consumed seq is NOT re-run (file still present)" "$(ls "$CTL" | grep -c "^acme-core.$s.neustart$")|$(started)|$(jcount ctl.done)" "1|3|1"
stop_sup

# --- T3 neustart --hard = ctl.done then exit 75 ----------------------------------------------------
ctl_world hard; as human:operator; boot
s="$(audit neustart acme-core human:operator "" '{"hard": true}')"; drop acme-core "$s" neustart
wait_exit "$SUP_PID"; rc=$RC; SUP_PID=""
eq "T3: hard neustart exits 75 (RestartForceExitStatus)" "$rc" 75
eq "T3: …after recording ctl.done" "$(done_for "$s" && echo yes)" yes

# --- T4 the busy gate and --force ------------------------------------------------------------------
ctl_world busy; as human:operator
boot; plan "0|3|slow turn"
m_send m-1 "a long job"
wait_for 10 lj_is state WORKING
s="$(audit neustart acme-core human:operator)"; drop acme-core "$s" neustart
wait_for 10 rej_for "$s"
eq "T4: WORKING without --force => ctl.rejected busy" "$(rejreason "$s")" busy
eq "T4: …the turn was not disturbed and finishes" "$(wait_for 15 state_is m-1 PROCESSED && m_state m-1)|$(started)" "PROCESSED|1"
cat > "$W/fakes/launch-agent" <<'FAKE'
#!/usr/bin/env bash
w=$(cd -P "$(dirname "$0")/.." && pwd)
n=$( ( flock 9; c=$(cat "$w/calls.n" 2>/dev/null || echo 0); echo $((c+1)) > "$w/calls.n"; echo $((c+1)) ) 9>"$w/calls.lock" )
cat > "$w/prompts/$n"
printf '%s\n' "$n" >> "$w/calls.log"
if [ "$n" -le 1 ] || [ ! -f "$w/second" ]; then sleep 37.31 & echo $! > "$w/gc.pid"; wait; exit 0; fi
echo "replayed ok"; exit 0
FAKE
chmod +x "$W/fakes/launch-agent"; : > "$W/calls.log"; echo 0 > "$W/calls.n"; rm -rf "$W/prompts"; mkdir "$W/prompts"
m_send m-2 "second long job"
wait_for 10 test -s "$W/gc.pid"
gc="$(cat "$W/gc.pid")"
touch "$W/second"                                  # from now on the launcher answers at once
s="$(audit neustart acme-core human:operator "" '{"force": true}')"; drop acme-core "$s" neustart
wait_for 15 done_for "$s"
eq "T4: --force: ctl.done after the grace period" "$(cf ctl.done -1 req)" "$s"
eq "T4: …the launcher's GRANDCHILD is gone (process-group kill)" "$(wait_for 10 bash -c "! kill -0 $gc 2>/dev/null" && echo dead)" dead
wait_for 15 state_is m-2 PROCESSED
eq "T4: …the message stays SEEN until the replay, which then succeeds (2 launches)" "$(m_state m-2)|$(cat "$W/calls.n")|$(done_for "$s" && echo done)" "PROCESSED|2|done"
has "T4: …the replay carries the retry preamble (F10)" "$(cat "$W/prompts/2" 2>/dev/null)" "may already contain"
eq "T4: …a cancelled turn does not count toward the brake" "$(lj brake.consecutive)|$(cf ctl.done -1 req)" "0|$s"
stop_sup

# --- T5 feierabend / standup -------------------------------------------------------------------------
ctl_world duty; as human:operator
plan "0||routine one" "0||routine two"; boot
s="$(audit feierabend acme-core human:operator)"; drop acme-core "$s" feierabend
wait_for 15 done_for "$s"
eq "T5: feierabend ran exactly one routine turn" "$(ncalls)" 1
has "T5: …with the feierabend routine prompt" "$(prompt 1)" "routine:feierabend"
eq "T5: …ctl.done only after that turn ended" "$(wc -l < "$W/ends.log" | tr -d ' ')" 1
wait_for 10 lj_is state WAITING
eq "T5: then WAITING reason off_duty, live.json off_duty:true" "$(lj state)|$(lj state_reason)|$(lj off_duty)" "WAITING|off_duty|true"
m_send m-1 "wait for the stand-up"
sleep 1.2
eq "T5: off duty: the new message is NOT picked up (stays PERSISTED, visible)" "$(m_state m-1)|$(ncalls)" "PERSISTED|1"
crash_sup; start_sup acme-core "${CTLENV[@]}"; wait_for 10 lj_is pid "$SUP_PID"; wait_for 10 lj_is state_reason off_duty
sleep 1
eq "T5: off-duty survives a crash + restart (still no turn)" "$(lj state)|$(lj state_reason)|$(ncalls)" "WAITING|off_duty|1"
s="$(audit standup acme-core human:operator)"; drop acme-core "$s" standup
wait_for 15 done_for "$s"
wait_for 15 state_is m-1 PROCESSED
has "T5: standup runs the briefing turn first (call 2)" "$(prompt 2)" "routine:standup"
has "T5: …then the waiting message (call 3)" "$(prompt 3)" "m-1"
eq "T5: …off duty cleared" "$(lj state)|$(lj off_duty)" "READY|false"
stop_sup

# --- T5b feierabend / standup while a turn runs: rejected busy, never silently dropped ------------------------------------------
ctl_world dutybusy; as human:operator
boot; plan "0|3|slow turn"; m_send m-1 "a long job"
wait_for 10 lj_is state WORKING
for v in feierabend standup; do
  s="$(audit $v acme-core human:operator)"; drop acme-core "$s" $v
  wait_for 10 rej_for "$s"
  eq "T5b: $v while WORKING => ctl.rejected busy (audited)" "$(rejreason "$s")|$(cf ctl.rejected -1 verb)" "busy|$v"
done
wait_for 15 state_is m-1 PROCESSED
sleep 1
eq "T5b: …no routine turn was queued behind the running one (one launch, still READY, not off duty)" "$(ncalls)|$(lj state)|$(lj off_duty)" "1|READY|false"
s="$(audit feierabend acme-core human:operator)"; drop acme-core "$s" feierabend
wait_for 15 done_for "$s"
eq "T5b: once idle the same verb is accepted (guard)" "$(done_for "$s" && echo done)" done
stop_sup

# --- T5c neustart --fresh drops the stored session: the next turn starts a NEW session (journaled) ------------------------------
ctl_world fresh; as human:operator
plan "0||one" "0||two" "0||three"; boot
m_send m-1 a; wait_for 10 state_is m-1 PROCESSED
sid1="$(callf 1 session)"; sid1="${sid1#new:}"
s="$(audit neustart acme-core human:operator)"; drop acme-core "$s" neustart
wait_for 10 done_for "$s"; wait_for 10 lj_is state READY; wait_for 10 started_is 2
m_send m-2 b; wait_for 10 state_is m-2 PROCESSED
eq "T5c: a plain neustart keeps the session: call 2 RESUMES it" "$(callf 2 session)" "$sid1"
s="$(audit neustart acme-core human:operator "" '{"fresh": true}')"; drop acme-core "$s" neustart
wait_for 10 done_for "$s"; wait_for 10 started_is 3
wait_for 10 lj_is state READY
eq "T5c: --fresh: journal session.rotated reason fresh, naming the dropped session" "$(jcount session.rotated)|$(jfield session.rotated 1 reason)|$(jfield session.rotated 1 prev_sid)" "1|fresh|$sid1"
m_send m-3 c; wait_for 10 state_is m-3 PROCESSED
sid3="$(callf 3 session)"
case "$sid3" in new:*) ok "T5c: …the next turn starts a NEW session (new:<uuid>)";; *) no "T5c: …the next turn starts a NEW session (got '$sid3')";; esac
eq "T5c: …a different uuid than before, and it is the session now bound" "$([ "${sid3#new:}" != "$sid1" ] && echo different)|$(jfield session.bound -1 sid)" "different|${sid3#new:}"
stop_sup

# --- T6 abschalten and protected -----------------------------------------------------------------------
live_ready() { [ "$(python3 -I "$JGET" "$W/state/$1/live.json" state)" = READY ]; }
ctl_world off; as human:operator; start_sup acme-sib "${CTLENV[@]}"; wait_for 10 live_ready acme-sib
s="$(audit abschalten acme-sib human:operator)"; drop acme-sib "$s" abschalten
wait_exit "$SUP_PID"; rc=$RC; SUP_PID=""
eq "T6: abschalten => exit 0 (deliberate stop, no restart)" "$rc" 0
eq "T6: …ctl.done result stopping" "$(cf ctl.done -1 result)|$(cf ctl.done -1 req)" "stopping|$s"
has "T6: …heartbeat done naming the caller" "$(cat "$STANDUP/acme-sib.log" 2>/dev/null)" "| done |"
has "T6: …(the text says who shut it down)" "$(cat "$STANDUP/acme-sib.log" 2>/dev/null)" "shut down by human:operator"
for t in acme-guard acme-gate; do
  start_sup "$t" "${CTLENV[@]}"; sp="$SUP_PID"; wait_for 10 live_ready "$t"
  s="$(audit abschalten "$t" human:operator "" '{"force": true}')"; drop "$t" "$s" abschalten
  wait_for 10 rej_for "$s"
  eq "T6: $t (protected) is refused by the executor too, even with force" "$(rejreason "$s")|$(kill -0 "$sp" 2>/dev/null && echo alive)" "protected|alive"
  kill -9 "$sp" 2>/dev/null; wait "$sp" 2>/dev/null; SUP_PID=""
done

# --- T7 reset-brake and neustart clear a tripped brake ----------------------------------------------
ctl_world brake; as human:operator
default "1||E:boom"; m_send m-1 a; m_send m-2 b; m_send m-3 c; start_sup acme-core "${CTLENV[@]}"
wait_for 15 lj_is brake.consecutive 5
eq "T7: brake tripped (precondition)" "$(lj state)|$(lj state_reason)" "FAILED|brake"
default "0||ok now"
s="$(audit reset-brake acme-core human:operator)"; drop acme-core "$s" reset-brake
wait_for 15 done_for "$s"
eq "T7: reset-brake is journalled" "$(jcount brake.reset)" 1
wait_for 15 state_is m-3 PROCESSED
eq "T7: …the loop resumes: the waiting messages run" "$(m_state m-2)|$(m_state m-3)" "PROCESSED|PROCESSED"
eq "T7: …brake counters cleared" "$(lj brake.consecutive)|$(lj brake.tripped_at)" "0|null"
stop_sup
ctl_world brake2; as human:operator
default "1||E:boom"; m_send m-1 a; m_send m-2 b; m_send m-3 c; start_sup acme-core "${CTLENV[@]}"
wait_for 15 lj_is brake.consecutive 5
default "0||ok now"
s="$(audit neustart acme-core human:operator)"; drop acme-core "$s" neustart
wait_for 15 done_for "$s"
wait_for 15 state_is m-3 PROCESSED
eq "T7: neustart also clears the brake (journal brake.reset, loop resumes)" "$(jcount brake.reset)|$(lj brake.consecutive)|$(m_state m-3)" "1|0|PROCESSED"
stop_sup

# --- T7b reset-brake also clears an in-flight session-loss count ----------------
ctl_world lossreset; as human:operator
start_sup acme-core "${CTLENV[@]}" AIB_SUP_POLL_S=1
m_send m-0 "establish a session"; wait_for 10 state_is m-0 PROCESSED
fail_resumes
m_send m-1 "reset between losses"
control_session_losses() { python3 -I - "$JOURNAL" <<'PY'
import json, sys
print(sum(json.loads(line).get("class") == "session_lost" for line in open(sys.argv[1]) if line.strip()))
PY
}
one_session_loss() { [ "$(control_session_losses)" -eq 1 ]; }
wait_for 10 one_session_loss
s="$(audit reset-brake acme-core human:operator)"; drop acme-core "$s" reset-brake
wait_for 10 done_for "$s"
wait_for 15 state_is m-1 FAILED
eq "T7b: reset-brake gives the message a fresh two-loss budget" "$(jcount session.rotated)|$(jcount session.persistence_failed)" "2|1"
stop_sup

# --- T7c a synthetic control turn is failed and bounded after two losses --------
ctl_world controlloss; as human:operator; boot
m_send m-0 "establish a session"; wait_for 10 state_is m-0 PROCESSED
fail_resumes
s="$(audit standup acme-core human:operator)"; drop acme-core "$s" standup
wait_for 15 done_for "$s"
eq "T7c: the failed control request gets a terminal audited result" "$(cf ctl.done -1 req)|$(cf ctl.done -1 result)" "$s|session_persistence_unavailable"
eq "T7c: its second loss is journalled as a persistence failure" "$(jfield session.persistence_failed -1 msg_id)" "control-standup-$s"
calls="$(ncalls)"; sleep 0.8
eq "T7c: the failed synthetic turn is not re-dispatched" "$(ncalls)" "$calls"
stop_sup

# --- T8 the executor repeats the authorization table ---------------------------------------------------
ctl_world authz; as human:operator; boot
xrow() { # xrow <identity> <actor> <verb> <target> <ok|deny>
  printf '%s=%s\n' "$ME_UID" "$1" > "$IDMAP"
  local s; s="$(audit "$3" "$4" "$1" "$2")"; drop "$4" "$s" "$3"
  if [ "$5" = ok ]; then wait_for 15 done_for "$s"; eq "T8: $1 actor='${2:-}' $3 -> executed" "$(done_for "$s" && echo done)" done
  else wait_for 10 rej_for "$s"; eq "T8: $1 actor='${2:-}' $3 -> ctl.rejected unauthorized" "$(rejreason "$s")" unauthorized; fi
}
default "0||ok"
xrow role:aib-agent acme-core standup acme-core ok          # lead claim (registry lead=true)
xrow gateway:gw "" standup acme-core ok
xrow role:aib-agent acme-sib standup acme-core deny         # not a lead
xrow role:aib-agent "" standup acme-core deny
xrow "unknown:$ME_UID" "" standup acme-core deny
xrow gateway:gw "" abschalten acme-core deny
xrow role:aib-agent acme-core abschalten acme-core deny
xrow role:aib-agent acme-core reset-brake acme-core deny
xrow gateway:gw "" reset-brake acme-core deny
eq "T8: nothing destructive ran: 7 refusals, same process, still READY" "$(cc ctl.rejected)|$(lj pid)|$(lj state)" "7|$SUP_PID|READY"
printf '%s=%s\n' "$ME_UID" human:operator > "$IDMAP"
s="$(audit frobnicate acme-core human:operator)"; drop acme-core "$s" frobnicate
wait_for 10 rej_for "$s"; eq "T8: an unknown verb => ctl.rejected unknown_verb" "$(rejreason "$s")" unknown_verb
eq "T8: every record of the run is in one gap-free seq (one allocator), 2 executed" "$(CL valid "$CLOG")|$(cc ctl.done)" "ok|2"
stop_sup

# --- T9 transcript is group-readable ------------------------------------------------------------------------
ctl_world tmode; as human:operator
plan "0||hello transcript"; m_send m-1 "x"; boot
wait_for 10 state_is m-1 PROCESSED
eq "T9: <standup>/transcripts/<uid>.log is mode 0640 (umask 000 must not leak through)" "$(stat -c %a "$TRANSCRIPT" 2>/dev/null)" 640
stop_sup

printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
