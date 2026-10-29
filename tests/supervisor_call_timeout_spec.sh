#!/usr/bin/env bash
# ai-bobnet — RED spec: AIB_SUP_CALL_TIMEOUT_S really bounds every helper call, and a timeout kills the WHOLE process group
# (S1a follow-up S4, carried into S1b). Today `subprocess.run(timeout=)` kills only the direct child: a hung GRANDCHILD (the real
# `bin/run-agent` runs `bin/message` through a shell) survives, still holds the call's stdout pipe, and piles up.
#
# WHAT THIS PINS (hermetic hook: the supervisor runs from a COPY of the engine, so the spec replaces $ENGINE/bin/run-agent and
# $W/fakes/broker-client with fakes that spawn a long-lived grandchild and hang — no production code path is faked)
#   - a hanging run-agent/bin/message call: the supervisor gives up after AIB_SUP_CALL_TIMEOUT_S (0.3 s here), the call's whole
#     process group is killed (the grandchild too, polled with a deadline), the loop keeps ticking meanwhile, and the next
#     poll tries again (no wedge, no pile-up: at most one hung call alive at a time).
#   - the same for the broker client (`leases` query while ORPHANED), grandchild included.
#   - SIGTERM during a hung call still ends the supervisor promptly with exit 0 (bounded by the call timeout, not by the hang).
#   - the launcher TURN itself is not bound by the call timeout (the harness comment): a 5 s turn with a 3 s call timeout
#     finishes normally and is PROCESSED.
#
#   Expected on the unbuilt tree: the direct child dies, the grandchildren survive.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/fixtures/sup_harness.sh"
AIB_TEST_SEAMS=1
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-suptmo.XXXXXX")"
cleanup2() { local p; for p in $(cat "${W:-/nonexistent}/gc.pids" 2>/dev/null); do kill -9 "$p" 2>/dev/null; done; sup_cleanup; }
trap cleanup2 EXIT
gc_alive() { local n=0 p; for p in $(cat "$W/gc.pids" 2>/dev/null); do kill -0 "$p" 2>/dev/null && n=$((n+1)); done; echo "$n"; }
gc_count() { wc -l < "$W/gc.pids" 2>/dev/null | tr -d ' '; }
alive_le1() { [ "$(gc_alive)" -le 1 ]; }
none_alive() { [ "$(gc_alive)" = 0 ]; }
ge2() { [ "$(gc_count)" -ge "$1" ]; }

# --- T1 hung run-agent/bin/message call with a surviving grandchild --------------------------------------------------
sup_world msg
cat > "$ENGINE/bin/run-agent" <<FAKE
#!/usr/bin/env bash
echo \$\$ >> "$W/hang.pids"
sleep 31.7 & echo \$! >> "$W/gc.pids"
wait
FAKE
chmod +x "$ENGINE/bin/run-agent"
start_sup AIB_SUP_CALL_TIMEOUT_S=0.3
wait_for 15 ge2 3
ge "T1: the poll is retried after each timeout (>= 3 hung calls started, deadline 15 s)" "$(gc_count)" 3
s1="$(lj seq)"; wait_for 15 seq_ge "$((s1 + 3))"
ge "T1: the loop keeps ticking while calls hang (>= +3)" "$(dl "$(lj seq)" "$s1")" 3
wait_for 5 alive_le1
ge "T1: hung grandchildren are killed, not piled up (alive <= 1 of $(gc_count))" "$(( 1 - $(gc_alive) ))" 0
kill -TERM "$SUP_PID"; t0=$(date +%s.%N); rc=0; wait "$SUP_PID" || rc=$?; t1=$(date +%s.%N); SUP_PID=""
eq "T1: SIGTERM during a hung call => exit 0" "$rc" 0
ge "T1: …and promptly (< 5 s, got $(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", b-a}') s)" "$(awk -v a="$t0" -v b="$t1" 'BEGIN{print 5-(b-a)}')" 0
wait_for 10 none_alive
eq "T1: …and no grandchild outlives the supervisor" "$(gc_alive)" 0

# --- T2 hung broker client with a surviving grandchild (ORPHANED wait polls `leases`) ---------------------------------------
sup_world brk
cat > "$W/fakes/broker-client" <<FAKE
#!/usr/bin/env bash
cat >/dev/null
echo \$\$ >> "$W/hang.pids"
sleep 31.7 & echo \$! >> "$W/gc.pids"
wait
FAKE
chmod +x "$W/fakes/broker-client"
# an unfinished turn in the journal forces the ORPHANED path at boot (as tests/supervisor_orphan_spec.sh seeds it)
SID="3f2b8c1e-9d4a-4e6b-8a7c-1b2d3e4f5a6b"; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$JOURNAL" <<JSON
{"seq":1,"ts":"$ts","event":"supervisor.started","pid":1,"reexec":false}
{"seq":2,"ts":"$ts","event":"session.bound","agent":"acme-core","sid":"$SID","cwd":"$HOMEDIR"}
{"seq":3,"ts":"$ts","event":"turn.started","msg_id":"m-1","sid":"$SID","attempt":1}
JSON
m_send m-1 "interrupted by a crash"
env -i PATH="$PATH" HOME="$W" "$ENGINE4/bin/run-agent" acme-core -- "$ENGINE4/bin/message" seen m-1 >/dev/null
start_sup AIB_SUP_CALL_TIMEOUT_S=0.3
wait_for 15 ge2 3
ge "T2: the leases query is re-issued after each timeout (>= 3 calls)" "$(gc_count)" 3
wait_for 5 alive_le1
ge "T2: …hung broker-client grandchildren are killed (alive <= 1 of $(gc_count))" "$(( 1 - $(gc_alive) ))" 0
eq "T2: …the supervisor is still ORPHANED-waiting, alive and ticking" "$(lj state)|$(kill -0 "$SUP_PID" 2>/dev/null && echo alive)" "ORPHANED|alive"
stop_sup; wait_for 10 none_alive
eq "T2: …nothing outlives it" "$(gc_alive)" 0

# --- T3 the turn is NOT bound by the call timeout ---------------------------------------------------------------------------
sup_world turn
plan "0|5|long but fine"; m_send m-1 x
start_sup AIB_SUP_CALL_TIMEOUT_S=3          # real run-agent/message calls need well under 3 s; the TURN takes 5 s
wait_for 30 state_is m-1 PROCESSED
eq "T3: a 5 s turn with a 3 s call timeout completes (PROCESSED, one launch)" "$(m_state m-1)|$(ncalls)" "PROCESSED|1"
stop_sup

# --- T4 a grandchild that ESCAPED the process group and still holds the pipe must not block the loop (bounded wait after the kill) --------
sup_world escape
cat > "$ENGINE/bin/run-agent" <<FAKE
#!/usr/bin/env bash
echo \$\$ >> "$W/hang.pids"
setsid sleep 31.9 &
echo \$! >> "$W/gc.pids"
wait
FAKE
chmod +x "$ENGINE/bin/run-agent"
start_sup AIB_SUP_CALL_TIMEOUT_S=0.3
wait_for 20 ge2 2
s1="$(lj seq)"; wait_for 20 seq_ge "$((s1 + 5))"
ge "T4: the loop keeps ticking although an escaped grandchild holds the call's stdout (>= +5 ticks in 20 s; blocked ~32 s otherwise)" "$(dl "$(lj seq)" "$s1")" 5
eq "T4: …and the helper is retried (>= 2 calls started)" "$([ "$(gc_count)" -ge 2 ] && echo yes)" yes
kill -TERM "$SUP_PID"; t0=$(date +%s.%N); rc=0; wait "$SUP_PID" || rc=$?; t1=$(date +%s.%N); SUP_PID=""
eq "T4: SIGTERM still ends it with exit 0" "$rc" 0
ge "T4: …within 5 s" "$(awk -v a="$t0" -v b="$t1" 'BEGIN{print 5-(b-a)}')" 0
pkill -9 -f 'sleep 31.9' 2>/dev/null

# --- T5 the same for the broker client ----------------------------------------------------------------------------------------------
sup_world escape2
cat > "$W/fakes/broker-client" <<FAKE
#!/usr/bin/env bash
cat >/dev/null
echo \$\$ >> "$W/hang.pids"
setsid sleep 31.9 &
echo \$! >> "$W/gc.pids"
wait
FAKE
chmod +x "$W/fakes/broker-client"
SID="3f2b8c1e-9d4a-4e6b-8a7c-1b2d3e4f5a6b"; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$JOURNAL" <<JSON
{"seq":1,"ts":"$ts","event":"supervisor.started","pid":1,"reexec":false}
{"seq":2,"ts":"$ts","event":"session.bound","agent":"acme-core","sid":"$SID","cwd":"$HOMEDIR"}
{"seq":3,"ts":"$ts","event":"turn.started","msg_id":"m-1","sid":"$SID","attempt":1}
JSON
m_send m-1 "interrupted by a crash"
env -i PATH="$PATH" HOME="$W" "$ENGINE4/bin/run-agent" acme-core -- "$ENGINE4/bin/message" seen m-1 >/dev/null
start_sup AIB_SUP_CALL_TIMEOUT_S=0.3
wait_for 20 ge2 2
s1="$(lj seq)"; wait_for 20 seq_ge "$((s1 + 5))"
ge "T5: the leases query does not block the loop behind an escaped grandchild (>= +5 ticks in 20 s)" "$(dl "$(lj seq)" "$s1")" 5
stop_sup
pkill -9 -f 'sleep 31.9' 2>/dev/null

printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
