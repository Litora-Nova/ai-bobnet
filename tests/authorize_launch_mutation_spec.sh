#!/usr/bin/env bash
# ai-bobnet — RM-1 adversarial mutation checks for the Policy Decision Point.
#
# aib_authorize_launch is the SINGLE authority for a managed launch and a PURE decision
# function: data in (request + snapshot records) -> verdict out. Because it is pure, its
# invariants are testable with pure data and NO process spawn — the RM-1 testing win.
# Each mutant here weakens one authority rule in lib/aibobnet.sh and must flip its named
# assertion in the driven tests/authorize_launch_spec.sh (the PDP unit acceptance),
# which exercises the clamp-DOWN cases the end-to-end launch fixtures never reach.
#
# Same disposable-copy discipline as tests/managed_launch_adversarial_spec.sh: a mutant
# is a full engine copy carrying its own tests/; the pristine PDP suite must pass; every
# weakened rule must flip its pinned behavioural assertion (never a rc=42 anchor miss).
set -uo pipefail

SRC_ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-pdp-mutations.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

pass=0
fail=0
ok() { pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
no() { fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; }

# A mutant carries bin/lib/scripts/tests. The PDP unit suite builds its own tiny temp
# registries and drives the function with pure data, so no registry.json is needed.
make_mutant() {
  local name="$1" root
  root="$WORK/$name"
  mkdir -p "$root"
  cp -R "$SRC_ROOT/bin" "$SRC_ROOT/lib" "$SRC_ROOT/scripts" "$SRC_ROOT/tests" "$root/"
  printf '%s\n' "$root"
}

# Replace exactly one whole line. awk -v processes backslash escapes in the value, so
# anchors and replacements must stay free of backslash sequences (none here do).
replace_exact() {
  local file="$1" old="$2" new="$3" tmp
  tmp="$file.mutant"
  awk -v old="$old" -v new="$new" '
    $0 == old { count++; print new; next }
    { print }
    END { if (count != 1) exit 42 }
  ' "$file" > "$tmp" || return $?
  # Overwrite in place so $file keeps its original mode (see the managed-launch spec).
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
    ok "clean PDP acceptance is green ($marker)"
  else
    no "clean PDP acceptance failed (rc=$rc)"
    sed -n '/^FAIL - /p' "$out"
  fi
}

# A mutant is "killed" when the PDP suite exits nonzero AND the specific assertion
# protecting the weakened rule is among the reported failures. Collateral failures are
# acceptable; a silent survivor is not.
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

expect_baseline_green "$SRC_ROOT/tests/authorize_launch_spec.sh" \
  "54 checks: 54 ok / 0 fail" "$WORK/clean-pdp.out"

# 1. Breaking the clearance min: inverting min(clearance, cap_tier) lets an agent whose
# clearance exceeds the provider tier ceiling keep the HIGHER clearance instead of
# clamping to the cap. The "cap binds the min" assertion pins the clamp.
CLEARANCE_MIN="$(make_mutant clearance-min-broken)"
replace_exact "$CLEARANCE_MIN/lib/aibobnet.sh" \
  '    if [ "$rc1" -le "$rc2" ]; then eff_clearance="$clearance"' \
  '    if [ "$rc1" -gt "$rc2" ]; then eff_clearance="$clearance"'
record_mutation "clearance-min-broken" "$?"
expect_targeted_failure "clearance-min-broken" \
  "$CLEARANCE_MIN/tests/authorize_launch_spec.sh" \
  "caps below clearance: the cap binds the min" \
  "$WORK/clearance-min-broken.out"

# 2. Breaking the effort min: inverting min(effort, cap_effort) lets a requested effort
# above the provider cap keep the higher level instead of clamping down.
EFFORT_MIN="$(make_mutant effort-min-broken)"
replace_exact "$EFFORT_MIN/lib/aibobnet.sh" \
  '    if [ "$rc1" -le "$rc2" ]; then eff_effort="$effort"' \
  '    if [ "$rc1" -gt "$rc2" ]; then eff_effort="$effort"'
record_mutation "effort-min-broken" "$?"
expect_targeted_failure "effort-min-broken" \
  "$EFFORT_MIN/tests/authorize_launch_spec.sh" \
  "effort above cap: clamped to the cap" \
  "$WORK/effort-min-broken.out"

# 3. Removing the sandbox ceiling: making the min-branch unconditional keeps the
# REQUESTED sandbox regardless of the provider ceiling — a request above the ceiling
# (and even danger-full-access) is no longer clamped. The clamp assertion fires.
SANDBOX_CEILING="$(make_mutant sandbox-ceiling-removed)"
replace_exact "$SANDBOX_CEILING/lib/aibobnet.sh" \
  '    if [ "$rreq" -le "$rcap" ]; then eff_sandbox="$req_sandbox"' \
  '    if [ 0 -eq 0 ]; then eff_sandbox="$req_sandbox" # mutation: sandbox ceiling removed'
record_mutation "sandbox-ceiling-removed" "$?"
expect_targeted_failure "sandbox-ceiling-removed" \
  "$SANDBOX_CEILING/tests/authorize_launch_spec.sh" \
  "sandbox above ceiling: clamped to ceiling" \
  "$WORK/sandbox-ceiling-removed.out"

# 4. Removing the missing-adapter deny: disabling the empty-adapter guard means an
# absent adapter no longer fails closed with the adapter-not-found (127) hint — the
# authority for what a provider may run (its adapter path) stops being enforced.
ADAPTER_DENY="$(make_mutant adapter-127-deny-removed)"
replace_exact "$ADAPTER_DENY/lib/aibobnet.sh" \
  '  if [ -z "$adapter" ]; then' \
  '  if false; then # mutation: missing-adapter 127 deny removed'
record_mutation "adapter-127-deny-removed" "$?"
expect_targeted_failure "adapter-127-deny-removed" \
  "$ADAPTER_DENY/tests/authorize_launch_spec.sh" \
  "absent adapter: exit hint is adapter-not-found (127)" \
  "$WORK/adapter-127-deny-removed.out"

# 5. Removing capability validation: forcing the cap_sandbox rank valid bypasses the
# "declares no valid sandbox capability" config deny, so a provider that declares no
# usable sandbox capability is authorised instead of refused (2).
CAP_VALIDATION="$(make_mutant cap-validation-removed)"
replace_exact "$CAP_VALIDATION/lib/aibobnet.sh" \
  '  _aib_rank sandbox "$cap_sandbox"' \
  '  _aib_rank sandbox read-only # mutation: cap_sandbox validation bypassed'
record_mutation "cap-validation-removed" "$?"
expect_targeted_failure "cap-validation-removed" \
  "$CAP_VALIDATION/tests/authorize_launch_spec.sh" \
  "missing cap_sandbox: denied config (2)" \
  "$WORK/cap-validation-removed.out"

total=$((pass+fail))
printf '\n%d checks: %d ok / %d fail\n' "$total" "$pass" "$fail"
[ "$fail" -eq 0 ]
