#!/usr/bin/env bash
# ai-bobnet — codex-run compatibility acceptance for the RM-0 managed launcher.
# No real inference/network: the provider seam is an executable named `codex` on PATH.
set -uo pipefail

SRC_ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
CR="$SRC_ROOT/bin/codex-run"
SYSTEM_PATH="$PATH"
TIMEOUT_BIN="$(command -v timeout)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-cr.XXXXXX")"
STATE="$WORK/state"
STUB_BIN="$WORK/stub-bin"
mkdir -p "$STATE/acme/standup" "$STUB_BIN"
REG="$WORK/registry.json"
HBLOG="$STATE/acme/standup/acme-core.log"
SENTINEL="$WORK/provider-called"
POISON_SENTINEL="$WORK/poison-called"
ARGV_OUT="$WORK/argv"
PWD_OUT="$WORK/pwd"
STUB_CONF="$STUB_BIN/stub.conf"

# The absolute adapter the schema-4 map points at; the PEP exec's THIS path.
ADAPTER="$STUB_BIN/codex"

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# Schema 4: managed launch requires the provider adapter map + declared capabilities.
write_registry() {
  printf '%s\n' "{
  \"schema_version\": 4,
  \"providers\": {
    \"codex\": {
      \"adapter\": \"$ADAPTER\",
      \"cap_sandbox\": \"workspace-write\",
      \"cap_tier\": \"t3\",
      \"cap_effort\": \"high\"
    }
  },
  \"projects\": {
    \"acme\": {
      \"home\": \"$STATE/acme\",
      \"standup_dir\": \"$STATE/acme/standup\",
      \"mux_session\": \"acme\",
      \"provider\": \"codex\",
      \"model\": \"registry-model\",
      \"effort\": \"medium\"
    }
  },
  \"teams\": {},
  \"agents\": {
    \"acme-core\": { \"project\": \"acme\", \"profile\": \"engine-dev\", \"clearance\": \"t2\" }
  }
}" > "$REG"
}
write_registry

# Instrumentation the stub reads from its own directory (survives the PEP's `env -i`).
write_stub_conf() {
  local mode="${1:-ok}" sleep_s="${2:-5}" rc="${3:-7}"
  cat > "$STUB_CONF" <<EOF
STUB_SENTINEL='$SENTINEL'
STUB_ARGV_OUT='$ARGV_OUT'
STUB_PWD_OUT='$PWD_OUT'
STUB_MODE='$mode'
STUB_SLEEP='$sleep_s'
STUB_RC='$rc'
EOF
}

printf '%s\n' '#!/usr/bin/env bash' \
  '_cfg="$(cd "$(dirname "$0")" && pwd)/stub.conf"' \
  '[ -f "$_cfg" ] && . "$_cfg"' \
  'printf "called\n" >> "$STUB_SENTINEL"' \
  ': > "$STUB_ARGV_OUT"' \
  'for arg in "$@"; do printf "[%s]\n" "$arg" >> "$STUB_ARGV_OUT"; done' \
  'pwd > "$STUB_PWD_OUT"' \
  'case "${STUB_MODE:-ok}" in' \
  '  ok) printf "STUB_BUILT_OK\n"; exit 0;;' \
  '  sleep) sleep "${STUB_SLEEP:-5}"; exit 0;;' \
  '  err) printf "stub failure\n" >&2; exit "${STUB_RC:-7}";;' \
  'esac' > "$STUB_BIN/codex"
chmod +x "$STUB_BIN/codex"
write_stub_conf ok

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
not_called(){
  if [ ! -e "$SENTINEL" ] && [ ! -e "$POISON_SENTINEL" ]; then
    ok "$1"
  else
    no "$1 (provider executable or poisoned override ran)"
  fi
}

CR_OUT=""; CR_RC=0; CASE_MODE=ok; CASE_SLEEP=5; CASE_RC=7
cr() {
  rm -f "$SENTINEL" "$POISON_SENTINEL" "$ARGV_OUT" "$PWD_OUT"
  write_stub_conf "$CASE_MODE" "$CASE_SLEEP" "$CASE_RC"
  CR_OUT=""; CR_RC=0
  # CODEX_RUN_BIN/POISON are injected to prove the PEP's `env -i` strips them; the stub
  # takes its behaviour from the conf beside it, not the (now emptied) inherited env.
  CR_OUT="$(
    PATH="$STUB_BIN:$SYSTEM_PATH" AIBOBNET_REGISTRY="$REG" \
    CODEX_RUN_BIN="$WORK/codex-poison" POISON_SENTINEL="$POISON_SENTINEL" \
      "$CR" "$@" 2>&1
  )" || CR_RC=$?
}

# Boundary validation: every rejection precedes provider execution.
cr --prompt x
eq "missing --as exits 64" "$CR_RC" 64
not_called "missing --as never starts provider"
cr --as acme-core --sandbox danger-full-access --prompt x
eq "danger-full-access is refused" "$CR_RC" 64
not_called "dangerous sandbox never starts provider"
cr --as acme-core --sandbox bogus --prompt x
eq "unknown sandbox is refused" "$CR_RC" 64
not_called "unknown sandbox never starts provider"
cr --as acme-core --timeout 1.5 --prompt x
eq "non-integer timeout is refused" "$CR_RC" 64
not_called "invalid timeout never starts provider"
cr --as acme-core --timeout 0 --prompt x
eq "zero timeout is refused" "$CR_RC" 64
cr --as acme-core --cwd "$WORK/missing" --prompt x
eq "missing cwd exits 2" "$CR_RC" 2
not_called "missing cwd never starts provider"
cr --as acme-core
eq "missing prompt is refused" "$CR_RC" 64
not_called "missing prompt never starts provider"
cr --as Bad_UID --prompt x
[ "$CR_RC" -ne 0 ] && ok "malformed agent uid is refused" || no "malformed agent uid is refused"
not_called "malformed agent uid never starts provider"
cr --as acme-core --unknown x --prompt x
eq "unknown option is refused" "$CR_RC" 64
not_called "unknown option never starts provider"

cr --as
eq "missing --as value is refused" "$CR_RC" 64
cr --as acme-core --sandbox
eq "missing --sandbox value is refused" "$CR_RC" 64
cr --as acme-core --cwd
eq "missing --cwd value is refused" "$CR_RC" 64
cr --as acme-core --timeout
eq "missing --timeout value is refused" "$CR_RC" 64
cr --as acme-core --label
eq "missing --label value is refused" "$CR_RC" 64
cr --as acme-core --prompt
eq "missing --prompt value is refused" "$CR_RC" 64
cr --as acme-core --prompt-file
eq "missing --prompt-file value is refused" "$CR_RC" 64
not_called "missing option value never starts provider"

# Registry truth replaces both former launcher authorities, with explicit migration errors.
cr --as acme-core --model old-model --prompt x
eq "--model override is refused" "$CR_RC" 64
has "--model error explains registry migration" "$CR_OUT" "--model is registry-managed"
not_called "--model refusal never starts provider"
cr --as acme-core --model
eq "missing --model value still gets migration exit" "$CR_RC" 64
has "missing --model value still gets migration message" "$CR_OUT" "--model is registry-managed"
cr --as acme-core --effort max --prompt x
eq "--effort override is refused" "$CR_RC" 64
has "--effort error explains registry migration" "$CR_OUT" "--effort is registry-managed"
not_called "--effort refusal never starts provider"
cr --as acme-core --effort
eq "missing --effort value still gets migration exit" "$CR_RC" 64
has "missing --effort value still gets migration message" "$CR_OUT" "--effort is registry-managed"

# Repeated options and every prompt-source collision fail closed.
cr --as acme-core --as acme-core --prompt x
eq "repeated --as is refused" "$CR_RC" 64
cr --as acme-core --sandbox read-only --sandbox workspace-write --prompt x
eq "repeated --sandbox is refused" "$CR_RC" 64
cr --as acme-core --cwd "$WORK" --cwd "$WORK" --prompt x
eq "repeated --cwd is refused" "$CR_RC" 64
cr --as acme-core --timeout 2 --timeout 3 --prompt x
eq "repeated --timeout is refused" "$CR_RC" 64
cr --as acme-core --label one --label two --prompt x
eq "repeated --label is refused" "$CR_RC" 64
printf 'from file' > "$WORK/prompt"
cr --as acme-core --prompt one --prompt two
eq "repeated --prompt is refused" "$CR_RC" 64
cr --as acme-core --prompt-file "$WORK/prompt" --prompt-file "$WORK/prompt"
eq "repeated --prompt-file is refused" "$CR_RC" 64
cr --as acme-core --prompt one --prompt-file "$WORK/prompt"
eq "prompt and file collision is refused" "$CR_RC" 64
not_called "repeated options never start provider"
CR_OUT=""; CR_RC=0; rm -f "$SENTINEL"
CR_OUT="$(printf 'stdin' | PATH="$STUB_BIN:$SYSTEM_PATH" AIBOBNET_REGISTRY="$REG" \
  CODEX_RUN_BIN="$WORK/codex-poison" POISON_SENTINEL="$POISON_SENTINEL" STUB_SENTINEL="$SENTINEL" \
  "$CR" --as acme-core --prompt x - 2>&1)" || CR_RC=$?
eq "prompt and stdin collision is refused" "$CR_RC" 64
not_called "prompt collision never starts provider"
CR_OUT=""; CR_RC=0; rm -f "$SENTINEL" "$POISON_SENTINEL"
CR_OUT="$(printf 'stdin' | PATH="$STUB_BIN:$SYSTEM_PATH" AIBOBNET_REGISTRY="$REG" \
  CODEX_RUN_BIN="$WORK/codex-poison" POISON_SENTINEL="$POISON_SENTINEL" STUB_SENTINEL="$SENTINEL" \
  "$CR" --as acme-core --prompt-file "$WORK/prompt" - 2>&1)" || CR_RC=$?
eq "file and stdin collision is refused" "$CR_RC" 64
not_called "file/stdin collision never starts provider"
CR_OUT=""; CR_RC=0; rm -f "$SENTINEL" "$POISON_SENTINEL"
CR_OUT="$(printf 'stdin' | PATH="$STUB_BIN:$SYSTEM_PATH" AIBOBNET_REGISTRY="$REG" \
  CODEX_RUN_BIN="$WORK/codex-poison" POISON_SENTINEL="$POISON_SENTINEL" STUB_SENTINEL="$SENTINEL" \
  "$CR" --as acme-core - - 2>&1)" || CR_RC=$?
eq "repeated stdin source is refused" "$CR_RC" 64
not_called "repeated stdin never starts provider"

# Compatibility success keeps runtime options while model/effort come only from registry.
: > "$HBLOG"
cr --as acme-core --label build-x --prompt "make it so"
eq "compatibility launch succeeds" "$CR_RC" 0
has "provider output is relayed" "$CR_OUT" "STUB_BUILT_OK"
[ ! -e "$POISON_SENTINEL" ] && ok "CODEX_RUN_BIN poison is ignored" || no "CODEX_RUN_BIN poison is ignored"
argv="$(sed -n '1,80p' "$ARGV_OUT" 2>/dev/null)"
has "argv uses registry model" "$argv" "[-m]
[registry-model]"
has "argv keeps default read-only sandbox" "$argv" "[-s]
[read-only]"
has "argv uses registry effort" "$argv" '[model_reasoning_effort="medium"]'
has "argv carries prompt" "$argv" "[make it so]"
has "busy heartbeat uses registry binding" "$(sed -n '1,20p' "$HBLOG")" "| busy | codex-run: registry-model/read-only effort=medium — build-x"
has "success heartbeat is preserved" "$(sed -n '1,20p' "$HBLOG")" "| done | codex-run OK — build-x"

cr --as acme-core --sandbox workspace-write --prompt p
eq "workspace-write remains an explicit runtime option" "$CR_RC" 0
has "workspace-write reaches provider" "$(sed -n '1,80p' "$ARGV_OUT")" "[-s]
[workspace-write]"

mkdir -p "$WORK/sub"
cr --as acme-core --cwd "$WORK/sub" --prompt p
eq "cwd launch succeeds" "$CR_RC" 0
eq "provider runs in requested cwd" "$(sed -n '1p' "$PWD_OUT")" "$WORK/sub"

CR_OUT=""; CR_RC=0; rm -f "$SENTINEL"
CR_OUT="$(printf 'from stdin' | PATH="$STUB_BIN:$SYSTEM_PATH" AIBOBNET_REGISTRY="$REG" \
  CODEX_RUN_BIN="$WORK/codex-poison" POISON_SENTINEL="$POISON_SENTINEL" \
  STUB_SENTINEL="$SENTINEL" STUB_ARGV_OUT="$ARGV_OUT" STUB_PWD_OUT="$PWD_OUT" \
  "$CR" --as acme-core - 2>&1)" || CR_RC=$?
eq "stdin prompt succeeds" "$CR_RC" 0
has "stdin prompt reaches provider" "$(sed -n '1,80p' "$ARGV_OUT")" "[from stdin]"
cr --as acme-core --prompt-file "$WORK/prompt"
eq "prompt-file succeeds" "$CR_RC" 0
has "file prompt reaches provider" "$(sed -n '1,80p' "$ARGV_OUT")" "[from file]"

# Watchdog and terminal heartbeat semantics remain compatible.
: > "$HBLOG"; CASE_MODE=sleep; CASE_SLEEP=5
cr --as acme-core --timeout 1 --label slowbuild --prompt p
CASE_MODE=ok
eq "watchdog timeout exits 124" "$CR_RC" 124
has "timeout heartbeat is preserved" "$(sed -n '1,20p' "$HBLOG")" "| blocked | codex-run TIMEOUT after 1s — slowbuild"

: > "$HBLOG"; CASE_MODE=err; CASE_RC=7
cr --as acme-core --label failbuild --prompt p
CASE_MODE=ok
eq "provider error code is propagated" "$CR_RC" 7
has "provider stderr is surfaced" "$CR_OUT" "stub failure"
has "failure heartbeat is preserved" "$(sed -n '1,20p' "$HBLOG")" "| blocked | codex-run FAILED rc=7 — failbuild"

# The compatibility entry performs no second resolution: a one-write FIFO suffices.
write_registry
write_stub_conf ok
SNAPSHOT="$(<"$REG")"
FIFO="$WORK/registry.fifo"
mkfifo "$FIFO"
rm -f "$SENTINEL" "$HBLOG"
(
  printf '%s\n' "$SNAPSHOT" > "$FIFO"
) &
writer=$!
CR_OUT=""; CR_RC=0
CR_OUT="$(
  "$TIMEOUT_BIN" 4 env PATH="$STUB_BIN:$SYSTEM_PATH" AIBOBNET_REGISTRY="$FIFO" \
    CODEX_RUN_BIN="$WORK/codex-poison" POISON_SENTINEL="$POISON_SENTINEL" \
    STUB_SENTINEL="$SENTINEL" STUB_ARGV_OUT="$ARGV_OUT" STUB_PWD_OUT="$PWD_OUT" \
      "$CR" --as acme-core --label compat-one-read --prompt x 2>&1
)" || CR_RC=$?
if kill -0 "$writer" 2>/dev/null; then kill "$writer" 2>/dev/null || true; fi
wait "$writer" 2>/dev/null || true
eq "codex-run delegates through one registry read" "$CR_RC" 0
has "delegated one-read launch completes" "$(sed -n '1,20p' "$HBLOG" 2>/dev/null)" "| done | codex-run OK — compat-one-read"

total=$((pass+fail))
printf '\n%d checks: %d ok / %d fail\n' "$total" "$pass" "$fail"
[ "$fail" -eq 0 ]
