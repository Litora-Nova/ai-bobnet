#!/usr/bin/env bash
# ai-bobnet — P0 black-box acceptance (CONTRACT §6).
# Proves, against a synthetic engine copy + registry under a temp dir:
#   (a) a fresh agent launched via run-agent can resolve context, log a heartbeat,
#       read its own inbox path, and write to another agent's inbox — deterministically;
#   (b) a poisoned BOOT_* / STANDUP_DIR / AIBOBNET_* ambient env does NOT route the
#       agent into a foreign project (run-agent scrubs it).
# No external deps; uses only the public CLI (black-box). Prints a pass/fail summary.
set -uo pipefail

# --- locate the engine under test (this repo) --------------------------------
SRC_ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)

WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-p0.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
ENGINE="$WORK/engine"
STATE="$WORK/state"
mkdir -p "$ENGINE" "$STATE/acme" "$STATE/beta"

# Copy the engine tree so registry discovery is fully path-based (no env override).
cp -R "$SRC_ROOT/bin" "$SRC_ROOT/scripts" "$SRC_ROOT/lib" "$ENGINE/"

# Synthetic white-label registry (two projects: acme, beta).
cat > "$ENGINE/registry.json" <<JSON
{
  "projects": {
    "acme": { "home": "$STATE/acme", "standup_dir": "$STATE/acme/standup", "mux_session": "acme" },
    "beta": { "home": "$STATE/beta", "standup_dir": "$STATE/beta/standup", "mux_session": "beta" }
  }
}
JSON

CTX="$ENGINE/bin/context"
INBOX="$ENGINE/bin/inbox"
RUN="$ENGINE/bin/run-agent"
LOG="$ENGINE/scripts/log.sh"

# --- tiny assertion harness ---------------------------------------------------
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
no(){ fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; }
assert_ok(){   local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else no "$d (expected success)"; fi; }
assert_fail(){ local d="$1"; shift; if "$@" >/dev/null 2>&1; then no "$d (expected failure)"; else ok "$d"; fi; }
assert_streq(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2' want '$3')"; fi; }
assert_grep(){ if printf '%s\n' "$2" | grep -qF -- "$3"; then ok "$1"; else no "$1 (missing '$3' in: $2)"; fi; }
assert_file_has(){ if grep -qF -- "$3" "$2" 2>/dev/null; then ok "$1"; else no "$1 (missing '$3' in $2)"; fi; }
assert_absent(){ if [ -e "$2" ]; then no "$1 ($2 exists)"; else ok "$1"; fi; }

# ============================================================================ #
# 1. context resolves deterministically for a known agent
# ============================================================================ #
out="$(AIBOBNET_PROJECT_UID=acme AIBOBNET_TASK=core "$CTX" 2>/dev/null)"
assert_grep "context: agent_uid derived"      "$out" "agent_uid=acme-core"
assert_grep "context: standup_dir from registry" "$out" "standup_dir=$STATE/acme/standup"
assert_grep "context: inbox_path per agent"   "$out" "inbox_path=$STATE/acme/standup/inbox/acme-core.md"
assert_grep "context: mux_session from registry" "$out" "mux_session=acme"

json="$(AIBOBNET_PROJECT_UID=acme AIBOBNET_TASK=core "$CTX" --json 2>/dev/null)"
assert_grep "context --json: emits agent_uid" "$json" '"agent_uid":"acme-core"'

# ============================================================================ #
# 2. context fail-closed: missing / unknown / inconsistent
# ============================================================================ #
assert_fail "context: missing PROJECT_UID -> non-zero" \
  env -u AIBOBNET_PROJECT_UID AIBOBNET_TASK=core "$CTX"
assert_fail "context: missing TASK -> non-zero" \
  env AIBOBNET_PROJECT_UID=acme -u AIBOBNET_TASK "$CTX"
assert_fail "context: unknown project -> non-zero" \
  env AIBOBNET_PROJECT_UID=ghost AIBOBNET_TASK=core "$CTX"
assert_fail "context: inconsistent AGENT_UID -> non-zero" \
  env AIBOBNET_PROJECT_UID=acme AIBOBNET_TASK=core AIBOBNET_AGENT_UID=beta-core "$CTX"

# ============================================================================ #
# 3. inbox: deterministic recipient path; fail-closed on unknown
# ============================================================================ #
got="$("$INBOX" acme-core 2>/dev/null)"
assert_streq "inbox: acme-core path" "$got" "$STATE/acme/standup/inbox/acme-core.md"
got="$("$INBOX" beta-review 2>/dev/null)"
assert_streq "inbox: beta-review path" "$got" "$STATE/beta/standup/inbox/beta-review.md"
assert_fail "inbox: unknown project -> non-zero"  "$INBOX" ghost-review
assert_fail "inbox: malformed agent_uid -> non-zero" "$INBOX" "no-good/../etc"
assert_fail "inbox: missing arg -> non-zero" "$INBOX"

# ============================================================================ #
# 4. ACCEPTANCE (positive): a fresh agent via run-agent does the full loop
# ============================================================================ #
export ENGINE
acc="$("$RUN" acme-core -- bash -c '
  set -eu
  "$ENGINE/bin/context" >/dev/null                                   # (1) resolve
  "$ENGINE/scripts/log.sh" "$AIBOBNET_AGENT_UID" busy "hello from acme-core"  # (2) heartbeat
  mine="$AIBOBNET_INBOX_PATH"                                        # (3) own inbox
  to="$("$ENGINE/bin/inbox" beta-review)"                            # (4) message another
  mkdir -p "$(dirname "$to")"
  printf "%s | from:%s | %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$AIBOBNET_AGENT_UID" "ping" >> "$to"
  printf "MINE=%s\nTO=%s\n" "$mine" "$to"
' 2>/dev/null)"
assert_grep "acceptance: own inbox_path exported" "$acc" "MINE=$STATE/acme/standup/inbox/acme-core.md"
assert_grep "acceptance: recipient path resolved" "$acc" "TO=$STATE/beta/standup/inbox/beta-review.md"
assert_file_has "acceptance: heartbeat logged to own standup" \
  "$STATE/acme/standup/acme-core.log" "acme-core | busy"
assert_file_has "acceptance: message landed in recipient inbox with real 'from' field" \
  "$STATE/beta/standup/inbox/beta-review.md" "from:acme-core"

# ============================================================================ #
# 5. ACCEPTANCE (negative): poisoned ambient env must NOT route into a foreign project
# ============================================================================ #
# Poison the environment as if leaked from a 'beta' session, then launch acme-core.
poison_out="$(
  BOOT_STANDUP="/evil/boot" \
  STANDUP_DIR="$STATE/beta/standup" \
  INBOX_PATH="/evil/inbox" \
  MUX_SESSION="beta" \
  PROJECT_HOME="/evil/home" \
  AIBOBNET_PROJECT_UID="beta" \
  AIBOBNET_TASK="review" \
  AIBOBNET_STANDUP_DIR="$STATE/beta/standup" \
  "$RUN" acme-core -- bash -c '
    printf "PROJ=%s\nSTANDUP=%s\nTASK=%s\nRAW_STANDUP=%s\nBOOT=%s\n" \
      "$AIBOBNET_PROJECT_UID" "$AIBOBNET_STANDUP_DIR" "$AIBOBNET_TASK" \
      "${STANDUP_DIR:-<unset>}" "${BOOT_STANDUP:-<unset>}"
  ' 2>/dev/null
)"
assert_grep "negative: routed to acme project (not beta)"     "$poison_out" "PROJ=acme"
assert_grep "negative: standup_dir is acme's (not foreign)"   "$poison_out" "STANDUP=$STATE/acme/standup"
assert_grep "negative: task is core (not leaked 'review')"    "$poison_out" "TASK=core"
assert_grep "negative: raw STANDUP_DIR re-exported to acme's" "$poison_out" "RAW_STANDUP=$STATE/acme/standup"
assert_grep "negative: BOOT_* scrubbed"                       "$poison_out" "BOOT=<unset>"

# And a heartbeat under poison lands in acme, never beta.
BOOT_STANDUP="/evil/boot" STANDUP_DIR="$STATE/beta/standup" \
AIBOBNET_PROJECT_UID="beta" AIBOBNET_TASK="review" \
  "$RUN" acme-core -- bash -c '"$ENGINE/scripts/log.sh" "$AIBOBNET_AGENT_UID" idle "poison test"' >/dev/null 2>&1
assert_file_has "negative: heartbeat under poison landed in acme" \
  "$STATE/acme/standup/acme-core.log" "acme-core | idle"
assert_absent  "negative: no acme-core log leaked into beta standup" \
  "$STATE/beta/standup/acme-core.log"

# ============================================================================ #
# 6. log.sh fail-loud
# ============================================================================ #
assert_fail "log: unknown project -> non-zero" "$LOG" ghost-core busy "x"
assert_absent "log: unknown project created no dir" "$STATE/../ghost"
assert_fail "log: bad status -> non-zero"      "$LOG" acme-core wat "x"
assert_fail "log: missing args -> non-zero"    "$LOG" acme-core busy

# ============================================================================ #
# summary
# ============================================================================ #
total=$((pass+fail))
printf '\n%d checks: %d ok / %d fail\n' "$total" "$pass" "$fail"
[ "$fail" -eq 0 ]
