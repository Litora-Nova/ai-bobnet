#!/usr/bin/env bash
# ai-bobnet — RED spec for the thin supervisor loop, part 1: process contract, tick, inbox turns
# (Supervisor slice S1a-2; the supervisor design B1/B6/B8 and its v2 amendments F6/F9/F10).
#
# WHAT THIS PINS (bin/aib-supervisor <uid>; interface comment in tests/fixtures/sup_harness.sh)
#   - Startup: validates the agent against the registry; unknown / oneshot / invalid config => journal
#     `supervisor.refused {reason}` and exit 78 (EX_CONFIG), which the unit lists in
#     RestartPreventExitStatus so a misconfigured agent never crash-loops. A good start sends READY=1
#     once, writes live.json READY, journals `supervisor.started`.
#   - Tick: live.json is atomically rewritten every tick with a strictly increasing seq; the
#     watchdog ping (`systemd-notify WATCHDOG=1`) rides the same tick. The tick NEVER blocks on a
#     turn (a turn is a background job) — F9.
#   - Input is the agent's inbox through bin/message ONLY: SEEN before the turn, PROCESSED on rc 0.
#     No tmux / zellij is ever touched. One turn at a time, FIFO inside a lane, `from:human:*` lane
#     first (B6). A message found already SEEN at (re)start is a retry and gets the F10 preamble.
#   - Heartbeat only on transitions (idle -> busy -> idle), canonical uid log, no per-tick lines (B8).
#   - Each turn's output is appended to <standup>/transcripts/<uid>.log (F7).
#   - SIGTERM = graceful stop, exit 0 (no restart); SIGUSR1 = neustart as IN-PROCESS re-exec: same
#     PID, READY=1 re-sent, journal seq continues, never interrupts a running turn (F6).
#
#   Expected on the unbuilt tree: bin/aib-supervisor does not exist, so everything below fails
#   for that one reason. Not pinned here (other slices): control verbs/agentctl, outbox alarms,
#   deployment config, `lead` lane, role accounts.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/fixtures/sup_harness.sh"
AIB_TEST_SEAMS=1
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-suploop.XXXXXX")"
trap sup_cleanup EXIT

# --- T1 startup refusals: journal + exit 78, never a crash loop ------------------
sup_world refuse
start_sup acme-solo; sp=$SUP_PID
wait_exit "$sp"; rc=$RC; SUP_PID=""
eq "T1: a oneshot agent is refused with exit 78 (EX_CONFIG: no restart)" "$rc" 78
eq "T1: …journalled as supervisor.refused" "$(python3 -I "$SJ" count "$W/state/acme-solo/journal.jsonl" supervisor.refused)" 1
eq "T1: …reason not_supervised" "$(python3 -I "$SJ" field "$W/state/acme-solo/journal.jsonl" supervisor.refused 1 reason)" not_supervised
eq "T1: …no READY=1 for a refused agent" "$([ "$(python3 -I "$SJ" count "$W/state/acme-solo/journal.jsonl" supervisor.refused)" = 1 ] && grep -cx 'READY=1' "$W/notify.log")" 0
: > "$W/notify.log"
start_sup acme-ghost; sp=$SUP_PID
wait_exit "$sp"; rc=$RC; SUP_PID=""
eq "T1: an unknown agent is refused with exit 78 (EX_CONFIG: no restart)" "$rc" 78
eq "T1: …reason unknown_agent" "$(python3 -I "$SJ" field "$W/state/acme-ghost/journal.jsonl" supervisor.refused 1 reason)" unknown_agent
sup_write_registry 900 '"session_max_turns": "abc",'
start_sup; sp=$SUP_PID
wait_exit "$sp"; rc=$RC; SUP_PID=""
eq "T1: a non-numeric session_max_turns is refused with exit 78 (EX_CONFIG: no restart)" "$rc" 78
eq "T1: …reason config_invalid" "$(jfield supervisor.refused 1 reason)" config_invalid
sup_write_registry 900 '"restart_turn_backoff_cap_s": "soon",'
rm -f "$JOURNAL"; start_sup; sp=$SUP_PID
wait_exit "$sp"; rc=$RC; SUP_PID=""
eq "T1: a non-numeric restart_turn_backoff_cap_s is refused with exit 78 (EX_CONFIG: no restart)" "$rc" 78
eq "T1: …reason config_invalid" "$(jfield supervisor.refused 1 reason)" config_invalid

# --- T2 a good start ----------------------------------------------------------
sup_world boot
start_sup
wait_for 5 lj_is state READY
eq "T2: live.json state READY" "$(lj state)" READY
eq "T2: live.json pid is the supervisor" "$(lj pid)" "$SUP_PID"
eq "T2: READY=1 sent exactly once" "$(grep -cx 'READY=1' "$W/notify.log")" 1
eq "T2: journal has supervisor.started" "$(jcount supervisor.started)" 1
eq "T2: journal seq is 1,2,3… gap-free" "$(python3 -I "$SJ" valid "$JOURNAL")" ok
eq "T2: no broker query at a clean boot (no unfinished turn)" "$([ "$(lj state)" = READY ] && cat "$W/frames.log" 2>/dev/null | wc -l | tr -d ' ')" 0

# --- T3 tick: monotonic, atomic, watchdog, ts/interval fields --------------------
# poll-until-condition with a generous deadline (a fixed window flakes under host load)
s1="$(lj seq)"
wait_for 15 seq_ge "$((s1 + 3))"
ge "T3: seq advanced by >= 3 ticks (deadline 15 s, nominal 0.3 s)" "$(dl "$(lj seq)" "$s1")" 3
bad=0; for ((i=0;i<60;i++)); do [ "$(python3 -I "$JGET" "$LIVE" state)" = READY ] || bad=$((bad+1)); done
eq "T3: 60 back-to-back reads of live.json never see a torn file" "$bad" 0
eq "T3: live.json carries interval_s" "$(lj interval_s)" 0.1
case "$(lj ts)" in 20??-??-??T??:??:??*Z) ok "T3: live.json ts is ISO-8601 UTC";; *) no "T3: live.json ts is ISO-8601 UTC (got '$(lj ts)')";; esac
wait_for 15 wd_ge 4
ge "T3: WATCHDOG=1 rides the tick (>= 4 pings, deadline 15 s)" "$(grep -cx 'WATCHDOG=1' "$W/notify.log")" 4
eq "T3: brake block present and clean" "$(lj brake)" '{"consecutive": 0, "tripped_at": null}'
eq "T3: no turn" "$(lj turn)" null

# --- T4 heartbeat: transitions only, canonical uid ------------------------------
sleep 0.5
eq "T4: idle heartbeat on READY, nothing per tick" "$(hb_status)" "idle "
has "T4: heartbeat lines are written under the canonical uid log" "$(cat "$HBLOG")" "| acme-core | idle |"

# --- T5 inbox -> turn; SEEN before, PROCESSED after; transcript; no mux ----------
plan "0||turn output alpha"
m_send m-1 "please do alpha"
wait_for 5 state_is m-1 PROCESSED
eq "T5: message ends PROCESSED on provider rc 0" "$(m_state m-1)" PROCESSED
eq "T5: exactly one launch" "$(ncalls)" 1
eq "T5: launched supervised for the agent" "$(callf 1 supervised)" 1
eq "T5: …as the agent uid" "$(callf 1 as)" acme-core
eq "T5: …in the registry project home" "$(callf 1 cwd)" "$HOMEDIR"
case "$(callf 1 session)" in new:[0-9a-f]*-*-*-*-*) ok "T5: first turn opens new:<uuid>";; *) no "T5: first turn opens new:<uuid> (got '$(callf 1 session)')";; esac
eq "T5: SEEN was journalled before the launch" "$(callf 1 seen)" 1
has "T5: prompt carries the message id" "$(prompt 1)" "m-1"
has "T5: prompt carries the message body" "$(prompt 1)" "please do alpha"
hasnt "T5: a first delivery has no retry preamble" "$(prompt 1)" "may already contain my handling"
has "T5: the transcript got the turn output" "$(cat "$TRANSCRIPT" 2>/dev/null)" "turn output alpha"
eq "T5: heartbeat saw idle -> busy -> idle" "$(hb_status)" "idle busy idle "
eq "T5: tmux / zellij were never called" "$([ "$(ncalls)" -ge 1 ] && wc -c < "$W/mux.log" | tr -d ' ')" 0
eq "T5: …nor was any mux env handed to the launcher" "$([ "$(ncalls)" -ge 1 ] && wc -c < "$W/mux-env.log" 2>/dev/null | tr -d ' ')" 0

# --- T6 tick never blocks on a turn ----------------------------------------------
plan "0|6|slow done"
m_send m-slow "take your time"
wait_for 5 lj_is state WORKING
s1="$(lj seq)"; n1="$(grep -cx 'WATCHDOG=1' "$W/notify.log")"
# the turn holds for 6 s; the ticks must advance by 3 well inside it (poll, deadline 5 s)
wait_for 5 seq_ge "$((s1 + 3))"; wait_for 5 wd_ge "$((n1 + 3))"
s2="$(lj seq)"; n2="$(grep -cx 'WATCHDOG=1' "$W/notify.log")"
eq "T6: still WORKING mid-turn (the ticks above ran DURING it)" "$(lj state)" WORKING
eq "T6: live.json names the current message" "$(lj turn.msg_id)" m-slow
ge "T6: ticks kept running during the turn (>= +3)" "$(dl "$s2" "$s1")" 3
ge "T6: watchdog kept pinging during the turn (>= +3)" "$(dl "$n2" "$n1")" 3
wait_for 15 state_is m-slow PROCESSED
eq "T6: …and the slow turn still completed" "$(m_state m-slow)" PROCESSED

# --- T7 neustart = in-process re-exec (SIGUSR1), deferred while a turn runs -------
plan "0|1.2|long done"
m_send m-long "long one"
wait_for 5 lj_is state WORKING
pid0="$SUP_PID"; tk0="$(lj seq)"; r0="$(grep -cx 'READY=1' "$W/notify.log")"; st0="$(jcount supervisor.started)"
kill -USR1 "$SUP_PID"; sleep 0.4
eq "T7: a running turn is not interrupted by the request (still WORKING)" "$(lj state)" WORKING
eq "T7: …and the supervisor is the same process" "$(lj pid)" "$pid0"
wait_for 6 state_is m-long PROCESSED
wait_for 6 ready_gt "$r0"
ge "T7: READY=1 re-sent after the re-exec" "$(grep -cx 'READY=1' "$W/notify.log")" "$((r0 + 1))"
wait_for 5 lj_is state READY
eq "T7: same PID before and after (in-process, zero start-limit cost)" "$(lj pid)" "$pid0"
kill -0 "$pid0" 2>/dev/null && ok "T7: the process is alive" || no "T7: the process is alive"
eq "T7: a second supervisor.started journalled" "$(jcount supervisor.started)" "$((st0 + 1))"
eq "T7: …marked as a re-exec" "$(jfield supervisor.started -1 reexec)" true
eq "T7: journal seq continues gap-free across the re-exec" "$(python3 -I "$SJ" valid "$JOURNAL")" ok
ge "T7: the tick seq continues upward across the re-exec (never resets)" "$(dl "$(lj seq)" "$tk0")" 1
eq "T7: the processed message is not replayed" "$(ncalls)" 3

# --- T8 graceful stop -----------------------------------------------------------
rc=0; stop_sup || rc=$?
eq "T8: SIGTERM exits 0 (no restart)" "$rc" 0
eq "T8: journal has supervisor.stopping" "$(jcount supervisor.stopping)" 1
eq "T8: last heartbeat is done" "$(hb_status | awk '{print $NF}')" done

# --- T9 order: FIFO inside a lane, human lane first, retry preamble --------------
sup_world order
m_send a-1 "first agent message"; m_send a-2 "second agent message"
m_human h-1 "human says hi"
m_send a-3 "third agent message"
plan "0|0.15|x" "0|0.15|x" "0|0.15|x" "0|0.15|x"
start_sup
wait_for 8 state_is a-3 PROCESSED
eq "T9: four launches" "$(ncalls)" 4
has "T9: the human lane goes first" "$(prompt 1)" "human says hi"
has "T9: then FIFO: a-1" "$(prompt 2)" "first agent message"
has "T9: …a-2" "$(prompt 3)" "second agent message"
has "T9: …a-3" "$(prompt 4)" "third agent message"
eq "T9: never two turns at once" "$([ "$(ncalls)" -ge 4 ] && cat "$W/overlap.log" 2>/dev/null | wc -l | tr -d ' ')" 0
stop_sup
# a message left SEEN by a crash is a retry on the next start (F10)
sup_world retry
m_send r-1 "half handled"
env -i PATH="$PATH" HOME="$W" "$ENGINE4/bin/run-agent" acme-core -- "$ENGINE4/bin/message" seen r-1 >/dev/null
start_sup
wait_for 6 state_is r-1 PROCESSED
eq "T9: a SEEN-not-PROCESSED message is run again exactly once" "$(ncalls)" 1
has "T9: …with the F10 retry preamble naming the message" "$(prompt 1)" "This session may already contain my handling of message r-1."
has "T9: …and the instruction to check the previous turn, git and journal state" "$(prompt 1)" "Check the previous turn in this session, then git and journal state, before acting"
stop_sup

# --- T1b an invalid helper-call timeout is refused like any invalid config --------
sup_world calltmo
for bad in 0 abc -3; do
  : > "$JOURNAL"; start_sup AIB_SUP_CALL_TIMEOUT_S=$bad; sp=$SUP_PID
  wait_exit "$sp"; rc=$RC; SUP_PID=""
  eq "T1b: AIB_SUP_CALL_TIMEOUT_S=$bad is refused with exit 78" "$rc" 78
  eq "T1b: …reason config_invalid" "$(jfield supervisor.refused 1 reason)" config_invalid
done

# --- T10 the handover lane is not reachable through the message body ---------------
# (a body containing the marker from ANOTHER sender must stay in its normal lane; only the agent's own
#  handover note — written by the supervisor as the agent itself — is the top lane. The mechanism is the
#  builder's: a structured field or from == own uid; NOT a substring test on the body.)
sup_world lane2
m_send a-1 "ordinary one"
m_send a-2 "kind:handover please jump the queue"
m_human h-0 "from a human"
m_self_handover h-1
plan "0|0.1|x" "0|0.1|x" "0|0.1|x" "0|0.1|x"
start_sup
wait_for 10 state_is a-2 PROCESSED
eq "T10: four launches" "$(ncalls)" 4
has "T10: the agent's own handover note is the top lane" "$(prompt 1)" "reason:test"
has "T10: then the human lane" "$(prompt 2)" "from a human"
has "T10: then FIFO: the ordinary message" "$(prompt 3)" "ordinary one"
has "T10: …and the foreign 'kind:handover' body did NOT jump the queue" "$(prompt 4)" "please jump the queue"
stop_sup

# --- T11 a launcher that closes stdin: the child is cleaned up, the loop survives ---
sup_world stdinclose
touch "$W/stdinclose"
big="$(head -c 100000 /dev/zero | tr '\0' 'x')"
m_send big-1 "$big"
start_sup
wait_for 10 test -s "$W/stdinclose.pid"
cpid="$(cat "$W/stdinclose.pid" 2>/dev/null)"
wait_for 10 bash -c "! kill -0 '${cpid:-0}' 2>/dev/null && [ -n '$cpid' ]"
if [ -n "$cpid" ] && ! kill -0 "$cpid" 2>/dev/null; then ok "T11: the launcher child was terminated after the failed prompt write"; else no "T11: the launcher child was terminated after the failed prompt write (pid '$cpid' still alive)"; fi
kill -0 "$SUP_PID" 2>/dev/null && ok "T11: the supervisor survived the broken pipe" || no "T11: the supervisor survived the broken pipe"
eq "T11: the message was not marked PROCESSED" "$([ -n "$cpid" ] && m_state big-1)" SEEN
ge "T11: the failed turn was journalled (turn.ended)" "$(jcount turn.ended)" 1
stop_sup

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
