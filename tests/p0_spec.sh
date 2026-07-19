#!/usr/bin/env bash
# ai-bobnet — P0/P0.5 black-box acceptance (CONTRACT §6, §1, §4.1).
# Proves, against a synthetic engine copy + registry under a temp dir:
#   (a) a fresh agent launched via run-agent can resolve context, log a heartbeat,
#       read its own inbox path, and write to another agent's inbox — deterministically;
#   (b) a poisoned BOOT_* / STANDUP_DIR / AIBOBNET_* ambient env does NOT route the
#       agent into a foreign project (run-agent scrubs it);
#   (c) P0.5 identity: the Agent is a REGISTRY OBJECT — lookup is the authority,
#       an unregistered uid is fail-closed through every consumer, no prefix guessing,
#       clearance rides on the agent object (not the profile), and `--as` is an actor
#       label on behalf of a parent agent rather than a new identity.
# No external deps; uses only the public CLI (black-box). Prints a pass/fail summary.
set -uo pipefail

# --- locate the engine under test (this repo) --------------------------------
SRC_ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)

WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-p0.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
ENGINE="$WORK/engine"
STATE="$WORK/state"
mkdir -p "$ENGINE" "$STATE/acme" "$STATE/beta" "$STATE/acmecore"

# Copy the engine tree so registry discovery is fully path-based (no env override).
cp -R "$SRC_ROOT/bin" "$SRC_ROOT/scripts" "$SRC_ROOT/lib" "$ENGINE/"

# Synthetic white-label registry (schema_version 2).
# Projects `acme` AND `acme-core` coexist on purpose: under the old prefix-scan this
# was the ambiguity case. The agent object names its project, so it is now decidable.
# The acme-core profile is a parameter so a profile swap can be tested in isolation.
write_registry() {
  local core_profile="${1:-engine-dev}"
  cat > "$ENGINE/registry.json" <<JSON
{
  "schema_version": 2,
  "projects": {
    "acme":      { "home": "$STATE/acme",     "standup_dir": "$STATE/acme/standup",     "mux_session": "acme" },
    "acme-core": { "home": "$STATE/acmecore", "standup_dir": "$STATE/acmecore/standup", "mux_session": "acme-core" },
    "beta":      { "home": "$STATE/beta",     "standup_dir": "$STATE/beta/standup",     "mux_session": "beta" }
  },
  "agents": {
    "acme-core":        { "project": "acme",      "profile": "$core_profile", "clearance": "t2", "display_name": "Core Bob" },
    "acme-tests":       { "project": "acme",      "profile": "tests",         "clearance": "t1" },
    "beta-review":      { "project": "beta",      "profile": "review",        "clearance": "t1" },
    "acme-core-review": { "project": "acme-core", "profile": "review",        "clearance": "t1" }
  }
}
JSON
}
write_registry

CTX="$ENGINE/bin/context"
INBOX="$ENGINE/bin/inbox"
RUN="$ENGINE/bin/run-agent"
LOG="$ENGINE/scripts/log.sh"
WAKE="$ENGINE/bin/wakeup"
MEM="$ENGINE/bin/memory"

# --- tiny assertion harness ---------------------------------------------------
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
no(){ fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; }
assert_ok(){   local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else no "$d (expected success)"; fi; }
assert_fail(){ local d="$1"; shift; if "$@" >/dev/null 2>&1; then no "$d (expected failure)"; else ok "$d"; fi; }
assert_streq(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2' want '$3')"; fi; }
assert_grep(){ if printf '%s\n' "$2" | grep -qF -- "$3"; then ok "$1"; else no "$1 (missing '$3' in: $2)"; fi; }
assert_ngrep(){ if printf '%s\n' "$2" | grep -qF -- "$3"; then no "$1 (unexpected '$3' in: $2)"; else ok "$1"; fi; }
assert_file_has(){ if grep -qF -- "$3" "$2" 2>/dev/null; then ok "$1"; else no "$1 (missing '$3' in $2)"; fi; }
assert_absent(){ if [ -e "$2" ]; then no "$1 ($2 exists)"; else ok "$1"; fi; }
# run a command, capture rc only
rc_of(){ "$@" >/dev/null 2>&1; printf '%s' "$?"; }

# ============================================================================ #
# 1. context resolves deterministically for a known agent
# ============================================================================ #
out="$(AIBOBNET_PROJECT_UID=acme AIBOBNET_AGENT_KEY=core "$CTX" 2>/dev/null)"
assert_grep "context: agent_uid derived"      "$out" "agent_uid=acme-core"
assert_grep "context: standup_dir from registry" "$out" "standup_dir=$STATE/acme/standup"
assert_grep "context: inbox_path per agent"   "$out" "inbox_path=$STATE/acme/standup/inbox/acme-core.md"
assert_grep "context: mux_session from registry" "$out" "mux_session=acme"

json="$(AIBOBNET_PROJECT_UID=acme AIBOBNET_AGENT_KEY=core "$CTX" --json 2>/dev/null)"
assert_grep "context --json: emits agent_uid" "$json" '"agent_uid":"acme-core"'

# P0.5 (1): the identity token is agent_key — `task` is gone from the resolver surface.
assert_grep  "rename: context text emits agent_key"  "$out"  "agent_key=core"
assert_ngrep "rename: context text has no task field" "$out"  "task="
assert_grep  "rename: context --json emits agent_key" "$json" '"agent_key":"core"'
assert_ngrep "rename: context --json has no task key" "$json" '"task"'

# ============================================================================ #
# 2. context fail-closed: missing / unknown / inconsistent
# ============================================================================ #
assert_fail "context: missing PROJECT_UID -> non-zero" \
  env -u AIBOBNET_PROJECT_UID AIBOBNET_AGENT_KEY=core "$CTX"
assert_fail "context: missing AGENT_KEY -> non-zero" \
  env AIBOBNET_PROJECT_UID=acme -u AIBOBNET_AGENT_KEY "$CTX"
assert_fail "context: unknown project -> non-zero" \
  env AIBOBNET_PROJECT_UID=ghost AIBOBNET_AGENT_KEY=core "$CTX"
assert_fail "context: inconsistent AGENT_UID -> non-zero" \
  env AIBOBNET_PROJECT_UID=acme AIBOBNET_AGENT_KEY=core AIBOBNET_AGENT_UID=beta-core "$CTX"
# P0.5: a registered project + a well-formed key is NOT enough — the agent must exist.
assert_fail "context: unregistered agent -> non-zero (prefix parsing is not enough)" \
  env AIBOBNET_PROJECT_UID=acme AIBOBNET_AGENT_KEY=ghost "$CTX"

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
  AIBOBNET_AGENT_KEY="review" \
  AIBOBNET_ACTOR="evil-actor" \
  AIBOBNET_STANDUP_DIR="$STATE/beta/standup" \
  "$RUN" acme-core -- bash -c '
    printf "PROJ=%s\nSTANDUP=%s\nKEY=%s\nRAW_STANDUP=%s\nBOOT=%s\nACTOR=%s\n" \
      "$AIBOBNET_PROJECT_UID" "$AIBOBNET_STANDUP_DIR" "$AIBOBNET_AGENT_KEY" \
      "${STANDUP_DIR:-<unset>}" "${BOOT_STANDUP:-<unset>}" "${AIBOBNET_ACTOR:-<unset>}"
  ' 2>/dev/null
)"
assert_grep "negative: routed to acme project (not beta)"       "$poison_out" "PROJ=acme"
assert_grep "negative: standup_dir is acme's (not foreign)"     "$poison_out" "STANDUP=$STATE/acme/standup"
assert_grep "negative: agent_key is core (not leaked 'review')" "$poison_out" "KEY=core"
assert_grep "negative: raw STANDUP_DIR re-exported to acme's"   "$poison_out" "RAW_STANDUP=$STATE/acme/standup"
assert_grep "negative: BOOT_* scrubbed"                         "$poison_out" "BOOT=<unset>"
assert_grep "negative: ambient AIBOBNET_ACTOR scrubbed (no self-declared actor)" \
  "$poison_out" "ACTOR=<unset>"

# And a heartbeat under poison lands in acme, never beta.
BOOT_STANDUP="/evil/boot" STANDUP_DIR="$STATE/beta/standup" \
AIBOBNET_PROJECT_UID="beta" AIBOBNET_AGENT_KEY="review" \
  "$RUN" acme-core -- bash -c '"$ENGINE/scripts/log.sh" "$AIBOBNET_AGENT_UID" idle "poison test"' >/dev/null 2>&1
assert_file_has "negative: heartbeat under poison landed in acme" \
  "$STATE/acme/standup/acme-core.log" "acme-core | idle"
assert_absent  "negative: no acme-core log leaked into beta standup" \
  "$STATE/beta/standup/acme-core.log"

# A poisoned AIBOBNET_REGISTRY must NOT become the resolution authority (scrub precedes resolve).
cat > "$WORK/evil-registry.json" <<JSON
{
  "schema_version": 2,
  "projects": { "acme": { "home": "/evil/home", "standup_dir": "/evil/standup", "mux_session": "evil" } },
  "agents":   { "acme-core": { "project": "acme", "profile": "engine-dev", "clearance": "t4" } }
}
JSON
reg_poison_out="$(
  AIBOBNET_REGISTRY="$WORK/evil-registry.json" \
    "$RUN" acme-core -- bash -c 'printf "STANDUP=%s\nHOME=%s\nCLEAR=%s\n" \
      "$AIBOBNET_STANDUP_DIR" "$AIBOBNET_HOME" "$AIBOBNET_CLEARANCE"' 2>/dev/null
)"
assert_grep "negative: AIBOBNET_REGISTRY poison ignored — canonical acme standup" "$reg_poison_out" "STANDUP=$STATE/acme/standup"
assert_grep "negative: AIBOBNET_REGISTRY poison ignored — canonical acme home"    "$reg_poison_out" "HOME=$STATE/acme"
assert_grep "negative: a foreign registry cannot elevate clearance (t2, not t4)"  "$reg_poison_out" "CLEAR=t2"

# ============================================================================ #
# 6. log.sh fail-loud
# ============================================================================ #
assert_fail "log: unknown project -> non-zero" "$LOG" ghost-core busy "x"
assert_absent "log: unknown project created no dir" "$STATE/../ghost"
assert_fail "log: bad status -> non-zero"      "$LOG" acme-core wat "x"
assert_fail "log: missing args -> non-zero"    "$LOG" acme-core busy

# ============================================================================ #
# 7. P0.5 — agent_key rename is visible in the launcher's exported env
# ============================================================================ #
key_env="$("$RUN" acme-core -- bash -c '
  printf "KEY=%s\nUID=%s\nPROFILE=%s\nCLEAR=%s\nTASK=%s\n" \
    "$AIBOBNET_AGENT_KEY" "$AIBOBNET_AGENT_UID" "$AIBOBNET_PROFILE" \
    "$AIBOBNET_CLEARANCE" "${AIBOBNET_TASK:-<unset>}"' 2>/dev/null)"
assert_grep "rename: run-agent exports AIBOBNET_AGENT_KEY" "$key_env" "KEY=core"
assert_grep "rename: AIBOBNET_TASK no longer exists"       "$key_env" "TASK=<unset>"
assert_grep "registry: profile exported from the agent object"   "$key_env" "PROFILE=engine-dev"
assert_grep "registry: clearance exported from the agent object" "$key_env" "CLEAR=t2"

# ============================================================================ #
# 8. P0.5 — FAIL-CLOSED: a prefix that parses is NOT an identity
# ============================================================================ #
# `acme-ghost` parses cleanly (registered project + valid key) but is not an agent
# object. The lookup must bite through EVERY consumer, not just one.
assert_fail "failclosed(run-agent): unregistered agent refuses to launch" \
  "$RUN" acme-ghost -- true
assert_fail "failclosed(log.sh): unregistered agent cannot heartbeat" \
  "$LOG" acme-ghost busy "should not log"
assert_absent "failclosed(log.sh): no heartbeat file was created" \
  "$STATE/acme/standup/acme-ghost.log"
assert_fail "failclosed(inbox): unregistered agent has no inbox path" \
  "$INBOX" acme-ghost
assert_fail "failclosed(wakeup): unregistered target refuses" \
  "$RUN" acme-core -- "$WAKE" acme-ghost
assert_fail "failclosed(memory): unregistered agent cannot resolve its own scope" \
  env AIBOBNET_PROJECT_UID=acme AIBOBNET_AGENT_KEY=ghost "$MEM" recall
# the error names the cause, so a fresh agent needs no research
err="$("$RUN" acme-ghost -- true 2>&1 >/dev/null)"
assert_grep "failclosed: the message says why" "$err" "unknown agent_uid 'acme-ghost'"

# ============================================================================ #
# 9. P0.5 — NO PREFIX GUESSING: the agent object names its project
# ============================================================================ #
# `acme-core-review` could be acme/core-review or acme-core/review; both projects are
# registered. The registry says acme-core, so there is no ambiguity to refuse.
amb="$("$RUN" acme-core-review -- bash -c '
  printf "PROJ=%s\nKEY=%s\nSTANDUP=%s\n" \
    "$AIBOBNET_PROJECT_UID" "$AIBOBNET_AGENT_KEY" "$AIBOBNET_STANDUP_DIR"' 2>/dev/null)"
assert_grep "no-guessing: resolves to the declared project acme-core" "$amb" "PROJ=acme-core"
assert_grep "no-guessing: agent_key is review (not core-review)"      "$amb" "KEY=review"
assert_grep "no-guessing: routed to the acme-core standup dir"        "$amb" "STANDUP=$STATE/acmecore/standup"
# and the sibling uid still belongs to plain acme — one prefix, two owners, no collision
sib="$("$RUN" acme-core -- bash -c 'printf "PROJ=%s\n" "$AIBOBNET_PROJECT_UID"' 2>/dev/null)"
assert_grep "no-guessing: sibling acme-core still belongs to acme" "$sib" "PROJ=acme"

# ============================================================================ #
# 10. P0.5 — registry inconsistency dies with exit 5
# ============================================================================ #
# agent `acme-core` declaring project `beta`: the uid cannot carry beta's prefix.
BAD_REG="$WORK/inconsistent-registry.json"
cat > "$BAD_REG" <<JSON
{
  "schema_version": 2,
  "projects": {
    "acme": { "home": "$STATE/acme", "standup_dir": "$STATE/acme/standup", "mux_session": "acme" },
    "beta": { "home": "$STATE/beta", "standup_dir": "$STATE/beta/standup", "mux_session": "beta" }
  },
  "agents": { "acme-core": { "project": "beta", "profile": "review", "clearance": "t1" } }
}
JSON
# (driven through bin/inbox: run-agent scrubs AIBOBNET_REGISTRY by design)
assert_streq "inconsistent: agent_uid vs declared project -> exit 5" \
  "$(rc_of env AIBOBNET_REGISTRY="$BAD_REG" "$INBOX" acme-core)" "5"
bad_err="$(AIBOBNET_REGISTRY="$BAD_REG" "$INBOX" acme-core 2>&1 >/dev/null)"
assert_grep "inconsistent: the message names the mismatch" "$bad_err" "registry inconsistent"
# an agent naming a project that does not exist at all is a lookup failure, not a parse
UNKNOWN_PROJ_REG="$WORK/unknown-project-registry.json"
cat > "$UNKNOWN_PROJ_REG" <<JSON
{
  "schema_version": 2,
  "projects": { "acme": { "home": "$STATE/acme", "standup_dir": "$STATE/acme/standup", "mux_session": "acme" } },
  "agents":   { "acme-core": { "project": "ghost", "profile": "review", "clearance": "t1" } }
}
JSON
assert_streq "inconsistent: agent naming an unregistered project -> exit 3" \
  "$(rc_of env AIBOBNET_REGISTRY="$UNKNOWN_PROJ_REG" "$INBOX" acme-core)" "3"

# ============================================================================ #
# 11. P0.5 — clearance rides on the AGENT, never on the mutable profile
# ============================================================================ #
before="$("$RUN" acme-core -- bash -c 'printf "%s %s" "$AIBOBNET_PROFILE" "$AIBOBNET_CLEARANCE"' 2>/dev/null)"
assert_streq "clearance: baseline profile+clearance" "$before" "engine-dev t2"
write_registry "release-manager"          # a profile swap, nothing else
after="$("$RUN" acme-core -- bash -c 'printf "%s %s" "$AIBOBNET_PROFILE" "$AIBOBNET_CLEARANCE"' 2>/dev/null)"
assert_streq "clearance: profile really changed" "${after%% *}" "release-manager"
assert_streq "clearance: swapping the profile does NOT change clearance" "${after##* }" "t2"
write_registry                            # restore
# a profile swap must not move the routing key or the inbox either
after_uid="$("$RUN" acme-core -- bash -c 'printf "%s|%s" "$AIBOBNET_AGENT_UID" "$AIBOBNET_INBOX_PATH"' 2>/dev/null)"
assert_streq "clearance: routing key + inbox survive a profile swap" \
  "$after_uid" "acme-core|$STATE/acme/standup/inbox/acme-core.md"
# a missing clearance is fail-closed, never an empty default
NO_CLEAR_REG="$WORK/no-clearance-registry.json"
cat > "$NO_CLEAR_REG" <<JSON
{
  "schema_version": 2,
  "projects": { "acme": { "home": "$STATE/acme", "standup_dir": "$STATE/acme/standup", "mux_session": "acme" } },
  "agents":   { "acme-core": { "project": "acme", "profile": "engine-dev" } }
}
JSON
assert_fail "clearance: an agent object without clearance is refused" \
  env AIBOBNET_REGISTRY="$NO_CLEAR_REG" "$INBOX" acme-core

# ============================================================================ #
# 12. P0.5 — `--as`: an actor label acts on behalf of a parent, it is not an identity
# ============================================================================ #
as_out="$("$RUN" --as helper-7 acme-core -- bash -c '
  printf "UID=%s\nPROJ=%s\nINBOX=%s\nACTOR=%s\nCLEAR=%s\n" \
    "$AIBOBNET_AGENT_UID" "$AIBOBNET_PROJECT_UID" "$AIBOBNET_INBOX_PATH" \
    "$AIBOBNET_ACTOR" "$AIBOBNET_CLEARANCE"' 2>/dev/null)"
assert_grep "as: routing identity stays the PARENT agent_uid" "$as_out" "UID=acme-core"
assert_grep "as: project stays the parent's"                  "$as_out" "PROJ=acme"
assert_grep "as: inbox stays the parent's"                    "$as_out" "INBOX=$STATE/acme/standup/inbox/acme-core.md"
assert_grep "as: the actor label is exported for audit"       "$as_out" "ACTOR=helper-7"
assert_grep "as: clearance is inherited from the parent"      "$as_out" "CLEAR=t2"
# the standup file is the parent's — a helper never opens a second heartbeat stream
"$RUN" --as helper-7 acme-core -- "$LOG" acme-core busy "on behalf of" >/dev/null 2>&1
assert_file_has "as: heartbeat lands in the PARENT's standup file" \
  "$STATE/acme/standup/acme-core.log" "acme-core | busy | on behalf of"
assert_absent "as: the label created no standup file of its own" \
  "$STATE/acme/standup/helper-7.log"
# there is no flag that raises clearance: --as cannot mint a new, higher identity
assert_fail "as: an actor label is not an agent_uid (no new identity)" \
  "$RUN" --as helper-7 helper-7 -- true

# ============================================================================ #
# 13. P0.5 — an actor label can never inject a journal field
# ============================================================================ #
assert_fail "actor: pipe in the label is rejected"      "$RUN" --as 'a|b'          acme-core -- true
assert_fail "actor: newline in the label is rejected"   "$RUN" --as "$(printf 'a\nb')" acme-core -- true
assert_fail "actor: spaces in the label are rejected"   "$RUN" --as 'a b'          acme-core -- true
assert_fail "actor: uppercase in the label is rejected" "$RUN" --as 'Helper'       acme-core -- true
assert_fail "actor: empty label is rejected"            "$RUN" --as ''             acme-core -- true
# and the encoded field really lands, after by: and before the free-text reason:
"$RUN" acme-core -- bash -c '"$ENGINE/bin/message" send acme-tests "audit me" --id as-1' >/dev/null 2>&1
"$RUN" --as helper-7 acme-tests -- bash -c '"$ENGINE/bin/message" fail as-1 "nope"' >/dev/null 2>&1
tests_inbox="$STATE/acme/standup/inbox/acme-tests.md"
assert_file_has "actor: FAILED line carries by: then actor: then reason:" \
  "$tests_inbox" "event:FAILED | by:acme-tests | actor:helper-7 | reason:nope"
# routing fields are untouched by the actor label
assert_file_has "actor: from:/to: remain the routing key" \
  "$tests_inbox" "from:acme-core | to:acme-tests"
# without --as the line stays exactly as P1 wrote it (no empty actor field)
"$RUN" acme-core -- bash -c '"$ENGINE/bin/message" send acme-tests "plain" --id as-2' >/dev/null 2>&1
"$RUN" acme-tests -- bash -c '"$ENGINE/bin/message" seen as-2' >/dev/null 2>&1
assert_file_has "actor: an unlabelled event line is unchanged" \
  "$tests_inbox" "id:as-2 | event:SEEN | by:acme-tests"
assert_ngrep "actor: no empty actor field is emitted" "$(cat "$tests_inbox")" "actor: |"

# ============================================================================ #
# 14. P0.5 — the registry is the identity authority, so a MALFORMED one must
#     never resolve (a torn write must not hand out identity + clearance)
# ============================================================================ #
# Each case is driven through bin/inbox with AIBOBNET_REGISTRY (run-agent scrubs it).
bad_reg() { # <name> <content>
  printf '%s\n' "$2" > "$WORK/$1.json"
  printf '%s' "$WORK/$1.json"
}
GOOD_PROJ='"projects": { "acme": { "home": "/h", "standup_dir": "/s", "mux_session": "m" } }'
GOOD_AG='"agents": { "acme-core": { "project": "acme", "profile": "engine-dev", "clearance": "t1" } }'

# (a) torn write: cut off mid-agents-object, leaving an unterminated string.
#     Before the fix this resolved happily and handed out the attacker's standup_dir.
r="$(bad_reg torn '{ "schema_version": 2,
  "projects": { "acme": { "home": "/evil/home", "standup_dir": "/evil/standup", "mux_session": "evil" } },
  "agents": { "acme-core": { "project": "acme", "profile": "engine-dev", "clearance": "t4')"
assert_fail "malformed: torn write (unterminated string) is refused" \
  env AIBOBNET_REGISTRY="$r" "$INBOX" acme-core
torn_err="$(AIBOBNET_REGISTRY="$r" "$INBOX" acme-core 2>&1 >/dev/null)"
assert_grep "malformed: the message says the registry is not valid JSON" "$torn_err" "not valid JSON"
assert_ngrep "malformed: a torn registry leaks no path" "$torn_err" "/evil/standup"

# (b) unbalanced / mismatched brackets
assert_fail "malformed: missing closing brace is refused" \
  env AIBOBNET_REGISTRY="$(bad_reg unbal "{ $GOOD_PROJ, $GOOD_AG")" "$INBOX" acme-core
assert_fail "malformed: mismatched bracket type is refused" \
  env AIBOBNET_REGISTRY="$(bad_reg mismatch "{ $GOOD_PROJ, $GOOD_AG ]")" "$INBOX" acme-core

# (c) trailing data after the top-level value (two documents concatenated)
assert_fail "malformed: trailing data after the top-level value is refused" \
  env AIBOBNET_REGISTRY="$(bad_reg trail "{ $GOOD_PROJ, $GOOD_AG } { \"projects\": {} }")" "$INBOX" acme-core

# (d) duplicate key: last-write-wins would let key ORDER decide routing/clearance
dup="$(bad_reg dup '{ "projects": { "acme": { "home": "/h", "standup_dir": "/s", "mux_session": "m" },
                                    "acme-core": { "home": "/h2", "standup_dir": "/s2", "mux_session": "m2" } },
  "agents": { "acme-core-review": { "project": "acme", "profile": "p", "clearance": "t1", "project": "acme-core" } } }')"
assert_fail "malformed: a duplicate key is refused (order must not decide routing)" \
  env AIBOBNET_REGISTRY="$dup" "$INBOX" acme-core-review
dup_err="$(AIBOBNET_REGISTRY="$dup" "$INBOX" acme-core-review 2>&1 >/dev/null)"
assert_grep "malformed: the message names the duplicate key" "$dup_err" "duplicate key"
# a duplicated agent_uid in the same section is caught too
assert_fail "malformed: a duplicate agent_uid is refused" \
  env AIBOBNET_REGISTRY="$(bad_reg dupagent "{ $GOOD_PROJ, \"agents\": {
    \"acme-core\": { \"project\": \"acme\", \"profile\": \"a\", \"clearance\": \"t1\" },
    \"acme-core\": { \"project\": \"acme\", \"profile\": \"b\", \"clearance\": \"t4\" } } }")" "$INBOX" acme-core

# (e) wrong value type on a CONSUMED field — the comment claims JSON strings, so enforce it
assert_fail "malformed: numeric clearance is refused (not a JSON string)" \
  env AIBOBNET_REGISTRY="$(bad_reg numclear "{ $GOOD_PROJ, \"agents\": { \"acme-core\": {
    \"project\": \"acme\", \"profile\": \"p\", \"clearance\": 4 } } }")" "$INBOX" acme-core
assert_fail "malformed: a non-string standup_dir is refused" \
  env AIBOBNET_REGISTRY="$(bad_reg numdir "{ \"projects\": { \"acme\": {
    \"home\": \"/h\", \"standup_dir\": 123, \"mux_session\": \"m\" } }, $GOOD_AG }")" "$INBOX" acme-core

# (f) a single MISSING QUOTE that re-synchronises on the next one: brackets balance and
#     every string terminates, so balance checking alone does NOT catch it — yet `home`
#     silently becomes "/h, " and standup_dir disappears. A silently wrong value at the
#     identity authority is worse than a refusal, so the document must parse as JSON.
resync="$(bad_reg resync '{ "projects": { "acme": { "home": "/h, "standup_dir": "/s", "mux_session": "m" } },
  "agents": { "acme-core": { "project": "acme", "profile": "p", "clearance": "t1" } } }')"
assert_fail "malformed: a re-synchronising missing quote is refused" \
  env AIBOBNET_REGISTRY="$resync" "$INBOX" acme-core
resync_err="$(AIBOBNET_REGISTRY="$resync" "$INBOX" acme-core 2>&1 >/dev/null)"
assert_grep "malformed: re-sync is reported as invalid JSON, not as a missing field" \
  "$resync_err" "not valid JSON"
# a bare (unquoted) value where a string belongs is the same class
assert_fail "malformed: an unquoted value token is refused" \
  env AIBOBNET_REGISTRY="$(bad_reg bareval "{ \"projects\": { \"acme\": {
    \"home\": /h, \"standup_dir\": \"/s\", \"mux_session\": \"m\" } }, $GOOD_AG }")" "$INBOX" acme-core
# a missing comma between two pairs likewise
assert_fail "malformed: a missing comma between pairs is refused" \
  env AIBOBNET_REGISTRY="$(bad_reg nocomma "{ \"projects\": { \"acme\": {
    \"home\": \"/h\" \"standup_dir\": \"/s\", \"mux_session\": \"m\" } }, $GOOD_AG }")" "$INBOX" acme-core

# (g) invalid escapes: taking the character verbatim yielded a DIFFERENT value than a
#     strict JSON reader would. \u is refused outright rather than mis-decoded to "u0041".
assert_fail "malformed: an invalid escape (\\m) is refused, not taken verbatim" \
  env AIBOBNET_REGISTRY="$(bad_reg badesc "{ \"projects\": { \"acme\": {
    \"home\": \"/h\", \"standup_dir\": \"/s\", \"\\mux_session\": \"m\" } }, $GOOD_AG }")" "$INBOX" acme-core
assert_fail "malformed: an undecodable \\u escape is refused, not mis-decoded" \
  env AIBOBNET_REGISTRY="$(bad_reg uesc "{ \"projects\": { \"acme\": {
    \"home\": \"/\\u0041\", \"standup_dir\": \"/s\", \"mux_session\": \"m\" } }, $GOOD_AG }")" "$INBOX" acme-core
# valid escapes still decode
assert_streq "malformed: a VALID escape still decodes normally" \
  "$(AIBOBNET_REGISTRY="$(bad_reg okesc "{ \"projects\": { \"acme\": {
    \"home\": \"/h\", \"standup_dir\": \"\\/s\", \"mux_session\": \"m\" } }, $GOOD_AG }")" \
    "$INBOX" acme-core 2>/dev/null)" "/s/inbox/acme-core.md"

# (h) forward compatibility survives all of it: unknown nested/array fields are ignored,
#     never load-bearing — the type rule applies only where a field is consumed.
fwd="$(bad_reg fwd "{ \"schema_version\": 2, $GOOD_PROJ, \"agents\": { \"acme-core\": {
  \"project\": \"acme\", \"profile\": \"p\", \"clearance\": \"t1\",
  \"display_name\": \"Core Bob äöü\", \"scopes\": [\"a\",\"b\"], \"meta\": { \"x\": \"y\" } } } }")"
assert_streq "forward-compat: unknown nested + array fields still resolve" \
  "$(AIBOBNET_REGISTRY="$fwd" "$INBOX" acme-core 2>/dev/null)" "/s/inbox/acme-core.md"

# ============================================================================ #
# summary
# ============================================================================ #
total=$((pass+fail))
printf '\n%d checks: %d ok / %d fail\n' "$total" "$pass" "$fail"
[ "$fail" -eq 0 ]
