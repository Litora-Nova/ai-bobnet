#!/usr/bin/env bash
# ai-bobnet — RED spec for the per-team outbox seam: the supervisor's human-bound alarms (Supervisor slice S1b; design B15, F6).
# E7 (an external comms hub) is pending and NOT depended on: today a human or the Inbox-first poller reads the file, tomorrow any
# hub can drain it. No transport is built here; the FORMAT is the contract.
#
# WHAT THIS PINS
#   - File: $AIB_OUTBOX_ROOT/<team_uid>/outbox.md (default root /srv/aib/outbox); the team dir is created on demand.
#   - Line = the bin/message journal format, one line per alarm:
#         <ISO UTC> | id:<unique id> | from:<agent uid> | to:human:<team_uid> | state:PERSISTED | alarm:<kind> agent:<uid> <k:v ...>
#     (the same `ts | id: | from: | to: | state:PERSISTED | body` shape as an inbox line, so a drain can reuse the inbox reader).
#   - Kinds written by the supervisor: brake_tripped (5th consecutive provider failure; carries consecutive:5),
#     infra_blocked (infra class lasting AIB_SUP_BLOCKED_AFTER_S — NO brake, F6), deployment_denied (deployment_config_spec).
#     `unit failed` (systemd gave up) cannot be written by the dead supervisor: it needs an OnFailure= unit, a provisioning hand-off.
#   - Exactly ONE line per episode: not per tick, not per poll, and a restart of the supervisor while the same episode is
#     still active does not repeat it. A healthy run writes nothing (the file does not even have to exist).
#   - An unwritable outbox must not stop the supervisor (alarms are best effort; the heartbeat `blocked` still happens).
#
#   Expected on the unbuilt tree: the supervisor never writes an outbox.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/fixtures/ctl_harness.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-outbox.XXXXXX")"
trap sup_cleanup EXIT
OB() { cat "$OUTBOX/acme-engine/outbox.md" 2>/dev/null; }
obn() { OB | grep -c "alarm:$1"; }
ob_has() { [ "$(obn "$1")" -ge "$2" ]; }
provision_intents() {
  mkdir -p "$W/state/acme-core/.aib/intents"
  chmod 700 "$W/state/acme-core" "$W/state/acme-core/.aib" "$W/state/acme-core/.aib/intents"
}

# --- T1 healthy run: silent -------------------------------------------------------------------------------
ctl_world quiet
provision_intents
plan "0||fine"; m_send m-1 x; start_sup acme-core "${CTLENV[@]}"
wait_for 10 state_is m-1 PROCESSED
sleep 0.5
eq "T1: a healthy run writes no alarm" "$(m_state m-1)|$(OB | wc -l | tr -d ' ')" "PROCESSED|0"
stop_sup

# --- T2 brake_tripped: one line, right format, not repeated by a restart ------------------------------------------
ctl_world brake
provision_intents
default "1||E:boom"; m_send m-1 a; m_send m-2 b; m_send m-3 c; start_sup acme-core "${CTLENV[@]}"
wait_for 15 lj_is brake.consecutive 5
wait_for 10 ob_has brake_tripped 1
line="$(OB | grep 'alarm:brake_tripped' | head -1)"
case "$line" in 20??-??-??T??:??:??*Z\ \|\ id:*) ok "T2: line starts with an ISO UTC timestamp and an id";; *) no "T2: line starts with an ISO UTC timestamp and an id (got '$line')";; esac
has "T2: from the agent" "$line" "| from:acme-core |"
has "T2: to the team's human" "$line" "| to:human:acme-engine |"
has "T2: PERSISTED" "$line" "| state:PERSISTED | "
has "T2: body names kind, agent and the count" "$line" "| alarm:brake_tripped agent:acme-core consecutive:5"
sleep 1
eq "T2: exactly one alarm while the brake stays tripped (ticks do not repeat it)" "$(obn brake_tripped)" 1
crash_sup; start_sup acme-core "${CTLENV[@]}"; wait_for 10 lj_is pid "$SUP_PID"; sleep 1
eq "T2: …nor does a restart that finds the brake still tripped" "$(obn brake_tripped)|$(lj state_reason)" "1|brake"
ids="$(OB | awk -F' [|] ' '{print $2}' | sort | uniq -d | wc -l | tr -d ' ')"
eq "T2: ids are unique" "$ids|$([ "$(OB | wc -l | tr -d ' ')" -ge 1 ] && echo have)" "0|have"
stop_sup

# --- T3 infra_blocked: no brake, one alarm, heals ----------------------------------------------------------------------
ctl_world infra
provision_intents
default "78||E:credential missing"; m_send m-1 x
start_sup acme-core "${CTLENV[@]}" AIB_SUP_BLOCKED_AFTER_S=0.6
wait_for 15 ob_has infra_blocked 1
has "T3: infra_blocked carries the agent" "$(OB | grep 'alarm:infra_blocked')" "alarm:infra_blocked agent:acme-core"
sleep 1.2
eq "T3: one alarm for the whole episode" "$(obn infra_blocked)" 1
eq "T3: …and NO brake alarm, brake counter 0" "$(obn infra_blocked)|$(obn brake_tripped)|$(lj brake.consecutive)" "1|0|0"
default "0||healed"
wait_for 15 state_is m-1 PROCESSED
eq "T3: the loop self-heals when the provider comes back" "$(m_state m-1)" PROCESSED
stop_sup

# --- T4 an unusable outbox does not stop the supervisor ------------------------------------------------------------------------
ctl_world broken
provision_intents
printf 'a file where the team directory should be' > "$OUTBOX/acme-engine"
default "1||E:boom"; m_send m-1 a; m_send m-2 b; m_send m-3 c; start_sup acme-core "${CTLENV[@]}"
wait_for 15 lj_is brake.consecutive 5
sleep 0.5
eq "T4: the brake still trips and the loop keeps ticking with an unusable outbox" "$(lj state)|$(lj state_reason)|$(kill -0 "$SUP_PID" 2>/dev/null && echo alive)" "FAILED|brake|alive"
eq "T4: …and the heartbeat blocked is still written" "$(hb_status | awk '{print $NF}')" blocked
stop_sup

# --- T5 the alarm is per EPISODE: reset-brake, then a second trip alarms again ---------------------------------------------------
ctl_world episode; as human:operator
provision_intents
default "1||E:boom"; for i in 1 2 3 4 5 6; do m_send m-$i x; done; start_sup acme-core "${CTLENV[@]}"
wait_for 15 ob_has brake_tripped 1
eq "T5: first trip, one alarm" "$(obn brake_tripped)" 1
s="$(audit reset-brake acme-core human:operator)"; drop acme-core "$s" reset-brake
wait_for 15 done_for "$s"
wait_for 20 ob_has brake_tripped 2
eq "T5: after reset-brake a SECOND trip alarms again (2 lines, 2 distinct ids)" "$(obn brake_tripped)|$(OB | awk -F' [|] ' '{print $2}' | sort -u | wc -l | tr -d ' ')" "2|2"
sleep 1
eq "T5: …and still only one per episode" "$(obn brake_tripped)" 2
stop_sup

# --- T6 a failed outbox write leaves a trace ------------------------------------------------------------------------------------
ctl_world trace
provision_intents
printf 'a file where the team directory should be' > "$OUTBOX/acme-engine"
default "1||E:boom"; m_send m-1 a; m_send m-2 b; m_send m-3 c; start_sup acme-core "${CTLENV[@]}"
wait_for 15 lj_is brake.consecutive 5
af_ge1() { [ "$(jcount alarm.failed)" -ge 1 ]; }
wait_for 10 af_ge1
eq "T6: the failed alarm write is journalled (alarm.failed, kind brake_tripped), not swallowed" "$(jcount alarm.failed)|$(jfield alarm.failed 1 kind)" "1|brake_tripped"
eq "T6: …and it is not recorded as sent" "$(jcount alarm.sent)" 0
stop_sup

# --- T7 the unit template lets the supervisor write the outbox -------------------------------------------------------------------
UNIT="$SRC_ROOT/deploy/systemd/aib-agent@.service"
rw="$(grep '^ReadWritePaths=' "$UNIT" 2>/dev/null)"
has "T7: ReadWritePaths= includes the team outbox root" "$rw" "/srv/aib/outbox"
has "T7: …and still the old paths (broker state, /run/aib, standup)" "$rw" "/run/aib"

printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
