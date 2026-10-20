#!/usr/bin/env bash
# ai-bobnet — RED spec for how the supervisor reacts to a missing/expired login and for the G8 alarm follow-ups
# (Supervisor slice S1c; design v3 G5, v3.1 H6, v3.2 J1 "Expiry during a turn -> 401 -> class (c) retry, never a child refresh").
#
# WHAT THIS PINS
#   - Login-shaped failures are the INFRA class (no brake, backoff, heartbeat blocked after AIB_SUP_BLOCKED_AFTER_S, auto-heal) when the adapter says
#     so: exit 78 (with the marker `hint:login` for the login hint). v3.5 L5: free text such as `Not logged in` or `401` in agent output never does it
#     (T2/T2b: it is an ordinary failure that counts toward the brake).
#   - The infra_blocked alarm now carries WHERE it comes from, so a hub can collapse N agents of one expired login into one message:
#         alarm:infra_blocked agent:<uid> provider:<registry provider of the agent's project> [hint:login]
#     `hint:login` is present exactly when the failing attempt exited 78 AND its stderr carried the adapter marker `hint:login`; absent otherwise.
#   - write_alarm dedupe is keyed on the EPISODE, not on the kind for the journal's lifetime: one infra outage = one alarm; after the loop heals
#     (a turn succeeds) a LATER outage alarms again (brake_tripped already does this per tripped_at; pinned again as a guard).
#   - A failed attempt never makes the supervisor touch a credential: the fake launcher is the only thing called (no refresher, no login command).
#
#   (v3.5 L5, T2/T2b: free-text login phrases at rc 1 count toward the brake; they are RED against the v3.4 implementation.)
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/fixtures/ctl_harness.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-suplogin.XXXXXX")"
# gate round 1 (Marvin 4./Riker): the supervisor can still be writing episodes/ when the plain cleanup removes the tree
# ("rm: Directory not empty", ~3300 stale /tmp/aibobnet-* dirs). Reap the supervisor and the fakes first, then retry the removal until it is gone.
login_cleanup() {
  if [ -n "${SUP_PID:-}" ]; then kill -9 "$SUP_PID" 2>/dev/null; wait "$SUP_PID" 2>/dev/null; SUP_PID=""; fi
  [ -z "${W:-}" ] || pkill -9 -f "$W/fakes/" 2>/dev/null
  local i; for i in 1 2 3 4 5 6 7 8 9 10; do rm -rf "$WORK" 2>/dev/null; [ ! -e "$WORK" ] && break; sleep 0.2; done
}
trap login_cleanup EXIT
OB() { cat "$OUTBOX/acme-engine/outbox.md" 2>/dev/null; }
obn() { OB | grep -c "alarm:$1"; }
ob_has() { [ "$(obn "$1")" -ge "$2" ]; }

# --- T1 provider + hint on infra_blocked --------------------------------------------------------------------------------------------------------------
ctl_world hint
default "78||E:codex adapter: credential mode shared: access token inside the refresh margin hint:login"; m_send m-1 x
start_sup acme-core "${CTLENV[@]}" AIB_SUP_BLOCKED_AFTER_S=0.6
wait_for 5 ob_has infra_blocked 1
line="$(OB | grep 'alarm:infra_blocked' | head -1)"
has "T1: infra_blocked names agent, provider and the login hint" "$line" "| alarm:infra_blocked agent:acme-core provider:acme hint:login"
eq "T1: one alarm, no brake" "$(obn infra_blocked)|$(lj brake.consecutive)" "1|0"
stop_sup
ctl_world nohint
default "78||E:credential unavailable or unsafe"; m_send m-1 x
start_sup acme-core "${CTLENV[@]}" AIB_SUP_BLOCKED_AFTER_S=0.6
wait_for 5 ob_has infra_blocked 1
line="$(OB | grep 'alarm:infra_blocked' | head -1)"
has "T1: a plain 78 still carries the provider" "$line" "| alarm:infra_blocked agent:acme-core provider:acme"
hasnt "T1: …but no login hint (the attempt did not say so)" "$line" "hint:login"
stop_sup

# --- T2 (FLIPPED in v3.5 L5/N5) login-shaped FREE TEXT at rc 1 is NOT infra ---------------------------------------------------------------------------------
# v3.2 pinned: rc 1 + `Not logged in` / `Failed to authenticate. API Error: 401` => infra class (no brake, alarm with hint:login). Flipped by design v3.5 L5
# (Riker N5): the login hint comes ONLY from the adapter's structured marker (rc 78 + `hint:login`). Free-text "not logged in" in agent output (a test run, a
# doc the agent printed, a tool it ran) never turns a provider failure into the infra class: it counts toward the brake like any other rc 1.
# The adapter now emits the marker itself for every login-shaped refusal (adapter_login_spec, run_confined_home_spec T5), so nothing is lost.
for text in "Not logged in · Please run /login" "Failed to authenticate. API Error: 401 Invalid authentication credentials" "not logged in" "NOT LOGGED IN to the staging site" "ERROR: user is not logged in"; do
  ctl_world rc1
  default "1||E:$text"; for i in 1 2 3 4 5 6; do m_send m-$i x; done
  start_sup acme-core "${CTLENV[@]}" AIB_SUP_BLOCKED_AFTER_S=0.4
  wait_for 5 lj_is brake.consecutive 5
  sleep 0.6
  eq "T2: rc 1 + free text '${text:0:34}' => ordinary provider failure: the brake counts (5), no infra_blocked alarm, no hint" "$(lj brake.consecutive)|$(obn infra_blocked)|$(lj state_reason)" "5|0|brake"
  stop_sup
done
# rc 78 is the adapter's own class: infra, with or without the marker; the HINT, however, is only the marker (here: absent, free text ignored)
ctl_world rc78text
default "78||E:Not logged in · Please run /login"; m_send m-1 x
start_sup acme-core "${CTLENV[@]}" AIB_SUP_BLOCKED_AFTER_S=0.6
wait_for 5 ob_has infra_blocked 1
line="$(OB | grep 'alarm:infra_blocked' | head -1)"
has "T2: rc 78 stays infra even without the marker (the provider is named)" "$line" "| alarm:infra_blocked agent:acme-core provider:acme"
hasnt "T2: …but free-text 'Not logged in' does not add the login hint" "$line" "hint:login"
eq "T2: …no brake" "$(lj brake.consecutive)" 0
stop_sup
ctl_world plain1
default "1||E:boom"; for i in 1 2 3; do m_send m-$i x; done
start_sup acme-core "${CTLENV[@]}"
wait_for 5 lj_is brake.consecutive 5
eq "T2: guard — an ordinary rc 1 failure still counts toward the brake" "$(lj brake.consecutive)|$(obn infra_blocked)" "5|0"
stop_sup

# --- T2b (Riker M6) the hint only comes from the adapter, never from free agent output ---------------------------------------------------------------
# An agent (or a test run it executes) can print anything. `hint:login` is the ADAPTER's marker and only counts on the adapter's own exit (78);
# a bare `401` inside ordinary output never counts. Otherwise a failing test run skips the brake and is retried forever.
for text in "hint:login" "FAILED: expected 401 got 200" "ran 401 tests, 3 failed" "GET /x -> 401"; do
  ctl_world neg
  default "1||E:$text"; for i in 1 2 3; do m_send m-$i x; done
  start_sup acme-core "${CTLENV[@]}" AIB_SUP_BLOCKED_AFTER_S=0.4
  wait_for 5 lj_is brake.consecutive 5
  sleep 0.6
  eq "T2b: rc 1 + free output '${text:0:34}' => ordinary provider failure: the brake counts (5), no infra_blocked alarm" "$(lj brake.consecutive)|$(obn infra_blocked)" "5|0"
  stop_sup
done

# --- T3 the alarm is per EPISODE ---------------------------------------------------------------------------------------------------------------------------------
ctl_world episodes
default "78||E:hint:login"; m_send m-1 x
start_sup acme-core "${CTLENV[@]}" AIB_SUP_BLOCKED_AFTER_S=0.5
wait_for 5 ob_has infra_blocked 1
sleep 1
eq "T3: first outage: exactly one alarm for the whole episode" "$(obn infra_blocked)" 1
default "0||healed"; wait_for 1 state_is m-1 PROCESSED
sleep 0.3
default "78||E:hint:login"; m_send m-2 y
wait_for 7 ob_has infra_blocked 2
sleep 1
eq "T3: a LATER outage after the loop healed alarms again (2 alarms, 2 distinct ids)" "$(obn infra_blocked)|$(OB | grep alarm:infra_blocked | awk -F' [|] ' '{print $2}' | sort -u | wc -l | tr -d ' ')" "2|2"
eq "T3: …and a restart in the middle of the second episode does not repeat it" "$(crash_sup; start_sup acme-core "${CTLENV[@]}" AIB_SUP_BLOCKED_AFTER_S=0.5; sleep 2; obn infra_blocked)" 2
stop_sup

# --- T4 the supervisor never touches credentials ------------------------------------------------------------------------------------------------------------------
ctl_world nocred
default "78||E:hint:login"; m_send m-1 x
start_sup acme-core "${CTLENV[@]}" AIB_SUP_BLOCKED_AFTER_S=0.4
wait_for 5 ob_has infra_blocked 1
eq "T4: during an outage the only external calls are the launcher's (no mux, no login or refresh command in the fake PATH)" "$(wc -l < "$W/mux.log" | tr -d ' ')|$(ls "$W/fakebin" | sort | tr '\n' ' ')" "0|systemd-notify tmux zellij "
stop_sup

printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
