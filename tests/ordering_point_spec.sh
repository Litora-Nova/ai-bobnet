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

# Pause only the selected message fold, after awk has captured its result. The
# release delay starts when the first racer arrives. With no lock, the peer also
# captures stale state before release. With a lock, the peer folds after append.
REAL_AWK="$(command -v awk)"
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
: > "$AIB_TEST_BARRIER/ready.$$"
while [ ! -e "$AIB_TEST_BARRIER/release" ]; do sleep 0.01; done
cat "$out"
exit "$rc"
SH
chmod +x "$SHIM/awk"

release_fold_after_first() {
  local barrier="$1" marker ticks=0
  while [ "$ticks" -lt 500 ]; do
    for marker in "$barrier"/ready.*; do
      if [ -e "$marker" ]; then
        sleep 1
        : > "$barrier/release"
        return 0
      fi
    done
    sleep 0.01
    ticks=$((ticks+1))
  done
  : > "$barrier/release"
  return 1
}

race_m() {
  local barrier="$1" mode="$2" want="$3" agent="$4"
  shift 4
  env PATH="$SHIM:$PATH" AIB_TEST_REAL_AWK="$REAL_AWK" \
    AIB_TEST_BARRIER="$barrier" AIB_TEST_FOLD_MODE="$mode" \
    AIB_TEST_FOLD_WANT="$want" \
    "$RUN" "$agent" -- "$MSG" "$@"
}

# 1. Concurrent idempotent sends must commit one PERSISTED record.
send_barrier="$WORK/send-barrier"
mkdir -p "$send_barrier"
release_fold_after_first "$send_barrier" & send_release_pid=$!
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
mkdir -p "$terminal_barrier"
release_fold_after_first "$terminal_barrier" & terminal_release_pid=$!
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
HOOK_RELEASE="$WORK/hook.release"
cat > "$HOOK" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$3" >> "$AIB_TEST_HOOK_LOG"
while [ ! -e "$AIB_TEST_HOOK_RELEASE" ]; do sleep 0.01; done
exit 0
SH
chmod +x "$HOOK"

release_hook_after_first() {
  local ticks=0
  while [ ! -s "$HOOK_LOG" ] && [ "$ticks" -lt 500 ]; do
    sleep 0.01
    ticks=$((ticks+1))
  done
  if [ ! -s "$HOOK_LOG" ]; then
    : > "$HOOK_RELEASE"
    return 1
  fi
  sleep 1
  : > "$HOOK_RELEASE"
}

release_hook_after_first & hook_release_pid=$!
for n in 1 2; do
  env AIB_TEST_HOOK_LOG="$HOOK_LOG" AIB_TEST_HOOK_RELEASE="$HOOK_RELEASE" \
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

total=$((pass+fail))
printf '\n%d checks: %d ok / %d fail\n' "$total" "$pass" "$fail"
[ "$fail" -eq 0 ]
