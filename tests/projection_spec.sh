#!/usr/bin/env bash
# ai-bobnet — Visibility V-1: RED spec for the read-only projector, `bin/project`.
#
# WHAT THIS PINS
#   docs/CONTRACT-visibility.md is the normative text; docs/decisions/0007-visibility-projection.md
#   is the placement/mechanism reasoning behind it. This file pins the design note's decisions
#   (standup/_design_visibility-v1.md v2, P-A through P-L, revised against the advisor consult
#   standup/_advisor_visibility-v1.md) against the concrete interfaces the contract names:
#
#     bin/project <project_uid> | --all [--stdout]
#
#     Env (unit-environment-only, never request/registry-supplied — CONTRACT-visibility.md
#     Interfaces summary):
#       AIB_PROJECTION_ROOT          projection output root, default /var/lib/aib/projection
#       AIB_PROJECTION_DEAD_MINUTES  presumed-dead threshold (SS8), default 15
#       AIB_BROKER_CAPACITY          mirrored broker capacity, capacity.limit only (SS10), default 12
#       AIB_EVENT_ROOT                already unit-env (ADR-0005); stream + attempts/.live source
#       TZ                            must equal the fleet's DEV_TEAM_TZ (SS9)
#
#     Library: aib_attempts_fold <events_path>  (SS12 — new, shared by bin/attempts and bin/project)
#
#   Fixtures below cover: a schema-4 registry with several agents across several projects;
#   fixture streams (ok / corrupt / absent / anchor lag / anchor ahead / torn tail); heartbeat
#   logs including dateless lines (last-line and non-last-line), an unparsable line, every
#   `needs:` kind plus an unrecognized one and a malformed one, hostile message text, an
#   unregistered log, and a log filename with control characters; a `.live` capacity file
#   (valid / absent / corrupt) alongside unreadable lease-file canaries; a `beats.mjs`
#   differential (node, skip-marked when unavailable or the sibling dashboard checkout is not
#   found — see "Cross-repo differential" below); the non-consumption grep; the fold-time
#   budget at 10,000 records; and the "handler never references the projection" pin.
#
#   Every assertion below states the POSITIVE outcome it expects once `bin/project` and
#   `aib_attempts_fold` exist. On THIS unbuilt tree, `bin/project` does not exist and
#   `aib_attempts_fold` is undefined, so the great majority of functional assertions FAIL —
#   that is the expected, correct state of a RED spec. A handful of invariant-style checks
#   (the non-consumption grep, "the handler never references the projection", and the current,
#   already-built `bin/attempts` baseline) are expected to PASS already and must keep passing
#   once the projector exists — they are the floor this contract must never regress.
#
#   Cross-repo differential: `claude-bobnet/dashboard/server/utils/beats.mjs` lives in a sibling
#   repository, not in this (public, white-label) one. This spec never hardcodes a host path to
#   it: `AIB_BEATS_MJS_PATH` names it explicitly, or a relative sibling-checkout guess
#   (`../claude-bobnet/dashboard/...`) is tried, and the differential is skip-marked — not
#   faked — when neither resolves to a readable file, the same "skipped, not faked" discipline
#   `docs/CONFINEMENT.md` already uses for a Landlock-less host's `cc` step.
set -uo pipefail

SRC_ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
REPO_ROOT="$SRC_ROOT"
PROJECT_BIN="$SRC_ROOT/bin/project"
FIXDIR="$SRC_ROOT/tests/fixtures"
JGET="$FIXDIR/projection_jget.py"
BULKGEN="$FIXDIR/projection_bulk_stream.py"
# shellcheck source=lib/aibobnet.sh
. "$REPO_ROOT/lib/aibobnet.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-projection.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PY="$(command -v python3 2>/dev/null || true)"
NODE="$(command -v node 2>/dev/null || true)"

pass=0; fail=0; skipped=0
ok()   { pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
no()   { fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; }
eq()   { [ "$2" = "$3" ] && ok "$1" || no "$1 (got '$2' want '$3')"; }
has()  { case "$2" in *"$3"*) ok "$1";; *) no "$1 (missing '$3' in: $2)";; esac; }
hasnt(){ case "$2" in *"$3"*) no "$1 (unexpected '$3' in: $2)";; *) ok "$1";; esac; }
skip() { skipped=$((skipped+1)); printf 'skip - %s\n' "$1"; }

jget() { # jget <jsonfile> <dotted-path>
  [ -n "$PY" ] || { printf '__NO_PYTHON__'; return 0; }
  "$PY" "$JGET" "$1" "$2" 2>/dev/null
}

# --- fixtures: registry --------------------------------------------------------
for p in acme empty broken bulk hbfixture; do mkdir -p "$WORK/$p/standup"; done
REG="$WORK/registry.json"
cat > "$REG" <<EOF
{
  "schema_version": 4,
  "providers": { "codex": { "adapter": "/bin/true", "cap_sandbox": "workspace-write",
    "cap_tier": "t3", "cap_effort": "high", "cap_timeout": "900" } },
  "projects": {
    "acme":      { "home": "$WORK/acme",      "standup_dir": "$WORK/acme/standup",      "mux_session": "acme",      "provider": "codex", "model": "m", "effort": "low" },
    "empty":     { "home": "$WORK/empty",     "standup_dir": "$WORK/empty/standup",     "mux_session": "empty",     "provider": "codex", "model": "m", "effort": "low" },
    "broken":    { "home": "$WORK/broken",    "standup_dir": "$WORK/broken/standup",    "mux_session": "broken",    "provider": "codex", "model": "m", "effort": "low" },
    "bulk":      { "home": "$WORK/bulk",      "standup_dir": "$WORK/bulk/standup",      "mux_session": "bulk",      "provider": "codex", "model": "m", "effort": "low" },
    "hbfixture": { "home": "$WORK/hbfixture", "standup_dir": "$WORK/hbfixture/standup", "mux_session": "hbfixture", "provider": "codex", "model": "m", "effort": "low" }
  },
  "agents": {
    "acme-core":      { "project": "acme",      "profile": "engine-dev", "clearance": "t2" },
    "acme-second":    { "project": "acme",      "profile": "engine-dev", "clearance": "t2" },
    "acme-third":     { "project": "acme",      "profile": "engine-dev", "clearance": "t2" },
    "empty-core":     { "project": "empty",     "profile": "engine-dev", "clearance": "t2" },
    "broken-core":    { "project": "broken",    "profile": "engine-dev", "clearance": "t2" },
    "bulk-core":      { "project": "bulk",      "profile": "engine-dev", "clearance": "t2" },
    "hbfixture-core": { "project": "hbfixture", "profile": "engine-dev", "clearance": "t2" }
  }
}
EOF

EVENTROOT="$WORK/events-root"
PROJROOT="$WORK/projection-root"
mkdir -p "$EVENTROOT/attempts"

stream_paths() { EVENTS="$EVENTROOT/$1/main.events"; LOCK="$EVENTS.lock"; }
reset_stream() { rm -rf "$EVENTROOT/$1"; mkdir -p "$EVENTROOT/$1"; stream_paths "$1"; }

commit_decided() { # commit_decided <uid> <agent> <pid> [occurred_at]
  local uid="$1" agent="$2" pid="$3" occurred="${4-}" env payload
  env="project_uid=$uid"$'\n'"actor_type=service"$'\n'"actor_id=aib-broker"$'\n'"agent_uid=$agent"
  [ -z "$occurred" ] || env="${env}"$'\n'"occurred_at=$occurred"
  payload="$(aib_event_compose_decided_payload "decision=allow"$'\n'"code=0"$'\n'"reasons="$'\n'"pid=$pid")"
  aib_event_commit "$EVENTS" "$LOCK" attempt.decided "$env" "$payload"
  LAST_ID="$AIB_EVENT_COMMIT_EVENT_ID"
}
commit_ended() { # commit_ended <uid> <decided_id> <exit_class> [exit_code] [signal] [occurred_at]
  local uid="$1" decided="$2" class="$3" code="${4-}" sig="${5-}" occurred="${6-}" env kv payload
  env="project_uid=$uid"$'\n'"actor_type=service"$'\n'"actor_id=aib-broker"
  [ -z "$occurred" ] || env="${env}"$'\n'"occurred_at=$occurred"
  kv="exit_class=$class"$'\n'"stage=provider"
  [ -z "$code" ] || kv="${kv}"$'\n'"exit_code=$code"
  [ -z "$sig" ]  || kv="${kv}"$'\n'"signal=$sig"
  payload="$(aib_event_compose_ended_payload "$kv")"
  aib_event_commit "$EVENTS" "$LOCK" attempt.ended "$env" "$payload" "$decided"
}

hb() { # hb <uid> <agent> <date-or-empty> <time> <status> <msg>
  local f="$WORK/$1/standup/$2.log"
  if [ -n "$3" ]; then printf '%s %s | %s | %s\n' "$3" "$4" "$5" "$6" >> "$f"
  else printf '%s | %s | %s\n' "$4" "$5" "$6" >> "$f"; fi
}

DEAD_MIN=15
CAP=12
TZ_OVERRIDE=Europe/Berlin
run_project() { # run_project <args...>
  RUN_OUT=""; RUN_ERR=""; RUN_RC=0
  RUN_OUT="$(AIBOBNET_REGISTRY="$REG" AIB_PROJECTION_ROOT="$PROJROOT" AIB_EVENT_ROOT="$EVENTROOT" \
    AIB_PROJECTION_DEAD_MINUTES="$DEAD_MIN" AIB_BROKER_CAPACITY="$CAP" TZ="$TZ_OVERRIDE" \
    "$PROJECT_BIN" "$@" 2>"$WORK/project.err")"; RUN_RC=$?
  RUN_ERR="$(cat "$WORK/project.err" 2>/dev/null)"
}

# =========================================================================
# A — existence
# =========================================================================
eq "bin/project exists and is executable" "$([ -x "$PROJECT_BIN" ] && printf yes || printf no)" yes

# =========================================================================
# B — placement, mode, atomic publish (CONTRACT-visibility.md SS14, ADR-0007 SSA/SSB)
# =========================================================================
hb acme acme-core "" "09:00" busy "warming up"
run_project acme
OUT_ACME="$PROJROOT/acme.json"
eq "run against a fresh fixture exits 0" "$RUN_RC" 0
eq "publishes <root>/<project_uid>.json" "$([ -f "$OUT_ACME" ] && printf yes || printf no)" yes
if [ -f "$OUT_ACME" ]; then
  dmode="$(stat -c %a "$PROJROOT" 2>/dev/null || stat -f %Lp "$PROJROOT" 2>/dev/null)"
  fmode="$(stat -c %a "$OUT_ACME" 2>/dev/null || stat -f %Lp "$OUT_ACME" 2>/dev/null)"
  eq "projection directory mode is 0750" "$dmode" 750
  eq "projection file mode is 0640" "$fmode" 640
else
  no "projection directory mode is 0750 (no file to check)"
  no "projection file mode is 0640 (no file to check)"
fi

# A pre-planted symlink at a plausible naive FIXED temp name must be irrelevant:
# mktemp uses a random suffix, so nothing fixed is ever opened for writing.
CANARY="$WORK/canary-fixed-temp"
ln -sf "$CANARY" "$PROJROOT/acme.json.tmp" 2>/dev/null || true
run_project acme
eq "a pre-planted fixed-name symlink is never written through" "$([ -e "$CANARY" ] && printf yes || printf no)" no
eq "publish still succeeds despite the planted symlink" "$RUN_RC" 0

# Never write anywhere under the project home/standup_dir.
before_snap="$(find "$WORK/acme" -type f | sort)"
run_project acme
after_snap="$(find "$WORK/acme" -type f | sort)"
eq "the projector never writes under the project home" "$after_snap" "$before_snap"
eq "the projector never creates the standup_dir symlink itself (provisioning-owned)" \
  "$([ -e "$WORK/acme/standup/_projection.json" ] && printf yes || printf no)" no

# =========================================================================
# C — capacity from the attested .live file (CONTRACT-visibility.md SS10)
# =========================================================================
LIVE="$EVENTROOT/attempts/.live"
printf '3' > "$LIVE"; touch -d '2026-09-07 14:00:00' "$LIVE" 2>/dev/null || touch "$LIVE"
run_project acme
eq "capacity.live reads the attested .live integer" "$(jget "$OUT_ACME" capacity.live)" 3
as_of_val="$(jget "$OUT_ACME" capacity.as_of)"
as_of_cnt="$(printf '%s' "$as_of_val" | grep -Ec '^[0-9]{4}-[0-9]{2}-[0-9]{2}T.*(\+|-)[0-9]{2}:[0-9]{2}$' 2>/dev/null)"; as_of_cnt="${as_of_cnt:-0}"
eq "capacity.as_of is the .live file's own mtime, offset-bearing" "$as_of_cnt" 1
eq "capacity.limit reads AIB_BROKER_CAPACITY from the projector's own env" "$(jget "$OUT_ACME" capacity.limit)" 12
CAP=7; run_project acme; CAP=12
eq "capacity.limit follows a different AIB_BROKER_CAPACITY" "$(jget "$OUT_ACME" capacity.limit)" 7

rm -f "$LIVE"
run_project acme
eq "capacity.live is null when .live is absent" "$(jget "$OUT_ACME" capacity.live)" null
eq "capacity.as_of is null when .live is absent" "$(jget "$OUT_ACME" capacity.as_of)" null

printf 'not-a-number' > "$LIVE"
run_project acme
eq "capacity.live is null on corrupt .live content, never an incident" "$(jget "$OUT_ACME" capacity.live)" null
eq "a corrupt .live still lets the run succeed" "$RUN_RC" 0

# A canary lease file the projector must never open, even when unreadable.
printf '3' > "$LIVE"
CANARY_LEASE="$EVENTROOT/attempts/acme-core.0"
: > "$CANARY_LEASE"; chmod 000 "$CANARY_LEASE" 2>/dev/null || true
run_project acme
eq "an unreadable lease file under attempts/ does not block the run" "$RUN_RC" 0
eq "the canary lease file is left exactly as planted (never opened)" \
  "$(stat -c %a "$CANARY_LEASE" 2>/dev/null || stat -f %Lp "$CANARY_LEASE" 2>/dev/null)" 0
chmod 644 "$CANARY_LEASE" 2>/dev/null || true
rm -f "$CANARY_LEASE"

# =========================================================================
# D — agent set is the registry, not a directory listing (CONTRACT-visibility.md SS11)
# =========================================================================
hb acme acme-second "" "09:05" idle "watching"
# acme-third: registered, no heartbeat log at all.
printf '' > "$WORK/acme/standup/acme-ghost.log"        # unregistered uid
CTRL_NAME=$'acme-weird\x01name.log'
printf '' > "$WORK/acme/standup/$CTRL_NAME" 2>/dev/null || true
run_project acme
eq "acme-core is a projected agent key" "$(jget "$OUT_ACME" 'agents.acme-core.state')" busy
eq "acme-second is a projected agent key" "$(jget "$OUT_ACME" 'agents.acme-second.state')" idle
eq "a registered agent with no log projects as unknown" "$(jget "$OUT_ACME" 'agents.acme-third.state')" unknown
eq "a registered agent with no log has since=null" "$(jget "$OUT_ACME" 'agents.acme-third.since')" null
eq "a registered agent with no log is stale" "$(jget "$OUT_ACME" 'agents.acme-third.stale')" true
eq "an unregistered log is never a projected agent key" "$(jget "$OUT_ACME" 'agents.acme-ghost')" __MISSING__
eq "a control-character log filename is never a projected agent key" \
  "$(jget "$OUT_ACME" "agents.$CTRL_NAME")" __MISSING__
gte_one="$(jget "$OUT_ACME" anomalies.unregistered_logs)"
case "$gte_one" in 0|__MISSING__|__PARSE_ERROR__) no "unregistered/control-char logs are counted as anomalies (got '$gte_one')";; *) ok "unregistered/control-char logs are counted as anomalies";; esac

# =========================================================================
# E — heartbeat parsing reproduces beats.mjs exactly (CONTRACT-visibility.md SS11)
# =========================================================================
hb hbfixture hbfixture-core "2026-09-01" "10:00" busy "first, not last"
hb hbfixture hbfixture-core "" "10:05" busy "dateless, NOT the last line"
touch -d '2026-09-01 10:10:00' "$WORK/hbfixture/standup/hbfixture-core.log" 2>/dev/null || true
run_project hbfixture
eq "an old dateless LAST line remains mtime-anchored, as in beats.mjs" "$(jget "$PROJROOT/hbfixture.json" 'agents.hbfixture-core.stale')" false

# Now make the dateless line the file's own last line — it anchors to mtime.
mv "$WORK/hbfixture/standup/hbfixture-core.log" "$WORK/hbfixture/standup/hbfixture-core.log.bak"
hb hbfixture hbfixture-core "2026-09-01" "10:00" busy "first"
hb hbfixture hbfixture-core "" "10:05" busy "dateless, IS the last line"
touch "$WORK/hbfixture/standup/hbfixture-core.log"
run_project hbfixture
eq "a dateless LAST line anchors to the file mtime and is not stale" \
  "$(jget "$PROJROOT/hbfixture.json" 'agents.hbfixture-core.stale')" false

mv "$WORK/hbfixture/standup/hbfixture-core.log.bak" "$WORK/hbfixture/standup/hbfixture-core.log" 2>/dev/null || true
printf 'this is not a heartbeat line at all\n' >> "$WORK/hbfixture/standup/hbfixture-core.log"
run_project hbfixture
eq "an unparsable line is conservatively stale" "$(jget "$PROJROOT/hbfixture.json" 'agents.hbfixture-core.stale')" true
gte_one="$(jget "$PROJROOT/hbfixture.json" anomalies.unparsable_lines)"
case "$gte_one" in 0|__MISSING__|__PARSE_ERROR__) no "an unparsable line is counted in anomalies.unparsable_lines (got '$gte_one')";; *) ok "an unparsable line is counted in anomalies.unparsable_lines";; esac

# Cross-repo differential against claude-bobnet/dashboard/server/utils/beats.mjs.
BEATS_MJS="${AIB_BEATS_MJS_PATH:-$SRC_ROOT/../claude-bobnet/dashboard/server/utils/beats.mjs}"
if [ -z "$NODE" ]; then
  skip "beats.mjs differential (node not present)"
elif [ ! -r "$BEATS_MJS" ]; then
  skip "beats.mjs differential (sibling checkout not found; set AIB_BEATS_MJS_PATH)"
else
  BEATS_JSON_PATH="$("$PY" -c "import json,sys; print(json.dumps(sys.argv[1]))" "$BEATS_MJS")"
  cat > "$WORK/beats_diff.mjs" <<NODEEOF
import { parseTail } from $BEATS_JSON_PATH;
import { readFileSync, statSync } from 'node:fs';
const path = process.argv[2];
const lines = readFileSync(path, 'utf8').split('\n').filter(l => l.length);
const mtimeMs = statSync(path).mtimeMs;
const parsed = parseTail(lines, mtimeMs, { tz: 'Europe/Berlin' });
console.log(parsed.map(p => p.stale ? '1' : '0').join(','));
NODEEOF
  diff_log="$WORK/hbfixture/standup/hbfixture-core.log"
  node_stale="$("$NODE" "$WORK/beats_diff.mjs" "$diff_log" 2>/dev/null)"
  if [ -z "$node_stale" ]; then
    skip "beats.mjs differential (node run failed to produce output)"
  else
    # agents[uid].stale reflects only the file's own LAST line (CONTRACT-visibility.md
    # SS11), so the differential compares against beats.mjs's own verdict for that
    # same last line.
    final_node_stale="${node_stale##*,}"
    want="false"; [ "$final_node_stale" = 1 ] && want="true"
    eq "bin/project's current-line staleness agrees with beats.mjs's own rule" \
      "$(jget "$PROJROOT/hbfixture.json" 'agents.hbfixture-core.stale')" "$want"
  fi
fi

# =========================================================================
# F — needs: vocabulary (CONTRACT-visibility.md SS7)
# =========================================================================
needs_case() { # needs_case <label> <msg> <expect_kind> <expect_reason_contains>
  hb acme acme-core "" "11:00" blocked "$2"
  run_project acme
  eq "needs: $1 — kind" "$(jget "$OUT_ACME" 'attention[kind='"$3"'].kind')" "$3"
  eq "needs: $1 — agent" "$(jget "$OUT_ACME" 'attention[kind='"$3"'].agent')" acme-core
  eq "needs: $1 — attested is false (agent-asserted)" "$(jget "$OUT_ACME" 'attention[kind='"$3"'].attested')" false
  has "needs: $1 — reason preserves the message" \
    "$(jget "$OUT_ACME" 'attention[kind='"$3"'].reason')" "$4"
}
needs_case "human"     "needs:human is this refactor worth the risk"        human    "worth the risk"
needs_case "t4"        "needs:t4 deploy to prod once reviewed"              t4       "deploy to prod"
needs_case "approval"  "needs:approval sign off on the schema bump"         approval "sign off"
needs_case "conflict"  "needs:conflict two PRs touch the same file"         conflict "two PRs"
needs_case "input"     "needs:input the staging DB password"                input    "staging DB password"
needs_case "other-explicit" "needs:other something not on the list"        other    "something not on the list"
needs_case "unrecognized-kind" "needs:banana do the thing"                 other    "needs:banana do the thing"
needs_case "malformed-no-space" "needs:justtext no space at all"           other    "needs:justtext no space at all"

hb acme acme-core "" "11:30" blocked "stuck, no ceremony used"
run_project acme
eq "a blocked line with no needs: prefix adds no attention item" \
  "$(jget "$OUT_ACME" 'attention[kind=other]')" __NOTFOUND__
eq "...but the agent still shows as blocked" "$(jget "$OUT_ACME" 'agents.acme-core.state')" blocked

hb acme acme-core "" "11:45" blocked 'needs:human said "quit" | also | a "pipe" \with\backslashes'
run_project acme
eq "hostile message text still parses as valid JSON" \
  "$([ -f "$OUT_ACME" ] && "$PY" -c "import json,sys; json.load(open(sys.argv[1])); print('yes')" "$OUT_ACME" 2>/dev/null || printf no)" yes
has "hostile message text is preserved in reason, escaped not interpreted" \
  "$(jget "$OUT_ACME" 'attention[kind=human].reason')" 'quit'

# =========================================================================
# G — broker-derived attention + the six stream-status variants
#     (CONTRACT-visibility.md SS8, SS18 "stream", ADR-0007)
# =========================================================================
# Reset acme-core to a known, current "busy" state before the stream-status
# fixtures below — SS F above deliberately left it on a blocked/needs: line.
hb acme acme-core "" "11:50" busy "back to work"

# ok
reset_stream acme
commit_decided acme acme-core "$$"
run_project acme
eq "stream.status ok" "$(jget "$OUT_ACME" stream.status)" ok
eq "stream.anchor.relationship absent (no anchor file, no anchor_mode used)" \
  "$(jget "$OUT_ACME" stream.anchor.relationship)" absent
eq "stream.torn_tail false on an intact stream" "$(jget "$OUT_ACME" stream.torn_tail)" false

# corrupt
reset_stream acme
commit_decided acme acme-core "$$"
printf '2 0 2 {}\n' >> "$EVENTS"
run_project acme
eq "stream.status corrupt" "$(jget "$OUT_ACME" stream.status)" corrupt
eq "corrupt stream still yields a stream_unhealthy attention item" \
  "$(jget "$OUT_ACME" 'attention[kind=stream_unhealthy].attested')" true
eq "a corrupt stream does not stop the agent-state facet from projecting" \
  "$(jget "$OUT_ACME" 'agents.acme-core.state')" busy

# absent
reset_stream empty
run_project empty
eq "stream.status absent when no stream file exists yet" "$(jget "$PROJROOT/empty.json" stream.status)" absent

# anchor lag
reset_stream acme
commit_decided acme acme-core "$$"; commit_decided acme acme-core "$$"
printf '1\n' > "${EVENTS}.high_water"
run_project acme
eq "stream.anchor.relationship lag" "$(jget "$OUT_ACME" stream.anchor.relationship)" lag

# anchor ahead
reset_stream acme
commit_decided acme acme-core "$$"
printf '99\n' > "${EVENTS}.high_water"
run_project acme
eq "stream.anchor.relationship ahead" "$(jget "$OUT_ACME" stream.anchor.relationship)" ahead
eq "an ahead anchor yields a stream_unhealthy attention item" \
  "$(jget "$OUT_ACME" 'attention[kind=stream_unhealthy].attested')" true

# torn tail
reset_stream acme
commit_decided acme acme-core "$$"
printf '2 999 999 {"uncommitted":true' >> "$EVENTS"
run_project acme
eq "stream.torn_tail true" "$(jget "$OUT_ACME" stream.torn_tail)" true
eq "a torn tail yields a stream_unhealthy attention item" \
  "$(jget "$OUT_ACME" 'attention[kind=stream_unhealthy].attested')" true

# presumed-dead: an old open decided(allow), no ended, no recent heartbeat for that agent.
reset_stream acme
: > "$WORK/acme/standup/acme-core.log"
commit_decided acme acme-core "$$" "2020-01-01T00:00:00+00:00"
dead_id="$LAST_ID"
run_project acme
eq "presumed_dead attention item is derived" \
  "$(jget "$OUT_ACME" 'attention[kind=presumed_dead].agent')" acme-core
eq "presumed_dead is attested (broker-derived, never agent text)" \
  "$(jget "$OUT_ACME" 'attention[kind=presumed_dead].attested')" true
has "presumed_dead reason names the attempt id" \
  "$(jget "$OUT_ACME" 'attention[kind=presumed_dead].reason')" "$dead_id"

# disagreement: heartbeat claims done/idle while the SAME attempt is still open.
reset_stream acme
commit_decided acme acme-core "$$"
hb acme acme-core "" "12:00" done "all finished here"
run_project acme
eq "disagreement attention item is derived" \
  "$(jget "$OUT_ACME" 'attention[kind=disagreement].agent')" acme-core
eq "disagreement is attested (broker-derived)" \
  "$(jget "$OUT_ACME" 'attention[kind=disagreement].attested')" true

# =========================================================================
# I — fold extraction: aib_attempts_fold (CONTRACT-visibility.md SS12)
# =========================================================================
eq "aib_attempts_fold is defined" "$(type -t aib_attempts_fold 2>/dev/null || printf undefined)" function

reset_stream acme
commit_decided acme acme-core "$$"; ok_id="$LAST_ID"; commit_ended acme "$ok_id" ok
commit_decided acme acme-core "$$"; open_id="$LAST_ID"
# pid must be genuinely alive (kill -0) for both fold readers to classify this
# attempt "open" rather than reader-side "presumed-dead" — the test's own PID
# ($$) is guaranteed alive for the duration of this script.

# Baseline: bin/attempts on this exact fixture — this already works today and
# MUST keep working byte-identically once it is refactored onto aib_attempts_fold.
STANDUP_FOR_ATTEMPTS="$WORK/acme/standup"
mkdir -p "$STANDUP_FOR_ATTEMPTS/events"
cp "$EVENTS" "$STANDUP_FOR_ATTEMPTS/events/main.events"
attempts_out="$(AIBOBNET_REGISTRY="$REG" "$SRC_ROOT/bin/attempts" acme-core 2>"$WORK/attempts.err")"; attempts_rc=$?
eq "baseline: bin/attempts still succeeds on this fixture pre-refactor" "$attempts_rc" 0
has "baseline: bin/attempts folds the ended attempt" "$attempts_out" "attempt_id:$ok_id | state:ok"
has "baseline: bin/attempts folds the open attempt" "$attempts_out" "attempt_id:$open_id | state:open"

fold_out=""
fold_rc=1
if declare -F aib_attempts_fold >/dev/null 2>&1; then
  aib_attempts_fold "$EVENTS" >"$WORK/fold.out" 2>"$WORK/fold.err"; fold_rc=$?
  fold_out="$(cat "$WORK/fold.out")"
fi
eq "aib_attempts_fold succeeds on the identical fixture" "$fold_rc" 0
has "aib_attempts_fold agrees with bin/attempts on the ended attempt" "${AIB_ATTEMPTS_FOLD_IDS:-}$fold_out" "$ok_id"
has "aib_attempts_fold agrees with bin/attempts on the open attempt" "${AIB_ATTEMPTS_FOLD_IDS:-}$fold_out" "$open_id"
eq "aib_attempts_fold reports the scan status rather than dying on corrupt" \
  "$([ -n "${AIB_ATTEMPTS_FOLD_STATUS:-}" ] && printf yes || printf no)" yes

# =========================================================================
# J — --all: per-project isolation and untouched-on-failure (CONTRACT-visibility.md SS13)
# =========================================================================
chmod 000 "$WORK/broken/standup" 2>/dev/null || true
run_project --all
eq "--all still publishes the healthy projects despite one broken project" \
  "$([ -f "$PROJROOT/acme.json" ] && [ -f "$PROJROOT/empty.json" ] && printf yes || printf no)" yes
eq "--all publishes bulk and hbfixture too" \
  "$([ -f "$PROJROOT/bulk.json" ] && [ -f "$PROJROOT/hbfixture.json" ] && printf yes || printf no)" yes

# Untouched-on-failure: a successful publish, then a forced publish failure —
# the previous file's content must not change even by one byte.
reset_stream acme
commit_decided acme acme-core "$$"
run_project acme
eq "baseline publish for the untouched-on-failure check succeeds" "$RUN_RC" 0
baseline_sum="$(cksum "$OUT_ACME" 2>/dev/null)"
chmod 0500 "$PROJROOT" 2>/dev/null || true
commit_decided acme acme-core "$$"
run_project acme
chmod 0750 "$PROJROOT" 2>/dev/null || true
eq "a publish that cannot write reports failure" "$([ "$RUN_RC" -ne 0 ] && printf yes || printf no)" yes
eq "the previous file is left byte-identical on a failed publish" "$(cksum "$OUT_ACME" 2>/dev/null)" "$baseline_sum"

# =========================================================================
# K — rebuild acceptance (CONTRACT-visibility.md SS17, docs/DOMAIN.md SS11(e))
# =========================================================================
reset_stream acme
commit_decided acme acme-core "$$"
run_project acme
first="$(cat "$OUT_ACME" 2>/dev/null | sed -E 's/"generated_at":"[^"]*"/"generated_at":"X"/')"
rm -f "$OUT_ACME"
run_project acme
second="$(cat "$OUT_ACME" 2>/dev/null | sed -E 's/"generated_at":"[^"]*"/"generated_at":"X"/')"
eq "a deleted projection rebuilds identical except generated_at" "$second" "$first"

# =========================================================================
# L — fold-time budget (CONTRACT-visibility.md SS16): 10,000 records under 2s
# =========================================================================
if [ -n "$PY" ]; then
  mkdir -p "$EVENTROOT/bulk"
  "$PY" "$BULKGEN" "$EVENTROOT/bulk/main.events" 10000 bulk bulk-core
  hb bulk bulk-core "" "09:00" busy "steady state"
  t0="$(date +%s.%N)"; run_project bulk; t1="$(date +%s.%N)"
  elapsed="$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f", b-a}')"
  eq "folding 10,000 records succeeds" "$RUN_RC" 0
  if [ "$RUN_RC" -eq 0 ]; then
    under_budget="$(awk -v e="$elapsed" 'BEGIN{print (e < 2.0) ? "yes" : "no"}')"
    eq "folding 10,000 records completes under the 2s budget (took ${elapsed}s)" "$under_budget" yes
  else
    no "folding 10,000 records completes under the 2s budget (run did not succeed, elapsed ${elapsed}s)"
  fi
else
  skip "fold-time budget (python3 not present to build the 10,000-record fixture)"
fi

# =========================================================================
# M — non-consumption clause + the prod rule is never a runtime gate
#     (CONTRACT-visibility.md SS3, SS5)
# =========================================================================
ALLOWLIST='^(docs/CONTRACT-visibility\.md|docs/decisions/0007-visibility-projection\.md|docs/CONFINEMENT\.md|docs/CONTRACT-execution-binding\.md|deploy/systemd/aib-projection\.(service|timer)|bin/project|tests/projection_spec\.sh|tests/fixtures/projection_jget\.py|tests/fixtures/projection_bulk_stream\.py)$'
hits="$(cd "$SRC_ROOT" && grep -rlE 'AIB_PROJECTION_ROOT|_projection\.json' --exclude-dir=.git . 2>/dev/null | sed 's#^\./##' | grep -vE "$ALLOWLIST" || true)"
eq "non-consumption: nothing outside bin/project + its own fixtures + docs references the projection" "$hits" ""

hasnt "the broker handler never references the projection root" \
  "$(cat "$SRC_ROOT/bin/aib-broker-handler")" "AIB_PROJECTION_ROOT"
hasnt "the broker handler never references the projection filename" \
  "$(cat "$SRC_ROOT/bin/aib-broker-handler")" "_projection.json"

# =========================================================================
# N — timezone coupling (CONTRACT-visibility.md SS9)
# =========================================================================
today="$(TZ=Europe/Berlin date '+%Y-%m-%d')"
now_minus1="$(TZ=Europe/Berlin date -d '-1 minute' '+%H:%M' 2>/dev/null || TZ=Europe/Berlin date -v-1M '+%H:%M' 2>/dev/null)"
if [ -n "$now_minus1" ]; then
  hb acme acme-core "$today" "$now_minus1" busy "just now, local wall time"
  run_project acme
  since="$(jget "$OUT_ACME" 'agents.acme-core.since')"
  since_cnt="$(printf '%s' "$since" | grep -Ec '(\+|-)[0-9]{2}:[0-9]{2}$' 2>/dev/null)"; since_cnt="${since_cnt:-0}"
  eq "since carries an explicit UTC offset (not bare Z-less/naive)" "$since_cnt" 1
  eq "a heartbeat from one minute ago under the fleet TZ is not stale" \
    "$(jget "$OUT_ACME" 'agents.acme-core.stale')" false
else
  skip "TZ coupling (date -d/-v not available to compute 'one minute ago')"
fi

total=$((pass+fail))
printf '\n%d checks (%d skipped): %d ok / %d fail\n' "$total" "$skipped" "$pass" "$fail"
[ "$fail" -eq 0 ]
