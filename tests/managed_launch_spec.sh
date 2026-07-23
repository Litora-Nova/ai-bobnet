#!/usr/bin/env bash
# ai-bobnet — RM-0 managed-launch acceptance.
# Uses only a PATH-prepended executable named `codex`; no provider-binary env seam.
set -uo pipefail

SRC_ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
LA="$SRC_ROOT/bin/launch-agent"
LOG="$SRC_ROOT/scripts/log.sh"
SYSTEM_PATH="$PATH"
TIMEOUT_BIN="$(command -v timeout)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-launch.XXXXXX")"
STATE="$WORK/state"
STUB_BIN="$WORK/stub-bin"
mkdir -p "$STATE/acme/standup" "$STUB_BIN"
REG="$WORK/registry.json"
SENTINEL="$WORK/provider-called"
POISON_SENTINEL="$WORK/poison-called"
ARGV_OUT="$WORK/argv"
ENV_OUT="$WORK/env"
PWD_OUT="$WORK/pwd"

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

write_v3() {
  local path="$1" provider="$2" effort="$3" standup_dir="${4:-$STATE/acme/standup}"
  printf '%s\n' "{
  \"schema_version\": 3,
  \"projects\": {
    \"acme\": {
      \"home\": \"$STATE/acme\",
      \"standup_dir\": \"$standup_dir\",
      \"mux_session\": \"acme\",
      \"provider\": \"$provider\",
      \"model\": \"project-model\",
      \"effort\": \"low\"
    }
  },
  \"teams\": {
    \"acme-engine\": { \"project\": \"acme\", \"model\": \"team/model-v2\" }
  },
  \"agents\": {
    \"acme-core\": {
      \"project\": \"acme\",
      \"team_uid\": \"acme-engine\",
      \"profile\": \"engine-dev\",
      \"clearance\": \"t2\",
      \"effort\": \"$effort\"
    }
  }
}" > "$path"
}

write_v2() {
  local path="$1"
  printf '%s\n' "{
  \"schema_version\": 2,
  \"projects\": { \"acme\": { \"home\": \"$STATE/acme\", \"standup_dir\": \"$STATE/acme/standup\", \"mux_session\": \"acme\" } },
  \"agents\": { \"acme-core\": { \"project\": \"acme\", \"profile\": \"engine-dev\", \"clearance\": \"t2\" } }
}" > "$path"
}

# Real managed test seam: the selected executable is literally `codex` via PATH.
printf '%s\n' '#!/usr/bin/env bash' \
  'printf "called\n" >> "$STUB_SENTINEL"' \
  ': > "$STUB_ARGV_OUT"' \
  'for arg in "$@"; do printf "[%s]\n" "$arg" >> "$STUB_ARGV_OUT"; done' \
  'pwd > "$STUB_PWD_OUT"' \
  'printf "agent_uid=%s\nproject_uid=%s\nagent_key=%s\nprofile=%s\nclearance=%s\nteam_uid=%s\n" \
    "${AIBOBNET_AGENT_UID-}" "${AIBOBNET_PROJECT_UID-}" "${AIBOBNET_AGENT_KEY-}" \
    "${AIBOBNET_PROFILE-}" "${AIBOBNET_CLEARANCE-}" "${AIBOBNET_TEAM_UID-}" > "$STUB_ENV_OUT"' \
  'printf "home=%s\nstandup_dir=%s\ninbox_path=%s\nmux_session=%s\nlegacy_standup=%s\n" \
    "${AIBOBNET_HOME-}" "${AIBOBNET_STANDUP_DIR-}" "${AIBOBNET_INBOX_PATH-}" \
    "${AIBOBNET_MUX_SESSION-}" "${STANDUP_DIR-}" >> "$STUB_ENV_OUT"' \
  'printf "provider=%s\nprovider_source=%s\nmodel=%s\nmodel_source=%s\neffort=%s\neffort_source=%s\nschema=%s\n" \
    "${AIBOBNET_PROVIDER-}" "${AIBOBNET_PROVIDER_SOURCE-}" "${AIBOBNET_MODEL-}" \
    "${AIBOBNET_MODEL_SOURCE-}" "${AIBOBNET_EFFORT-}" "${AIBOBNET_EFFORT_SOURCE-}" \
    "${AIBOBNET_REGISTRY_SCHEMA_VERSION-}" >> "$STUB_ENV_OUT"' \
  'printf "codex_run_bin=%s\n" "${CODEX_RUN_BIN-unset}" >> "$STUB_ENV_OUT"' \
  'case "${STUB_MODE:-ok}" in' \
  '  ok) printf "STUB_BUILT_OK\n"; exit 0;;' \
  '  sleep) sleep "${STUB_SLEEP:-5}"; exit 0;;' \
  '  err) printf "stub failure\n" >&2; exit "${STUB_RC:-7}";;' \
  '  mutate) rm -f -- "$STUB_REGISTRY"; printf "STUB_MUTATED_OK\n"; exit 0;;' \
  'esac' > "$STUB_BIN/codex"
chmod +x "$STUB_BIN/codex"

printf '%s\n' '#!/usr/bin/env bash' \
  'printf "poison\n" >> "$POISON_SENTINEL"' \
  'exit 99' > "$WORK/codex-poison"
chmod +x "$WORK/codex-poison"

pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
no(){ fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; }
eq(){ [ "$2" = "$3" ] && ok "$1" || no "$1 (got '$2' want '$3')"; }
has(){ case "$2" in *"$3"*) ok "$1";; *) no "$1 (missing '$3')";; esac; }
hasnt(){ case "$2" in *"$3"*) no "$1 (unexpected '$3')";; *) ok "$1";; esac; }
not_called(){ [ ! -e "$SENTINEL" ] && ok "$1" || no "$1 (provider executed)"; }

RUN_OUT=""; RUN_ERR=""; RUN_RC=0; CASE_MODE=ok; CASE_SLEEP=5; CASE_RC=7
run_launch() {
  local registry="$1"; shift
  rm -f "$SENTINEL" "$POISON_SENTINEL" "$ARGV_OUT" "$ENV_OUT" "$PWD_OUT"
  RUN_OUT=""; RUN_ERR=""; RUN_RC=0
  RUN_OUT="$(
    PATH="$STUB_BIN:$SYSTEM_PATH" \
    AIBOBNET_REGISTRY="$registry" \
    AIBOBNET_PROVIDER=ambient-provider AIBOBNET_PROVIDER_SOURCE=agent:ambient \
    AIBOBNET_MODEL=ambient-model AIBOBNET_MODEL_SOURCE=agent:ambient \
    AIBOBNET_EFFORT=ambient-effort AIBOBNET_EFFORT_SOURCE=agent:ambient \
    AIBOBNET_TEAM_UID=ambient-team AIBOBNET_CLEARANCE=t4 STANDUP_DIR="$WORK/ambient-standup" \
    CODEX_RUN_BIN="$WORK/codex-poison" POISON_SENTINEL="$POISON_SENTINEL" \
    STUB_SENTINEL="$SENTINEL" STUB_ARGV_OUT="$ARGV_OUT" STUB_ENV_OUT="$ENV_OUT" \
    STUB_PWD_OUT="$PWD_OUT" STUB_MODE="$CASE_MODE" STUB_SLEEP="$CASE_SLEEP" \
    STUB_RC="$CASE_RC" STUB_REGISTRY="$registry" \
      "$LA" "$@" 2>"$WORK/launch-stderr"
  )" || RUN_RC=$?
  RUN_ERR="$(<"$WORK/launch-stderr")"
  [ -z "$RUN_ERR" ] || RUN_OUT="${RUN_OUT}${RUN_OUT:+$'\n'}${RUN_ERR}"
}

write_v3 "$REG" codex high
HBLOG="$STATE/acme/standup/acme-core.log"
: > "$HBLOG"
run_launch "$REG" --as acme-core --label managed --prompt "make it so"
eq "managed success returns zero" "$RUN_RC" 0
has "managed success relays provider output" "$RUN_OUT" "STUB_BUILT_OK"
eq "managed launch executes provider once" "$(wc -l < "$SENTINEL" 2>/dev/null || printf 0)" 1
[ ! -e "$POISON_SENTINEL" ] && ok "CODEX_RUN_BIN poison is never executed" || no "CODEX_RUN_BIN poison is never executed"
argv="$(sed -n '1,100p' "$ARGV_OUT" 2>/dev/null)"
has "argv selects codex exec" "$argv" "[exec]"
has "argv uses resolved team model" "$argv" "[-m]
[team/model-v2]"
has "argv defaults sandbox to read-only" "$argv" "[-s]
[read-only]"
has "argv uses resolved agent effort" "$argv" '[model_reasoning_effort="high"]'
has "argv forces approval never" "$argv" '[approval_policy="never"]'
has "argv carries the prompt as one argument" "$argv" "[make it so]"
env_out="$(sed -n '1,100p' "$ENV_OUT" 2>/dev/null)"
has "child gets resolved identity and clearance" "$env_out" $'agent_uid=acme-core\nproject_uid=acme\nagent_key=core\nprofile=engine-dev\nclearance=t2'
has "child gets resolved direct team" "$env_out" "team_uid=acme-engine"
has "child gets resolved paths" "$env_out" "standup_dir=$STATE/acme/standup"
has "child gets resolved inbox" "$env_out" "inbox_path=$STATE/acme/standup/inbox/acme-core.md"
has "child gets resolved binding and provenance" "$env_out" $'provider=codex\nprovider_source=project:acme\nmodel=team/model-v2\nmodel_source=team:acme-engine\neffort=high\neffort_source=agent:acme-core\nschema=3'
has "child sees CODEX_RUN_BIN removed" "$env_out" "codex_run_bin=unset"
binding_emit="{\"event\":\"managed_launch_binding\",\"agent_uid\":\"acme-core\",\"provider\":\"codex\",\"provider_source\":\"project:acme\",\"model\":\"team/model-v2\",\"model_source\":\"team:acme-engine\",\"effort\":\"high\",\"effort_source\":\"agent:acme-core\",\"adapter_path\":\"$STUB_BIN/codex\"}"
has "launch emits structured resolved binding and adapter path on stderr" "$RUN_ERR" "$binding_emit"
has "busy heartbeat uses resolved model and effort" "$(<"$HBLOG")" "| busy | codex-run: team/model-v2/read-only effort=high — managed"
has "terminal heartbeat records success" "$(<"$HBLOG")" "| done | codex-run OK — managed"

# Managed dispatch rejects unsupported registry truth before any provider process.
V2="$WORK/v2.json"; write_v2 "$V2"
run_launch "$V2" --as acme-core --prompt x
eq "schema 2 managed launch is refused" "$RUN_RC" 3
not_called "schema 2 refusal happens before provider start"

UNKNOWN="$WORK/unknown-provider.json"; write_v3 "$UNKNOWN" claude-code high
run_launch "$UNKNOWN" --as acme-core --prompt x
eq "unsupported provider is refused" "$RUN_RC" 64
has "unsupported provider error names registry binding" "$RUN_OUT" "unsupported registry provider 'claude-code'"
not_called "unsupported provider refusal happens before provider start"

BAD_EFFORT="$WORK/bad-effort.json"; write_v3 "$BAD_EFFORT" codex turbo
run_launch "$BAD_EFFORT" --as acme-core --prompt x
eq "unsupported Codex effort is refused" "$RUN_RC" 64
has "effort error names registry migration" "$RUN_OUT" "registry effort 'turbo'"
not_called "invalid effort refusal happens before provider start"

# The full launch consumes one registry open. Any later open of this FIFO hangs.
write_v3 "$REG" codex high
SNAPSHOT="$(<"$REG")"
FIFO="$WORK/registry.fifo"
mkfifo "$FIFO"
rm -f "$SENTINEL" "$POISON_SENTINEL" "$HBLOG"
(
  printf '%s\n' "$SNAPSHOT" > "$FIFO"
) &
writer=$!
RUN_OUT=""; RUN_RC=0
RUN_OUT="$(
  "$TIMEOUT_BIN" 4 env PATH="$STUB_BIN:$SYSTEM_PATH" AIBOBNET_REGISTRY="$FIFO" \
    CODEX_RUN_BIN="$WORK/codex-poison" POISON_SENTINEL="$POISON_SENTINEL" \
    STUB_SENTINEL="$SENTINEL" STUB_ARGV_OUT="$ARGV_OUT" STUB_ENV_OUT="$ENV_OUT" \
    STUB_PWD_OUT="$PWD_OUT" STUB_MODE=ok STUB_REGISTRY="$FIFO" \
      "$LA" --as acme-core --label one-read --prompt x 2>&1
)" || RUN_RC=$?
if kill -0 "$writer" 2>/dev/null; then kill "$writer" 2>/dev/null || true; fi
wait "$writer" 2>/dev/null || true
eq "whole managed launch reads a one-write FIFO once" "$RUN_RC" 0
has "one-read launch reaches terminal heartbeat" "$(sed -n '1,20p' "$HBLOG" 2>/dev/null)" "| done | codex-run OK — one-read"

# Removing the registry inside the provider cannot suppress or redirect completion.
write_v3 "$REG" codex high
: > "$HBLOG"
CASE_MODE=mutate
run_launch "$REG" --as acme-core --label mutate-after-busy --prompt x
CASE_MODE=ok
eq "registry removal after busy does not break launch" "$RUN_RC" 0
has "registry removal still records terminal heartbeat at original path" "$(<"$HBLOG")" "| done | codex-run OK — mutate-after-busy"

# Heartbeat free text remains one encoded physical record per state transition.
write_v3 "$REG" codex high
: > "$HBLOG"
run_launch "$REG" --as acme-core --label $'safe|field\nsecond\rthird' --prompt x
eq "hostile label launch succeeds" "$RUN_RC" 0
eq "hostile label cannot forge physical heartbeat records" "$(wc -l < "$HBLOG")" 2
has "hostile label pipe is encoded" "$(<"$HBLOG")" "safe%7Cfield second third"

# The standalone logger remains registry-authenticated while sharing encoding.
: > "$HBLOG"
AIBOBNET_REGISTRY="$REG" "$LOG" acme-core busy $'standalone|field\nsecond' >/dev/null 2>&1
eq "standalone logger still succeeds" "$?" 0
eq "standalone logger writes one physical record" "$(wc -l < "$HBLOG")" 1
has "standalone logger uses shared encoding" "$(<"$HBLOG")" "standalone%7Cfield second"

# Regression (hotfix #1): a prompt that begins with '-' must reach codex as the
# prompt operand after an explicit end-of-options '--', never be parsed as a codex
# option. Without the '--', a leading-dash prompt (e.g. a sandbox-bypass flag)
# would be consumed as an option instead of prompt text.
write_v3 "$REG" codex high
: > "$HBLOG"
INJ='--dangerously-bypass-approvals-and-sandbox'
run_launch "$REG" --as acme-core --label argv-guard --prompt "$INJ"
eq "leading-dash prompt launch succeeds" "$RUN_RC" 0
argv="$(sed -n '1,100p' "$ARGV_OUT" 2>/dev/null)"
has "leading-dash prompt passes after end-of-options --" "$argv" "[--]
[$INJ]"
has "argv-guard keeps read-only sandbox flag" "$argv" "[-s]
[read-only]"
has "argv-guard keeps approval_policy never" "$argv" '[approval_policy="never"]'

total=$((pass+fail))
printf '\n%d checks: %d ok / %d fail\n' "$total" "$pass" "$fail"
[ "$fail" -eq 0 ]
