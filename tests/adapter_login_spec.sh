#!/usr/bin/env bash
# ai-bobnet — RED spec for the shared-login credential modes of the two provider adapters and the broker-side token tool
# (Supervisor slice S1c; design v3.1 H1/H2, v3.2 J1/J2, E9: Claude = fd hand-off from `login`, `setup_token` reserved).
#
# WHAT THIS PINS
#   Adapter inputs (env, set by the broker/launcher from the deployment config + registry — never from a request):
#     AIB_CREDENTIAL_MODE      file (default, UNCHANGED; the golden specs cover it) | fd | shared | proxy
#     AIB_TURN_TIMEOUT_S       the broker's cap for this turn (seconds)
#   Seams (gate: AIB_TEST_SEAMS=1 and no `<engine root>/.aib-installed`): AIB_LOGIN_NOW (epoch), AIB_LOGIN_MARGIN_S (300), AIB_LOGIN_SLACK_S (600).
#
#   adapters/claude-code, mode `fd` (the Claude credential mode for a subscription login; refresher + fd, no symlink — the CLI would replace it):
#     - the per-agent $HOME/.claude holds history only: NO .credentials.json is required, and the adapter never creates one;
#     - AIB_CREDENTIAL_FD (3..9) must be an open, readable, NON-EMPTY descriptor, else 78; the adapter exports
#       CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR=<that fd> to the wrapped CLI, keeps the fd open across exec, unsets CLAUDE_CODE_OAUTH_TOKEN and
#       ANTHROPIC_API_KEY, and still sets CLAUDE_CONFIG_DIR=$HOME/.claude. A bad/missing/low fd number (0,1,2, text) => 78.
#   adapters/codex, mode `shared`:
#     - $HOME/.codex is a 0700 real dir and auth.json in it is a SYMLINK whose realpath equals realpath(AIB_LOGIN_STORE_PATH); the target is a
#       regular file, owner AIB_LOGIN_STORE_OWNER (default aib-broker), group AIB_LOGIN_STORE_GROUP (default aib-login), mode exactly 0640;
#       anything else (regular file, other target, dangling, 0644/0660/0600, wrong owner/group) => 78;
#     - preflight margin: JWT `exp` of tokens.access_token must be >= now + AIB_TURN_TIMEOUT_S + MARGIN + SLACK (default 300 + 600).
#       Exactly at the floor runs; one second less => 78 (class c, the supervisor adds no brake) with `hint:login` on stderr. A missing
#       AIB_TURN_TIMEOUT_S or an unreadable/malformed JWT => 78 too (fail closed). The CLI is never started on a 78.
#   mode `proxy` is only RESERVED (S1d): 78 with "not built" on stderr, CLI not started, for both adapters. An unknown mode => 78.
#   bin/aib-login-token claude-code [--source login|setup_token]   prints the access token (and nothing else) on stdout:
#     login:       claudeAiOauth.accessToken from $AIB_LOGIN_ROOT/claude-code/.credentials.json; refuses 78 (stdout empty, `hint:login` on stderr)
#                  unless expiresAt >= now + AIB_TURN_TIMEOUT_S + MARGIN + SLACK;
#     setup_token: the plain file $AIB_LOGIN_ROOT/claude-code/setup-token (no expiry check) — the reserved E9-B seam;
#     the store file must be a regular file with mode exactly 0640 (symlink / other mode => 78); absent => 66; unknown provider/source => 64;
#     it never writes anything and never logs a token to stderr.
#   Refusal text for every new-mode 78: stderr line `<adapter> adapter: credential mode <mode>: <reason>` (the spec keys on the prefix).
#
#   Expected on the unbuilt tree: the adapters know none of the modes; bin/aib-login-token does not exist.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/fixtures/login_harness.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-adlogin.XXXXXX")"
trap sup_cleanup EXIT
lw_world a
FAKE="$W/fakes/provider"
cat > "$FAKE" <<'STUB'
#!/usr/bin/env bash
w=$(cd -P "$(dirname "$0")/.." && pwd)
{ echo started; env; } > "$w/fake.env"
tok=""; fd="${CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR:-}"
[ -z "$fd" ] || { eval "tok=\$(cat <&$fd)" 2>/dev/null; }
printf '%s' "$tok" > "$w/fake.tok"
ls -A "$HOME/.claude" > "$w/fake.claudedir" 2>/dev/null
cat > /dev/null; echo FAKE_OK
STUB
chmod +x "$FAKE"
MODEL="team/model-v2"; CWD="$W/cwd"; mkdir -p "$CWD"
CH="$W/ahome"; mkdir -p "$CH/.claude" "$CH/.codex"; chmod 700 "$CH/.claude" "$CH/.codex"
FD_TOKEN="plain-access-token-$SENT"
# run_adapter <claude-code|codex> <fd-or-""> <env...>  -> RC ERR; the fake wrote fake.env/fake.tok when it started
run_adapter() {
  local ad="$1" fd="$2"; shift 2; rm -f "$W/fake.env" "$W/fake.tok" "$W/fake.claudedir"
  CUR_MODE=""; local a; for a in "$@"; do case "$a" in AIB_CREDENTIAL_MODE=*) CUR_MODE="${a#AIB_CREDENTIAL_MODE=}";; esac; done
  local bin_env=AIB_CLAUDE_BIN; [ "$ad" = codex ] && bin_env=AIB_CODEX_BIN
  RC=0
  if [ -n "$fd" ]; then
    ( cd "$CWD" && exec 3< "$W/fd.token" && env -i HOME="$CH" PATH="$PATH" "$bin_env=$FAKE" AIB_TEST_SEAMS=1 AIB_LOGIN_NOW="$LNOW" "$@" \
        "$SRC_ROOT/adapters/$ad" exec -m "$MODEL" -s workspace-write -c 'model_reasoning_effort="high"' -c 'approval_policy="never"' -- "hi" ) >"$W/ad.out" 2>"$W/ad.err" || RC=$?
  else
    ( cd "$CWD" && env -i HOME="$CH" PATH="$PATH" "$bin_env=$FAKE" AIB_TEST_SEAMS=1 AIB_LOGIN_NOW="$LNOW" "$@" \
        "$SRC_ROOT/adapters/$ad" exec -m "$MODEL" -s workspace-write -c 'model_reasoning_effort="high"' -c 'approval_policy="never"' -- "hi" ) >"$W/ad.out" 2>"$W/ad.err" || RC=$?
  fi
  ERR="$(cat "$W/ad.err")"
}
# ran -> "ran" when the CLI started; "not-started:tagged" when it did not AND stderr says `credential mode <mode>: ...` (pinned refusal text, so a
# 78 for the old file-mode reason ("credential unavailable or unsafe") is not mistaken for the new mode's refusal); else "not-started"
ran() { if [ -f "$W/fake.env" ]; then echo ran; elif grep -q "^[a-z-]* adapter: credential mode ${CUR_MODE:-}:" "$W/ad.err" 2>/dev/null; then echo not-started:tagged; else echo not-started; fi; }
ran0() { [ -f "$W/fake.env" ] && echo ran || echo not-started; }
envof() { grep -m1 "^$1=" "$W/fake.env" 2>/dev/null | cut -d= -f2-; }

# --- T1 claude-code, mode fd --------------------------------------------------------------------------------------------------------------------------
rm -f "$CH/.claude/.credentials.json"; printf '%s' "$FD_TOKEN" > "$W/fd.token"
run_adapter claude-code 3 AIB_CREDENTIAL_MODE=fd AIB_CREDENTIAL_FD=3 AIB_TURN_TIMEOUT_S=900
eq "T1: fd mode with NO credential file in the agent dir runs the CLI" "$RC|$(ran)" "0|ran"
eq "T1: …the CLI gets CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR=3 and can read the token from that fd" "$(envof CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR)|$(cat "$W/fake.tok" 2>/dev/null)" "3|$FD_TOKEN"
eq "T1: …no CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_API_KEY in its env, CLAUDE_CONFIG_DIR is the agent's history dir" "$(grep -cE '^(CLAUDE_CODE_OAUTH_TOKEN|ANTHROPIC_API_KEY)=' "$W/fake.env" 2>/dev/null)|$(envof CLAUDE_CONFIG_DIR)" "0|$CH/.claude"
eq "T1: …and the adapter never created a credential file" "$([ -z "$(ls -A "$CH/.claude")" ] && echo empty)" empty
eq "T1: the token is not in the adapter's own output" "$(grep -c "$SENT" "$W/ad.out" "$W/ad.err" | grep -vc ':0$')" 0
run_adapter claude-code 3 AIB_CREDENTIAL_MODE=fd AIB_CREDENTIAL_FD=5 AIB_TURN_TIMEOUT_S=900
eq "T1: AIB_CREDENTIAL_FD names a closed descriptor (5) => 78, CLI not started" "$RC|$(ran)" "78|not-started:tagged"
for bad in 0 1 2 x '' 10 -1 '3 4'; do
  run_adapter claude-code 3 AIB_CREDENTIAL_MODE=fd AIB_CREDENTIAL_FD="$bad" AIB_TURN_TIMEOUT_S=900
  eq "T1: AIB_CREDENTIAL_FD='$bad' => 78, CLI not started" "$RC|$(ran)" "78|not-started:tagged"
done
: > "$W/fd.token"; run_adapter claude-code 3 AIB_CREDENTIAL_MODE=fd AIB_CREDENTIAL_FD=3 AIB_TURN_TIMEOUT_S=900
eq "T1: an empty token on the fd => 78" "$RC|$(ran)" "78|not-started:tagged"
printf '%s' "$FD_TOKEN" > "$W/fd.token"
run_adapter claude-code "" AIB_CREDENTIAL_MODE=fd AIB_CREDENTIAL_FD=3 AIB_TURN_TIMEOUT_S=900
eq "T1: no fd handed over at all => 78" "$RC|$(ran)" "78|not-started:tagged"
printf '{"key":"x"}' > "$CH/.claude/.credentials.json"; chmod 600 "$CH/.claude/.credentials.json"
run_adapter claude-code "" AIB_CREDENTIAL_MODE=file
eq "T1: guard — mode 'file' with a normal 0600 credential still runs exactly as before" "$RC|$(ran)" "0|ran"
run_adapter claude-code "" 
eq "T1: guard — an unset mode is 'file'" "$RC|$(ran)" "0|ran"
rm -f "$CH/.claude/.credentials.json"
run_adapter claude-code "" AIB_CREDENTIAL_MODE=file
eq "T1: guard — mode 'file' without a credential still refuses 78" "$RC|$(ran0)" "78|not-started"

# --- T2 reserved / unknown modes ---------------------------------------------------------------------------------------------------------------------------
printf '{"key":"x"}' > "$CH/.claude/.credentials.json"; chmod 600 "$CH/.claude/.credentials.json"
printf '{"key":"x"}' > "$CH/.codex/auth.json"; chmod 600 "$CH/.codex/auth.json"
for ad in claude-code codex; do
  run_adapter $ad "" AIB_CREDENTIAL_MODE=proxy AIB_TURN_TIMEOUT_S=900
  eq "T2: $ad mode proxy => 78 'not built', CLI not started" "$RC|$(ran)|$(printf '%s' "$ERR" | grep -c 'not built')" "78|not-started:tagged|1"
  run_adapter $ad "" AIB_CREDENTIAL_MODE=banana AIB_TURN_TIMEOUT_S=900
  eq "T2: $ad unknown mode => 78, CLI not started" "$RC|$(ran)" "78|not-started:tagged"
done
rm -f "$CH/.claude/.credentials.json" "$CH/.codex/auth.json"

# --- T3 codex, mode shared ---------------------------------------------------------------------------------------------------------------------------------
ST="$LROOT/codex/auth.json"; ME="$(id -un)"; MG="$(id -gn)"
shared() { # shared <extra env...> — runs the adapter in shared mode with the proper store and expectations
  run_adapter codex "" AIB_CREDENTIAL_MODE=shared AIB_LOGIN_STORE_PATH="$ST" AIB_LOGIN_STORE_OWNER="$ME" AIB_LOGIN_STORE_GROUP="$MG" AIB_TURN_TIMEOUT_S=900 "$@"
}
link() { rm -f "$CH/.codex/auth.json"; ln -s "$ST" "$CH/.codex/auth.json"; }
FLOOR=$(( 900 + 300 + 600 ))
mk_codex $(( LNOW + FLOOR )); link
shared; eq "T3: symlink to the store, exp exactly at timeout+300+600 => runs" "$RC|$(ran)" "0|ran"
mk_codex $(( LNOW + FLOOR - 1 )); link
shared; eq "T3: one second short of the floor => 78, CLI not started" "$RC|$(ran)" "78|not-started:tagged"
has "T3: …stderr carries the login hint (the supervisor reads it)" "$ERR" "hint:login"
mk_codex $(( LNOW + FLOOR - 1 )); link
shared AIB_LOGIN_SLACK_S=0 AIB_LOGIN_MARGIN_S=0; eq "T3: margin and slack are parameters (0/0 => the same token is fine)" "$RC|$(ran)" "0|ran"
mk_codex $(( LNOW + 100000 )); link
shared AIB_TURN_TIMEOUT_S=; eq "T3: no turn timeout from the broker => 78 (fail closed)" "$RC|$(ran)" "78|not-started:tagged"
shared AIB_TEST_SEAMS=1 AIB_LOGIN_NOW=$(( LNOW + 200000 )); eq "T3: an expired token (clock moved past exp) => 78" "$RC|$(ran)" "78|not-started:tagged"
mkdir -p "$W/eng"; cp -R "$SRC_ROOT/adapters" "$W/eng/"; : > "$W/eng/.aib-installed"
RC=0; ( cd "$CWD" && env -i HOME="$CH" PATH="$PATH" AIB_CODEX_BIN="$FAKE" AIB_TEST_SEAMS=1 AIB_LOGIN_NOW=$(( LNOW + 200000 )) AIB_CREDENTIAL_MODE=shared AIB_LOGIN_STORE_PATH="$ST" \
    AIB_LOGIN_STORE_OWNER="$ME" AIB_LOGIN_STORE_GROUP="$MG" AIB_TURN_TIMEOUT_S=900 rm -f "$W/fake.env"; true ) >/dev/null 2>&1
rm -f "$W/fake.env"; ( cd "$CWD" && env -i HOME="$CH" PATH="$PATH" AIB_CODEX_BIN="$FAKE" AIB_TEST_SEAMS=1 AIB_LOGIN_NOW=$(( LNOW + 200000 )) AIB_CREDENTIAL_MODE=shared AIB_LOGIN_STORE_PATH="$ST" \
    AIB_LOGIN_STORE_OWNER="$ME" AIB_LOGIN_STORE_GROUP="$MG" AIB_TURN_TIMEOUT_S=900 "$W/eng/adapters/codex" exec -m "$MODEL" -s workspace-write \
    -c 'model_reasoning_effort="high"' -c 'approval_policy="never"' -- hi ) >/dev/null 2>&1; rc=$?
eq "T3: on an INSTALLED engine (.aib-installed) the AIB_LOGIN_NOW seam is ignored: the real clock sees a valid token" "$rc|$(ran)" "0|ran"
mk_codex $(( LNOW + 100000 ))
rm -f "$CH/.codex/auth.json"; cp "$ST" "$CH/.codex/auth.json"; chmod 600 "$CH/.codex/auth.json"
shared; eq "T3: a regular file in the agent dir (not a symlink) => 78" "$RC|$(ran)" "78|not-started:tagged"
mk_codex $(( LNOW + 100000 )); mv "$ST" "$ST.other"; ln -sf "$ST.other" "$CH/.codex/auth.json"
shared; eq "T3: a symlink to some OTHER path => 78" "$RC|$(ran)" "78|not-started:tagged"
rm -f "$ST.other"; link
shared; eq "T3: a dangling symlink => 78" "$RC|$(ran)" "78|not-started:tagged"
for m in 644 660 600 400 666; do
  mk_codex $(( LNOW + 100000 )); link; chmod $m "$ST"
  shared; eq "T3: store mode $m (not exactly 0640) => 78" "$RC|$(ran)" "78|not-started:tagged"
done
mk_codex $(( LNOW + 100000 )); link
shared AIB_LOGIN_STORE_OWNER=nobody-else; eq "T3: store owner is not the expected broker account => 78" "$RC|$(ran)" "78|not-started:tagged"
shared AIB_LOGIN_STORE_GROUP=nogroup-else; eq "T3: store group is not the expected login group => 78" "$RC|$(ran)" "78|not-started:tagged"
chmod 755 "$CH/.codex"; shared; eq "T3: the agent's .codex dir not 0700 => 78" "$RC|$(ran)" "78|not-started:tagged"; chmod 700 "$CH/.codex"
printf '{"tokens":{"access_token":"not-a-jwt","refresh_token":"x"}}' > "$ST"; chmod 640 "$ST"
shared; eq "T3: a malformed JWT => 78" "$RC|$(ran)" "78|not-started:tagged"
rm -f "$CH/.codex/auth.json"

# --- T4 bin/aib-login-token ---------------------------------------------------------------------------------------------------------------------------------
TOK="$ENGINE/bin/aib-login-token"
FLOORC=$(( 900 + 300 + 600 ))
mk_claude $(( LNOW + FLOORC )); lrun AIB_TURN_TIMEOUT_S=900 -- "$TOK" claude-code
eq "T4: login source prints exactly the access token (floor reached)" "$RC|$OUT" "0|at-$SENT"
eq "T4: …nothing on stderr" "$([ -z "$ERR" ] && echo empty)" empty
mk_claude $(( LNOW + FLOORC - 1 )); lrun AIB_TURN_TIMEOUT_S=900 -- "$TOK" claude-code
eq "T4: a second short of the floor => 78, stdout empty, hint:login on stderr" "$RC|$OUT|$(printf '%s' "$ERR" | grep -c 'hint:login')" "78||1"
mk_claude $(( LNOW + 100000 )); lrun -- "$TOK" claude-code
eq "T4: no turn timeout => 78 (fail closed)" "$RC|$OUT" "78|"
printf '%s' "setup-$SENT" > "$LROOT/claude-code/setup-token"; chmod 640 "$LROOT/claude-code/setup-token"
lrun AIB_TURN_TIMEOUT_S=900 -- "$TOK" claude-code --source setup_token
eq "T4: setup_token source (reserved seam) prints the plain file" "$RC|$OUT" "0|setup-$SENT"
rm -f "$LROOT/claude-code/setup-token"; lrun AIB_TURN_TIMEOUT_S=900 -- "$TOK" claude-code --source setup_token
eq "T4: …absent => 66" "$RC|$OUT" "66|"
lrun AIB_TURN_TIMEOUT_S=900 -- "$TOK" claude-code --source banana; eq "T4: unknown source => 64" "$RC" 64
lrun AIB_TURN_TIMEOUT_S=900 -- "$TOK" nope; eq "T4: unknown provider => 64" "$RC" 64
chmod 644 "$LROOT/claude-code/.credentials.json"; lrun AIB_TURN_TIMEOUT_S=900 -- "$TOK" claude-code
eq "T4: store file mode 0644 => 78" "$RC|$OUT" "78|"
chmod 640 "$LROOT/claude-code/.credentials.json"; mv "$LROOT/claude-code/.credentials.json" "$W/elsewhere"; ln -s "$W/elsewhere" "$LROOT/claude-code/.credentials.json"
lrun AIB_TURN_TIMEOUT_S=900 -- "$TOK" claude-code; eq "T4: a symlinked store file => 78" "$RC|$OUT" "78|"
rm -f "$LROOT/claude-code/.credentials.json"; lrun AIB_TURN_TIMEOUT_S=900 -- "$TOK" claude-code; eq "T4: no credential => 66" "$RC|$OUT" "66|"

# =====================================================================================================================================
# Gate round 1 delta (v3.4): K5 (the fd is checked by stat, not by access()), Marvin G3 (stdio descriptors), Riker M8 (owner of the store file)
# =====================================================================================================================================

# --- T5 (K5) the descriptor, not the path, carries the right to read ---------------------------------------------------------------------------
# The broker's buffer is a 0600 file owned by aib-broker; the role account has no access to the PATH, only the inherited descriptor. `-r` on
# /proc/self/fd/N is access(R_OK) on the inode and refuses it. Mode 000 reproduces that for any non-root user.
printf '%s' "$FD_TOKEN" > "$W/fd.nopath"
rm -f "$W/fake.env" "$W/fake.tok"; RC=0
( cd "$CWD" && exec 3< "$W/fd.nopath" && chmod 000 "$W/fd.nopath" && env -i HOME="$CH" PATH="$PATH" AIB_CLAUDE_BIN="$FAKE" AIB_TEST_SEAMS=1 AIB_LOGIN_NOW="$LNOW" \
    AIB_CREDENTIAL_MODE=fd AIB_CREDENTIAL_FD=3 AIB_TURN_TIMEOUT_S=900 \
    "$SRC_ROOT/adapters/claude-code" exec -m "$MODEL" -s workspace-write -c 'model_reasoning_effort="high"' -c 'approval_policy="never"' -- "hi" ) >"$W/ad.out" 2>"$W/ad.err" || RC=$?
if [ "$(id -u)" -eq 0 ]; then
  printf 'ok   - (skipped: running as root - root passes access(R_OK) on a mode-000 file, so the mode-000 case cannot show the bug here; the cross-uid case below is the root-side proof)\n'
else
  eq "T5: fd mode with the buffer at mode 000 (path unreadable, descriptor open) => the CLI runs and reads the token from the fd" "$RC|$([ -f "$W/fake.env" ] && echo ran)|$(cat "$W/fake.tok" 2>/dev/null)" "0|ran|$FD_TOKEN"
fi
chmod 600 "$W/fd.nopath" 2>/dev/null

# stdio descriptors are never a credential channel, even when they are open and non-empty (Marvin G3)
ADARGS=(exec -m "$MODEL" -s workspace-write -c 'model_reasoning_effort="high"' -c 'approval_policy="never"' -- "hi")
for stdio in 0 1 2; do
  printf '%s' "$FD_TOKEN" > "$W/fd.stdio"; rm -f "$W/fake.env" "$W/fake.tok"; RC=0
  AD=( env -i HOME="$CH" PATH="$PATH" AIB_CLAUDE_BIN="$FAKE" AIB_TEST_SEAMS=1 AIB_LOGIN_NOW="$LNOW" AIB_CREDENTIAL_MODE=fd AIB_CREDENTIAL_FD="$stdio" AIB_TURN_TIMEOUT_S=900 "$SRC_ROOT/adapters/claude-code" "${ADARGS[@]}" )
  case "$stdio" in
    0) ( cd "$CWD" && "${AD[@]}" ) <"$W/fd.stdio" >"$W/ad.out" 2>"$W/ad.err" || RC=$?;;
    1) ( cd "$CWD" && "${AD[@]}" ) 1<>"$W/fd.stdio" 2>"$W/ad.err" || RC=$?;;
    2) ( cd "$CWD" && "${AD[@]}" ) >"$W/ad.out" 2<>"$W/fd.stdio" || RC=$?;;
  esac
  eq "T5: AIB_CREDENTIAL_FD=$stdio with that stdio descriptor open and NON-empty => 78, CLI not started" "$RC|$([ -f "$W/fake.env" ] && echo ran || echo not-started)" "78|not-started"
done

# VM-only cross-uid proof (needs root; skipped elsewhere): the role account cannot open the path, but inherits the descriptor
if [ "$(id -u)" -ne 0 ] || ! command -v setpriv >/dev/null 2>&1; then
  printf 'ok   - (skipped: needs root and setpriv - the cross-uid hand-off is proven on the VM, the mode-000 case above is the non-root proxy)\n'
else
  RU=64231; chmod -R a+rX "$W" "$WORK" 2>/dev/null; mkdir -p "$W/xhome/.claude"; chown -R $RU:$RU "$W/xhome"; chmod 700 "$W/xhome/.claude"
  printf '%s' "$FD_TOKEN" > "$W/fd.x"; chown 0:0 "$W/fd.x"; chmod 600 "$W/fd.x"; chmod a+rx "$W/fakes" "$FAKE"; rm -f "$W/fake.env" "$W/fake.tok"; RC=0
  ( cd "$CWD" && exec 3< "$W/fd.x" && exec setpriv --reuid=$RU --regid=$RU --clear-groups env -i HOME="$W/xhome" PATH="$PATH" AIB_CLAUDE_BIN="$FAKE" AIB_TEST_SEAMS=1 AIB_LOGIN_NOW="$LNOW" \
      AIB_CREDENTIAL_MODE=fd AIB_CREDENTIAL_FD=3 AIB_TURN_TIMEOUT_S=900 "$SRC_ROOT/adapters/claude-code" exec -m "$MODEL" -s workspace-write -- "hi" ) >"$W/ad.out" 2>"$W/ad.err" || RC=$?
  eq "T5 (VM, root): a different uid, root-owned 0600 buffer, only the inherited fd => the CLI runs and reads the token" "$RC|$([ -f "$W/fake.env" ] && echo ran)|$(cat "$W/fake.tok" 2>/dev/null)" "0|ran|$FD_TOKEN"
fi

# --- T6 (M8) the store file must belong to the account that owns the store ---------------------------------------------------------------------
# The store directory is group-writable by the role accounts; whatever 0640 file is found there is handed to every agent. The token tool therefore
# requires the file's owner (default: its own effective uid; seam AIB_LOGIN_STORE_OWNER, the same name the codex adapter uses) and, when
# AIB_LOGIN_STORE_GROUP is given, its group.
mk_claude $(( LNOW + FLOORC )); other_user="$(getent passwd 0 | cut -d: -f1)"; [ "$(id -u)" -ne 0 ] || other_user="nobody"
lrun AIB_TURN_TIMEOUT_S=900 -- "$TOK" claude-code
eq "T6: guard — the file owned by the tool's own uid is served" "$RC|$OUT" "0|at-$SENT"
lrun AIB_TURN_TIMEOUT_S=900 AIB_LOGIN_STORE_OWNER="$other_user" -- "$TOK" claude-code
eq "T6: a store file owned by someone else than the expected owner => 78, nothing on stdout" "$RC|$OUT" "78|"
lrun AIB_TURN_TIMEOUT_S=900 AIB_LOGIN_STORE_OWNER="$(id -un)" AIB_LOGIN_STORE_GROUP="no-such-group-$$" -- "$TOK" claude-code
eq "T6: …nor a store file in the wrong group" "$RC|$OUT" "78|"
if [ "$(id -u)" -eq 0 ]; then
  chown 64299:64299 "$LROOT/claude-code/.credentials.json"; lrun AIB_TURN_TIMEOUT_S=900 -- "$TOK" claude-code
  eq "T6 (VM, root): a file owned by an arbitrary uid is refused by default (st_uid != geteuid())" "$RC|$OUT" "78|"
else
  printf 'ok   - (skipped: not root - the arbitrary-uid case needs chown; the seam-based cases above pin the same check)\n'
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
