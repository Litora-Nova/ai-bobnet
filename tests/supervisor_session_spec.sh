#!/usr/bin/env bash
# ai-bobnet — RED spec for the supervisor's provider-session binding and rotation
# (Supervisor slice S1a-2; design v2 amendments F2 (retry semantics a-d), F10, B5, Q7).
#
# WHAT THIS PINS
#   (a) `session.bound {agent,sid,cwd}` is journalled BEFORE the first launch of a session; the
#       launcher is called with `--session new:<uuid>` for the first turn and `--session <uuid>` after.
#   (b) A turn replayed after a crash (the bound session already has a turn.started) is relaunched as
#       a RESUME of the same uuid, never `new:` twice. A `new:` turn that reports "is already in use"
#       is retried once as a resume, and that retry does not touch the brake.
#   (c) "No conversation found" on a resume = forced ROTATION (new sid, `session.rotated`, a handover
#       note in the agent's OWN inbox marked `kind:handover`, read first by the next turn), not a
#       brake count. Rotation is never silent: no new session without a handover turn (Q7).
#   (d) The bound cwd must equal the registry's project home for the agent; a mismatch rotates
#       (`session.rebound`) instead of resuming the old sid.
#   rotation by policy: registry `session_max_turns` (flat string field, schema 5) -> after that many
#       turns the next unit of work first runs a routine HANDOVER turn in the old session, then the
#       session rotates (`session.rotated reason=max_turns`) and work continues as `new:<uuid>`.
#   The provider's stderr/stdout is read by the supervisor, not the adapter: the adapter passes the
#   strings through (adapter_session_turn_spec T7); this spec fakes them via the launcher.
#
#   Expected on the unbuilt tree: bin/aib-supervisor does not exist -> every assertion fails.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/fixtures/sup_harness.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-supsess.XXXXXX")"
trap sup_cleanup EXIT
UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
is_uuid() { printf '%s\n' "$1" | grep -Eq "$UUID_RE"; }

# --- T1 bind before launch; new: then resume ---------------------------------
sup_world bind
start_sup
m_send m-1 "first"; wait_for 6 state_is m-1 PROCESSED
m_send m-2 "second"; wait_for 6 state_is m-2 PROCESSED
sid="$(callf 1 session)"; sid="${sid#new:}"
if is_uuid "$sid"; then ok "T1: first launch is --session new:<lower-case uuid>"; else no "T1: first launch is --session new:<lower-case uuid> (got '$(callf 1 session)')"; fi
case "$(callf 1 session)" in new:*) ok "T1: …with the new: prefix";; *) no "T1: …with the new: prefix";; esac
eq "T1: second launch resumes the SAME bare uuid" "$(callf 2 session)" "$sid"
eq "T1: session.bound journalled exactly once" "$(jcount session.bound)" 1
eq "T1: …agent" "$(jfield session.bound 1 agent)" acme-core
eq "T1: …sid" "$(jfield session.bound 1 sid)" "$sid"
eq "T1: …cwd = the registry project home" "$(jfield session.bound 1 cwd)" "$HOMEDIR"
eq "T1: session.bound existed before the launcher ran" "$(callf 1 bound)" 1
eq "T1: turn.started names the message" "$(jfield turn.started 1 msg_id)" m-1
eq "T1: turn.started names the session" "$(jfield turn.started 1 sid)" "$sid"
eq "T1: turn.ended is journalled with class ok" "$(jfield turn.ended 1 class)" ok
eq "T1: …and the provider rc" "$(jfield turn.ended 1 rc)" 0
eq "T1: live.json shows the bound session" "$(lj session_id)" "$sid"
eq "T1: …and the turn count in it" "$(lj turns_in_session)" 2
stop_sup

# --- T2 a crash mid new:-turn replays as RESUME ------------------------------
sup_world replay
plan "0|5|never finishes"
start_sup
m_send m-1 "will be interrupted"
wait_for 6 lj_is state WORKING
# S1c G8 (flake): state WORKING can be visible a moment before the fake launcher has logged its call; wait for the call itself
has_call1() { [ -n "$(callf 1 session)" ]; }
wait_for 6 has_call1
sid="$(callf 1 session)"; sid="${sid#new:}"
crash_sup; pkill -9 -f "$W/fakes/launch-agent" 2>/dev/null; rmdir "$W/turn.lock" 2>/dev/null; : > "$W/plan"
start_sup
wait_for 8 state_is m-1 PROCESSED
eq "T2: the interrupted message completes after the restart" "$(m_state m-1)" PROCESSED
eq "T2: relaunched exactly once more" "$(ncalls)" 2
eq "T2: …as a resume of the bound uuid, never new: twice" "$(callf 2 session)" "$sid"
eq "T2: session.bound is not repeated for the same session" "$(jcount session.bound)" 1
has "T2: the replayed turn carries the F10 retry preamble" "$(prompt 2)" "This session may already contain my handling of message m-1."
stop_sup

# --- T3 'is already in use' on new: -> one retry as resume, brake untouched ----
sup_world inuse
plan "1||E:Error: Session ID is already in use"
start_sup
m_send m-1 "collides"
wait_for 8 state_is m-1 PROCESSED
sid="$(callf 1 session)"; sid="${sid#new:}"
eq "T3: exactly two launches" "$(ncalls)" 2
case "$(callf 1 session)" in new:*) ok "T3: the first try was new:<uuid>";; *) no "T3: the first try was new:<uuid>";; esac
eq "T3: the retry is a resume of the same uuid" "$(callf 2 session)" "$sid"
eq "T3: the message completes" "$(m_state m-1)" PROCESSED
eq "T3: the brake never counted it" "$(lj brake.consecutive)" 0
stop_sup

# --- T4 'No conversation found' -> forced rotation, not brake ------------------
sup_world lost
start_sup
m_send m-0 "establish a session"; wait_for 6 state_is m-0 PROCESSED
sidA="$(callf 1 session)"; sidA="${sidA#new:}"
plan "1||E:No conversation found with session ID: $sidA"
m_send m-1 "after the session vanished"
wait_for 10 state_is m-1 PROCESSED
sidB="$(jfield session.bound -1 sid)"
eq "T4: the lost resume was attempted on the old sid" "$(callf 2 session)" "$sidA"
if is_uuid "$sidB" && [ "$sidB" != "$sidA" ]; then ok "T4: a NEW session was bound"; else no "T4: a NEW session was bound (got '$sidB')"; fi
eq "T4: session.rotated journalled" "$(jcount session.rotated)" 1
eq "T4: …reason unknown_sid" "$(jfield session.rotated 1 reason)" unknown_sid
eq "T4: …naming the lost sid" "$(jfield session.rotated 1 prev_sid)" "$sidA"
eq "T4: the brake did not count a lost session" "$(lj brake.consecutive)" 0
case "$(callf 3 session)" in "new:$sidB") ok "T4: the next turn opens new:<new uuid>";; *) no "T4: the next turn opens new:<new uuid> (got '$(callf 3 session)')";; esac
has "T4: …and reads the handover note first" "$(prompt 3)" "kind:handover"
has "T4: the handover note sits in the agent's OWN inbox" "$(grep -F 'kind:handover' "$INBOX")" "from:acme-core | to:acme-core"
eq "T4: the original message then runs in the new session" "$(callf 4 session)" "$sidB"
has "T4: …with its own text" "$(prompt 4)" "after the session vanished"
stop_sup

# --- T5 cwd mismatch -> rebound, never resume the old sid ----------------------
sup_world cwd
start_sup
m_send m-0 "establish a session"; wait_for 6 state_is m-0 PROCESSED
sidA="$(callf 1 session)"; sidA="${sidA#new:}"
stop_sup
mkdir -p "$W/home2"; HOMEDIR="$W/home2"; sup_write_registry 900 ""
start_sup
m_send m-1 "after the project moved"
wait_for 10 state_is m-1 PROCESSED
sidB="$(jfield session.bound -1 sid)"
if [ "$sidB" != "$sidA" ] && is_uuid "$sidB"; then ok "T5: a new session is bound for the new home"; else no "T5: a new session is bound for the new home (got '$sidB')"; fi
eq "T5: …with the new cwd" "$(jfield session.bound -1 cwd)" "$W/home2"
eq "T5: session.rebound journalled" "$(jcount session.rebound)" 1
eq "T5: …for the new sid" "$(jfield session.rebound 1 sid)" "$sidB"
eq "T5: …replacing the old one" "$(jfield session.rebound 1 prev_sid)" "$sidA"
eq "T5: …cwd" "$(jfield session.rebound 1 cwd)" "$W/home2"
eq "T5: the old uuid was never resumed from the new home" "$(is_uuid "$sidA" && [ "$(ncalls)" -ge 3 ] && grep -c "session=$sidA " "$W/calls.log")" 0
eq "T5: …it only ever appeared as the original new:<uuid>" "$(grep -c "session=new:$sidA " "$W/calls.log")" 1
eq "T5: the rotation turn is new:<new uuid> in the new home" "$(callf 2 session)|$(callf 2 cwd)" "new:$sidB|$W/home2"
has "T5: …it reads a handover note" "$(prompt 2)" "kind:handover"
eq "T5: the message then continues in the new session" "$(callf 3 session)" "$sidB"
stop_sup

# --- T6 rotation by policy: session_max_turns, handover turn first -------------
sup_world maxturns
sup_write_registry 900 '"session_max_turns": "2",'
start_sup
m_send m-1 "one"; wait_for 6 state_is m-1 PROCESSED
m_send m-2 "two"; wait_for 6 state_is m-2 PROCESSED
sidA="$(callf 1 session)"; sidA="${sidA#new:}"
m_send m-3 "three"; wait_for 10 state_is m-3 PROCESSED
sidB="$(jfield session.bound -1 sid)"
eq "T6: four launches in total" "$(ncalls)" 4
eq "T6: the third unit of work is still in the OLD session" "$(callf 3 session)" "$sidA"
if printf '%s' "$(prompt 3)" | grep -qi handover; then ok "T6: …and it is a routine handover turn"; else no "T6: …and it is a routine handover turn"; fi
hasnt "T6: …not the message" "$(prompt 3)" "three"
case "$(callf 4 session)" in "new:$sidB") ok "T6: the message then runs as new:<new uuid>";; *) no "T6: the message then runs as new:<new uuid> (got '$(callf 4 session)')";; esac
has "T6: …with its own text" "$(prompt 4)" "three"
eq "T6: session.rotated reason max_turns" "$(jfield session.rotated 1 reason)" max_turns
eq "T6: …naming the old sid" "$(jfield session.rotated 1 prev_sid)" "$sidA"
if is_uuid "$sidA" && is_uuid "$sidB" && [ "$sidB" != "$sidA" ]; then ok "T6: the new session differs"; else no "T6: the new session differs"; fi
eq "T6: the turn count restarted for the new session" "$(lj turns_in_session)" 1
stop_sup

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
