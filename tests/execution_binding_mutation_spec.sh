#!/usr/bin/env bash
# ai-bobnet — RM-0 adversarial mutation checks for execution binding.
#
# Each mutant is a disposable engine copy carrying its own tests/. The clean
# acceptance suite must pass on the pristine tree; every weakened invariant must
# make its named black-box assertion in tests/execution_binding_spec.sh fail. The
# mutant runs ITS OWN copy of that suite, whose SRC_ROOT is the mutant root, so a
# lib/aibobnet.sh substitution is exercised end to end.
#
# Style mirrors tests/ordering_point_mutation_spec.sh: exact single-line source
# anchors, disposable copies, targeted failure markers, and the shared
# "N checks: N ok / 0 fail" summary line.
set -uo pipefail

SRC_ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-binding-mutations.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

pass=0
fail=0
ok() { pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
no() { fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; }

make_mutant() {
  local name="$1" root
  root="$WORK/$name"
  mkdir -p "$root"
  cp -R "$SRC_ROOT/bin" "$SRC_ROOT/lib" "$SRC_ROOT/scripts" "$SRC_ROOT/tests" "$root/"
  printf '%s\n' "$root"
}

# Replace exactly one whole line. awk -v processes backslash escapes in the value,
# so anchors and replacements must stay free of backslash sequences (none here do).
replace_exact() {
  local file="$1" old="$2" new="$3" tmp
  tmp="$file.mutant"
  awk -v old="$old" -v new="$new" '
    $0 == old { count++; print new; next }
    { print }
    END { if (count != 1) exit 42 }
  ' "$file" > "$tmp" || return $?
  # Overwrite in place so $file keeps its original mode. `mv` would give $file the
  # temp file's 644, stripping +x from mutated executables (bin/, scripts/) so they
  # fail with rc=126 — a false "kill" that fires the targeted assertion for a
  # permission error instead of the mutated behavior under test.
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

record_mutation() {
  local label="$1" rc="$2"
  if [ "$rc" -eq 0 ]; then
    ok "$label: exact mutation applied once"
  else
    no "$label: source anchor did not match exactly once (rc=$rc)"
  fi
}

expect_baseline_green() {
  local suite="$1" marker="$2" out="$3" rc=0
  "$suite" > "$out" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ] && grep -qF -- "$marker" "$out"; then
    ok "clean execution-binding acceptance is green ($marker)"
  else
    no "clean execution-binding acceptance failed (rc=$rc)"
    sed -n '/^FAIL - /p' "$out"
  fi
}

# A mutant is "killed" when the acceptance suite exits nonzero AND the specific
# assertion protecting the weakened invariant is among the reported failures.
# Extra collateral failures are acceptable; a silent survivor is not.
expect_targeted_failure() {
  local name="$1" suite="$2" marker="$3" out="$4" rc=0
  "$suite" > "$out" 2>&1 || rc=$?
  printf 'MUTANT %s: rc=%s\n' "$name" "$rc"
  printf '  observed failed assertions:\n'
  sed -n 's/^FAIL - /    - /p' "$out"

  if [ "$rc" -ne 0 ]; then
    ok "$name: acceptance exits nonzero"
  else
    no "$name: mutant unexpectedly survives"
  fi
  if grep -qF -- "FAIL - $marker" "$out"; then
    ok "$name: targeted assertion failed: $marker"
  else
    no "$name: targeted assertion was not observed: $marker"
  fi
}

BASE_OUT="$WORK/clean.out"
expect_baseline_green "$SRC_ROOT/tests/execution_binding_spec.sh" \
  "54 checks: 54 ok / 0 fail" "$BASE_OUT"

# 1. Managed resolution must never silently downgrade to the schema-2 legacy mode:
# a schema-2 registry has no binding, so a managed launch from it must fail closed.
V2_MANAGED="$(make_mutant schema2-managed-accepted)"
replace_exact "$V2_MANAGED/lib/aibobnet.sh" \
  '  aib_resolve_agent_snapshot "$1" managed' \
  '  aib_resolve_agent_snapshot "$1" legacy # mutation: schema-2 managed accepted'
record_mutation "schema2-managed-accepted" "$?"
expect_targeted_failure "schema2-managed-accepted" \
  "$V2_MANAGED/tests/execution_binding_spec.sh" \
  "v2 managed: binding resolver requires schema 3" \
  "$WORK/schema2-managed-accepted.out"

# 2. Removing the agent level breaks the normative agent -> team -> project order:
# the agent-supplied effort would then fall through to a lower level.
NO_AGENT_PRECEDENCE="$(make_mutant agent-precedence-removed)"
replace_exact "$NO_AGENT_PRECEDENCE/lib/aibobnet.sh" \
  '  if _aib_snapshot_field agents "$agent" "$field" "agent '"'"'$agent'"'"'"; then' \
  '  if false && _aib_snapshot_field agents "$agent" "$field" "agent '"'"'$agent'"'"'"; then # mutation'
record_mutation "agent-precedence-removed" "$?"
expect_targeted_failure "agent-precedence-removed" \
  "$NO_AGENT_PRECEDENCE/tests/execution_binding_spec.sh" \
  "mixed: effort comes from agent" \
  "$WORK/agent-precedence-removed.out"

# 3. Removing the direct-team level also reorders precedence: the team-supplied
# model would fall through to the project instead of winning over it.
NO_TEAM_PRECEDENCE="$(make_mutant team-precedence-removed)"
replace_exact "$NO_TEAM_PRECEDENCE/lib/aibobnet.sh" \
  '  if [ -n "$team" ] && _aib_snapshot_field teams "$team" "$field" "team '"'"'$team'"'"'"; then' \
  '  if false && [ -n "$team" ] && _aib_snapshot_field teams "$team" "$field" "team '"'"'$team'"'"'"; then # mutation'
record_mutation "team-precedence-removed" "$?"
expect_targeted_failure "team-precedence-removed" \
  "$NO_TEAM_PRECEDENCE/tests/execution_binding_spec.sh" \
  "mixed: model comes from direct team" \
  "$WORK/team-precedence-removed.out"

# 4. A forged provenance label makes the resolved binding unobservable: the value
# may be right while the reported source lies about which level supplied it.
FLAT_PROVENANCE="$(make_mutant provenance-forged)"
replace_exact "$FLAT_PROVENANCE/lib/aibobnet.sh" \
  '    AIB_RESOLVED_SOURCE="agent:$agent"' \
  '    AIB_RESOLVED_SOURCE="project:$project" # mutation: provenance forged'
record_mutation "provenance-forged" "$?"
expect_targeted_failure "provenance-forged" \
  "$FLAT_PROVENANCE/tests/execution_binding_spec.sh" \
  "mixed: effort provenance is agent uid" \
  "$WORK/provenance-forged.out"

# 5. Treating a present-but-empty field as absence restores fallback for invalid
# registry data. Only true absence may fall through; a present bad value must die.
EMPTY_FALLTHROUGH="$(make_mutant invalid-present-falls-through)"
replace_exact "$EMPTY_FALLTHROUGH/lib/aibobnet.sh" \
  '      [ -n "$value" ] || aib_die 3 "registry: $label field '"'"'$field'"'"' is present but empty"' \
  '      if [ -z "$value" ]; then AIB_SNAPSHOT_FIELD_VALUE=""; return 4; fi # mutation'
record_mutation "invalid-present-falls-through" "$?"
expect_targeted_failure "invalid-present-falls-through" \
  "$EMPTY_FALLTHROUGH/tests/execution_binding_spec.sh" \
  "invalid: present-empty provider does not fall through" \
  "$WORK/invalid-present-falls-through.out"

# 6. Dropping provider syntax validation admits an unknown/foreign provider token
# from the registry, so a garbage provider would resolve instead of being refused.
PROVIDER_OPEN="$(make_mutant provider-validation-disabled)"
replace_exact "$PROVIDER_OPEN/lib/aibobnet.sh" \
  '  aib_validate_token "$provider" provider' \
  '  : # mutation: provider syntax validation disabled'
record_mutation "provider-validation-disabled" "$?"
expect_targeted_failure "provider-validation-disabled" \
  "$PROVIDER_OPEN/tests/execution_binding_spec.sh" \
  "invalid: provider syntax is closed" \
  "$WORK/provider-validation-disabled.out"

# 7. Synthesizing a team's project from its uid prefix turns an unknown or
# mismatched direct team into an accepted authority instead of a refusal.
UNKNOWN_TEAM="$(make_mutant foreign-team-synthesized)"
replace_exact "$UNKNOWN_TEAM/lib/aibobnet.sh" \
  '_aib_snapshot_query() {' \
  '_aib_snapshot_query() {
  if [ "$1" = teams ] && [ "$2" = has ]; then return 0; fi
  if [ "$1" = teams ] && [ "$2" = field ] && [ "$4" = project ]; then printf "%s\n" "${3%%-*}"; return 0; fi'
record_mutation "foreign-team-synthesized" "$?"
expect_targeted_failure "foreign-team-synthesized" \
  "$UNKNOWN_TEAM/tests/execution_binding_spec.sh" \
  "invalid: team project must match uid prefix" \
  "$WORK/foreign-team-synthesized.out"

# 8. Reusing an ambient AIB_REGISTRY_SNAPSHOT in the file-backed legacy query path
# restores exactly the environment-poisoning redirect the fix bf4ec03 closed.
AMBIENT_SNAPSHOT="$(make_mutant ambient-snapshot-authority-restored)"
replace_exact "$AMBIENT_SNAPSHOT/lib/aibobnet.sh" \
  '  awk -v sect="$sect" -v op="$op" -v uid="$uid" -v field="$field" "$_AIB_AWK" "$reg"' \
  '  if [ -n "${AIB_REGISTRY_SNAPSHOT:-}" ]; then printf "%s\n" "$AIB_REGISTRY_SNAPSHOT" | awk -v sect="$sect" -v op="$op" -v uid="$uid" -v field="$field" "$_AIB_AWK"; else awk -v sect="$sect" -v op="$op" -v uid="$uid" -v field="$field" "$_AIB_AWK" "$reg"; fi # mutation'
record_mutation "ambient-snapshot-authority-restored" "$?"
expect_targeted_failure "ambient-snapshot-authority-restored" \
  "$AMBIENT_SNAPSHOT/tests/execution_binding_spec.sh" \
  "snapshot poison: direct legacy entrypoint uses canonical registry" \
  "$WORK/ambient-snapshot-authority-restored.out"

# 9. Reopening the registry for every snapshot query permits mixed generations
# between resolve steps. The one-write FIFO makes the second read deterministic:
# it cannot complete, so the timeout-capped assertion fails closed.
SECOND_READ="$(make_mutant second-registry-read)"
replace_exact "$SECOND_READ/lib/aibobnet.sh" \
  '  _aib_snapshot_awk "$1" "$2" "${3:-}" "${4:-}"' \
  '  aib_registry_awk "$1" "$2" "${3:-}" "${4:-}" # mutation: reopen registry per query'
record_mutation "second-registry-read" "$?"
expect_targeted_failure "second-registry-read" \
  "$SECOND_READ/tests/execution_binding_spec.sh" \
  "snapshot: resolver consumes a one-write FIFO exactly once" \
  "$WORK/second-registry-read.out"

total=$((pass+fail))
printf '\n%d checks: %d ok / %d fail\n' "$total" "$pass" "$fail"
[ "$fail" -eq 0 ]
