#!/usr/bin/env bash
# ai-bobnet — RM-1 Policy Decision Point (aib_authorize_launch) unit acceptance.
#
# The PDP is a PURE decision function: data in (a request record + a resolved snapshot
# record) -> verdict out (via AIB_VERDICT_* globals). This spec drives it with pure
# data — no process spawn, no fixture on disk — which is exactly the RM-1 testing win.
# It also proves, against tiny temp registries, that the schema-4 adapter map + caps
# resolve into the snapshot the PEP will hand the PDP, and that a schema-3 registry
# (no adapter map) fails closed with the same missing-adapter verdict.
#
# Authority checked here (and NOWHERE else, per the PDP/PEP split): the sandbox
# ceiling, min(clearance, cap_tier), and the effort cap.
set -uo pipefail

SRC_ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
REPO_ROOT="$SRC_ROOT"
# shellcheck source=lib/aibobnet.sh
. "$SRC_ROOT/lib/aibobnet.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-pdp.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# --- tiny assertion harness (same style as tests/p0_spec.sh) ------------------
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
no(){ fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; }
assert_streq(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2' want '$3')"; fi; }
assert_grep(){ if printf '%s\n' "$2" | grep -qF -- "$3"; then ok "$1"; else no "$1 (missing '$3' in: $2)"; fi; }
assert_ngrep(){ if printf '%s\n' "$2" | grep -qF -- "$3"; then no "$1 (unexpected '$3' in: $2)"; else ok "$1"; fi; }
assert_ok(){   local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else no "$d (expected success)"; fi; }
assert_fail(){ local d="$1"; shift; if "$@" >/dev/null 2>&1; then no "$d (expected failure)"; else ok "$d"; fi; }

# --- record builders (the exact serialisable shapes the PEP will construct) ---
# req <agent_uid> <sandbox> [cwd] [timeout] [label]
req() {
  printf 'agent_uid=%s\nsandbox=%s\ncwd=%s\ntimeout=%s\nlabel=%s' \
    "${1:-acme-core}" "${2:-read-only}" "${3:-/w}" "${4:-1200}" "${5:-l}"
}
# snap <clearance> <provider> <effort> <adapter> <cap_sandbox> <cap_tier> <cap_effort>
snap() {
  printf 'clearance=%s\nprovider=%s\neffort=%s\nadapter=%s\ncap_sandbox=%s\ncap_tier=%s\ncap_effort=%s' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7"
}
# Serialise the resolver's globals into a snapshot record — documents, for Lane B,
# precisely which resolved values become the PDP's trusted input.
snap_from_resolved() {
  snap "$AIB_CLEARANCE" "$AIB_PROVIDER" "$AIB_EFFORT" "$AIB_ADAPTER_PATH" \
    "$AIB_CAP_SANDBOX" "$AIB_CAP_TIER" "$AIB_CAP_EFFORT"
}
# Run the PDP; RC captures the return status (0 allow, non-zero deny).
pdp() { if aib_authorize_launch "$1" "$2"; then RC=0; else RC=$?; fi; }

# ============================================================================ #
# 1. The min binds both ways: min(clearance, cap_tier)
# ============================================================================ #
pdp "$(req)" "$(snap t2 codex low /a/b read-only t3 high)"
assert_streq "clearance below caps: allowed"                 "$AIB_VERDICT_DECISION" "allow"
assert_streq "clearance below caps: effective = the lower clearance" "$AIB_VERDICT_EFFECTIVE_CLEARANCE" "t2"

pdp "$(req)" "$(snap t4 codex low /a/b read-only t2 high)"
assert_streq "caps below clearance: allowed"                 "$AIB_VERDICT_DECISION" "allow"
assert_streq "caps below clearance: the cap binds the min"   "$AIB_VERDICT_EFFECTIVE_CLEARANCE" "t2"
assert_grep  "caps below clearance: the clamp is reported"   "$AIB_VERDICT_REASONS" "clamped to 't2'"

pdp "$(req)" "$(snap t3 codex low /a/b read-only t3 high)"
assert_streq "clearance equals cap: effective = t3"          "$AIB_VERDICT_EFFECTIVE_CLEARANCE" "t3"

# ============================================================================ #
# 2. Sandbox ceiling = min(requested, cap_sandbox)
# ============================================================================ #
pdp "$(req acme-core read-only)"       "$(snap t2 codex low /a/b workspace-write t3 high)"
assert_streq "sandbox below ceiling: requested honoured"     "$AIB_VERDICT_EFFECTIVE_SANDBOX" "read-only"

pdp "$(req acme-core workspace-write)" "$(snap t2 codex low /a/b workspace-write t3 high)"
assert_streq "sandbox at ceiling: requested honoured"        "$AIB_VERDICT_EFFECTIVE_SANDBOX" "workspace-write"

pdp "$(req acme-core workspace-write)" "$(snap t2 codex low /a/b read-only t3 high)"
assert_streq "sandbox above ceiling: still allowed"          "$AIB_VERDICT_DECISION" "allow"
assert_streq "sandbox above ceiling: clamped to ceiling"     "$AIB_VERDICT_EFFECTIVE_SANDBOX" "read-only"
assert_grep  "sandbox above ceiling: the clamp is reported"  "$AIB_VERDICT_REASONS" "clamped to 'read-only'"

# A danger-full-access request is NEVER granted: it can only clamp down to the ceiling
# (the provider never declares danger as a capability). This is the min, not a bypass.
pdp "$(req acme-core danger-full-access)" "$(snap t2 codex low /a/b workspace-write t3 high)"
assert_streq "danger request: never granted, clamped to ceiling" "$AIB_VERDICT_EFFECTIVE_SANDBOX" "workspace-write"
assert_ngrep "danger request: danger never appears as effective"  "$AIB_VERDICT_EFFECTIVE_SANDBOX" "danger-full-access"

# ============================================================================ #
# 3. Effort cap = min(effort, cap_effort)
# ============================================================================ #
pdp "$(req)" "$(snap t2 codex low  /a/b read-only t3 high)"
assert_streq "effort below cap: effort honoured"             "$AIB_VERDICT_EFFECTIVE_EFFORT" "low"

pdp "$(req)" "$(snap t2 codex max  /a/b read-only t3 medium)"
assert_streq "effort above cap: allowed"                     "$AIB_VERDICT_DECISION" "allow"
assert_streq "effort above cap: clamped to the cap"          "$AIB_VERDICT_EFFECTIVE_EFFORT" "medium"
assert_grep  "effort above cap: the clamp is reported"       "$AIB_VERDICT_REASONS" "clamped to 'medium'"

# ============================================================================ #
# 4. Adapter map: fail-closed, absolute, and cwd-independent (Decision 3)
# ============================================================================ #
# Absent adapter (== unknown provider): the same missing-adapter fail-closed the PEP
# turns into exit 127. Built by hand so the adapter key is genuinely absent.
pdp "$(printf 'agent_uid=acme-core\nsandbox=read-only\ncwd=/w\ntimeout=1\nlabel=l')" \
    "$(printf 'clearance=t2\nprovider=ghost\neffort=low\ncap_sandbox=read-only\ncap_tier=t3\ncap_effort=high')"
assert_streq "absent adapter: denied"                        "$AIB_VERDICT_DECISION" "deny"
assert_streq "absent adapter: exit hint is adapter-not-found (127)" "$AIB_VERDICT_CODE" "127"
assert_grep  "absent adapter: the reason names the provider" "$AIB_VERDICT_REASONS" "provider 'ghost'"

pdp "$(req)" "$(snap t2 codex low '' read-only t3 high)"
assert_streq "empty adapter: denied 127"                     "$AIB_VERDICT_CODE" "127"

pdp "$(req)" "$(snap t2 codex low relative/codex read-only t3 high)"
assert_streq "non-absolute adapter: denied"                  "$AIB_VERDICT_DECISION" "deny"
assert_streq "non-absolute adapter: exit hint is config (2)" "$AIB_VERDICT_CODE" "2"
assert_grep  "non-absolute adapter: the reason says absolute" "$AIB_VERDICT_REASONS" "is not absolute"

# A deny leaves NO effective authority and NO adapter path to act on.
assert_streq "deny: no effective sandbox leaks"              "$AIB_VERDICT_EFFECTIVE_SANDBOX" ""
assert_streq "deny: no adapter path leaks"                   "$AIB_VERDICT_ADAPTER_PATH" ""

# ============================================================================ #
# 5. Declared capabilities must be present and well-formed (Decision 2/4)
# ============================================================================ #
pdp "$(req)" "$(snap t2 codex low /a/b '' t3 high)"
assert_streq "missing cap_sandbox: denied config (2)"        "$AIB_VERDICT_CODE" "2"
pdp "$(req)" "$(snap t2 codex low /a/b read-only bogus high)"
assert_streq "invalid cap_tier: denied config (2)"           "$AIB_VERDICT_CODE" "2"
pdp "$(req)" "$(snap t2 codex low /a/b read-only t3 louder)"
assert_streq "invalid cap_effort: denied config (2)"         "$AIB_VERDICT_CODE" "2"

# ============================================================================ #
# 6. Request form is re-validated (input hygiene, safe to call in isolation)
# ============================================================================ #
pdp "$(req acme-core nope)"  "$(snap t2 codex low /a/b workspace-write t3 high)"
assert_streq "unknown requested sandbox: refused (64)"       "$AIB_VERDICT_CODE" "64"
pdp "$(req)" "$(snap bad codex low /a/b workspace-write t3 high)"
assert_streq "invalid clearance token: refused (64)"         "$AIB_VERDICT_CODE" "64"
pdp "$(req)" "$(snap t2 codex nope /a/b workspace-write t3 high)"
assert_streq "invalid resolved effort: refused (64)"         "$AIB_VERDICT_CODE" "64"
# Hand-built so agent_uid is genuinely absent (the req helper would default it).
pdp "$(printf 'sandbox=read-only\ncwd=/w\ntimeout=1\nlabel=l')" \
    "$(snap t2 codex low /a/b workspace-write t3 high)"
assert_streq "missing agent_uid: refused (64)"               "$AIB_VERDICT_CODE" "64"

# ============================================================================ #
# 7. Verdict shape + env allow-list + return status
# ============================================================================ #
pdp "$(req)" "$(snap t2 codex high /opt/acme/adapters/codex workspace-write t3 high)"
assert_streq "allow: the function returns success"           "$RC" "0"
assert_grep  "verdict record carries the decision"           "$AIB_VERDICT_RECORD" '"decision":"allow"'
assert_grep  "verdict record carries the absolute adapter"   "$AIB_VERDICT_RECORD" '"adapter_path":"/opt/acme/adapters/codex"'
assert_grep  "verdict record is the launch_verdict event"    "$AIB_VERDICT_RECORD" '"event":"launch_verdict"'
assert_streq "env allow-list is the documented default set"  "$AIB_VERDICT_ENV_ALLOW" "HOME PATH"
assert_streq "env allow-list equals the exported constant"   "$AIB_VERDICT_ENV_ALLOW" "$AIB_ENV_ALLOW_DEFAULT"

# The return STATUS is the allow/deny boolean (non-zero = deny); the exit-code hint
# the PEP should use lives in AIB_VERDICT_CODE. Both are asserted here.
pdp "$(req)" "$(snap t2 codex low '' read-only t3 high)"
assert_streq "deny: the function returns a non-zero status"  "$RC" "1"
assert_streq "deny: the exit-code hint is 127"               "$AIB_VERDICT_CODE" "127"

# ============================================================================ #
# 8. Purity: the PDP needs no registry, no env, no cwd — proven under `env -i`
# ============================================================================ #
pure_req='agent_uid=acme-core
sandbox=workspace-write
cwd=/w
timeout=1
label=l'
pure_snap='clearance=t2
provider=codex
effort=high
adapter=/opt/acme/adapters/codex
cap_sandbox=workspace-write
cap_tier=t3
cap_effort=high'
pure_out="$(env -i "$(command -v bash)" -c '
  . "'"$SRC_ROOT"'/lib/aibobnet.sh"
  aib_authorize_launch "$1" "$2" && printf "%s\n" "$AIB_VERDICT_DECISION"
' _ "$pure_req" "$pure_snap" 2>&1)"
assert_streq "purity: allows with only the two records, under env -i (no REPO_ROOT/registry)" \
  "$pure_out" "allow"

# ============================================================================ #
# 9. Schema 4 resolves the adapter map + caps into the snapshot (acceptance)
# ============================================================================ #
reg4="$WORK/reg4.json"
cat > "$reg4" <<'JSON'
{
  "schema_version": 4,
  "providers": {
    "codex": { "adapter": "/opt/acme/adapters/codex", "cap_sandbox": "workspace-write", "cap_tier": "t3", "cap_effort": "high" }
  },
  "projects": {
    "acme": { "home": "/srv/acme", "standup_dir": "/srv/acme/standup", "mux_session": "acme", "provider": "codex", "model": "example-model", "effort": "max" }
  },
  "teams": {},
  "agents": { "acme-core": { "project": "acme", "profile": "engine-dev", "clearance": "t4" } }
}
JSON
AIBOBNET_REGISTRY="$reg4" aib_resolve_managed_agent acme-core
assert_streq "schema 4: accepted, schema surfaced"           "$AIB_REGISTRY_SCHEMA_VERSION" "4"
assert_streq "schema 4: adapter resolved (absolute, from the map)" "$AIB_ADAPTER_PATH" "/opt/acme/adapters/codex"
assert_streq "schema 4: cap_sandbox resolved"                "$AIB_CAP_SANDBOX" "workspace-write"
assert_streq "schema 4: cap_tier resolved"                   "$AIB_CAP_TIER" "t3"
assert_streq "schema 4: cap_effort resolved"                 "$AIB_CAP_EFFORT" "high"

# End to end: the resolved schema-4 snapshot authorises, clamping t4->t3 and max->high.
pdp "$(req)" "$(snap_from_resolved)"
assert_streq "schema 4 e2e: allowed"                         "$AIB_VERDICT_DECISION" "allow"
assert_streq "schema 4 e2e: clearance clamped to the cap"    "$AIB_VERDICT_EFFECTIVE_CLEARANCE" "t3"
assert_streq "schema 4 e2e: effort clamped to the cap"       "$AIB_VERDICT_EFFECTIVE_EFFORT" "high"

# A schema-4 registry whose provider is missing from the adapter map is fail-closed.
reg4_noprov="$WORK/reg4-noprov.json"
cat > "$reg4_noprov" <<'JSON'
{
  "schema_version": 4,
  "providers": { "other": { "adapter": "/opt/acme/adapters/other", "cap_sandbox": "read-only", "cap_tier": "t2", "cap_effort": "low" } },
  "projects": { "acme": { "home": "/srv/acme", "standup_dir": "/srv/acme/standup", "mux_session": "acme", "provider": "codex", "model": "m", "effort": "low" } },
  "teams": {},
  "agents": { "acme-core": { "project": "acme", "profile": "engine-dev", "clearance": "t2" } }
}
JSON
assert_fail "schema 4: an undeclared provider is fail-closed at resolve" \
  bash -c '. "'"$SRC_ROOT"'/lib/aibobnet.sh"; AIBOBNET_REGISTRY="'"$reg4_noprov"'" aib_resolve_managed_agent acme-core'

# ============================================================================ #
# 10. Schema 3 has no adapter map -> resolves an empty adapter -> PDP denies 127
# ============================================================================ #
reg3="$WORK/reg3.json"
cat > "$reg3" <<'JSON'
{
  "schema_version": 3,
  "projects": { "acme": { "home": "/srv/acme", "standup_dir": "/srv/acme/standup", "mux_session": "acme", "provider": "codex", "model": "example-model", "effort": "high" } },
  "teams": {},
  "agents": { "acme-core": { "project": "acme", "profile": "engine-dev", "clearance": "t2" } }
}
JSON
AIBOBNET_REGISTRY="$reg3" aib_resolve_managed_agent acme-core
assert_streq "schema 3: binding still resolves (provider)"   "$AIB_PROVIDER" "codex"
assert_streq "schema 3: no adapter map -> empty adapter"     "$AIB_ADAPTER_PATH" ""
pdp "$(req)" "$(snap_from_resolved)"
assert_streq "schema 3 e2e: fail-closed missing-adapter (127)" "$AIB_VERDICT_CODE" "127"

# ============================================================================ #
# summary
# ============================================================================ #
total=$((pass+fail))
printf '\n%d checks: %d ok / %d fail\n' "$total" "$pass" "$fail"
[ "$fail" -eq 0 ]
