#!/usr/bin/env bash
# ai-bobnet — RM-2 Lane B: durable attempt audit in the managed-launch PEP.
#
# These are black-box process tests. The adapter is a real child process, signals are
# delivered to a real launch-agent PID, and assertions inspect the durable framed
# stream rather than shell implementation details (except the explicit trap-disarm
# mutation pin required by B3).
set -uo pipefail

SRC_ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
LA="$SRC_ROOT/bin/launch-agent"
SYSTEM_PATH="$PATH"

command -v jq >/dev/null 2>&1 || { printf 'FAIL - required test dependency missing: jq\n'; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-attempt-audit.XXXXXX")"
STATE="$WORK/state"
STANDUP="$STATE/acme/standup"
STUB_BIN="$WORK/stub-bin"
ADAPTER="$STUB_BIN/codex"
REG="$WORK/registry.json"
CONF="$STUB_BIN/stub.conf"
EVENTS="$STANDUP/events/main.events"
CALLED="$WORK/provider-called"
CHILD_OBS="$WORK/child-observation"
CHILD_PID="$WORK/child-pid"
CHILD_READY="$WORK/child-ready"
CHILD_RESULT="$WORK/child-result"
RUN_STDOUT="$WORK/launch-stdout"
RUN_STDERR="$WORK/launch-stderr"
mkdir -p "$STANDUP" "$STUB_BIN"

cleanup() {
  if [ -s "$CHILD_PID" ]; then
    child_pid="$(cat "$CHILD_PID" 2>/dev/null || true)"
    [ -z "$child_pid" ] || kill -KILL "$child_pid" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

write_registry() {
  local provider="$1" adapter="$2"
  cat > "$REG" <<EOF
{
  "schema_version": 4,
  "providers": {
    "$provider": {
      "adapter": "$adapter",
      "cap_sandbox": "workspace-write",
      "cap_tier": "t3",
      "cap_effort": "high"
    }
  },
  "projects": {
    "acme": {
      "home": "$STATE/acme",
      "standup_dir": "$STANDUP",
      "mux_session": "acme",
      "provider": "$provider",
      "model": "project-model",
      "effort": "low"
    }
  },
  "teams": {
    "acme-engine": { "project": "acme", "model": "team/model-v2" }
  },
  "agents": {
    "acme-core": {
      "project": "acme",
      "team_uid": "acme-engine",
      "profile": "engine-dev",
      "clearance": "t2",
      "effort": "high"
    }
  }
}
EOF
}

write_registry_without_adapter_map() {
  cat > "$REG" <<EOF
{
  "schema_version": 3,
  "projects": {
    "acme": {
      "home": "$STATE/acme",
      "standup_dir": "$STANDUP",
      "mux_session": "acme",
      "provider": "codex",
      "model": "project-model",
      "effort": "low"
    }
  },
  "teams": {
    "acme-engine": { "project": "acme", "model": "team/model-v2" }
  },
  "agents": {
    "acme-core": {
      "project": "acme",
      "team_uid": "acme-engine",
      "profile": "engine-dev",
      "clearance": "t2",
      "effort": "high"
    }
  }
}
EOF
}

write_stub_conf() {
  local mode="$1"
  cat > "$CONF" <<EOF
AIB_TEST_MODE='$mode'
AIB_TEST_EVENTS='$EVENTS'
AIB_TEST_CALLED='$CALLED'
AIB_TEST_OBS='$CHILD_OBS'
AIB_TEST_PID='$CHILD_PID'
AIB_TEST_READY='$CHILD_READY'
AIB_TEST_RESULT='$CHILD_RESULT'
EOF
}

cat > "$ADAPTER" <<'EOF'
#!/usr/bin/env bash
set -u
config="$(cd -P "$(dirname "$0")" >/dev/null 2>&1 && pwd)/stub.conf"
. "$config"
printf '%s\n' "$$" > "$AIB_TEST_PID"
printf 'called\n' >> "$AIB_TEST_CALLED"
if [ -f "$AIB_TEST_EVENTS" ]; then
  event_lines="$(wc -l < "$AIB_TEST_EVENTS")"
else
  event_lines=0
fi
printf 'attempt_id=%s\nevent_lines_at_start=%s\n' \
  "${AIBOBNET_ATTEMPT_ID-}" "$event_lines" > "$AIB_TEST_OBS"

case "$AIB_TEST_MODE" in
  ok)
    printf 'provider-ok\n'
    printf 'ok\n' > "$AIB_TEST_RESULT"
    exit 0
    ;;
  fail)
    printf 'provider-failed\n' >&2
    printf 'failed\n' > "$AIB_TEST_RESULT"
    exit 7
    ;;
  sleep)
    : > "$AIB_TEST_READY"
    sleep 20
    printf 'late-success\n' > "$AIB_TEST_RESULT"
    exit 0
    ;;
  term-success)
    trap 'printf "term-success\n" > "$AIB_TEST_RESULT"; exit 0' TERM
    : > "$AIB_TEST_READY"
    sleep 2
    printf 'natural-success\n' > "$AIB_TEST_RESULT"
    exit 0
    ;;
  *)
    exit 99
    ;;
esac
EOF
chmod +x "$ADAPTER"

pass=0
fail=0
ok() { pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
no() { fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; }
eq() { [ "$2" = "$3" ] && ok "$1" || no "$1 (got '$2' want '$3')"; }
has() { case "$2" in *"$3"*) ok "$1";; *) no "$1 (missing '$3')";; esac; }
hasnt() { case "$2" in *"$3"*) no "$1 (unexpected '$3')";; *) ok "$1";; esac; }

reset_case() {
  rm -rf "$STANDUP/events"
  rm -f "$CALLED" "$CHILD_OBS" "$CHILD_PID" "$CHILD_READY" "$CHILD_RESULT" \
    "$RUN_STDOUT" "$RUN_STDERR" "$STANDUP/acme-core.log"
}

event_count() {
  if [ -f "$EVENTS" ]; then wc -l < "$EVENTS"; else printf '0\n'; fi
}

event_json() {
  local number="$1" line
  line="$(sed -n "${number}p" "$EVENTS" 2>/dev/null)"
  printf '%s' "${line#* * * }"
}

event_value() {
  local number="$1" query="$2"
  event_json "$number" | jq -r "$query"
}

run_sync() {
  local mode="$1"; shift
  write_stub_conf "$mode"
  RUN_RC=0
  PATH="$STUB_BIN:$SYSTEM_PATH" AIBOBNET_REGISTRY="$REG" \
    "$LA" "$@" >"$RUN_STDOUT" 2>"$RUN_STDERR" || RUN_RC=$?
}

start_async() {
  local mode="$1"; shift
  write_stub_conf "$mode"
  PATH="$STUB_BIN:$SYSTEM_PATH" AIBOBNET_REGISTRY="$REG" \
    "$LA" "$@" >"$RUN_STDOUT" 2>"$RUN_STDERR" &
  LAUNCH_PID=$!
}

wait_ready() {
  local count=0
  while [ ! -e "$CHILD_READY" ] && kill -0 "$LAUNCH_PID" 2>/dev/null && [ "$count" -lt 100 ]; do
    sleep 0.05
    count=$((count + 1))
  done
  [ -e "$CHILD_READY" ]
}

wait_launch() {
  RUN_RC=0
  wait "$LAUNCH_PID" || RUN_RC=$?
}

# B1(b): the current pure PDP cannot derive the launcher's codex-only argv support
# from its frozen snapshot without changing Lane A. The support refusal therefore
# occurs after a durable allow decision and closes with ended(io-refused).
reset_case
write_registry claude-code "$ADAPTER"
run_sync ok --as acme-core --label unsupported --prompt x
eq "B1(b): unsupported resolved provider keeps exit 64" "$RUN_RC" 64
eq "B1(b): unsupported resolved provider writes decided plus ended" "$(event_count)" 2
eq "B1(b): first record is the durable allow decision" "$(event_value 1 '.event_type + ":" + .payload.decision')" "attempt.decided:allow"
eq "B1(b): refusal closes as io-refused" "$(event_value 2 '.event_type + ":" + .payload.exit.class')" "attempt.ended:io-refused"
[ ! -e "$CALLED" ] && ok "B1(b): unsupported provider never starts" || no "B1(b): unsupported provider never starts"

# A PDP deny is terminal in the decided record: exactly one durable record, no ended.
reset_case
write_registry_without_adapter_map
run_sync ok --as acme-core --label denied --prompt x
eq "deny returns the PDP's adapter-missing code" "$RUN_RC" 127
eq "deny writes exactly one terminal decided record" "$(event_count)" 1
eq "deny record carries decision and code" "$(event_value 1 '.payload.decision + ":" + (.payload.code|tostring)')" "deny:127"
[ ! -e "$CALLED" ] && ok "deny never starts the provider" || no "deny never starts the provider"

# B4 + write-ahead: the broker-assigned decided id is persisted, exported to the
# provider, and passed back unchanged as the ended attempt/causation id.
reset_case
write_registry codex "$ADAPTER"
prompt='audit prompt must not persist'
run_sync ok --as acme-core --label success --prompt "$prompt"
eq "successful attempt returns zero" "$RUN_RC" 0
eq "successful attempt writes decided plus ended" "$(event_count)" 2
decided_id="$(event_value 1 '.event_id')"
eq "decided id comes from the in-lock stream sequence" "$decided_id" "acme-main-1"
eq "ended attempt_id reuses the persisted decided id" "$(event_value 2 '.attempt_id')" "$decided_id"
eq "ended causation_id reuses the persisted decided id" "$(event_value 2 '.causation_id')" "$decided_id"
child_observation="$(cat "$CHILD_OBS" 2>/dev/null)"
has "child receives explicit AIBOBNET_ATTEMPT_ID" "$child_observation" "attempt_id=$decided_id"
has "decided is durable before provider start" "$child_observation" "event_lines_at_start=1"
events_text="$(cat "$EVENTS")"
hasnt "prompt text never enters the audit stream" "$events_text" "$prompt"
expected_sha="$(printf '%s' "$prompt" | sha256sum)"; expected_sha="${expected_sha%% *}"
eq "decided records the prompt sha256" "$(event_value 1 '.payload.prompt.sha256')" "$expected_sha"
eq "decided records the prompt byte length" "$(event_value 1 '.payload.prompt.len|tostring')" "${#prompt}"
eq "success closes with ended(ok)" "$(event_value 2 '.payload.exit.class')" "ok"

# Observed nonzero and watchdog outcomes become truthful terminal records.
reset_case
write_registry codex "$ADAPTER"
run_sync fail --as acme-core --label failed --prompt x
eq "provider failure preserves provider exit status" "$RUN_RC" 7
eq "provider failure writes two records" "$(event_count)" 2
eq "provider failure records class and code" "$(event_value 2 '.payload.exit.class + ":" + (.payload.exit.code|tostring)')" "provider-failure:7"

reset_case
write_registry codex "$ADAPTER"
run_sync sleep --as acme-core --timeout 1 --label timeout --prompt x
eq "watchdog timeout returns 124" "$RUN_RC" 124
eq "watchdog timeout writes two records" "$(event_count)" 2
eq "watchdog timeout records timeout class" "$(event_value 2 '.payload.exit.class + ":" + (.payload.exit.code|tostring)')" "timeout:124"

# B2/B3: TERM is forwarded to a real running child, which is reaped before audit.
# A genuinely TERM-killed child yields exactly one aborted terminal record.
reset_case
write_registry codex "$ADAPTER"
start_async sleep --as acme-core --timeout 20 --label term-abort --prompt x
if wait_ready; then ok "TERM abort fixture reached a running child"; else no "TERM abort fixture reached a running child"; fi
kill -TERM "$LAUNCH_PID" 2>/dev/null || true
wait_launch
eq "TERM abort preserves the signal-shaped launcher status" "$RUN_RC" 143
eq "TERM abort writes exactly decided plus one ended" "$(event_count)" 2
eq "TERM-killed child records aborted(TERM)" "$(event_value 2 '.payload.exit.class + ":" + .payload.exit.signal')" "aborted:TERM"
abort_child_pid="$(cat "$CHILD_PID" 2>/dev/null)"
if [ -n "$abort_child_pid" ] && ! kill -0 "$abort_child_pid" 2>/dev/null; then
  ok "TERM-killed provider is reaped before launch-agent exits"
else
  no "TERM-killed provider is reaped before launch-agent exits"
fi

# Signal truth: the provider handles TERM and exits 0. The parent may still preserve
# its TERM-shaped status, but must never forge aborted after the confirmed success.
reset_case
write_registry codex "$ADAPTER"
start_async term-success --as acme-core --timeout 20 --label term-success --prompt x
if wait_ready; then ok "TERM success fixture reached a running child"; else no "TERM success fixture reached a running child"; fi
kill -TERM "$LAUNCH_PID" 2>/dev/null || true
wait_launch
eq "signalled parent preserves its TERM-shaped status" "$RUN_RC" 143
eq "TERM-handling successful child still gets one terminal record" "$(event_count)" 2
eq "confirmed child success records ok, never aborted" "$(event_value 2 '.payload.exit.class')" "ok"
eq "adapter proves it handled TERM and exited successfully" "$(cat "$CHILD_RESULT" 2>/dev/null)" "term-success"

# B3 mutation pin: trap disarm must be the signal handler's first action. Removing
# that exact action is exercised in an isolated real launcher copy: EXIT re-enters,
# attempts a second ended, and the broker refuses it. The persisted stream still has
# one ended, but the refusal proves the process-level double-terminal path went live.
signal_first_action="$(awk '/^_pep_signal_handler\(\) \{/{getline; print; exit}' "$LA")"
eq "signal handler disarms EXIT/INT/TERM/HUP before any other action" "$signal_first_action" "  trap - EXIT INT TERM HUP"
MUTANT_ROOT="$WORK/no-trap-disarm"
MUTANT="$MUTANT_ROOT/bin/launch-agent"
mkdir -p "$MUTANT_ROOT/bin" "$MUTANT_ROOT/lib"
cp "$SRC_ROOT/lib/aibobnet.sh" "$MUTANT_ROOT/lib/aibobnet.sh"
if awk '
  /^_pep_signal_handler\(\) \{/ { in_handler=1; print; next }
  /^_pep_exit_handler\(\) \{/ { in_handler=0; print; next }
  in_handler && $0 == "  trap - EXIT INT TERM HUP" { print "  : # mutation: trap disarm removed"; changed++; in_handler=0; next }
  { print }
  END { if (changed != 1) exit 42 }
' "$LA" > "$MUTANT" && chmod +x "$MUTANT"; then
  ok "trap-disarm mutation applied exactly once"
else
  no "trap-disarm mutation applied exactly once"
fi

reset_case
write_registry codex "$ADAPTER"
write_stub_conf sleep
PATH="$STUB_BIN:$SYSTEM_PATH" AIBOBNET_REGISTRY="$REG" \
  "$MUTANT" --as acme-core --timeout 20 --label mutant-term --prompt x \
  >"$RUN_STDOUT" 2>"$RUN_STDERR" &
LAUNCH_PID=$!
if wait_ready; then ok "trap-disarm mutant reached a running child"; else no "trap-disarm mutant reached a running child"; fi
kill -TERM "$LAUNCH_PID" 2>/dev/null || true
wait_launch
eq "trap-disarm mutant preserves the original TERM status" "$RUN_RC" 143
eq "broker still persists only one ended under reentry" "$(event_count)" 2
mutant_error="$(cat "$RUN_STDERR" 2>/dev/null)"
has "trap-disarm mutant reaches the refused second-ended path" "$mutant_error" "already has an attempt.ended"

total=$((pass+fail))
printf '\n%d checks: %d ok / %d fail\n' "$total" "$pass" "$fail"
[ "$fail" -eq 0 ]
