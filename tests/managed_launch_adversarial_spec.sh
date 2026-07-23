#!/usr/bin/env bash
# ai-bobnet — RM-0 adversarial mutation checks for the managed launch boundary.
#
# Each mutant is a disposable engine copy carrying its own tests/. The pristine
# acceptance suites must pass; every weakened managed-launch invariant must make
# its named black-box assertion fail. Mutants run their OWN copy of the driven
# suite, whose SRC_ROOT is the mutant root, so a bin/ substitution is exercised
# end to end through launch-agent / codex-run against a PATH `codex` stub.
#
# Registry.json is deliberately NOT copied into a mutant: the driven suites always
# pass AIBOBNET_REGISTRY explicitly, and a mutant that reopens the registry after
# the scrub must find nothing at the canonical path — making that fault loud and
# deterministic instead of dependent on an unwritable /srv default.
#
# Style mirrors tests/ordering_point_mutation_spec.sh: exact single-line anchors,
# disposable copies, targeted markers, and the shared summary line.
set -uo pipefail

SRC_ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-launch-mutations.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

pass=0
fail=0
ok() { pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
no() { fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; }

# A mutant carries bin/lib/scripts/tests but no registry.json (see header).
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
  mv "$tmp" "$file"
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
    ok "clean managed-launch acceptance is green ($marker)"
  else
    no "clean managed-launch acceptance failed (rc=$rc)"
    sed -n '/^FAIL - /p' "$out"
  fi
}

# A mutant is "killed" when the driven suite exits nonzero AND the specific
# assertion protecting the weakened invariant is among the reported failures.
# Extra collateral failures are acceptable; a silent survivor is not.
expect_targeted_failure() {
  local name="$1" suite="$2" marker="$3" out="$4" rc=0
  "$suite" > "$out" 2>&1 || rc=$?
  printf 'MUTANT %s: rc=%s\n' "$name" "$rc"
  printf '  observed failed assertions:\n'
  sed -n 's/^FAIL - /    - /p' "$out"

  if [ "$rc" -ne 0 ]; then
    ok "$name: driven suite exits nonzero"
  else
    no "$name: mutant unexpectedly survives"
  fi
  if grep -qF -- "FAIL - $marker" "$out"; then
    ok "$name: targeted assertion failed: $marker"
  else
    no "$name: targeted assertion was not observed: $marker"
  fi
}

expect_baseline_green "$SRC_ROOT/tests/managed_launch_spec.sh" \
  "40 checks: 40 ok / 0 fail" "$WORK/clean-launch.out"
expect_baseline_green "$SRC_ROOT/tests/codex_run_spec.sh" \
  "74 checks: 74 ok / 0 fail" "$WORK/clean-codex-run.out"

# 1. Downgrading the launcher to legacy resolution lets a schema-2 registry drive
# a managed launch: legacy leaves the binding empty, so the guarantee that v2 is
# refused as a MANAGED launch (exit 3) collapses.
V2_LAUNCH="$(make_mutant launch-resolves-legacy)"
replace_exact "$V2_LAUNCH/bin/launch-agent" \
  'aib_resolve_managed_agent "$as"' \
  'aib_resolve_agent_snapshot "$as" legacy # mutation: managed launch uses legacy resolution'
record_mutation "launch-resolves-legacy" "$?"
expect_targeted_failure "launch-resolves-legacy" \
  "$V2_LAUNCH/tests/managed_launch_spec.sh" \
  "schema 2 managed launch is refused" \
  "$WORK/launch-resolves-legacy.out"

# 2. Accepting an unknown provider adapter runs a foreign provider from the
# registry instead of refusing everything but the implemented `codex` adapter.
UNKNOWN_PROVIDER="$(make_mutant unknown-provider-accepted)"
replace_exact "$UNKNOWN_PROVIDER/bin/launch-agent" \
  '  *) aib_die 64 "unsupported registry provider '"'"'$AIB_PROVIDER'"'"' (RM-0 supports only '"'"'codex'"'"')";;' \
  '  *) : ;; # mutation: unknown provider accepted'
record_mutation "unknown-provider-accepted" "$?"
expect_targeted_failure "unknown-provider-accepted" \
  "$UNKNOWN_PROVIDER/tests/managed_launch_spec.sh" \
  "unsupported provider is refused" \
  "$WORK/unknown-provider-accepted.out"

# 3. Accepting an out-of-enum Codex effort passes an unvalidated argv token to the
# provider instead of failing closed before any process starts.
BAD_EFFORT="$(make_mutant bad-effort-accepted)"
replace_exact "$BAD_EFFORT/bin/launch-agent" \
  '  *) aib_die 64 "unsupported Codex registry effort '"'"'$AIB_EFFORT'"'"' (expected: low|medium|high|max)";;' \
  '  *) : ;; # mutation: out-of-enum effort accepted'
record_mutation "bad-effort-accepted" "$?"
expect_targeted_failure "bad-effort-accepted" \
  "$BAD_EFFORT/tests/managed_launch_spec.sh" \
  "unsupported Codex effort is refused" \
  "$WORK/bad-effort-accepted.out"

# 4. Restoring --model as an authority reopens the removed CLI override: the
# migration refusal (exit 64) turns into an accepted launch.
MODEL_OVERRIDE="$(make_mutant model-override-restored)"
replace_exact "$MODEL_OVERRIDE/bin/launch-agent" \
  '      aib_die 64 "--model is registry-managed in schema 3; remove the launcher override"' \
  '      shift 2 2>/dev/null || shift; continue # mutation: --model override restored'
record_mutation "model-override-restored" "$?"
expect_targeted_failure "model-override-restored" \
  "$MODEL_OVERRIDE/tests/codex_run_spec.sh" \
  "--model override is refused" \
  "$WORK/model-override-restored.out"

# 5. The symmetric --effort override restoration.
EFFORT_OVERRIDE="$(make_mutant effort-override-restored)"
replace_exact "$EFFORT_OVERRIDE/bin/launch-agent" \
  '      aib_die 64 "--effort is registry-managed in schema 3; remove the launcher override"' \
  '      shift 2 2>/dev/null || shift; continue # mutation: --effort override restored'
record_mutation "effort-override-restored" "$?"
expect_targeted_failure "effort-override-restored" \
  "$EFFORT_OVERRIDE/tests/codex_run_spec.sh" \
  "--effort override is refused" \
  "$WORK/effort-override-restored.out"

# 6. Leaving CODEX_RUN_BIN in the child environment re-exposes the ambient
# executable-selection seam RM-0 scrubs; the provider child must see it removed.
CODEX_RUN_BIN_KEPT="$(make_mutant codex-run-bin-not-scrubbed)"
replace_exact "$CODEX_RUN_BIN_KEPT/bin/launch-agent" \
  'unset CODEX_RUN_BIN 2>/dev/null || true' \
  ': # mutation: CODEX_RUN_BIN left in the child environment'
record_mutation "codex-run-bin-not-scrubbed" "$?"
expect_targeted_failure "codex-run-bin-not-scrubbed" \
  "$CODEX_RUN_BIN_KEPT/tests/managed_launch_spec.sh" \
  "child sees CODEX_RUN_BIN removed" \
  "$WORK/codex-run-bin-not-scrubbed.out"

# 7. Resolving twice reads the registry a second time. One launch must consume one
# snapshot; the one-write FIFO makes the second read deterministic — it hangs, so
# the timeout-capped "reads a one-write FIFO once" assertion fails closed.
DOUBLE_RESOLVE="$(make_mutant launch-resolves-twice)"
replace_exact "$DOUBLE_RESOLVE/bin/launch-agent" \
  'aib_resolve_managed_agent "$as"' \
  'aib_resolve_managed_agent "$as"; aib_resolve_managed_agent "$as" # mutation: second registry read'
record_mutation "launch-resolves-twice" "$?"
expect_targeted_failure "launch-resolves-twice" \
  "$DOUBLE_RESOLVE/tests/managed_launch_spec.sh" \
  "whole managed launch reads a one-write FIFO once" \
  "$WORK/launch-resolves-twice.out"

# 8. Routing the terminal heartbeat back through the registry-authenticated front
# door reopens registry state after resolution. The pre-resolved bundle must own
# the terminal heartbeat; a reopen cannot find the (removed/absent) registry, so
# a registry mutation during the launch would suppress the completion heartbeat.
HEARTBEAT_REOPEN="$(make_mutant terminal-heartbeat-reopens-registry)"
replace_exact "$HEARTBEAT_REOPEN/bin/launch-agent" \
  'hb done "codex-run OK — $lbl"' \
  '"$REPO_ROOT/scripts/log.sh" "$AIB_AGENT_UID" done "codex-run OK — $lbl" # mutation: terminal heartbeat reopens registry'
record_mutation "terminal-heartbeat-reopens-registry" "$?"
expect_targeted_failure "terminal-heartbeat-reopens-registry" \
  "$HEARTBEAT_REOPEN/tests/managed_launch_spec.sh" \
  "registry removal still records terminal heartbeat at original path" \
  "$WORK/terminal-heartbeat-reopens-registry.out"

# 9. Dropping the end-of-options -- before the prompt lets a leading-dash prompt be
# parsed by codex as an option instead of prompt text (RM-0 hotfix #1). The regression
# assertion pins the prompt operand immediately after a standalone -- in the argv.
NO_EOO="$(make_mutant end-of-options-removed)"
replace_exact "$NO_EOO/bin/launch-agent" \
  '    -- "$prompt" 2>&1' \
  '    "$prompt" 2>&1 # mutation: end-of-options -- removed'
record_mutation "end-of-options-removed" "$?"
expect_targeted_failure "end-of-options-removed" \
  "$NO_EOO/tests/managed_launch_spec.sh" \
  "leading-dash prompt passes after end-of-options --" \
  "$WORK/end-of-options-removed.out"

total=$((pass+fail))
printf '\n%d checks: %d ok / %d fail\n' "$total" "$pass" "$fail"
[ "$fail" -eq 0 ]
