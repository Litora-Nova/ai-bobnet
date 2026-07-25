#!/usr/bin/env bash
# ai-bobnet — RM-2 cross-stack adversarial mutation gate (Lane E).
#
# One permanent home for the safety-critical RM-2 invariants that span more than one
# lane — writer framing, PEP signal honesty, the read-only fold, and payload
# extraction. Each entry weakens EXACTLY ONE invariant in a disposable engine copy and
# proves a NAMED acceptance check turns RED. A silent survivor is a regression hole.
#
# NEWLY pinned here (not covered elsewhere): the UTF-8 boundary. event_commit_spec
# exercises only a loose 0xff byte, so a regression that weakened just the overlong or
# surrogate boundary — while still rejecting 0xff — would slip through. Those two legs
# pin C0 80 (overlong) and ED A0 80 (surrogate) directly, and prove a boundary-scoped
# mutant flips them without touching the loose-0xff rejection.
#
# REFERENCED (not restated): every cross-stack leg re-runs the sister spec that already
# owns the named assertion and asserts the mutation makes THAT assertion fail. This
# gate does not duplicate the sister assertions; it guarantees the invariants they
# protect cannot be quietly removed across the stack.
#
# Lane E attacks the code; it never edits lib/ or bin/. All mutation is on throwaway
# copies under $WORK. Style mirrors tests/execution_binding_mutation_spec.sh.
set -uo pipefail

SRC_ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-rm2-adversarial.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
no()  { fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; }
has() { case "$2" in *"$3"*) ok "$1";; *) no "$1 (missing '$3')";; esac; }

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
  # Overwrite in place so $file keeps its original mode: `mv` would give it the temp
  # file's 644 and strip +x from mutated executables (bin/), a false permission "kill".
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

# A mutant is "killed" when the sister acceptance suite exits nonzero AND the specific
# assertion protecting the weakened invariant is among the reported failures. Extra
# collateral failures are acceptable; a silent survivor is not.
expect_targeted_failure() {
  local name="$1" suite="$2" marker="$3" out="$4" rc=0
  # Run via `bash` (not direct exec): the sister specs are run this way by the suite
  # harness and not all of them carry the +x bit, so a direct "$suite" would die with
  # a permission error — a false "kill" unrelated to the mutation under test.
  bash "$suite" > "$out" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    ok "$name: sister acceptance exits nonzero"
  else
    no "$name: mutant unexpectedly survives (sister suite still green)"
  fi
  if grep -qF -- "FAIL - $marker" "$out"; then
    ok "$name: targeted assertion failed: $marker"
  else
    no "$name: targeted assertion was not observed: $marker"
  fi
}

# Probe a given lib's frozen UTF-8 validator against the canonical boundary vectors.
# Emits one `<tag>=accept|reject` line per vector so a mutant run can be diffed against
# the real engine. Sourced in a subshell so the caller's shell state is untouched.
utf8_probe() {
  local lib="$1"
  (
    # shellcheck source=/dev/null
    . "$lib" 2>/dev/null || exit 0
    _p() {
      local tag="$1" bytes
      bytes="$(printf '%b' "$2")"
      if _aib_utf8_is_valid "$bytes"; then printf '%s=accept\n' "$tag"; else printf '%s=reject\n' "$tag"; fi
    }
    _p loose     '\377'              # bare 0xff — the only case event_commit_spec covers
    _p overlong  '\300\200'          # C0 80 — overlong encoding of U+0000
    _p surrogate '\355\240\200'      # ED A0 80 — UTF-16 surrogate U+D800, illegal in UTF-8
    _p valid2    '\303\244'          # ä  U+00E4
    _p valid3    '\342\202\254'      # €  U+20AC
    _p valid4    '\360\237\230\200'  # 😀 U+1F600
  )
}

# ===========================================================================
# Part 1 — NEWLY pinned: the UTF-8 boundary (RFC 3629)
# ===========================================================================
REAL="$(utf8_probe "$SRC_ROOT/lib/aibobnet.sh")"
has "real validator rejects overlong C0 80"     "$REAL" "overlong=reject"
has "real validator rejects surrogate ED A0 80" "$REAL" "surrogate=reject"
has "real validator rejects loose 0xff"         "$REAL" "loose=reject"
has "real validator accepts valid 2-byte"       "$REAL" "valid2=accept"
has "real validator accepts valid 3-byte"       "$REAL" "valid3=accept"
has "real validator accepts valid 4-byte"       "$REAL" "valid4=accept"

# Mutant: widen the surrogate second-byte range so ED A0 80 is wrongly accepted. This
# weakens ONLY the surrogate boundary; loose 0xff must stay rejected, proving the pin
# above is boundary-scoped and not just a blanket "some invalid byte" check.
MU1="$(make_mutant utf8-surrogate-widened)"
replace_exact "$MU1/lib/aibobnet.sh" \
  '        237) [ "$second" -ge 128 ] && [ "$second" -le 159 ] || return 1;;' \
  '        237) : ;;'
record_mutation "utf8-surrogate-widened" "$?"
MU1_OUT="$(utf8_probe "$MU1/lib/aibobnet.sh")"
case "$MU1_OUT" in
  *surrogate=accept*) ok "utf8-surrogate-widened: surrogate now accepted -> flips 'rejects surrogate ED A0 80'";;
  *)                  no "utf8-surrogate-widened: surrogate still rejected (silent survivor)";;
esac
has "utf8-surrogate-widened stays boundary-scoped (0xff still rejected)" "$MU1_OUT" "loose=reject"

# Mutant: widen the 2-byte lead range down to 192 so the overlong lead C0 (192) is
# treated as a valid 2-byte start and C0 80 is wrongly accepted. 0xff (255) is outside
# every lead range and must stay rejected.
MU2="$(make_mutant utf8-overlong-accepted)"
replace_exact "$MU2/lib/aibobnet.sh" \
  '    if [ "$byte" -ge 194 ] && [ "$byte" -le 223 ]; then' \
  '    if [ "$byte" -ge 192 ] && [ "$byte" -le 223 ]; then'
record_mutation "utf8-overlong-accepted" "$?"
MU2_OUT="$(utf8_probe "$MU2/lib/aibobnet.sh")"
case "$MU2_OUT" in
  *overlong=accept*) ok "utf8-overlong-accepted: overlong now accepted -> flips 'rejects overlong C0 80'";;
  *)                 no "utf8-overlong-accepted: overlong still rejected (silent survivor)";;
esac
has "utf8-overlong-accepted stays boundary-scoped (0xff still rejected)" "$MU2_OUT" "loose=reject"

# ===========================================================================
# Part 2 — cross-stack invariants (each references a named sister assertion)
# ===========================================================================

# Reader corrupt-gate: without it the fold folds a valid prefix out of a corrupt stream
# instead of failing closed — a partial-audit leak. (attempts_spec)
M3="$(make_mutant reader-corrupt-gate-removed)"
replace_exact "$M3/bin/attempts" \
  'if [ "$AIB_EVENT_SCAN_STATUS" = corrupt ]; then' \
  'if false; then'
record_mutation "reader-corrupt-gate-removed" "$?"
expect_targeted_failure "reader-corrupt-gate-removed" \
  "$M3/tests/attempts_spec.sh" \
  "corrupt refusal never leaks the valid prefix attempt" \
  "$WORK/reader-corrupt-gate-removed.out"

# PEP signal honesty: the handler must commit the child's CONFIRMED status, never forge
# aborted. Forcing aborted forges a terminal abort after a child that handled TERM and
# exited 0. (attempt_audit_spec)
M4="$(make_mutant pep-forges-aborted-after-success)"
replace_exact "$M4/bin/launch-agent" \
  '    [ "$_provider_status_confirmed" -eq 0 ] || ( _pep_commit_status "$_provider_status" ) || true' \
  '    ( _pep_commit_ended aborted "" "$signal" ) || true'
record_mutation "pep-forges-aborted-after-success" "$?"
expect_targeted_failure "pep-forges-aborted-after-success" \
  "$M4/tests/attempt_audit_spec.sh" \
  "confirmed child success records ok, never aborted" \
  "$WORK/pep-forges-aborted-after-success.out"

# Payload extractor: it must follow the object path, not the leaf key, or a top-level
# or nested spoof key shadows the real payload field. Leaf-only matching returns the
# top-level spoof. (attempts_spec)
M5="$(make_mutant payload-extractor-leaf-match)"
replace_exact "$M5/lib/aibobnet.sh" \
  '  if (!found && path == target) {' \
  '  { _np=split(path,_pa,"."); _nt=split(target,_ta,"."); } if (!found && _pa[_np]==_ta[_nt]) {'
record_mutation "payload-extractor-leaf-match" "$?"
expect_targeted_failure "payload-extractor-leaf-match" \
  "$M5/tests/attempts_spec.sh" \
  "payload accessor reads payload.decision, not a spoof" \
  "$WORK/payload-extractor-leaf-match.out"

# Frame-prefix forge: the scanner ties the crc-protected event_id's seq to the frame
# prefix seq. Disabling the tie lets a shifted prefix (identity forged from the frame,
# not the body) pass, and the writer appends onto it. (event_commit_spec)
M6="$(make_mutant frame-prefix-seq-tie-disabled)"
replace_exact "$M6/lib/aibobnet.sh" \
  '      if [ "${fev_id##*-}" != "$seq" ]; then' \
  '      if [ "${fev_id##*-}" != "$seq" ] && false; then'
record_mutation "frame-prefix-seq-tie-disabled" "$?"
expect_targeted_failure "frame-prefix-seq-tie-disabled" \
  "$M6/tests/event_commit_spec.sh" \
  "decided writer refuses an event_id/seq-mismatched stream" \
  "$WORK/frame-prefix-seq-tie-disabled.out"

total=$((pass+fail))
printf '\n%d checks: %d ok / %d fail\n' "$total" "$pass" "$fail"
[ "$fail" -eq 0 ]
