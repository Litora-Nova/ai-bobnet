#!/usr/bin/env bash
# ai-bobnet — install pre-flight refuses role.env that gives children the broker socket group.
set -uo pipefail

ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/aib-preflight.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

pass=0 fail=0 RC=0 OUT=
ok(){ pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
no(){ fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; }
eq(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2' want '$3')"; fi; }
has(){ case "$2" in *"$3"*) ok "$1";; *) no "$1 (missing '$3')";; esac; }

SHARED_GID=$(getent group aib-shared 2>/dev/null | cut -d: -f3)
: "${SHARED_GID:=424242}"
ROLE_ENV="$WORK/role.env"

write_role_env(){
  printf 'AIB_ROLE_UID=5001\nAIB_ROLE_GID=%s\nAIB_ROLE_UIDS=5001\nAIB_ROLE_GROUPS=%s\nAIB_SUP_STATE_ROOT=/var/lib/aib-sup\n' \
    "$1" "$2" > "$ROLE_ENV"
}
run_preflight(){
  RC=0
  OUT=$(env AIB_TEST_SEAMS=1 AIB_TEST_SHARED_GID="$SHARED_GID" \
    "$ROOT/bin/aib-preflight" "$ROLE_ENV" 2>&1) || RC=$?
}

write_role_env 5001 5002,5003
run_preflight
eq "a role.env without aib-shared passes the install pre-flight" "$RC" 0

write_role_env "$SHARED_GID" 5002,5003
run_preflight
eq "aib-shared as AIB_ROLE_GID refuses installation" "$RC" 1
has "the primary-group refusal names AIB_ROLE_GID" "$OUT" "AIB_ROLE_GID"
has "the primary-group refusal gives a clear provisioning instruction" "$OUT" "aib-shared"

write_role_env 5001 "5002,$SHARED_GID,5003"
run_preflight
eq "aib-shared in AIB_ROLE_GROUPS refuses installation" "$RC" 1
has "the supplementary-group refusal names AIB_ROLE_GROUPS" "$OUT" "AIB_ROLE_GROUPS"
has "the supplementary-group refusal gives a clear provisioning instruction" "$OUT" "aib-shared"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
