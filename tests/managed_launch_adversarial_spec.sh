#!/usr/bin/env bash
# ai-bobnet — RM-1 adversarial mutation checks for the managed launch policy gate.
#
# RM-1 split the launcher into a pure Policy Decision Point (aib_authorize_launch)
# and a Policy Enforcement Point (bin/launch-agent) that ENACTS the verdict: it exec's
# the ABSOLUTE registry adapter inside a child env CONSTRUCTED from an allow-list via
# `env -i`, and re-decides no authority of its own. Each mutant here weakens one of
# those end-to-end invariants and must make its named black-box assertion — in the
# driven managed_launch/codex_run acceptance suites — fail. This is a policy gate for
# cooperating agents, NOT an enforcement boundary; the bypass surface is RM-3's job.
#
# Each mutant is a disposable engine copy carrying its own tests/. The pristine driven
# suites must pass; every weakened invariant must flip its pinned behavioural assertion
# (never a rc=126 permission fault or a rc=42 anchor miss). Mutants run their OWN copy
# of the driven suite, whose SRC_ROOT is the mutant root, so a bin/ or lib/ substitution
# is exercised end to end through launch-agent / codex-run against the schema-4 adapter.
#
# Registry.json is deliberately NOT copied into a mutant: the driven suites always pass
# AIBOBNET_REGISTRY explicitly, and a mutant that reopens the registry after resolution
# must find nothing at the canonical path — making that fault loud and deterministic.
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
# so anchors and replacements must stay free of backslash sequences (none here do —
# the `env -i … \` continuation line is intentionally NOT a target for this reason).
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
  "62 checks: 62 ok / 0 fail" "$WORK/clean-launch.out"
expect_baseline_green "$SRC_ROOT/tests/codex_run_spec.sh" \
  "74 checks: 74 ok / 0 fail" "$WORK/clean-codex-run.out"

# 1. Downgrading the launcher to legacy resolution lets a schema-2 registry drive a
# managed launch: legacy leaves the managed binding unbuilt, so the guarantee that v2
# is refused AS A MANAGED launch (exit 3) collapses.
V2_LAUNCH="$(make_mutant launch-resolves-legacy)"
replace_exact "$V2_LAUNCH/bin/launch-agent" \
  'aib_resolve_managed_agent "$as"' \
  'aib_resolve_agent_snapshot "$as" legacy # mutation: managed launch uses legacy resolution'
record_mutation "launch-resolves-legacy" "$?"
expect_targeted_failure "launch-resolves-legacy" \
  "$V2_LAUNCH/tests/managed_launch_spec.sh" \
  "schema 2 managed launch is refused" \
  "$WORK/launch-resolves-legacy.out"

# 2. Accepting an unknown provider adapter drives a foreign provider from the map
# instead of refusing everything but the codex adapter CLI the PEP knows how to shape.
UNKNOWN_PROVIDER="$(make_mutant unknown-provider-accepted)"
replace_exact "$UNKNOWN_PROVIDER/bin/launch-agent" \
  '  *) aib_die 64 "unsupported registry provider '"'"'$AIB_PROVIDER'"'"' (this launcher drives only the codex adapter CLI)";;' \
  '  *) : ;; # mutation: unknown provider accepted'
record_mutation "unknown-provider-accepted" "$?"
expect_targeted_failure "unknown-provider-accepted" \
  "$UNKNOWN_PROVIDER/tests/managed_launch_spec.sh" \
  "unsupported provider is refused" \
  "$WORK/unknown-provider-accepted.out"

# 3. Restoring --model as an authority reopens the removed CLI override: the migration
# refusal (exit 64) turns into an accepted launch.
MODEL_OVERRIDE="$(make_mutant model-override-restored)"
replace_exact "$MODEL_OVERRIDE/bin/launch-agent" \
  '      aib_die 64 "--model is registry-managed in schema 3; remove the launcher override"' \
  '      shift 2 2>/dev/null || shift; continue # mutation: --model override restored'
record_mutation "model-override-restored" "$?"
expect_targeted_failure "model-override-restored" \
  "$MODEL_OVERRIDE/tests/codex_run_spec.sh" \
  "--model override is refused" \
  "$WORK/model-override-restored.out"

# 4. The symmetric --effort override restoration.
EFFORT_OVERRIDE="$(make_mutant effort-override-restored)"
replace_exact "$EFFORT_OVERRIDE/bin/launch-agent" \
  '      aib_die 64 "--effort is registry-managed in schema 3; remove the launcher override"' \
  '      shift 2 2>/dev/null || shift; continue # mutation: --effort override restored'
record_mutation "effort-override-restored" "$?"
expect_targeted_failure "effort-override-restored" \
  "$EFFORT_OVERRIDE/tests/codex_run_spec.sh" \
  "--effort override is refused" \
  "$WORK/effort-override-restored.out"

# 5. Resolving twice reads the registry a second time. One launch must consume one
# snapshot; the one-write FIFO makes the second read deterministic — it hangs, so the
# timeout-capped "reads a one-write FIFO once" assertion fails closed.
DOUBLE_RESOLVE="$(make_mutant launch-resolves-twice)"
replace_exact "$DOUBLE_RESOLVE/bin/launch-agent" \
  'aib_resolve_managed_agent "$as"' \
  'aib_resolve_managed_agent "$as"; aib_resolve_managed_agent "$as" # mutation: second registry read'
record_mutation "launch-resolves-twice" "$?"
expect_targeted_failure "launch-resolves-twice" \
  "$DOUBLE_RESOLVE/tests/managed_launch_spec.sh" \
  "whole managed launch reads a one-write FIFO once" \
  "$WORK/launch-resolves-twice.out"

# 6. Routing the terminal heartbeat back through the registry-authenticated front door
# reopens registry state after resolution. The pre-resolved bundle must own the
# terminal heartbeat; a reopen cannot find the (removed) registry, so a registry
# mutation during the launch would suppress the completion heartbeat.
HEARTBEAT_REOPEN="$(make_mutant terminal-heartbeat-reopens-registry)"
replace_exact "$HEARTBEAT_REOPEN/bin/launch-agent" \
  'hb done "codex-run OK — $lbl"' \
  '"$REPO_ROOT/scripts/log.sh" "$AIB_AGENT_UID" done "codex-run OK — $lbl" # mutation: terminal heartbeat reopens registry'
record_mutation "terminal-heartbeat-reopens-registry" "$?"
expect_targeted_failure "terminal-heartbeat-reopens-registry" \
  "$HEARTBEAT_REOPEN/tests/managed_launch_spec.sh" \
  "registry removal still records terminal heartbeat at original path" \
  "$WORK/terminal-heartbeat-reopens-registry.out"

# 7. Dropping the end-of-options -- before the prompt lets a leading-dash prompt be
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

# 8. Effort-enum validation moved from the launcher into the PDP (RM-1). Bypassing the
# PDP's effort rank check (re-homed from the old bad-effort mutant) lets an out-of-enum
# registry effort resolve to an unvalidated argv token instead of failing closed (64)
# before any provider starts.
EFFORT_ENUM="$(make_mutant effort-enum-accepted)"
replace_exact "$EFFORT_ENUM/lib/aibobnet.sh" \
  '  _aib_rank effort "$effort"' \
  '  _aib_rank effort low # mutation: unrecognised effort accepted (validation bypassed)'
record_mutation "effort-enum-accepted" "$?"
expect_targeted_failure "effort-enum-accepted" \
  "$EFFORT_ENUM/tests/managed_launch_spec.sh" \
  "unsupported effort is refused" \
  "$WORK/effort-enum-accepted.out"

# 9. Restoring PATH/cwd adapter resolution reopens the exact seam RM-1 closes: the PEP
# must exec the ABSOLUTE registry adapter from the verdict, never a `codex` resolved on
# PATH at the launch cwd. Under the poison fixture (a hostile codex earlier on PATH and
# one in cwd) the restored lookup runs the poison, so the "never executed" assertion
# fires. (This also covers the adapter facet of "authority re-decided in the PEP".)
PATH_ADAPTER="$(make_mutant restore-path-adapter)"
replace_exact "$PATH_ADAPTER/bin/launch-agent" \
  'adapter_path="$AIB_VERDICT_ADAPTER_PATH"' \
  'adapter_path="$(cd "$cwd" && command -v codex)" # mutation: PATH/cwd adapter resolution restored'
record_mutation "restore-path-adapter" "$?"
expect_targeted_failure "restore-path-adapter" \
  "$PATH_ADAPTER/tests/managed_launch_spec.sh" \
  "a codex earlier on PATH or in cwd is never executed" \
  "$WORK/restore-path-adapter.out"

# 10. Switching the child env from the allow-list to a denylist mindset: widening the
# allow-list loop to admit ambient variables lets non-allow-listed inheritance cross
# `env -i` into the provider. The child must see ONLY the allow-list + explicit exports;
# a leaked LEAKME_SENTINEL / CODEX_RUN_BIN proves the allow-list stopped being complete.
ENV_DENYLIST="$(make_mutant env-denylist-scrub)"
replace_exact "$ENV_DENYLIST/bin/launch-agent" \
  'for _n in $AIB_VERDICT_ENV_ALLOW; do' \
  'for _n in $AIB_VERDICT_ENV_ALLOW LEAKME_SENTINEL CODEX_RUN_BIN AIBOBNET_PROVIDER; do # mutation: ambient vars admitted (denylist mindset)'
record_mutation "env-denylist-scrub" "$?"
expect_targeted_failure "env-denylist-scrub" \
  "$ENV_DENYLIST/tests/managed_launch_spec.sh" \
  "child env drops non-allow-listed inherited vars" \
  "$WORK/env-denylist-scrub.out"

# 11. Accepting a non-absolute adapter drops the PDP's absoluteness guard: a cwd-relative
# adapter map entry (which cwd could reinterpret) is authorised instead of refused as a
# config error. The "…explains absoluteness" assertion pins the refusal reason, which
# the guard no longer produces.
NONABS_ADAPTER="$(make_mutant non-absolute-adapter-accepted)"
replace_exact "$NONABS_ADAPTER/lib/aibobnet.sh" \
  '      /*) ;;' \
  '      ?*) ;; # mutation: non-absolute adapter accepted'
record_mutation "non-absolute-adapter-accepted" "$?"
expect_targeted_failure "non-absolute-adapter-accepted" \
  "$NONABS_ADAPTER/tests/managed_launch_spec.sh" \
  "non-absolute adapter error explains absoluteness" \
  "$WORK/non-absolute-adapter-accepted.out"

# 12. Breaking the sandbox min so it no longer binds: inverting min(requested, cap_sandbox)
# raises a read-only request up to the provider ceiling (workspace-write) instead of
# honouring the lower, safer bound. The effective sandbox the adapter receives is no
# longer the min, so the argv sandbox assertion fires.
SANDBOX_MIN="$(make_mutant sandbox-min-broken)"
replace_exact "$SANDBOX_MIN/lib/aibobnet.sh" \
  '    if [ "$rreq" -le "$rcap" ]; then eff_sandbox="$req_sandbox"' \
  '    if [ "$rreq" -gt "$rcap" ]; then eff_sandbox="$req_sandbox"'
record_mutation "sandbox-min-broken" "$?"
expect_targeted_failure "sandbox-min-broken" \
  "$SANDBOX_MIN/tests/managed_launch_spec.sh" \
  "argv uses effective read-only sandbox" \
  "$WORK/sandbox-min-broken.out"

# 13. Duplicating authority into the PEP: instead of consuming the verdict's effective
# sandbox, the PEP re-decides it (here to workspace-write). Authority must live ONLY in
# the PDP (Decision 2) — a second source of truth in the enforcement point drives the
# provider at a sandbox the verdict never granted, so the resolved-binding heartbeat
# assertion (which pins the effective sandbox) fires.
PEP_AUTHORITY="$(make_mutant duplicate-authority-in-pep)"
replace_exact "$PEP_AUTHORITY/bin/launch-agent" \
  'sandbox="$AIB_VERDICT_EFFECTIVE_SANDBOX"' \
  'sandbox="workspace-write" # mutation: PEP re-decides sandbox, ignoring the verdict'
record_mutation "duplicate-authority-in-pep" "$?"
expect_targeted_failure "duplicate-authority-in-pep" \
  "$PEP_AUTHORITY/tests/managed_launch_spec.sh" \
  "busy heartbeat uses resolved model and effective effort" \
  "$WORK/duplicate-authority-in-pep.out"

total=$((pass+fail))
printf '\n%d checks: %d ok / %d fail\n' "$total" "$pass" "$fail"
[ "$fail" -eq 0 ]
