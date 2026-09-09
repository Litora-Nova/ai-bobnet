#!/usr/bin/env bash
# ai-bobnet — RED spec for schema 2 (the `launch` object) and `bin/dashboard`.
#
# WHAT THIS PINS
#   docs/CONTRACT-visibility.md §18/§19 (schema 2, rendering obligations) and
#   docs/decisions/0008-dashboard.md are the normative text. This file pins their decisions against
#   the concrete interfaces they name:
#
#     bin/dashboard
#       Env: AIB_DASHBOARD_BIND (no default — refuses 0.0.0.0 unless this names it explicitly)
#            AIB_DASHBOARD_PORT   default 3030; 0 means "pick an ephemeral port and print it"
#            AIB_PROJECTION_ROOT  same root bin/project publishes to
#            AIB_PROJECTION_STALE_SECONDS  default 60, dashboard-only (never read by bin/project)
#       Routes: GET /  GET /p/<uid>  GET /api/fleet  GET /api/project/<uid>
#       On startup (only when AIB_DASHBOARD_PORT=0), prints `port=<N>` to stdout before serving.
#
#   Fixtures below cover: a schema-2 fold through `bin/project` over a fixture registry/event stream
#   (allow with a clamped field, deny with blanked `effective`, a genuinely unresolved field, an RM-2
#   legacy `{decision, pid}`-only record, an agent with no decided record at all under both an `ok`
#   and a `corrupt` stream); the fold's raw-JSON passthrough and malformed-tolerant `launch:null` path
#   called directly against `lib/attempts_fold.py`; and a hand-built projection root (bypassing
#   `bin/project`, which does not yet emit `launch`) driving `bin/dashboard`'s HTTP surface directly —
#   enumeration, escaping, CSP, 404s, the bind refusal, and one assertion per §19 rendering obligation.
#
#   On THIS unbuilt tree, `bin/dashboard` does not exist, `lib/attempts_fold.py` does not carry
#   `launch`, and `bin/project`'s Python pass does not emit it either — so the great majority of
#   assertions below FAIL. That is the expected, correct state of a RED spec pinning behaviour that
#   does not exist yet (mirrors `tests/projection_spec.sh`'s own header at V-1). A handful of
#   invariant-style checks (the deploy-unit text, the non-consumption ALLOWLIST in
#   `tests/projection_spec.sh`, and the untouched `bin/attempts`/`frame_parity_spec` baselines) are
#   expected to PASS already and must keep passing once `bin/dashboard` and schema 2 exist.
set -uo pipefail

SRC_ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
REPO_ROOT="$SRC_ROOT"
PROJECT_BIN="$SRC_ROOT/bin/project"
DASHBOARD_BIN="$SRC_ROOT/bin/dashboard"
UNIT_FILE="$SRC_ROOT/deploy/systemd/aib-dashboard.service"
FOLD_PY="$SRC_ROOT/lib/attempts_fold.py"
FIXDIR="$SRC_ROOT/tests/fixtures"
JGET="$FIXDIR/projection_jget.py"
# shellcheck source=lib/aibobnet.sh
. "$REPO_ROOT/lib/aibobnet.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-dashboard.XXXXXX")"
cleanup() { [ -n "${DASH_PID:-}" ] && kill "$DASH_PID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

PY="$(command -v python3 2>/dev/null || true)"
CURL="$(command -v curl 2>/dev/null || true)"

pass=0; fail=0; skipped=0
ok()   { pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
no()   { fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; }
eq()   { [ "$2" = "$3" ] && ok "$1" || no "$1 (got '$2' want '$3')"; }
has()  { case "$2" in *"$3"*) ok "$1";; *) no "$1 (missing '$3' in: $2)";; esac; }
hasnt(){ case "$2" in *"$3"*) no "$1 (unexpected '$3' in: $2)";; *) ok "$1";; esac; }
skip() { skipped=$((skipped+1)); printf 'skipped: %s\n' "$1"; }

jget() { [ -n "$PY" ] || { printf '__NO_PYTHON__'; return 0; }
  "$PY" "$JGET" "$1" "$2" 2>/dev/null; }

# =========================================================================
# 0 — existence
# =========================================================================
eq "bin/dashboard exists and is executable" "$([ -x "$DASHBOARD_BIN" ] && printf yes || printf no)" yes
eq "the aib-dashboard.service unit text exists" "$([ -f "$UNIT_FILE" ] && printf yes || printf no)" yes

# =========================================================================
# A — schema 2 through bin/project: the SS B7 null shapes, fixture stream
#     (CONTRACT-visibility.md SS18/SS19, advisor findings 2/5/6/12)
# =========================================================================
mkdir -p "$WORK/acme/standup" "$WORK/acme-corrupt/standup" "$WORK/acme-reasons/standup"
cat > "$WORK/registry.json" <<EOF
{
  "schema_version": 4,
  "providers": { "codex": { "adapter": "/bin/true", "cap_sandbox": "workspace-write",
    "cap_tier": "t3", "cap_effort": "high", "cap_timeout": "900" } },
  "projects": {
    "acme":         { "home": "$WORK/acme",         "standup_dir": "$WORK/acme/standup",         "mux_session": "acme",         "provider": "codex", "model": "m", "effort": "low" },
    "acme-corrupt": { "home": "$WORK/acme-corrupt", "standup_dir": "$WORK/acme-corrupt/standup", "mux_session": "acme-corrupt", "provider": "codex", "model": "m", "effort": "low" },
    "acme-reasons": { "home": "$WORK/acme-reasons", "standup_dir": "$WORK/acme-reasons/standup", "mux_session": "acme-reasons", "provider": "codex", "model": "m", "effort": "low" }
  },
  "agents": {
    "acme-core":     { "project": "acme", "profile": "engine-dev", "clearance": "t2" },
    "acme-deny":     { "project": "acme", "profile": "engine-dev", "clearance": "t2" },
    "acme-legacy":   { "project": "acme", "profile": "engine-dev", "clearance": "t2" },
    "acme-unres":    { "project": "acme", "profile": "engine-dev", "clearance": "t2" },
    "acme-idle":     { "project": "acme", "profile": "engine-dev", "clearance": "t2" },
    "acme-corrupt-core": { "project": "acme-corrupt", "profile": "engine-dev", "clearance": "t2" },
    "acme-reasons-core": { "project": "acme-reasons", "profile": "engine-dev", "clearance": "t2" }
  }
}
EOF
REG="$WORK/registry.json"
EVENTROOT="$WORK/events-root"; PROJROOT="$WORK/projection-root"
mkdir -p "$EVENTROOT/attempts"

stream_paths() { EVENTS="$EVENTROOT/$1/main.events"; LOCK="$EVENTS.lock"; }
reset_stream() { rm -rf "$EVENTROOT/$1"; mkdir -p "$EVENTROOT/$1"; stream_paths "$1"; }

# commit_decided2 <uid> <agent> <pid> <decision> <extra-kv...>
commit_decided2() {
  local uid="$1" agent="$2" pid="$3" decision="$4"; shift 4
  local env kv="decision=$decision"$'\n'"code=0"$'\n'"reasons="$'\n'"pid=$pid" extra="$*"
  env="project_uid=$uid"$'\n'"actor_type=service"$'\n'"actor_id=aib-broker"$'\n'"agent_uid=$agent"
  [ -z "$extra" ] || kv="$kv"$'\n'"$extra"
  payload="$(aib_event_compose_decided_payload "$kv")"
  aib_event_commit "$EVENTS" "$LOCK" attempt.decided "$env" "$payload"
  LAST_ID="$AIB_EVENT_COMMIT_EVENT_ID"
}
# commit_legacy_decided <uid> <agent> <pid> — pre-launch-object shape, no binding objects at all.
commit_legacy_decided() {
  local uid="$1" agent="$2" pid="$3" env
  env="project_uid=$uid"$'\n'"actor_type=service"$'\n'"actor_id=aib-broker"$'\n'"agent_uid=$agent"
  aib_event_commit "$EVENTS" "$LOCK" attempt.decided "$env" "{\"decision\":\"allow\",\"pid\":$pid}"
  LAST_ID="$AIB_EVENT_COMMIT_EVENT_ID"
}
hb() { # hb <uid> <agent> <time> <status> <msg>
  printf '%s | %s | %s\n' "$3" "$4" "$5" >> "$WORK/$1/standup/$2.log"
}

DEAD_MIN=15; CAP=12
run_project() {
  RUN_OUT=""; RUN_ERR=""; RUN_RC=0
  RUN_OUT="$(AIBOBNET_REGISTRY="$REG" AIB_PROJECTION_ROOT="$PROJROOT" AIB_EVENT_ROOT="$EVENTROOT" \
    AIB_PROJECTION_DEAD_MINUTES="$DEAD_MIN" AIB_BROKER_CAPACITY="$CAP" TZ=Europe/Berlin \
    "$PROJECT_BIN" "$@" 2>"$WORK/project.err")"; RUN_RC=$?
  RUN_ERR="$(cat "$WORK/project.err" 2>/dev/null)"
}

reset_stream acme
commit_decided2 acme acme-core "$$" allow \
  "provider_resolved=codex"$'\n'"provider_source=agent:acme-core"$'\n'"provider_effective=codex"$'\n'\
"model_resolved=gpt-6-astra"$'\n'"model_source=project:acme"$'\n'"model_effective=gpt-6-astra"$'\n'\
"effort_resolved=xhigh"$'\n'"effort_source=team:acme"$'\n'"effort_effective=high"$'\n'\
"sandbox_requested=workspace-write"$'\n'"sandbox_effective=workspace-write"$'\n'\
"adapter_source=agent:acme-core"
commit_decided2 acme acme-deny "$$" deny \
  "provider_resolved=codex"$'\n'"provider_source=team:acme"$'\n'\
"model_resolved=gpt-6-astra"$'\n'"model_source=team:acme"$'\n'\
"effort_resolved=high"$'\n'"effort_source=project:acme"$'\n'\
"sandbox_requested=workspace-write"$'\n'\
"adapter_source=team:acme"
# real deny payload carries a reasons sentence; recompose with it for this record only.
kv_deny="decision=deny"$'\n'"code=3"$'\n'"reasons=needs:t4 not satisfied -- deploy key rotation pending on the build host"$'\n'"pid=$$"$'\n'\
"provider_resolved=codex"$'\n'"provider_source=team:acme"$'\n'\
"model_resolved=gpt-6-astra"$'\n'"model_source=team:acme"$'\n'\
"effort_resolved=high"$'\n'"effort_source=project:acme"$'\n'\
"sandbox_requested=workspace-write"$'\n'"adapter_source=team:acme"
payload="$(aib_event_compose_decided_payload "$kv_deny")"
aib_event_commit "$EVENTS" "$LOCK" attempt.decided \
  "project_uid=acme"$'\n'"actor_type=service"$'\n'"actor_id=aib-broker"$'\n'"agent_uid=acme-deny" "$payload"
commit_legacy_decided acme acme-legacy "$$"
# unresolved model: every binding object present and well-formed, but model.resolved/effective are
# both null because the composer received no model_* kv at all — the reserved, genuinely-unresolved
# shape (CONTRACT-visibility.md SS18), never a malformed object.
commit_decided2 acme acme-unres "$$" allow \
  "provider_resolved=codex"$'\n'"provider_source=agent:acme-unres"$'\n'"provider_effective=codex"$'\n'\
"effort_resolved=high"$'\n'"effort_source=agent:acme-unres"$'\n'"effort_effective=high"$'\n'\
"sandbox_requested=read-only"$'\n'"sandbox_effective=read-only"$'\n'\
"adapter_source=agent:acme-unres"
hb acme acme-core 09:00 busy "slice 6 build"
hb acme acme-deny 09:00 blocked "denied by broker policy"
hb acme acme-legacy 09:00 busy "legacy record"
hb acme acme-unres 09:00 busy "unresolved model"
hb acme acme-idle 09:00 idle "never launched anything"

run_project acme
OUT_ACME="$PROJROOT/acme.json"
eq "run_project acme exits 0 with all SS B7 shapes present" "$RUN_RC" 0

eq "schema bumps to 2" "$(jget "$OUT_ACME" schema)" 2
has "attested_sources gains launch" "$(jget "$OUT_ACME" attested_sources)" launch
eq "allow: launch.provider.effective" "$(jget "$OUT_ACME" 'agents.acme-core.launch.provider.effective')" codex
eq "allow with clamp: effort.effective differs from resolved" "$(jget "$OUT_ACME" 'agents.acme-core.launch.effort.effective')" high
eq "allow with clamp: effort.resolved is the pre-clamp value" "$(jget "$OUT_ACME" 'agents.acme-core.launch.effort.resolved')" xhigh
eq "launch.provider.requested is always null" "$(jget "$OUT_ACME" 'agents.acme-core.launch.provider.requested')" null
eq "launch.attested is true when launch is non-null" "$(jget "$OUT_ACME" 'agents.acme-core.launch.attested')" true

eq "deny: provider.effective is blanked to null" "$(jget "$OUT_ACME" 'agents.acme-deny.launch.provider.effective')" null
eq "deny: provider.resolved stays populated" "$(jget "$OUT_ACME" 'agents.acme-deny.launch.provider.resolved')" codex
eq "deny: sandbox.effective is blanked to null" "$(jget "$OUT_ACME" 'agents.acme-deny.launch.sandbox.effective')" null
eq "deny: sandbox.requested stays populated" "$(jget "$OUT_ACME" 'agents.acme-deny.launch.sandbox.requested')" workspace-write
deny_reasons="$(jget "$OUT_ACME" 'agents.acme-deny.launch.reasons')"
has "deny: reasons carries the verdict sentence" "$deny_reasons" "deploy key rotation"

eq "RM-2 legacy record folds to launch:null" "$(jget "$OUT_ACME" 'agents.acme-legacy.launch')" null
eq "RM-2 legacy record counts as launch_malformed" "$(jget "$OUT_ACME" 'anomalies.launch_malformed')" 1
eq "RM-2 legacy record never flips bin/project's exit code" "$RUN_RC" 0

eq "unresolved model: resolved is null" "$(jget "$OUT_ACME" 'agents.acme-unres.launch.model.resolved')" null
eq "unresolved model: effective is also null" "$(jget "$OUT_ACME" 'agents.acme-unres.launch.model.effective')" null
eq "unresolved model: provider (a real field) still resolves" "$(jget "$OUT_ACME" 'agents.acme-unres.launch.provider.effective')" codex
eq "unresolved model does not count as launch_malformed" "$(jget "$OUT_ACME" 'anomalies.launch_malformed')" 1

eq "no decided record: launch is null" "$(jget "$OUT_ACME" 'agents.acme-idle.launch')" null
eq "no decided record, stream ok: attempt is also null" "$(jget "$OUT_ACME" 'agents.acme-idle.attempt')" null

# bin/attempts byte-identity, copying the V-1 pin, against every fixture stream built above.
# Reference copy placed exactly as tests/frame_parity_spec.sh places it: a sibling bin/ + lib
# symlink at the same directory level, so the legacy script's own dirname/../lib resolution finds
# the real lib/aibobnet.sh rather than a path one level above $WORK.
mkdir -p "$WORK/reference/bin"
ln -sfn "$SRC_ROOT/lib" "$WORK/reference/lib"
LEGACY="$WORK/reference/bin/attempts"
cp "$SRC_ROOT/tests/fixtures/attempts_main.sh" "$LEGACY"; chmod +x "$LEGACY"
for agent in acme-core acme-deny acme-legacy acme-unres; do
  old="$(AIBOBNET_REGISTRY="$REG" "$LEGACY" "$agent" 2>&1)"; old_rc=$?
  new="$(AIBOBNET_REGISTRY="$REG" "$SRC_ROOT/bin/attempts" "$agent" 2>&1)"; new_rc=$?
  eq "bin/attempts byte-identical to main for $agent (rc)" "$new_rc" "$old_rc"
  eq "bin/attempts byte-identical to main for $agent (output)" "$new" "$old"
done

# frame_parity_spec.sh must stay green — schema 2 changes bin/project's Python pass and the fold,
# never the frame/CRC/legacy-CLI layer this spec pins. (Not +x in the repo; run via bash.)
if [ -r "$SRC_ROOT/tests/frame_parity_spec.sh" ]; then
  bash "$SRC_ROOT/tests/frame_parity_spec.sh" >"$WORK/parity.out" 2>&1
  eq "frame_parity_spec.sh stays green" "$?" 0
else
  skip "frame_parity_spec.sh not readable"
fi

# reasons cap: a 700-byte reasons string on a deny truncates to <=512 bytes in the projection.
# Uses a fresh project (acme-reasons, registered above), never reset_stream on "acme" — the
# byte-identity loop above and the --all isolation check below still need acme's original
# four-record fixture stream intact.
mkdir -p "$WORK/acme-reasons/standup"
reset_stream acme-reasons
long_reason="$(printf 'x%.0s' $(seq 1 700))"
kv_long="decision=deny"$'\n'"code=3"$'\n'"reasons=$long_reason"$'\n'"pid=$$"
payload="$(aib_event_compose_decided_payload "$kv_long")"
aib_event_commit "$EVENTS" "$LOCK" attempt.decided \
  "project_uid=acme-reasons"$'\n'"actor_type=service"$'\n'"actor_id=aib-broker"$'\n'"agent_uid=acme-reasons-core" "$payload"
hb acme-reasons acme-reasons-core 09:01 busy "long reasons fixture"
run_project acme-reasons
OUT_REASONS="$PROJROOT/acme-reasons.json"
if [ -n "$PY" ]; then
  reasons_len="$("$PY" -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["agents"]["acme-reasons-core"]["launch"]["reasons"].encode("utf-8")))' "$OUT_REASONS" 2>/dev/null || printf '__MISSING__')"
  if [ "$reasons_len" = __MISSING__ ]; then
    no "launch.reasons is capped at 512 bytes (launch object not present in the projection yet)"
  else
    eq "launch.reasons is capped at 512 bytes" "$([ "$reasons_len" -le 512 ] && printf yes || printf no)" yes
  fi
else
  skip "reasons byte-cap (python3 not present)"
fi

# stream-not-ok: launch is null with a distinct cause from "never launched" (SS19: "unknown").
reset_stream acme-corrupt
printf 'not a valid framed record\n' > "$EVENTROOT/acme-corrupt/main.events"
hb acme-corrupt acme-corrupt-core 09:00 busy "stream is corrupt"
run_project acme-corrupt
OUT_CORRUPT="$PROJROOT/acme-corrupt.json"
eq "corrupt stream still publishes (never a runtime gate)" "$RUN_RC" 0
eq "corrupt stream: launch is null" "$(jget "$OUT_CORRUPT" 'agents.acme-corrupt-core.launch')" null
has "corrupt stream: attested_sources still lists launch (present+readable, SS18)" \
  "$(jget "$OUT_CORRUPT" attested_sources)" launch
eq "corrupt stream: stream.status is corrupt, not ok" "$(jget "$OUT_CORRUPT" 'stream.status')" corrupt

# --all isolation is untouched by schema 2: one project's launch_malformed does not stop the other.
run_project --all
eq "--all still exits 0 with a mixed-shape fixture" "$RUN_RC" 0
eq "--all still writes acme" "$([ -f "$PROJROOT/acme.json" ] && printf yes || printf no)" yes
eq "--all still writes acme-corrupt" "$([ -f "$PROJROOT/acme-corrupt.json" ] && printf yes || printf no)" yes

# =========================================================================
# B — fold: launch carried as raw JSON, never scalar() (CONTRACT-visibility.md SS12/SS18)
# =========================================================================
if [ -n "$PY" ]; then
  raw_json_check="$("$PY" - "$FOLD_PY" <<'PYEOF'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location('reader', sys.argv[1])
reader = importlib.util.module_from_spec(spec); spec.loader.exec_module(reader)
decided_allow = dict(event_id='acme-main-1', attempt_id='acme-main-1', event_type='attempt.decided',
    agent_uid='acme-core', occurred_at='2026-09-07T00:00:00Z',
    payload={'decision':'allow','pid':1,
             'provider':{'requested':None,'resolved':'codex','source':'agent:acme-core','effective':'codex'},
             'model':{'requested':None,'resolved':None,'source':None,'effective':None},
             'effort':{'requested':None,'resolved':'xhigh','source':'team:acme','effective':'high'},
             'sandbox':{'requested':'workspace-write','effective':'workspace-write'},
             'adapter':{'raw':'codex','effective_path':'/opt/x','source':'agent:acme-core'},
             'reasons':''})
decided_legacy = dict(event_id='acme-main-2', attempt_id='acme-main-2', event_type='attempt.decided',
    agent_uid='acme-legacy', occurred_at='2026-09-07T00:00:01Z', payload={'decision':'allow','pid':2})
records = [(1, decided_allow, False), (2, decided_legacy, False)]
attempts = {a['id']: a for a in reader.fold_records(records)} if hasattr(reader, 'fold_records') else {}
out = dict(has_launch=hasattr(reader, 'fold_records'),
           model_null_not_empty=attempts.get('acme-main-1', {}).get('launch', {}).get('model', {}).get('resolved', 'MISSING') if attempts else 'MISSING',
           legacy_launch=attempts.get('acme-main-2', {}).get('launch', 'MISSING') if attempts else 'MISSING',
           no_valueerror=True)
print(json.dumps(out))
PYEOF
)"
  eq "attempts_fold.py: allow's launch.model.resolved stays None, never ''" \
    "$(printf '%s' "$raw_json_check" | "$PY" -c 'import json,sys;print(json.load(sys.stdin).get("model_null_not_empty"))' 2>/dev/null)" None
  eq "attempts_fold.py: legacy record folds launch to None, not a KeyError" \
    "$(printf '%s' "$raw_json_check" | "$PY" -c 'import json,sys;print(json.load(sys.stdin).get("legacy_launch"))' 2>/dev/null)" None
else
  skip "fold raw-JSON passthrough (python3 not present)"
fi

# =========================================================================
# C — bin/dashboard HTTP surface (CONTRACT-visibility.md SS19, docs/decisions/0008-dashboard.md)
#     A hand-built projection root, independent of whether bin/project emits schema 2 yet.
# =========================================================================
DROOT="$WORK/dash-root"; mkdir -p "$DROOT"
write_json() { # write_json <uid> <json>
  printf '%s' "$2" > "$DROOT/$1.json"
}
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

write_json acme "$(cat <<JSON
{"schema":2,"generated_at":"$(now_iso)","project_uid":"acme","attested_sources":["stream","capacity","launch"],
 "stream":{"status":"ok","last_seq":3,"anchor":{"value":3,"relationship":"ok"},"torn_tail":false,"undecodable_records":[]},
 "capacity":{"limit":12,"live":1,"as_of":"$(now_iso)"},
 "attention":[],
 "agents":{
   "acme-core":{"state":"busy","since":"$(now_iso)","message":"<script>alert(1)<\/script>","stale":false,"attested":false,
     "attempt":{"id":"acme-main-1","decided_at":"$(now_iso)","decision":"allow","open":true,"last":{"class":null,"stage":null,"ended_at":null}},
     "launch":{"provider":{"requested":null,"resolved":"codex","source":"agent:acme-core","effective":"codex"},
       "model":{"requested":null,"resolved":"gpt-6-astra","source":"project:acme","effective":"gpt-6-astra"},
       "effort":{"requested":null,"resolved":"xhigh","source":"team:acme","effective":"high"},
       "sandbox":{"requested":"workspace-write","effective":"workspace-write"},
       "adapter":{"source":"agent:acme-core"},"reasons":"<img src=x onerror=1>","attested":true}},
   "acme-deny":{"state":"blocked","since":"$(now_iso)","message":"denied by policy","stale":false,"attested":false,
     "attempt":{"id":"acme-main-2","decided_at":"$(now_iso)","decision":"deny","open":false,"last":{"class":null,"stage":null,"ended_at":"$(now_iso)"}},
     "launch":{"provider":{"requested":null,"resolved":"codex","source":"team:acme","effective":null},
       "model":{"requested":null,"resolved":"gpt-6-astra","source":"team:acme","effective":null},
       "effort":{"requested":null,"resolved":"high","source":"project:acme","effective":null},
       "sandbox":{"requested":"workspace-write","effective":null},
       "adapter":{"source":"team:acme"},"reasons":"needs:t4 deploy key rotation pending","attested":true}},
   "acme-idle":{"state":"idle","since":"$(now_iso)","message":"nothing to do","stale":false,"attested":false,
     "attempt":null,"launch":null},
   "acme-unknown-launch":{"state":"unknown","since":null,"message":"","stale":true,"attested":false,
     "attempt":null,"launch":null}
 },
 "anomalies":{"unregistered_logs":0,"unparsable_lines":0,"uid_mismatches":0,"undecodable_records":0,"launch_malformed":0}}
JSON
)"
write_json acme-corrupt "$(cat <<JSON
{"schema":2,"generated_at":"$(now_iso)","project_uid":"acme-corrupt","attested_sources":["stream","capacity","launch"],
 "stream":{"status":"corrupt","last_seq":1,"anchor":{"value":1,"relationship":"ok"},"torn_tail":false,"undecodable_records":[]},
 "capacity":{"limit":12,"live":0,"as_of":"$(now_iso)"},"attention":[],
 "agents":{"acme-corrupt-core":{"state":"unknown","since":null,"message":"","stale":true,"attested":false,
   "attempt":null,"launch":null}},
 "anomalies":{"unregistered_logs":0,"unparsable_lines":0,"uid_mismatches":0,"undecodable_records":0,"launch_malformed":0}}
JSON
)"
old_epoch="$(( $(date -u +%s) - 86400 ))"
old_iso="$([ "$(uname)" = Darwin ] && date -u -r "$old_epoch" +%Y-%m-%dT%H:%M:%SZ || date -u -d "@$old_epoch" +%Y-%m-%dT%H:%M:%SZ)"
write_json acme-stale "$(cat <<JSON
{"schema":2,"generated_at":"$old_iso","project_uid":"acme-stale","attested_sources":["stream","capacity","launch"],
 "stream":{"status":"ok","last_seq":1,"anchor":{"value":1,"relationship":"ok"},"torn_tail":false,"undecodable_records":[]},
 "capacity":{"limit":12,"live":0,"as_of":"$old_iso"},"attention":[],"agents":{},
 "anomalies":{"unregistered_logs":0,"unparsable_lines":0,"uid_mismatches":0,"undecodable_records":0,"launch_malformed":0}}
JSON
)"
: > "$DROOT/.acme.json.tmp42"                      # dotfile temp: must be ignored
ln -sfn "/etc/hostname" "$DROOT/evil.json" 2>/dev/null   # symlink: must be ignored, never followed
printf '{}' > "$DROOT/bad name.json"                # invalid token (space): must be ignored

start_dashboard() {
  DASH_PID=""; DASH_PORT=""
  [ -x "$DASHBOARD_BIN" ] || return 1
  AIB_DASHBOARD_BIND=127.0.0.1 AIB_DASHBOARD_PORT=0 AIB_PROJECTION_ROOT="$DROOT" \
    AIB_PROJECTION_STALE_SECONDS=60 "$DASHBOARD_BIN" >"$WORK/dash.out" 2>"$WORK/dash.err" &
  DASH_PID=$!
  local i=0
  while [ "$i" -lt 30 ]; do
    DASH_PORT="$(grep -m1 '^port=' "$WORK/dash.out" 2>/dev/null | cut -d= -f2)"
    [ -n "$DASH_PORT" ] && return 0
    kill -0 "$DASH_PID" 2>/dev/null || return 1
    sleep 0.1; i=$((i+1))
  done
  return 1
}
curl_ok() { [ -n "$CURL" ] && [ -n "${DASH_PORT:-}" ]; }
get() { curl_ok && "$CURL" -sS --max-time 2 "http://127.0.0.1:$DASH_PORT$1"; }
head_of() { curl_ok && "$CURL" -sSD - -o /dev/null --max-time 2 "http://127.0.0.1:$DASH_PORT$1"; }
code_of() { curl_ok && "$CURL" -sS -o /dev/null -w '%{http_code}' --max-time 2 "$@" "http://127.0.0.1:$DASH_PORT$1"; }

if start_dashboard; then
  ok "bin/dashboard starts on AIB_DASHBOARD_BIND=127.0.0.1 AIB_DASHBOARD_PORT=0 and prints its port"
else
  no "bin/dashboard starts on AIB_DASHBOARD_BIND=127.0.0.1 AIB_DASHBOARD_PORT=0 and prints its port"
fi

fleet="$(get /api/fleet)"
has "GET /api/fleet lists acme" "$fleet" '"acme"'
has "GET /api/fleet lists acme-corrupt" "$fleet" '"acme-corrupt"'
has "GET /api/fleet lists acme-stale" "$fleet" '"acme-stale"'
hasnt "GET /api/fleet ignores the dotfile temp" "$fleet" '.acme.json.tmp42'
hasnt "GET /api/fleet ignores the planted symlink" "$fleet" 'evil'
hasnt "GET /api/fleet ignores the space-named file" "$fleet" 'bad name'

proj="$(get /api/project/acme)"
has "GET /api/project/acme returns schema 2" "$proj" '"schema":2'
eq "GET /api/project/does-not-exist is a 404" "$(code_of /api/project/does-not-exist)" 404
eq "GET /api/project/.. is a 404, never a 500" "$(code_of /api/project/..)" 404
eq "GET /api/project/%2e%2e is a 404, never a 500" "$(code_of /api/project/%2e%2e)" 404
eq "GET /api/project/..%2fx is a 404, never a 500" "$(code_of "/api/project/..%2fx")" 404
not_found_body="$(get /api/project/does-not-exist)"
has "a 404 body is JSON, not an HTML stack trace" "$not_found_body" '{'

html_fleet_headers="$(head_of /)"
has "GET / is text/html; charset=utf-8" "$html_fleet_headers" "text/html; charset=utf-8"
has "GET / carries the pinned CSP header" "$html_fleet_headers" "default-src 'none'; style-src 'unsafe-inline'"
html_fleet="$(get /)"
hasnt "GET / has zero <script tags" "$html_fleet" "<script"
has "GET / has a meta refresh for liveness" "$html_fleet" 'meta http-equiv="refresh"'

html_proj="$(get /p/acme)"
hasnt "GET /p/acme has zero <script tags even with a hostile message" "$html_proj" "<script>alert"
has "GET /p/acme escapes a hostile heartbeat message" "$html_proj" "&lt;script&gt;"
hasnt "GET /p/acme never renders the raw hostile reasons markup" "$html_proj" "<img src=x onerror=1>"
has "GET /p/acme escapes hostile launch.reasons text" "$html_proj" "&lt;img src=x onerror=1&gt;"
has "SS19: deny renders effective as denied" "$html_proj" "denied"
has "SS19: no decided record + ok stream renders never launched" "$html_proj" "never launched"

html_corrupt="$(get /p/acme-corrupt)"
has "SS19: no decided record + corrupt stream renders unknown, not never launched" "$html_corrupt" "unknown"

html_stale="$(get /p/acme-stale)"
has "SS19: a day-old generated_at renders stale" "$html_stale" "stale"
lower_stale="$(printf '%s' "$html_stale" | tr 'A-Z' 'a-z')"
hasnt "SS19: an aging/unregistered file is never rendered as an alarm" "$lower_stale" "alarm"
hasnt "SS19: an aging/unregistered file is never rendered as an error" "$lower_stale" "error"

eq "POST / is a 405" "$(code_of / -X POST)" 405
eq "POST /api/fleet is a 405" "$(code_of /api/fleet -X POST)" 405

kill "$DASH_PID" 2>/dev/null; wait "$DASH_PID" 2>/dev/null; DASH_PID=""

# Bind refusal: 0.0.0.0 without an explicit AIB_DASHBOARD_BIND=0.0.0.0 must refuse to start.
if [ -x "$DASHBOARD_BIN" ]; then
  AIB_DASHBOARD_BIND=0.0.0.0 AIB_DASHBOARD_PORT=0 AIB_PROJECTION_ROOT="$DROOT" \
    timeout 2 "$DASHBOARD_BIN" >"$WORK/bind.out" 2>"$WORK/bind.err"
  bind_rc=$?
  eq "refuses to bind 0.0.0.0 by default (nonzero exit)" "$([ "$bind_rc" -ne 0 ] && printf yes || printf no)" yes
  eq "refuses to bind 0.0.0.0 with a message on stderr" "$([ -s "$WORK/bind.err" ] && printf yes || printf no)" yes
else
  no "refuses to bind 0.0.0.0 by default (nonzero exit) (bin/dashboard does not exist)"
  no "refuses to bind 0.0.0.0 with a message on stderr (bin/dashboard does not exist)"
fi

# =========================================================================
# D — the unit file text (docs/decisions/0008-dashboard.md SSE)
# =========================================================================
unit_text="$(cat "$UNIT_FILE" 2>/dev/null)"
has "unit runs as User=aib-dash" "$unit_text" "User=aib-dash"
has "unit makes /var/lib/aib/auth inaccessible" "$unit_text" "InaccessiblePaths=/var/lib/aib/auth"
has "unit makes /var/lib/aib/events inaccessible" "$unit_text" "/var/lib/aib/events"
has "unit's projection root is read-only" "$unit_text" "ReadOnlyPaths=/var/lib/aib/projection"
# A directive-line check, not a naive substring one: the unit's own comments discuss
# ReadWritePaths by name (explaining why it is absent), so a plain `hasnt` on that string would
# trip on the comment text itself.
eq "unit never grants ReadWritePaths=" "$(printf '%s\n' "$unit_text" | grep -c '^ReadWritePaths=')" 0

total=$((pass+fail))
printf '\n%d checks (%d skipped): %d ok / %d fail\n' "$total" "$skipped" "$pass" "$fail"
[ "$fail" -eq 0 ]
