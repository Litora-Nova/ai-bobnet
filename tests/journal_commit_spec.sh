#!/usr/bin/env bash
# ai-bobnet — direct fail-closed coverage for the serialized journal helper.
#
# Every case runs in a disposable subshell because aib_die intentionally exits.
# Rejections must leave the journal empty, publish no success result, and emit a
# diagnostic. No registry, agent context, or product command is involved.
set -uo pipefail

SRC_ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
REPO_ROOT="$SRC_ROOT"
# shellcheck source=lib/aibobnet.sh
. "$REPO_ROOT/lib/aibobnet.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-journal-commit.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
JOURNAL="$WORK/journal.md"
LOCK="$WORK/journal.md.lock"
SYSTEM_PATH="$PATH"

pass=0
fail=0
ok() { pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
no() { fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; }
assert_streq() {
  if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2' want '$3')"; fi
}
assert_nonzero() {
  if [ "$2" -ne 0 ]; then ok "$1"; else no "$1 (got rc 0)"; fi
}
assert_empty_file() {
  if [ ! -s "$2" ]; then ok "$1"; else no "$1 ($2 is not empty)"; fi
}
assert_nonempty_file() {
  if [ -s "$2" ]; then ok "$1"; else no "$1 ($2 is empty)"; fi
}

append_success_decider() {
  AIB_JOURNAL_ACTION=append
  AIB_JOURNAL_RECORD='record:committed'
  AIB_JOURNAL_RESULT='result:visible-after-commit'
}

empty_append_decider() {
  AIB_JOURNAL_ACTION=append
  AIB_JOURNAL_RECORD=''
  AIB_JOURNAL_RESULT='false-success'
}

newline_append_decider() {
  AIB_JOURNAL_ACTION=append
  AIB_JOURNAL_RECORD=$'first line\nsecond line'
  AIB_JOURNAL_RESULT='false-success'
}

carriage_return_append_decider() {
  AIB_JOURNAL_ACTION=append
  AIB_JOURNAL_RECORD=$'first field\rsecond field'
  AIB_JOURNAL_RESULT='false-success'
}

dirty_noop_decider() {
  AIB_JOURNAL_ACTION=noop
  AIB_JOURNAL_RECORD='record must not accompany noop'
  AIB_JOURNAL_RESULT='false-success'
}

invalid_action_decider() {
  AIB_JOURNAL_ACTION=replace
  AIB_JOURNAL_RECORD='invalid action record'
  AIB_JOURNAL_RESULT='false-success'
}

no_action_decider() {
  AIB_JOURNAL_RESULT='false-success'
}

run_rejection() {
  local label="$1" scenario="$2"
  local stdout="$WORK/${label}.out" stderr="$WORK/${label}.err" rc
  : > "$JOURNAL"
  : > "$stdout"
  : > "$stderr"
  ( "$scenario" ) > "$stdout" 2> "$stderr"
  rc=$?
  assert_nonzero "$label: exits nonzero" "$rc"
  assert_empty_file "$label: appends nothing" "$JOURNAL"
  assert_empty_file "$label: emits no false success" "$stdout"
  assert_nonempty_file "$label: emits a diagnostic" "$stderr"
}

# 1. Success publishes the result only after the checked append completes.
: > "$JOURNAL"
( aib_journal_commit "$LOCK" "$JOURNAL" append_success_decider
  printf '%s\n' "$AIB_JOURNAL_COMMIT_RESULT"
) > "$WORK/success.out" 2> "$WORK/success.err"
success_rc=$?
assert_streq "success: exits zero" "$success_rc" "0"
assert_streq "success: appends exactly one complete record" "$(cat "$JOURNAL")" "record:committed"
assert_streq "success: result is caller-visible after commit" \
  "$(cat "$WORK/success.out")" "result:visible-after-commit"
assert_empty_file "success: emits no diagnostic" "$WORK/success.err"

# 2. Missing and failing flock implementations fail before the decider can run.
NO_FLOCK_PATH="$WORK/no-flock"
mkdir -p "$NO_FLOCK_PATH"
missing_flock_scenario() {
  PATH="$NO_FLOCK_PATH"
  aib_journal_commit "$LOCK" "$JOURNAL" append_success_decider
  printf '%s\n' "${AIB_JOURNAL_COMMIT_RESULT:-}"
}
run_rejection missing-flock missing_flock_scenario

FAIL_FLOCK_PATH="$WORK/failing-flock"
mkdir -p "$FAIL_FLOCK_PATH"
cat > "$FAIL_FLOCK_PATH/flock" <<'SH'
#!/bin/bash
exit 73
SH
chmod +x "$FAIL_FLOCK_PATH/flock"
failing_flock_scenario() {
  PATH="$FAIL_FLOCK_PATH:$SYSTEM_PATH"
  aib_journal_commit "$LOCK" "$JOURNAL" append_success_decider
  printf '%s\n' "${AIB_JOURNAL_COMMIT_RESULT:-}"
}
run_rejection failing-flock failing_flock_scenario

# 3. Nested commits are rejected before a second journal can be touched.
INNER_JOURNAL="$WORK/inner.md"
INNER_LOCK="$WORK/inner.md.lock"
: > "$INNER_JOURNAL"
nested_decider() {
  aib_journal_commit "$INNER_LOCK" "$INNER_JOURNAL" append_success_decider
  AIB_JOURNAL_ACTION=append
  AIB_JOURNAL_RECORD='outer record'
  AIB_JOURNAL_RESULT='false-success'
}
nested_commit_scenario() {
  aib_journal_commit "$LOCK" "$JOURNAL" nested_decider
  printf '%s\n' "${AIB_JOURNAL_COMMIT_RESULT:-}"
}
run_rejection nested-commit nested_commit_scenario
assert_empty_file "nested-commit: inner journal is untouched" "$INNER_JOURNAL"

# 4. Invalid decider outputs are all fail-closed.
empty_append_scenario() {
  aib_journal_commit "$LOCK" "$JOURNAL" empty_append_decider
  printf '%s\n' "${AIB_JOURNAL_COMMIT_RESULT:-}"
}
run_rejection empty-append-record empty_append_scenario

newline_append_scenario() {
  aib_journal_commit "$LOCK" "$JOURNAL" newline_append_decider
  printf '%s\n' "${AIB_JOURNAL_COMMIT_RESULT:-}"
}
run_rejection multiline-record newline_append_scenario

carriage_return_append_scenario() {
  aib_journal_commit "$LOCK" "$JOURNAL" carriage_return_append_decider
  printf '%s\n' "${AIB_JOURNAL_COMMIT_RESULT:-}"
}
run_rejection carriage-return-record carriage_return_append_scenario

dirty_noop_scenario() {
  aib_journal_commit "$LOCK" "$JOURNAL" dirty_noop_decider
  printf '%s\n' "${AIB_JOURNAL_COMMIT_RESULT:-}"
}
run_rejection noop-with-record dirty_noop_scenario

invalid_action_scenario() {
  aib_journal_commit "$LOCK" "$JOURNAL" invalid_action_decider
  printf '%s\n' "${AIB_JOURNAL_COMMIT_RESULT:-}"
}
run_rejection invalid-action invalid_action_scenario

no_action_scenario() {
  aib_journal_commit "$LOCK" "$JOURNAL" no_action_decider
  printf '%s\n' "${AIB_JOURNAL_COMMIT_RESULT:-}"
}
run_rejection no-action no_action_scenario

total=$((pass+fail))
printf '\n%d checks: %d ok / %d fail\n' "$total" "$pass" "$fail"
[ "$fail" -eq 0 ]
