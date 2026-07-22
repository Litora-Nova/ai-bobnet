#!/usr/bin/env bash
# ai-bobnet — deterministic black-box races for serialized journal commits.
#
# The engine is copied into a temporary tree and driven only through its public
# commands. An awk shim pauses a selected fold after it has read the journal.
# That makes the legacy check-then-append race reproducible while still allowing
# a locking implementation to serialize the second process behind the first.
set -uo pipefail

SRC_ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
SOURCE_ENGINE="${AIB_ORDERING_SOURCE_ROOT:-$SRC_ROOT}"
printf 'ordering source engine: %s\n' "$SOURCE_ENGINE" >&2
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-ordering.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

ENGINE="$WORK/engine"
STATE="$WORK/state"
mkdir -p "$ENGINE" "$STATE/acme" "$STATE/beta"
cp -R "$SOURCE_ENGINE/bin" "$SOURCE_ENGINE/scripts" "$SOURCE_ENGINE/lib" "$ENGINE/"

cat > "$ENGINE/registry.json" <<JSON
{
  "schema_version": 2,
  "projects": {
    "acme": { "home": "$STATE/acme", "standup_dir": "$STATE/acme/standup", "mux_session": "acme" },
    "beta": { "home": "$STATE/beta", "standup_dir": "$STATE/beta/standup", "mux_session": "beta" }
  },
  "agents": {
    "acme-core":  { "project": "acme", "profile": "engine-dev", "clearance": "t2" },
    "beta-review": { "project": "beta", "profile": "review", "clearance": "t1" }
  }
}
JSON

RUN="$ENGINE/bin/run-agent"
MSG="$ENGINE/bin/message"
WAKE="$ENGINE/bin/wakeup"
INBOX="$STATE/beta/standup/inbox/beta-review.md"

m() { local agent="$1"; shift; "$RUN" "$agent" -- "$MSG" "$@"; }

pass=0
fail=0
ok() { pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
no() { fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; }
assert_streq() {
  if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2' want '$3')"; fi
}

# A flock shim reports lock identity and can park an acquired holder. Selected
# awk folds park after capturing state. The controller releases one fold only
# after a peer has attempted the same lock; with distinct or missing locks it
# waits for both stale folds. Lock-only races release an acquired holder only
# after the peer attempts its lock. No wall-clock grace decides race readiness.
REAL_AWK="$(command -v awk)"
REAL_FLOCK="$(command -v flock)"
SHIM="$WORK/shim"
mkdir -p "$SHIM"
cat > "$SHIM/awk" <<'SH'
#!/usr/bin/env bash
matched_mode=0
matched_want=0
for arg in "$@"; do
  [ "$arg" = "mode=$AIB_TEST_FOLD_MODE" ] && matched_mode=1
  [ "$arg" = "want=$AIB_TEST_FOLD_WANT" ] && matched_want=1
done
if [ "$matched_mode" -ne 1 ] || [ "$matched_want" -ne 1 ]; then
  exec "$AIB_TEST_REAL_AWK" "$@"
fi
out="$AIB_TEST_BARRIER/out.$$"
"$AIB_TEST_REAL_AWK" "$@" > "$out"
rc=$?
if [ "${AIB_TEST_PAUSE_FOLD:-0}" -eq 1 ] &&
   [ ! -e "$AIB_TEST_BARRIER/release" ]; then
  gate="$AIB_TEST_BARRIER/gate.fold.$$"
  mkfifo "$gate"
  printf 'fold\t%s\t-\n' "$$" > "$AIB_TEST_BARRIER/events"
  IFS= read -r _release < "$gate"
fi
cat "$out"
exit "$rc"
SH
chmod +x "$SHIM/awk"

cat > "$SHIM/flock" <<'SH'
#!/usr/bin/env bash
lock_fd="${!#}"
lock_path="$(readlink "/proc/self/fd/$lock_fd" 2>/dev/null || true)"
[ -n "$lock_path" ] || { printf 'cannot resolve test lock fd %s\n' "$lock_fd" >&2; exit 98; }
if [ ! -e "$AIB_TEST_BARRIER/release" ]; then
  printf 'attempt\t%s\t%s\n' "$$" "$lock_path" > "$AIB_TEST_BARRIER/events"
fi
"$AIB_TEST_REAL_FLOCK" "$@"
rc=$?
if [ "$rc" -eq 0 ] && [ "${AIB_TEST_PAUSE_LOCK:-0}" -eq 1 ] &&
   [ ! -e "$AIB_TEST_BARRIER/release" ]; then
  gate="$AIB_TEST_BARRIER/gate.lock.$$"
  mkfifo "$gate"
  printf 'held\t%s\t%s\n' "$$" "$lock_path" > "$AIB_TEST_BARRIER/events"
  IFS= read -r _release < "$gate"
fi
exit "$rc"
SH
chmod +x "$SHIM/flock"

prepare_barrier() {
  mkdir -p "$1"
  mkfifo "$1/events"
}

release_barrier_gates() {
  local barrier="$1" gate gate_fd rc=0
  for gate in "$barrier"/gate.*; do
    [ -p "$gate" ] || continue
    if exec {gate_fd}<>"$gate"; then
      printf 'release\n' >&"$gate_fd" || rc=1
      exec {gate_fd}>&- || rc=1
    else
      rc=1
    fi
  done
  return "$rc"
}

release_after_contention() {
  local barrier="$1" mode="$2" event pid lock_path
  local attempt_count=0 held_count=0 fold_count=0 event_fd gate rc=0
  local first_lock="" second_lock=""
  exec {event_fd}<>"$barrier/events" || return 1
  while :; do
    if ! IFS=$'\t' read -r -t 10 -u "$event_fd" event pid lock_path; then
      rc=1
      break
    fi
    case "$event" in
      attempt)
        attempt_count=$((attempt_count+1))
        [ "$attempt_count" -ne 1 ] || first_lock="$lock_path"
        [ "$attempt_count" -ne 2 ] || second_lock="$lock_path"
        ;;
      held) held_count=$((held_count+1));;
      fold) fold_count=$((fold_count+1));;
    esac
    case "$mode" in
      fold)
        [ "$fold_count" -lt 2 ] || break
        if [ "$attempt_count" -ge 2 ] && [ "$first_lock" = "$second_lock" ] &&
           [ "$fold_count" -ge 1 ]; then break; fi
        ;;
      lock)
        if [ "$attempt_count" -ge 2 ] && [ "$first_lock" = "$second_lock" ] &&
           [ "$held_count" -ge 1 ]; then break; fi
        if [ "$attempt_count" -ge 2 ] && [ "$first_lock" != "$second_lock" ] &&
           [ "$held_count" -ge 2 ]; then break; fi
        ;;
      *) rc=1; break;;
    esac
  done
  : > "$barrier/release"
  release_barrier_gates "$barrier" || rc=1
  exec {event_fd}>&-
  return "$rc"
}

stale_gate_barrier="$WORK/stale-gate-barrier"
mkdir -p "$stale_gate_barrier"
mkfifo "$stale_gate_barrier/gate.stale"
export -f release_barrier_gates
if timeout 1 bash -c 'release_barrier_gates "$1"' _ "$stale_gate_barrier"; then
  ok "barrier cleanup: a stale FIFO without a reader cannot block release"
else
  no "barrier cleanup: stale FIFO release blocked or failed"
fi
export -n -f release_barrier_gates

race_m() {
  local barrier="$1" mode="$2" want="$3" agent="$4"
  shift 4
  env PATH="$SHIM:$PATH" AIB_TEST_REAL_AWK="$REAL_AWK" \
    AIB_TEST_REAL_FLOCK="$REAL_FLOCK" \
    AIB_TEST_BARRIER="$barrier" AIB_TEST_FOLD_MODE="$mode" \
    AIB_TEST_FOLD_WANT="$want" AIB_TEST_PAUSE_FOLD=1 AIB_TEST_PAUSE_LOCK=0 \
    "$RUN" "$agent" -- "$MSG" "$@"
}

# 1. Concurrent idempotent sends must commit one PERSISTED record.
send_barrier="$WORK/send-barrier"
prepare_barrier "$send_barrier"
release_after_contention "$send_barrier" fold & send_release_pid=$!
race_m "$send_barrier" exists send-race acme-core \
  send beta-review "first sender" --id send-race >"$WORK/send-1.out" 2>&1 & send_1=$!
race_m "$send_barrier" exists send-race acme-core \
  send beta-review "second sender" --id send-race >"$WORK/send-2.out" 2>&1 & send_2=$!
wait "$send_1"; send_1_rc=$?
wait "$send_2"; send_2_rc=$?
wait "$send_release_pid"; send_release_rc=$?
assert_streq "parallel send: the fold release was reached" "$send_release_rc" "0"
assert_streq "parallel send: both idempotent calls succeed" "$send_1_rc:$send_2_rc" "0:0"
send_count="$(grep -cF 'id:send-race | from:acme-core | to:beta-review' "$INBOX" 2>/dev/null || true)"
assert_streq "parallel send: exactly one PERSISTED record is committed" "$send_count" "1"

# 2. Concurrent terminal transitions must have one winner.
m acme-core send beta-review "terminal race" --id terminal-race >/dev/null
terminal_barrier="$WORK/terminal-barrier"
prepare_barrier "$terminal_barrier"
release_after_contention "$terminal_barrier" fold & terminal_release_pid=$!
race_m "$terminal_barrier" state terminal-race beta-review \
  done terminal-race >"$WORK/done.out" 2>&1 & done_pid=$!
race_m "$terminal_barrier" state terminal-race beta-review \
  fail terminal-race "parallel failure" >"$WORK/fail.out" 2>&1 & fail_pid=$!
wait "$done_pid"; done_rc=$?
wait "$fail_pid"; fail_rc=$?
wait "$terminal_release_pid"; terminal_release_rc=$?
assert_streq "parallel terminal: the fold release was reached" "$terminal_release_rc" "0"
assert_streq "parallel terminal: both commands complete cleanly" "$done_rc:$fail_rc" "0:0"
terminal_count="$(grep -Ec 'id:terminal-race \| event:(PROCESSED|FAILED)' "$INBOX" 2>/dev/null || true)"
assert_streq "parallel terminal: exactly one terminal event is committed" "$terminal_count" "1"

# 3. Concurrent wakeups must not duplicate either the external ping or NOTIFIED.
m acme-core send beta-review "wakeup race" --id wake-race >/dev/null
HOOK="$WORK/slow-success-hook"
HOOK_LOG="$WORK/hook.log"
hook_barrier="$WORK/hook-barrier"
prepare_barrier "$hook_barrier"
cat > "$HOOK" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$3" >> "$AIB_TEST_HOOK_LOG"
exit 0
SH
chmod +x "$HOOK"

release_after_contention "$hook_barrier" lock & hook_release_pid=$!
for n in 1 2; do
  env PATH="$SHIM:$PATH" AIB_TEST_REAL_AWK="$REAL_AWK" \
    AIB_TEST_REAL_FLOCK="$REAL_FLOCK" \
    AIB_TEST_BARRIER="$hook_barrier" AIB_TEST_PAUSE_LOCK=1 \
    AIB_TEST_HOOK_LOG="$HOOK_LOG" \
    "$RUN" acme-core -- env AIBOBNET_WAKEUP_HOOK="$HOOK" \
      "$WAKE" beta-review >"$WORK/wake-$n.out" 2>&1 &
  eval "wake_${n}_pid=$!"
done
wait "$wake_1_pid"; wake_1_rc=$?
wait "$wake_2_pid"; wake_2_rc=$?
wait "$hook_release_pid"; hook_release_rc=$?
assert_streq "parallel wakeup: the hook release was reached" "$hook_release_rc" "0"
assert_streq "parallel wakeup: both commands complete cleanly" "$wake_1_rc:$wake_2_rc" "0:0"
hook_count="$(grep -cFx 'wake-race' "$HOOK_LOG" 2>/dev/null || true)"
assert_streq "parallel wakeup: the success hook is invoked exactly once" "$hook_count" "1"
notified_count="$(grep -cF 'id:wake-race | event:NOTIFIED' "$INBOX" 2>/dev/null || true)"
assert_streq "parallel wakeup: exactly one NOTIFIED event is committed" "$notified_count" "1"

# 4. Concurrent failed wakeups at the attempt limit must exhaust exactly once.
m acme-core send beta-review "wakeup exhaustion race" --id wake-exhaust-race >/dev/null
EXHAUST_HOOK="$WORK/failing-hook"
EXHAUST_HOOK_LOG="$WORK/failing-hook.log"
cat > "$EXHAUST_HOOK" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$3" >> "$AIB_TEST_HOOK_LOG"
exit 1
SH
chmod +x "$EXHAUST_HOOK"

# Leave one attempt in a budget of two, then race the two exhaustion candidates.
env AIB_TEST_HOOK_LOG="$EXHAUST_HOOK_LOG" \
  "$RUN" acme-core -- env AIBOBNET_WAKEUP_HOOK="$EXHAUST_HOOK" \
    AIBOBNET_WAKEUP_MAX_ATTEMPTS=2 "$WAKE" beta-review >/dev/null 2>&1
exhaust_barrier="$WORK/exhaust-barrier"
prepare_barrier "$exhaust_barrier"
release_after_contention "$exhaust_barrier" lock & exhaust_release_pid=$!
for n in 1 2; do
  env PATH="$SHIM:$PATH" AIB_TEST_REAL_AWK="$REAL_AWK" \
    AIB_TEST_REAL_FLOCK="$REAL_FLOCK" AIB_TEST_BARRIER="$exhaust_barrier" \
    AIB_TEST_PAUSE_LOCK=1 AIB_TEST_HOOK_LOG="$EXHAUST_HOOK_LOG" \
    "$RUN" acme-core -- env AIBOBNET_WAKEUP_HOOK="$EXHAUST_HOOK" \
      AIBOBNET_WAKEUP_MAX_ATTEMPTS=2 "$WAKE" beta-review \
      >"$WORK/exhaust-$n.out" 2>&1 &
  eval "exhaust_${n}_pid=$!"
done
wait "$exhaust_1_pid"; exhaust_1_rc=$?
wait "$exhaust_2_pid"; exhaust_2_rc=$?
wait "$exhaust_release_pid"; exhaust_release_rc=$?
assert_streq "concurrent wakeup exhaustion: the lock release was reached" \
  "$exhaust_release_rc" "0"
assert_streq "concurrent wakeup exhaustion: both commands complete cleanly" \
  "$exhaust_1_rc:$exhaust_2_rc" "0:0"
exhaust_hook_count="$(grep -cFx 'wake-exhaust-race' "$EXHAUST_HOOK_LOG" 2>/dev/null || true)"
assert_streq "concurrent wakeup exhaustion: failed hook stops at the attempt budget" \
  "$exhaust_hook_count" "2"
exhaust_attempt_count="$(grep -cF '| wakeattempt:wake-exhaust-race |' "$INBOX" 2>/dev/null || true)"
assert_streq "concurrent wakeup exhaustion: exactly two attempt records are committed" \
  "$exhaust_attempt_count" "2"
exhaust_failed_count="$(grep -cF 'wakeattempt:wake-exhaust-race | id:wake-exhaust-race | event:FAILED' "$INBOX" 2>/dev/null || true)"
assert_streq "concurrent wakeup exhaustion: exactly one terminal FAILED event is committed" \
  "$exhaust_failed_count" "1"
assert_streq "concurrent wakeup exhaustion: final state is FAILED" \
  "$(m beta-review state wake-exhaust-race)" "FAILED"

total=$((pass+fail))
printf '\n%d checks: %d ok / %d fail\n' "$total" "$pass" "$fail"
[ "$fail" -eq 0 ]
