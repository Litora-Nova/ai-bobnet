#!/usr/bin/env bash
# ai-bobnet — mechanical mutation checks for the serialized ordering point.
#
# Each mutant is a disposable copy of the candidate engine. The public ordering
# suites must identify the specific guarantee removed by the substitution.
set -uo pipefail

SRC_ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-ordering-mutations.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
no() { fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; }

make_mutant() {
  local name="$1" root
  root="$WORK/$name"
  mkdir -p "$root"
  cp -R "$SRC_ROOT/bin" "$SRC_ROOT/scripts" "$SRC_ROOT/lib" "$root/"
  printf '%s\n' "$root"
}

replace_exact() {
  local file="$1" old="$2" new="$3" tmp
  tmp="$file.mutant"
  awk -v old="$old" -v new="$new" '
    $0 == old { count++; print new; next }
    { print }
    END { if (count != 1) exit 42 }
  ' "$file" > "$tmp" || return $?
  mv "$tmp" "$file"
}

replace_nth() {
  local file="$1" old="$2" new="$3" nth="$4" expected="$5" tmp
  tmp="$file.mutant"
  awk -v old="$old" -v new="$new" -v nth="$nth" -v expected="$expected" '
    $0 == old { count++; if (count == nth) print new; else print; next }
    { print }
    END { if (count != expected) exit 42 }
  ' "$file" > "$tmp" || return $?
  mv "$tmp" "$file"
}

expect_targeted_failure() {
  local label="$1" source="$2" suite="$3" marker="$4" out="$5" rc
  AIB_ORDERING_SOURCE_ROOT="$source" "$suite" > "$out" 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then
    ok "$label: mutated suite fails"
  else
    no "$label: mutated suite unexpectedly passes"
  fi
  if grep -qF -- "$marker" "$out"; then
    ok "$label: targeted assertion reports the mutation"
  else
    no "$label: targeted assertion was not observed"
  fi
}

# 1. Removing the exclusive flock must be caught by the concurrent message and
# wakeup races, not merely by a source-shape assertion.
NO_FLOCK="$(make_mutant no-flock)"
replace_exact "$NO_FLOCK/lib/aibobnet.sh" \
  '  flock -x "$_aib_lock_fd" || aib_die 2 "cannot acquire journal lock: $lock_path"' \
  '  : # mutation: exclusive flock removed'
no_flock_mutation_rc=$?
if [ "$no_flock_mutation_rc" -eq 0 ]; then
  ok "removed flock: exact mutation applied once"
else
  no "removed flock: source anchor did not match exactly once"
fi
expect_targeted_failure "removed flock" "$NO_FLOCK" \
  "$SRC_ROOT/tests/ordering_point_spec.sh" \
  'FAIL - parallel send: exactly one PERSISTED record is committed' \
  "$WORK/no-flock.out"

# 2. A per-file proposal lock loses cross-journal uniqueness. Mutate only the
# first of the three namespace-lock assignments (the propose branch).
PER_FILE="$(make_mutant per-file-memory)"
replace_nth "$PER_FILE/bin/memory" \
  '    _memory_lock="$(_memory_lock_path)"; _ensure_memory_lock_dir' \
  '    _memory_lock="$_journal.lock"; _ensure_memory_lock_dir' 1 3
per_file_mutation_rc=$?
if [ "$per_file_mutation_rc" -eq 0 ]; then
  ok "per-file memory lock: exact propose mutation applied once"
else
  no "per-file memory lock: source anchors did not match expected shape"
fi
expect_targeted_failure "per-file memory lock" "$PER_FILE" \
  "$SRC_ROOT/tests/ordering_point_failures_spec.sh" \
  'FAIL - cross-scope propose: exactly one command wins' \
  "$WORK/per-file-memory.out"

# 3. Ignoring the append status must be caught at the public acknowledgement
# boundary: a failed write may never print the requested id as success.
IGNORE_APPEND="$(make_mutant ignore-append)"
replace_exact "$IGNORE_APPEND/lib/aibobnet.sh" \
  '        aib_die 2 "cannot append journal record: $journal_path"' \
  '        : # mutation: append error ignored'
ignore_append_mutation_rc=$?
if [ "$ignore_append_mutation_rc" -eq 0 ]; then
  ok "ignored append error: exact mutation applied once"
else
  no "ignored append error: source anchor did not match exactly once"
fi
expect_targeted_failure "ignored append error" "$IGNORE_APPEND" \
  "$SRC_ROOT/tests/ordering_point_failures_spec.sh" \
  'FAIL - message append failure: command fails' \
  "$WORK/ignore-append.out"

# 4. Removing the duplicate-review no-op must allow a second event, which the
# deterministic same-verdict race detects at the journal boundary.
DUPLICATE_REVIEW="$(make_mutant duplicate-review)"
replace_exact "$DUPLICATE_REVIEW/bin/memory" \
  '      return 0' \
  '      : # mutation: duplicate-review no-op removed'
duplicate_review_mutation_rc=$?
if [ "$duplicate_review_mutation_rc" -eq 0 ]; then
  ok "duplicate review guard: exact mutation applied once"
else
  no "duplicate review guard: source anchors did not match expected shape"
fi
expect_targeted_failure "duplicate review guard" "$DUPLICATE_REVIEW" \
  "$SRC_ROOT/tests/ordering_point_failures_spec.sh" \
  'FAIL - duplicate review: exactly one REVIEWED_ACCEPT event is committed' \
  "$WORK/duplicate-review.out"

# 5. An off-by-one exhaustion guard permits one ping beyond the configured
# budget. The concurrent near-limit race must expose that extra hook call.
LATE_EXHAUSTION="$(make_mutant late-exhaustion)"
replace_exact "$LATE_EXHAUSTION/bin/wakeup" \
  '  if [ "$n" -ge "$attempt_max" ]; then' \
  '  if [ "$n" -gt "$attempt_max" ]; then'
late_exhaustion_mutation_rc=$?
if [ "$late_exhaustion_mutation_rc" -eq 0 ]; then
  ok "late wakeup exhaustion: exact mutation applied once"
else
  no "late wakeup exhaustion: source anchor did not match exactly once"
fi
expect_targeted_failure "late wakeup exhaustion" "$LATE_EXHAUSTION" \
  "$SRC_ROOT/tests/ordering_point_spec.sh" \
  'FAIL - concurrent wakeup exhaustion: failed hook stops at the attempt budget' \
  "$WORK/late-exhaustion.out"

total=$((pass+fail))
printf '\n%d checks: %d ok / %d fail\n' "$total" "$pass" "$fail"
[ "$fail" -eq 0 ]
