#!/usr/bin/env bash
# ai-bobnet — RED spec for the two login verbs of the gateway (Supervisor slice S1c; design v3.1 H4/H5). Extends tests/aib_gw_spec.sh
# (same invocation, same seams, same refusal classes); that spec is NOT changed.
#
# WHAT THIS PINS
#   New accepted forms in $SSH_ORIGINAL_COMMAND (exactly):
#     login start <provider>              handed to agentctl as argv `login start <provider>` with AIBOBNET_ACTOR=gateway-peer:<id>;
#                                         agentctl's exit code is the gateway's. Whether the login is DUE and the 1/h limit are the login
#                                         unit's decisions (tests/login_lifecycle_spec.sh), not the gateway's.
#     login-code <provider> <vorgang>     the one-time code arrives on STDIN (never on the command line). The gateway validates, then connects to
#                                         $AIB_LOGIN_SOCK_DIR/login-<provider>.sock (default /run/aib), sends ONE JSON line
#                                         {"provider":P,"vorgang":V,"code":C,"received_at":<epoch float, the gateway's clock>} and reads ONE JSON line back.
#                                         {"ok":true} => exit 0, print nothing. {"ok":false,"reason":R} => exit 77, stderr `rejected: R`.
#                                         No socket / connection refused / no answer in 10 s => exit 69, stderr says unavailable.
#   Validation (exit 64 `gateway_malformed`, audited as ctl.rejected like every malformed command, the socket NOT contacted):
#     provider matches [a-z0-9]+(-[a-z0-9]+)*; vorgang is exactly 32 lower-case hex chars; extra tokens (a code on the command line!) are
#     malformed; the stdin code is 1..256 bytes of [A-Za-z0-9#_-] with at most ONE trailing newline stripped (empty, a space, a tab, an
#     embedded newline, a quote, non-ASCII, or more than 256 bytes => 64).
#   Other login forms stay denied: `login stop x`, `login status x`, `login x`, `login-code` with no args... => 77 gateway_verb_denied for an unknown
#     sub-verb, 64 for missing operands of a known one. Peer allow-list applies first (unknown peer => 77 gateway_peer_denied, stdin never read).
#   THE CODE NEVER REACHES A LOG: not _control.jsonl, not stderr/stdout of the gateway, not agentctl's argv/env.
#
#   Expected on the unbuilt tree: the gateway whitelists neither form.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/fixtures/login_harness.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-gwlogin.XXXXXX")"
trap 'kill $(cat "$W/srv.pid" 2>/dev/null) 2>/dev/null; sup_cleanup' EXIT
lw_world g; as gateway:gw
printf 'hub1\n' > "$W/peers"
cat > "$W/fakes/agentctl" <<'FAKE'
#!/usr/bin/env bash
w=$(cd -P "$(dirname "$0")/.." && pwd)
{ printf 'ARGC=%s\n' "$#"; for a in "$@"; do printf 'ARG=%s\n' "$a"; done; printf 'ACTOR=%s\n---\n' "${AIBOBNET_ACTOR:-}"; } >> "$w/agentctl.calls"
exit "$(cat "$w/agentctl.rc" 2>/dev/null || echo 0)"
FAKE
chmod +x "$W/fakes/agentctl"
V=0123456789abcdef0123456789abcdef; CODE='GOOD-CODE_9#xyz'
# a one-shot-per-connection fake login unit: appends each received line to $W/srv.log, answers with the contents of $W/srv.reply
cat > "$W/srv.py" <<'PY'
import os, socket, sys
path, log, reply = sys.argv[1:4]
if os.path.exists(path): os.unlink(path)
s = socket.socket(socket.AF_UNIX); s.bind(path); s.listen(5)
while True:
    c, _ = s.accept()
    line = c.makefile().readline()
    open(log, "a").write(line)
    c.sendall((open(reply).read().strip() + "\n").encode()); c.close()
PY
gw() { # gw <peer-args> <command> [stdin]
  : > "$W/agentctl.calls"; : > "$CLOG"; : > "$W/srv.log"
  RC=0; OUT="$(printf '%s' "${3-}" | env -i PATH="$W/fakebin:$PATH" HOME="$W/home-ctl" LANG=C "${CTLENV[@]}" AIB_LOGIN_SOCK_DIR="$LSOCK" AIB_AGENTCTL="$W/fakes/agentctl" \
      AIB_GW_PEERS="$W/peers" SSH_ORIGINAL_COMMAND="$2" timeout 30 "$ENGINE/bin/aib-gw" $1 2>"$W/gw.err")" || RC=$?
  ERR="$(cat "$W/gw.err")"; CALLS="$(cat "$W/agentctl.calls")"
}

# --- T1 login start ---------------------------------------------------------------------------------------------------------------------------------
gw "--id hub1" "login start claude-code"
eq "T1: 'login start claude-code' => rc 0, agentctl argv exactly 'login start claude-code', actor gateway-peer:hub1" "$RC|$CALLS" "0|ARGC=3
ARG=login
ARG=start
ARG=claude-code
ACTOR=gateway-peer:hub1
---"
printf '77\n' > "$W/agentctl.rc"; gw "--id hub1" "login start codex"; eq "T1: agentctl's exit code is the gateway's (77)" "$RC" 77; rm -f "$W/agentctl.rc"
for c in "login start" "login start ../x" "login start Claude" "login start claude-code extra" "login start claude-code --force" "login start a;b" 'login start $(id)'; do
  gw "--id hub1" "$c"; eq "T1: '$c' => 64, agentctl not called, audited gateway_malformed" "$RC|$([ -z "$CALLS" ] && echo uncalled)|$(cf ctl.rejected -1 reason)" "64|uncalled|gateway_malformed"
done
for c in "login stop claude-code" "login status claude-code" "login claude-code" "login-start claude-code" "LOGIN start claude-code"; do
  gw "--id hub1" "$c"; eq "T1: '$c' => 77 gateway_verb_denied" "$RC|$([ -z "$CALLS" ] && echo uncalled)|$(cf ctl.rejected -1 reason)" "77|uncalled|gateway_verb_denied"
done
gw "--id mallory" "login start claude-code"; eq "T1: an unknown peer is refused first (77 gateway_peer_denied)" "$RC|$([ -z "$CALLS" ] && echo uncalled)|$(cf ctl.rejected -1 reason)" "77|uncalled|gateway_peer_denied"

# --- T2 login-code: forwarded over the socket -----------------------------------------------------------------------------------------------------------
echo '{"ok": true}' > "$W/srv.reply"
python3 -I "$W/srv.py" "$LSOCK/login-claude-code.sock" "$W/srv.log" "$W/srv.reply" & echo $! > "$W/srv.pid"
wait_for 5 bash -c "[ -S '$LSOCK/login-claude-code.sock' ]"
t0=$(date +%s.%N)
gw "--id hub1" "login-code claude-code $V" "$CODE"
t1=$(date +%s.%N)
eq "T2: an accepted code => rc 0, no output" "$RC|$OUT|$ERR" "0||"
msg="$(cat "$W/srv.log")"
eq "T2: the unit received exactly one JSON line with provider, vorgang, the code and a gateway timestamp" "$(printf '%s' "$msg" | python3 -I -c 'import json,sys;d=json.loads(sys.stdin.read());print(sorted(d),d["provider"],d["vorgang"],d["code"])' 2>/dev/null)" "['code', 'provider', 'received_at', 'vorgang'] claude-code $V $CODE"
eq "T2: received_at is the gateway's clock (between start and end of the call)" "$(printf '%s' "$msg" | python3 -I -c 'import json,sys;d=json.loads(sys.stdin.read());print(float(sys.argv[1])-1<=d["received_at"]<=float(sys.argv[2])+1)' "$t0" "$t1" 2>/dev/null)" True
eq "T2: agentctl was not involved" "$RC|$([ -z "$CALLS" ] && echo uncalled)" "0|uncalled"
eq "T2: the code is in no log: not _control.jsonl, not stderr, not stdout" "$(test -s "$W/srv.log" && echo forwarded)|$(grep -c "$CODE" "$CLOG")|$(printf '%s%s' "$OUT" "$ERR" | grep -c "$CODE")" "forwarded|0|0"
gw "--id hub1" "login-code claude-code $V" "$CODE
"
eq "T2: one trailing newline is stripped (the unit sees the bare code)" "$RC|$(printf '%s' "$(cat "$W/srv.log")" | python3 -I -c 'import json,sys;print(json.loads(sys.stdin.read())["code"])' 2>/dev/null)" "0|$CODE"
for r in stale vorgang_unknown unauthorized bad_code; do
  echo "{\"ok\": false, \"reason\": \"$r\"}" > "$W/srv.reply"; gw "--id hub1" "login-code claude-code $V" "$CODE"
  eq "T2: unit says '$r' => rc 77, stderr 'rejected: $r', code not echoed" "$RC|$ERR|$(printf '%s' "$OUT" | grep -c "$CODE")" "77|rejected: $r|0"
done
gw "--id mallory" "login-code claude-code $V" "$CODE"
eq "T2: an unknown peer => 77 gateway_peer_denied and the socket is never contacted" "$RC|$(wc -c < "$W/srv.log" | tr -d ' ')|$(cf ctl.rejected -1 reason)" "77|0|gateway_peer_denied"
kill "$(cat "$W/srv.pid")" 2>/dev/null; wait "$(cat "$W/srv.pid")" 2>/dev/null; rm -f "$LSOCK/login-claude-code.sock"
gw "--id hub1" "login-code claude-code $V" "$CODE"
eq "T2: no socket => rc 69 (unavailable)" "$RC" 69
hasnt "T2: …and the message does not contain the code" "$ERR" "$CODE"

# --- T3 login-code validation: 64, socket never contacted ------------------------------------------------------------------------------------------------
echo '{"ok": true}' > "$W/srv.reply"
python3 -I "$W/srv.py" "$LSOCK/login-claude-code.sock" "$W/srv.log" "$W/srv.reply" & echo $! > "$W/srv.pid"
wait_for 5 bash -c "[ -S '$LSOCK/login-claude-code.sock' ]"
bad() { # bad <label> <command> <stdin>
  gw "--id hub1" "$2" "$3"
  eq "T3: $1 => 64, socket untouched, audited gateway_malformed" "$RC|$(wc -c < "$W/srv.log" | tr -d ' ')|$(cf ctl.rejected -1 reason)" "64|0|gateway_malformed"
}
bad "a code on the command line" "login-code claude-code $V $CODE" "$CODE"
bad "no vorgang" "login-code claude-code" "$CODE"
bad "no operands" "login-code" "$CODE"
bad "a short vorgang" "login-code claude-code abc123" "$CODE"
bad "an upper-case vorgang" "login-code claude-code ${V^^}" "$CODE"
bad "a vorgang that is not hex" "login-code claude-code zzzz456789abcdef0123456789abcdef" "$CODE"
bad "a provider with a slash (socket path traversal)" "login-code ../claude-code $V" "$CODE"
bad "an upper-case provider" "login-code Claude $V" "$CODE"
bad "an empty code" "login-code claude-code $V" ""
bad "a lone newline" "login-code claude-code $V" $'\n'
bad "a space in the code" "login-code claude-code $V" "ab cd"
bad "a tab in the code" "login-code claude-code $V" $'ab\tcd'
bad "an embedded newline" "login-code claude-code $V" $'abc\ndef'
bad "two trailing newlines" "login-code claude-code $V" $'abc\n\n'
bad "a quote in the code" "login-code claude-code $V" "ab'cd"
bad "a semicolon in the code" "login-code claude-code $V" "ab;cd"
bad "a dollar sign in the code" "login-code claude-code $V" 'ab$cd'
bad "non-ASCII in the code" "login-code claude-code $V" "abcé"
bad "257 bytes of code" "login-code claude-code $V" "$(head -c 257 /dev/zero | tr '\0' a)"
gw "--id hub1" "login-code claude-code $V" "$(head -c 256 /dev/zero | tr '\0' a)"
eq "T3: exactly 256 bytes is under the cap and goes through" "$RC" 0
gw "--id hub1" "login-code claude-code $V" 'aZ09#_-'
eq "T3: the whole charset [A-Za-z0-9#_-] is accepted" "$RC" 0

printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
