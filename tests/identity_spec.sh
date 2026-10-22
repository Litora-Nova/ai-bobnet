#!/usr/bin/env bash
# ai-bobnet — control-plane identity classification from kernel uid and protected role.env.
set -uo pipefail
SRC_ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-identity.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
no(){ fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; }
eq(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2' want '$3')"; fi; }

cat > "$WORK/role.env" <<'EOF'
# Parsed as data, never sourced.
AIB_ROLE_UID=41001
IGNORED=$(printf unsafe)
AIB_ROLE_UIDS=41001,41002
EOF

OUT="$(AIB_TEST_SEAMS=1 AIB_ROLE_ENV_FILE="$WORK/role.env" PYTHONPATH="$SRC_ROOT/lib" python3 -I - "$SRC_ROOT/lib" <<'PY'
import sys
from types import SimpleNamespace

sys.path.insert(0, sys.argv[1])
import aib_control

accounts = {
    40001: SimpleNamespace(pw_name="operator", pw_gid=50001),
    40002: SimpleNamespace(pw_name="aib-gw", pw_gid=50002),
    41002: SimpleNamespace(pw_name="worker", pw_gid=50003),
}
primary_groups = {
    50001: SimpleNamespace(gr_name="aib-shared"),
    50002: SimpleNamespace(gr_name="aib-gateway"),
    50003: SimpleNamespace(gr_name="workers"),
}
supplementary = [SimpleNamespace(gr_name="aib-gateway", gr_mem=["operator"])]
aib_control.pwd.getpwuid = accounts.__getitem__
aib_control.grp.getgrgid = primary_groups.__getitem__
aib_control.grp.getgrall = lambda: supplementary

for uid in accounts:
    print(aib_control.identity_for(uid))
PY
)"
eq "an aib-gateway group member who is also aib-shared remains human" "$(printf '%s\n' "$OUT" | sed -n '1p')" "human:operator"
eq "the dedicated aib-gw account is a gateway" "$(printf '%s\n' "$OUT" | sed -n '2p')" "gateway:aib-gw"
eq "a non-aib account whose numeric uid is in role.env is a role" "$(printf '%s\n' "$OUT" | sed -n '3p')" "role:worker"

printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
