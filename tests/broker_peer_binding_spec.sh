#!/usr/bin/env bash
# ai-bobnet — DP: broker launches are bound to the connecting AF_UNIX peer.
set -uo pipefail

ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
# shellcheck source=lib/aibobnet.sh
. "$ROOT/lib/aibobnet.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/aib-peer.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

pass=0 fail=0
ok(){ pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
no(){ fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; }
skip(){ printf 'ok   - (skipped: %s)\n' "$1"; }
has(){ if printf '%s\n' "$2" | grep -qF -- "$3"; then ok "$1"; else no "$1 (missing '$3')"; fi; }
hasnt(){ if printf '%s\n' "$2" | grep -qF -- "$3"; then no "$1 (unexpected '$3')"; else ok "$1"; fi; }

ME=$(id -u)
OTHER=$((ME + 10000))
HUMAN=$((ME + 10001))
GATEWAY=$((ME + 10002))
mkdir -p "$WORK/home" "$WORK/standup" "$WORK/state/acme-worker" "$WORK/events"

cat > "$WORK/identity" <<SH
#!/usr/bin/env bash
case "\$1" in
  $ME|$OTHER) printf 'role:aib-worker\n' ;;
  $HUMAN) printf 'human:operator\n' ;;
  $GATEWAY) printf 'gateway:aib-gw\n' ;;
  *) printf 'unknown:%s\n' "\$1" ;;
esac
SH
chmod +x "$WORK/identity"

REAL_PEER=$(env -i PATH="$PATH" python3 -I - "$ROOT/lib/aib_broker_security.py" <<'PY'
import os
import socket
import subprocess
import sys

left, right = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
proc = subprocess.Popen(
    [sys.executable, "-I", sys.argv[1], "peer-agent", "acme-worker"],
    stdin=right,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    env={"PATH": os.environ["PATH"]},
)
right.close()
out, _ = proc.communicate(timeout=5)
left.close()
print(out, end="")
PY
)
if printf '%s\n' "$REAL_PEER" | grep -qF "peer_uid=$ME"; then
  ok "the production path reads the real uid from an AF_UNIX SO_PEERCRED"
elif printf '%s\n' "$REAL_PEER" | grep -qF 'reason=peer_credentials_unavailable'; then
  skip "SO_PEERCRED is denied by this sandbox; fake-peer policy coverage continues"
else
  no "the production path reads the real uid from an AF_UNIX SO_PEERCRED (got '$REAL_PEER')"
fi

# The installed marker disables fake credentials even when both environment
# variables are present. stdin is deliberately a pipe, so only a leaked seam
# could turn this into an allow/root result.
mkdir -p "$WORK/installed/lib"
cp "$ROOT/lib/aib_broker_security.py" "$ROOT/lib/aib_control.py" "$WORK/installed/lib/"
: > "$WORK/installed/.aib-installed"
INSTALLED_PEER=$(printf x | env -i PATH="$PATH" AIB_TEST_SEAMS=1 AIB_TEST_PEER_UID=0 \
  python3 -I "$WORK/installed/lib/aib_broker_security.py" peer-agent acme-worker)
has "an installed engine ignores the fake-peer seam" "$INSTALLED_PEER" "reason=peer_credentials_unavailable"
hasnt "the disabled installed-tree seam cannot impersonate root" "$INSTALLED_PEER" "reason=root_supervisor"

cat > "$WORK/provider" <<'SH'
#!/usr/bin/env bash
printf 'provider-ran\n'
SH
cat > "$WORK/landlock" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(dirname "$0")/landlock.args"
while [ "${1:-}" = --uid ] || [ "${1:-}" = --gid ] || [ "${1:-}" = --groups ]; do shift 2; done
exec "$@"
SH
chmod +x "$WORK/provider" "$WORK/landlock"

cat > "$WORK/registry.json" <<JSON
{
  "schema_version": 4,
  "providers": {"stub": {"adapter": "$WORK/provider", "cap_sandbox": "workspace-write", "cap_tier": "t2", "cap_effort": "high", "cap_timeout": "30"}},
  "projects": {"acme": {"home": "$WORK/home", "standup_dir": "$WORK/standup", "data_class": "internal", "mux_session": "acme", "provider": "stub", "model": "example", "effort": "low"}},
  "teams": {},
  "agents": {
    "acme-worker": {"project": "acme", "profile": "worker", "clearance": "t2"},
    "acme-lead": {"project": "acme", "profile": "lead", "clearance": "t2"}
  }
}
JSON

frame(){
  printf 'op=launch\nagent_uid=%s\nsandbox=read-only\ntimeout=10\ncwd_bytes=0\nlabel_bytes=0\nprompt_bytes=2\n\nhi' "$1"
}
run_as(){
  local peer=$1 target=$2
  frame "$target" | env -i PATH="$PATH" HOME="$WORK" \
    AIB_TEST_SEAMS=1 AIB_TEST_PEER_UID="$peer" AIB_IDENTITY_CMD="$WORK/identity" \
    AIB_ROLE_UIDS="$ME" \
    AIB_SUP_STATE_ROOT="$WORK/state" AIBOBNET_REGISTRY="$WORK/registry.json" \
    AIB_EVENT_ROOT="$WORK/events" AIB_CONFINE_BIN="$WORK/landlock" \
    "$ROOT/bin/aib-broker-handler" 2>"$WORK/handler.err"
}

# The state directory is kernel-owned by ME. A role peer with another uid must not
# use the caller-supplied agent label to acquire that agent's launch authority.
RC=0; OUT=$(run_as "$OTHER" acme-lead) || RC=$?
has "a role peer cannot launch an agent whose state owner is another uid" "$OUT" "end=denied"
has "the denial names the peer authorization stage" "$OUT" "stage=peer"
has "the denial uses the existing authorization reason" "$OUT" "reason=unauthorized"
hasnt "a peer denial never enacts the provider" "$OUT" "provider-ran"
[ "$RC" -eq 3 ] && ok "a peer denial exits 3" || no "a peer denial exits 3 (got $RC)"

SCAN=$(aib_event_scan "$WORK/events/acme/main.events")
has "the peer denial is durably audited as attempt.decided" "$SCAN" '"event_type":"attempt.decided"'
has "the audit records a deny decision" "$SCAN" '"decision":"deny"'
has "the audit reason distinguishes a role/agent mismatch" "$SCAN" 'peer_role_mismatch'

OUT=$(run_as "$ME" acme-worker)
has "the role account bound to the target state owner may launch its own agent" "$OUT" "provider-ran"
has "the own-agent launch completes normally" "$OUT" "end=ok"
has "the target role uid/gid come from the prepared agent state directory" "$(cat "$WORK/landlock.args")" "--uid $ME --gid $(id -g)"

mkdir -p "$WORK/state/acme-lead"
OUT=$(run_as 0 acme-lead)
has "the root supervisor path may launch any registered agent" "$OUT" "provider-ran"

OUT=$(run_as "$HUMAN" acme-lead)
has "a current human operator may launch through the broker" "$OUT" "provider-ran"

RC=0; OUT=$(run_as "$GATEWAY" acme-lead) || RC=$?
has "a gateway identity does not inherit the human launch exception" "$OUT" "reason=unauthorized"
hasnt "a gateway denial never enacts" "$OUT" "provider-ran"

RC=0; OUT=$(run_as "$ME" acme-worker) || RC=$?
has "one role uid owning two agent state dirs is ambiguous and denied" "$OUT" "peer_role_mismatch"
hasnt "an ambiguous role binding never enacts" "$OUT" "provider-ran"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
