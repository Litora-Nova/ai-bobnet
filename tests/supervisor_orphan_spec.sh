#!/usr/bin/env bash
# ai-bobnet — RED spec for orphan adoption at supervisor boot (Supervisor slice S1a-2; B9 + F9;
# DOMAIN invariant (j): "a living orphaned session is adopted, not duplicated").
#
# WHAT THIS PINS
#   The broker ignores SIGPIPE, so a provider turn can outlive a crashed supervisor. At boot, when the
#   journal shows a `turn.started` without a matching `turn.ended`, the supervisor asks the broker
#   through $AIB_BROKER_CLIENT for the live lease count of ITS OWN label:
#       frame on stdin:   op=leases / agent_uid=<uid> / prompt_bytes=0 / <blank line>
#       answer:           supervised=<n> / other=<m> / end=ok       (tests/broker_leases_spec.sh)
#   - supervised >= 1 -> state ORPHANED (reason orphan): no new turn, poll every AIB_SUP_ORPHAN_POLL_S;
#   - the wait is bounded by the provider's registry `cap_timeout`: after that the supervisor logs
#     `orphan.timeout` and carries on (a lease that outlives cap_timeout is not a live turn);
#   - once it clears, the unfinished turn is closed (`turn.ended class=orphan_gone`) and the message
#     replays exactly once as a RESUME of the bound session;
#   - `other` leases (a human's one-shot run-agent --as) never stall the supervisor (F9);
#   - no unfinished turn in the journal -> the broker is not asked at all.
#
#   Expected on the unbuilt tree: bin/aib-supervisor does not exist -> every assertion fails.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/fixtures/sup_harness.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-suporph.XXXXXX")"
trap sup_cleanup EXIT
SID="3f2b8c1e-9d4a-4e6b-8a7c-1b2d3e4f5a6b"

seed_unfinished() { # a journal as left by a kill -9 mid-turn
  local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  cat > "$JOURNAL" <<JSON
{"seq":1,"ts":"$ts","event":"supervisor.started","pid":1,"reexec":false}
{"seq":2,"ts":"$ts","event":"session.bound","agent":"acme-core","sid":"$SID","cwd":"$HOMEDIR"}
{"seq":3,"ts":"$ts","event":"turn.started","msg_id":"m-1","sid":"$SID","attempt":1}
JSON
  m_send m-1 "interrupted by a crash"
  env -i PATH="$PATH" HOME="$W" "$ENGINE4/bin/run-agent" acme-core -- "$ENGINE4/bin/message" seen m-1 >/dev/null
}

# --- T1 a live supervised lease -> ORPHANED, then adopt -----------------------------
sup_world adopt
seed_unfinished
printf 'supervised=1\nother=0\nend=ok\n' > "$W/leases.answer"
start_sup
wait_for 5 lj_is state ORPHANED
eq "T1: state ORPHANED while the old turn's lease is live" "$(lj state)" ORPHANED
eq "T1: …reason orphan" "$(lj state_reason)" orphan
sleep 0.5
eq "T1: no new turn while orphaned (adopt, don't duplicate)" "$([ "$(lj state)" = ORPHANED ] && ncalls)" 0
ge "T1: the broker is polled while waiting (>= 3 frames)" "$(grep -c '^---$' "$W/frames.log")" 3
eq "T1: the frame is exactly the leases request for the agent's own label" "$(sed -n '1,/^---$/p' "$W/frames.log" | head -n -1 | tr '\n' '~')" "op=leases~agent_uid=acme-core~prompt_bytes=0~~"
printf 'supervised=0\nother=0\nend=ok\n' > "$W/leases.answer"
wait_for 6 state_is m-1 PROCESSED
eq "T1: after the lease ends the message replays once" "$(ncalls)" 1
eq "T1: …as a RESUME of the bound session" "$(callf 1 session)" "$SID"
eq "T1: …no second session was bound" "$([ "$(ncalls)" -ge 1 ] && jcount session.bound)" 1
has "T1: …with the retry preamble" "$(prompt 1)" "This session may already contain my handling of message m-1."
eq "T1: the dead turn was closed as orphan_gone" "$(jfield turn.ended 1 class)" orphan_gone
eq "T1: …that close did not count toward the brake" "$(lj brake.consecutive)" 0
stop_sup

# --- T2 the wait is bounded by cap_timeout ------------------------------------------
sup_world bounded 1
seed_unfinished
printf 'supervised=1\nother=0\nend=ok\n' > "$W/leases.answer"
start_sup
wait_for 3 lj_is state ORPHANED
eq "T2: starts ORPHANED" "$(lj state)" ORPHANED
wait_for 6 state_is m-1 PROCESSED
eq "T2: after cap_timeout (1 s) the supervisor stops waiting and carries on" "$(m_state m-1)" PROCESSED
eq "T2: …journalled as orphan.timeout" "$(jcount orphan.timeout)" 1
stop_sup

# --- T3 other leases never orphan ---------------------------------------------------
sup_world other
seed_unfinished
printf 'supervised=0\nother=3\nend=ok\n' > "$W/leases.answer"
start_sup
wait_for 4 state_is m-1 PROCESSED
eq "T3: a human's one-shot leases (other=3) do not stall the loop" "$(m_state m-1)" PROCESSED
eq "T3: …no orphan.timeout was needed" "$([ "$(m_state m-1)" = PROCESSED ] && jcount orphan.timeout)" 0
stop_sup

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
