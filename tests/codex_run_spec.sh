#!/usr/bin/env bash
# ai-bobnet — codex-run acceptance (docs/CONTRACT-codex-run.md §5).
# Drives bin/codex-run against a synthetic white-label registry (acme) + a STUB codex binary
# (CODEX_RUN_BIN test seam) — proving arg-fidelity, fail-closed validation, the watchdog timeout,
# error/success relay, heartbeat emission, and cwd. NO real inference / no network.
set -uo pipefail

SRC_ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
CR="$SRC_ROOT/bin/codex-run"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-cr.XXXXXX")"
STATE="$WORK/state"; mkdir -p "$STATE/acme/standup"
REG="$WORK/registry.json"
cat > "$REG" <<JSON
{
  "schema_version": 2,
  "projects": { "acme": { "home": "$STATE/acme", "standup_dir": "$STATE/acme/standup", "mux_session": "acme" } },
  "agents":   { "acme-core": { "project": "acme", "profile": "engine-dev", "clearance": "t2" } }
}
JSON
HBLOG="$STATE/acme/standup/acme-core.log"

# stub codex: records argv + pwd, then behaves per STUB_MODE.
STUB="$WORK/codex-stub"
cat > "$STUB" <<'STUB'
#!/usr/bin/env bash
[ -n "${STUB_ARGV_OUT:-}" ] && printf '%s\n' "$*" > "$STUB_ARGV_OUT"
[ -n "${STUB_PWD_OUT:-}" ]  && pwd > "$STUB_PWD_OUT"
case "${STUB_MODE:-ok}" in
  ok)    printf 'STUB_BUILT_OK\n'; exit 0;;
  sleep) sleep "${STUB_SLEEP:-5}"; exit 0;;
  err)   printf 'stub failure\n' >&2; exit "${STUB_RC:-7}";;
esac
STUB
chmod +x "$STUB"

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# run codex-run with the seam + synthetic registry; capture stdout(+stderr) and rc.
ARGV_OUT="$WORK/argv"; PWD_OUT="$WORK/pwd"
cr() {
  CR_OUT=""; CR_RC=0
  CR_OUT="$(AIBOBNET_REGISTRY="$REG" CODEX_RUN_BIN="$STUB" \
            STUB_ARGV_OUT="$ARGV_OUT" STUB_PWD_OUT="$PWD_OUT" \
            "$CR" "$@" 2>&1)" || CR_RC=$?
}

pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
no(){ fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; }
eq(){ [ "$2" = "$3" ] && ok "$1" || { no "$1 (got '$2' want '$3')"; }; }
has(){ case "$2" in *"$3"*) ok "$1";; *) no "$1 (missing '$3')";; esac; }
hasnt(){ case "$2" in *"$3"*) no "$1 (unexpected '$3')";; *) ok "$1";; esac; }

# --- fail-closed validation (no codex call) ----------------------------------
rm -f "$ARGV_OUT"
cr --prompt "x"                                   ; eq "missing --as -> exit 64" "$CR_RC" 64
[ -f "$ARGV_OUT" ] && no "no codex call on bad args" || ok "no codex call on bad args"
cr --as acme-core --sandbox danger-full-access --prompt x ; eq "danger-full-access refused (64)" "$CR_RC" 64
cr --as acme-core --sandbox bogus --prompt x      ; eq "invalid --sandbox (64)" "$CR_RC" 64
cr --as acme-core --effort turbo --prompt x       ; eq "invalid --effort (64)" "$CR_RC" 64
cr --as acme-core --timeout 1.5 --prompt x        ; eq "non-integer --timeout (64)" "$CR_RC" 64
cr --as acme-core                                 ; eq "missing prompt (64)" "$CR_RC" 64
cr --as 'Bad_UID' --prompt x                      ; eq "invalid agent_uid rejected" "$([ "$CR_RC" -ne 0 ] && echo nz)" "nz"

# --- success + heartbeat + relay ---------------------------------------------
: > "$HBLOG"
cr --as acme-core --label build-x --prompt "make it so"
eq "success rc 0" "$CR_RC" 0
has "codex output relayed 1:1" "$CR_OUT" "STUB_BUILT_OK"
hb="$(cat "$HBLOG")"
has "heartbeat busy on start" "$hb" "| busy | codex-run: gpt-5.6-luna/read-only"
has "heartbeat done on success" "$hb" "| done | codex-run OK — build-x"

# --- arg fidelity (defaults + overrides) -------------------------------------
argv="$(cat "$ARGV_OUT")"
has "argv has exec" "$argv" "exec"
has "argv default model" "$argv" "-m gpt-5.6-luna"
has "argv default sandbox" "$argv" "-s read-only"
has "argv reasoning effort" "$argv" 'model_reasoning_effort="high"'
has "argv approval never" "$argv" 'approval_policy="never"'
has "argv carries prompt" "$argv" "make it so"
cr --as acme-core --model gpt-5.6-sol --sandbox workspace-write --effort max --prompt p
argv="$(cat "$ARGV_OUT")"
has "override model" "$argv" "-m gpt-5.6-sol"
has "override sandbox" "$argv" "-s workspace-write"
has "override effort" "$argv" 'model_reasoning_effort="max"'

# --- cwd ---------------------------------------------------------------------
mkdir -p "$WORK/sub"
cr --as acme-core --cwd "$WORK/sub" --prompt p
eq "codex ran in --cwd" "$(cat "$PWD_OUT")" "$WORK/sub"
cr --as acme-core --cwd "$WORK/nope" --prompt p ; eq "missing cwd -> exit 2" "$CR_RC" 2

# --- prompt sources ----------------------------------------------------------
printf 'from stdin' > "$WORK/stdin.txt"
CR_RC=0
CR_OUT="$(AIBOBNET_REGISTRY="$REG" CODEX_RUN_BIN="$STUB" STUB_ARGV_OUT="$ARGV_OUT" "$CR" --as acme-core - < "$WORK/stdin.txt" 2>&1)" || CR_RC=$?
eq "stdin prompt rc 0" "$CR_RC" 0
has "stdin prompt reached codex" "$(cat "$ARGV_OUT")" "from stdin"
echo "file prompt here" > "$WORK/pf"
cr --as acme-core --prompt-file "$WORK/pf" ; eq "prompt-file rc 0" "$CR_RC" 0
cr --as acme-core --prompt a --prompt-file "$WORK/pf" ; eq "two prompt sources refused (64)" "$CR_RC" 64

# --- watchdog timeout (the headline fix) -------------------------------------
: > "$HBLOG"
export STUB_MODE=sleep STUB_SLEEP=5
cr --as acme-core --timeout 1 --label slowbuild --prompt p
unset STUB_MODE STUB_SLEEP
eq "timeout -> exit 124" "$CR_RC" 124
has "heartbeat blocked TIMEOUT" "$(cat "$HBLOG")" "| blocked | codex-run TIMEOUT after 1s — slowbuild"

# --- codex error surfaced ----------------------------------------------------
: > "$HBLOG"
export STUB_MODE=err STUB_RC=7
cr --as acme-core --label failbuild --prompt p
unset STUB_MODE STUB_RC
eq "codex error propagates rc" "$CR_RC" 7
has "heartbeat blocked FAILED" "$(cat "$HBLOG")" "| blocked | codex-run FAILED rc=7 — failbuild"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
