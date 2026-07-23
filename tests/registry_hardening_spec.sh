#!/usr/bin/env bash
# ai-bobnet — RM-1 Lane-C deferred hardening acceptance.
# Two RM-0 findings land here, both inside lib/aibobnet.sh's snapshot load:
#   #2 raw-NUL rejection WITHIN the one-open invariant — $(<file) silently drops
#      NUL bytes; the registry crosses into line-oriented key=value / journal
#      protocols where an embedded NUL is unsafe, so it must be a loud refusal.
#      The detection MUST stay a single registry open (the failed hotfix added a
#      second tr/mv read and deadlocked the one-write FIFO seam).
#   #3 team-key LOAD-time validation — every team key is validated at load, not
#      only the one an agent happens to reference (lazy validation let a malformed,
#      unreferenced team key sit silently until first use).
# Scope: the snapshot load + team-key validation only. The PDP (Lane A) is untouched.
set -uo pipefail

SRC_ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-hardening.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
ENGINE="$WORK/engine"
mkdir -p "$ENGINE"
cp -R "$SRC_ROOT/bin" "$SRC_ROOT/lib" "$ENGINE/"

pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
no(){ fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; }
assert_eq(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2' want '$3')"; fi; }
assert_has(){ if printf '%s\n' "$2" | grep -qF -- "$3"; then ok "$1"; else no "$1 (missing '$3' in: $2)"; fi; }

write_file(){ printf '%s\n' "$2" > "$1"; }

# Resolve one managed agent in a clean subshell. Prints stdout; the caller inspects
# rc and captured stderr. env -i-free here on purpose: this exercises load + team
# validation, not the PEP.
resolve_managed(){
  REPO_ROOT="$ENGINE" AIBOBNET_REGISTRY="$1" AGENT_UID="$2" bash -c '
    set -euo pipefail
    . "$REPO_ROOT/lib/aibobnet.sh"
    aib_resolve_managed_agent "$AGENT_UID" >/dev/null
    printf "provider=%s model=%s effort=%s\n" "$AIB_PROVIDER" "$AIB_MODEL" "$AIB_EFFORT"
  '
}

# A complete, valid schema-3 registry. acme-core carries no team_uid, so nothing
# references the teams map — the map is present only to exercise LOAD-time checks.
REG='{
  "schema_version": 3,
  "projects": {
    "acme": { "home": "/srv/acme", "standup_dir": "/srv/acme/standup", "mux_session": "acme",
      "provider": "codex", "model": "project-model", "effort": "low" }
  },
  "teams": {
    "acme-extra": { "project": "acme", "model": "team/model-v2" }
  },
  "agents": {
    "acme-core": { "project": "acme", "profile": "engine-dev", "clearance": "t2" }
  }
}'

# ---------------------------------------------------------------------------
# Finding #2 — raw-NUL rejection within a single registry open
# ---------------------------------------------------------------------------
# Baseline: the clean registry resolves — the NUL guard must not false-positive on
# ordinary content (read -r -d '' returns the whole file when no NUL is present).
NUL_OK="$WORK/nul-clean.json"
write_file "$NUL_OK" "$REG"
clean_out="$(resolve_managed "$NUL_OK" acme-core 2>/dev/null)"; clean_rc=$?
assert_eq  "nul: a clean registry still resolves (no false positive)" "$clean_rc" "0"
assert_has "nul: the clean resolution carries the real binding" "$clean_out" "provider=codex"

# A raw NUL inserted immediately after the opening brace. Dropping that one byte
# rejoins the document into the byte-identical valid REG above — so ONLY the NUL
# guard can reject this file. Under the old $(<file) load the NUL is silently
# dropped and the file resolves: reverting the guard turns this assertion red.
NUL_BAD="$WORK/nul-raw.json"
printf '{\000%s' "${REG#\{}" > "$NUL_BAD"
nul_err="$(resolve_managed "$NUL_BAD" acme-core 2>&1 >/dev/null)"; nul_rc=$?
if [ "$nul_rc" -ne 0 ]; then ok "nul: an interior raw NUL is a loud refusal"; else no "nul: an interior raw NUL is a loud refusal (resolved rc=0)"; fi
assert_has "nul: the refusal names the NUL byte cause" "$nul_err" "NUL"

# The detection must consume exactly ONE registry open. A one-write FIFO delivers
# a single generation; a second open blocks forever, so a timeout-capped read that
# returns 0 proves the whole managed path (load + NUL detection + validation)
# reads the registry exactly once. rc=124 (timeout) would mean a second open crept
# back in — the exact failure mode of the retired hotfix.
FIFO="$WORK/registry.fifo"
mkfifo "$FIFO"
( printf '%s\n' "$REG" > "$FIFO" ) &
writer=$!
fifo_out="$(timeout 5 env REPO_ROOT="$ENGINE" AIBOBNET_REGISTRY="$FIFO" AGENT_UID=acme-core bash -c '
  set -euo pipefail
  . "$REPO_ROOT/lib/aibobnet.sh"
  aib_resolve_managed_agent "$AGENT_UID" >/dev/null
  printf "%s" "$AIB_PROVIDER"
' 2>/dev/null)"
fifo_rc=$?
if kill -0 "$writer" 2>/dev/null; then kill "$writer" 2>/dev/null || true; fi
wait "$writer" 2>/dev/null || true
assert_eq "nul: the managed path reads a one-write FIFO exactly once (rc, not 124)" "$fifo_rc" "0"
assert_eq "nul: the single FIFO generation supplies the full binding" "$fifo_out" "codex"

# ---------------------------------------------------------------------------
# Finding #3 — team-key validation at LOAD, not only when referenced
# ---------------------------------------------------------------------------
# Baseline: a valid, unreferenced team key passes load validation cleanly.
TEAM_OK="$WORK/team-ok.json"
write_file "$TEAM_OK" "$REG"
team_ok_out="$(resolve_managed "$TEAM_OK" acme-core 2>/dev/null)"; team_ok_rc=$?
assert_eq "team: a valid unreferenced team key loads clean" "$team_ok_rc" "0"

# An UNREFERENCED team whose uid disagrees with its own declared project. No agent
# points at it, so the lazy per-reference path never sees it — only load-time
# validation of ALL team keys catches it. Removing that validation lets the
# registry resolve, turning this assertion red.
TEAM_BAD="$WORK/team-bad.json"
write_file "$TEAM_BAD" '{
  "schema_version": 3,
  "projects": {
    "acme": { "home": "/srv/acme", "standup_dir": "/srv/acme/standup", "mux_session": "acme",
      "provider": "codex", "model": "project-model", "effort": "low" }
  },
  "teams": {
    "zzz-core": { "project": "acme", "model": "team/model-v2" }
  },
  "agents": {
    "acme-core": { "project": "acme", "profile": "engine-dev", "clearance": "t2" }
  }
}'
team_err="$(resolve_managed "$TEAM_BAD" acme-core 2>&1 >/dev/null)"; team_rc=$?
if [ "$team_rc" -ne 0 ]; then ok "team: an invalid unreferenced team key is a loud refusal"; else no "team: an invalid unreferenced team key is a loud refusal (resolved rc=0)"; fi
assert_has "team: the refusal names the inconsistent team uid" "$team_err" "zzz-core"

total=$((pass+fail))
printf '\n%d checks: %d ok / %d fail\n' "$total" "$pass" "$fail"
[ "$fail" -eq 0 ]
