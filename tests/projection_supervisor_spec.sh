#!/usr/bin/env bash
# ai-bobnet — RED spec for the supervisor block of the visibility projection
# (Supervisor slice S1a-2; design B16, B8 "health stays derived", DOMAIN §3.1/§3.6).
#
# WHAT THIS PINS
#   bin/project gains, for every registered agent, `agents[uid].supervisor`:
#     null                       for an agent whose registry `mode` is absent or `oneshot`;
#     an object                  for `mode: supervised` (design says an `agents[]` block; the existing
#                                `agents` object is keyed by uid and its key set is a contract
#                                invariant, so the block is a sub-object of that entry — RESOLVED HERE).
#   Sources (read-only, never a second write path; state root = unit-env AIB_SUP_STATE_ROOT, default
#   /var/lib/aib-sup): <root>/<uid>/live.json, <root>/<uid>/journal.jsonl, the agent's inbox journal,
#   and `systemctl show … aib-agent@<uid>.service` (ActiveState, UnitFileState — faked on PATH).
#   Fields (all present, none invented, each traceable to a record):
#     mode                   "supervised"
#     account                null  (the role account arrives with S1c; the key is present now)
#     unit_state             systemd ActiveState ("active" | "inactive" | "failed" …)
#     disabled               true iff UnitFileState == "disabled"
#     session_state          live.json state (DOMAIN §3.1); "OFFLINE" when no live.json exists
#     state_reason           live.json state_reason ("" when none)
#     health                 DERIVED, never stored: tick age > 3 x live.json interval_s => "unhealthy"
#                            regardless of what the last heartbeat text says; a fresh tick on a
#                            WORKING loop => "healthy"; no live.json => "unhealthy"
#     tick_seq, tick_age_s   live.json seq / seconds since live.json ts (null without live.json)
#     current_turn           live.json turn {msg_id, started_at, attempt_id} or null
#     session_id_short       first 8 characters of live.json session_id (null when none)
#     turns_in_session       live.json turns_in_session
#     restarts_24h           journal `supervisor.started` records with reexec=false in the last 24 h
#     brake                  live.json brake {consecutive, tripped_at}
#     off_duty               false (the verb that sets it is S1b; the key is present now)
#     inbox_open             open (not PROCESSED/FAILED) messages in the agent's inbox journal
#     last_control           null (S1b)
#     journal_seq            highest seq in journal.jsonl (traceability)
#   The pre-existing fields of agents[uid] (state, since, message, …) stay exactly as they were.
#
#   Expected on the unbuilt tree: bin/project knows neither schema 5 nor `supervisor`, so it refuses
#   the registry (rc 2) and every functional assertion fails.
set -uo pipefail
SRC_ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
PROJECT_BIN="$SRC_ROOT/bin/project"
JGET="$SRC_ROOT/tests/fixtures/projection_jget.py"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-projsup.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
no(){ fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; }
eq(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2' want '$3')"; fi; }
jg() { python3 -I "$JGET" "$OUT" "$1"; }
iso() { date -u -d "$1" +%Y-%m-%dT%H:%M:%SZ; }

HOMEDIR="$WORK/home"; STANDUP="$WORK/standup"; SUPROOT="$WORK/sup"; EVR="$WORK/events"
mkdir -p "$HOMEDIR" "$STANDUP/inbox" "$SUPROOT" "$EVR/attempts" "$WORK/fakebin"
REG="$WORK/registry.json"
cat > "$REG" <<JSON
{ "schema_version": 5,
  "providers": { "acme": { "adapter": "/bin/true", "cap_sandbox": "workspace-write", "cap_tier": "t2", "cap_effort": "high", "cap_timeout": "900" } },
  "projects": { "acme": { "home": "$HOMEDIR", "standup_dir": "$STANDUP", "mux_session": "acme", "provider": "acme", "model": "m", "effort": "low" } },
  "agents": {
    "acme-core":  { "mode": "supervised", "project": "acme", "profile": "engine-dev", "clearance": "t2" },
    "acme-stale": { "mode": "supervised", "project": "acme", "profile": "engine-dev", "clearance": "t2" },
    "acme-down":  { "mode": "supervised", "project": "acme", "profile": "engine-dev", "clearance": "t2" },
    "acme-solo":  { "mode": "oneshot",    "project": "acme", "profile": "engine-dev", "clearance": "t2" },
    "acme-plain": { "project": "acme", "profile": "engine-dev", "clearance": "t2" }
  } }
JSON
# fake systemctl: answers `show` for aib-agent@<uid>.service from $WORK/unit.<uid> (ActiveState/UnitFileState)
cat > "$WORK/fakebin/systemctl" <<FAKE
#!/usr/bin/env bash
for a in "\$@"; do case "\$a" in aib-agent@*.service) u="\${a#aib-agent@}"; u="\${u%.service}"; cat "$WORK/unit.\$u" 2>/dev/null; exit 0;; esac; done
exit 0
FAKE
chmod +x "$WORK/fakebin/systemctl"
printf 'ActiveState=active\nSubState=running\nUnitFileState=enabled\n' > "$WORK/unit.acme-core"
printf 'ActiveState=active\nSubState=running\nUnitFileState=enabled\n' > "$WORK/unit.acme-stale"
printf 'ActiveState=inactive\nSubState=dead\nUnitFileState=disabled\n' > "$WORK/unit.acme-down"

SID="3f2b8c1e-9d4a-4e6b-8a7c-1b2d3e4f5a6b"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$SUPROOT/acme-core" "$SUPROOT/acme-stale"
cat > "$SUPROOT/acme-core/live.json" <<JSON
{"seq":1234,"ts":"$now","interval_s":30,"pid":4242,"state":"WORKING","state_reason":"",
 "turn":{"msg_id":"m-77","started_at":"$now","attempt_id":"att-9"},
 "brake":{"consecutive":2,"tripped_at":null},"session_id":"$SID","turns_in_session":7}
JSON
cat > "$SUPROOT/acme-core/journal.jsonl" <<JSON
{"seq":1,"ts":"$(iso '48 hours ago')","event":"supervisor.started","pid":1,"reexec":false}
{"seq":2,"ts":"$(iso '2 hours ago')","event":"supervisor.started","pid":2,"reexec":false}
{"seq":3,"ts":"$(iso '1 hour ago')","event":"supervisor.started","pid":3,"reexec":false}
{"seq":4,"ts":"$(iso '30 minutes ago')","event":"supervisor.started","pid":3,"reexec":true}
JSON
printf '%s | id:i-1 | from:acme-sib | to:acme-core | state:PERSISTED | one\n%s | id:i-2 | from:acme-sib | to:acme-core | state:PERSISTED | two\n%s | id:i-3 | from:acme-sib | to:acme-core | state:PERSISTED | three\n%s | id:i-3 | event:PROCESSED | by:acme-core\n' "$now" "$now" "$now" "$now" > "$STANDUP/inbox/acme-core.md"
# the stale one: last tick an hour ago, interval 30 s; the heartbeat claims it is busy RIGHT NOW
cat > "$SUPROOT/acme-stale/live.json" <<JSON
{"seq":99,"ts":"$(iso '1 hour ago')","interval_s":30,"pid":7,"state":"WORKING","state_reason":"",
 "turn":null,"brake":{"consecutive":0,"tripped_at":null},"session_id":null,"turns_in_session":0}
JSON
printf '{"seq":1,"ts":"%s","event":"supervisor.started","pid":7,"reexec":false}\n' "$(iso '1 hour ago')" > "$SUPROOT/acme-stale/journal.jsonl"
printf '%s | acme-stale | busy | still on it\n' "$now" > "$STANDUP/acme-stale.log"

OUT="$WORK/out.json"; RC=0
env -i PATH="$WORK/fakebin:$PATH" TZ=UTC AIBOBNET_REGISTRY="$REG" AIB_PROJECTION_ROOT="$WORK/proj" AIB_EVENT_ROOT="$EVR" \
  AIB_SUP_STATE_ROOT="$SUPROOT" "$PROJECT_BIN" acme --stdout > "$OUT" 2>"$WORK/err" || RC=$?
eq "bin/project accepts a schema-5 registry and exits 0" "$RC" 0

S="agents.acme-core.supervisor"
eq "T1: a supervised agent has a supervisor block" "$(jg "$S.mode")" supervised
eq "T1: account key present, null until S1c" "$(jg "$S.account")" null
eq "T1: unit_state from systemd ActiveState" "$(jg "$S.unit_state")" active
eq "T1: disabled false for an enabled unit" "$(jg "$S.disabled")" false
eq "T1: session_state from live.json" "$(jg "$S.session_state")" WORKING
eq "T1: state_reason present (empty)" "$(jg "$S.state_reason")" ""
eq "T1: tick_seq traces to live.json seq" "$(jg "$S.tick_seq")" 1234
ta="$(jg "$S.tick_age_s")"
if [ "$ta" -ge 0 ] 2>/dev/null && [ "$ta" -le 20 ]; then ok "T1: tick_age_s is the age of the tick ($ta s)"; else no "T1: tick_age_s is the age of the tick (got '$ta')"; fi
eq "T1: health healthy on a fresh tick" "$(jg "$S.health")" healthy
eq "T1: current_turn.msg_id" "$(jg "$S.current_turn.msg_id")" m-77
eq "T1: current_turn.attempt_id" "$(jg "$S.current_turn.attempt_id")" att-9
eq "T1: current_turn.started_at present" "$(jg "$S.current_turn.started_at" | cut -c1-2)" 20
eq "T1: session_id_short = first 8 chars" "$(jg "$S.session_id_short")" "3f2b8c1e"
eq "T1: turns_in_session" "$(jg "$S.turns_in_session")" 7
eq "T1: restarts_24h counts real starts in 24 h, not re-execs, not older" "$(jg "$S.restarts_24h")" 2
eq "T1: brake.consecutive" "$(jg "$S.brake.consecutive")" 2
eq "T1: brake.tripped_at" "$(jg "$S.brake.tripped_at")" null
eq "T1: off_duty key present, false until S1b" "$(jg "$S.off_duty")" false
eq "T1: inbox_open counts non-terminal messages (3 sent, 1 processed)" "$(jg "$S.inbox_open")" 2
eq "T1: last_control key present, null until S1b" "$(jg "$S.last_control")" null
eq "T1: journal_seq traces to the journal's last record" "$(jg "$S.journal_seq")" 4

S="agents.acme-stale.supervisor"
eq "T2: a stale tick is unhealthy (3600 s > 3 x 30 s)" "$(jg "$S.health")" unhealthy
eq "T2: …even though the heartbeat says busy (existing field untouched)" "$(jg agents.acme-stale.state)" busy
ta="$(jg "$S.tick_age_s")"
if [ "$ta" -ge 3500 ] 2>/dev/null; then ok "T2: tick_age_s shows the real age ($ta s)"; else no "T2: tick_age_s shows the real age (got '$ta')"; fi
eq "T2: current_turn null when idle" "$(jg "$S.current_turn")" null
eq "T2: session_id_short null without a session" "$(jg "$S.session_id_short")" null

S="agents.acme-down.supervisor"
eq "T3: no live.json -> session_state OFFLINE" "$(jg "$S.session_state")" OFFLINE
eq "T3: …unhealthy" "$(jg "$S.health")" unhealthy
eq "T3: …tick_seq null" "$(jg "$S.tick_seq")" null
eq "T3: …tick_age_s null" "$(jg "$S.tick_age_s")" null
eq "T3: …unit_state from systemd" "$(jg "$S.unit_state")" inactive
eq "T3: …disabled true for a disabled unit" "$(jg "$S.disabled")" true
eq "T3: …journal_seq 0 without a journal" "$(jg "$S.journal_seq")" 0

eq "T4: a oneshot agent has supervisor null" "$(jg agents.acme-solo.supervisor)" null
eq "T4: an agent without a mode has supervisor null" "$(jg agents.acme-plain.supervisor)" null
eq "T4: the agents key set is still exactly the registered agents" "$(python3 -I -c 'import json,sys;print(",".join(sorted(json.load(open(sys.argv[1]))["agents"])))' "$OUT" 2>/dev/null)" "acme-core,acme-down,acme-plain,acme-solo,acme-stale"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
