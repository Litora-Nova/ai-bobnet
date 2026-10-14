#!/usr/bin/env bash
# ai-bobnet — RED spec for registry schema 5 (Supervisor slice S1a-2; design B13 as it applies to S1a).
#
# WHAT THIS PINS
#   - schema_version 5 is accepted everywhere 3/4 are (plain registry queries, bin/run-agent, the
#     managed-execution resolver); 6 and 1 are still refused (fail-closed gate).
#   - the S1a agent fields are FLAT JSON strings: `mode` (oneshot|supervised), `session_max_turns`,
#     `restart_burst`, `restart_interval_s`, `restart_turn_backoff_cap_s`. The design wrote them as
#     nested objects (`session: {max_turns}`, `restart: {…}`), but the registry reader only exposes
#     depth-2 string fields (a nested object answers rc 8 "not a JSON string"), so the nested form is
#     unreadable by construction — RESOLVED HERE by flattening, not by teaching the reader nesting.
#   - validation of VALUES happens where a field is consumed (bin/aib-supervisor refuses with
#     exit 0 + journal `config_invalid`, supervisor_loop_spec T1); the reader itself stays forward
#     compatible and returns whatever string is stored.
#   - an agent with no `mode` behaves as oneshot (schema-4 registries keep working untouched).
#   Not pinned (later slices): `protected`, `lead`, `control_policy`, `providers.<p>.modes`,
#   `projects.<p>.data_class` (S1b), per-agent HOME / `account` (S1c).
set -uo pipefail
SRC_ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-reg5.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
no(){ fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; }
eq(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2' want '$3')"; fi; }

mkdir -p "$WORK/home" "$WORK/standup"
reg() { # reg <schema> <file>
  cat > "$2" <<JSON
{ "schema_version": $1,
  "providers": { "acme": { "adapter": "$SRC_ROOT/adapters/codex", "cap_sandbox": "workspace-write", "cap_tier": "t2", "cap_effort": "high", "cap_timeout": "900" } },
  "projects": { "acme": { "home": "$WORK/home", "standup_dir": "$WORK/standup", "mux_session": "acme", "provider": "acme", "model": "m", "effort": "low" } },
  "teams": { "acme-engine": { "project": "acme", "model": "m" } },
  "agents": {
    "acme-core": { "mode": "supervised", "session_max_turns": "200", "restart_burst": "5", "restart_interval_s": "900", "restart_turn_backoff_cap_s": "600",
                   "project": "acme", "team_uid": "acme-engine", "profile": "engine-dev", "clearance": "t2" },
    "acme-solo": { "project": "acme", "team_uid": "acme-engine", "profile": "engine-dev", "clearance": "t2" }
  } }
JSON
}
q() { # q <registry> <fn...> — run a library call hermetically
  local r="$1"; shift
  env -i PATH="$PATH" AIBOBNET_REGISTRY="$r" bash -c '. "$1/lib/aibobnet.sh"; shift; "$@"' _ "$SRC_ROOT" "$@" 2>/dev/null
}
for v in 5 4 6 1; do reg $v "$WORK/r$v.json"; done

# --- gate ------------------------------------------------------------------------
rc=0; q "$WORK/r5.json" aib_registry_query agents keys >/dev/null || rc=$?
eq "schema 5: plain registry query succeeds" "$rc" 0
rc=0; q "$WORK/r4.json" aib_registry_query agents keys >/dev/null || rc=$?
eq "schema 4: still accepted (regression guard)" "$rc" 0
for v in 6 1; do
  rc=0; q "$WORK/r$v.json" aib_registry_query agents keys >/dev/null || rc=$?
  eq "schema $v: still refused (raw reader rc 11, fail-closed gate)" "$rc" 11
done
eq "schema 5: aib_registry_schema_version reports 5" "$(q "$WORK/r5.json" aib_registry_schema_version)" 5

# --- fields ----------------------------------------------------------------------
for f in "mode supervised" "session_max_turns 200" "restart_burst 5" "restart_interval_s 900" "restart_turn_backoff_cap_s 600"; do
  eq "schema 5: agents.acme-core.${f% *} reads as a flat string" "$(q "$WORK/r5.json" aib_registry_query agents field acme-core "${f% *}")" "${f#* }"
done
rc=0; q "$WORK/r5.json" aib_registry_query agents field acme-solo mode >/dev/null || rc=$?
eq "an agent without mode: field absent (rc 4) = oneshot by default" "$rc" 4

# --- consumers accept schema 5 -----------------------------------------------------
cp -R "$SRC_ROOT/bin" "$SRC_ROOT/scripts" "$SRC_ROOT/lib" "$SRC_ROOT/adapters" "$WORK/"
cp "$WORK/r5.json" "$WORK/registry.json"
rc=0; env -i PATH="$PATH" "$WORK/bin/run-agent" acme-core -- true >/dev/null 2>&1 || rc=$?
eq "bin/run-agent resolves a supervised agent under schema 5" "$rc" 0
out="$(env -i PATH="$PATH" "$WORK/bin/run-agent" acme-core -- printenv AIBOBNET_PROJECT_UID 2>/dev/null)"
eq "…and exports the same routing context as before" "$out" acme
eq "managed resolver accepts schema 5 (provider resolved)" "$(q "$WORK/r5.json" bash -c '. "$0/lib/aibobnet.sh"; aib_resolve_managed_agent acme-core && printf %s "$AIB_PROVIDER"' "$SRC_ROOT")" acme

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
