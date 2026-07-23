#!/usr/bin/env bash
# ai-bobnet — RM-1 managed-launch acceptance (policy gate, NOT containment).
# The launcher (PEP) consumes the PDP verdict, builds the child env from an allow-list
# via `env -i`, and exec's the ABSOLUTE registry adapter — never a `codex` found through
# PATH from the launch cwd. The provider seam is a stub executable pointed at by the
# schema-4 adapter map, so no real inference/network is involved.
#
# Because the PEP now strips every non-allow-listed variable via `env -i`, the stub can
# no longer read its instrumentation from inherited env. It instead sources a conf file
# beside itself (keyed off its own install path) — exactly the property env -i enforces:
# an adapter's behaviour comes from where it is installed, not from ambient environment.
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
ARGV_OUT="$WORK/argv"
ENV_OUT="$WORK/env"
FULLENV_OUT="$WORK/fullenv"
PWD_OUT="$WORK/pwd"
STUB_CONF="$STUB_BIN/stub.conf"

# The absolute adapter the schema-4 map points at. Authority is registry data; the PEP
# exec's THIS path, so PATH/cwd cannot substitute a different `codex`.
ADAPTER="$STUB_BIN/codex"

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# Schema 4 carries the provider adapter map + declared capabilities. Managed launch
# REQUIRES the adapter field; the provider key mirrors the project's provider.
write_v4() {
  local path="$1" provider="$2" effort="$3" standup_dir="${4:-$STATE/acme/standup}" adapter="${5:-$ADAPTER}"
  printf '%s\n' "{
  \"schema_version\": 4,
  \"providers\": {
    \"$provider\": {
      \"adapter\": \"$adapter\",
      \"cap_sandbox\": \"workspace-write\",
      \"cap_tier\": \"t3\",
      \"cap_effort\": \"high\"
    }
  },
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

# Schema 3: execution binding but NO adapter map. Managed launch resolves an empty
# adapter, so the PDP fails it closed with the same missing-adapter verdict (exit 127).
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

# Instrumentation the stub reads from its own directory (survives `env -i`). Only mode
# and the registry-under-test vary between cases; the capture paths are fixed.
write_stub_conf() {
  local mode="${1:-ok}" registry="${2:-$REG}" sleep_s="${3:-5}" rc="${4:-7}"
  cat > "$STUB_CONF" <<EOF
STUB_SENTINEL='$SENTINEL'
STUB_ARGV_OUT='$ARGV_OUT'
STUB_ENV_OUT='$ENV_OUT'
STUB_FULLENV_OUT='$FULLENV_OUT'
STUB_PWD_OUT='$PWD_OUT'
STUB_MODE='$mode'
STUB_SLEEP='$sleep_s'
STUB_RC='$rc'
STUB_REGISTRY='$registry'
EOF
}

# The managed test seam: the adapter records argv/env/pwd and dumps its FULL environment
# so the `env -i` allow-list can be proven (nothing inherited leaks). Config comes from
# the conf beside it, not the ambient environment the PEP has stripped.
printf '%s\n' '#!/usr/bin/env bash' \
  '_cfg="$(cd "$(dirname "$0")" && pwd)/stub.conf"' \
  '[ -f "$_cfg" ] && . "$_cfg"' \
  'printf "called\n" >> "$STUB_SENTINEL"' \
  ': > "$STUB_ARGV_OUT"' \
  'for arg in "$@"; do printf "[%s]\n" "$arg" >> "$STUB_ARGV_OUT"; done' \
  'pwd > "$STUB_PWD_OUT"' \
  'env > "${STUB_FULLENV_OUT:-/dev/null}"' \
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
  rm -f "$SENTINEL" "$ARGV_OUT" "$ENV_OUT" "$FULLENV_OUT" "$PWD_OUT"
  write_stub_conf "$CASE_MODE" "$registry" "$CASE_SLEEP" "$CASE_RC"
  RUN_OUT=""; RUN_ERR=""; RUN_RC=0
  # Ambient AIBOBNET_*, LEAKME_SENTINEL and CODEX_RUN_BIN are deliberately injected to
  # prove `env -i` strips them: the resolved binding wins and nothing inherited crosses.
  RUN_OUT="$(
    PATH="$STUB_BIN:$SYSTEM_PATH" \
    AIBOBNET_REGISTRY="$registry" \
    AIBOBNET_PROVIDER=ambient-provider AIBOBNET_PROVIDER_SOURCE=agent:ambient \
    AIBOBNET_MODEL=ambient-model AIBOBNET_MODEL_SOURCE=agent:ambient \
    AIBOBNET_EFFORT=ambient-effort AIBOBNET_EFFORT_SOURCE=agent:ambient \
    AIBOBNET_TEAM_UID=ambient-team AIBOBNET_CLEARANCE=t4 STANDUP_DIR="$WORK/ambient-standup" \
    LEAKME_SENTINEL=must-not-cross-env-i CODEX_RUN_BIN="$WORK/codex-poison" \
      "$LA" "$@" 2>"$WORK/launch-stderr"
  )" || RUN_RC=$?
  RUN_ERR="$(<"$WORK/launch-stderr")"
  [ -z "$RUN_ERR" ] || RUN_OUT="${RUN_OUT}${RUN_OUT:+$'\n'}${RUN_ERR}"
}

# --- 1. schema-4 happy path: verdict consumed, adapter exec'd, env allow-listed -----
write_v4 "$REG" codex high
HBLOG="$STATE/acme/standup/acme-core.log"
: > "$HBLOG"
run_launch "$REG" --as acme-core --label managed --prompt "make it so"
eq "managed success returns zero" "$RUN_RC" 0
has "managed success relays provider output" "$RUN_OUT" "STUB_BUILT_OK"
eq "managed launch executes provider once" "$(wc -l < "$SENTINEL" 2>/dev/null || printf 0)" 1
argv="$(sed -n '1,100p' "$ARGV_OUT" 2>/dev/null)"
has "argv selects codex exec" "$argv" "[exec]"
has "argv uses resolved team model" "$argv" "[-m]
[team/model-v2]"
has "argv uses effective read-only sandbox" "$argv" "[-s]
[read-only]"
has "argv uses effective effort" "$argv" '[model_reasoning_effort="high"]'
has "argv forces approval never" "$argv" '[approval_policy="never"]'
has "argv carries the prompt as one argument" "$argv" "[make it so]"
env_out="$(sed -n '1,100p' "$ENV_OUT" 2>/dev/null)"
has "child gets resolved identity and clearance" "$env_out" $'agent_uid=acme-core\nproject_uid=acme\nagent_key=core\nprofile=engine-dev\nclearance=t2'
has "child gets resolved direct team" "$env_out" "team_uid=acme-engine"
has "child gets resolved paths" "$env_out" "standup_dir=$STATE/acme/standup"
has "child gets resolved inbox" "$env_out" "inbox_path=$STATE/acme/standup/inbox/acme-core.md"
has "child gets resolved binding and provenance" "$env_out" $'provider=codex\nprovider_source=project:acme\nmodel=team/model-v2\nmodel_source=team:acme-engine\neffort=high\neffort_source=agent:acme-core\nschema=4'
has "child sees CODEX_RUN_BIN removed" "$env_out" "codex_run_bin=unset"

# §8.1: the emitted adapter path is the ABSOLUTE registry adapter (from the verdict),
# no longer a `command -v codex` resolved at launch cwd.
binding_emit="{\"event\":\"managed_launch_binding\",\"agent_uid\":\"acme-core\",\"provider\":\"codex\",\"provider_source\":\"project:acme\",\"model\":\"team/model-v2\",\"model_source\":\"team:acme-engine\",\"effort\":\"high\",\"effort_source\":\"agent:acme-core\",\"adapter_path\":\"$ADAPTER\"}"
has "launch emits structured resolved binding and absolute adapter path on stderr" "$RUN_ERR" "$binding_emit"
has "busy heartbeat uses resolved model and effective effort" "$(<"$HBLOG")" "| busy | codex-run: team/model-v2/read-only effort=high — managed"
has "terminal heartbeat records success" "$(<"$HBLOG")" "| done | codex-run OK — managed"

# §8.2: the child environment is CONSTRUCTED from the allow-list via `env -i`. The
# allow-list (HOME PATH) passes through; the explicit managed exports are re-added;
# every other inherited variable is gone. Nothing scrubbed-by-denylist can survive.
fullenv="$(<"$FULLENV_OUT")"
has "child env passes through allow-listed HOME"        "$fullenv" "HOME=$HOME"
has "child env passes through allow-listed PATH"         "$fullenv" "PATH=$STUB_BIN:"
has "child env keeps the explicit managed export"        "$fullenv" "AIBOBNET_AGENT_UID=acme-core"
hasnt "child env drops non-allow-listed inherited vars"  "$fullenv" "LEAKME_SENTINEL"
hasnt "child env never inherits ambient provenance"      "$fullenv" "ambient-provider"
hasnt "child env never inherits the poison binary path"  "$fullenv" "CODEX_RUN_BIN"

# --- 2. exit-127: a missing adapter fails closed BEFORE any heartbeat or provider ---
# Schema 3 carries execution binding but no adapter map -> empty adapter -> the PDP's
# missing-adapter deny, which the PEP maps to exit 127 before it starts anything.
write_v3 "$REG" codex high
: > "$HBLOG"
run_launch "$REG" --as acme-core --label no-adapter --prompt x
eq "missing-adapter managed launch fails closed 127" "$RUN_RC" 127
not_called "missing-adapter refusal happens before provider start"
eq "missing-adapter refusal writes no heartbeat" "$(wc -l < "$HBLOG" 2>/dev/null || printf 0)" 0
has "missing-adapter error names the adapter" "$RUN_OUT" "adapter"

# A schema-4 adapter that points at a non-existent absolute path also fails closed at
# 127 (IO hygiene, before heartbeat) — the resolved adapter must actually be runnable.
GHOST="$WORK/ghost.json"; write_v4 "$GHOST" codex high "$STATE/acme/standup" "/nonexistent/acme/adapters/codex"
: > "$HBLOG"
run_launch "$GHOST" --as acme-core --label ghost-adapter --prompt x
eq "non-existent adapter fails closed 127" "$RUN_RC" 127
not_called "non-existent adapter refusal happens before provider start"
eq "non-existent adapter refusal writes no heartbeat" "$(wc -l < "$HBLOG" 2>/dev/null || printf 0)" 0

# A schema-4 adapter that is not absolute is a config error (exit 2), not 127.
RELADAPT="$WORK/reladapter.json"; write_v4 "$RELADAPT" codex high "$STATE/acme/standup" "relative/codex"
: > "$HBLOG"
run_launch "$RELADAPT" --as acme-core --label rel-adapter --prompt x
eq "non-absolute adapter is a config refusal (2)" "$RUN_RC" 2
not_called "non-absolute adapter refusal happens before provider start"
has "non-absolute adapter error explains absoluteness" "$RUN_OUT" "not absolute"

# --- 3. remaining registry-truth refusals, all before any provider process ----------
V2="$WORK/v2.json"; write_v2 "$V2"
run_launch "$V2" --as acme-core --prompt x
eq "schema 2 managed launch is refused" "$RUN_RC" 3
not_called "schema 2 refusal happens before provider start"

# The PEP drives only the codex adapter CLI: a provider present in the map but not
# codex is a support refusal (64), before the PDP call and any heartbeat.
UNKNOWN="$WORK/unknown-provider.json"; write_v4 "$UNKNOWN" claude-code high
: > "$HBLOG"
run_launch "$UNKNOWN" --as acme-core --prompt x
eq "unsupported provider is refused" "$RUN_RC" 64
has "unsupported provider error names the registry provider" "$RUN_OUT" "unsupported registry provider 'claude-code'"
not_called "unsupported provider refusal happens before provider start"
eq "unsupported provider refusal writes no heartbeat" "$(wc -l < "$HBLOG" 2>/dev/null || printf 0)" 0

# An unrecognised registry effort is denied by the PDP (64), before any provider.
BAD_EFFORT="$WORK/bad-effort.json"; write_v4 "$BAD_EFFORT" codex turbo
run_launch "$BAD_EFFORT" --as acme-core --prompt x
eq "unsupported effort is refused" "$RUN_RC" 64
has "effort refusal names the unrecognised level" "$RUN_OUT" "resolved effort 'turbo'"
not_called "invalid effort refusal happens before provider start"

# --- 4. absolute adapter exec: PATH/cwd cannot swap the provider --------------------
# A hostile `codex` earlier on PATH and one sitting in the launch cwd are BOTH present;
# the PEP still exec's the absolute registry adapter, so neither runs. The poisons bake
# their sentinel path literally, so they record even under `env -i` if wrongly invoked.
write_v4 "$REG" codex high
write_stub_conf ok "$REG"
PSWAP="$WORK/pathswap"; mkdir -p "$PSWAP"
PATHSWAP_SENTINEL="$WORK/pathswap-called"
printf '%s\n' '#!/usr/bin/env bash' "printf 'swap\n' >> '$PATHSWAP_SENTINEL'" 'exit 88' > "$PSWAP/codex"
chmod +x "$PSWAP/codex"
CWDPOISON="$WORK/cwd-poison"; mkdir -p "$CWDPOISON"
cp "$PSWAP/codex" "$CWDPOISON/codex"
: > "$HBLOG"; rm -f "$SENTINEL" "$PATHSWAP_SENTINEL" "$PWD_OUT"
RUN_RC=0
RUN_ERR="$(
  PATH="$PSWAP:.:$STUB_BIN:$SYSTEM_PATH" AIBOBNET_REGISTRY="$REG" \
    "$LA" --as acme-core --cwd "$CWDPOISON" --label abs-adapter --prompt x 2>&1 >/dev/null
)" || RUN_RC=$?
eq "absolute-adapter launch succeeds despite PATH/cwd poison" "$RUN_RC" 0
eq "the registry adapter ran exactly once" "$(wc -l < "$SENTINEL" 2>/dev/null || printf 0)" 1
[ ! -e "$PATHSWAP_SENTINEL" ] && ok "a codex earlier on PATH or in cwd is never executed" || no "a codex earlier on PATH or in cwd is never executed"
has "the emitted adapter_path stays the absolute registry path" "$RUN_ERR" "\"adapter_path\":\"$ADAPTER\""
eq "the adapter still runs inside the requested cwd" "$(sed -n '1p' "$PWD_OUT" 2>/dev/null)" "$CWDPOISON"

# --- 5. RM-0 regressions preserved (adapted to schema 4) ----------------------------
# The full launch consumes one registry open. Any later open of this FIFO hangs.
write_v4 "$REG" codex high
SNAPSHOT="$(<"$REG")"
FIFO="$WORK/registry.fifo"
mkfifo "$FIFO"
write_stub_conf ok "$FIFO"
rm -f "$SENTINEL" "$HBLOG"
(
  printf '%s\n' "$SNAPSHOT" > "$FIFO"
) &
writer=$!
RUN_OUT=""; RUN_RC=0
RUN_OUT="$(
  "$TIMEOUT_BIN" 4 env PATH="$STUB_BIN:$SYSTEM_PATH" AIBOBNET_REGISTRY="$FIFO" \
      "$LA" --as acme-core --label one-read --prompt x 2>&1
)" || RUN_RC=$?
if kill -0 "$writer" 2>/dev/null; then kill "$writer" 2>/dev/null || true; fi
wait "$writer" 2>/dev/null || true
eq "whole managed launch reads a one-write FIFO once" "$RUN_RC" 0
has "one-read launch reaches terminal heartbeat" "$(sed -n '1,20p' "$HBLOG" 2>/dev/null)" "| done | codex-run OK — one-read"

# Removing the registry inside the provider cannot suppress or redirect completion.
write_v4 "$REG" codex high
: > "$HBLOG"
CASE_MODE=mutate
run_launch "$REG" --as acme-core --label mutate-after-busy --prompt x
CASE_MODE=ok
eq "registry removal after busy does not break launch" "$RUN_RC" 0
has "registry removal still records terminal heartbeat at original path" "$(<"$HBLOG")" "| done | codex-run OK — mutate-after-busy"

# Heartbeat free text remains one encoded physical record per state transition.
write_v4 "$REG" codex high
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
write_v4 "$REG" codex high
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
