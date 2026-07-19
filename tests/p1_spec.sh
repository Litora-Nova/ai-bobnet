#!/usr/bin/env bash
# ai-bobnet — P1 black-box acceptance (CONTRACT-delivery.md §9).
# Proves, against a synthetic engine copy + white-label registry (acme, beta) under a temp dir,
# and driving ONLY the public CLI launched via bin/run-agent:
#   1. Full state progression: send -> PERSISTED -> NOTIFIED -> SEEN -> PROCESSED, observable at each step.
#   2. Idempotency: double-send (same id) = one message; double-done = no error / no effect.
#   3. Replay: a "restarted" recipient recovers exactly the unprocessed messages, in order.
#   4. Dead-letter: a FAILED message surfaces in dlq, not in inbox, and is not re-notified endlessly.
#   5. Cross-target: deliver to another project's agent while it is down; nothing lost on restart.
#   6. Fail-closed / fail-loud (per P0): unknown recipient, unknown id, bad args.
# Pure bash/awk; no external deps. Prints a pass/fail summary.
set -uo pipefail

# --- locate the engine under test (this repo) --------------------------------
SRC_ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)

WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-p1.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
ENGINE="$WORK/engine"
STATE="$WORK/state"
mkdir -p "$ENGINE" "$STATE/acme" "$STATE/beta"

# Copy the engine tree so registry discovery is fully path-based (no env override).
cp -R "$SRC_ROOT/bin" "$SRC_ROOT/scripts" "$SRC_ROOT/lib" "$ENGINE/"

# Synthetic white-label registry (two projects: acme, beta).
# Since P0.5 an Agent is a registry object: every uid driven below must be declared here.
cat > "$ENGINE/registry.json" <<JSON
{
  "schema_version": 2,
  "projects": {
    "acme": { "home": "$STATE/acme", "standup_dir": "$STATE/acme/standup", "mux_session": "acme" },
    "beta": { "home": "$STATE/beta", "standup_dir": "$STATE/beta/standup", "mux_session": "beta" }
  },
  "agents": {
    "acme-core":   { "project": "acme", "profile": "engine-dev", "clearance": "t2" },
    "beta-review": { "project": "beta", "profile": "review",     "clearance": "t1" },
    "beta-replay": { "project": "beta", "profile": "review",     "clearance": "t1" },
    "beta-dlq":    { "project": "beta", "profile": "review",     "clearance": "t1" },
    "beta-down":   { "project": "beta", "profile": "review",     "clearance": "t1" }
  }
}
JSON

RUN="$ENGINE/bin/run-agent"
MSG="$ENGINE/bin/message"

# Drive `bin/message` as a given agent, each call a fresh (scrubbed, re-resolved) process
# — i.e. every invocation is itself a "restart" proving the file journal is the only state.
m() { local agent="$1"; shift; "$RUN" "$agent" -- "$MSG" "$@"; }

beta_inbox="$STATE/beta/standup/inbox/beta-review.md"

# --- tiny assertion harness (same style as tests/p0_spec.sh) ------------------
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
no(){ fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; }
assert_ok(){   local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else no "$d (expected success)"; fi; }
assert_fail(){ local d="$1"; shift; if "$@" >/dev/null 2>&1; then no "$d (expected failure)"; else ok "$d"; fi; }
assert_streq(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2' want '$3')"; fi; }
assert_grep(){ if printf '%s\n' "$2" | grep -qF -- "$3"; then ok "$1"; else no "$1 (missing '$3' in: $2)"; fi; }
assert_ngrep(){ if printf '%s\n' "$2" | grep -qF -- "$3"; then no "$1 (unexpected '$3' in: $2)"; else ok "$1"; fi; }
assert_file_has(){ if grep -qF -- "$3" "$2" 2>/dev/null; then ok "$1"; else no "$1 (missing '$3' in $2)"; fi; }
# count message (PERSISTED) lines for an id in a journal file
count_persisted(){ grep -F "id:$1 " "$2" 2>/dev/null | grep -c "state:PERSISTED"; }
# first 1-based line index of an id in a captured listing (0 if absent)
pos_of(){ printf '%s\n' "$2" | grep -nF "id:$1 " | head -1 | cut -d: -f1; }

# ============================================================================ #
# 1. Full state progression (cross-target: acme-core -> beta-review), observable
# ============================================================================ #
id1="$(m acme-core send beta-review "please review PR 7")"
assert_grep "progression: send prints an id" "$id1" "msg-"
assert_streq "progression: PERSISTED after send"  "$(m beta-review state "$id1")" "PERSISTED"
# message line format EXACTLY per §2
assert_file_has "progression: message line has real from/to/state fields" \
  "$beta_inbox" "from:acme-core | to:beta-review | state:PERSISTED |"
# message appears in recipient's OPEN inbox
assert_grep "progression: message shows in recipient inbox" "$(m beta-review inbox)" "id:$id1"

m acme-core notify beta-review "$id1" >/dev/null
assert_streq "progression: NOTIFIED after notify" "$(m beta-review state "$id1")" "NOTIFIED"
assert_file_has "progression: NOTIFIED event line format" "$beta_inbox" "event:NOTIFIED | by:acme-core"

m beta-review seen "$id1" >/dev/null
assert_streq "progression: SEEN after seen" "$(m beta-review state "$id1")" "SEEN"
assert_file_has "progression: SEEN event carries by=recipient" "$beta_inbox" "event:SEEN | by:beta-review"

m beta-review done "$id1" >/dev/null
assert_streq "progression: PROCESSED after done" "$(m beta-review state "$id1")" "PROCESSED"
# terminal message no longer OPEN in inbox
assert_ngrep "progression: PROCESSED message leaves the open inbox" "$(m beta-review inbox)" "id:$id1"

# ============================================================================ #
# 2. Idempotency: double-send (same id) = one message; double-done = no-op
# ============================================================================ #
first="$(m acme-core send beta-review "dup body" --id acme-dup-1)"
assert_streq "idempotency: send honors explicit --id" "$first" "acme-dup-1"
again="$(m acme-core send beta-review "should NOT append again" --id acme-dup-1)"
assert_streq "idempotency: re-send returns same id (no-op)" "$again" "acme-dup-1"
assert_streq "idempotency: exactly one PERSISTED line for the id" "$(count_persisted acme-dup-1 "$beta_inbox")" "1"

m beta-review seen acme-dup-1 >/dev/null
m beta-review done acme-dup-1 >/dev/null
assert_ok   "idempotency: double-done exits 0 (no error)" m beta-review done acme-dup-1
assert_streq "idempotency: double-done leaves state PROCESSED" "$(m beta-review state acme-dup-1)" "PROCESSED"
assert_streq "idempotency: only one PROCESSED event recorded" \
  "$(grep -cF "id:acme-dup-1 | event:PROCESSED" "$beta_inbox")" "1"

# ============================================================================ #
# 3. Replay: a restarted recipient recovers exactly the unprocessed msgs, in order
# ============================================================================ #
r1="$(m acme-core send beta-replay "first"  --id rp-1)"
r2="$(m acme-core send beta-replay "second" --id rp-2)"
r3="$(m acme-core send beta-replay "third"  --id rp-3)"
m beta-replay done rp-1 >/dev/null          # rp-1 processed
m beta-replay seen rp-2 >/dev/null          # rp-2 claimed but NOT processed (must still replay)
replay_out="$(m beta-replay replay)"        # fresh process == a restart
assert_ngrep "replay: processed message is not replayed"        "$replay_out" "id:rp-1"
assert_grep  "replay: claimed-but-unprocessed message recovers" "$replay_out" "id:rp-2"
assert_grep  "replay: never-touched message recovers"           "$replay_out" "id:rp-3"
p2="$(pos_of rp-2 "$replay_out")"; p3="$(pos_of rp-3 "$replay_out")"
if [ -n "$p2" ] && [ -n "$p3" ] && [ "$p2" -lt "$p3" ]; then
  ok "replay: messages come back in arrival order"
else no "replay: order wrong (rp-2@$p2 rp-3@$p3)"; fi

# ============================================================================ #
# 4. Dead-letter: FAILED surfaces in dlq, not inbox, and is not re-notified endlessly
# ============================================================================ #
d1="$(m acme-core send beta-dlq "this one fails" --id dl-1)"
m beta-dlq fail dl-1 "downstream unavailable" >/dev/null
assert_streq "dlq: FAILED is terminal state" "$(m beta-dlq state dl-1)" "FAILED"
dlq_out="$(m beta-dlq dlq)"
assert_grep "dlq: failed message surfaces in dlq"        "$dlq_out" "id:dl-1"
assert_grep "dlq: dlq shows the failure reason"          "$dlq_out" "downstream unavailable"
assert_ngrep "dlq: failed message is NOT in open inbox"  "$(m beta-dlq inbox)" "id:dl-1"
# not re-notified endlessly: notify on a terminal message is a no-op, state unchanged
assert_ok   "dlq: re-notify of a failed message is a no-op (exit 0)" m acme-core notify beta-dlq dl-1
assert_streq "dlq: state still FAILED after attempted re-notify" "$(m beta-dlq state dl-1)" "FAILED"
dlq_beta="$STATE/beta/standup/inbox/beta-dlq.md"
assert_streq "dlq: no NOTIFIED event was ever appended after fail" \
  "$(grep -cF "id:dl-1 | event:NOTIFIED" "$dlq_beta" 2>/dev/null || true)" "0"

# ============================================================================ #
# 5. Cross-target while recipient is DOWN — durable, nothing lost on restart
# ============================================================================ #
# beta-down has never been launched: send must still persist to its journal file.
down_id="$(m acme-core send beta-down "urgent: handle on wakeup" --id cd-1)"
down_inbox="$STATE/beta/standup/inbox/beta-down.md"
assert_file_has "cross-target: persisted durably though recipient was down" "$down_inbox" "id:cd-1"
# recipient "boots" for the first time and recovers the message via replay
assert_grep "cross-target: down recipient recovers message on first boot" \
  "$(m beta-down replay)" "id:cd-1"
m beta-down seen cd-1 >/dev/null
m beta-down done cd-1 >/dev/null
assert_streq "cross-target: recovered message processes to completion" \
  "$(m beta-down state cd-1)" "PROCESSED"

# ============================================================================ #
# 6. Fail-closed / fail-loud (per P0)
# ============================================================================ #
assert_fail "failclosed: send to unknown recipient -> non-zero" m acme-core send ghost-review "x"
assert_fail "failclosed: send with no body -> non-zero"         m acme-core send beta-review
assert_fail "failclosed: send with malformed --id -> non-zero"  m acme-core send beta-review "x" --id "bad id"
assert_fail "failclosed: no subcommand -> non-zero"             m acme-core
assert_fail "failclosed: unknown subcommand -> non-zero"        m acme-core bogus
assert_fail "failclosed: state of unknown id -> non-zero"       m beta-review state no-such-id
assert_fail "failclosed: seen of unknown id -> non-zero"        m beta-review seen no-such-id
# context must come from the resolver, never a leaked ambient var (P0 canon):
assert_fail "failclosed: message without resolvable context -> non-zero" \
  env -u AIBOBNET_PROJECT_UID -u AIBOBNET_AGENT_KEY "$MSG" inbox

# ============================================================================ #
# summary
# ============================================================================ #
total=$((pass+fail))
printf '\n%d checks: %d ok / %d fail\n' "$total" "$pass" "$fail"
[ "$fail" -eq 0 ]
