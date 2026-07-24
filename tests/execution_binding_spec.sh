#!/usr/bin/env bash
# ai-bobnet — RM-0 Lane-A execution-binding acceptance.
# Covers the schema-3 resolver/context bundle only. Managed provider execution is Lane B.
set -uo pipefail

SRC_ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-binding.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
ENGINE="$WORK/engine"
mkdir -p "$ENGINE"
cp -R "$SRC_ROOT/bin" "$SRC_ROOT/lib" "$ENGINE/"
CTX="$ENGINE/bin/context"
RUN="$ENGINE/bin/run-agent"
INBOX="$ENGINE/bin/inbox"

pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
no(){ fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; }
assert_ok(){ local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else no "$d (expected success)"; fi; }
assert_fail(){ local d="$1"; shift; if "$@" >/dev/null 2>&1; then no "$d (expected failure)"; else ok "$d"; fi; }
assert_eq(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2' want '$3')"; fi; }
assert_has(){ if printf '%s\n' "$2" | grep -qF -- "$3"; then ok "$1"; else no "$1 (missing '$3' in: $2)"; fi; }
assert_lacks(){ if printf '%s\n' "$2" | grep -qF -- "$3"; then no "$1 (unexpected '$3' in: $2)"; else ok "$1"; fi; }

write_file(){ printf '%s\n' "$2" > "$1"; }
context_for(){
  AIBOBNET_REGISTRY="$1" AIBOBNET_PROJECT_UID=acme AIBOBNET_AGENT_KEY="$2" "$CTX" "${3:-}"
}
bundle_for(){
  REPO_ROOT="$ENGINE" AIBOBNET_REGISTRY="$1" AGENT_UID="$2" bash -c '
    set -euo pipefail
    . "$REPO_ROOT/lib/aibobnet.sh"
    aib_resolve_managed_agent "$AGENT_UID"
    printf "agent_uid=%s\nproject=%s\nteam=%s\nprofile=%s\nclearance=%s\nstandup_dir=%s\n" \
      "$AIB_AGENT_UID" "$AIB_PROJECT_UID" "${AIB_TEAM_UID:-}" "$AIB_PROFILE" "$AIB_CLEARANCE" "$AIB_STANDUP_DIR"
    printf "provider=%s\nprovider_source=%s\n" "$AIB_PROVIDER" "$AIB_PROVIDER_SOURCE"
    printf "model=%s\nmodel_source=%s\n" "$AIB_MODEL" "$AIB_MODEL_SOURCE"
    printf "effort=%s\neffort_source=%s\nregistry_schema_version=%s\n" \
      "$AIB_EFFORT" "$AIB_EFFORT_SOURCE" "$AIB_REGISTRY_SCHEMA_VERSION"
  '
}

V2="$WORK/v2.json"
write_file "$V2" '{
  "schema_version": 2,
  "projects": { "acme": { "home": "/srv/acme", "standup_dir": "/srv/acme/standup", "mux_session": "acme" } },
  "agents": { "acme-core": { "project": "acme", "profile": "engine-dev", "clearance": "t2" } }
}'

V3="$WORK/v3.json"
write_file "$V3" '{
  "schema_version": 3,
  "projects": {
    "acme": { "home": "/srv/acme", "standup_dir": "/srv/acme/standup", "mux_session": "acme",
      "provider": "codex", "model": "project-model", "effort": "low" }
  },
  "teams": {
    "acme-engine": { "project": "acme", "model": "team/model-v2" }
  },
  "agents": {
    "acme-mixed": { "project": "acme", "team_uid": "acme-engine", "profile": "engine-dev", "clearance": "t2", "effort": "high" },
    "acme-direct": { "project": "acme", "profile": "review", "clearance": "t1",
      "provider": "codex", "model": "agent-model", "effort": "medium" },
    "acme-noteam": { "project": "acme", "profile": "tests", "clearance": "t1" }
  }
}'

# Schema 2 is still a usable legacy identity/context, but not a managed binding.
legacy="$(context_for "$V2" core 2>/dev/null)"
assert_has "v2 legacy: identity still resolves" "$legacy" "agent_uid=acme-core"
assert_lacks "v2 legacy: no binding is invented" "$legacy" "provider="
assert_fail "v2 managed: binding resolver requires schema 3" bundle_for "$V2" acme-core

# Field-wise inheritance and exact per-field provenance.
mixed="$(bundle_for "$V3" acme-mixed 2>/dev/null)"
assert_has "mixed: provider falls through to project" "$mixed" "provider=codex"
assert_has "mixed: provider provenance is project uid" "$mixed" "provider_source=project:acme"
assert_has "mixed: model comes from direct team" "$mixed" "model=team/model-v2"
assert_has "mixed: model provenance is team uid" "$mixed" "model_source=team:acme-engine"
assert_has "mixed: effort comes from agent" "$mixed" "effort=high"
assert_has "mixed: effort provenance is agent uid" "$mixed" "effort_source=agent:acme-mixed"
assert_has "mixed: direct team is observable" "$mixed" "team=acme-engine"
assert_has "mixed: clearance remains agent data" "$mixed" "clearance=t2"
assert_has "mixed: bundle carries canonical agent uid" "$mixed" "agent_uid=acme-mixed"
assert_has "mixed: bundle carries resolved standup dir" "$mixed" "standup_dir=/srv/acme/standup"
assert_has "mixed: schema version is in the bundle" "$mixed" "registry_schema_version=3"

direct="$(bundle_for "$V3" acme-direct 2>/dev/null)"
assert_has "agent override: model wins at agent" "$direct" "model=agent-model"
assert_has "agent override: provenance stays agent" "$direct" "model_source=agent:acme-direct"

noteam="$(bundle_for "$V3" acme-noteam 2>/dev/null)"
assert_has "no team: project model fallback" "$noteam" "model=project-model"
assert_has "no team: empty direct-team value" "$noteam" "team="

# context text/JSON and run-agent env use the exact stable names from the sprint.
ctx_text="$(context_for "$V3" mixed 2>/dev/null)"
assert_has "context text: provider" "$ctx_text" "provider=codex"
assert_has "context text: provider provenance" "$ctx_text" "provider_source=project:acme"
assert_has "context text: model provenance" "$ctx_text" "model_source=team:acme-engine"
assert_has "context text: effort provenance" "$ctx_text" "effort_source=agent:acme-mixed"
assert_has "context text: schema version" "$ctx_text" "registry_schema_version=3"
ctx_json="$(context_for "$V3" mixed --json 2>/dev/null)"
assert_has "context json: provider key" "$ctx_json" '"provider":"codex"'
assert_has "context json: provider_source key" "$ctx_json" '"provider_source":"project:acme"'
assert_has "context json: registry schema key" "$ctx_json" '"registry_schema_version":"3"'

cp "$V3" "$ENGINE/registry.json"
run_env="$(
  AIBOBNET_PROVIDER=evil AIBOBNET_PROVIDER_SOURCE=agent:evil \
  AIBOBNET_MODEL=evil AIBOBNET_MODEL_SOURCE=agent:evil \
  AIBOBNET_EFFORT=evil AIBOBNET_EFFORT_SOURCE=agent:evil \
  AIBOBNET_REGISTRY_SCHEMA_VERSION=99 \
    "$RUN" acme-mixed -- sh -c '
      printf "provider=%s\nprovider_source=%s\nmodel=%s\nmodel_source=%s\neffort=%s\neffort_source=%s\nregistry_schema_version=%s\n" \
        "$AIBOBNET_PROVIDER" "$AIBOBNET_PROVIDER_SOURCE" "$AIBOBNET_MODEL" "$AIBOBNET_MODEL_SOURCE" \
        "$AIBOBNET_EFFORT" "$AIBOBNET_EFFORT_SOURCE" "$AIBOBNET_REGISTRY_SCHEMA_VERSION"
    ' 2>/dev/null
)"
assert_has "env poison: provider comes from registry" "$run_env" "provider=codex"
assert_has "env poison: model comes from team" "$run_env" "model=team/model-v2"
assert_has "env poison: effort comes from agent" "$run_env" "effort=high"
assert_has "env poison: schema comes from snapshot" "$run_env" "registry_schema_version=3"
assert_lacks "env poison: no ambient binding survives" "$run_env" "evil"

# Schema 4 carries the SAME execution binding as schema 3 (RM-1 added the provider
# adapter map on top; it did not remove the binding). V4 is byte-for-byte V3 with the
# version bumped and a `providers` map added — so any output difference is a pure
# schema-number regression. The binding output surfaces (context text/JSON, run-agent
# env) must therefore emit all seven fields under 4 exactly as they do under 3.
V4="$WORK/v4.json"
write_file "$V4" '{
  "schema_version": 4,
  "projects": {
    "acme": { "home": "/srv/acme", "standup_dir": "/srv/acme/standup", "mux_session": "acme",
      "provider": "codex", "model": "project-model", "effort": "low" }
  },
  "teams": {
    "acme-engine": { "project": "acme", "model": "team/model-v2" }
  },
  "providers": {
    "codex": { "adapter": "/opt/acme/adapters/codex", "cap_sandbox": "workspace-write",
      "cap_tier": "t3", "cap_effort": "high" }
  },
  "agents": {
    "acme-mixed": { "project": "acme", "team_uid": "acme-engine", "profile": "engine-dev", "clearance": "t2", "effort": "high" }
  }
}'

ctx4_text="$(context_for "$V4" mixed 2>/dev/null)"
assert_has "schema4 context text: provider" "$ctx4_text" "provider=codex"
assert_has "schema4 context text: provider provenance" "$ctx4_text" "provider_source=project:acme"
assert_has "schema4 context text: model" "$ctx4_text" "model=team/model-v2"
assert_has "schema4 context text: model provenance" "$ctx4_text" "model_source=team:acme-engine"
assert_has "schema4 context text: effort" "$ctx4_text" "effort=high"
assert_has "schema4 context text: effort provenance" "$ctx4_text" "effort_source=agent:acme-mixed"
assert_has "schema4 context text: schema version" "$ctx4_text" "registry_schema_version=4"

ctx4_json="$(context_for "$V4" mixed --json 2>/dev/null)"
assert_has "schema4 context json: provider key" "$ctx4_json" '"provider":"codex"'
assert_has "schema4 context json: provider_source key" "$ctx4_json" '"provider_source":"project:acme"'
assert_has "schema4 context json: model key" "$ctx4_json" '"model":"team/model-v2"'
assert_has "schema4 context json: model_source key" "$ctx4_json" '"model_source":"team:acme-engine"'
assert_has "schema4 context json: effort key" "$ctx4_json" '"effort":"high"'
assert_has "schema4 context json: effort_source key" "$ctx4_json" '"effort_source":"agent:acme-mixed"'
assert_has "schema4 context json: registry schema key" "$ctx4_json" '"registry_schema_version":"4"'

# run-agent scrubs AIBOBNET_* (incl. AIBOBNET_REGISTRY) before resolving, so it always
# reads the canonical registry.json — point that at V4 for this leg, then restore V3.
cp "$V4" "$ENGINE/registry.json"
run4_env="$(
  "$RUN" acme-mixed -- sh -c '
    printf "provider=%s\nprovider_source=%s\nmodel=%s\nmodel_source=%s\neffort=%s\neffort_source=%s\nregistry_schema_version=%s\n" \
      "$AIBOBNET_PROVIDER" "$AIBOBNET_PROVIDER_SOURCE" "$AIBOBNET_MODEL" "$AIBOBNET_MODEL_SOURCE" \
      "$AIBOBNET_EFFORT" "$AIBOBNET_EFFORT_SOURCE" "$AIBOBNET_REGISTRY_SCHEMA_VERSION"
  ' 2>/dev/null
)"
cp "$V3" "$ENGINE/registry.json"
assert_has "schema4 run-agent env: provider" "$run4_env" "provider=codex"
assert_has "schema4 run-agent env: provider provenance" "$run4_env" "provider_source=project:acme"
assert_has "schema4 run-agent env: model" "$run4_env" "model=team/model-v2"
assert_has "schema4 run-agent env: model provenance" "$run4_env" "model_source=team:acme-engine"
assert_has "schema4 run-agent env: effort" "$run4_env" "effort=high"
assert_has "schema4 run-agent env: effort provenance" "$run4_env" "effort_source=agent:acme-mixed"
assert_has "schema4 run-agent env: schema version" "$run4_env" "registry_schema_version=4"

# Resolver snapshots are process-local state, never an ambient registry authority.
# Both a direct legacy entrypoint and a run-agent child must reopen the canonical
# file-backed registry rather than consume an attacker-supplied shell variable.
AMBIENT_SNAPSHOT='{
  "schema_version": 2,
  "projects": { "acme": { "home": "/evil", "standup_dir": "/evil-standup", "mux_session": "evil" } },
  "agents": { "acme-mixed": { "project": "acme", "profile": "evil", "clearance": "t4" } }
}'
direct_inbox="$(AIB_REGISTRY_SNAPSHOT="$AMBIENT_SNAPSHOT" "$INBOX" acme-mixed 2>/dev/null)"
assert_eq "snapshot poison: direct legacy entrypoint uses canonical registry" \
  "$direct_inbox" "/srv/acme/standup/inbox/acme-mixed.md"
wrapped_inbox="$(AIB_REGISTRY_SNAPSHOT="$AMBIENT_SNAPSHOT" \
  "$RUN" acme-mixed -- "$INBOX" acme-mixed 2>/dev/null)"
assert_eq "snapshot poison: run-agent child uses canonical registry" \
  "$wrapped_inbox" "/srv/acme/standup/inbox/acme-mixed.md"

# Only absence falls through. Present-invalid values must fail at that level.
invalid_case(){
  local name="$1" agent_extra="$2" teams="$3"
  local path="$WORK/$name.json"
  write_file "$path" "{
    \"schema_version\": 3,
    \"projects\": { \"acme\": { \"home\": \"/h\", \"standup_dir\": \"/s\", \"mux_session\": \"m\",
      \"provider\": \"codex\", \"model\": \"project-model\", \"effort\": \"low\" } },
    \"teams\": { $teams },
    \"agents\": { \"acme-core\": { \"project\": \"acme\", \"profile\": \"p\", \"clearance\": \"t1\" $agent_extra } }
  }"
  assert_fail "$name" bundle_for "$path" acme-core
}
invalid_case "invalid: present-empty provider does not fall through" ', "provider": ""' ''
invalid_case "invalid: non-string model does not fall through" ', "model": 7' ''
invalid_case "invalid: undecodable effort does not fall through" ', "effort": "h\u0069gh"' ''
invalid_case "invalid: provider syntax is closed" ', "provider": "Codex!"' ''
invalid_case "invalid: model syntax is closed" ', "model": "bad model"' ''
invalid_case "invalid: present-empty team_uid is not no-team" ', "team_uid": ""' ''
invalid_case "invalid: non-string team_uid is refused" ', "team_uid": 3' ''
invalid_case "invalid: undecodable team_uid is refused" ', "team_uid": "acme-\u0065ngine"' ''
invalid_case "invalid: malformed team_uid is refused" ', "team_uid": "engine"' ''
invalid_case "invalid: unknown direct team is refused" ', "team_uid": "acme-ghost"' ''
invalid_case "invalid: foreign direct team is refused" ', "team_uid": "beta-engine"' '"beta-engine": { "project": "beta" }'
invalid_case "invalid: team project must match uid prefix" ', "team_uid": "acme-engine"' '"acme-engine": { "project": "beta" }'
invalid_case "invalid: team project must exist" ', "team_uid": "acme-engine"' '"acme-engine": { "project": "ghost" }'

# Rebuild the missing-provider case without the project default (the helper above keeps it).
MISSING="$WORK/missing-provider.json"
write_file "$MISSING" '{
  "schema_version": 3,
  "projects": { "acme": { "home": "/h", "standup_dir": "/s", "mux_session": "m", "model": "m", "effort": "low" } },
  "teams": {},
  "agents": { "acme-core": { "project": "acme", "profile": "p", "clearance": "t1" } }
}'
assert_fail "invalid: a binding field missing from the complete chain is refused" bundle_for "$MISSING" acme-core

# A FIFO with one writer provides exactly one registry snapshot. Reopening it hangs;
# timeout is only the deterministic failure cap, not a synchronization mechanism.
FIFO="$WORK/registry.fifo"
mkfifo "$FIFO"
(
  printf '%s\n' "$(<"$V3")" > "$FIFO"
) &
writer=$!
fifo_out="$(timeout 3 env REPO_ROOT="$ENGINE" AIBOBNET_REGISTRY="$FIFO" AGENT_UID=acme-mixed bash -c '
  set -euo pipefail
  . "$REPO_ROOT/lib/aibobnet.sh"
  aib_resolve_managed_agent "$AGENT_UID"
  printf "%s|%s|%s" "$AIB_PROVIDER" "$AIB_MODEL" "$AIB_EFFORT"
' 2>/dev/null)"
fifo_rc=$?
if kill -0 "$writer" 2>/dev/null; then
  kill "$writer" 2>/dev/null || true
fi
wait "$writer" 2>/dev/null || true
assert_eq "snapshot: resolver consumes a one-write FIFO exactly once" "$fifo_rc" "0"
assert_eq "snapshot: one generation supplies the full binding" "$fifo_out" "codex|team/model-v2|high"

# Managed callers must heartbeat without reopening the registry. The primitive takes
# only pre-resolved bundle values and preserves log.sh status/sanitization semantics.
HB_DIR="$WORK/heartbeat"
resolved_log(){
  REPO_ROOT="$ENGINE" AIBOBNET_REGISTRY="$WORK/does-not-exist.json" bash -c '
    set -euo pipefail
    . "$REPO_ROOT/lib/aibobnet.sh"
    aib_log_resolved "$1" "$2" "$3" "$4"
  ' _ "$@"
}
assert_ok "resolved heartbeat: no registry read is required" \
  resolved_log "$HB_DIR" acme-mixed busy $'hello\nthere | structured'
hb="$(<"$HB_DIR/acme-mixed.log")"
assert_has "resolved heartbeat: newline and pipe use the canonical encoding" \
  "$hb" "hello there %7C structured"
assert_eq "resolved heartbeat: exactly one physical record is written" \
  "$(wc -l < "$HB_DIR/acme-mixed.log")" "1"
assert_fail "resolved heartbeat: invalid status remains fail-closed" \
  resolved_log "$HB_DIR" acme-mixed wat "bad"
assert_fail "resolved heartbeat: malformed agent uid remains fail-closed" \
  resolved_log "$HB_DIR" 'bad/agent' busy "bad"

total=$((pass+fail))
printf '\n%d checks: %d ok / %d fail\n' "$total" "$pass" "$fail"
[ "$fail" -eq 0 ]
