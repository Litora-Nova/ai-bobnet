#!/usr/bin/env bash
# The advisory sample is emitted for admitted/refused requests, never a gate.
set -uo pipefail
ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HANDLER="$ROOT/bin/aib-broker-handler"
WORK=$(mktemp -d)
holder=''
trap '[ -z "$holder" ] || kill "$holder" 2>/dev/null; rm -rf "$WORK"' EXIT
export AIB_EVENT_ROOT="$WORK/events" AIBOBNET_REGISTRY=/nonexistent AIB_BROKER_CAPACITY=1
pass=0 fail=0
check() { if "$@"; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL - %s\n' "$*"; fi; }
request() { printf 'op=launch\nagent_uid=acme-core\nprompt_bytes=2\n\nhi' | "$HANDLER" 2>"$WORK/err"; }
request >"$WORK/out"
check test "$(cat "$AIB_EVENT_ROOT/attempts/.live" 2>/dev/null)" = 0
check grep -qx reason=registry_unavailable "$WORK/out"
lease="$AIB_EVENT_ROOT/attempts/acme-core.0"
( exec 9>>"$lease"; flock 9; exec sleep 30 ) & holder=$!
for ((i=0;i<100;i++)); do ( exec 8>>"$lease"; flock -n 8 ) || break; sleep .02; done
request >"$WORK/out"; rc=$?
check test "$rc" = 2
check grep -qx reason=over_capacity "$WORK/out"
check test "$(cat "$AIB_EVENT_ROOT/attempts/.live" 2>/dev/null)" = 1
check test "$(stat -c %a "$AIB_EVENT_ROOT/attempts/.live" 2>/dev/null)" = 640
kill "$holder"; wait "$holder" 2>/dev/null || true; holder=''
mkdir "$WORK/bin"
cat > "$WORK/bin/mv" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$WORK/bin/mv"
PATH="$WORK/bin:$PATH" request >"$WORK/out"
check grep -qx reason=registry_unavailable "$WORK/out"
check test "$(cat "$AIB_EVENT_ROOT/attempts/.live" 2>/dev/null)" = 1
check grep -q 'cannot publish admission live count' "$WORK/err"
printf '\nbroker_live_spec: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
