#!/usr/bin/env bash
# ai-bobnet — RED spec for the `claude-code` provider adapter (Sprint I-B slice 2).
#
# WHAT THIS PINS
#   docs/CONTRACT-codex-run.md §4.1.1, docs/CONFINEMENT.md ("Effective sandbox x provider state_dir ->
#   LL_RW"), docs/PROVIDERS.md's `claude-code` section, and docs/decisions/0010-claude-code-adapter.md
#   are the docs-first pin this spec exercises against code. `adapters/claude-code` does not exist yet on
#   this tree, `run_confined`'s LL_RW derivation is still `.codex`-literal (lib/aibobnet.sh:1888, unaware
#   of any `state_dir` field), and no registry-resolve validation of a `state_dir` field exists — every
#   block below is expected RED until the builder lands `adapters/claude-code` and the two
#   lib/aibobnet.sh amendments (LL_RW generalisation + state_dir format check). A block whose assertions
#   already pass on the unbuilt tree is a regression guard (codex's own byte-identical LL_RW composition,
#   the allow-list grep), not a mistake.
#
#   FOUR BLOCKS:
#     A. `adapters/claude-code` invoked directly (env -i, a fake wrapped `claude` binary that records
#        argv/env/cwd/stdin/pid) — well-formed ABI: fixed flags in the pinned order, effort identity,
#        model verbatim, stdin byte-exact, exec identity, env exports, --add-dir/--disallowedTools.
#     B. Same harness, refusal paths — shape/effort/sandbox (65), credential (78), missing/non-executable
#        binary (127/126 unmasked), provider exit passthrough, secrets never reach the child even when
#        the calling environment carries them.
#     P. Parity matrix: the SAME malformed argv bytes fed to `adapters/codex` (already built) and
#        `adapters/claude-code` (not yet) must both refuse 65 — proves the frozen ABI's shape validation
#        is not accidentally provider-specific.
#     C. `run_confined`'s LL_RW derivation generalised to a per-provider `state_dir`, sourced from
#        lib/aibobnet.sh directly, against a stub confinement helper (same shape as
#        tests/adapter_codex_spec.sh's own): codex's own composition stays byte-identical (regression),
#        a claude-code-shaped record must carry $HOME/.claude and never fall back to $HOME/.codex
#        (target, RED), a registry-declared state_dir that fails the format regex is refused at resolve
#        time with exit 3 (target, RED, exercised through bin/launch-agent), and a missing or symlinked
#        $HOME/<state_dir> at launch time refuses the launch rather than silently omitting it or widening
#        the cage onto the symlink's target (target, RED).
#
#   TEST-SEAM NOTE (docs/PROVIDERS.md): `adapters/claude-code` resolves its wrapped binary from
#   `AIB_CLAUDE_BIN` if set, defaulting to a fixed provisioning path otherwise — the same seam shape as
#   `AIB_CODEX_BIN`. This spec is the one caller that sets it; Blocks A/B/P therefore test the adapter
#   scripts in isolation, not through the full confined broker chain.
#
#   WHY ENV-EXPORT ORDER IS NOT ASSERTED: a forked child's own `env` dump is not a reliable witness of
#   the order a script's `export A=x B=y ...` line lists its assignments in (shell/OS dependent) —
#   `tests/adapter_codex_spec.sh` never asserts it either (only presence, via `has`). This spec pins each
#   of the eight env exports present exactly once instead, and docs/PROVIDERS.md is the single-sourced
#   place the intended export-line order is written down. Fixed-flag ARGV order, unlike env-dump order,
#   *is* a reliable, meaningful observable (it is literally what the wrapped binary parses), and is
#   pinned as a single ordered block below.
#
#   TRAPS SELF-REVIEWED BEFORE WRITING THIS (recurring findings on earlier specs in this repo):
#     - No EXIT trap kills a captured pid: the only backgrounded call (A, exec identity) is always
#       `wait`-ed for in the same statement group before the script moves on.
#     - Every JSON fixture uses the same printf/escaped-quote literal convention already used by
#       tests/adapter_codex_spec.sh's Block D, not a heredoc with unescaped interpolation.
#     - Every per-case fixture writer removes prior output files BEFORE writing new instrumentation and
#       BEFORE invoking the thing under test — never after.
#     - `tests/adapter_codex_spec.sh` is not touched by this file and must still pass on this same tree
#       (verified manually before this pin, see the report).
set -uo pipefail

SRC_ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
# shellcheck source=lib/aibobnet.sh
. "$SRC_ROOT/lib/aibobnet.sh"

ADAPTER="$SRC_ROOT/adapters/claude-code"
ADAPTER_CODEX="$SRC_ROOT/adapters/codex"
LAUNCH_AGENT="$SRC_ROOT/bin/launch-agent"
SYSTEM_PATH="$PATH"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-ccadapter.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
no(){ fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; }
skip(){ printf 'ok   - (skipped: %s)\n' "$1"; }
eq(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2' want '$3')"; fi; }
has(){ case "$2" in *"$3"*) ok "$1";; *) no "$1 (missing '$3')";; esac; }
hasnt(){ case "$2" in *"$3"*) no "$1 (unexpected '$3')";; *) ok "$1";; esac; }
count_matches_in_string(){ local n; [ "${1-}" != -- ] || shift; n="$(printf '%s\n' "$2" | grep -c -- "$1" 2>/dev/null)"; printf '%s' "${n:-0}"; }
file_byte_count(){ [ -e "$1" ] && wc -c < "$1" 2>/dev/null || printf 0; }

# =============================================================================
# Blocks A + B + P fixtures — adapters/claude-code invoked directly, a fake wrapped binary
# =============================================================================

FIXTURE_HOME="$WORK/broker-home"
FIXTURE_CLAUDE_DIR="$FIXTURE_HOME/.claude"
mkdir -p "$FIXTURE_HOME"

FIXTURE_CWD="$WORK/project-root"
mkdir -p "$FIXTURE_CWD"
FIXTURE_CWD_RESOLVED="$(cd "$FIXTURE_CWD" && pwd -P)"

FAKE_CLAUDE="$WORK/fake-bin/claude"
mkdir -p "$WORK/fake-bin"
FAKE_ARGV_OUT="$WORK/fake-argv"
FAKE_ENV_OUT="$WORK/fake-env"
FAKE_CWD_OUT="$WORK/fake-cwd"
FAKE_PID_OUT="$WORK/fake-pid"
FAKE_STDIN_OUT="$WORK/fake-stdin"

cat > "$FAKE_CLAUDE" <<'STUB'
#!/usr/bin/env bash
# The stand-in for the real, pinned claude-code CLI: records everything
# adapters/claude-code hands it (argv, its own environment, cwd, pid, and every stdin
# byte to EOF), then answers with a fixed marker so a caller can tell it ran.
printf '%s\n' "$$" > "${FAKE_PID_OUT:?FAKE_PID_OUT not set}"
pwd -P > "${FAKE_CWD_OUT:?FAKE_CWD_OUT not set}"
: > "${FAKE_ARGV_OUT:?FAKE_ARGV_OUT not set}"
for a in "$@"; do printf '[%s]\n' "$a" >> "$FAKE_ARGV_OUT"; done
env > "${FAKE_ENV_OUT:?FAKE_ENV_OUT not set}"
cat > "${FAKE_STDIN_OUT:?FAKE_STDIN_OUT not set}"
printf 'FAKE_CLAUDE_OK\n'
exit 0
STUB
chmod +x "$FAKE_CLAUDE"

MODEL="team/model-v2"

write_auth_ok() {
  mkdir -p "$FIXTURE_CLAUDE_DIR"
  chmod 0700 "$FIXTURE_CLAUDE_DIR"
  printf '{"key":"x"}' > "$FIXTURE_CLAUDE_DIR/.credentials.json"
  chmod 0600 "$FIXTURE_CLAUDE_DIR/.credentials.json"
}
write_auth_missing() {
  mkdir -p "$FIXTURE_CLAUDE_DIR"
  chmod 0700 "$FIXTURE_CLAUDE_DIR"
  rm -f "$FIXTURE_CLAUDE_DIR/.credentials.json"
}
write_auth_wrong_mode() {
  write_auth_ok
  chmod 0644 "$FIXTURE_CLAUDE_DIR/.credentials.json"
}

reset_fake_outputs() {
  rm -f "$FAKE_ARGV_OUT" "$FAKE_ENV_OUT" "$FAKE_CWD_OUT" "$FAKE_PID_OUT" "$FAKE_STDIN_OUT"
}

# call_adapter_raw <arg>... — invokes adapters/claude-code directly, env -i, from FIXTURE_CWD,
# with only the vars this test-seam harness needs (docs/PROVIDERS.md's AIB_CLAUDE_BIN note above).
# Sets ADAPTER_OUT / ADAPTER_RC.
ADAPTER_OUT=""; ADAPTER_RC=0
call_adapter_raw() {
  reset_fake_outputs
  ADAPTER_OUT=""; ADAPTER_RC=0
  ADAPTER_OUT="$(
    cd "$FIXTURE_CWD" && env -i HOME="$FIXTURE_HOME" PATH="$SYSTEM_PATH" AIB_CLAUDE_BIN="$FAKE_CLAUDE" \
      FAKE_ARGV_OUT="$FAKE_ARGV_OUT" FAKE_ENV_OUT="$FAKE_ENV_OUT" FAKE_CWD_OUT="$FAKE_CWD_OUT" \
      FAKE_PID_OUT="$FAKE_PID_OUT" FAKE_STDIN_OUT="$FAKE_STDIN_OUT" \
      "$ADAPTER" "$@" 2>&1
  )" || ADAPTER_RC=$?
}

# call_adapter <sandbox> <effort> <prompt> — the well-formed ABI shape (frozen argv, docs/CONTRACT-
# codex-run.md §4.1): the same 11 tokens the PEP hands every adapter, codex-flavoured names and all.
call_adapter() {
  call_adapter_raw exec -m "$MODEL" -s "$1" \
    -c "model_reasoning_effort=\"$2\"" -c 'approval_policy="never"' -- "$3"
}

provider_was_called() { [ -s "$FAKE_ARGV_OUT" ]; }

# =============================================================================
# Block A — well-formed ABI: fixed flags in the pinned order, stdin, exec identity, env
# =============================================================================

write_auth_ok

MULTILINE_PROMPT=$'first line\nsecond line\nthird line'
call_adapter workspace-write high "$MULTILINE_PROMPT"
argv="$(cat "$FAKE_ARGV_OUT" 2>/dev/null)"
eq "A: well-formed call reaches the wrapped binary" "$ADAPTER_RC" 0

EXPECT_FIXED_BLOCK="[-p]
[--model]
[$MODEL]
[--effort]
[high]
[--permission-mode]
[bypassPermissions]
[--no-session-persistence]
[--output-format]
[text]
[--setting-sources]
[]
[--strict-mcp-config]
[--add-dir]
[$FIXTURE_CWD_RESOLVED]"
has "A: the fixed flags appear as one contiguous block, in the pinned order" "$argv" "$EXPECT_FIXED_BLOCK"
eq "A: --permission-mode appears exactly once" "$(count_matches_in_string -- '\[--permission-mode\]' "$argv")" 1
eq "A: --setting-sources appears exactly once" "$(count_matches_in_string -- '\[--setting-sources\]' "$argv")" 1
eq "A: --strict-mcp-config appears exactly once" "$(count_matches_in_string -- '\[--strict-mcp-config\]' "$argv")" 1
eq "A: --add-dir appears exactly once" "$(count_matches_in_string -- '\[--add-dir\]' "$argv")" 1
hasnt "A: --settings never appears (dropped entirely, v2/F3)" "$argv" "--settings"
hasnt "A: no bare -- sentinel or trailing prompt token is appended (claude reads stdin from -p alone)" "$argv" "[--]"
hasnt "A: the prompt is never a trailing argv token" "$argv" "[$MULTILINE_PROMPT]"

printf '%s' "$MULTILINE_PROMPT" > "$WORK/expect-stdin-multiline"
if cmp -s "$WORK/expect-stdin-multiline" "$FAKE_STDIN_OUT"; then
  ok "A: stdin carries the multi-line prompt byte-exact (no trailing newline)"
else
  no "A: stdin carries the multi-line prompt byte-exact (no trailing newline)"
fi
eq "A: fd 0 is at EOF after exactly the prompt's own bytes" \
  "$(file_byte_count "$FAKE_STDIN_OUT")" "$(printf '%s' "$MULTILINE_PROMPT" | wc -c)"

call_adapter workspace-write high '--dangerously fake flag, not a real one'
printf '%s' '--dangerously fake flag, not a real one' > "$WORK/expect-stdin-dashprompt"
if cmp -s "$WORK/expect-stdin-dashprompt" "$FAKE_STDIN_OUT"; then
  ok "A: a prompt beginning with --dangerously reaches stdin unmangled"
else
  no "A: a prompt beginning with --dangerously reaches stdin unmangled"
fi

call_adapter workspace-write high ''
eq "A: an empty prompt is accepted (shape is still valid)" "$ADAPTER_RC" 0
eq "A: an empty prompt leaves stdin at 0 bytes" "$(file_byte_count "$FAKE_STDIN_OUT")" 0

# --disallowedTools: single-token form, present iff read-only, absent at workspace-write.
call_adapter read-only high 'ro check'
argv="$(cat "$FAKE_ARGV_OUT" 2>/dev/null)"
has "A: read-only appends --disallowedTools=Edit,Write,NotebookEdit as ONE token" \
  "$argv" "[--disallowedTools=Edit,Write,NotebookEdit]"
eq "A: --disallowedTools appears exactly once under read-only" \
  "$(count_matches_in_string -- '\[--disallowedTools=' "$argv")" 1
call_adapter workspace-write high 'ww check'
argv="$(cat "$FAKE_ARGV_OUT" 2>/dev/null)"
hasnt "A: workspace-write never appends --disallowedTools" "$argv" "--disallowedTools"

env_out="$(cat "$FAKE_ENV_OUT" 2>/dev/null)"
has "A: the wrapper exports SHELL=/bin/bash" "$env_out" "SHELL=/bin/bash"
has "A: the wrapper exports TERM=dumb" "$env_out" "TERM=dumb"
has "A: the wrapper exports CLAUDE_CONFIG_DIR=\$HOME/.claude" "$env_out" "CLAUDE_CONFIG_DIR=$FIXTURE_HOME/.claude"
has "A: the wrapper exports DISABLE_AUTOUPDATER=1" "$env_out" "DISABLE_AUTOUPDATER=1"
has "A: the wrapper exports CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1" "$env_out" "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1"
has "A: the wrapper exports CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 (F1, cross-attempt memory injection)" \
  "$env_out" "CLAUDE_CODE_DISABLE_AUTO_MEMORY=1"
has "A: the wrapper exports XDG_CACHE_HOME=\$HOME/.claude/cache (F5)" "$env_out" "XDG_CACHE_HOME=$FIXTURE_HOME/.claude/cache"
has "A: the wrapper exports CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1 (F2, pairs with --add-dir)" \
  "$env_out" "CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1"
for kv in 'SHELL=/bin/bash' 'TERM=dumb' "CLAUDE_CONFIG_DIR=$FIXTURE_HOME/.claude" 'DISABLE_AUTOUPDATER=1' \
          'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1' 'CLAUDE_CODE_DISABLE_AUTO_MEMORY=1' \
          "XDG_CACHE_HOME=$FIXTURE_HOME/.claude/cache" 'CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1'; do
  eq "A: '$kv' appears exactly once in the child's env" \
    "$(count_matches_in_string -- "^${kv}\$" "$env_out")" 1
done

grep -q 'AIB_ENV_ALLOW_DEFAULT="HOME PATH"' "$SRC_ROOT/lib/aibobnet.sh" \
  && ok "A: the broker's own env -i allow-list is still exactly HOME PATH (grep pin)" \
  || no "A: the broker's own env -i allow-list is still exactly HOME PATH (grep pin)"

# ANTHROPIC_API_KEY / CLAUDE_CODE_OAUTH_TOKEN must never reach the child, even if this test-seam
# harness's own call carries them (simulating an upstream leak past the broker's HOME/PATH allow-list).
reset_fake_outputs
ADAPTER_OUT=""; ADAPTER_RC=0
ADAPTER_OUT="$(
  cd "$FIXTURE_CWD" && env -i HOME="$FIXTURE_HOME" PATH="$SYSTEM_PATH" AIB_CLAUDE_BIN="$FAKE_CLAUDE" \
    ANTHROPIC_API_KEY="leaked-api-key" CLAUDE_CODE_OAUTH_TOKEN="leaked-oauth-token" \
    FAKE_ARGV_OUT="$FAKE_ARGV_OUT" FAKE_ENV_OUT="$FAKE_ENV_OUT" FAKE_CWD_OUT="$FAKE_CWD_OUT" \
    FAKE_PID_OUT="$FAKE_PID_OUT" FAKE_STDIN_OUT="$FAKE_STDIN_OUT" \
    "$ADAPTER" exec -m "$MODEL" -s workspace-write \
      -c 'model_reasoning_effort="high"' -c 'approval_policy="never"' -- "secret check" 2>&1
)" || ADAPTER_RC=$?
eq "A: a call carrying ANTHROPIC_API_KEY/CLAUDE_CODE_OAUTH_TOKEN still succeeds" "$ADAPTER_RC" 0
env_out="$(cat "$FAKE_ENV_OUT" 2>/dev/null)"
hasnt "A: ANTHROPIC_API_KEY never reaches the wrapped binary's own env" "$env_out" "leaked-api-key"
hasnt "A: CLAUDE_CODE_OAUTH_TOKEN never reaches the wrapped binary's own env" "$env_out" "leaked-oauth-token"

# Exec identity: adapters/claude-code must exec into the wrapped binary, never fork.
#
# HARNESS FIX (Ikarus build report, standup/_build_ikarus_claude-code-adapter.md, "Blocking spec
# defect"): backgrounding the compound list `cd "$FIXTURE_CWD" && env ... &` makes `$!` the pid of
# the intermediate AND-list subshell bash forks to run it asynchronously, not the pid the adapter's
# own exec chain ends up running as (observed off-by-one: wrapper=427, fake=428) -- a spec bug, not
# an adapter bug: the adapter already ends in a bare `exec`, and no production change can make a
# child process replace its own parent shell. Fixed by making the `cd` complete BEFORE anything is
# backgrounded, and using `exec` (not `&`'s own optimization) to guarantee this exact subshell's pid
# is what actually keeps running: `( cd ... && exec env ... )` backgrounded as one unit means $! is
# this subshell's own pid, and `exec env` replaces that same process (same pid) rather than forking a
# new one, so the pid survives unchanged through env -> adapter -> the fake binary's own final exec.
reset_fake_outputs
(
  ( cd "$FIXTURE_CWD" && exec env -i HOME="$FIXTURE_HOME" PATH="$SYSTEM_PATH" AIB_CLAUDE_BIN="$FAKE_CLAUDE" \
      FAKE_ARGV_OUT="$FAKE_ARGV_OUT" FAKE_ENV_OUT="$FAKE_ENV_OUT" FAKE_CWD_OUT="$FAKE_CWD_OUT" \
      FAKE_PID_OUT="$FAKE_PID_OUT" FAKE_STDIN_OUT="$FAKE_STDIN_OUT" \
      "$ADAPTER" exec -m "$MODEL" -s workspace-write \
        -c 'model_reasoning_effort="high"' -c 'approval_policy="never"' -- "pid-check" \
      >"$WORK/pidcheck-out" 2>&1 ) &
  wrapper_pid=$!
  wait "$wrapper_pid"
  printf '%s' "$wrapper_pid" > "$WORK/wrapper-pid"
)
wrapper_pid="$(cat "$WORK/wrapper-pid" 2>/dev/null)"
fake_pid="$(cat "$FAKE_PID_OUT" 2>/dev/null)"
if [ -n "$wrapper_pid" ] && [ -n "$fake_pid" ] && [ "$wrapper_pid" = "$fake_pid" ]; then
  ok "A: adapters/claude-code execs into the wrapped binary (fake pid == wrapper pid)"
else
  no "A: adapters/claude-code execs into the wrapped binary (fake pid == wrapper pid) (wrapper='$wrapper_pid' fake='$fake_pid')"
fi

# Effort: identity, not codex's max->xhigh rename.
for registry_effort in low medium high max; do
  call_adapter read-only "$registry_effort" 'effort check'
  argv="$(cat "$FAKE_ARGV_OUT" 2>/dev/null)"
  if [ "$ADAPTER_RC" -eq 0 ] && [[ "$argv" == *"[--effort]
[$registry_effort]"* ]]; then
    ok "A: effort $registry_effort passes through by identity (no rename)"
  else no "A: effort $registry_effort passes through by identity (no rename)"; fi
done

# Model: non-empty, passed verbatim (the adapter's own check is load-bearing — claude itself accepts
# --model "" per standup/_advisor_claude-code-adapter.md F9).
call_adapter workspace-write high 'model verbatim check'
argv="$(cat "$FAKE_ARGV_OUT" 2>/dev/null)"
has "A: --model carries the frozen ABI's model value verbatim" "$argv" "[--model]
[$MODEL]"

for prompt_kind in trailing-newlines pipe-sized; do
  if [ "$prompt_kind" = trailing-newlines ]; then edge_prompt=$'last line\n\n'
  else printf -v edge_prompt '%65536s' ''; fi
  call_adapter read-only low "$edge_prompt"
  printf '%s' "$edge_prompt" > "$WORK/expect-edge-prompt"
  if [ "$ADAPTER_RC" -eq 0 ] && cmp -s "$WORK/expect-edge-prompt" "$FAKE_STDIN_OUT"; then
    ok "A: $prompt_kind prompt is byte-exact on stdin"
  else no "A: $prompt_kind prompt is byte-exact on stdin"; fi
done

# =============================================================================
# Block B — refusals
# =============================================================================

PROMPT_MARKER="B_REFUSAL_PROMPT_MARKER_should_never_be_echoed"

write_auth_ok
call_adapter danger-full-access high "$PROMPT_MARKER"
eq "B1: danger-full-access is refused (65), regardless of the registry cap" "$ADAPTER_RC" 65
if provider_was_called; then no "B1: the wrapped binary never runs on refusal"; else ok "B1: the wrapped binary never runs on refusal"; fi
hasnt "B1: the prompt never appears in refusal output" "$ADAPTER_OUT" "$PROMPT_MARKER"

call_adapter workspace-write bogus-effort "$PROMPT_MARKER"
eq "B2: an unknown effort value is refused (65) -- claude itself would only warn (F4), the adapter's own check is load-bearing" "$ADAPTER_RC" 65
if provider_was_called; then no "B2: the wrapped binary never runs on refusal"; else ok "B2: the wrapped binary never runs on refusal"; fi
hasnt "B2: the prompt never appears in refusal output" "$ADAPTER_OUT" "$PROMPT_MARKER"

call_adapter_raw exec -s workspace-write \
  -c 'model_reasoning_effort="high"' -c 'approval_policy="never"' -- "$PROMPT_MARKER"
eq "B3a: missing -m/model is refused (65)" "$ADAPTER_RC" 65
hasnt "B3a: the prompt never appears in refusal output" "$ADAPTER_OUT" "$PROMPT_MARKER"

call_adapter_raw exec -x "$MODEL" -s workspace-write \
  -c 'model_reasoning_effort="high"' -c 'approval_policy="never"' -- "$PROMPT_MARKER"
eq "B3b: an unrecognized flag token is refused (65)" "$ADAPTER_RC" 65
hasnt "B3b: the prompt never appears in refusal output" "$ADAPTER_OUT" "$PROMPT_MARKER"

call_adapter_raw exec -s workspace-write -m "$MODEL" \
  -c 'model_reasoning_effort="high"' -c 'approval_policy="never"' -- "$PROMPT_MARKER"
eq "B3c: -m/-s out of the contract's fixed order is refused (65)" "$ADAPTER_RC" 65
hasnt "B3c: the prompt never appears in refusal output" "$ADAPTER_OUT" "$PROMPT_MARKER"

call_adapter_raw exec -m "$MODEL" -s workspace-write \
  -c 'model_reasoning_effort="high"' -c 'approval_policy="always"' -- "$PROMPT_MARKER"
eq "B3d: a non-constant approval_policy value is refused (65)" "$ADAPTER_RC" 65
hasnt "B3d: the prompt never appears in refusal output" "$ADAPTER_OUT" "$PROMPT_MARKER"

call_adapter_raw exec -m "$MODEL" -s workspace-write \
  -c 'model_reasoning_effort="high"' -c 'approval_policy="never"' -- "$PROMPT_MARKER" "extra-trailing-token"
eq "B3e: an extra token after the prompt is refused (65)" "$ADAPTER_RC" 65
hasnt "B3e: the prompt never appears in refusal output" "$ADAPTER_OUT" "$PROMPT_MARKER"

call_adapter_raw exec -m "$MODEL" -s workspace-write \
  -c 'model_reasoning_effort="high"' -c 'approval_policy="never"' "$PROMPT_MARKER"
eq "B3f: a missing -- separator is refused (65)" "$ADAPTER_RC" 65
hasnt "B3f: the prompt never appears in refusal output" "$ADAPTER_OUT" "$PROMPT_MARKER"

# B4-B6: credential refusals — shape is otherwise valid.
write_auth_missing
call_adapter workspace-write high "$PROMPT_MARKER"
eq "B4: a missing .credentials.json is refused (78)" "$ADAPTER_RC" 78
if provider_was_called; then no "B4: the wrapped binary never runs on a credential refusal"; else ok "B4: the wrapped binary never runs on a credential refusal"; fi
hasnt "B4: the prompt never appears in refusal output" "$ADAPTER_OUT" "$PROMPT_MARKER"

write_auth_wrong_mode
call_adapter workspace-write high "$PROMPT_MARKER"
eq "B5: a .credentials.json with mode 0644 is refused (78)" "$ADAPTER_RC" 78
if provider_was_called; then no "B5: the wrapped binary never runs on a credential refusal"; else ok "B5: the wrapped binary never runs on a credential refusal"; fi
hasnt "B5: the prompt never appears in refusal output" "$ADAPTER_OUT" "$PROMPT_MARKER"

write_auth_ok
own_uid="$(id -u)"
foreign_uid=$((own_uid + 1))
if chown "$foreign_uid" "$FIXTURE_CLAUDE_DIR/.credentials.json" 2>/dev/null \
   && [ "$(stat -c %u "$FIXTURE_CLAUDE_DIR/.credentials.json" 2>/dev/null || stat -f %u "$FIXTURE_CLAUDE_DIR/.credentials.json" 2>/dev/null)" = "$foreign_uid" ]; then
  call_adapter workspace-write high "$PROMPT_MARKER"
  eq "B6: a foreign-owned .credentials.json is refused (78)" "$ADAPTER_RC" 78
  if provider_was_called; then no "B6: the wrapped binary never runs on a credential refusal"; else ok "B6: the wrapped binary never runs on a credential refusal"; fi
  hasnt "B6: the prompt never appears in refusal output" "$ADAPTER_OUT" "$PROMPT_MARKER"
else
  skip "B6: foreign-owned .credentials.json (this host cannot chown to a different uid without root)"
  skip "B6: foreign-owned .credentials.json — wrapped binary never runs"
  skip "B6: foreign-owned .credentials.json — prompt never echoed"
fi
write_auth_ok

# B7: the wrapper never manufactures 124/126/127 itself.
reset_fake_outputs
ADAPTER_OUT=""; ADAPTER_RC=0
ADAPTER_OUT="$(
  cd "$FIXTURE_CWD" && env -i HOME="$FIXTURE_HOME" PATH="$SYSTEM_PATH" AIB_CLAUDE_BIN="$WORK/does-not-exist/claude" \
    FAKE_ARGV_OUT="$FAKE_ARGV_OUT" FAKE_ENV_OUT="$FAKE_ENV_OUT" FAKE_CWD_OUT="$FAKE_CWD_OUT" \
    FAKE_PID_OUT="$FAKE_PID_OUT" FAKE_STDIN_OUT="$FAKE_STDIN_OUT" \
    "$ADAPTER" exec -m "$MODEL" -s workspace-write \
      -c 'model_reasoning_effort="high"' -c 'approval_policy="never"' -- "hello" 2>&1
)" || ADAPTER_RC=$?
eq "B7: a missing wrapped binary surfaces its own unmasked 127" "$ADAPTER_RC" 127

for bad_shape in empty-model unknown-sandbox unquoted-effort; do
  write_auth_ok
  case "$bad_shape" in
    empty-model) MODEL='' call_adapter read-only high "$PROMPT_MARKER" ;;
    unknown-sandbox) call_adapter arbitrary high "$PROMPT_MARKER" ;;
    unquoted-effort) call_adapter_raw exec -m "$MODEL" -s read-only -c model_reasoning_effort=high -c 'approval_policy="never"' -- "$PROMPT_MARKER" ;;
  esac
  eq "B8: $bad_shape is refused" "$ADAPTER_RC" 65
  if ! provider_was_called && [[ "$ADAPTER_OUT" != *"$PROMPT_MARKER"* ]]; then ok "B8: $bad_shape neither runs nor exposes the prompt"
  else no "B8: $bad_shape neither runs nor exposes the prompt"; fi
done
MODEL="team/model-v2"
for unsafe in dir-mode auth-symlink dir-symlink auth-directory auth-fifo empty-home; do
  rm -rf "$FIXTURE_CLAUDE_DIR" "$WORK/linked-state"
  write_auth_ok
  case "$unsafe" in
    dir-mode) chmod 0750 "$FIXTURE_CLAUDE_DIR" ;;
    auth-symlink) mv "$FIXTURE_CLAUDE_DIR/.credentials.json" "$FIXTURE_CLAUDE_DIR/saved"; ln -s saved "$FIXTURE_CLAUDE_DIR/.credentials.json" ;;
    dir-symlink) mv "$FIXTURE_CLAUDE_DIR" "$WORK/linked-state"; ln -s "$WORK/linked-state" "$FIXTURE_CLAUDE_DIR" ;;
    auth-directory) rm "$FIXTURE_CLAUDE_DIR/.credentials.json"; mkdir "$FIXTURE_CLAUDE_DIR/.credentials.json" ;;
    auth-fifo) rm "$FIXTURE_CLAUDE_DIR/.credentials.json"; mkfifo "$FIXTURE_CLAUDE_DIR/.credentials.json" ;;
  esac
  if [ "$unsafe" = empty-home ]; then FIXTURE_HOME='' call_adapter read-only high "$PROMPT_MARKER"
  else call_adapter read-only high "$PROMPT_MARKER"; fi
  eq "B9: $unsafe is a credential refusal" "$ADAPTER_RC" 78
  if ! provider_was_called && [[ "$ADAPTER_OUT" != *"$PROMPT_MARKER"* ]]; then ok "B9: $unsafe neither runs nor exposes the prompt"
  else no "B9: $unsafe neither runs nor exposes the prompt"; fi
done
rm -rf "$FIXTURE_CLAUDE_DIR" "$WORK/linked-state"
write_auth_ok
REAL_STAT="$(command -v stat)"
mkdir -p "$WORK/metadata-bin"
for stat_case in foreign-owner metadata-failure; do
  if [ "$stat_case" = foreign-owner ]; then stat_result="printf '%s\\n' '$foreign_uid:600'"
  else stat_result='exit 1'; fi
  cat > "$WORK/metadata-bin/stat" <<EOF
#!/usr/bin/env bash
if [ "\$2" = '%u:%a' ]; then $stat_result
else exec "$REAL_STAT" "\$@"; fi
EOF
  chmod +x "$WORK/metadata-bin/stat"
  SYSTEM_PATH="$WORK/metadata-bin:$SYSTEM_PATH" call_adapter read-only high "$PROMPT_MARKER"
  eq "B10: $stat_case is a credential refusal" "$ADAPTER_RC" 78
  if ! provider_was_called && [[ "$ADAPTER_OUT" != *"$PROMPT_MARKER"* ]]; then ok "B10: $stat_case neither runs nor exposes the prompt"
  else no "B10: $stat_case neither runs nor exposes the prompt"; fi
  SYSTEM_PATH="$PATH"
done

# Native exec failures and provider statuses are not wrapper-owned refusals.
cp "$FAKE_CLAUDE" "$WORK/fake-saved"
chmod 0600 "$FAKE_CLAUDE"
call_adapter read-only high 'native exec check'
eq "B11: a non-executable wrapped binary surfaces native 126" "$ADAPTER_RC" 126
cat > "$FAKE_CLAUDE" <<'EXITSTUB'
#!/usr/bin/env bash
cat >/dev/null
printf 'provider stdout\n'
printf 'provider stderr\n' >&2
exit 42
EXITSTUB
chmod +x "$FAKE_CLAUDE"
call_adapter read-only high 'exit check'
eq "B11: a provider exit remains unmodified" "$ADAPTER_RC" 42
has "B11: provider stdout is relayed" "$ADAPTER_OUT" 'provider stdout'
has "B11: provider stderr is relayed" "$ADAPTER_OUT" 'provider stderr'
cp "$WORK/fake-saved" "$FAKE_CLAUDE"; chmod +x "$FAKE_CLAUDE"

# =============================================================================
# Block P — parity matrix against adapters/codex (already built): the SAME malformed argv
# bytes, fed to both adapters, must both refuse 65. Neither adapter needs a credential
# fixture for these cases — both validate shape/sandbox/effort before ever touching HOME.
# =============================================================================

PARITY_HOME="$WORK/parity-home"
mkdir -p "$PARITY_HOME"
PARITY_PROMPT="P_PARITY_PROMPT_MARKER_should_never_be_echoed"

invoke_adapter() { # invoke_adapter <adapter_path> <arg>...
  local adapter="$1"; shift
  INVOKE_OUT=""; INVOKE_RC=0
  INVOKE_OUT="$(env -i HOME="$PARITY_HOME" PATH="$SYSTEM_PATH" "$adapter" "$@" 2>&1)" || INVOKE_RC=$?
}

parity_case() { # parity_case <label> <want_rc> <arg>...
  local label="$1" want="$2"; shift 2
  invoke_adapter "$ADAPTER_CODEX" "$@"
  eq "P: $label -- codex refuses ($want)" "$INVOKE_RC" "$want"
  hasnt "P: $label -- codex never echoes the prompt" "$INVOKE_OUT" "$PARITY_PROMPT"
  invoke_adapter "$ADAPTER" "$@"
  eq "P: $label -- claude-code refuses the same shape ($want)" "$INVOKE_RC" "$want"
  hasnt "P: $label -- claude-code never echoes the prompt" "$INVOKE_OUT" "$PARITY_PROMPT"
}

parity_case "missing -m/model"          65 exec -s workspace-write -c 'model_reasoning_effort="high"' -c 'approval_policy="never"' -- "$PARITY_PROMPT"
parity_case "unrecognized flag token"   65 exec -x "$MODEL" -s workspace-write -c 'model_reasoning_effort="high"' -c 'approval_policy="never"' -- "$PARITY_PROMPT"
parity_case "-m/-s out of fixed order"  65 exec -s workspace-write -m "$MODEL" -c 'model_reasoning_effort="high"' -c 'approval_policy="never"' -- "$PARITY_PROMPT"
parity_case "non-constant approval_policy" 65 exec -m "$MODEL" -s workspace-write -c 'model_reasoning_effort="high"' -c 'approval_policy="always"' -- "$PARITY_PROMPT"
parity_case "extra trailing token"      65 exec -m "$MODEL" -s workspace-write -c 'model_reasoning_effort="high"' -c 'approval_policy="never"' -- "$PARITY_PROMPT" "extra"
parity_case "missing -- separator"      65 exec -m "$MODEL" -s workspace-write -c 'model_reasoning_effort="high"' -c 'approval_policy="never"' "$PARITY_PROMPT"
parity_case "danger-full-access sandbox" 65 exec -m "$MODEL" -s danger-full-access -c 'model_reasoning_effort="high"' -c 'approval_policy="never"' -- "$PARITY_PROMPT"
parity_case "empty model"               65 exec -m "" -s read-only -c 'model_reasoning_effort="high"' -c 'approval_policy="never"' -- "$PARITY_PROMPT"
parity_case "unrecognized effort token" 65 exec -m "$MODEL" -s workspace-write -c 'model_reasoning_effort="bogus"' -c 'approval_policy="never"' -- "$PARITY_PROMPT"

# =============================================================================
# Block C — run_confined's LL_RW generalised to effective sandbox x provider state_dir
# (docs/CONFINEMENT.md, "Effective sandbox x provider state_dir -> LL_RW")
# =============================================================================

C_BROKER_HOME="$WORK/c-broker-home"
CPROJECT_ROOT="$WORK/c-project-home"
mkdir -p "$C_BROKER_HOME" "$CPROJECT_ROOT" "$C_BROKER_HOME/.codex" "$C_BROKER_HOME/.claude"

C_STUB_DIR="$WORK/c-stub-bin"
mkdir -p "$C_STUB_DIR"
C_LL_LOG="$WORK/c-ll-log"
cat > "$C_STUB_DIR/landlock.conf" <<EOF
STUB_LL_LOG='$C_LL_LOG'
EOF
C_LANDLOCK_STUB="$C_STUB_DIR/landlock-exec"
cat > "$C_LANDLOCK_STUB" <<'STUB'
#!/usr/bin/env bash
# Same CLI-contract shape as tests/broker_enact_spec.sh's / tests/adapter_codex_spec.sh's own stub
# (LL_RO/LL_RW logged, LL_STATUS_FD closed silently on success, always execs its argument).
_cfg="$(cd "$(dirname "$0")" && pwd)/landlock.conf"
[ -f "$_cfg" ] && . "$_cfg"
{
  printf 'LL_RO=%s\n' "${LL_RO-<unset>}"
  printf 'LL_RW=%s\n' "${LL_RW-<unset>}"
  printf '%s\n' '---'
} >> "${STUB_LL_LOG:-/dev/null}"
if [ -n "${LL_STATUS_FD-}" ]; then eval "exec ${LL_STATUS_FD}>&-"; fi
exec "$@"
STUB
chmod +x "$C_LANDLOCK_STUB"

C_ADAPTER="$C_STUB_DIR/provider"
printf '#!/usr/bin/env bash\nexit 0\n' > "$C_ADAPTER"
chmod +x "$C_ADAPTER"

C_EVENT_ROOT="$WORK/c-events"
mkdir -p "$C_EVENT_ROOT"
C_EVENTS_FILE="$C_EVENT_ROOT/main.events"
C_EVENTS_LOCK="$C_EVENT_ROOT/main.events.lock"
C_ENVELOPE_KV="project_uid=acme
actor_type=service
actor_id=aib-broker
agent_uid=acme-core
team_uid=acme-engine
session_id=acme-broker"

c_seed_decided() {
  local kv payload
  kv="$(printf 'decision=allow\ncode=0\nreasons=\npid=%s\nprompt_len=1\nprompt_sha256=deadbeef' "$$")"
  payload="$(aib_event_compose_decided_payload "$kv")"
  aib_event_commit "$C_EVENTS_FILE" "$C_EVENTS_LOCK" attempt.decided "$C_ENVELOPE_KV" "$payload" >/dev/null 2>&1
  printf '%s' "$AIB_EVENT_COMMIT_EVENT_ID"
}

# c_enact_record <sandbox> [state_dir] — state_dir is the field this slice's amendment is
# designed to add; today's aib_enact_launch simply ignores an unrecognised extra key, which is
# exactly what makes the assertions below RED (the value is carried, but nothing reads it yet).
c_enact_record() {
  local extra=""
  [ -z "${2-}" ] || extra=$'\n'"state_dir=$2"
  printf 'adapter=%s\nroot=%s\ncwd=%s\nsandbox=%s\neffort=high\nmodel=team/model-v2\ntimeout=5%s' \
    "$C_ADAPTER" "$CPROJECT_ROOT" "$CPROJECT_ROOT" "$1" "$extra"
}

run_confined_ll() { # run_confined_ll <sandbox> [state_dir] [broker_home]
  : > "$C_LL_LOG"
  local decided_id broker_home="${3:-$C_BROKER_HOME}"
  decided_id="$(c_seed_decided)"
  HOME="$broker_home" AIB_CONFINE_BIN="$C_LANDLOCK_STUB" \
    aib_enact_launch "$(c_enact_record "$1" "${2-}")" "hello" \
    "$C_EVENTS_FILE" "$C_EVENTS_LOCK" "$C_ENVELOPE_KV" "$decided_id" \
    >"$WORK/c-resp" 2>"$WORK/c-err"
}
c_last_ll_rw() { grep '^LL_RW=' "$C_LL_LOG" | tail -1 | sed 's/^LL_RW=//'; }
c_resp_field() { grep "^$1=" "$WORK/c-resp" | tail -1 | sed "s/^$1=//"; }

if command -v aib_enact_launch >/dev/null 2>&1 || type aib_enact_launch >/dev/null 2>&1; then
  # C1 — regression guard: an explicit state_dir=.codex must not change codex's own composition.
  run_confined_ll read-only .codex
  c_ll_rw="$(c_last_ll_rw)"
  has "C1: read-only LL_RW carries /tmp:/var/tmp:/dev" "$c_ll_rw" "/tmp:/var/tmp:/dev"
  has "C1: read-only LL_RW carries \$HOME/.codex (byte-identical to today)" "$c_ll_rw" "$C_BROKER_HOME/.codex"
  hasnt "C1: read-only LL_RW does NOT carry the project root" "$c_ll_rw" "$CPROJECT_ROOT"
  hasnt "C1: read-only LL_RW never carries /var/lib/aib/auth" "$c_ll_rw" "/var/lib/aib/auth"

  run_confined_ll workspace-write .codex
  c_ll_rw="$(c_last_ll_rw)"
  has "C1: workspace-write LL_RW carries \$HOME/.codex (byte-identical to today)" "$c_ll_rw" "$C_BROKER_HOME/.codex"
  has "C1: workspace-write LL_RW carries the project root" "$c_ll_rw" "$CPROJECT_ROOT"
  hasnt "C1: workspace-write LL_RW never carries /var/lib/aib/auth" "$c_ll_rw" "/var/lib/aib/auth"

  # C2 — target: a claude-code-shaped record must carry $HOME/.claude and must NOT silently fall
  # back to codex's own hard-coded $HOME/.codex. RED today: the formula is .codex-literal regardless
  # of what state_dir says.
  run_confined_ll read-only .claude
  c_ll_rw="$(c_last_ll_rw)"
  has "C2: read-only LL_RW carries \$HOME/.claude for a claude-code-shaped record" "$c_ll_rw" "$C_BROKER_HOME/.claude"
  hasnt "C2: read-only LL_RW does not fall back to \$HOME/.codex for claude-code" "$c_ll_rw" "$C_BROKER_HOME/.codex"
  hasnt "C2: read-only LL_RW does NOT carry the project root" "$c_ll_rw" "$CPROJECT_ROOT"

  run_confined_ll workspace-write .claude
  c_ll_rw="$(c_last_ll_rw)"
  has "C2: workspace-write LL_RW carries \$HOME/.claude for a claude-code-shaped record" "$c_ll_rw" "$C_BROKER_HOME/.claude"
  hasnt "C2: workspace-write LL_RW does not fall back to \$HOME/.codex for claude-code" "$c_ll_rw" "$C_BROKER_HOME/.codex"
  has "C2: workspace-write LL_RW carries the project root" "$c_ll_rw" "$CPROJECT_ROOT"
  hasnt "C2: workspace-write LL_RW never carries /var/lib/aib/auth" "$c_ll_rw" "/var/lib/aib/auth"

  # C4 — target (F7): a missing or symlinked $HOME/<state_dir> must refuse the launch outright
  # (exit_class=io-refused, stage=confine — this pin's own inference for the wire shape, docs/
  # CONFINEMENT.md), never silently proceed and never appear in LL_RW. RED today: nothing checks
  # $HOME/<state_dir> for -d/-L at all, so the launch runs to a plain provider success.
  C4_MISSING="$WORK/c4-broker-missing"; mkdir -p "$C4_MISSING"
  run_confined_ll workspace-write .claude "$C4_MISSING"
  eq "C4a: a MISSING \$HOME/.claude refuses the launch (exit_class=io-refused)" "$(c_resp_field exit_class)" "io-refused"
  eq "C4a: a MISSING \$HOME/.claude refuses at stage=confine" "$(c_resp_field stage)" "confine"
  hasnt "C4a: the missing state dir never appears in LL_RW" "$(c_last_ll_rw)" "$C4_MISSING/.claude"

  C4_SYMLINK="$WORK/c4-broker-symlink"; mkdir -p "$C4_SYMLINK/elsewhere"
  ln -s "$C4_SYMLINK/elsewhere" "$C4_SYMLINK/.claude"
  run_confined_ll workspace-write .claude "$C4_SYMLINK"
  eq "C4b: a SYMLINKED \$HOME/.claude refuses the launch (exit_class=io-refused)" "$(c_resp_field exit_class)" "io-refused"
  eq "C4b: a SYMLINKED \$HOME/.claude refuses at stage=confine" "$(c_resp_field stage)" "confine"
  hasnt "C4b: the symlink target is never granted through LL_RW" "$(c_last_ll_rw)" "$C4_SYMLINK/elsewhere"

  # Same guard for .codex — F7 applies generically, fixed once, not a claude-code-only check.
  C4_CODEX_MISSING="$WORK/c4-broker-codex-missing"; mkdir -p "$C4_CODEX_MISSING"
  run_confined_ll workspace-write .codex "$C4_CODEX_MISSING"
  eq "C4c: a MISSING \$HOME/.codex refuses the launch too (exit_class=io-refused)" "$(c_resp_field exit_class)" "io-refused"

  C4_CODEX_SYMLINK="$WORK/c4-broker-codex-symlink"; mkdir -p "$C4_CODEX_SYMLINK/elsewhere"
  ln -s "$C4_CODEX_SYMLINK/elsewhere" "$C4_CODEX_SYMLINK/.codex"
  run_confined_ll workspace-write .codex "$C4_CODEX_SYMLINK"
  eq "C4d: a SYMLINKED \$HOME/.codex refuses the launch too (exit_class=io-refused)" "$(c_resp_field exit_class)" "io-refused"
  eq "C4d: a SYMLINKED \$HOME/.codex refuses at stage=confine" "$(c_resp_field stage)" "confine"
  hasnt "C4d: the symlink target is never granted through LL_RW for .codex either" "$(c_last_ll_rw)" "$C4_CODEX_SYMLINK/elsewhere"
else
  no "C1/C2/C4: aib_enact_launch is defined (not built yet)"
fi

# C3 — target: a registry-declared state_dir that fails the format regex is refused at RESOLVE
# time (exit 3, the same family _aib_resolve_provider_caps already uses for "declares no valid ..."),
# before any launch. Exercised through bin/launch-agent with a working stub adapter, so a pass
# (RED today) shows the launch running to completion unguarded rather than merely failing for some
# unrelated reason.
C3_HOME="$WORK/c3-home"
mkdir -p "$C3_HOME/proj/standup"
C3_STUB_BIN="$WORK/c3-stub-bin"
mkdir -p "$C3_STUB_BIN"
C3_ADAPTER="$C3_STUB_BIN/stub-provider"
cat > "$C3_ADAPTER" <<'STUBEOF'
#!/usr/bin/env bash
printf 'C3_STUB_OK\n'
exit 0
STUBEOF
chmod +x "$C3_ADAPTER"

c3_case_n=0
for bad_state_dir in '../x' 'a/b' '.' ''; do
  c3_case_n=$((c3_case_n+1))
  C3_REG="$WORK/c3-registry-$c3_case_n.json"
  printf '%s\n' "{
  \"schema_version\": 4,
  \"providers\": {
    \"badprovider\": {
      \"adapter\": \"$C3_ADAPTER\",
      \"state_dir\": \"$bad_state_dir\",
      \"cap_sandbox\": \"workspace-write\",
      \"cap_tier\": \"t3\",
      \"cap_effort\": \"high\",
      \"cap_timeout\": \"900\"
    }
  },
  \"projects\": {
    \"proj\": {
      \"home\": \"$C3_HOME/proj\",
      \"standup_dir\": \"$C3_HOME/proj/standup\",
      \"mux_session\": \"proj\",
      \"provider\": \"badprovider\",
      \"model\": \"registry-model\",
      \"effort\": \"medium\"
    }
  },
  \"teams\": {},
  \"agents\": {
    \"proj-core\": { \"project\": \"proj\", \"profile\": \"engine-dev\", \"clearance\": \"t2\" }
  }
}" > "$C3_REG"
  C3_OUT=""; C3_RC=0
  C3_OUT="$(
    PATH="$C3_STUB_BIN:$SYSTEM_PATH" AIBOBNET_REGISTRY="$C3_REG" \
      "$LAUNCH_AGENT" --as proj-core --prompt "c3-prompt" 2>&1
  )" || C3_RC=$?
  eq "C3: state_dir '$bad_state_dir' is refused at resolve time (exit 3), before any launch" "$C3_RC" 3
  hasnt "C3: state_dir '$bad_state_dir' -- the stub adapter never actually ran" "$C3_OUT" "C3_STUB_OK"
done

# =============================================================================
# Regression check (not an assertion here, verified manually and recorded in the pin report):
# tests/adapter_codex_spec.sh must still pass, unmoved, on this exact tree.
# =============================================================================

total=$((pass+fail))
printf '\nadapter_claude_code_spec: %d checks, %d passed, %d failed\n' "$total" "$pass" "$fail"
[ "$fail" -eq 0 ]
