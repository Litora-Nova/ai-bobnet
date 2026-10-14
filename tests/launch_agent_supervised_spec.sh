#!/usr/bin/env bash
# ai-bobnet — spec for bin/launch-agent --supervised / --session and the broker-response mapping
# (Supervisor slice S1a-2, delta round 1: the supervisor specs stop at a fake launcher, so the real
# launcher's supervised branch and lib/aib_broker_response.py need their own pins).
#
# WHAT THIS PINS (fake $AIB_BROKER_CLIENT: frame on stdin -> recorded; scripted response on stdout)
#   usage (rc 64, nothing sent to the broker):
#     --session without --supervised; --supervised without --session; repeated --supervised /
#     --session; --session with no value; a session that is not `new:<uuid>` or `<uuid>` in strict
#     lower-case canonical form (uppercase, short, `new:new:…`, `NEW:…`, trailing junk, empty);
#     the existing refusal of --sandbox danger-full-access still precedes the broker.
#   frame (exact bytes): op=launch / agent_uid / lease_class=supervised / session / sandbox / timeout /
#     cwd_bytes / label_bytes / prompt_bytes / blank line, then cwd+label+prompt; lease_class=supervised
#     appears exactly once and no unrelated field does.
#   client failure: client rc != 0 => rc 69 even when its stdout looks like success.
#   response mapping (lib/aib_broker_response.py, via the launcher):
#     chunks are relayed to stdout; end=ok + exit_class=ok => 0; exit_code=N => N (clamped to 255);
#     signal TERM/INT/HUP/KILL => 143/130/129/137 and SIGNAL-<n> => 128+n; reason=over_capacity => 75;
#     end=denied / end=error otherwise, an empty answer, a missing end line, a torn or malformed chunk,
#     a non-UTF-8 line, and an ok answer with no exit evidence => 69.
set -uo pipefail
SRC_ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
LA="$SRC_ROOT/bin/launch-agent"; MAP="$SRC_ROOT/lib/aib_broker_response.py"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-lasup.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
no(){ fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; }
eq(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2' want '$3')"; fi; }

mkdir -p "$WORK/cwd"
UU=3f2b8c1e-9d4a-4e6b-8a7c-1b2d3e4f5a6b
cat > "$WORK/client" <<'FAKE'
#!/usr/bin/env bash
w=$(cd -P "$(dirname "$0")" && pwd)
cat > "$w/frame.bin"; : >> "$w/client.calls"; echo x >> "$w/client.calls"
cat "$w/response.bin" 2>/dev/null
exit "$(cat "$w/client.rc" 2>/dev/null || echo 0)"
FAKE
chmod +x "$WORK/client"
reset() { rm -f "$WORK/frame.bin" "$WORK/client.calls" "$WORK/client.rc" "$WORK/response.bin"; }
# run <launch-agent args...> -> RC, OUT (stdout)
run() { RC=0; OUT="$(env -i PATH="$PATH" HOME="$WORK" AIB_BROKER_CLIENT="$WORK/client" "$LA" "$@" 2>"$WORK/stderr")" || RC=$?; }
calls() { [ -f "$WORK/client.calls" ] && wc -l < "$WORK/client.calls" | tr -d ' ' || echo 0; }
base=(--as acme-core --cwd "$WORK/cwd" --prompt hi)

# --- usage ----------------------------------------------------------------------
reset; run "${base[@]}" --session "$UU"
eq "--session without --supervised => 64" "$RC" 64
reset; run "${base[@]}" --supervised
eq "--supervised without --session => 64" "$RC" 64
reset; run "${base[@]}" --supervised --supervised --session "$UU"
eq "repeated --supervised => 64" "$RC" 64
reset; run "${base[@]}" --supervised --session "$UU" --session "$UU"
eq "repeated --session => 64" "$RC" 64
reset; run "${base[@]}" --supervised --session
eq "--session with no value => 64" "$RC" 64
for bad in "" "${UU^^}" "new:${UU^^}" "NEW:$UU" "new:new:$UU" "new:" "${UU:0:35}" "$UU " "$UU-x" "${UU//-/}" "../$UU" "new: $UU"; do
  reset; run "${base[@]}" --supervised --session "$bad"
  eq "non-canonical session '${bad:0:44}' => 64" "$RC|$(calls)" "64|0"
done
reset; run --as acme-core --cwd "$WORK/cwd" --prompt hi --sandbox danger-full-access --supervised --session "$UU"
eq "danger-full-access is refused before the broker" "$RC|$(calls)" "64|0"
for ok_s in "$UU" "new:$UU"; do
  reset; printf 'end=ok\nexit_class=ok\n' > "$WORK/response.bin"; run "${base[@]}" --supervised --session "$ok_s"
  eq "session '${ok_s:0:12}…' is accepted and reaches the broker once" "$RC|$(calls)" "0|1"
done

# --- the frame -----------------------------------------------------------------
reset; printf 'end=ok\nexit_class=ok\n' > "$WORK/response.bin"
run --as acme-core --cwd "$WORK/cwd" --label lbl --timeout 77 --sandbox workspace-write --prompt "hello" --supervised --session "new:$UU"
want="$(printf 'op=launch\nagent_uid=acme-core\nlease_class=supervised\nsession=new:%s\nsandbox=workspace-write\ntimeout=77\ncwd_bytes=%s\nlabel_bytes=3\nprompt_bytes=5\n\n%s%slblhello' "$UU" "$(printf %s "$WORK/cwd" | wc -c | tr -d ' ')" "$WORK/cwd" "")"
eq "the frame bytes are exactly the supervised launch request" "$(cat "$WORK/frame.bin"; echo .)" "$want."
eq "lease_class=supervised appears exactly once" "$(grep -c '^lease_class=supervised$' "$WORK/frame.bin")" 1
eq "stdin prompt (-) is framed the same way" "$(printf 'from stdin' | env -i PATH="$PATH" HOME="$WORK" AIB_BROKER_CLIENT="$WORK/client" "$LA" --as acme-core --cwd "$WORK/cwd" --supervised --session "$UU" - >/dev/null 2>&1; grep -c '^prompt_bytes=10$' "$WORK/frame.bin")" 1

# --- client failure -------------------------------------------------------------
reset; printf 'end=ok\nexit_class=ok\n' > "$WORK/response.bin"; echo 3 > "$WORK/client.rc"
run "${base[@]}" --supervised --session "$UU"
eq "client rc != 0 => 69 even if its answer looks like success" "$RC" 69
reset; RC=0; env -i PATH="$PATH" HOME="$WORK" AIB_BROKER_CLIENT="" "$LA" "${base[@]}" --supervised --session "$UU" >/dev/null 2>&1 || RC=$?
eq "an empty AIB_BROKER_CLIENT => 69" "$RC" 69

# --- response mapping ------------------------------------------------------------
resp() { # resp <name> <expected rc> <printf-format> [args…]  (also checked straight against the mapper)
  local name="$1" want="$2" f="$3"; shift 3
  reset; printf "$f" "$@" > "$WORK/response.bin"
  run "${base[@]}" --supervised --session "$UU"
  eq "response: $name => rc $want" "$RC" "$want"
  local m=0; python3 -I "$MAP" "$WORK/response.bin" >/dev/null 2>&1 || m=$?
  eq "mapper (direct): $name => rc $want" "$m" "$want"
}
resp "ok / exit_class ok" 0 'end=ok\nexit_class=ok\n'
resp "exit_code 3" 3 'exit_class=failed\nexit_code=3\nend=ok\n'
resp "exit_code 300 clamps to 255" 255 'exit_class=failed\nexit_code=300\nend=ok\n'
resp "signal TERM" 143 'exit_class=aborted\nsignal=TERM\nend=ok\n'
resp "signal INT" 130 'exit_class=aborted\nsignal=INT\nend=ok\n'
resp "signal HUP" 129 'exit_class=aborted\nsignal=HUP\nend=ok\n'
resp "signal KILL" 137 'exit_class=aborted\nsignal=KILL\nend=ok\n'
resp "signal SIGNAL-9" 137 'exit_class=aborted\nsignal=SIGNAL-9\nend=ok\n'
resp "over_capacity" 75 'reason=over_capacity\nend=error\n'
resp "denied" 69 'reason=unknown_agent\nend=denied\n'
resp "error" 69 'reason=registry_unavailable\nend=error\n'
resp "empty answer (silent connection close)" 69 ''
resp "no end line" 69 'exit_class=ok\n'
resp "ok with no exit evidence" 69 'end=ok\n'
resp "torn chunk (short payload)" 69 'chunk_bytes=50\n\nshort\nend=ok\nexit_class=ok\n'
resp "malformed chunk size" 69 'chunk_bytes=abc\n\nx\nend=ok\nexit_class=ok\n'
resp "chunk header without blank line" 69 'chunk_bytes=2\nxx\nend=ok\nexit_class=ok\n'
resp "non-UTF-8 line" 69 '\377\376\nend=ok\nexit_class=ok\n'
reset; printf 'chunk_bytes=11\n\nhello world\nchunk_bytes=0\n\nexit_class=ok\nend=ok\n' > "$WORK/response.bin"
run "${base[@]}" --supervised --session "$UU"
eq "chunks are relayed to stdout verbatim" "$RC|$OUT" "0|hello world"
rc=0; python3 -I "$MAP" >/dev/null 2>&1 || rc=$?
eq "mapper with no argument => 69" "$rc" 69
rc=0; python3 -I "$MAP" "$WORK/does-not-exist" >/dev/null 2>&1 || rc=$?
eq "mapper with an unreadable file => 69" "$rc" 69

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
