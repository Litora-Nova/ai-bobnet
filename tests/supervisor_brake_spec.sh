#!/usr/bin/env bash
# ai-bobnet — RED spec for the supervisor's turn-failure classes and the inner crash brake
# (Supervisor slice S1a-2; design B9 as amended by F6).
#
# THE LAUNCHER-RESULT MAPPING THIS SPEC PINS (launcher = $AIB_LAUNCH_AGENT, rc + combined output)
#   rc 0 with output                    -> class ok:        message PROCESSED, brake reset to 0
#   rc 75 (EX_TEMPFAIL, over_capacity)  -> class infra, state WAITING reason=capacity
#   rc 78 (adapter config/credential)   -> class infra, state WAITING reason=infra
#   rc 69 (EX_UNAVAILABLE: broker/registry/event-store error)
#                                       -> class infra, state WAITING reason=infra
#   rc 0 with EMPTY output (the socket's silent MaxConnections close, F6)
#                                       -> class infra, state WAITING reason=infra
#   anything else non-zero (1, 124 timeout, 130/137/143 aborted/killed, 64/65, …)
#                                       -> class provider_failure: the ONLY class that counts.
#   Infra faults NEVER count toward any brake; they back off (jittered MIN..MAX) and retry forever;
#   after AIB_SUP_BLOCKED_AFTER_S in the class: ONE heartbeat `blocked`, and the loop self-heals.
#   (The outbox alarm of F6 belongs to S1b and is not pinned here.)
#
# THE BRAKE
#   - a message failing 3 turns in a row is FAILED (DLQ, with a reason) and the loop moves on;
#   - 5 consecutive provider failures across messages -> state FAILED reason=brake, brake.tripped_at
#     set, heartbeat `blocked`; the loop stays alive (ticks continue) but starts NO further turn;
#   - backoff between failed attempts: base * 2^(n-1), capped (AIB_SUP_BACKOFF_BASE_S/_CAP_S);
#   - the counters live in the journal: a process restart does NOT reset them (neither the
#     per-message count nor the consecutive count nor the tripped state).
#   - every turn.ended record carries `class`, `rc` and `brake` (consecutive count AFTER the turn).
#   Clearing a tripped brake is a control verb (S1b) and is not pinned here.
#
#   Expected on the unbuilt tree: bin/aib-supervisor does not exist -> every assertion fails.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/fixtures/sup_harness.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-supbrake.XXXXXX")"
trap sup_cleanup EXIT
gap() { awk -v a="$(sed -n "$1p" "$W/calls.log" | tr ' ' '\n' | grep '^t=' | cut -d= -f2)" -v b="$(sed -n "$2p" "$W/calls.log" | tr ' ' '\n' | grep '^t=' | cut -d= -f2)" 'BEGIN{printf "%.3f", b-a}'; }

# --- T1 the brake trips at 5 consecutive provider failures; a message dies at 3 ---
sup_world trip
m_send m-1 "doomed one"; m_send m-2 "doomed two"; m_send m-3 "never started"
plan "1||E:boom" "124||" "143||" "1||E:boom" "137||"
start_sup
wait_for 10 lj_is brake.consecutive 5
eq "T1: five provider failures, five launches" "$(ncalls)" 5
eq "T1: the first message is FAILED after 3 consecutive failures" "$(m_state m-1)" FAILED
has "T1: …and sits in the DLQ with a reason" "$(m_dlq)" "id:m-1"
has "T1: …reason names the failure" "$(m_dlq)" "reason:"
eq "T1: calls 1-3 were the first message, 4-5 the second" "$(for i in 1 2 3; do prompt $i | grep -q 'm-1' && printf 1 || printf 0; done)$(for i in 4 5; do prompt $i | grep -q 'm-2' && printf 1 || printf 0; done)" "11111"
eq "T1: brake.consecutive = 5" "$(lj brake.consecutive)" 5
case "$(lj brake.tripped_at)" in 20??-*Z) ok "T1: brake.tripped_at is set (ISO UTC)";; *) no "T1: brake.tripped_at is set (got '$(lj brake.tripped_at)')";; esac
eq "T1: state FAILED" "$(lj state)" FAILED
eq "T1: …reason brake" "$(lj state_reason)" brake
eq "T1: the second message is neither done nor failed (stays SEEN)" "$(m_state m-2)" SEEN
s1="$(lj seq)"; wait_for 15 seq_ge "$((s1 + 3))"; s2="$(lj seq)"
ge "T1: the loop stays alive: ticks continue while FAILED (>= +3, poll deadline 15 s)" "$(dl "$s2" "$s1")" 3
eq "T1: …and no turn is started after the trip (3rd message untouched)" "$(ncalls)" 5
eq "T1: …the third message is still unseen" "$([ "$(ncalls)" -ge 5 ] && m_state m-3)" PERSISTED
eq "T1: last heartbeat is blocked" "$(hb_status | awk '{print $NF}')" blocked
ge "T1: backoff after failure 1 >= base (0.1 s)" "$(gap 1 2)" 0.09
ge "T1: backoff after failure 2 >= 2*base (0.2 s)" "$(gap 2 3)" 0.18
ge "T1: backoff after failure 4 >= base*2^3 capped at 0.4 s" "$(gap 4 5)" 0.36
eq "T1: turn.ended brake counts run 1,2,3,4,5" "$(for i in 1 2 3 4 5; do jfield turn.ended $i brake; done | tr '\n' ' ')" "1 2 3 4 5 "
eq "T1: …every one is class provider_failure" "$(for i in 1 2 3 4 5; do jfield turn.ended $i class; done | sort -u | tr '\n' ' ')" "provider_failure "
eq "T1: …with the real rc recorded (124 timeout)" "$(jfield turn.ended 2 rc)" 124

# the tripped brake survives a restart
stop_sup; : > "$W/calls.log"; echo 0 > "$W/calls.n"
start_sup
wait_for 5 lj_is state FAILED
eq "T2: a restart keeps the tripped brake (consecutive 5)" "$(lj brake.consecutive)" 5
eq "T2: …state FAILED/brake right after the restart" "$(lj state)/$(lj state_reason)" "FAILED/brake"
sleep 0.5
eq "T2: …and still starts no turn" "$([ "$(lj state)" = FAILED ] && ncalls)" 0
stop_sup

# --- T3 counters persist mid-way across restarts ----------------------------------
sup_world persist
m_send m-1 "flaky"
plan "1||E:boom" "1||E:boom" "1||E:boom"
start_sup AIB_SUP_BACKOFF_BASE_S=5 AIB_SUP_BACKOFF_CAP_S=5
wait_for 6 lj_is brake.consecutive 1
crash_sup
start_sup
wait_for 8 state_is m-1 FAILED
eq "T3: the per-message count survived the crash: 3 failures over two lives = FAILED" "$(m_state m-1)" FAILED
eq "T3: …exactly three launches in total" "$(ncalls)" 3
eq "T3: …and the consecutive count carried over (3, not 2)" "$(lj brake.consecutive)" 3
stop_sup

# --- T4 infra faults never count; capacity shows as WAITING ----------------------
sup_world capacity
plan "75||"
m_send m-1 "queued behind a full pool"
start_sup AIB_SUP_INFRA_BACKOFF_MIN_S=0.8 AIB_SUP_INFRA_BACKOFF_MAX_S=0.8
wait_for 5 lj_is state_reason capacity
eq "T4: over_capacity (75) -> WAITING" "$(lj state)" WAITING
eq "T4: …reason capacity" "$(lj state_reason)" capacity
eq "T4: …no brake count" "$(lj brake.consecutive)" 0
wait_for 6 state_is m-1 PROCESSED
eq "T4: the message runs afterwards without a human" "$(m_state m-1)" PROCESSED
eq "T4: first turn.ended is class infra" "$(jfield turn.ended 1 class)" infra
eq "T4: …brake stays 0" "$(jfield turn.ended 1 brake)" 0
stop_sup

sup_world infra
plan "78||E:no credential" "75||" "69||" "0||" "0||recovered"
m_send m-1 "through the storm"
start_sup
wait_for 10 state_is m-1 PROCESSED
eq "T5: 78, 75, 69 and an empty rc-0 body, then success: five launches" "$(ncalls)" 5
eq "T5: the message completes" "$(m_state m-1)" PROCESSED
eq "T5: the classes are infra x4 then ok" "$(for i in 1 2 3 4 5; do jfield turn.ended $i class; done | tr '\n' ' ')" "infra infra infra infra ok "
eq "T5: no infra fault counted: brake 0 on all five" "$(for i in 1 2 3 4 5; do jfield turn.ended $i brake; done | sort -u | tr '\n' ' ')" "0 "
eq "T5: the brake never tripped" "$(lj brake.tripped_at)" null
has "T5: the successful turn's output reached the transcript" "$(cat "$TRANSCRIPT" 2>/dev/null)" recovered
stop_sup

# --- T6 provider failures count, infra in between does not reset or add -----------
sup_world mixed
plan "1||E:boom" "78||" "78||" "1||E:boom"
m_send m-1 "mixed"
start_sup
wait_for 10 state_is m-1 PROCESSED
eq "T6: classes: provider, infra, infra, provider, ok" "$(for i in 1 2 3 4 5; do jfield turn.ended $i class; done | tr '\n' ' ')" "provider_failure infra infra provider_failure ok "
eq "T6: brake counts 1,1,1,2 — infra neither adds nor resets" "$(for i in 1 2 3 4; do jfield turn.ended $i brake; done | tr '\n' ' ')" "1 1 1 2 "
eq "T6: success resets the count" "$(jfield turn.ended 5 brake)" 0
eq "T6: …live.json agrees" "$(lj brake.consecutive)" 0
stop_sup

# --- T7 a long infra outage: one blocked heartbeat, no brake, self-heal ------------
sup_world outage
default "78||E:credential outage"
m_send m-1 "waits out the outage"
start_sup AIB_SUP_BLOCKED_AFTER_S=0.6
wait_for 6 bash -c "grep -q '| blocked |' '$HBLOG'"
sleep 0.8
eq "T7: exactly one blocked heartbeat despite many retries" "$(grep -c '| blocked |' "$HBLOG")" 1
ge "T7: it kept retrying (>= 4 launches)" "$(ncalls)" 4
eq "T7: no brake" "$(lj brake.consecutive)" 0
eq "T7: heartbeat stays quiet while retrying (transitions only)" "$(hb_status)" "idle busy blocked "
case "$(lj state)" in WAITING|WORKING) ok "T7: the loop is not in FAILED (it is waiting/retrying)";; *) no "T7: the loop is not in FAILED (got '$(lj state)')";; esac
default "0||ok again"
wait_for 6 state_is m-1 PROCESSED
eq "T7: the outage heals without a human" "$(m_state m-1)" PROCESSED
eq "T7: …and the heartbeat returns to idle" "$(hb_status | awk '{print $NF}')" idle
stop_sup

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
