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
#
#   S2a (agent view, design B1/B2/C1-C4): section "S2a" below, hand-built projections acme-sup / acme-supxss / acme-supbad / acme-supold.
#   The HTML markers the builder must emit (chosen here; assertions target these, never CSS):
#     /p/<uid>   a section whose heading text is `Agents (supervised)`, placed BEFORE the existing agents table, present only when at least
#                one agent has a non-null `supervisor`. One `<article class="sup-card" data-agent="<uid>" ...>` per supervised agent
#                (class is exactly `sup-card`; `sup-card sup-stale` when the projection is older than AIB_PROJECTION_STALE_SECONDS, which also
#                keeps the existing `stale since` banner; `sup-card sup-invalid` for an invalid supervisor block). Oneshot agents get no card.
#       valid card attributes: data-session-state=<enum> data-health=<healthy|unhealthy> data-unit-state=<text> data-off-duty=<true|false>
#                data-braked=<true iff brake.tripped_at is set> data-login-state=<account.state | none (account null) | invalid>
#       valid card text: state_reason, label, `c0de`-style id_hint, absolute expiry date (YYYY-MM-DD of expires_at), relative hint as ONE unit,
#                floor, units `d` `h` `min` (`in 6 d`, `expired 2 h ago`), `braked since` when braked, the words `off duty` iff off_duty is true,
#                up to 5 last_control lines containing verb, outcome and reason, restarts, current turn msg_id, session_id_short.
#       invalid supervisor block (bad enum, string > 200 chars, > 5 last_control entries, non-object): the card carries data-supervisor="invalid"
#                and the text `supervisor data invalid`, and NO value of the block appears anywhere in the page. An invalid account inside a
#                valid supervisor block: the card still renders the supervisor part, shows the text `account data invalid` in place of the
#                account, data-login-state="invalid", and no account value appears. Never a 500.
#     /          the project row contains `<td class="sup-counts" data-supervised="N" data-braked="N" data-login-attention="N">`
#                (login-attention = supervised agents whose account state is expiring|expired|absent; N = 0 for a project without supervisors).
#   All projected strings stay inert (HTML-escaped). Expected on the unbuilt renderer: every S2a assertion except the no-500 and the
#   no-card-for-unsupervised ones is RED.
#
#   S2a round 2 (design v2): R5 the reader accepts an account id_hint of at most 4 characters; R7 each whitelist is pinned in its own layer
#   (reader: control keys exactly req/verb/outcome/reason/at, verb outside agentctl's set, outcome outside done|rejected|accepted, account state
#   outside the enum; each => the invalid markers above, with no value of the block rendered); the relative expiry hint is exactly ONE
#   floored unit (`in 2 d`, `in 23 h`, `in 5 min`, `in 0 min`, `expired 3 d ago`, `expired 0 min ago`; d >= 1 day, h >= 1 hour, else min);
#   the fleet counts treat `absent` as login-attention and count an invalid supervisor block as supervised but never as braked or
#   login-attention; a null session id renders as the em dash U+2014 (never `<code>null</code>`). The reader keeps its 200-char bound for
#   state_reason/reason (hand-built projections): the R6 machine-word rule lives in bin/project only. Fixtures are written by $WORK/supfix.py.
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

# Binding faults are display anomalies, including malformed leaves. Neither raw
# nulls nor multibyte reasons may turn a legacy-compatible fold into corruption.
if [ -n "$PY" ]; then
  "$PY" - "$FOLD_PY" <<'PYEOF'
import copy, importlib.util, sys
spec = importlib.util.spec_from_file_location('reader', sys.argv[1])
reader = importlib.util.module_from_spec(spec); spec.loader.exec_module(reader)
binding = dict(requested=None, resolved='codex', source='project:acme', effective='codex')
payload = dict(decision='allow', pid=1, provider=binding, model=binding, effort=binding,
               sandbox=dict(requested='read-only', effective='read-only'),
               adapter=dict(source='project:acme', effective_path='/private/adapter'), reasons='é' * 257)
def fold(p):
    record = dict(attempt_id='acme-main-1', agent_uid='acme-core', occurred_at='2026-09-09T00:00:00Z', event_type='attempt.decided', payload=p)
    return reader.fold_records([(1, record, False)])[0]
launch = fold(payload)['launch']
assert launch['reasons'] == 'é' * 256
assert launch['adapter'] == dict(source='project:acme')
assert launch['provider']['requested'] is None
for key in ['provider', 'model', 'effort', 'sandbox', 'adapter']:
    for value in [None, [], 'bad', {}]:
        p = copy.deepcopy(payload); p[key] = value
        assert fold(p)['launch'] is None, (key, value)
for key, value in [('reasons', []), ('model', dict(binding, effective=3)), ('effort', dict(binding, source='bad\0source'))]:
    p = copy.deepcopy(payload); p[key] = value
    assert fold(p)['launch'] is None, key
PYEOF
  eq "launch malformed corpus: nulls, privacy, UTF-8 cap and leaf faults stay nonfatal" "$?" 0
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
if [ -n "$PY" ]; then
  "$PY" - "$DROOT/acme.json" <<'PYEOF'
import copy, json, sys
from pathlib import Path
path = Path(sys.argv[1]); p = json.loads(path.read_text())
a = copy.deepcopy(p['agents']['acme-core'])
a['message'] = 'unresolved launch binding'
a['attempt']['id'] = 'acme-main-3'
for dimension in ['provider', 'model', 'effort', 'sandbox']:
    a['launch'][dimension]['effective'] = None
a['launch']['model']['resolved'] = None
p['agents']['acme-unresolved'] = a
path.write_text(json.dumps(p))
PYEOF
fi
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

# --- S2a fixtures (hand-built; no real data) ---
if [ -n "$PY" ]; then
cat > "$WORK/supfix.py" <<'PYEOF'
import datetime as dt, json, sys
root = sys.argv[1]; mode = sys.argv[2]
now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
iso = lambda d: d.strftime('%Y-%m-%dT%H:%M:%SZ')
def base(uid, gen, agents):
    return {"schema": 2, "generated_at": iso(gen), "project_uid": uid, "attested_sources": ["stream", "capacity", "launch"],
        "stream": {"status": "ok", "last_seq": 1, "anchor": {"value": 1, "relationship": "ok"}, "torn_tail": False, "undecodable_records": []},
        "capacity": {"limit": 12, "live": 0, "as_of": iso(gen)}, "attention": [], "agents": agents,
        "anomalies": {"unregistered_logs": 0, "unparsable_lines": 0, "uid_mismatches": 0, "undecodable_records": 0, "launch_malformed": 0}}
def agent(sup, gen=now):
    return {"state": "idle", "since": iso(gen), "message": "plain heartbeat", "stale": False, "attested": False, "attempt": None, "launch": None, "supervisor": sup}
def acct(state, label, hint, exp, chk):
    return {"provider": "claude-code", "state": state, "label": label, "id_hint": hint, "expires_at": exp, "checked_at": chk}
def sup(gen=now, **kw):
    v = {"mode": "supervised", "account": None, "unit_state": "active", "disabled": False, "session_state": "WORKING", "state_reason": "",
         "health": "healthy", "tick_seq": 10, "tick_age_s": 12, "current_turn": None, "session_id_short": None, "turns_in_session": 0,
         "restarts_24h": 0, "brake": {"consecutive": 0, "tripped_at": None}, "off_duty": False, "inbox_open": 0, "last_control": [], "journal_seq": 4}
    v.update(kw); return v
def lc(req, verb, outcome, reason, at): return {"req": req, "verb": verb, "outcome": outcome, "reason": reason, "at": iso(at)}
def put(uid, value):
    open(f"{root}/{uid}.json", "w").write(json.dumps(value))

if mode == 'rel':
    cases = {"d1": 216000, "d2": 90000, "h1": 84600, "h2": 5400, "m1": 340, "m2": 3570, "z1": 40,
             "p0": -20, "pm": -310, "ph": -5400, "pd": -(3 * 86400 + 12 * 3600), "pd2": -(25 * 3600), "n1": None}
    agents = {}
    for name, off in cases.items():
        exp = None if off is None else iso(now + dt.timedelta(seconds=off))
        agents["rel-" + name] = agent(sup(account=acct("expired" if off is not None and off < 0 else "ok", "rel-label", "ab12", exp, iso(now))))
    put("acme-suprel", base("acme-suprel", now, agents))
    sys.exit(0)

run = sup(session_state="WORKING", state_reason="quota backoff", unit_state="active", health="healthy", tick_age_s=12,
    current_turn={"msg_id": "m-77", "started_at": iso(now), "attempt_id": "att-9"}, session_id_short="3f2b8c1e", turns_in_session=7, restarts_24h=2,
    account=acct("ok", "Interim: PO account", "c0de", iso(now + dt.timedelta(days=6, hours=2)), iso(now)),
    last_control=[lc(7, "neustart", "done", "", now), lc(2, "feierabend", "rejected", "not_authorized", now - dt.timedelta(hours=1))])
brk = sup(session_state="FAILED", state_reason="brake tripped", unit_state="failed", health="unhealthy", tick_age_s=4000, off_duty=True,
    brake={"consecutive": 3, "tripped_at": iso(now - dt.timedelta(minutes=10))},
    account=acct("expired", "Backup login", "beef", iso(now - dt.timedelta(hours=2, minutes=10)), iso(now)))
put("acme-sup", base("acme-sup", now, {"sup-run": agent(run), "sup-brk": agent(brk), "sup-solo": agent(None)}))

xss = sup(state_reason="<script>SUPXSS</script>",
    account=acct("ok", "<img src=x onerror=SUPXSS>", "ab12", iso(now + dt.timedelta(days=3)), iso(now)),
    last_control=[lc(1, "neustart", "rejected", "<b onmouseover=SUPXSS>x</b>", now)])
put("acme-supxss", base("acme-supxss", now, {"sup-xss": agent(xss)}))

bad = {
  "bad-session": sup(session_state="EXPLODING", state_reason="LEAKMARK1"),
  "bad-long":    sup(state_reason="LEAKLONG" + "A" * 300),
  "bad-control": sup(state_reason="LEAKMARK3", last_control=[lc(i, "neustart", "done", "LEAKMARK2", now) for i in range(1, 8)]),
  "bad-acct":    sup(state_reason="fine-reason-ok", account=acct("ok", "LEAKLABEL", "LEAKHINT123456", None, None)),
  "bad-type":    "oops-LEAKMARK4",
  "good":        sup(state_reason="still-fine"),
  "bad-hint5":   sup(state_reason="hint5_card", account=acct("ok", "LEAKFIVE", "abcde", None, None)),
  "ok-hint4":    sup(state_reason="hint4_card", account=acct("ok", "hint4-label", "ab12", None, None)),
  "bad-ctl-verb":    sup(state_reason="LEAKCTLV", last_control=[lc(1, "frobnicate", "done", "", now)]),
  "bad-ctl-extra":   sup(state_reason="LEAKCTLX", last_control=[dict(lc(1, "neustart", "done", "", now), caller="LEAKCALLER")]),
  "bad-ctl-outcome": sup(state_reason="LEAKCTLO", last_control=[lc(1, "neustart", "weird", "", now)]),
  "bad-acct-state":  sup(state_reason="acct_state_ok", account=acct("weird", "LEAKSTATE", "ab12", None, None)),
}
put("acme-supbad", base("acme-supbad", now, {k: agent(v) for k, v in bad.items()}))

old = now - dt.timedelta(days=1)
put("acme-supold", base("acme-supold", old, {"sup-old": agent(sup(gen=old, state_reason="old news"), old)}))

cnt = {
  "cnt-absent":  sup(account=acct("absent", "cnt-label", "", None, None)),
  "cnt-brk":     sup(brake={"consecutive": 2, "tripped_at": iso(now - dt.timedelta(minutes=10))}, account=acct("ok", "cnt-label", "ab12", None, None)),
  "cnt-invalid": sup(session_state="EXPLODING", brake={"consecutive": 9, "tripped_at": iso(now)}, account=acct("expired", "cnt-label", "ab12", None, None)),
  "cnt-solo":    None,
}
put("acme-supcnt", base("acme-supcnt", now, {k: agent(v) for k, v in cnt.items()}))
PYEOF
"$PY" "$WORK/supfix.py" "$DROOT" static
fi

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
code_of() { local path="$1"; shift; curl_ok && "$CURL" -sS -o /dev/null -w '%{http_code}' --max-time 2 "$@" "http://127.0.0.1:$DASH_PORT$path"; }

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

if [ -n "$PY" ] && [ -n "$DASH_PORT" ]; then
  "$PY" - "$DASH_PORT" <<'PYEOF'
from html.parser import HTMLParser
from urllib.request import urlopen
import re, sys
class Rows(HTMLParser):
    def __init__(self):
        super().__init__(); self.rows=[]; self.row=None; self.cell=None
    def handle_starttag(self, tag, attrs):
        if tag == 'tr': self.row=[]
        if tag in ('td', 'th'): self.cell=[]
    def handle_data(self, data):
        if self.cell is not None: self.cell.append(data)
    def handle_endtag(self, tag):
        if tag in ('td', 'th') and self.cell is not None:
            self.row.append(' '.join(self.cell)); self.cell=None
        if tag == 'tr' and self.row is not None:
            self.rows.append(self.row); self.row=None
with urlopen('http://127.0.0.1:'+sys.argv[1]+'/p/acme', timeout=2) as response:
    assert response.status == 200
    parser=Rows(); parser.feed(response.read().decode())
rows=[row for row in parser.rows if row and row[0].split()[0] == 'acme-unresolved']
assert len(rows) == 1 and len(rows[0]) == 7, rows
row=rows[0]
assert re.search(r'\bdecision\s+allow\b', row[6]), row[6]
for cell in row[2:6]:
    assert re.search(r'\beffective\s+unknown\b', cell), cell
assert not re.search(r'\bdenied\b', ' '.join(row)), row
PYEOF
  eq "HTTP unresolved allow: own agent row renders unknown, never denied" "$?" 0
fi

html_corrupt="$(get /p/acme-corrupt)"
has "SS19: no decided record + corrupt stream renders unknown, not never launched" "$html_corrupt" "unknown"

html_stale="$(get /p/acme-stale)"
has "SS19: a day-old generated_at renders stale" "$html_stale" "stale"
lower_stale="$(printf '%s' "$html_stale" | tr 'A-Z' 'a-z')"
hasnt "SS19: an aging/unregistered file is never rendered as an alarm" "$lower_stale" "alarm"
hasnt "SS19: an aging/unregistered file is never rendered as an error" "$lower_stale" "error"


# =========================================================================
# S2a — agent view: B1/B2 validation, C1 contents, C2 fleet counts, C3 escaping, C4 stale greying
# =========================================================================
card_of() { printf '%s' "$1" | "$PY" -I -c 'import re,sys;h=sys.stdin.read();m=re.search(r"<article[^>]*data-agent=\""+re.escape(sys.argv[1])+r"\"[^>]*>.*?</article>",h,re.S);print(m.group(0) if m else "")' "$2"; }
open_of() { printf '%s' "$1" | "$PY" -I -c 'import re,sys;m=re.match(r"<article[^>]*>",sys.stdin.read());print(m.group(0) if m else "")'; }
row_of() { printf '%s' "$1" | "$PY" -I -c 'import re,sys;h=sys.stdin.read()
for m in re.finditer(r"<tr>.*?</tr>",h,re.S):
    if "href=\"/p/"+sys.argv[1]+"\"" in m.group(0): print(m.group(0)); break' "$2"; }
lowercase() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }

page_sup="$(get /p/acme-sup)"
eq "C1: GET /p/acme-sup is 200" "$(code_of /p/acme-sup)" 200
has "C1: the section heading 'Agents (supervised)' is present" "$page_sup" "Agents (supervised)"
order="$(printf '%s' "$page_sup" | "$PY" -I -c 'import sys;h=sys.stdin.read();a=h.find("Agents (supervised)");b=h.find("Agent state and effective launch bindings");print("ok" if 0<=a<b else "bad %d %d"%(a,b))')"
eq "C1: the supervised section sits above the existing agents table" "$order" ok
eq "C1: one sup-card per supervised agent, none for the oneshot (supervisor null)" "$(printf '%s' "$page_sup" | grep -o '<article class="sup-card' | wc -l | tr -d ' ')|$(card_of "$page_sup" sup-solo | wc -c | tr -d ' ')" "2|1"
c_run="$(card_of "$page_sup" sup-run)"; o_run="$(open_of "$c_run")"
has "C1: running card: class sup-card (fresh, not stale)" "$o_run" 'class="sup-card"'
has "C1: running card: data-session-state" "$o_run" 'data-session-state="WORKING"'
has "C1: running card: data-health" "$o_run" 'data-health="healthy"'
has "C1: running card: data-unit-state" "$o_run" 'data-unit-state="active"'
has "C1: running card: data-off-duty false" "$o_run" 'data-off-duty="false"'
has "C1: running card: data-braked false" "$o_run" 'data-braked="false"'
has "C1: running card: data-login-state" "$o_run" 'data-login-state="ok"'
has "C1: running card shows the reason" "$c_run" "quota backoff"
has "C1: running card shows the account label" "$c_run" "Interim: PO account"
has "C1: running card shows the id_hint" "$c_run" "c0de"
has "C1: running card shows the absolute expiry date" "$c_run" "$(date -u -d '6 days 2 hours' +%Y-%m-%d)"
has "C1: running card shows the relative expiry hint (one unit, floor)" "$c_run" "in 6 d"
has "C1: running card shows the current turn" "$c_run" "m-77"
has "C1: running card shows the short session id" "$c_run" "3f2b8c1e"
has "C1: running card lists a done control (verb)" "$c_run" "neustart"
has "C1: running card lists a rejected control with its reason" "$c_run" "not_authorized"
has "C1: running card shows the outcome words" "$(lowercase "$c_run")" "rejected"
hasnt "C1: running card does not say 'off duty'" "$(lowercase "$c_run")" "off duty"
hasnt "C1: running card does not say 'braked since'" "$(lowercase "$c_run")" "braked since"
c_brk="$(card_of "$page_sup" sup-brk)"; o_brk="$(open_of "$c_brk")"
has "C1: braked card: data-session-state FAILED" "$o_brk" 'data-session-state="FAILED"'
has "C1: braked card: data-health unhealthy" "$o_brk" 'data-health="unhealthy"'
has "C1: braked card: data-unit-state failed" "$o_brk" 'data-unit-state="failed"'
has "C1: braked card: data-off-duty true" "$o_brk" 'data-off-duty="true"'
has "C1: braked card: data-braked true" "$o_brk" 'data-braked="true"'
has "C1: braked card: data-login-state expired" "$o_brk" 'data-login-state="expired"'
has "C1: braked card says 'braked since'" "$(lowercase "$c_brk")" "braked since"
has "C1: off-duty card says 'off duty'" "$(lowercase "$c_brk")" "off duty"
has "C1: expired login shows the relative hint 'expired 2 h ago'" "$c_brk" "expired 2 h ago"
has "C1: braked card shows its account label" "$c_brk" "Backup login"
page_plain="$(get /p/acme)"
hasnt "C1: a project without supervised agents has no supervised section" "$page_plain" "Agents (supervised)"
hasnt "C1: ...and no sup-card" "$page_plain" '<article class="sup-card'

# C2 fleet counts
fleet_html="$(get /)"
row_sup="$(row_of "$fleet_html" acme-sup)"
has "C2: fleet row acme-sup: 2 supervised" "$row_sup" 'data-supervised="2"'
has "C2: fleet row acme-sup: 1 braked" "$row_sup" 'data-braked="1"'
has "C2: fleet row acme-sup: 1 login-attention (expired; the ok one does not count)" "$row_sup" 'data-login-attention="1"'
has "C2: the counts live in a td.sup-counts" "$row_sup" 'class="sup-counts"'
row_plain="$(row_of "$fleet_html" acme)"
has "C2: fleet row acme (no supervisors): data-supervised 0" "$row_plain" 'data-supervised="0"'
has "C2: ...data-braked 0" "$row_plain" 'data-braked="0"'
has "C2: ...data-login-attention 0" "$row_plain" 'data-login-attention="0"'

# C3 escaping
page_xss="$(get /p/acme-supxss)"
eq "C3: GET /p/acme-supxss is 200" "$(code_of /p/acme-supxss)" 200
has "C3: the card exists" "$(card_of "$page_xss" sup-xss)" "data-agent"
hasnt "C3: no raw <script> from a state_reason" "$page_xss" "<script>SUPXSS"
hasnt "C3: no raw <img> from an account label" "$page_xss" "<img src=x"
hasnt "C3: no raw <b onmouseover> from a control reason" "$page_xss" "<b onmouseover"
has "C3: the script text is shown inert (escaped)" "$page_xss" "&lt;script&gt;SUPXSS"
has "C3: the label is shown inert (escaped)" "$page_xss" "&lt;img src=x"

# B1/B2 invalid blocks
page_bad="$(get /p/acme-supbad)"
eq "B1: GET /p/acme-supbad (invalid blocks) is 200, never 500" "$(code_of /p/acme-supbad)" 200
eq "B1: the fleet page still renders with an invalid project" "$(code_of /)" 200
eq "B1: /api/fleet still renders with an invalid project" "$(code_of /api/fleet)" 200
for u in bad-session bad-long bad-control bad-type; do
  c="$(card_of "$page_bad" "$u")"
  has "B1: $u renders the invalid marker attribute" "$(open_of "$c")" 'data-supervisor="invalid"'
  has "B1: $u says 'supervisor data invalid'" "$c" "supervisor data invalid"
done
for leak in LEAKMARK1 LEAKLONG LEAKMARK2 LEAKMARK3 LEAKMARK4 AAAAAAAAAA EXPLODING; do
  hasnt "B1: invalid block value $leak never reaches the page (no partial data)" "$page_bad" "$leak"
done
c="$(card_of "$page_bad" bad-acct)"
has "B2: an invalid account (id_hint > 8) shows 'account data invalid'" "$c" "account data invalid"
has "B2: ...login state attribute is invalid" "$(open_of "$c")" 'data-login-state="invalid"'
has "B2: ...while the valid supervisor part still renders" "$c" "fine-reason-ok"
hasnt "B2: ...and the account label does not leak" "$page_bad" "LEAKLABEL"
hasnt "B2: ...nor the id_hint" "$page_bad" "LEAKHINT"
c="$(card_of "$page_bad" good)"
has "B1: a valid sibling in the same projection renders normally" "$c" "still-fine"
hasnt "B1: ...and is not marked invalid" "$c" 'data-supervisor="invalid"'

# C4 stale greying
page_old="$(get /p/acme-supold)"
has "C4: a stale projection keeps the existing 'stale since' banner" "$page_old" "stale since"
has "C4: its supervised card is greyed via class 'sup-card sup-stale'" "$(open_of "$(card_of "$page_old" sup-old)")" 'class="sup-card sup-stale"'
has "C4: stale card still shows its data" "$(card_of "$page_old" sup-old)" "old news"
hasnt "C4: a fresh card is not marked sup-stale" "$o_run" "sup-stale"


# =========================================================================
# S2a v2 — R5 hint length, R7 reader whitelists, relative-hint units, fleet-count rules, null session id
# =========================================================================
c="$(card_of "$page_bad" bad-hint5)"
has "R5: an id_hint of 5 characters is invalid in the reader ('account data invalid')" "$c" "account data invalid"
hasnt "R5: ...and the account label does not leak" "$page_bad" "LEAKFIVE"
c="$(card_of "$page_bad" ok-hint4)"
has "R5: an id_hint of 4 characters is accepted" "$c" "hint4-label"
has "R5: ...and shown" "$c" "ab12"
has "R5: ...with its login state attribute" "$(open_of "$c")" 'data-login-state="ok"'
for u in bad-ctl-verb bad-ctl-extra bad-ctl-outcome; do
  c="$(card_of "$page_bad" "$u")"
  has "R7: reader whitelist: $u => the supervisor block is invalid" "$(open_of "$c")" 'data-supervisor="invalid"'
done
for leak in LEAKCTLV LEAKCTLX LEAKCTLO LEAKCALLER; do hasnt "R7: reader whitelist: $leak never reaches the page" "$page_bad" "$leak"; done
c="$(card_of "$page_bad" bad-acct-state)"
has "R7: reader whitelist: an account state outside the enum => 'account data invalid'" "$c" "account data invalid"
has "R7: ...while the valid supervisor part still renders" "$c" "acct_state_ok"
hasnt "R7: ...and the account label does not leak" "$page_bad" "LEAKSTATE"

# relative expiry hints: regenerate with a fresh clock right before reading
"$PY" "$WORK/supfix.py" "$DROOT" rel
page_rel="$(get /p/acme-suprel)"
eq "R7: GET /p/acme-suprel is 200" "$(code_of /p/acme-suprel)" 200
hint_of() { printf '%s' "$1" | "$PY" -I -c 'import re,sys;print(";".join(re.findall(r"in \d+ (?:d|h|min)\b|expired \d+ (?:d|h|min) ago",sys.stdin.read())))'; }
while IFS='|' read -r who want; do
  eq "R7: relative hint of $who is exactly '$want'" "$(hint_of "$(card_of "$page_rel" "rel-$who")")" "$want"
done <<'LIST'
d1|in 2 d
d2|in 1 d
h1|in 23 h
h2|in 1 h
m1|in 5 min
m2|in 59 min
z1|in 0 min
p0|expired 0 min ago
pm|expired 5 min ago
ph|expired 1 h ago
pd|expired 3 d ago
pd2|expired 1 d ago
n1|
LIST

# fleet-count rules
fleet_html="$(get /)"
row_cnt="$(row_of "$fleet_html" acme-supcnt)"
has "R7: fleet: absent counts as login-attention; an invalid block counts as supervised only" "$row_cnt" 'data-supervised="3"'
has "R7: fleet: an invalid block is never braked (only cnt-brk is)" "$row_cnt" 'data-braked="1"'
has "R7: fleet: login-attention counts absent but not the invalid block's expired account, nor an ok one" "$row_cnt" 'data-login-attention="1"'

# null session id
c_brk="$(card_of "$page_sup" sup-brk)"
has "cosmetic: a null session id renders as an em dash" "$c_brk" "—"
hasnt "cosmetic: ...never as <code>null</code>" "$c_brk" "<code>null</code>"

eq "POST / is a 405" "$(code_of / -X POST)" 405
eq "POST /api/fleet is a 405" "$(code_of /api/fleet -X POST)" 405

# =========================================================================
# E — theming: tokens, cookie-selected class, no JS (CONTRACT-visibility.md SS19 "Theming",
#     docs/decisions/0008-dashboard.md SSG; PO amendment 2026-09-09)
# =========================================================================
get_cookie() { curl_ok && "$CURL" -sS --max-time 2 -b "aib_theme=$2" "http://127.0.0.1:$DASH_PORT$1"; }

css="$( [ -n "$PY" ] && printf '%s' "$html_fleet" | "$PY" -c '
import re, sys
m = re.search(r"<style>(.*?)</style>", sys.stdin.read(), re.S)
print(m.group(1) if m else "")
' 2>/dev/null || true)"

if [ -n "$PY" ]; then
  color_leaks="$(printf '%s' "$css" | "$PY" -c '
import re, sys
css = sys.stdin.read()
allowed = {":root", "body.light", "body.dark", "body.c64"}
leaks = []
for m in re.finditer(r"([^{}]+)\{([^{}]*)\}", css):
    sel = m.group(1).strip()
    if sel in allowed:
        continue
    if re.search(r"#[0-9a-fA-F]{3,8}\b|rgba?\(", m.group(2)):
        leaks.append(sel)
print(len(leaks))
' 2>/dev/null || printf 'na')"
  if [ "$color_leaks" = na ]; then
    no "every colour literal is confined to :root{}/body.light{}/body.dark{}/body.c64{} (could not parse served CSS)"
  else
    eq "every colour literal is confined to :root{}/body.light{}/body.dark{}/body.c64{}" "$color_leaks" 0
  fi
  "$PY" - "$css" <<'PYEOF'
import re, sys
css = sys.argv[1]
blocks = {}
for match in re.finditer(r"([^{}]+)\{([^{}]*)\}", css):
    blocks.setdefault(match[1].strip(), []).append(match[2])
for selector in [':root', 'body.light', 'body.dark', 'body.c64']:
    assert len(blocks.get(selector, [])) == 1, selector
for token in ['bg','bg2','titb','fg','dim','ink','coral','amber','green','line']:
    for theme in ['dark', 'light']:
        assert re.search(r'--'+theme+'-'+token+r'\s*:', blocks[':root'][0]), (theme, token)
        assert re.search(r'--'+token+r'\s*:\s*var\(--'+theme+'-'+token+r'\)', blocks['body.'+theme][0]), (theme, token)
PYEOF
  eq "four theme token blocks retain explicit dark/light alias overrides" "$?" 0
  c64_upper="$(printf '%s' "$css" | "$PY" -c '
import re, sys
css = sys.stdin.read()
m = re.search(r"body\.c64\s*\{([^{}]*)\}", css)
print("yes" if m and re.search(r"text-transform\s*:\s*uppercase", m.group(1)) else "no")
' 2>/dev/null || printf 'na')"
  eq "body.c64{} contains text-transform:uppercase" "$c64_upper" yes
else
  skip "colour-literal confinement + body.c64 uppercase (python3 not present)"
fi
has ":root declares the pinned dark-default token names" "$css" "--bg"
has "a prefers-color-scheme: light media block exists" "$css" "prefers-color-scheme: light"

theme_light_headers="$(head_of "/?theme=light")"
has "?theme=light sets Set-Cookie: aib_theme=light" "$theme_light_headers" "Set-Cookie: aib_theme=light"
theme_light_body="$(get "/?theme=light")"
has '?theme=light renders <body class="light">' "$theme_light_body" 'body class="light"'

cookie_only_body="$(get_cookie / light)"
has 'aib_theme=light cookie alone renders <body class="light">' "$cookie_only_body" 'body class="light"'

bogus_headers="$(head_of "/?theme=bogus")"
hasnt "?theme=bogus never sets a Set-Cookie" "$bogus_headers" "Set-Cookie"
bogus_body="$(get "/?theme=bogus")"
hasnt '?theme=bogus never renders an explicit body class (falls back to auto)' "$bogus_body" "<body class="

theme_links="$(get /p/acme)"
has "the header carries a path-preserving ?theme=dark link" "$theme_links" "?theme=dark"
has "the header carries a path-preserving ?theme=light link" "$theme_links" "?theme=light"
has "the header carries a path-preserving ?theme=c64 link" "$theme_links" "?theme=c64"

if [ -n "$PY" ] && [ -n "$DASH_PORT" ]; then
  "$PY" - "$DASH_PORT" "$DROOT" <<'PYEOF'
import http.client, json, os, socket, sys, time
from pathlib import Path
port, root = int(sys.argv[1]), Path(sys.argv[2])
def request(path, method='GET', headers=None):
    client = http.client.HTTPConnection('127.0.0.1', port, timeout=2)
    client.request(method, path, headers=headers or {})
    response = client.getresponse(); data = response.read()
    result = response.status, dict(response.getheaders()), data
    client.close(); return result
original = (root/'acme.json').read_bytes()
for method in ['POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS', 'TRACE', 'CONNECT']:
    status, headers, body = request('/api/project/acme', method)
    assert status == 405 and headers['Allow'] == 'GET, HEAD', method
assert (root/'acme.json').read_bytes() == original
status, headers, body = request('/api/project/acme', 'HEAD')
assert status == 200 and body == b''
assert int(headers['Content-Length']) == len(request('/api/project/acme')[2])
assert headers['Cache-Control'] == 'no-store'
assert request('/api/project/evil')[0] == 404
os.mkfifo(root/'pipe.json')
assert request('/api/project/pipe')[0] == 404
assert 'pipe' not in request('/api/fleet')[2].decode()
(root/'broken.json').write_text('{')
(root/'array.json').write_text('[]')
for uid in ['broken', 'array']:
    assert request('/api/project/'+uid)[0] == 404
    rows = json.loads(request('/api/fleet')[2])['projects']
    row = next(p for p in rows if p['project_uid'] == uid)
    assert row['present'] is False and row['agents_by_state'] is None
for uid in ['duplicate', 'nonfinite', 'surrogate', 'bad-utf8']:
    p = json.loads(original); p['project_uid'] = uid
    if uid == 'nonfinite':
        p['extra'] = float('nan')
    if uid == 'surrogate':
        p['agents']['acme-core']['message'] = '\ud800'
    raw = json.dumps(p, separators=(',', ':')).encode()
    if uid == 'duplicate':
        raw = raw.replace(b'"schema":2', b'"schema":2,"schema":2', 1)
    if uid == 'bad-utf8':
        raw = raw.replace(b'"schema":2', b'"extra":"\xff","schema":2', 1)
    (root/(uid+'.json')).write_bytes(raw)
    assert request('/api/project/'+uid)[0] == 404, uid
    row = next(p for p in json.loads(request('/api/fleet')[2])['projects'] if p['project_uid'] == uid)
    assert row['present'] is False and row['agents_by_state'] is None, uid
p = json.loads(original); p['project_uid']='other'
(root/'mismatch.json').write_text(json.dumps(p))
assert request('/api/project/mismatch')[0] == 404
p = json.loads(original); p['stream']['last_seq']=987
(root/'acme.new').write_text(json.dumps(p)); os.replace(root/'acme.new', root/'acme.json')
assert json.loads(request('/api/project/acme')[2])['stream']['last_seq'] == 987
(root/'acme.json').write_bytes(original)
status, headers, body = request('/p/acme?theme=light')
assert 'SameSite=Strict' in headers['Set-Cookie'] and 'Path=/' in headers['Set-Cookie']
assert b'href="/p/acme?theme=c64"' in body
assert b'<body class="dark">' in request('/p/acme?theme=dark', headers={'Cookie':'aib_theme=light'})[2]
assert b'<body class=' not in request('/p/acme?theme=bogus', headers={'Cookie':'aib_theme=light'})[2]
assert b'<body class=' not in request('/p/acme?theme=auto')[2]
assert 'Set-Cookie' not in request('/p/acme?theme=%22%3E%3Cscript%3E')[1]
assert b'<script>' not in request('/p/acme?theme=%22%3E%3Cscript%3E')[2]
with socket.create_connection(('127.0.0.1', port)) as slow:
    slow.sendall(b'GET / HTTP/1.1\r\nHost: localhost\r\n')
    started=time.monotonic(); assert request('/api/fleet')[0] == 200
    assert time.monotonic()-started < 2
PYEOF
  eq "HTTP boundary corpus: methods, HEAD, nofollow/FIFO, bad files, replacement, cookies and slow clients" "$?" 0
fi

if [ -n "$PY" ]; then
  "$PY" - "$SRC_ROOT" "$DROOT" <<'PYEOF'
import json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from dashboard.reader import ProjectionRoot, instant
from dashboard.render import fleet_page, freshness, project_page
import runpy
configuration = runpy.run_path(str(Path(sys.argv[1])/'bin/dashboard'))['configuration']
root = Path(sys.argv[2])
p = json.loads((root/'acme.json').read_text())
reader = ProjectionRoot(root)
at = instant(p['generated_at'])
for age, stale in [(59.9, False), (60, False), (60.1, True), (-1, False)]:
    row = next(row for row in reader.fleet(at + age, 60)['projects'] if row['project_uid'] == 'acme')
    assert row['stale'] is stale, ('fleet', age, row['stale'])
    rendered = project_page(p, at + age, 60, 'auto')
    assert ('stale since ' in rendered) is stale, ('project', age)
for age, human in [(89, '89 s'), (90, '1 min'), (5399, '89 min'), (5400, '1 h 30 min'),
                   (172799, '47 h 59 min'), (172800, '2 d 0 h')]:
    fleet = reader.fleet(at + age, 60)
    row = next(row for row in fleet['projects'] if row['project_uid'] == 'acme')
    assert row['age_seconds'] == age, row
    for rendered in [fleet_page(fleet, 'auto', 60), project_page(p, at + age, 60, 'auto')]:
        assert 'stale since '+human+'</span>' in rendered, (age, human)
        assert p['generated_at'] in rendered, age
    assert 'fresh · '+human+' old</span>' in freshness(age, False), age
    assert 'clock ahead by '+human+'</span>' in freshness(-age, False), age
assert freshness(None, False) == 'unknown'
assert configuration({'AIB_DASHBOARD_BIND':'0.0.0.0'})[0] == ('0.0.0.0', 3030)
for key, values in [('AIB_DASHBOARD_BIND', ['', 'localhost', '::1']),
                    ('AIB_DASHBOARD_PORT', ['-1', '65536', 'bad']),
                    ('AIB_PROJECTION_STALE_SECONDS', ['-1', 'bad', '1000000000'])]:
    for value in values:
        try:
            configuration(dict({'AIB_DASHBOARD_BIND':'127.0.0.1'}, **{key:value}))
        except ValueError:
            pass
        else:
            raise AssertionError((key, value))
assert reader.read('../acme') == (None, 'invalid_uid')
assert ProjectionRoot(root/'absent').fleet(at, 60)['root_status'] == 'unknown'
(root/'linked-root').symlink_to(root, target_is_directory=True)
assert ProjectionRoot(root/'linked-root').fleet(at, 60)['root_status'] == 'unknown'
PYEOF
  eq "freshness keeps exact thresholds and compact age boundaries; bind remains explicit" "$?" 0
fi

kill "$DASH_PID" 2>/dev/null; wait "$DASH_PID" 2>/dev/null; DASH_PID=""

# Bind refusal: 0.0.0.0 without an explicit AIB_DASHBOARD_BIND=0.0.0.0 must refuse to start.
if [ -x "$DASHBOARD_BIN" ]; then
  env -u AIB_DASHBOARD_BIND AIB_DASHBOARD_PORT=0 AIB_PROJECTION_ROOT="$DROOT" \
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
