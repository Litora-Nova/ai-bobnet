#!/usr/bin/env bash
# ai-bobnet — RED spec for the `session-turn` adapter mode (Supervisor slice S1a-1).
#
# WHAT THIS PINS
#   A second, closed adapter ABI form for BOTH providers: the 12-token
#       session-turn <sid> -m <model> -s <sandbox> -c model_reasoning_effort="<e>"
#                    -c approval_policy="never" -- <prompt>
#   where <sid> is `new:<uuid>` (start a provider session under that id) or a bare `<uuid>`
#   (continue it). The existing 11-token `exec ...` form stays byte-identical. The adapter does
#   no interpretation of provider errors ("already in use", "No conversation found"): it passes
#   the provider's rc and text through, the supervisor decides.
#
#   Expected on the unbuilt tree: every positive `session-turn` assertion FAILS (the adapters
#   refuse any first token other than `exec` with exit 65). Refusal assertions (bad sid shape,
#   forbidden subcommands, wrong token count) and the golden `exec` argv blocks already hold
#   today and are regression guards: they keep the new mode from loosening the closed shape.
#
#   BLOCKS
#     C. claude-code  — T1 new, T2 resume, T3 sid regex/token count, T4 golden `exec`,
#                       T5 read-only disallowedTools on both paths, T6 forbidden words, T7 passthrough.
#     X. codex        — T8 new, T9 resume (no -s, -s still validated), T10 golden `exec`,
#                       T11 credential preflight on both paths, T12 thread.started on stdout.
#
#   DESIGN POINTS RESOLVED HERE (see the hand-off note; each is an assumption, not a given)
#     - Position of `--session-id <uuid>` among the claude flags is NOT pinned: the pair must be
#       adjacent, and the argv with that pair removed must equal the ADR-0010 flags minus
#       `--no-session-persistence`, in order.
#     - Invalid -s on the codex resume path exits 65 (the adapters' existing "unsupported
#       sandbox" code), not 64.
#     - For `exec resume`, only the prefix `exec resume <uuid> --json -m <m> -c <effort>
#       -c <approval>` is pinned contiguously; the tail must still carry the bypass flag and read
#       the prompt from stdin (`-- -`).
#
#   TEST SEAM: AIB_CLAUDE_BIN / AIB_CODEX_BIN, as in tests/adapter_*_spec.sh. Hermetic HOME, `env -i`.
set -uo pipefail

SRC_ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
ADAPTER_CLAUDE="$SRC_ROOT/adapters/claude-code"
ADAPTER_CODEX="$SRC_ROOT/adapters/codex"
SYSTEM_PATH="$PATH"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-sessturn.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
no(){ fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; }
eq(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2' want '$3')"; fi; }
has(){ case "$2" in *"$3"*) ok "$1";; *) no "$1 (missing '$3')";; esac; }
hasnt(){ case "$2" in *"$3"*) no "$1 (unexpected '$3')";; *) ok "$1";; esac; }

FIXTURE_HOME="$WORK/home"
FIXTURE_CWD="$WORK/project-root"
FAKE_STATE="$WORK/provider-state"
mkdir -p "$FIXTURE_HOME" "$FIXTURE_CWD" "$FAKE_STATE" "$WORK/fake-bin"
CWD_RESOLVED="$(cd "$FIXTURE_CWD" && pwd -P)"

FAKE_ARGV_OUT="$WORK/fake-argv"; FAKE_ENV_OUT="$WORK/fake-env"
FAKE_CWD_OUT="$WORK/fake-cwd";   FAKE_STDIN_OUT="$WORK/fake-stdin"

# One stub plays both CLIs. It records argv/env/cwd/stdin, then simulates the provider by sid state:
#   claude --session-id <u>  : refuses "already in use" (rc 1) if <u> exists, else creates it
#   claude --resume <u>      : refuses "No conversation found" (rc 1) if <u> is absent
#   codex exec               : prints a thread.started event carrying $FAKE_THREAD_ID
#   codex exec resume <u>    : prints a turn.started event
cat > "$WORK/fake-bin/provider" <<'STUB'
#!/usr/bin/env bash
: > "${FAKE_ARGV_OUT:?}"
for a in "$@"; do printf '[%s]\n' "$a" >> "$FAKE_ARGV_OUT"; done
pwd -P > "${FAKE_CWD_OUT:?}"
env > "${FAKE_ENV_OUT:?}"
cat > "${FAKE_STDIN_OUT:?}"
case "${FAKE_KIND:?}" in
  claude)
    prev=''
    for a in "$@"; do
      case "$prev" in
        --session-id)
          if [ -e "$FAKE_STATE/$a" ]; then printf 'Error: Session ID %s is already in use.\n' "$a" >&2; exit 1; fi
          : > "$FAKE_STATE/$a" ;;
        --resume)
          if [ ! -e "$FAKE_STATE/$a" ]; then printf 'No conversation found with session ID: %s\n' "$a" >&2; exit 1; fi ;;
      esac
      prev=$a
    done
    printf 'FAKE_CLAUDE_OK\n' ;;
  codex)
    if [ "${2:-}" = resume ]; then printf '{"type":"turn.started"}\n'
    else printf '{"type":"thread.started","thread_id":"%s"}\n' "${FAKE_THREAD_ID:-}"; fi ;;
esac
exit 0
STUB
chmod +x "$WORK/fake-bin/provider"

MODEL="team/model-v2"
UUID1="123e4567-e89b-42d3-a456-426614174000"
UUID2="0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"

write_auth() { # write_auth claude|codex
  case "$1" in
    claude) mkdir -p "$FIXTURE_HOME/.claude"; chmod 0700 "$FIXTURE_HOME/.claude"
            printf '{"k":"x"}' > "$FIXTURE_HOME/.claude/.credentials.json"; chmod 0600 "$FIXTURE_HOME/.claude/.credentials.json" ;;
    codex)  mkdir -p "$FIXTURE_HOME/.codex"; chmod 0700 "$FIXTURE_HOME/.codex"
            printf '{"k":"x"}' > "$FIXTURE_HOME/.codex/auth.json"; chmod 0600 "$FIXTURE_HOME/.codex/auth.json" ;;
  esac
}
write_auth claude; write_auth codex

OUT=""; ERR=""; RC=0
# call <claude|codex> <adapter-arg>...   (cwd = project root; secrets in the caller env on purpose)
call() {
  local kind="$1" adapter binvar; shift
  case "$kind" in claude) adapter=$ADAPTER_CLAUDE; binvar=AIB_CLAUDE_BIN;; codex) adapter=$ADAPTER_CODEX; binvar=AIB_CODEX_BIN;; esac
  rm -f "$FAKE_ARGV_OUT" "$FAKE_ENV_OUT" "$FAKE_CWD_OUT" "$FAKE_STDIN_OUT"
  RC=0
  OUT="$(cd "$FIXTURE_CWD" && env -i HOME="$FIXTURE_HOME" PATH="$SYSTEM_PATH" "$binvar=$WORK/fake-bin/provider" \
    FAKE_KIND="$kind" FAKE_STATE="$FAKE_STATE" FAKE_THREAD_ID="$UUID1" \
    FAKE_ARGV_OUT="$FAKE_ARGV_OUT" FAKE_ENV_OUT="$FAKE_ENV_OUT" FAKE_CWD_OUT="$FAKE_CWD_OUT" FAKE_STDIN_OUT="$FAKE_STDIN_OUT" \
    ANTHROPIC_API_KEY=leak1 CLAUDE_CODE_OAUTH_TOKEN=leak2 \
    "$adapter" "$@" 2>"$WORK/stderr")" || RC=$?
  ERR="$(cat "$WORK/stderr" 2>/dev/null)"
}
# turn <kind> <sid> <sandbox> <effort> <prompt>  — the 12-token form
turn() { call "$1" session-turn "$2" -m "$MODEL" -s "$3" -c "model_reasoning_effort=\"$4\"" -c 'approval_policy="never"' -- "$5"; }
# old <kind> <sandbox> <effort> <prompt> — the 11-token form
old() { call "$1" exec -m "$MODEL" -s "$2" -c "model_reasoning_effort=\"$3\"" -c 'approval_policy="never"' -- "$4"; }

reset_state() { find "$FAKE_STATE" -mindepth 1 -delete; }
argv() { cat "$FAKE_ARGV_OUT" 2>/dev/null; }
bracket() { local a; for a in "$@"; do printf '[%s]\n' "$a"; done; }
joined() { bracket "$@"; }   # trailing newline is stripped by $( )
ran() { [ -s "$FAKE_ARGV_OUT" ]; }
# argv with one `<flag> <value>` pair removed / the value of that pair ('' if absent)
argv_without_pair() {
  [ -r "$FAKE_ARGV_OUT" ] || return 0
  awk -v f="[$1]" 'skip { skip=0; next } $0 == f { skip=1; next } { print }' "$FAKE_ARGV_OUT"
}
pair_value() {
  [ -r "$FAKE_ARGV_OUT" ] || return 0
  awk -v f="[$1]" 'v { sub(/^\[/, ""); sub(/\]$/, ""); print; exit } $0 == f { v=1 }' "$FAKE_ARGV_OUT"
}
count_in() { printf '%s\n' "$2" | grep -cF -- "$1"; }

# =============================================================================
# Block C — claude-code
# =============================================================================
CLAUDE_BASE="$(joined -p --model "$MODEL" --effort high --permission-mode bypassPermissions \
  --output-format text --setting-sources '' --strict-mcp-config --add-dir "$CWD_RESOLVED")"

# T1 new session: ADR-0010 flags minus --no-session-persistence, plus --session-id <uuid>
PROMPT=$'line one\nline two'
turn claude "new:$UUID1" workspace-write high "$PROMPT"
eq "T1: session-turn new:<uuid> reaches the provider (rc 0)" "$RC" 0
rest="$(argv_without_pair --session-id)"
eq "T1: --session-id carries the bare uuid (no new: prefix)" "$(pair_value --session-id)" "$UUID1"
eq "T1: argv minus the pair is exactly the ADR-0010 flags minus --no-session-persistence" "$rest" "$CLAUDE_BASE"
hasnt "T1: no --no-session-persistence" "$(argv)" "[--no-session-persistence]"
hasnt "T1: no --resume on a new session" "$(argv)" "[--resume]"
printf '%s' "$PROMPT" > "$WORK/expect-stdin"
if cmp -s "$WORK/expect-stdin" "$FAKE_STDIN_OUT"; then ok "T1: prompt arrives on stdin byte-exact"; else no "T1: prompt arrives on stdin byte-exact"; fi
has "T1: CLAUDE_CONFIG_DIR is the broker home's .claude (same as exec)" "$(cat "$FAKE_ENV_OUT" 2>/dev/null)" "CLAUDE_CONFIG_DIR=$FIXTURE_HOME/.claude"
hasnt "T1: ANTHROPIC_API_KEY unset for the child (same as exec)" "$(cat "$FAKE_ENV_OUT" 2>/dev/null)" "ANTHROPIC_API_KEY"
hasnt "T1: CLAUDE_CODE_OAUTH_TOKEN unset for the child (same as exec)" "$(cat "$FAKE_ENV_OUT" 2>/dev/null)" "CLAUDE_CODE_OAUTH_TOKEN"
eq "T1: cwd is preserved" "$(cat "$FAKE_CWD_OUT" 2>/dev/null)" "$CWD_RESOLVED"

# T2 continue
reset_state; : > "$FAKE_STATE/$UUID2"
turn claude "$UUID2" workspace-write high "again"
eq "T2: session-turn <uuid> reaches the provider (rc 0)" "$RC" 0
rest="$(argv_without_pair --resume)"
eq "T2: --resume carries the uuid" "$(pair_value --resume)" "$UUID2"
eq "T2: argv minus the pair is exactly the same base flags" "$rest" "$CLAUDE_BASE"
hasnt "T2: no --session-id on a resume" "$(argv)" "[--session-id]"

# T3 closed shape: sid regex and token count -> 65, provider never invoked
bad_sids=("new:" "new:not-a-uuid" "not-a-uuid" "" "new:${UUID1^^}" "${UUID1^^}" "new:new:$UUID1" "$UUID1 extra" "new:${UUID1}0" "${UUID1:0:35}" "-$UUID1" "new:../$UUID1")
for sid in "${bad_sids[@]}"; do
  turn claude "$sid" workspace-write high "p"
  eq "T3: sid '$sid' is refused with 65" "$RC" 65
  if ran; then no "T3: sid '$sid' never reaches the provider"; else ok "T3: sid '$sid' never reaches the provider"; fi
done
call claude session-turn "new:$UUID1" -m "$MODEL" -s workspace-write -c 'model_reasoning_effort="high"' -c 'approval_policy="never"' --
eq "T3: 11 tokens (prompt missing) -> 65" "$RC" 65
call claude session-turn "new:$UUID1" -m "$MODEL" -s workspace-write -c 'model_reasoning_effort="high"' -c 'approval_policy="never"' -- p extra
eq "T3: 13 tokens -> 65" "$RC" 65
call claude session-turn "new:$UUID1" -m "$MODEL" -s workspace-write -c 'model_reasoning_effort="high"' -c 'approval_policy="never"' p --
eq "T3: sentinel not in position 11 -> 65" "$RC" 65
call claude session-turn "new:$UUID1" -m "$MODEL" -s workspace-write -c 'model_reasoning_effort="turbo"' -c 'approval_policy="never"' -- p
eq "T3: invalid effort on the new form -> 65" "$RC" 65
turn claude "new:$UUID1" danger-full-access high p
eq "T3: danger-full-access on the new form -> 65" "$RC" 65
call claude session-turn "new:$UUID1" -m "$MODEL" -s workspace-write -c 'model_reasoning_effort="high"' -c 'approval_policy="on-request"' -- p
eq "T3: approval other than never -> 65" "$RC" 65

# T4 golden: the 11-token exec form is unchanged
old claude workspace-write high "golden"
eq "T4: exec form still reaches the provider" "$RC" 0
GOLD="$(joined -p --model "$MODEL" --effort high --permission-mode bypassPermissions --no-session-persistence \
  --output-format text --setting-sources '' --strict-mcp-config --add-dir "$CWD_RESOLVED")"
eq "T4: exec argv is byte-identical to today (golden)" "$(argv)" "$GOLD"
hasnt "T4: exec form never gains --session-id/--resume" "$(argv)" "[--session-id]"

# T5 read-only keeps --disallowedTools on both paths; workspace-write never has it
reset_state
turn claude "new:$UUID2" read-only medium "ro"
has "T5: read-only new session adds --disallowedTools" "$(argv)" "[--disallowedTools=Edit,Write,NotebookEdit]"
reset_state; : > "$FAKE_STATE/$UUID1"
turn claude "$UUID1" read-only medium "ro"
has "T5: read-only resume adds --disallowedTools" "$(argv)" "[--disallowedTools=Edit,Write,NotebookEdit]"
turn claude "$UUID1" workspace-write medium "rw"
hasnt "T5: workspace-write resume has no --disallowedTools" "$(argv)" "--disallowedTools"

# T6 forbidden words are unreachable: any argv outside the closed shape -> 65
for w in --bg agents --continue --fork-session app-server remote-control; do
  call claude "$w"; eq "T6: bare '$w' as the mode -> 65" "$RC" 65
  call claude session-turn "$w" -m "$MODEL" -s workspace-write -c 'model_reasoning_effort="high"' -c 'approval_policy="never"' -- p
  eq "T6: '$w' in the sid position -> 65" "$RC" 65
  call claude session-turn "new:$UUID1" "$w" "$MODEL" -s workspace-write -c 'model_reasoning_effort="high"' -c 'approval_policy="never"' -- p
  eq "T6: '$w' in place of -m -> 65" "$RC" 65
  if ran; then no "T6: '$w' never reaches the provider"; else ok "T6: '$w' never reaches the provider"; fi
done
call claude resume "$UUID1" -m "$MODEL" -s workspace-write -c 'model_reasoning_effort="high"' -c 'approval_policy="never"' -- p
eq "T6: an invented mode name (resume) -> 65" "$RC" 65

# T7 the adapter does not interpret provider errors: rc and text pass through
reset_state; : > "$FAKE_STATE/$UUID1"
turn claude "new:$UUID1" workspace-write high p
eq "T7: 'already in use' -> rc 1 passed through" "$RC" 1
has "T7: …with the provider's own text" "$ERR" "already in use"
reset_state
turn claude "$UUID2" workspace-write high p
eq "T7: 'No conversation found' -> rc 1 passed through" "$RC" 1
has "T7: …with the provider's own text" "$ERR" "No conversation found"
reset_state

# =============================================================================
# Block X — codex
# =============================================================================
CODEX_TAIL=(--skip-git-repo-check --dangerously-bypass-approvals-and-sandbox -- -)

# T8 new
turn codex "new:$UUID1" workspace-write high "hello codex"
eq "T8: session-turn new:<uuid> reaches the provider (rc 0)" "$RC" 0
eq "T8: argv is exec --json … with -s, no --ephemeral, prompt via stdin" "$(argv)" \
  "$(joined exec --json -m "$MODEL" -s workspace-write -c 'model_reasoning_effort="high"' -c 'approval_policy="never"' "${CODEX_TAIL[@]}")"
eq "T8: prompt on stdin" "$(cat "$FAKE_STDIN_OUT" 2>/dev/null)" "hello codex"
hasnt "T8: the new: prefix and uuid are not forwarded (codex assigns its own id)" "$(argv)" "$UUID1"

# T9 resume: no -s forwarded, -s still validated (65, see header)
turn codex "$UUID2" workspace-write max "again"
eq "T9: session-turn <uuid> reaches the provider (rc 0)" "$RC" 0
a="$(argv)"
has "T9: argv starts exec resume <uuid> --json -m … -c effort -c approval" "$a" \
  "$(joined exec resume "$UUID2" --json -m "$MODEL" -c 'model_reasoning_effort="xhigh"' -c 'approval_policy="never"')"
hasnt "T9: no -s forwarded on resume" "$a" "[-s]"
hasnt "T9: no --ephemeral on resume" "$a" "[--ephemeral]"
has "T9: bypass flag still present" "$a" "[--dangerously-bypass-approvals-and-sandbox]"
eq "T9: prompt on stdin" "$(cat "$FAKE_STDIN_OUT" 2>/dev/null)" "again"
turn codex "$UUID2" danger-full-access high p
eq "T9: danger-full-access is still refused on the resume path (65)" "$RC" 65
turn codex "$UUID2" wide-open high p
eq "T9: an unknown sandbox is still refused on the resume path (65)" "$RC" 65
if ran; then no "T9: a refused sandbox never reaches the provider"; else ok "T9: a refused sandbox never reaches the provider"; fi
for sid in "new:" "not-a-uuid" "new:${UUID1^^}" "new:new:$UUID1"; do
  turn codex "$sid" workspace-write high p
  eq "T9: codex sid '$sid' is refused with 65" "$RC" 65
done
for w in --bg agents app-server remote-control; do
  call codex session-turn "$w" -m "$MODEL" -s workspace-write -c 'model_reasoning_effort="high"' -c 'approval_policy="never"' -- p
  eq "T9: codex '$w' in the sid position -> 65" "$RC" 65
done

# T10 golden exec
old codex workspace-write high "golden"
eq "T10: exec form unchanged (golden)" "$(argv)" \
  "$(joined exec -m "$MODEL" -s workspace-write -c 'model_reasoning_effort="high"' -c 'approval_policy="never"' --skip-git-repo-check --ephemeral --dangerously-bypass-approvals-and-sandbox -- -)"

# T11 credential preflight identical on both paths
mv "$FIXTURE_HOME/.codex/auth.json" "$WORK/auth.saved"
old codex workspace-write high p;           eq "T11: exec without credentials -> 78 (baseline)" "$RC" 78
turn codex "new:$UUID1" workspace-write high p; eq "T11: session-turn new without credentials -> 78" "$RC" 78
turn codex "$UUID2" workspace-write high p;     eq "T11: session-turn resume without credentials -> 78" "$RC" 78
if ran; then no "T11: provider never reached without credentials"; else ok "T11: provider never reached without credentials"; fi
mv "$WORK/auth.saved" "$FIXTURE_HOME/.codex/auth.json"
chmod 0644 "$FIXTURE_HOME/.codex/auth.json"
turn codex "$UUID2" workspace-write high p; eq "T11: world-readable credential on resume -> 78" "$RC" 78
chmod 0600 "$FIXTURE_HOME/.codex/auth.json"
mv "$FIXTURE_HOME/.claude/.credentials.json" "$WORK/cauth.saved"
turn claude "new:$UUID1" workspace-write high p; eq "T11: claude session-turn without credentials -> 78" "$RC" 78
mv "$WORK/cauth.saved" "$FIXTURE_HOME/.claude/.credentials.json"

# T12 (spike item) the thread id reaches the caller on stdout, passed through untouched
turn codex "new:$UUID1" workspace-write high p
has "T12: thread.started with thread_id is present on adapter stdout" "$OUT" "\"type\":\"thread.started\",\"thread_id\":\"$UUID1\""
turn codex "$UUID2" workspace-write high p
hasnt "T12: no thread.started on a resume turn (fake contract)" "$OUT" "thread.started"

printf '\nadapter_session_turn_spec: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
