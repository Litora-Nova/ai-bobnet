#!/usr/bin/env bash
# ai-bobnet — RED spec for the single credential refresher (Supervisor slice S1c; design v3.1 H1, v3.2 J2/J3, spike S1c-0).
#
# WHAT THIS PINS
#   bin/aib-login-refresh <provider>       one-shot; the ExecStart of aib-login-refresh@<provider>.service (User=aib-broker), fired by
#                                          aib-login-refresh@<provider>.timer. It is the ONLY process that ever refreshes a credential.
#   bin/aib-login-refresh --cadence <p>    prints the timer cadence in seconds: an integer strictly below AIB_LOGIN_ACCESS_LIFETIME_S / 2.
#   Due rule: the access token's remaining validity <= THRESHOLD, where THRESHOLD = AIB_LOGIN_REFRESH_BELOW_S if set, else
#       cadence + AIB_LOGIN_MAX_TURN_S + AIB_LOGIN_MARGIN_S + AIB_LOGIN_SLACK_S
#   (so a child that starts right after a tick still has timeout + the CLI's own margin + slack of validity left: it never reaches a
#   refresh). Remaining validity = Claude `claudeAiOauth.expiresAt` (ms) / Codex JWT `exp` of tokens.access_token, minus AIB_LOGIN_NOW.
#   Not due => rc 0, the CLI is NOT called, the store is untouched.
#   Due =>   the refresher copies the provider dir to a PRIVATE temp dir (mode 0700, removed afterwards), runs the wrapped CLI's own refresh
#            code against it (claude: `-p` ping with CLAUDE_CONFIG_DIR=<private>, no --resume/--session-id; codex: exactly
#            `features list` with CODEX_HOME=<private>; nothing else), and publishes the result with tmp + rename in the store dir:
#              - the credential file is a NEW inode (a holder of the old fd still reads the OLD content — also for Codex, whose CLI writes in place),
#              - mode 0640 (Claude's CLI writes 0600; the refresher fixes it), the directory keeps its mode, no stray files are left,
#              - the refresh token inside is whatever the CLI wrote (the refresher never edits token content).
#   Failure (CLI rc != 0, or the credential is unchanged after the call) => rc 1, the store is byte-identical, the private dir is gone.
#   Absent credential => rc 66, no CLI call. A SYMLINKED credential file in the store => rc 78 (the store holds regular files), no CLI call.
#   Token hygiene: stdout/stderr never contain a token. The CLI is only ever called by this tool with the store as input — no spec here
#   can show uid-per-call on a sandbox, so `uid=` of every CLI call is logged by the fake and asserted to be our (single) uid.
#   Units (text pins): deploy/systemd/aib-login-refresh@.service  — Type=oneshot, User=aib-broker, ExecStart=/…/bin/aib-login-refresh %i,
#   OnFailure=aib-alarm@%n.service, no credential-looking Environment=; deploy/systemd/aib-login-refresh@.timer — OnUnitActiveSec equal to the
#   tool's default --cadence, [Install] WantedBy=timers.target.
#
#   Expected on the unbuilt tree: bin/aib-login-refresh and the units do not exist.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/fixtures/login_harness.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-lrefresh.XXXXXX")"
trap sup_cleanup EXIT
lw_world r
REF="$ENGINE/bin/aib-login-refresh"
cat > "$W/fakes/claude" <<'FAKE'
#!/usr/bin/env bash
w=$(cd -P "$(dirname "$0")/.." && pwd); now=$(cat "$w/cli.now")
printf 'provider=claude uid=%s argv=%s cfg=%s\n' "$(id -u)" "$*" "${CLAUDE_CONFIG_DIR:-}" >> "$w/cli.log"
[ "$(cat "$w/cli.mode" 2>/dev/null)" != fail ] || { echo "refresh failed" >&2; exit 1; }
[ "$(cat "$w/cli.mode" 2>/dev/null)" != noop ] || exit 0
c="$CLAUDE_CONFIG_DIR/.credentials.json"
python3 -I - "$c" "$now" <<'PY'
import json, os, sys
p, now = sys.argv[1], int(sys.argv[2]); d = json.load(open(p)); o = d["claudeAiOauth"]
o["accessToken"] = "at-NEW-" + str(now); o["refreshToken"] = "rt-NEW-" + str(now); o["expiresAt"] = (now + 3600) * 1000
t = p + ".tmp"; open(t, "w").write(json.dumps(d)); os.chmod(t, 0o600); os.rename(t, p)      # tmp + rename, 0600, like the CLI
PY
FAKE
cat > "$W/fakes/codex" <<'FAKE'
#!/usr/bin/env bash
w=$(cd -P "$(dirname "$0")/.." && pwd); now=$(cat "$w/cli.now")
printf 'provider=codex uid=%s argv=%s cfg=%s\n' "$(id -u)" "$*" "${CODEX_HOME:-}" >> "$w/cli.log"
[ "$(cat "$w/cli.mode" 2>/dev/null)" != fail ] || { echo "refresh failed" >&2; exit 1; }
[ "$(cat "$w/cli.mode" 2>/dev/null)" != noop ] || exit 0
python3 -I - "$CODEX_HOME/auth.json" "$now" <<'PY'
import base64, json, sys
p, now = sys.argv[1], int(sys.argv[2]); d = json.load(open(p))
b = lambda x: base64.urlsafe_b64encode(json.dumps(x).encode()).rstrip(b"=").decode()
d["tokens"]["access_token"] = b({"alg": "none"}) + "." + b({"exp": now + 3600}) + ".sigNEW"; d["tokens"]["refresh_token"] = "rt-NEW"
open(p, "w").write(json.dumps(d))                                                           # IN PLACE (truncate + write), like the CLI
PY
FAKE
chmod +x "$W/fakes/claude" "$W/fakes/codex"
echo "$LNOW" > "$W/cli.now"
LENV+=(AIB_CLAUDE_BIN="$W/fakes/claude" AIB_CODEX_BIN="$W/fakes/codex")
clog() { cat "$W/cli.log" 2>/dev/null; }
reset() { : > "$W/cli.log"; rm -f "$W/cli.mode"; }

# --- T1 cadence is a parameter and stays under half the access-token lifetime ----------------------------------------------------
lrun -- "$REF" --cadence claude-code; C="$OUT"
case "$C" in ''|*[!0-9]*) no "T1: --cadence prints an integer (got '$C', rc $RC)";; *) if [ "$C" -gt 0 ] && [ "$C" -lt 1800 ]; then ok "T1: cadence $C s is below half the access lifetime (3600/2)"; else no "T1: cadence $C s is below 1800"; fi;; esac
lrun AIB_LOGIN_ACCESS_LIFETIME_S=600 -- "$REF" --cadence claude-code
case "$OUT" in ''|*[!0-9]*) no "T1: cadence follows the lifetime parameter (got '$OUT')";; *) if [ "$OUT" -lt 300 ]; then ok "T1: …and shrinks with AIB_LOGIN_ACCESS_LIFETIME_S=600 (<300)"; else no "T1: cadence for 600 s lifetime is <300 (got $OUT)"; fi;; esac
THR=$(( C + 900 + 300 + 600 ))

# --- T2 the due boundary (claude): remaining == threshold refreshes, +1 does not -----------------------------------------------------
reset; mk_claude $(( LNOW + THR + 1 )); before="$(cat "$LROOT/claude-code/.credentials.json")"
lrun -- "$REF" claude-code
eq "T2: remaining = threshold+1 => rc 0, no CLI call, store untouched" "$RC|$(clog | wc -l | tr -d ' ')|$([ "$before" = "$(cat "$LROOT/claude-code/.credentials.json")" ] && echo same)" "0|0|same"
mk_claude $(( LNOW + THR ))
lrun -- "$REF" claude-code
eq "T2: remaining = threshold => refreshes (exactly one CLI call)" "$RC|$(clog | wc -l | tr -d ' ')" "0|1"
mk_claude $(( LNOW + 10 )); reset
lrun AIB_LOGIN_REFRESH_BELOW_S=5 -- "$REF" claude-code
eq "T2: AIB_LOGIN_REFRESH_BELOW_S overrides the derived threshold (10 s left > 5 => not due)" "$RC|$(clog | wc -l | tr -d ' ')" "0|0"

# --- T3 what the claude refresh does to the store ----------------------------------------------------------------------------------
reset; mk_claude $(( LNOW + 100 )); f="$LROOT/claude-code/.credentials.json"; ino="$(stat -c %i "$f")"
exec 7< "$f"
lrun -- "$REF" claude-code
old="$(cat <&7)"; exec 7<&-
has "T3: a holder of the old fd still reads the OLD token (atomic replace, not in-place)" "$old" "at-$SENT"
hasnt "T3: …while the store now holds the CLI's new access token" "$(cat "$f")" "at-$SENT"
has "T3: …the CLI's new token" "$(cat "$f")" "at-NEW-$LNOW"
eq "T3: new inode, mode 0640 (CLI wrote 0600), directory mode unchanged (750)" "$([ "$(stat -c %i "$f")" != "$ino" ] && echo new)|$(mode_of "$f")|$(mode_of "$LROOT/claude-code")" "new|640|750"
eq "T3: no stray files in the store dir" "$(ls -A "$LROOT/claude-code" | tr '\n' ' ')" ".credentials.json "
log="$(clog)"
has "T3: the ping is a -p run" "$log" "argv=-p"
hasnt "T3: …never a resume or a named session" "$log" "--resume"
hasnt "T3: …nor --session-id" "$log" "--session-id"
cfg="$(printf '%s' "$log" | sed 's/.* cfg=//' | head -1)"
eq "T3: the CLI ran against a PRIVATE copy, not the store, and the copy is gone" "$([ -n "$cfg" ] && [ "$cfg" != "$LROOT/claude-code" ] && echo private)|$([ ! -e "$cfg" ] && echo removed)" "private|removed"
eq "T3: every CLI call ran as our (single) uid" "$(printf '%s' "$log" | grep -o 'uid=[0-9]*' | sort -u | tr '\n' ' ')" "uid=$ME_UID "
eq "T3: no token on stdout/stderr" "$(printf '%s%s' "$OUT" "$ERR" | grep -c -e "$SENT" -e NEW)" 0

# --- T4 codex: the CLI writes IN PLACE, the store still gets an atomic replace ------------------------------------------------------
reset; mk_codex $(( LNOW + 100 )); f="$LROOT/codex/auth.json"; ino="$(stat -c %i "$f")"
exec 7< "$f"
lrun -- "$REF" codex
old="$(cat <&7)"; exec 7<&-
has "T4: the old-fd holder still reads the OLD refresh token" "$old" "rt-$SENT"
has "T4: the store holds the new refresh token" "$(cat "$f")" "rt-NEW"
eq "T4: new inode, mode 0640, no stray files" "$([ "$(stat -c %i "$f")" != "$ino" ] && echo new)|$(mode_of "$f")|$(ls -A "$LROOT/codex" | tr '\n' ' ')" "new|640|auth.json "
log="$(clog)"
has "T4: the trigger is exactly 'features list' (one token call, no model turn)" "$log" "argv=features list cfg="
eq "T4: one call, private CODEX_HOME" "$(printf '%s' "$log" | wc -l | tr -d ' ')|$(printf '%s' "$log" | sed 's/.* cfg=//' | grep -vc "^$LROOT")" "1|1"
mk_codex $(( LNOW + THR + 1 )); reset
lrun -- "$REF" codex
eq "T4: a codex token far from expiry is not refreshed" "$RC|$(clog | wc -l | tr -d ' ')" "0|0"

# --- T5 failures leave the store byte-identical ---------------------------------------------------------------------------------------
for mode in fail noop; do
  reset; mk_claude $(( LNOW + 100 )); before="$(cat "$LROOT/claude-code/.credentials.json")"; echo "$mode" > "$W/cli.mode"
  lrun -- "$REF" claude-code
  eq "T5: CLI '$mode' => rc 1, store byte-identical, private dir removed" "$RC|$([ "$before" = "$(cat "$LROOT/claude-code/.credentials.json")" ] && echo same)|$([ ! -e "$(clog | sed 's/.* cfg=//' | head -1)" ] && echo clean)" "1|same|clean"
done
reset; rm -f "$LROOT/codex/auth.json"
lrun -- "$REF" codex
eq "T5: an absent credential => rc 66, no CLI call" "$RC|$(clog | wc -l | tr -d ' ')" "66|0"
reset; mk_claude $(( LNOW + 100 )); mv "$LROOT/claude-code/.credentials.json" "$W/real-cred"; ln -s "$W/real-cred" "$LROOT/claude-code/.credentials.json"
lrun -- "$REF" claude-code
eq "T5: a symlinked credential in the store => rc 78, no CLI call" "$RC|$(clog | wc -l | tr -d ' ')" "78|0"
lrun -- "$REF" no-such-provider
eq "T5: an unknown provider => rc 64" "$RC" 64
lrun -- "$REF"
eq "T5: no provider => rc 64" "$RC" 64

# --- T6 unit texts ---------------------------------------------------------------------------------------------------------------------------
SVC="$SRC_ROOT/deploy/systemd/aib-login-refresh@.service"; TMR="$SRC_ROOT/deploy/systemd/aib-login-refresh@.timer"
sv() { grep -v '^[[:space:]]*#' "$SVC" 2>/dev/null; }
eq "T6: service is Type=oneshot, User=aib-broker" "$(sv | grep -cx -e 'Type=oneshot' -e 'User=aib-broker')" 2
es="$(sv | grep '^ExecStart=' | head -1)"
case "$es" in ExecStart=/*/bin/aib-login-refresh\ %i) ok "T6: ExecStart= absolute path to bin/aib-login-refresh %i";; *) no "T6: ExecStart= absolute path to bin/aib-login-refresh %i (got '$es')";; esac
eq "T6: OnFailure=aib-alarm@%n.service" "$(sv | grep -c '^OnFailure=aib-alarm@%n.service$')" 1
eq "T6: no credential-looking Environment=" "$([ -f "$SVC" ] && sv | grep -ciE '^Environment=.*(TOKEN|KEY|SECRET|PASSWORD)')" 0
tv="$(grep '^OnUnitActiveSec=' "$TMR" 2>/dev/null | head -1 | cut -d= -f2)"
case "$tv" in *min) ts=$(( ${tv%min} * 60 ));; *s) ts=${tv%s};; *[!0-9]*|'') ts=x;; *) ts=$tv;; esac
lrun AIB_LOGIN_ACCESS_LIFETIME_S= -- "$REF" --cadence claude-code
eq "T6: the timer's OnUnitActiveSec equals the tool's default cadence" "$ts" "$OUT"
eq "T6: the timer is installable as WantedBy=timers.target" "$(grep -c '^WantedBy=timers.target$' "$TMR" 2>/dev/null)" 1

printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
