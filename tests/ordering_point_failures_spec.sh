#!/usr/bin/env bash
# ai-bobnet — black-box fault and race coverage for serialized journal commits.
#
# The engine is copied into a disposable tree and exercised only through public
# commands. Mechanical PATH shims pause existing awk/flock calls; no production
# test hook or private shell function is invoked.
set -uo pipefail

SRC_ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
SOURCE_ENGINE="${AIB_ORDERING_SOURCE_ROOT:-$SRC_ROOT}"
printf 'ordering source engine: %s\n' "$SOURCE_ENGINE" >&2
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-ordering-failures.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

ENGINE="$WORK/engine"
STATE="$WORK/state"
mkdir -p "$ENGINE" "$STATE/acme" "$STATE/beta" "$STATE/shared"
cp -R "$SOURCE_ENGINE/bin" "$SOURCE_ENGINE/scripts" "$SOURCE_ENGINE/lib" "$ENGINE/"

cat > "$ENGINE/registry.json" <<JSON
{
  "schema_version": 2,
  "shared_memory_dir": "$STATE/shared",
  "projects": {
    "acme": { "home": "$STATE/acme", "standup_dir": "$STATE/acme/standup", "mux_session": "acme" },
    "beta": { "home": "$STATE/beta", "standup_dir": "$STATE/beta/standup", "mux_session": "beta" }
  },
  "agents": {
    "acme-core":      { "project": "acme", "profile": "engine-dev", "clearance": "t2" },
    "acme-review":    { "project": "acme", "profile": "review",     "clearance": "t1" },
    "acme-second":    { "project": "acme", "profile": "review",     "clearance": "t1" },
    "beta-review":    { "project": "beta", "profile": "review",     "clearance": "t1" },
    "beta-lockfail":  { "project": "beta", "profile": "tests",      "clearance": "t1" },
    "beta-writefail": { "project": "beta", "profile": "tests",      "clearance": "t1" }
  }
}
JSON

RUN="$ENGINE/bin/run-agent"
MEM="$ENGINE/bin/memory"
MSG="$ENGINE/bin/message"
WAKE="$ENGINE/bin/wakeup"
PROJECT_JOURNAL="$STATE/acme/standup/memory/project.md"
SHARED_JOURNAL="$STATE/shared/shared.md"
INBOX="$STATE/beta/standup/inbox/beta-review.md"
mkdir -p "$(dirname "$PROJECT_JOURNAL")"
: > "$PROJECT_JOURNAL"
: > "$SHARED_JOURNAL"

mem() { local agent="$1"; shift; "$RUN" "$agent" -- "$MEM" "$@"; }
msg() { local agent="$1"; shift; "$RUN" "$agent" -- "$MSG" "$@"; }

pass=0
fail=0
ok() { pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
no() { fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; }
assert_streq() {
  if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2' want '$3')"; fi
}
assert_nonzero() {
  if [ "$2" -ne 0 ]; then ok "$1"; else no "$1 (got rc 0)"; fi
}
assert_absent() {
  if ! grep -qF -- "$3" "$2" 2>/dev/null; then ok "$1"; else no "$1 (unexpected '$3' in $2)"; fi
}
assert_nonempty_file() {
  if [ -s "$2" ]; then ok "$1"; else no "$1 (expected a diagnostic in $2)"; fi
}

successes() {
  local count=0 rc
  for rc in "$@"; do [ "$rc" -eq 0 ] && count=$((count+1)); done
  printf '%s\n' "$count"
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
matched_file=0
for arg in "$@"; do
  [ "$arg" = "mode=$AIB_TEST_FOLD_MODE" ] && matched_mode=1
  [ "$arg" = "want=$AIB_TEST_FOLD_WANT" ] && matched_want=1
  [ "$arg" = "$AIB_TEST_FOLD_FILE" ] && matched_file=1
done
if [ "$matched_mode" -ne 1 ] || [ "$matched_want" -ne 1 ] || [ "$matched_file" -ne 1 ]; then
  exec "$AIB_TEST_REAL_AWK" "$@"
fi
out="$AIB_TEST_BARRIER/out.$$"
"$AIB_TEST_REAL_AWK" "$@" > "$out"
rc=$?
if [ "${AIB_TEST_PAUSE_FOLD:-0}" -eq 1 ] &&
   [ ! -e "$AIB_TEST_BARRIER/release" ]; then
  gate="$AIB_TEST_BARRIER/gate.fold.$$"
  mkfifo "$gate"
  exec {gate_fd}<>"$gate" || exit 98
  printf 'fold\t%s\t-\n' "$$" > "$AIB_TEST_BARRIER/events"
  IFS= read -r -u "$gate_fd" _release || exit 98
  exec {gate_fd}>&- || exit 98
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
  exec {gate_fd}<>"$gate" || exit 98
  printf 'held\t%s\t%s\n' "$$" "$lock_path" > "$AIB_TEST_BARRIER/events"
  IFS= read -r -u "$gate_fd" _release || exit 98
  exec {gate_fd}>&- || exit 98
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

retained_gate_barrier="$WORK/retained-gate-barrier"
mkdir -p "$retained_gate_barrier"
mkfifo "$retained_gate_barrier/gate.late-reader"
exec {retained_gate_fd}<>"$retained_gate_barrier/gate.late-reader"
retained_gate_value=""
release_barrier_gates "$retained_gate_barrier"
if IFS= read -r -t 1 -u "$retained_gate_fd" retained_gate_value &&
   [ "$retained_gate_value" = release ]; then
  ok "barrier cleanup: an opened receiver retains release until its late read"
else
  no "barrier cleanup: release was lost before the opened receiver read it"
fi
exec {retained_gate_fd}>&-

race_mem() {
  local barrier="$1" want="$2" mode="$3" agent="$4"
  local pause_fold=0 pause_lock=1
  [ "$mode" != fold ] || { pause_fold=1; pause_lock=0; }
  shift 4
  env PATH="$SHIM:$PATH" AIB_TEST_REAL_AWK="$REAL_AWK" \
    AIB_TEST_REAL_FLOCK="$REAL_FLOCK" \
    AIB_TEST_BARRIER="$barrier" AIB_TEST_FOLD_MODE=meta \
    AIB_TEST_FOLD_WANT="$want" AIB_TEST_FOLD_FILE="$SHARED_JOURNAL" \
    AIB_TEST_PAUSE_FOLD="$pause_fold" AIB_TEST_PAUSE_LOCK="$pause_lock" \
    timeout 10 "$RUN" "$agent" -- "$MEM" "$@"
}

# 1. One explicit memory id may occupy only one reachable journal.
cross_barrier="$WORK/cross-barrier"
prepare_barrier "$cross_barrier"
release_after_contention "$cross_barrier" fold & cross_release_pid=$!
race_mem "$cross_barrier" memory-cross fold acme-core \
  propose --scope project "project racer" --id memory-cross >"$WORK/cross-project.out" 2>&1 & cross_project_pid=$!
race_mem "$cross_barrier" memory-cross fold acme-core \
  propose --scope shared "shared racer" --id memory-cross >"$WORK/cross-shared.out" 2>&1 & cross_shared_pid=$!
wait "$cross_project_pid"; cross_project_rc=$?
wait "$cross_shared_pid"; cross_shared_rc=$?
wait "$cross_release_pid"; cross_release_rc=$?
assert_streq "cross-scope propose: the fold barrier was reached" "$cross_release_rc" "0"
assert_streq "cross-scope propose: exactly one command wins" \
  "$(successes "$cross_project_rc" "$cross_shared_rc")" "1"
cross_project_count="$(grep -cF 'id:memory-cross | scope:project' "$PROJECT_JOURNAL" 2>/dev/null || true)"
cross_shared_count="$(grep -cF 'id:memory-cross | scope:shared' "$SHARED_JOURNAL" 2>/dev/null || true)"
cross_project_count="${cross_project_count:-0}"
cross_shared_count="${cross_shared_count:-0}"
cross_count="$((cross_project_count + cross_shared_count))"
assert_streq "cross-scope propose: exactly one PROPOSED record is committed" "$cross_count" "1"

# A same-scope retry remains idempotent while sharing the same commit lock.
retry_barrier="$WORK/retry-barrier"
prepare_barrier "$retry_barrier"
release_after_contention "$retry_barrier" fold & retry_release_pid=$!
race_mem "$retry_barrier" memory-retry fold acme-core \
  propose --scope project "first retry body" --id memory-retry >"$WORK/retry-1.out" 2>&1 & retry_1_pid=$!
race_mem "$retry_barrier" memory-retry fold acme-core \
  propose --scope project "second retry body" --id memory-retry >"$WORK/retry-2.out" 2>&1 & retry_2_pid=$!
wait "$retry_1_pid"; retry_1_rc=$?
wait "$retry_2_pid"; retry_2_rc=$?
wait "$retry_release_pid"; retry_release_rc=$?
assert_streq "same-scope retry: the fold barrier was reached" "$retry_release_rc" "0"
assert_streq "same-scope retry: both idempotent commands succeed" "$retry_1_rc:$retry_2_rc" "0:0"
retry_count="$(grep -cF 'id:memory-retry | scope:project' "$PROJECT_JOURNAL" 2>/dev/null || true)"
assert_streq "same-scope retry: exactly one PROPOSED record is committed" "$retry_count" "1"

# 2. Conflicting reviews must serialize their state decision with the append.
mem acme-core propose --scope project "review race" --id memory-review >/dev/null
review_barrier="$WORK/review-barrier"
prepare_barrier "$review_barrier"
release_after_contention "$review_barrier" lock & review_release_pid=$!
race_mem "$review_barrier" memory-review lock acme-review \
  review memory-review accept "accept racer" >"$WORK/accept.out" 2>&1 & accept_pid=$!
race_mem "$review_barrier" memory-review lock acme-second \
  review memory-review reject "reject racer" >"$WORK/reject.out" 2>&1 & reject_pid=$!
wait "$accept_pid"; accept_rc=$?
wait "$reject_pid"; reject_rc=$?
wait "$review_release_pid"; review_release_rc=$?
assert_streq "conflicting review: the fold barrier was reached" "$review_release_rc" "0"
assert_streq "conflicting review: exactly one command wins" \
  "$(successes "$accept_rc" "$reject_rc")" "1"
review_count="$(grep -Ec 'id:memory-review \| event:REVIEWED_(ACCEPT|REJECT)' "$PROJECT_JOURNAL" 2>/dev/null || true)"
assert_streq "conflicting review: exactly one review event is committed" "$review_count" "1"

# 3. Duplicate reviews with the same verdict serialize to one event.
mem acme-core propose --scope project "duplicate review race" --id memory-review-duplicate >/dev/null
duplicate_review_barrier="$WORK/duplicate-review-barrier"
prepare_barrier "$duplicate_review_barrier"
release_after_contention "$duplicate_review_barrier" lock & duplicate_review_release_pid=$!
race_mem "$duplicate_review_barrier" memory-review-duplicate lock acme-review \
  review memory-review-duplicate accept "first accept" >"$WORK/accept-1.out" 2>&1 & accept_1_pid=$!
race_mem "$duplicate_review_barrier" memory-review-duplicate lock acme-second \
  review memory-review-duplicate accept "second accept" >"$WORK/accept-2.out" 2>&1 & accept_2_pid=$!
wait "$accept_1_pid"; accept_1_rc=$?
wait "$accept_2_pid"; accept_2_rc=$?
wait "$duplicate_review_release_pid"; duplicate_review_release_rc=$?
assert_streq "duplicate review: the lock release was reached" "$duplicate_review_release_rc" "0"
assert_streq "duplicate review: both idempotent commands succeed" "$accept_1_rc:$accept_2_rc" "0:0"
duplicate_review_count="$(grep -cF 'id:memory-review-duplicate | event:REVIEWED_ACCEPT' "$PROJECT_JOURNAL" 2>/dev/null || true)"
assert_streq "duplicate review: exactly one REVIEWED_ACCEPT event is committed" \
  "$duplicate_review_count" "1"

# 4. Promotion retries are successful no-ops after the first serialized append.
mem acme-core propose --scope project "promotion race" --id memory-promote >/dev/null
mem acme-review review memory-promote accept >/dev/null
promote_barrier="$WORK/promote-barrier"
prepare_barrier "$promote_barrier"
release_after_contention "$promote_barrier" lock & promote_release_pid=$!
race_mem "$promote_barrier" memory-promote lock acme-review \
  promote memory-promote >"$WORK/promote-1.out" 2>&1 & promote_1_pid=$!
race_mem "$promote_barrier" memory-promote lock acme-second \
  promote memory-promote >"$WORK/promote-2.out" 2>&1 & promote_2_pid=$!
wait "$promote_1_pid"; promote_1_rc=$?
wait "$promote_2_pid"; promote_2_rc=$?
wait "$promote_release_pid"; promote_release_rc=$?
assert_streq "parallel promote: the fold barrier was reached" "$promote_release_rc" "0"
assert_streq "parallel promote: both idempotent commands succeed" "$promote_1_rc:$promote_2_rc" "0:0"
promote_count="$(grep -cF 'id:memory-promote | event:PROMOTED' "$PROJECT_JOURNAL" 2>/dev/null || true)"
assert_streq "parallel promote: exactly one PROMOTED event is committed" "$promote_count" "1"

# 5. Failure to open the delivery lock must fail before acknowledging the id.
LOCKFAIL_INBOX="$STATE/beta/standup/inbox/beta-lockfail.md"
mkdir -p "$(dirname "$LOCKFAIL_INBOX")" "$LOCKFAIL_INBOX.lock"
timeout 5 "$RUN" acme-core -- "$MSG" send beta-lockfail "lock failure" --id message-lockfail \
  >"$WORK/message-lockfail.out" 2>"$WORK/message-lockfail.err"
message_lockfail_rc=$?
assert_nonzero "message lock-open failure: command fails" "$message_lockfail_rc"
assert_streq "message lock-open failure: no id is printed" "$(cat "$WORK/message-lockfail.out")" ""
assert_absent "message lock-open failure: no journal record is committed" "$LOCKFAIL_INBOX" "id:message-lockfail"

# 6. A checked append must fail loudly and never print a success id. A symlink
# to the finite, readable, non-appendable procfs status file reaches the append
# after the normal pre-append fold without depending on the test user's uid.
WRITEFAIL_INBOX="$STATE/beta/standup/inbox/beta-writefail.md"
ln -s /proc/self/status "$WRITEFAIL_INBOX"
: > "$WRITEFAIL_INBOX.lock"
timeout 5 "$RUN" acme-core -- "$MSG" send beta-writefail "append failure" --id message-writefail \
  >"$WORK/message-writefail.out" 2>"$WORK/message-writefail.err"
message_writefail_rc=$?
assert_nonzero "message append failure: command fails" "$message_writefail_rc"
assert_streq "message append failure: no id is printed" "$(cat "$WORK/message-writefail.out")" ""
assert_nonempty_file "message append failure: a diagnostic is printed" "$WORK/message-writefail.err"

# 7. A wakeup hook runs inside the recipient mutation boundary. A concurrent
# recipient mutation must wait. Killing only the wakeup parent must release the
# lock even while its blocked hook child remains alive; inherited lock handles
# must not let an orphaned external process stall future journal mutations.
msg acme-core send beta-review "lock release" --id wakeup-kill >/dev/null
HOOK_MARKER="$WORK/hook-entered"
HOOK_RELEASE="$WORK/hook-release"
BLOCKING_HOOK="$WORK/blocking-hook"
cat > "$BLOCKING_HOOK" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$AIB_TEST_HOOK_MARKER"
while [ ! -e "$AIB_TEST_HOOK_RELEASE" ]; do sleep 0.01; done
exit 0
SH
chmod +x "$BLOCKING_HOOK"

env AIB_TEST_HOOK_MARKER="$HOOK_MARKER" AIB_TEST_HOOK_RELEASE="$HOOK_RELEASE" \
  "$RUN" acme-core -- env AIBOBNET_WAKEUP_HOOK="$BLOCKING_HOOK" \
  "$WAKE" beta-review >"$WORK/wakeup-kill.out" 2>"$WORK/wakeup-kill.err" & wakeup_pid=$!

ticks=0
while [ ! -e "$HOOK_MARKER" ] && [ "$ticks" -lt 500 ]; do
  sleep 0.01
  ticks=$((ticks+1))
done
if [ -e "$HOOK_MARKER" ]; then
  ok "killed wakeup: blocking hook was entered"
else
  no "killed wakeup: blocking hook was not entered"
fi

timeout 1 "$RUN" beta-review -- "$MSG" seen wakeup-kill \
  >"$WORK/while-hook.out" 2>"$WORK/while-hook.err"
while_hook_rc=$?
assert_streq "killed wakeup: recipient mutation waits while the hook owns the lock" \
  "$while_hook_rc" "124"

hook_pid="$(cat "$HOOK_MARKER" 2>/dev/null || true)"
kill -TERM "$wakeup_pid" 2>/dev/null || true
wait "$wakeup_pid" 2>/dev/null || true
if [ -n "$hook_pid" ] && kill -0 "$hook_pid" 2>/dev/null; then
  ok "killed wakeup: hook child remains blocked after its parent exits"
else
  no "killed wakeup: hook child did not remain alive"
fi

timeout 5 "$RUN" beta-review -- "$MSG" seen wakeup-kill \
  >"$WORK/after-kill.out" 2>"$WORK/after-kill.err"
after_kill_rc=$?
assert_streq "killed wakeup: a subsequent recipient mutation completes" "$after_kill_rc" "0"
seen_count="$(grep -cF 'id:wakeup-kill | event:SEEN' "$INBOX" 2>/dev/null || true)"
assert_streq "killed wakeup: the subsequent mutation commits exactly once" "$seen_count" "1"

: > "$HOOK_RELEASE"
ticks=0
while [ -n "$hook_pid" ] && kill -0 "$hook_pid" 2>/dev/null && [ "$ticks" -lt 500 ]; do
  sleep 0.01
  ticks=$((ticks+1))
done
if [ -z "$hook_pid" ] || ! kill -0 "$hook_pid" 2>/dev/null; then
  ok "killed wakeup: released hook child exits during cleanup"
else
  no "killed wakeup: released hook child did not exit"
  kill -TERM "$hook_pid" 2>/dev/null || true
fi

# 8. Explicit memory ids are engine-global collision keys, including project
# and private journals that are not otherwise readable by the proposing agent.
mem acme-core propose --scope project "global project id" --id global-project-id >/dev/null
mem beta-review propose --scope shared "must collide with acme project" --id global-project-id \
  >"$WORK/global-project.out" 2>"$WORK/global-project.err"
global_project_rc=$?
assert_nonzero "global memory id: shared proposal rejects another project's project id" \
  "$global_project_rc"
assert_absent "global memory id: rejected shared proposal appends nothing" \
  "$SHARED_JOURNAL" "id:global-project-id"
assert_streq "global memory id: project record remains unambiguous" \
  "$(mem acme-core state global-project-id 2>/dev/null || true)" "PROPOSED"

mem acme-core propose --scope agent "global private id" --id global-private-id >/dev/null
mem beta-review propose --scope shared "must collide with acme private" --id global-private-id \
  >"$WORK/global-private.out" 2>"$WORK/global-private.err"
global_private_rc=$?
assert_nonzero "global memory id: shared proposal rejects another project's private id" \
  "$global_private_rc"
assert_absent "global memory id: private collision appends no shared record" \
  "$SHARED_JOURNAL" "id:global-private-id"
assert_streq "global memory id: private record remains unambiguous" \
  "$(mem acme-core state global-private-id 2>/dev/null || true)" "PROPOSED"

mem acme-review propose --scope agent "other agent private id" --id other-private-id >/dev/null
mem acme-core propose --scope project "must collide with other private" --id other-private-id \
  >"$WORK/other-private.out" 2>"$WORK/other-private.err"
other_private_rc=$?
assert_nonzero "global memory id: project proposal rejects another agent's private id" \
  "$other_private_rc"
assert_absent "global memory id: other-agent collision appends no project record" \
  "$PROJECT_JOURNAL" "id:other-private-id"
assert_streq "global memory id: other agent's private record remains unambiguous" \
  "$(mem acme-review state other-private-id 2>/dev/null || true)" "PROPOSED"

# 8. An explicit send must propagate an unexpected exists-fold failure. Treating
# every non-match status as "absent" would acknowledge and append unverified work.
FOLDFAIL_SHIM="$WORK/foldfail-shim"
FOLDFAIL_MARKER="$WORK/foldfail-reached"
mkdir -p "$FOLDFAIL_SHIM"
cat > "$FOLDFAIL_SHIM/awk" <<'SH'
#!/usr/bin/env bash
matched_mode=0
matched_want=0
for arg in "$@"; do
  [ "$arg" = mode=exists ] && matched_mode=1
  [ "$arg" = want=message-foldfail ] && matched_want=1
done
if [ "$matched_mode" -eq 1 ] && [ "$matched_want" -eq 1 ]; then
  : > "$AIB_TEST_FOLDFAIL_MARKER"
  exit 2
fi
exec "$AIB_TEST_REAL_AWK" "$@"
SH
chmod +x "$FOLDFAIL_SHIM/awk"

env PATH="$FOLDFAIL_SHIM:$PATH" AIB_TEST_REAL_AWK="$REAL_AWK" \
  AIB_TEST_FOLDFAIL_MARKER="$FOLDFAIL_MARKER" \
  "$RUN" acme-core -- "$MSG" send beta-review "fold failure" --id message-foldfail \
  >"$WORK/message-foldfail.out" 2>"$WORK/message-foldfail.err"
message_foldfail_rc=$?
if [ -e "$FOLDFAIL_MARKER" ]; then
  ok "message fold failure: targeted exists fold was reached"
else
  no "message fold failure: targeted exists fold was not reached"
fi
assert_nonzero "message fold failure: send fails closed" "$message_foldfail_rc"
assert_streq "message fold failure: no id is printed" "$(cat "$WORK/message-foldfail.out")" ""
assert_absent "message fold failure: no journal record is committed" \
  "$INBOX" "id:message-foldfail"

# 9. A fold that emits plausible partial output and then fails is still a
# failure. Neither mutation decisions nor public reads may trust its stdout.
PARTIAL_SHIM="$WORK/partial-output-shim"
PARTIAL_MARKER="$WORK/partial-output-reached"
mkdir -p "$PARTIAL_SHIM"
cat > "$PARTIAL_SHIM/awk" <<'SH'
#!/usr/bin/env bash
matched_mode=0
matched_want=0
matched_file=0
for arg in "$@"; do
  [ "$arg" = "mode=$AIB_TEST_PARTIAL_MODE" ] && matched_mode=1
  [ "$arg" = "want=$AIB_TEST_PARTIAL_WANT" ] && matched_want=1
  [ -z "${AIB_TEST_PARTIAL_FILE:-}" ] || [ "$arg" != "$AIB_TEST_PARTIAL_FILE" ] || matched_file=1
done
[ "$AIB_TEST_PARTIAL_WANT" != '*' ] || matched_want=1
[ -n "${AIB_TEST_PARTIAL_FILE:-}" ] || matched_file=1
if [ "$matched_mode" -eq 1 ] && [ "$matched_want" -eq 1 ] && [ "$matched_file" -eq 1 ]; then
  : > "$AIB_TEST_PARTIAL_MARKER"
  case "$AIB_TEST_PARTIAL_MODE" in
    state) printf '%s\n' PERSISTED;;
    meta)  printf 'project\tacme-core\tPROPOSED\n';;
  esac
  exit 2
fi
exec "$AIB_TEST_REAL_AWK" "$@"
SH
chmod +x "$PARTIAL_SHIM/awk"

msg acme-core send beta-review "partial state fold" --id message-partial-state >/dev/null

rm -f "$PARTIAL_MARKER"
env PATH="$PARTIAL_SHIM:$PATH" AIB_TEST_REAL_AWK="$REAL_AWK" \
  AIB_TEST_PARTIAL_MARKER="$PARTIAL_MARKER" AIB_TEST_PARTIAL_MODE=state \
  AIB_TEST_PARTIAL_WANT=message-partial-state AIB_TEST_PARTIAL_FILE='' \
  "$RUN" beta-review -- "$MSG" state message-partial-state \
  >"$WORK/partial-state-read.out" 2>"$WORK/partial-state-read.err"
partial_state_read_rc=$?
if [ -e "$PARTIAL_MARKER" ]; then
  ok "partial state read: targeted fold emitted output and rc 2"
else
  no "partial state read: targeted fold was not reached"
fi
assert_nonzero "partial state read: public read propagates rc 2" "$partial_state_read_rc"
assert_streq "partial state read: unverified state is not printed" \
  "$(cat "$WORK/partial-state-read.out")" ""

rm -f "$PARTIAL_MARKER"
env PATH="$PARTIAL_SHIM:$PATH" AIB_TEST_REAL_AWK="$REAL_AWK" \
  AIB_TEST_PARTIAL_MARKER="$PARTIAL_MARKER" AIB_TEST_PARTIAL_MODE=state \
  AIB_TEST_PARTIAL_WANT=message-partial-state AIB_TEST_PARTIAL_FILE='' \
  "$RUN" beta-review -- "$MSG" done message-partial-state \
  >"$WORK/partial-state-done.out" 2>"$WORK/partial-state-done.err"
partial_state_done_rc=$?
if [ -e "$PARTIAL_MARKER" ]; then
  ok "partial state mutation: targeted fold emitted output and rc 2"
else
  no "partial state mutation: targeted fold was not reached"
fi
assert_nonzero "partial state mutation: done fails closed" "$partial_state_done_rc"
assert_absent "partial state mutation: no PROCESSED event is appended" \
  "$INBOX" "id:message-partial-state | event:PROCESSED"
assert_streq "partial state mutation: normal state remains PERSISTED" \
  "$(msg beta-review state message-partial-state 2>/dev/null || true)" "PERSISTED"

# A metadata fold follows the same rule. Plausible scope/author/state output may
# not hide rc 2 and permit an engine-global id collision in the shared journal.
mem acme-core propose --scope project "partial meta fold" --id memory-partial-meta >/dev/null
rm -f "$PARTIAL_MARKER"
env PATH="$PARTIAL_SHIM:$PATH" AIB_TEST_REAL_AWK="$REAL_AWK" \
  AIB_TEST_PARTIAL_MARKER="$PARTIAL_MARKER" AIB_TEST_PARTIAL_MODE=meta \
  AIB_TEST_PARTIAL_WANT=memory-partial-meta AIB_TEST_PARTIAL_FILE="$PROJECT_JOURNAL" \
  "$RUN" beta-review -- "$MEM" propose --scope shared \
    "must reject partial metadata" --id memory-partial-meta \
  >"$WORK/partial-meta.out" 2>"$WORK/partial-meta.err"
partial_meta_rc=$?
if [ -e "$PARTIAL_MARKER" ]; then
  ok "partial metadata: targeted fold emitted valid metadata and rc 2"
else
  no "partial metadata: targeted fold was not reached"
fi
assert_nonzero "partial metadata: shared proposal fails closed" "$partial_meta_rc"
assert_streq "partial metadata: no id is acknowledged" "$(cat "$WORK/partial-meta.out")" ""
assert_absent "partial metadata: no shared proposal is appended" \
  "$SHARED_JOURNAL" "id:memory-partial-meta"
assert_streq "partial metadata: original proposal remains unambiguous" \
  "$(mem acme-core state memory-partial-meta 2>/dev/null || true)" "PROPOSED"

# Generated ids use the same metadata scan. An unexpected error is not proof
# that the generated id is free, even when no explicit id was supplied.
rm -f "$PARTIAL_MARKER"
env PATH="$PARTIAL_SHIM:$PATH" AIB_TEST_REAL_AWK="$REAL_AWK" \
  AIB_TEST_PARTIAL_MARKER="$PARTIAL_MARKER" AIB_TEST_PARTIAL_MODE=meta \
  AIB_TEST_PARTIAL_WANT='*' AIB_TEST_PARTIAL_FILE="$PROJECT_JOURNAL" \
  "$RUN" acme-core -- "$MEM" propose --scope project "generated scan must fail" \
  >"$WORK/generated-meta.out" 2>"$WORK/generated-meta.err"
generated_meta_rc=$?
if [ -e "$PARTIAL_MARKER" ]; then
  ok "generated metadata: targeted collision scan returned rc 2"
else
  no "generated metadata: targeted collision scan was not reached"
fi
assert_nonzero "generated metadata: proposal fails closed" "$generated_meta_rc"
assert_streq "generated metadata: no generated id is acknowledged" \
  "$(cat "$WORK/generated-meta.out")" ""
assert_absent "generated metadata: no proposal is appended" \
  "$PROJECT_JOURNAL" "generated scan must fail"

total=$((pass+fail))
printf '\n%d checks: %d ok / %d fail\n' "$total" "$pass" "$fail"
[ "$fail" -eq 0 ]
