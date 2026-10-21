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
#   the registry (rc 2) and every functional assertion fails.#
#   S2a (agent view, design A1/A2/A4) — section "S2a" at the end of this file. One FLIP of an earlier expectation: `last_control` was
#   pinned `null` "until S1b"; it is now a list (`[]` when the journal holds no control records). `off_duty` stays false when live.json
#   has no (or a non-bool) `off_duty`; it is true iff live.json `off_duty` is the JSON boolean true.
#     last_control  newest 5 control outcomes from <root>/<uid>/journal.jsonl: one entry per `req` (events ctl.done > ctl.rejected >
#                   ctl.accepted by PRIORITY, not recency; `ctl.consumed` ignored), entry keys exactly {req,verb,outcome,reason,at},
#                   outcome done|rejected|accepted, reason = the ctl.rejected `reason` else "", at = ts of the chosen event;
#                   verbs outside agentctl's queued set (neustart feierabend standup abschalten reset-brake) are dropped BEFORE the
#                   limit; order = `at` descending, newest first; caller/args/text payload fields never appear anywhere in the output.
#     attention     kind "brake" (brake.tripped_at set), "login" (supervised agent with an account whose state is expiring|expired|absent;
#                   NOT for account null, ok or pending), "unit" (unit_state failed); each item names the agent in `agent`.
#
#   S2a round 2 (design v2, R1-R7) — section "S2a v2" at the end of this file, on its own registry/state root (agents r-*):
#     R1  timestamps: journal `ts`, live.json `brake.tripped_at` and the account times accept YYYY-MM-DDTHH:MM:SS[.f+]Z (the real writers
#         emit milliseconds) and are emitted as whole seconds YYYY-MM-DDTHH:MM:SSZ. A fraction with no digits ("05.Z") is not a timestamp.
#     R2  a torn / non-JSON / non-object / non-UTF-8 journal line is skipped; the other records still feed last_control, restarts_24h, journal_seq.
#     R3  only the LAST 262144 bytes of journal.jsonl are read; the first (partial) line of the window is dropped even when its tail is valid JSON.
#     R4  `brake` is rebuilt from the known keys only: consecutive int >= 0 (bool/str/negative => 0), tripped_at instant or null (garbage => null);
#         no other live.json brake key reaches the projection.
#     R6  `state_reason` and the control `reason` are machine words ^[a-z][a-z0-9_]{0,39}$ (matched as a FULL string: a trailing newline fails),
#         otherwise "other". DECISION (not in the design): the EMPTY string stays "" (no reason is not "other"); the existing T1 check needs it.
#     R7  last_control: equal `at` => higher req first; order is by `at` (not journal position); same req + same priority + same `at` => the LATER
#         journal line wins (DECISION: determinism pin); reason non-empty only for rejected; req must be an int >= 1 (0, -1, true, "5", 5.0, null dropped).
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
eq "T1: last_control is an empty list when the journal has no control records (S2a FLIP: was null until S1b)" "$(jg "$S.last_control")" "[]"
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

# =========================================================================
# S2a — off_duty (A1), last_control (A2), attention brake/login/unit (A4)
# =========================================================================
SUP2="$WORK/sup2"; LST2="$WORK/lstat2"; EVR2="$WORK/events2"; STD2="$WORK/standup2"
mkdir -p "$SUP2/s-ctl" "$SUP2/s-brk" "$SUP2/s-ok" "$SUP2/s-badoff" "$LST2" "$EVR2/attempts" "$STD2/inbox"
REG2="$WORK/registry2.json"
cat > "$REG2" <<JSON
{ "schema_version": 5,
  "providers": { "acme": { "adapter": "/bin/true", "cap_sandbox": "workspace-write", "cap_tier": "t2", "cap_effort": "high", "cap_timeout": "900" } },
  "projects": { "acme": { "home": "$HOMEDIR", "standup_dir": "$STD2", "mux_session": "acme", "provider": "acme", "model": "m", "effort": "low" } },
  "agents": {
    "s-ctl":    { "mode": "supervised", "project": "acme", "profile": "engine-dev", "clearance": "t2" },
    "s-brk":    { "mode": "supervised", "project": "acme", "profile": "engine-dev", "clearance": "t2" },
    "s-ok":     { "mode": "supervised", "project": "acme", "profile": "engine-dev", "clearance": "t2" },
    "s-badoff": { "mode": "supervised", "project": "acme", "profile": "engine-dev", "clearance": "t2" },
    "s-solo":   { "mode": "oneshot",    "project": "acme", "profile": "engine-dev", "clearance": "t2" }
  } }
JSON
for u in s-ctl s-ok s-badoff; do printf 'ActiveState=active\nSubState=running\nUnitFileState=enabled\n' > "$WORK/unit.$u"; done
printf 'ActiveState=failed\nSubState=failed\nUnitFileState=enabled\n' > "$WORK/unit.s-brk"
live2() { # live2 <uid> <extra-json-fields-with-leading-comma> <brake-json>
  printf '{"seq":5,"ts":"%s","interval_s":30,"pid":9,"state":"WORKING","state_reason":"","turn":null,"brake":%s,"session_id":null,"turns_in_session":0%s}\n' "$now" "$3" "$2" > "$SUP2/$1/live.json"; }
NOBRAKE='{"consecutive":0,"tripped_at":null}'
TRIP="$(iso '10 minutes ago')"
live2 s-ctl ',"off_duty":true' "$NOBRAKE"
live2 s-brk ',"off_duty":false' "{\"consecutive\":3,\"tripped_at\":\"$TRIP\"}"
live2 s-ok '' "$NOBRAKE"
live2 s-badoff ',"off_duty":"yes"' "$NOBRAKE"
T1="$(iso '100 minutes ago')"; T2="$(iso '95 minutes ago')"; T3="$(iso '90 minutes ago')"; T4="$(iso '80 minutes ago')"
T5="$(iso '70 minutes ago')"; T6="$(iso '60 minutes ago')"; T7="$(iso '50 minutes ago')"; T8="$(iso '40 minutes ago')"; T9="$(iso '30 minutes ago')"
cat > "$SUP2/s-ctl/journal.jsonl" <<JSON
{"seq":1,"ts":"$T1","event":"ctl.accepted","req":1,"verb":"neustart","target":"s-ctl","result":"accepted"}
{"seq":2,"ts":"$T1","event":"ctl.consumed","req":1}
{"seq":3,"ts":"$T2","event":"ctl.done","req":1,"verb":"neustart","target":"s-ctl","result":"ok"}
{"seq":4,"ts":"$T3","event":"ctl.rejected","req":2,"verb":"feierabend","target":"s-ctl","caller":"CALLER-LEAK","reason":"not_authorized","args":{"x":"ARGS-LEAK"}}
{"seq":5,"ts":"$T4","event":"ctl.accepted","req":3,"verb":"standup","target":"s-ctl","result":"accepted"}
{"seq":6,"ts":"$T5","event":"ctl.accepted","req":4,"verb":"abschalten","target":"s-ctl","result":"accepted"}
{"seq":7,"ts":"$T6","event":"ctl.rejected","req":4,"verb":"abschalten","target":"s-ctl","reason":"busy"}
{"seq":8,"ts":"$T6","event":"ctl.done","req":5,"verb":"reset-brake","target":"s-ctl","result":"ok"}
{"seq":9,"ts":"$T7","event":"ctl.rejected","req":5,"verb":"reset-brake","target":"s-ctl","reason":"late_reject"}
{"seq":10,"ts":"$T8","event":"ctl.done","req":6,"verb":"frobnicate","target":"s-ctl","result":"ok"}
{"seq":11,"ts":"$T9","event":"ctl.done","req":7,"verb":"neustart","target":"s-ctl","result":"ok","text":"SAYPAYLOAD-LEAK","caller":"CALLER-LEAK","args":{"y":"ARGS-LEAK"}}
JSON
proj2() { # proj2 [login-state-json-or-empty]
  RC=0; env -i PATH="$WORK/fakebin:$PATH" TZ=UTC AIB_TEST_SEAMS=1 AIB_DEPLOYMENT_OWNER_UID="$(id -u)" AIB_DEPLOYMENT_CONFIG="$WORK/none.json" AIB_LOGIN_STATUS_DIR="$LST2" \
    AIBOBNET_REGISTRY="$REG2" AIB_PROJECTION_ROOT="$WORK/proj2" AIB_EVENT_ROOT="$EVR2" AIB_SUP_STATE_ROOT="$SUP2" "$PROJECT_BIN" acme --stdout > "$OUT" 2>"$WORK/err2" || RC=$?; }
proj2
eq "S2a: bin/project runs on the S2a fixture" "$RC" 0
eq "A1: off_duty true from live.json" "$(jg agents.s-ctl.supervisor.off_duty)" true
eq "A1: off_duty false from live.json false" "$(jg agents.s-brk.supervisor.off_duty)" false
eq "A1: off_duty false when live.json has no off_duty" "$(jg agents.s-ok.supervisor.off_duty)" false
eq "A1: off_duty false when live.json off_duty is not a boolean" "$(jg agents.s-badoff.supervisor.off_duty)" false
lc() { python3 -I -c 'import json,sys;l=json.load(open(sys.argv[1]))["agents"]["s-ctl"]["supervisor"]["last_control"];print(sys.argv[2].join(str(e[sys.argv[3]]) for e in l))' "$OUT" "$1" "$2" 2>/dev/null; }
S="agents.s-ctl.supervisor.last_control"
eq "A2: at most 5 entries, newest first, one per req, unknown verb dropped before the limit (reqs)" "$(lc , req)" "7,5,4,3,2"
eq "A2: verbs" "$(lc , verb)" "neustart,reset-brake,abschalten,standup,feierabend"
eq "A2: outcome priority done > rejected > accepted (req 5 done beats a later reject; req 4 rejected beats accepted)" "$(lc , outcome)" "done,done,rejected,accepted,rejected"
eq "A2: reason only from ctl.rejected, else empty" "$(lc , reason)" ",,busy,,not_authorized"
eq "A2: at = ts of the chosen event" "$(lc , at)" "$T9,$T6,$T6,$T4,$T3"
eq "A2: entry keys are exactly req,verb,outcome,reason,at" "$(python3 -I -c 'import json,sys;l=json.load(open(sys.argv[1]))["agents"]["s-ctl"]["supervisor"]["last_control"];print(sorted({",".join(sorted(e)) for e in l}))' "$OUT" 2>/dev/null)" "['at,outcome,reason,req,verb']"
eq "A2: no caller / args / say payload text anywhere in the projection" "$(grep -c -e CALLER-LEAK -e ARGS-LEAK -e SAYPAYLOAD-LEAK -e late_reject "$OUT")" 0
eq "A2: a supervised agent without ctl records has last_control []" "$(jg agents.s-ok.supervisor.last_control)" "[]"
eq "A2: a oneshot agent keeps supervisor null" "$(jg agents.s-solo.supervisor)" null
kinds() { python3 -I -c 'import json,sys;print(",".join(sorted(i["kind"]+":"+str(i["agent"]) for i in json.load(open(sys.argv[1]))["attention"] if i["kind"] in ("brake","login","unit"))))' "$OUT" 2>/dev/null; }
eq "A4: brake (tripped_at set) and unit (failed) name the agent; account null => no login item; ok/idle agents none" "$(kinds)" "brake:s-brk,unit:s-brk"
for st in expiring expired absent; do
  printf '{"provider":"acme","state":"%s","expires_at":null,"label":"","id_hint":"ab12","checked_at":null}' "$st" > "$LST2/acme.json"; proj2
  eq "A4: account state $st => login item for each supervised agent (not the oneshot)" "$(kinds)" "brake:s-brk,login:s-badoff,login:s-brk,login:s-ctl,login:s-ok,unit:s-brk"
done
for st in ok pending; do
  printf '{"provider":"acme","state":"%s","expires_at":null,"label":"","id_hint":"ab12","checked_at":null}' "$st" > "$LST2/acme.json"; proj2
  eq "A4: account state $st => no login item" "$(kinds)" "brake:s-brk,unit:s-brk"
done
rm -f "$LST2/acme.json"; live2 s-brk ',"off_duty":false' "$NOBRAKE"; printf 'ActiveState=active\nSubState=running\nUnitFileState=enabled\n' > "$WORK/unit.s-brk"; proj2
eq "A4: no tripped brake and an active unit => none of the three kinds" "$(kinds)" ""
printf 'ActiveState=inactive\nSubState=dead\nUnitFileState=enabled\n' > "$WORK/unit.s-brk"; proj2
eq "A4: an inactive (not failed) unit is not a unit item" "$(kinds)" ""

# =========================================================================
# S2a v2 — R1 millisecond timestamps, R2 torn lines, R3 bounded read, R4 brake rebuild, R6 machine words, R7 ordering rules
# =========================================================================
SUP3="$WORK/sup3"; EVR3="$WORK/events3"; STD3="$WORK/standup3"
mkdir -p "$SUP3" "$EVR3/attempts" "$STD3/inbox"
for u in r-ms r-torn r-big r-tie r-rules r-var; do mkdir -p "$SUP3/$u"; done
REG3="$WORK/registry3.json"
cat > "$REG3" <<JSON
{ "schema_version": 5,
  "providers": { "acme": { "adapter": "/bin/true", "cap_sandbox": "workspace-write", "cap_tier": "t2", "cap_effort": "high", "cap_timeout": "900" } },
  "projects": { "acme": { "home": "$HOMEDIR", "standup_dir": "$STD3", "mux_session": "acme", "provider": "acme", "model": "m", "effort": "low" } },
  "agents": {
    "r-ms":    { "mode": "supervised", "project": "acme", "profile": "engine-dev", "clearance": "t2" },
    "r-torn":  { "mode": "supervised", "project": "acme", "profile": "engine-dev", "clearance": "t2" },
    "r-big":   { "mode": "supervised", "project": "acme", "profile": "engine-dev", "clearance": "t2" },
    "r-tie":   { "mode": "supervised", "project": "acme", "profile": "engine-dev", "clearance": "t2" },
    "r-rules": { "mode": "supervised", "project": "acme", "profile": "engine-dev", "clearance": "t2" },
    "r-var":   { "mode": "supervised", "project": "acme", "profile": "engine-dev", "clearance": "t2" }
  } }
JSON
proj3() { RC=0; env -i PATH="$WORK/fakebin:$PATH" TZ=UTC AIB_TEST_SEAMS=1 AIB_DEPLOYMENT_OWNER_UID="$(id -u)" AIB_DEPLOYMENT_CONFIG="$WORK/none.json" AIB_LOGIN_STATUS_DIR="$WORK/lstat3" \
    AIBOBNET_REGISTRY="$REG3" AIB_PROJECTION_ROOT="$WORK/proj3" AIB_EVENT_ROOT="$EVR3" AIB_SUP_STATE_ROOT="$SUP3" "$PROJECT_BIN" acme --stdout > "$OUT" 2>"$WORK/err3" || RC=$?; }
msiso() { date -u -d "$1" +%Y-%m-%dT%H:%M:%S."$2"Z; }   # msiso '10 minutes ago' 123
seciso() { date -u -d "$1" +%Y-%m-%dT%H:%M:%SZ; }
lv() { # lv <uid> <ts> <state_reason JSON literal> <brake JSON literal>
  printf '{"seq":5,"ts":"%s","interval_s":30,"pid":9,"state":"WORKING","state_reason":%s,"turn":null,"brake":%s,"session_id":null,"turns_in_session":0}\n' "$2" "$3" "$4" > "$SUP3/$1/live.json"; }
NB='{"consecutive":0,"tripped_at":null}'
for u in r-torn r-big r-tie r-rules r-var; do lv "$u" "$(msiso 'now' 456)" '""' "$NB"; done
lv r-ms "$(msiso 'now' 789)" '""' "$NB"
lc3() { python3 -I -c 'import json,sys;l=json.load(open(sys.argv[1]))["agents"][sys.argv[2]]["supervisor"]["last_control"];print(sys.argv[3].join(str(e[sys.argv[4]]) for e in l))' "$OUT" "$1" "$2" "$3" 2>/dev/null; }
# --- R1: the real writer's millisecond format, plus a second-precision control ---
Ta="$(seciso '10 minutes ago')"; Tb="$(seciso '20 minutes ago')"; Tc="$(seciso '30 minutes ago')"; Td="$(seciso '40 minutes ago')"
cat > "$SUP3/r-ms/journal.jsonl" <<JSON
{"seq":1,"ts":"$(msiso '48 hours ago' 100)","event":"supervisor.started","pid":1,"reexec":false}
{"seq":2,"ts":"$(msiso '2 hours ago' 200)","event":"supervisor.started","pid":2,"reexec":false}
{"seq":3,"ts":"$(seciso '1 hour ago')","event":"supervisor.started","pid":3,"reexec":false}
{"seq":4,"ts":"${Td%Z}.123Z","event":"ctl.done","req":1,"verb":"neustart","target":"r-ms","result":"ok"}
{"seq":5,"ts":"${Tc%Z}.5Z","event":"ctl.accepted","req":2,"verb":"standup","target":"r-ms","result":"accepted"}
{"seq":6,"ts":"${Tb%Z}.123456Z","event":"ctl.rejected","req":3,"verb":"abschalten","target":"r-ms","reason":"busy"}
{"seq":7,"ts":"$Ta","event":"ctl.done","req":4,"verb":"reset-brake","target":"r-ms","result":"ok"}
{"seq":8,"ts":"$(seciso '5 minutes ago' | sed 's/Z$/.Z/')","event":"ctl.done","req":5,"verb":"neustart","target":"r-ms","result":"ok"}
JSON
proj3
eq "R1: bin/project runs on the v2 fixtures" "$RC" 0
eq "R1: millisecond journal timestamps (1, 3 and 6 fraction digits) and a second-precision one: all four controls survive, newest first; '05.Z' dropped" "$(lc3 r-ms , req)" "4,3,2,1"
eq "R1: ...and every 'at' is emitted as whole seconds" "$(lc3 r-ms , at)" "$Ta,$Tb,$Tc,$Td"
eq "R1: restarts_24h counts millisecond and second precision records alike (2 in 24 h)" "$(jg agents.r-ms.supervisor.restarts_24h)" 2
eq "R1: a millisecond live.json ts keeps the agent healthy" "$(jg agents.r-ms.supervisor.health)" healthy
# --- R2: torn / garbage lines never empty the journal ---
python3 -I - "$SUP3/r-torn/journal.jsonl" "$(msiso '2 hours ago' 321)" "$(msiso '1 hour ago' 654)" "$(seciso '30 minutes ago')" <<'PYEOF'
import sys
path, t_a, t_b, t_c = sys.argv[1:]
lines = [
  b'{"seq":1,"ts":"%s","event":"supervisor.started","pid":1,"reexec":false}' % t_a.encode(),
  b'{"seq":2,"ts":"%s","event":"ctl.done","req":1,"verb":"neustart"' % t_c.encode(),
  b'this is not json at all',
  b'[1,2,3]',
  b'"just a string"',
  b'\xff\xfe broken \x80 utf8',
  b'{"seq":7,"ts":"%s","event":"ctl.done","req":2,"verb":"standup","target":"r-torn","result":"ok"}' % t_c.encode(),
  b'{"seq":8,"ts":"%s","event":"supervisor.started","pid":2,"reexec":false}' % t_b.encode(),
  b'',
]
tail = b'{"seq":99,"ts":"%s","event":"ctl.done","req":3,"ver' % t_c.encode()
open(path, 'wb').write(b'\n'.join(lines) + b'\n' + tail)
PYEOF
proj3
eq "R2: a journal with torn, non-JSON, non-object, non-UTF-8 lines and a torn tail still projects (rc 0)" "$RC" 0
eq "R2: ...the valid control still feeds last_control" "$(lc3 r-torn , req)" "2"
eq "R2: ...restarts_24h still counts the valid starts (2)" "$(jg agents.r-torn.supervisor.restarts_24h)" 2
eq "R2: ...journal_seq is the highest VALID seq (8; the torn tail's 99 is ignored)" "$(jg agents.r-torn.supervisor.journal_seq)" 8
# --- R3: bounded read of the last 262144 bytes, first partial line dropped even when its tail is valid JSON ---
python3 -I - "$SUP3/r-big/journal.jsonl" "$(msiso '90 minutes ago' 111)" "$(msiso '80 minutes ago' 222)" "$(msiso '70 minutes ago' 333)" "$(msiso '20 minutes ago' 444)" "$(msiso '10 minutes ago' 555)" "$(seciso '15 minutes ago')" <<'PYEOF'
import sys, json
path, t_head1, t_head2, t_strag, t_s1, t_s2, t_c = sys.argv[1:]
rec = lambda **k: (json.dumps(k, separators=(',', ':')) + '\n').encode()
head = rec(seq=999999, ts=t_head1, event='supervisor.started', pid=1, reexec=False) + \
       rec(seq=5, ts=t_head2, event='ctl.done', req=50, verb='neustart', target='r-big', result='ok')
inner = json.dumps(dict(seq=777, ts=t_strag, event='supervisor.started', pid=3, reexec=False), separators=(',', ':'))
straggler = b'x' * 3000 + inner.encode() + b'\n'
tail_fixed = rec(seq=1001, ts=t_s1, event='supervisor.started', pid=4, reexec=False) + \
             rec(seq=1002, ts=t_c, event='ctl.done', req=60, verb='standup', target='r-big', result='ok') + \
             rec(seq=1003, ts=t_s2, event='supervisor.started', pid=5, reexec=False)
# the 262144-byte window must start exactly at the '{' of a valid JSON object that is the tail of a longer, invalid line (x-run prefix)
fill_len = 262144 - (len(inner) + 1) - len(tail_fixed)
base = len(rec(seq=1000, ts=t_head2, event='filler', pad=''))
filler = rec(seq=1000, ts=t_head2, event='filler', pad='y' * (fill_len - base))
assert len(filler) == fill_len
open(path, 'wb').write(head + straggler + filler + tail_fixed)
PYEOF
sz="$(wc -c < "$SUP3/r-big/journal.jsonl")"
if [ "$sz" -gt 262144 ]; then ok "R3: fixture journal is larger than the 262144-byte window ($sz bytes)"; else no "R3: fixture journal is larger than the window (got $sz)"; fi
proj3
eq "R3: bin/project runs on the large journal" "$RC" 0
eq "R3: restarts_24h counts only the window (2): not the head record, not the partial first line's valid-looking tail" "$(jg agents.r-big.supervisor.restarts_24h)" 2
eq "R3: last_control sees only the window (req 60), not req 50 from the head" "$(lc3 r-big , req)" "60"
eq "R3: journal_seq is the highest seq inside the window (not 999999 from the head)" "$(jg agents.r-big.supervisor.journal_seq)" 1003
# --- R7: ordering and rules ---
Tt="$(seciso '5 minutes ago')"; Tn="$(seciso '20 minutes ago')"; To="$(seciso '40 minutes ago')"; Tz="$(seciso '60 minutes ago')"
cat > "$SUP3/r-tie/journal.jsonl" <<JSON
{"seq":1,"ts":"$Tn","event":"ctl.done","req":30,"verb":"neustart","target":"r-tie","result":"ok"}
{"seq":2,"ts":"$To","event":"ctl.done","req":31,"verb":"standup","target":"r-tie","result":"ok"}
{"seq":3,"ts":"$Tt","event":"ctl.done","req":10,"verb":"neustart","target":"r-tie","result":"ok"}
{"seq":4,"ts":"$Tt","event":"ctl.done","req":11,"verb":"standup","target":"r-tie","result":"ok"}
{"seq":5,"ts":"$Tz","event":"ctl.rejected","req":20,"verb":"abschalten","target":"r-tie","reason":"first_one"}
{"seq":6,"ts":"$Tz","event":"ctl.rejected","req":20,"verb":"abschalten","target":"r-tie","reason":"second_one"}
JSON
cat > "$SUP3/r-rules/journal.jsonl" <<JSON
{"seq":1,"ts":"$(seciso '1 minute ago')","event":"ctl.done","req":0,"verb":"neustart","target":"r-rules","result":"ok"}
{"seq":2,"ts":"$(seciso '1 minute ago')","event":"ctl.done","req":-1,"verb":"neustart","target":"r-rules","result":"ok"}
{"seq":3,"ts":"$(seciso '1 minute ago')","event":"ctl.done","req":true,"verb":"neustart","target":"r-rules","result":"ok"}
{"seq":4,"ts":"$(seciso '1 minute ago')","event":"ctl.done","req":"5","verb":"neustart","target":"r-rules","result":"ok"}
{"seq":5,"ts":"$(seciso '1 minute ago')","event":"ctl.done","req":5.0,"verb":"neustart","target":"r-rules","result":"ok"}
{"seq":6,"ts":"$(seciso '1 minute ago')","event":"ctl.done","req":null,"verb":"neustart","target":"r-rules","result":"ok"}
{"seq":7,"ts":"$(seciso '3 minutes ago')","event":"ctl.done","req":7,"verb":"neustart","target":"r-rules","result":"ok","reason":"leak_done"}
{"seq":8,"ts":"$(seciso '4 minutes ago')","event":"ctl.accepted","req":8,"verb":"standup","target":"r-rules","result":"accepted","reason":"leak_acc"}
JSON
proj3
eq "R7: order is by 'at' descending (not journal position, not req); equal 'at' => higher req first; duplicates of one req collapse" "$(lc3 r-tie , req)" "11,10,30,31,20"
eq "R7: same req, same priority, same 'at' => the LATER journal line wins (reason second_one)" "$(python3 -I -c 'import json,sys;l=json.load(open(sys.argv[1]))["agents"]["r-tie"]["supervisor"]["last_control"];print([e["reason"] for e in l if e["req"]==20][0])' "$OUT" 2>/dev/null)" "second_one"
eq "R7: req must be an int >= 1: 0, -1, true, \"5\", 5.0 and null are dropped (only 7 and 8 remain)" "$(lc3 r-rules , req)" "7,8"
eq "R7: reason is non-empty only for rejected: a done and an accepted record carrying a reason give \"\"" "$(lc3 r-rules , reason)" ","
# --- R4 / R6 on live.json (agent r-var) ---
bk() { python3 -I -c 'import json,sys;print(json.dumps(json.load(open(sys.argv[1]))["agents"]["r-var"]["supervisor"]["brake"],sort_keys=True))' "$OUT" 2>/dev/null; }
sr() { python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["agents"]["r-var"]["supervisor"]["state_reason"])' "$OUT" 2>/dev/null; }
mw40="b$(printf 'a%.0s' $(seq 1 39))"; mw41="b$(printf 'a%.0s' $(seq 1 40))"; long300="$(printf 'a%.0s' $(seq 1 300))"
rv() { # rv <state_reason JSON literal> <expected>
  lv r-var "$(msiso 'now' 1)" "$1" "$NB"; proj3; eq "R6: state_reason ${1:0:40} ($((${#1}-2)) chars) => '${2:0:40}'" "$RC|$(sr)" "0|$2"; }
rv '"quota_backoff"' quota_backoff
rv "\"$mw40\"" "$mw40"
rv "\"$mw41\"" other
rv "\"$long300\"" other
rv '"Quota_backoff"' other
rv '"quota backoff"' other
rv '"quota-backoff"' other
rv '"1st_try"' other
rv '"_lead"' other
rv '"abc\n"' other
rv '"<script>x</script>"' other
rv '"größe"' other
rv '""' ""
while IFS='|' read -r brake want; do
  lv r-var "$(msiso 'now' 1)" '"ok_word"' "$brake"; proj3
  eq "R4: brake $brake => $want (other fields untouched)" "$RC|$(bk)|$(jg agents.r-var.supervisor.session_state)|$(sr)" "0|$want|WORKING|ok_word"
done <<'LIST'
{"consecutive":2,"tripped_at":null,"extra":"EVIL-BRAKE-KEY","nested":{"EVIL":1}}|{"consecutive": 2, "tripped_at": null}
{"consecutive":"3","tripped_at":"garbage"}|{"consecutive": 0, "tripped_at": null}
{"consecutive":-1,"tripped_at":12345}|{"consecutive": 0, "tripped_at": null}
{"consecutive":true,"tripped_at":null}|{"consecutive": 0, "tripped_at": null}
{"consecutive":4,"tripped_at":"2026-10-21T08:15:42.789Z"}|{"consecutive": 4, "tripped_at": "2026-10-21T08:15:42Z"}
{"consecutive":1,"tripped_at":"2026-10-21T08:15:42Z"}|{"consecutive": 1, "tripped_at": "2026-10-21T08:15:42Z"}
"not-a-dict"|{"consecutive": 0, "tripped_at": null}
LIST
lv r-var "$(msiso 'now' 1)" '"ok_word"' '{"consecutive":1,"tripped_at":"2026-10-21T08:15:42.789Z","extra":"EVIL-BRAKE-KEY"}'; proj3
eq "R4: no unknown live.json brake key reaches the projection" "$(grep -c EVIL-BRAKE-KEY "$OUT")" 0
eq "R1: the brake attention item carries the whole-second tripped_at" "$(python3 -I -c 'import json,sys;print([i["since"] for i in json.load(open(sys.argv[1]))["attention"] if i["kind"]=="brake" and i["agent"]=="r-var"])' "$OUT" 2>/dev/null)" "['2026-10-21T08:15:42Z']"
lv r-var "$(msiso 'now' 1)" '"ok_word"' "$NB"
# --- R6 on the control reason ---
rr() { # rr <reason JSON literal, or NONE> <expected>
  if [ "$1" = NONE ]; then printf '{"seq":1,"ts":"%s","event":"ctl.rejected","req":1,"verb":"neustart","target":"r-var"}\n' "$(seciso '1 minute ago')" > "$SUP3/r-var/journal.jsonl"
  else printf '{"seq":1,"ts":"%s","event":"ctl.rejected","req":1,"verb":"neustart","target":"r-var","reason":%s}\n' "$(seciso '1 minute ago')" "$1" > "$SUP3/r-var/journal.jsonl"; fi
  proj3; eq "R6: control reason ${1:0:40} ($((${#1}-2)) chars) => '${2:0:40}'" "$RC|$(lc3 r-var , reason)" "0|$2"; }
rr '"not_authorized"' not_authorized
rr "\"$mw40\"" "$mw40"
rr "\"$mw41\"" other
rr "\"$long300\"" other
rr '"Not_authorized"' other
rr '"not authorized"' other
rr '"not-authorized"' other
rr '"busy\n"' other
rr '"<b>x</b>"' other
rr '"größe"' other
rr '""' ""
rr NONE ""

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
