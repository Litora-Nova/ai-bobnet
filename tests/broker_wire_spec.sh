#!/usr/bin/env bash
# ai-bobnet — RM-3 broker, slice 1: transport framing and unit wiring.
#
# WHAT THIS PINS (mediated launch contract §6):
#   A request frame is  <token record lines> \n\n <exactly N raw bytes of free text>.
#   Token fields carry ONLY validated tokens. Free text is length-prefixed and read by
#   COUNTING BYTES — never by searching for a separator. That is the whole point: a prompt
#   containing "\nagent_uid=root" must arrive as bytes, not as a forged field.
#
#   A response frame ALWAYS ends with a terminal status line. Both spikes on 2026-08-10 showed
#   why: a crashed handler and a connection dropped by MaxConnections are both indistinguishable
#   from success at the client (empty body, rc=0). Without a terminal line the caller cannot tell
#   "denied" from "broker died".
#
#   The unit files are asserted as text because the wiring itself was the trap: with Accept=yes
#   but no explicit StandardInput/StandardOutput=socket, the handler receives nothing on stdin and
#   writes to the journal — a silently non-functional service.
set -uo pipefail

SRC_ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
# shellcheck source=lib/aibobnet.sh
. "$SRC_ROOT/lib/aibobnet.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-wire.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
no(){ fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; }
assert_streq(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2' want '$3')"; fi; }
assert_ok(){   local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else no "$d (expected success)"; fi; }
assert_fail(){ local d="$1"; shift; if "$@" >/dev/null 2>&1; then no "$d (expected refusal)"; else ok "$d"; fi; }
assert_grep(){ if printf '%s\n' "$2" | grep -qF -- "$3"; then ok "$1"; else no "$1 (missing '$3')"; fi; }
assert_ngrep(){ if printf '%s\n' "$2" | grep -qF -- "$3"; then no "$1 (unexpected '$3')"; else ok "$1"; fi; }

# frame <freetext> <token-line>...  -> writes a request frame to stdout
frame(){ local t="$1"; shift; local l; for l in "$@"; do printf '%s\n' "$l"; done
         printf 'prompt_bytes=%s\n\n' "${#t}"; printf '%s' "$t"; }

read_req(){ aib_wire_read_request; }   # reads stdin, sets AIB_REQ_*, rc!=0 on refusal

# --- 1. the honest case ------------------------------------------------------
out="$(frame "hallo welt" "op=launch" "agent_uid=acme-dev" | { read_req && printf '%s|%s|%s' \
      "${AIB_REQ_OP:-}" "${AIB_REQ_AGENT_UID:-}" "${AIB_REQ_PROMPT:-}"; })"
assert_streq "token fields and free text are separated" "$out" "launch|acme-dev|hallo welt"

# --- 2. THE injection probe (§6) --------------------------------------------
inj="$(printf 'zeile1\nagent_uid=root\nzeile3')"
out="$(frame "$inj" "op=launch" "agent_uid=acme-dev" | { read_req && printf '%s' "${AIB_REQ_AGENT_UID:-}"; })"
assert_streq "embedded newline cannot forge agent_uid" "$out" "acme-dev"
out="$(frame "$inj" "op=launch" "agent_uid=acme-dev" | { read_req && printf '%s' "${AIB_REQ_PROMPT:-}"; })"
assert_streq "the forged text survives INTACT as payload" "$out" "$inj"

# --- 3. fail closed on the length prefix ------------------------------------
assert_fail "missing prompt_bytes is refused" \
  bash -c 'printf "op=launch\nagent_uid=acme-dev\n\nfreitext" | { . "'"$SRC_ROOT"'/lib/aibobnet.sh"; aib_wire_read_request; }'
assert_fail "non-numeric prompt_bytes is refused" \
  bash -c 'printf "op=launch\nprompt_bytes=viele\n\nfreitext" | { . "'"$SRC_ROOT"'/lib/aibobnet.sh"; aib_wire_read_request; }'
assert_fail "short read (fewer bytes than declared) is refused" \
  bash -c 'printf "op=launch\nprompt_bytes=999\n\nkurz" | { . "'"$SRC_ROOT"'/lib/aibobnet.sh"; aib_wire_read_request; }'
assert_fail "free text beyond the cap is refused" \
  bash -c 'p=$(head -c 200000 /dev/zero | tr "\0" "x"); printf "op=launch\nprompt_bytes=%s\n\n%s" "${#p}" "$p" | { . "'"$SRC_ROOT"'/lib/aibobnet.sh"; aib_wire_read_request; }'

# --- 4. identity is composed under the lock, never accepted (§3) -------------
for f in event_id attempt_id seq; do
  assert_fail "pre-composed $f is refused at the seam" \
    bash -c 'printf "op=launch\n'"$f"'=x1\nprompt_bytes=2\n\nhi" | { . "'"$SRC_ROOT"'/lib/aibobnet.sh"; aib_wire_read_request; }'
done

# --- 5. token fields stay tokens --------------------------------------------
assert_fail "control character in a token field is refused" \
  bash -c 'printf "op=launch\nagent_uid=acme\x01dev\nprompt_bytes=2\n\nhi" | { . "'"$SRC_ROOT"'/lib/aibobnet.sh"; aib_wire_read_request; }'
assert_fail "the protocol carries no environment fields" \
  bash -c 'printf "op=launch\nenv_HOME=/tmp\nprompt_bytes=2\n\nhi" | { . "'"$SRC_ROOT"'/lib/aibobnet.sh"; aib_wire_read_request; }'

# --- 6. every response ends with a terminal status line ---------------------
resp="$(aib_wire_write_response ok "exit_class=success")"
assert_grep "response carries its payload"        "$resp" "exit_class=success"
assert_grep "response ends with a terminal line"  "$resp" "end=ok"
assert_streq "the terminal line is genuinely LAST" "$(printf '%s\n' "$resp" | tail -1)" "end=ok"
resp="$(aib_wire_write_response denied "reason=clearance")"
assert_grep "a refusal is also terminal"          "$resp" "end=denied"

# --- 7. the unit wiring (the silent-failure trap) ---------------------------
SVC="$SRC_ROOT/deploy/systemd/aib-broker@.service"
SOCK="$SRC_ROOT/deploy/systemd/aib-broker.socket"
assert_ok "instance unit is shipped" test -f "$SVC"
assert_ok "socket unit is shipped"   test -f "$SOCK"
svc="$(cat "$SVC" 2>/dev/null)"; sock="$(cat "$SOCK" 2>/dev/null)"
assert_grep  "stdin is EXPLICITLY the socket"  "$svc"  "StandardInput=socket"
assert_grep  "stdout is EXPLICITLY the socket" "$svc"  "StandardOutput=socket"
assert_grep  "one instance per connection"     "$sock" "Accept=yes"
assert_grep  "connection limit is set"         "$sock" "MaxConnections="
assert_ngrep "MaxConnectionsPerSource is NOT used" "$sock" "MaxConnectionsPerSource"
assert_ngrep "no daemon loop is shipped"       "$svc"  "Type=simple"

printf '\nbroker_wire_spec: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
