#!/usr/bin/env bash
# Anchor durability failures and admission configuration must fail closed.
set -uo pipefail
SRC_ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$SRC_ROOT/lib/aibobnet.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
pass=0 fail=0
check() { if "$@"; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL - %s\n' "$*"; fi; }
EVENTS="$WORK/events"
ENV_KV=$'project_uid=acme\nactor_type=service\nactor_id=broker'
PAYLOAD=$(aib_event_compose_decided_payload $'decision=allow\ncode=0')
commit() { aib_event_commit "$EVENTS" "$EVENTS.lock" attempt.decided "$ENV_KV" "$PAYLOAD" '' anchor; }
# Seed without depending on the implementation's anchor support.
aib_event_commit "$EVENTS" "$EVENTS.lock" attempt.decided "$ENV_KV" "$PAYLOAD"
printf '1\n' > "$EVENTS.high_water"
original=$(cat "$EVENTS")
for bad in '' -1 01 '1 2' $'1\n\n' $'1\nx'; do
  printf '%s' "$bad" > "$EVENTS.high_water"
  ( commit ) >"$WORK/out" 2>"$WORK/err"; rc=$?
  check test "$rc" -ne 0
  check test "$(cat "$EVENTS")" = "$original"
  printf '%s\n' "$original" > "$EVENTS"
done
# No signed integer wraparound can turn a huge ahead anchor into lag.
printf '9999999999999999999999999999' > "$EVENTS.high_water"
( commit ) >"$WORK/out" 2>"$WORK/err"; check test "$?" -ne 0
check test "$(cat "$EVENTS")" = "$original"
mkdir "$WORK/bin"
REAL_SYNC=$(command -v sync); REAL_MV=$(command -v mv)
export REAL_SYNC REAL_MV EVENTS
cat > "$WORK/bin/sync" <<'STUB'
#!/usr/bin/env bash
printf 'sync %s\n' "$*" >> "$TRACE"
case "$FAULT:$*" in
  stream:"-d -- $EVENTS"|temp:*"$EVENTS.high_water."*|dir:"-- ${EVENTS%/*}") exit 1;;
esac
exec "$REAL_SYNC" "$@"
STUB
cat > "$WORK/bin/mv" <<'STUB'
#!/usr/bin/env bash
printf 'mv %s\n' "$*" >> "$TRACE"
[ "$FAULT" != rename ] || exit 1
exec "$REAL_MV" "$@"
STUB
chmod +x "$WORK/bin/"*
export TRACE="$WORK/trace"
for FAULT in stream temp rename dir; do
  export FAULT
  printf '%s\n' "$original" > "$EVENTS"
  printf '1\n' > "$EVENTS.high_water"
  ( PATH="$WORK/bin:$PATH" commit ) >"$WORK/out" 2>"$WORK/err"; check test "$?" -ne 0
  if [ "$FAULT" != dir ]; then check test "$(cat "$EVENTS.high_water")" = 1; fi
done
# Catch-up must make the scanned prefix durable before publishing its anchor.
# A process crash may leave a complete append in cache before its stream fsync.
for state in lag absent; do
  printf '%s\n' "$original" > "$EVENTS"
  if [ "$state" = lag ]; then printf '0\n' > "$EVENTS.high_water"; else rm -f "$EVENTS.high_water"; fi
  ( FAULT=stream PATH="$WORK/bin:$PATH" commit ) >"$WORK/out" 2>"$WORK/err"; rc=$?
  check test "$rc" -ne 0
  check test "$(cat "$EVENTS")" = "$original"
  if [ "$state" = lag ]; then check test "$(cat "$EVENTS.high_water")" = 0
  else check test ! -e "$EVENTS.high_water"; fi
done
printf '%s\n' "$original" > "$EVENTS"
printf '99\n' > "$EVENTS.high_water"
FAULT=stream PATH="$WORK/bin:$PATH" "$SRC_ROOT/bin/anchor" "$EVENTS" reanchor --accept-truncation >"$WORK/out" 2>"$WORK/err"
check test "$?" -ne 0
check test "$(cat "$EVENTS.high_water")" = 99

# Successful ordering excludes capability probes and requires full temp fsync.
printf '%s\n' "$original" > "$EVENTS"
printf '1\n' > "$EVENTS.high_water"
: > "$TRACE"
FAULT=none PATH="$WORK/bin:$PATH" commit >"$WORK/out" 2>"$WORK/err"
check test "$?" = 0
sequence=$(grep -v 'aib-sync\.' "$TRACE")
case "$sequence" in
  "sync -d -- $EVENTS"$'\n'"sync -- $EVENTS.high_water."*$'\n'"mv -f -- $EVENTS.high_water."*" $EVENTS.high_water"$'\n'"sync -- $WORK") check true;;
  *) check false;;
esac
# A NUL cannot be silently stripped by the anchor reader.
printf '2\0' > "$EVENTS.high_water"
( commit ) >"$WORK/out" 2>"$WORK/err"; check test "$?" -ne 0
# A corrupt stream cannot be blessed by the human repair tool either.
printf 'broken\n' > "$EVENTS"
"$SRC_ROOT/bin/anchor" "$EVENTS" reanchor --accept-truncation >"$WORK/out" 2>"$WORK/err"
check test "$?" -ne 0
check test "$(cat "$EVENTS")" = broken
# Admission configuration is rejected before attempting to read a frame.
for cap in 0 -1 bad 01 999999999999999999999999; do
  out=$(AIB_BROKER_CAPACITY="$cap" "$SRC_ROOT/bin/aib-broker-handler" </dev/null 2>"$WORK/err"); rc=$?
  check test "$rc" = 2
  check grep -qx 'reason=broker_misconfigured' <<<"$out"
done
out=$(AIB_BROKER_MAX_CONNECTIONS=bad "$SRC_ROOT/bin/aib-broker-handler" </dev/null 2>"$WORK/err")
check grep -qx 'reason=broker_misconfigured' <<<"$out"
# A project named attempts can share this directory with the pool. Its stream
# and anchor are never lease files and must survive admission's stale sweep.
export AIB_EVENT_ROOT="$WORK/store" AIBOBNET_REGISTRY=/nonexistent
mkdir -p "$AIB_EVENT_ROOT/attempts"
printf 'preserve\n' > "$AIB_EVENT_ROOT/attempts/main.events"
request() { printf 'op=launch\nagent_uid=acme-core\nprompt_bytes=2\n\nhi'; }
handler() { request | "$SRC_ROOT/bin/aib-broker-handler"; }
handler >"$WORK/out" 2>"$WORK/err"
check test "$(cat "$AIB_EVENT_ROOT/attempts/main.events" 2>/dev/null)" = preserve
# Operational admission failures must answer on the wire, before the registry.
REAL_FLOCK=$(command -v flock); REAL_RM=$(command -v rm)
export REAL_FLOCK REAL_RM
cat > "$WORK/bin/flock" <<'STUB'
#!/usr/bin/env bash
case "$MODE:$*" in
  lock:'-x -w 10 '*) exit 1;;
  probe:'-n -x '*) exit 70;;
  create:'-n -x '*) exit 1;;
esac
exec "$REAL_FLOCK" "$@"
STUB
cat > "$WORK/bin/rm" <<'STUB'
#!/usr/bin/env bash
[ "$MODE" != remove ] || exit 1
exec "$REAL_RM" "$@"
STUB
chmod +x "$WORK/bin/flock" "$WORK/bin/rm"
for MODE in root lockopen leaseopen lock probe create remove; do
  export MODE
  rm -rf "$AIB_EVENT_ROOT"
  mkdir -p "$AIB_EVENT_ROOT/attempts"
  case "$MODE" in
    root) rm -rf "$AIB_EVENT_ROOT"; : > "$AIB_EVENT_ROOT";;
    lockopen) mkdir "$AIB_EVENT_ROOT/attempts/attempts.lock";;
    leaseopen) mkdir "$AIB_EVENT_ROOT/attempts/acme-core.0";;
    probe|remove) : > "$AIB_EVENT_ROOT/attempts/acme-core.0";;
  esac
  PATH="$WORK/bin:$PATH" handler >"$WORK/out" 2>"$WORK/err"; rc=$?
  check test "$rc" = 2
  check grep -qx reason=event_store_unavailable "$WORK/out"
done
printf '\nbroker_anchor_fault_spec: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
