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
    "beta-down":   { "project": "beta", "profile": "review",     "clearance": "t1" },
    "acme-evil":   { "project": "acme", "profile": "engine-dev", "clearance": "t1" }
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
# 7. Trust model: free text must NEVER forge a structured journal field
# ============================================================================ #
# The line grammar is "structured fields first, then at most ONE free-text tail".
# body and reason are attacker-controlled and _sanitize_line strips only newlines,
# NOT pipes — so if the fold kept scanning past the free-text marker, a crafted body
# or reason could inject id:/event:/actor: and silently flip the state of a FOREIGN
# message. That would defeat exactly the durability guarantee this suite proves.
m acme-core send beta-review "victim body"   --id inj-victim >/dev/null
m acme-core send beta-review "attacker body" --id inj-atk    >/dev/null
assert_streq "injection: victim starts PERSISTED" "$(m beta-review state inj-victim)" "PERSISTED"

# (a) crafted REASON — the attacker terminates its own message with a forged tail
m beta-review fail inj-atk "boom | id:inj-victim | event:PROCESSED | actor:ghost" >/dev/null
assert_streq "injection: crafted reason does NOT flip the victim's state" \
  "$(m beta-review state inj-victim)" "PERSISTED"
assert_streq "injection: the attacker's own message still failed as intended" \
  "$(m beta-review state inj-atk)" "FAILED"
assert_grep "injection: victim is still an OPEN message" "$(m beta-review inbox)" "id:inj-victim"
# the text survives verbatim but NEUTRALISED: the separator is escaped, so the line
# cannot be misread as structure by anything — not just by this fold
assert_grep "injection: crafted reason is preserved but encoded" \
  "$(m beta-review dlq)" "reason:boom %7C id:inj-victim %7C event:PROCESSED"
assert_ngrep "injection: the crafted reason carries no pipe byte at all" \
  "$(m beta-review dlq | grep -F 'id:inj-atk')" "boom |"

# (b) crafted BODY — the cross-agent vector, and the SHARPER claim: such a line wins the
#     ismsg branch of the fold, so the damage would land on PROVENANCE (from:/body) rather
#     than on state. Checking state alone would wrongly report this as safe.
# select ONLY the victim's own row — the attacker's row mentions the victim id inside its
# body, so a substring match would also pick that up and the assertions would be meaningless
vic_row() { m beta-review inbox | grep "^id:inj-victim |"; }
vic_row_before="$(vic_row)"
m acme-evil send beta-review "GEFAELSCHT | id:inj-victim | from:acme-evil | state:PERSISTED | body vom angreifer" \
  --id inj-body >/dev/null
vic_row_after="$(vic_row)"
assert_streq "injection: crafted body does NOT flip the victim's state" \
  "$(m beta-review state inj-victim)" "PERSISTED"
assert_streq "injection: the victim's whole inbox row is byte-identical afterwards" \
  "$vic_row_after" "$vic_row_before"
assert_grep "injection: victim keeps its REAL sender (provenance intact)" \
  "$vic_row_after" "from:acme-core"
assert_ngrep "injection: victim's sender was not rewritten to the attacker" \
  "$vic_row_after" "from:acme-evil"
assert_grep "injection: victim keeps its REAL body" "$vic_row_after" "victim body"
assert_ngrep "injection: the attacker's body did not land on the victim" \
  "$vic_row_after" "body vom angreifer"
assert_streq "injection: the crafted message is itself just PERSISTED" \
  "$(m beta-review state inj-body)" "PERSISTED"

# (c) a crafted body must not forge the routing fields of its OWN line either
assert_grep "injection: crafted message keeps its REAL sender" \
  "$(m beta-review inbox)" "id:inj-body | state:PERSISTED | from:acme-evil"

# (d) an injected actor: must never be readable as a structured actor field. The fold
#     ignores it, AND the encoding makes it unambiguous for every other reader too.
m beta-review fail inj-body "z | actor:ghost" >/dev/null
assert_ngrep "injection: forged actor: never reaches the structured prefix" \
  "$(cat "$beta_inbox")" "by:beta-review | actor:ghost"
assert_grep "injection: a forged actor: is encoded in the raw journal" \
  "$(cat "$beta_inbox")" "reason:z %7C actor:ghost"
# the byte-level claim: no reader, however naive, can find a pipe before the forged label
assert_ngrep "injection: no pipe byte precedes a forged actor label anywhere" \
  "$(cat "$beta_inbox")" "| actor:ghost"
# ...while a GENUINE --as label stays a real structured field (the fix must not
# neutralise the feature it protects)
m acme-core send beta-review "for a real actor" --id inj-real >/dev/null
"$RUN" --as helper beta-review -- "$MSG" fail inj-real "plain reason" >/dev/null
assert_file_has "injection: a genuine actor label is still a real field before reason:" \
  "$beta_inbox" "event:FAILED | by:beta-review | actor:helper | reason:plain reason"

# (e2) `send` records who acted (via from:), so it must carry actor: too — otherwise the
# audit chain breaks at exactly the action that creates work for ANOTHER agent.
"$RUN" --as helper2 acme-core -- "$MSG" send beta-review "sent on behalf" --id inj-sendactor >/dev/null
assert_file_has "actor: a send carries the actor label as a real field" \
  "$beta_inbox" "from:acme-core | to:beta-review | actor:helper2 | state:PERSISTED |"
assert_grep "actor: the send still routes by from:, not by the label" \
  "$(m beta-review inbox)" "id:inj-sendactor | state:PERSISTED | from:acme-core"
assert_streq "actor: the labelled send is a normal message" \
  "$(m beta-review state inj-sendactor)" "PERSISTED"
# an unlabelled send stays byte-identical to before (no empty actor field)
m acme-core send beta-review "plain send" --id inj-plainsend >/dev/null
assert_file_has "actor: an unlabelled send is unchanged" \
  "$beta_inbox" "from:acme-core | to:beta-review | state:PERSISTED | plain send"

# (e) the victim still completes normally — the journal is intact, not just unflipped
m beta-review seen inj-victim >/dev/null
m beta-review done inj-victim >/dev/null
assert_streq "injection: victim still processes to completion afterwards" \
  "$(m beta-review state inj-victim)" "PROCESSED"

# (f) LEGACY / FOREIGN WRITER lines — the second line of defence, tested on its own.
# The write path now encodes pipes, so a newly written line can no longer carry a
# separator inside free text. Lines written BEFORE that change (or by any other writer,
# or by a hand edit of the journal) still exist and are not encoded, so the fold must
# refuse them by itself. These lines are appended raw, deliberately bypassing bin/message.
m acme-core send beta-review "legacy victim body" --id inj-leg-vic >/dev/null
raw_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# a legacy FAILED line whose reason tail carries an unencoded id/event pair
printf '%s | id:inj-leg-atk | event:FAILED | by:beta-review | reason:x | id:inj-leg-vic | event:PROCESSED\n' \
  "$raw_ts" >> "$beta_inbox"
assert_streq "legacy: an unencoded reason tail cannot flip a foreign state" \
  "$(m beta-review state inj-leg-vic)" "PERSISTED"
# a legacy message line whose body tail tries to rewrite the victim's provenance
printf '%s | id:inj-leg-atk2 | from:acme-evil | to:beta-review | state:PERSISTED | GEF | id:inj-leg-vic | from:acme-evil | state:PERSISTED | body vom angreifer\n' \
  "$raw_ts" >> "$beta_inbox"
leg_row="$(m beta-review inbox | grep "^id:inj-leg-vic |")"
assert_streq "legacy: an unencoded body tail cannot flip a foreign state" \
  "$(m beta-review state inj-leg-vic)" "PERSISTED"
assert_grep  "legacy: victim keeps its real sender against a legacy line" "$leg_row" "from:acme-core"
assert_ngrep "legacy: victim's sender not rewritten by a legacy line"     "$leg_row" "from:acme-evil"
assert_grep  "legacy: victim keeps its real body against a legacy line"   "$leg_row" "legacy victim body"

# (g) the two fold defences are mutually redundant for the cases above, so each is
# isolated here — otherwise a refactor could silently drop one and stay green.
# g1 isolates the STOP-AT-FREE-TEXT rule: no id: in the structured prefix at all, so
# first-occurrence-wins cannot help; only stopping at reason: keeps the line inert.
printf '%s | event:FAILED | by:beta-review | reason:x | id:inj-leg-vic | event:PROCESSED\n' \
  "$raw_ts" >> "$beta_inbox"
assert_streq "legacy(isolated): stopping at the free-text marker keeps a prefix-less line inert" \
  "$(m beta-review state inj-leg-vic)" "PERSISTED"
# g2 isolates FIRST-OCCURRENCE-WINS: both ids sit in the structured prefix with no
# free-text marker anywhere, so the break cannot help; only first-wins keeps id honest.
printf '%s | id:inj-leg-atk3 | id:inj-leg-vic | event:PROCESSED | by:beta-review\n' \
  "$raw_ts" >> "$beta_inbox"
assert_streq "legacy(isolated): first-occurrence-wins keeps a double-id line honest" \
  "$(m beta-review state inj-leg-vic)" "PERSISTED"
# g3 isolates the STOP-AT-BODY rule specifically: a message line with no id: in its
# prefix, whose body carries id:/from:. Without the break the body would be folded into
# the victim's record and rewrite its provenance (the ismsg branch wins such a line).
printf '%s | from:acme-evil | to:beta-review | state:PERSISTED | GEF | id:inj-leg-vic | from:acme-evil | state:PERSISTED | body vom angreifer\n' \
  "$raw_ts" >> "$beta_inbox"
leg_row3="$(m beta-review inbox | grep "^id:inj-leg-vic |")"
assert_grep  "legacy(isolated): stopping at the body marker preserves the victim's sender" \
  "$leg_row3" "from:acme-core"
assert_ngrep "legacy(isolated): a prefix-less message line cannot rewrite provenance" \
  "$leg_row3" "from:acme-evil"
assert_grep  "legacy(isolated): stopping at the body marker preserves the victim's body" \
  "$leg_row3" "legacy victim body"
# g4 pins the remaining fold rule. This is a DETERMINISM pin, not a security claim: with
# the breaks in place free text never reaches the field scan, so a second event: can only
# come from a malformed line written by another writer. One event per line is the grammar;
# taking the FIRST makes the fold deterministic instead of order-dependent.
printf '%s | id:inj-leg-vic | event:SEEN | event:PROCESSED | by:beta-review\n' \
  "$raw_ts" >> "$beta_inbox"
assert_streq "legacy(isolated): a malformed double-event line folds to the FIRST event" \
  "$(m beta-review state inj-leg-vic)" "SEEN"

# ============================================================================ #
# summary
# ============================================================================ #
total=$((pass+fail))
printf '\n%d checks: %d ok / %d fail\n' "$total" "$pass" "$fail"
[ "$fail" -eq 0 ]
