#!/usr/bin/env bash
# ai-bobnet — RED spec for the `codex` provider adapter itself (Sprint I-B slice 1).
#
# WHAT THIS PINS
#   docs/CONTRACT-codex-run.md §4.1 (the adapter ABI), docs/CONFINEMENT.md
#   ("Effective-sandbox -> LL_RW"), docs/PROVIDERS.md, and docs/decisions/0009-codex-adapter.md
#   are the docs-first pin this spec exercises against code. `adapters/codex` does not exist yet
#   on this tree, and run_confined's LL_RW derivation and bin/launch-agent's provider dispatch are
#   both still in their pre-amendment shape — every block below is expected RED until the builder
#   lands `adapters/codex` and the two lib/aibobnet.sh + bin/launch-agent amendments. A block whose
#   assertions already pass on the unbuilt tree is a regression guard (the allow-list grep, the
#   already-working resolver refusal for an unregistered provider), not a mistake.
#
#   FOUR BLOCKS:
#     A. `adapters/codex` invoked directly (env -i, a fake wrapped `codex` binary that records
#        argv/env/cwd/stdin/pid) — argv/flag/stdin/env pass-through, exec identity.
#     B. Same harness, refusal paths — shape/effort/sandbox (65), credential (78), missing binary
#        (127, unmasked).
#     C. `run_confined`'s LL_RW derivation, sourced from lib/aibobnet.sh directly, against a stub
#        confinement helper (same CLI-contract shape as tests/broker_enact_spec.sh's), for both
#        effective sandboxes.
#     D. `bin/launch-agent`'s provider dispatch generalisation — a second registered (non-codex)
#        provider on the direct path, an unregistered provider still resolver-refused, and the
#        `codex)` case-literal gone from the source.
#
#   TEST-SEAM NOTE (docs/PROVIDERS.md): `adapters/codex` resolves its wrapped binary from
#   `AIB_CODEX_BIN` if set, defaulting to a fixed provisioning path otherwise. This spec is the one
#   caller that sets it — the broker's own `env -i` allow-list (HOME PATH) is never widened for it,
#   and Blocks A/B therefore test the adapter script in isolation, not through the full confined
#   broker chain (that integration is tests/broker_enact_spec.sh's job once the registry names a
#   real adapter path).
#
#   TRAPS SELF-REVIEWED BEFORE WRITING THIS (recurring findings on earlier specs in this repo):
#     - No EXIT trap kills a captured pid: the only backgrounded call (A9, exec identity) is always
#       `wait`-ed for in the same statement group before the script moves on, so there is never a
#       live pid left for a trap to chase, and the sole EXIT trap here only removes $WORK.
#     - Every JSON fixture (Block D's registry) uses the same printf/escaped-quote literal
#       convention already used by tests/codex_run_spec.sh, not a heredoc with unescaped
#       interpolation.
#     - Every per-case fixture writer removes prior output files BEFORE writing new instrumentation
#       and BEFORE invoking the thing under test — never after — so a case that crashes leaves no
#       stale file for the next case to misread as its own.
set -uo pipefail

SRC_ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
# shellcheck source=lib/aibobnet.sh
. "$SRC_ROOT/lib/aibobnet.sh"

ADAPTER="$SRC_ROOT/adapters/codex"
LAUNCH_AGENT="$SRC_ROOT/bin/launch-agent"
SYSTEM_PATH="$PATH"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-codexadapter.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
no(){ fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; }
skip(){ printf 'ok   - (skipped: %s)\n' "$1"; }
eq(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2' want '$3')"; fi; }
has(){ case "$2" in *"$3"*) ok "$1";; *) no "$1 (missing '$3')";; esac; }
hasnt(){ case "$2" in *"$3"*) no "$1 (unexpected '$3')";; *) ok "$1";; esac; }
count_matches_in_string(){ local n; n="$(printf '%s\n' "$2" | grep -c -- "$1" 2>/dev/null)"; printf '%s' "${n:-0}"; }
file_byte_count(){ [ -e "$1" ] && wc -c < "$1" 2>/dev/null || printf 0; }

# =============================================================================
# Blocks A + B fixtures — adapters/codex invoked directly, a fake wrapped binary
# =============================================================================

FIXTURE_HOME="$WORK/broker-home"
FIXTURE_CODEX_DIR="$FIXTURE_HOME/.codex"
mkdir -p "$FIXTURE_HOME"

FAKE_CODEX="$WORK/fake-bin/codex"
mkdir -p "$WORK/fake-bin"
FAKE_ARGV_OUT="$WORK/fake-argv"
FAKE_ENV_OUT="$WORK/fake-env"
FAKE_CWD_OUT="$WORK/fake-cwd"
FAKE_PID_OUT="$WORK/fake-pid"
FAKE_STDIN_OUT="$WORK/fake-stdin"

cat > "$FAKE_CODEX" <<'STUB'
#!/usr/bin/env bash
# The stand-in for the real, pinned codex-cli static binary: records everything
# adapters/codex hands it (argv, its own environment, cwd, pid, and every stdin
# byte to EOF), then answers with a fixed marker so a caller can tell it ran.
printf '%s\n' "$$" > "${FAKE_PID_OUT:?FAKE_PID_OUT not set}"
pwd -P > "${FAKE_CWD_OUT:?FAKE_CWD_OUT not set}"
: > "${FAKE_ARGV_OUT:?FAKE_ARGV_OUT not set}"
for a in "$@"; do printf '[%s]\n' "$a" >> "$FAKE_ARGV_OUT"; done
env > "${FAKE_ENV_OUT:?FAKE_ENV_OUT not set}"
cat > "${FAKE_STDIN_OUT:?FAKE_STDIN_OUT not set}"
printf 'FAKE_CODEX_OK\n'
exit 0
STUB
chmod +x "$FAKE_CODEX"

MODEL="team/model-v2"

write_auth_ok() {
  mkdir -p "$FIXTURE_CODEX_DIR"
  chmod 0700 "$FIXTURE_CODEX_DIR"
  printf '{"key":"x"}' > "$FIXTURE_CODEX_DIR/auth.json"
  chmod 0600 "$FIXTURE_CODEX_DIR/auth.json"
}
write_auth_missing() {
  mkdir -p "$FIXTURE_CODEX_DIR"
  chmod 0700 "$FIXTURE_CODEX_DIR"
  rm -f "$FIXTURE_CODEX_DIR/auth.json"
}
write_auth_wrong_mode() {
  write_auth_ok
  chmod 0644 "$FIXTURE_CODEX_DIR/auth.json"
}

reset_fake_outputs() {
  rm -f "$FAKE_ARGV_OUT" "$FAKE_ENV_OUT" "$FAKE_CWD_OUT" "$FAKE_PID_OUT" "$FAKE_STDIN_OUT"
}

# call_adapter_raw <arg>... — invokes adapters/codex directly, env -i, with only the
# vars this test-seam harness needs (docs/PROVIDERS.md's AIB_CODEX_BIN note above).
# Sets ADAPTER_OUT / ADAPTER_RC.
ADAPTER_OUT=""; ADAPTER_RC=0
call_adapter_raw() {
  reset_fake_outputs
  ADAPTER_OUT=""; ADAPTER_RC=0
  ADAPTER_OUT="$(
    env -i HOME="$FIXTURE_HOME" PATH="$SYSTEM_PATH" AIB_CODEX_BIN="$FAKE_CODEX" \
      FAKE_ARGV_OUT="$FAKE_ARGV_OUT" FAKE_ENV_OUT="$FAKE_ENV_OUT" FAKE_CWD_OUT="$FAKE_CWD_OUT" \
      FAKE_PID_OUT="$FAKE_PID_OUT" FAKE_STDIN_OUT="$FAKE_STDIN_OUT" \
      "$ADAPTER" "$@" 2>&1
  )" || ADAPTER_RC=$?
}

# call_adapter <sandbox> <effort> <prompt> — the well-formed ABI shape.
call_adapter() {
  call_adapter_raw exec -m "$MODEL" -s "$1" \
    -c "model_reasoning_effort=\"$2\"" -c 'approval_policy="never"' -- "$3"
}

provider_was_called() { [ -s "$FAKE_ARGV_OUT" ]; }

# =============================================================================
# Block A — well-formed ABI: argv/flag/stdin/env pass-through, exec identity
# =============================================================================

write_auth_ok

MULTILINE_PROMPT=$'first line\nsecond line\nthird line'
call_adapter workspace-write high "$MULTILINE_PROMPT"
argv="$(cat "$FAKE_ARGV_OUT" 2>/dev/null)"
eq "A: well-formed call reaches the wrapped binary" "$ADAPTER_RC" 0
has "A: argv passes -m/model byte-exact" "$argv" "[-m]
[$MODEL]"
has "A: argv passes -s/sandbox byte-exact" "$argv" "[-s]
[workspace-write]"
has "A: argv passes model_reasoning_effort byte-exact" "$argv" '[model_reasoning_effort="high"]'
has "A: argv passes approval_policy=never byte-exact" "$argv" '[approval_policy="never"]'
eq "A: --skip-git-repo-check appears exactly once" "$(count_matches_in_string -- '\[--skip-git-repo-check\]' "$argv")" 1
eq "A: --ephemeral appears exactly once" "$(count_matches_in_string -- '\[--ephemeral\]' "$argv")" 1
eq "A: --dangerously-bypass-approvals-and-sandbox appears exactly once" \
  "$(count_matches_in_string -- '\[--dangerously-bypass-approvals-and-sandbox\]' "$argv")" 1
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

env_out="$(cat "$FAKE_ENV_OUT" 2>/dev/null)"
has "A: the wrapper exports SHELL=/bin/bash" "$env_out" "SHELL=/bin/bash"
has "A: the wrapper exports TERM=dumb" "$env_out" "TERM=dumb"

grep -q 'AIB_ENV_ALLOW_DEFAULT="HOME PATH"' "$SRC_ROOT/lib/aibobnet.sh" \
  && ok "A: the broker's own env -i allow-list is still exactly HOME PATH (grep pin)" \
  || no "A: the broker's own env -i allow-list is still exactly HOME PATH (grep pin)"

# Exec identity: adapters/codex must exec into the wrapped binary, never fork — the
# fake binary's own $$ must equal the pid bash assigned the adapter invocation itself.
reset_fake_outputs
(
  env -i HOME="$FIXTURE_HOME" PATH="$SYSTEM_PATH" AIB_CODEX_BIN="$FAKE_CODEX" \
    FAKE_ARGV_OUT="$FAKE_ARGV_OUT" FAKE_ENV_OUT="$FAKE_ENV_OUT" FAKE_CWD_OUT="$FAKE_CWD_OUT" \
    FAKE_PID_OUT="$FAKE_PID_OUT" FAKE_STDIN_OUT="$FAKE_STDIN_OUT" \
    "$ADAPTER" exec -m "$MODEL" -s workspace-write \
      -c 'model_reasoning_effort="high"' -c 'approval_policy="never"' -- "pid-check" \
    >"$WORK/pidcheck-out" 2>&1 &
  wrapper_pid=$!
  wait "$wrapper_pid"
  printf '%s' "$wrapper_pid" > "$WORK/wrapper-pid"
)
wrapper_pid="$(cat "$WORK/wrapper-pid" 2>/dev/null)"
fake_pid="$(cat "$FAKE_PID_OUT" 2>/dev/null)"
if [ -n "$wrapper_pid" ] && [ -n "$fake_pid" ] && [ "$wrapper_pid" = "$fake_pid" ]; then
  ok "A: adapters/codex execs into the wrapped binary (fake pid == wrapper pid)"
else
  no "A: adapters/codex execs into the wrapped binary (fake pid == wrapper pid) (wrapper='$wrapper_pid' fake='$fake_pid')"
fi

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
eq "B2: an unknown effort value is refused (65)" "$ADAPTER_RC" 65
if provider_was_called; then no "B2: the wrapped binary never runs on refusal"; else ok "B2: the wrapped binary never runs on refusal"; fi
hasnt "B2: the prompt never appears in refusal output" "$ADAPTER_OUT" "$PROMPT_MARKER"

# B3: malformed shape, several independent ways to fail positive validation.
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
eq "B4: a missing auth.json is refused (78)" "$ADAPTER_RC" 78
if provider_was_called; then no "B4: the wrapped binary never runs on a credential refusal"; else ok "B4: the wrapped binary never runs on a credential refusal"; fi
hasnt "B4: the prompt never appears in refusal output" "$ADAPTER_OUT" "$PROMPT_MARKER"

write_auth_wrong_mode
call_adapter workspace-write high "$PROMPT_MARKER"
eq "B5: an auth.json with mode 0644 is refused (78)" "$ADAPTER_RC" 78
if provider_was_called; then no "B5: the wrapped binary never runs on a credential refusal"; else ok "B5: the wrapped binary never runs on a credential refusal"; fi
hasnt "B5: the prompt never appears in refusal output" "$ADAPTER_OUT" "$PROMPT_MARKER"

write_auth_ok
own_uid="$(id -u)"
foreign_uid=$((own_uid + 1))
if chown "$foreign_uid" "$FIXTURE_CODEX_DIR/auth.json" 2>/dev/null \
   && [ "$(stat -c %u "$FIXTURE_CODEX_DIR/auth.json" 2>/dev/null || stat -f %u "$FIXTURE_CODEX_DIR/auth.json" 2>/dev/null)" = "$foreign_uid" ]; then
  call_adapter workspace-write high "$PROMPT_MARKER"
  eq "B6: a foreign-owned auth.json is refused (78)" "$ADAPTER_RC" 78
  if provider_was_called; then no "B6: the wrapped binary never runs on a credential refusal"; else ok "B6: the wrapped binary never runs on a credential refusal"; fi
  hasnt "B6: the prompt never appears in refusal output" "$ADAPTER_OUT" "$PROMPT_MARKER"
else
  skip "B6: foreign-owned auth.json (this host cannot chown to a different uid without root)"
  skip "B6: foreign-owned auth.json — wrapped binary never runs"
  skip "B6: foreign-owned auth.json — prompt never echoed"
fi
write_auth_ok

# B7: the wrapper never manufactures 124/126/127 itself — a missing wrapped binary's
# own 127 (bash's native exec failure) must surface unmasked, not be remapped to 65/78/126.
reset_fake_outputs
ADAPTER_OUT=""; ADAPTER_RC=0
ADAPTER_OUT="$(
  env -i HOME="$FIXTURE_HOME" PATH="$SYSTEM_PATH" AIB_CODEX_BIN="$WORK/does-not-exist/codex" \
    FAKE_ARGV_OUT="$FAKE_ARGV_OUT" FAKE_ENV_OUT="$FAKE_ENV_OUT" FAKE_CWD_OUT="$FAKE_CWD_OUT" \
    FAKE_PID_OUT="$FAKE_PID_OUT" FAKE_STDIN_OUT="$FAKE_STDIN_OUT" \
    "$ADAPTER" exec -m "$MODEL" -s workspace-write \
      -c 'model_reasoning_effort="high"' -c 'approval_policy="never"' -- "hello" 2>&1
)" || ADAPTER_RC=$?
eq "B7: a missing wrapped binary surfaces its own unmasked 127" "$ADAPTER_RC" 127

# =============================================================================
# Block C — run_confined's LL_RW derivation (docs/CONFINEMENT.md, "Effective-sandbox -> LL_RW")
# =============================================================================

C_BROKER_HOME="$WORK/c-broker-home"
CPROJECT_ROOT="$WORK/c-project-home"
mkdir -p "$C_BROKER_HOME" "$CPROJECT_ROOT"

C_STUB_DIR="$WORK/c-stub-bin"
mkdir -p "$C_STUB_DIR"
C_LL_LOG="$WORK/c-ll-log"
cat > "$C_STUB_DIR/landlock.conf" <<EOF
STUB_LL_LOG='$C_LL_LOG'
EOF
C_LANDLOCK_STUB="$C_STUB_DIR/landlock-exec"
cat > "$C_LANDLOCK_STUB" <<'STUB'
#!/usr/bin/env bash
# Same CLI-contract shape as tests/broker_enact_spec.sh's own stub (LL_RO/LL_RW logged,
# LL_STATUS_FD closed silently on success, always execs its argument) — config comes
# from a file beside the binary, not the environment, because run_confined's own
# `env -i` call to this helper strips everything else.
_cfg="$(cd "$(dirname "$0")" && pwd)/landlock.conf"
[ -f "$_cfg" ] && . "$_cfg"
{
  printf 'LL_RO=%s\n' "${LL_RO-<unset>}"
  printf 'LL_RW=%s\n' "${LL_RW-<unset>}"
  printf '---\n'
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

c_enact_record() { # c_enact_record <sandbox>
  printf 'adapter=%s\nroot=%s\ncwd=%s\nsandbox=%s\neffort=high\nmodel=team/model-v2\ntimeout=5' \
    "$C_ADAPTER" "$CPROJECT_ROOT" "$CPROJECT_ROOT" "$1"
}

run_confined_ll() { # run_confined_ll <sandbox>
  : > "$C_LL_LOG"
  local decided_id
  decided_id="$(c_seed_decided)"
  HOME="$C_BROKER_HOME" AIB_CONFINE_BIN="$C_LANDLOCK_STUB" \
    aib_enact_launch "$(c_enact_record "$1")" "hello" \
    "$C_EVENTS_FILE" "$C_EVENTS_LOCK" "$C_ENVELOPE_KV" "$decided_id" \
    >"$WORK/c-resp" 2>"$WORK/c-err"
}
c_last_ll_rw() { grep '^LL_RW=' "$C_LL_LOG" | tail -1 | sed 's/^LL_RW=//'; }

if command -v aib_enact_launch >/dev/null 2>&1 || type aib_enact_launch >/dev/null 2>&1; then
  run_confined_ll read-only
  c_ll_rw="$(c_last_ll_rw)"
  has "C1: read-only LL_RW carries /tmp:/var/tmp:/dev" "$c_ll_rw" "/tmp:/var/tmp:/dev"
  has "C1: read-only LL_RW carries \$HOME/.codex" "$c_ll_rw" "$C_BROKER_HOME/.codex"
  hasnt "C1: read-only LL_RW does NOT carry the project root (read-only is enforced)" "$c_ll_rw" "$CPROJECT_ROOT"
  hasnt "C1: read-only LL_RW never carries /var/lib/aib/auth" "$c_ll_rw" "/var/lib/aib/auth"

  run_confined_ll workspace-write
  c_ll_rw="$(c_last_ll_rw)"
  has "C2: workspace-write LL_RW carries /tmp:/var/tmp:/dev" "$c_ll_rw" "/tmp:/var/tmp:/dev"
  has "C2: workspace-write LL_RW carries \$HOME/.codex" "$c_ll_rw" "$C_BROKER_HOME/.codex"
  has "C2: workspace-write LL_RW carries the project root" "$c_ll_rw" "$CPROJECT_ROOT"
  hasnt "C2: workspace-write LL_RW never carries /var/lib/aib/auth" "$c_ll_rw" "/var/lib/aib/auth"
else
  no "C1/C2: aib_enact_launch is defined (not built yet)"
fi

# =============================================================================
# Block D — bin/launch-agent's provider dispatch generalisation
# =============================================================================

D_WORK="$WORK/d-home"
mkdir -p "$D_WORK/acme/standup"
D_STUB_BIN="$WORK/d-stub-bin"
mkdir -p "$D_STUB_BIN"
D_SENTINEL="$WORK/d-sentinel"
D_ARGV_OUT="$WORK/d-argv"
D_ADAPTER="$D_STUB_BIN/stub-provider"
cat > "$D_ADAPTER" <<STUBEOF
#!/usr/bin/env bash
printf 'called\n' >> "$D_SENTINEL"
: > "$D_ARGV_OUT"
for a in "\$@"; do printf '[%s]\n' "\$a" >> "$D_ARGV_OUT"; done
printf 'STUB_PROVIDER_OK\n'
exit 0
STUBEOF
chmod +x "$D_ADAPTER"

D_REG="$WORK/d-registry.json"
printf '%s\n' "{
  \"schema_version\": 4,
  \"providers\": {
    \"codex\": {
      \"adapter\": \"/nonexistent/codex-adapter-never-invoked-by-this-block\",
      \"cap_sandbox\": \"workspace-write\",
      \"cap_tier\": \"t3\",
      \"cap_effort\": \"high\",
      \"cap_timeout\": \"900\"
    },
    \"stub\": {
      \"adapter\": \"$D_ADAPTER\",
      \"cap_sandbox\": \"workspace-write\",
      \"cap_tier\": \"t3\",
      \"cap_effort\": \"high\",
      \"cap_timeout\": \"900\"
    }
  },
  \"projects\": {
    \"acme\": {
      \"home\": \"$D_WORK/acme\",
      \"standup_dir\": \"$D_WORK/acme/standup\",
      \"mux_session\": \"acme\",
      \"provider\": \"stub\",
      \"model\": \"registry-model\",
      \"effort\": \"medium\"
    }
  },
  \"teams\": {},
  \"agents\": {
    \"acme-core\": { \"project\": \"acme\", \"profile\": \"engine-dev\", \"clearance\": \"t2\" },
    \"acme-ghost\": { \"project\": \"acme\", \"profile\": \"engine-dev\", \"clearance\": \"t2\", \"provider\": \"ghost\" }
  }
}" > "$D_REG"

rm -f "$D_SENTINEL" "$D_ARGV_OUT"
D_OUT=""; D_RC=0
D_OUT="$(
  PATH="$D_STUB_BIN:$SYSTEM_PATH" AIBOBNET_REGISTRY="$D_REG" \
    "$LAUNCH_AGENT" --as acme-core --prompt "d-prompt" 2>&1
)" || D_RC=$?
eq "D1: the direct path succeeds through a second registered (non-codex) provider" "$D_RC" 0
has "D1: the registered stub provider's output is relayed" "$D_OUT" "STUB_PROVIDER_OK"
if [ -s "$D_ARGV_OUT" ]; then ok "D1: the stub adapter was actually invoked"; else no "D1: the stub adapter was actually invoked"; fi

D_OUT=""; D_RC=0
D_OUT="$(
  PATH="$D_STUB_BIN:$SYSTEM_PATH" AIBOBNET_REGISTRY="$D_REG" \
    "$LAUNCH_AGENT" --as acme-ghost --prompt "d-prompt" 2>&1
)" || D_RC=$?
eq "D2: an unregistered provider still fails at the resolver's own config-error code" "$D_RC" 3

if grep -q 'codex)' "$LAUNCH_AGENT"; then
  no "D3: bin/launch-agent's hard-coded codex) case is gone (grep pin)"
else
  ok "D3: bin/launch-agent's hard-coded codex) case is gone (grep pin)"
fi

# =============================================================================
# Regression guard (not an assertion here): tests/broker_enact_spec.sh's own pass/fail
# totals must not move because of the LL_RW amendment Block C pins. Verified by the
# builder/gate by diffing that spec's own summary line before/after the build, per the
# report this file's commit is paired with — not re-derivable from inside this file.
# =============================================================================

total=$((pass+fail))
printf '\nadapter_codex_spec: %d checks, %d passed, %d failed\n' "$total" "$pass" "$fail"
[ "$fail" -eq 0 ]
