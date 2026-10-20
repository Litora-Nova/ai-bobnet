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
#   Failure (CLI rc != 0) => rc 1; "credential unchanged" is rc 0 + a log line (v3.4 K2), the store is byte-identical, the private dir is gone.
#   Absent credential => rc 0 + a log line (v3.4 K2/K8; was 66), no CLI call. A SYMLINKED credential file in the store => rc 78 (the store holds regular files), no CLI call.
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
# Encodes the MEASURED rule (spike S1c-0 (b), v3.4 K2): the CLI refreshes ONLY when expiresAt - now <= 300 s. `-p` needs a non-empty prompt (like
# the real CLI: without one and with stdin at /dev/null it fails "input must be provided"). Modes: fail | noop | hang | racing (a human login lands in the store mid-ping).
w=$(cd -P "$(dirname "$0")/.." && pwd); now=$(cat "$w/cli.now"); c="$CLAUDE_CONFIG_DIR/.credentials.json"
exp_in=$(python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["claudeAiOauth"]["expiresAt"]//1000-int(sys.argv[2]))' "$c" "$now" 2>/dev/null)
prompt=""; if [ "${1:-}" = "-p" ]; then prompt="${2:-}"; case "$prompt" in -*) prompt="";; esac; fi
printf 'provider=claude uid=%s argv=%s cfg=%s exp_in=%s prompt=%s\n' "$(id -u)" "$*" "${CLAUDE_CONFIG_DIR:-}" "$exp_in" "$prompt" >> "$w/cli.log"
mode="$(cat "$w/cli.mode" 2>/dev/null)"
[ -n "$prompt" ] || { echo "Error: input must be provided either through stdin or as a prompt argument when using --print" >&2; exit 1; }
[ "$mode" != fail ] || { echo "refresh failed" >&2; exit 1; }
[ "$mode" != hang ] || { echo $$ > "$w/cli.pid"; sleep 30; exit 0; }
[ "$mode" != noop ] || exit 0
if [ "$mode" = racing ]; then
  s="$w/login/claude-code/.credentials.json"
  printf '{"claudeAiOauth":{"accessToken":"at-HUMAN","refreshToken":"rt-HUMAN","expiresAt":%s000}}' "$(( now + 28800 ))" > "$s.h"; chmod 640 "$s.h"; mv "$s.h" "$s"
fi
[ "$exp_in" -le 300 ] || exit 0                                    # not inside the refresh window: the ping succeeds and changes nothing
python3 -I - "$c" "$now" <<'PY'
import json, os, sys
p, now = sys.argv[1], int(sys.argv[2]); d = json.load(open(p)); o = d["claudeAiOauth"]
o["accessToken"] = "at-NEW-" + str(now); o["refreshToken"] = "rt-NEW-" + str(now); o["expiresAt"] = (now + 3600) * 1000
t = p + ".tmp"; open(t, "w").write(json.dumps(d)); os.chmod(t, 0o600); os.rename(t, p)      # tmp + rename, 0600, like the CLI
PY
FAKE
cat > "$W/fakes/codex" <<'FAKE'
#!/usr/bin/env bash
# Same measured rule for the JWT: refresh only when exp - now <= 300 s. Modes: fail | noop | hang | racing.
w=$(cd -P "$(dirname "$0")/.." && pwd); now=$(cat "$w/cli.now"); a="$CODEX_HOME/auth.json"
exp_in=$(python3 -I - "$a" "$now" 2>/dev/null <<'PY'
import base64, json, sys
d = json.load(open(sys.argv[1])); p = d["tokens"]["access_token"].split(".")[1]
print(json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))["exp"] - int(sys.argv[2]))
PY
)
printf 'provider=codex uid=%s argv=%s cfg=%s exp_in=%s\n' "$(id -u)" "$*" "${CODEX_HOME:-}" "$exp_in" >> "$w/cli.log"
mode="$(cat "$w/cli.mode" 2>/dev/null)"
[ "$mode" != fail ] || { echo "refresh failed" >&2; exit 1; }
[ "$mode" != hang ] || { echo $$ > "$w/cli.pid"; sleep 30; exit 0; }
[ "$mode" != noop ] || exit 0
if [ "$mode" = racing ]; then
  s="$w/login/codex/auth.json"; printf '{"tokens":{"access_token":"jwt-HUMAN","refresh_token":"rt-HUMAN","account_id":"acct-human"}}' > "$s.h"; chmod 640 "$s.h"; mv "$s.h" "$s"
fi
[ "$exp_in" -le 300 ] || exit 0
python3 -I - "$a" "$now" <<'PY'
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
eq "T4: one call, private CODEX_HOME" "$(printf '%s\n' "$log" | wc -l | tr -d ' ')|$(printf '%s' "$log" | sed 's/.* cfg=//' | grep -vc "^$LROOT")" "1|1"
mk_codex $(( LNOW + THR + 1 )); reset
lrun -- "$REF" codex
eq "T4: a codex token far from expiry is not refreshed" "$RC|$(clog | wc -l | tr -d ' ')" "0|0"

# --- T5 failures leave the store byte-identical ---------------------------------------------------------------------------------------
for mode in fail noop; do
  reset; mk_claude $(( LNOW + 100 )); before="$(cat "$LROOT/claude-code/.credentials.json")"; echo "$mode" > "$W/cli.mode"
  lrun -- "$REF" claude-code
  want=1; [ "$mode" != noop ] || want=0                                                        # v3.4 K2/K8: "no change" is not a failure
  eq "T5: CLI '$mode' => rc $want, store byte-identical, private dir removed" "$RC|$([ "$before" = "$(cat "$LROOT/claude-code/.credentials.json")" ] && echo same)|$([ ! -e "$(clog | sed 's/.* cfg=//' | head -1)" ] && echo clean)" "$want|same|clean"
done
reset; rm -f "$LROOT/codex/auth.json"
lrun -- "$REF" codex
eq "T5: an absent credential => rc 0 (v3.4 K2/K8: a fresh install must not alarm every cycle), no CLI call, a log line" "$RC|$(clog | wc -l | tr -d ' ')|$([ -n "$OUT$ERR" ] && echo logged)" "0|0|logged"
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

# =====================================================================================================================================
# Gate round 1 delta (v3.4): K2 forced refresh on the private copy, K8 rc 0 for "nothing to do", M2 no overwrite of a newer human login,
# M3 bounded children. The fakes above encode the MEASURED rule (refresh only at <= 300 s), so the due window (> 300 s) is only reachable
# if the refresher lowers the expiry in its PRIVATE copy first.
# =====================================================================================================================================

# --- T7 (K2) claude: a due token far above the CLI's own 300 s window is still refreshed, via the private copy ------------------------
reset; rm -f "$LROOT/claude-code/.credentials.json" "$W/real-cred"; mk_claude $(( LNOW + THR )); f="$LROOT/claude-code/.credentials.json"
lrun -- "$REF" claude-code
log="$(clog)"
eq "T7: due at threshold (> 300 s left) => rc 0, exactly one ping" "$RC|$(printf '%s' "$log" | grep -c '^provider=claude')" "0|1"
exp_seen="$(printf '%s' "$log" | sed -n 's/.* exp_in=\([-0-9]*\) .*/\1/p' | head -1)"
case "$exp_seen" in ''|*[!0-9-]*) no "T7: the CLI saw a numeric expiry in its copy (got '$exp_seen')";; *) if [ "$exp_seen" -le 300 ]; then ok "T7: the PRIVATE copy's expiresAt was lowered into the CLI's refresh window (saw ${exp_seen}s)"; else no "T7: the private copy's expiresAt was lowered to <= 300 s (saw ${exp_seen}s)"; fi;; esac
prompt="$(printf '%s' "$log" | sed -n 's/.* prompt=\(.*\)$/\1/p' | head -1)"
eq "T7: the ping carries a NON-EMPTY prompt (the real CLI fails without one)" "$([ -n "${prompt// /}" ] && echo prompt)" prompt
has "T7: …and the published store has the new tokens" "$(cat "$f")" "at-NEW-$LNOW"
expat() { python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["claudeAiOauth"]["expiresAt"])' "$1" 2>/dev/null; }
eq "T7: …with the CLI's new expiry (the store is not left with the lowered value)" "$(expat "$f")" "$(( (LNOW + 3600) * 1000 ))"
eq "T7: mode 0640 and no stray files after the forced refresh" "$(mode_of "$f")|$(ls -A "$LROOT/claude-code" | tr '\n' ' ')" "640|.credentials.json "
eq "T7: the lowered value (now+60 s) never reaches the store" "$(printf '%s' "$(cat "$f")" | grep -c "$(( (LNOW + 60) * 1000 ))")" 0

# --- T8 (K2/K8) nothing to do is not a failure ----------------------------------------------------------------------------------------
reset; mk_claude $(( LNOW + THR )); echo noop > "$W/cli.mode"; before="$(cat "$f")"
lrun -- "$REF" claude-code
eq "T8: the CLI changed nothing => rc 0, store byte-identical, one log line (not an alarm)" "$RC|$([ "$before" = "$(cat "$f")" ] && echo same)|$([ -n "$OUT$ERR" ] && echo logged)" "0|same|logged"
reset; rm -f "$LROOT/claude-code/.credentials.json"
lrun -- "$REF" claude-code
eq "T8: no login yet (claude-code) => rc 0, no CLI call, one log line" "$RC|$(clog | wc -l | tr -d ' ')|$([ -n "$OUT$ERR" ] && echo logged)" "0|0|logged"

# --- T9 (M3) a hung CLI is bounded -------------------------------------------------------------------------------------------------------
for prov in claude-code codex; do
  reset; if [ "$prov" = codex ]; then mk_codex $(( LNOW + 100 )); else mk_claude $(( LNOW + 100 )); fi
  echo hang > "$W/cli.mode"; rm -f "$W/cli.pid"
  cf_="$LROOT/$prov/$([ "$prov" = codex ] && echo auth.json || echo .credentials.json)"; before="$(cat "$cf_")"
  t0=$(date +%s); lrun AIB_LOGIN_CLI_TIMEOUT_S=1 -- "$REF" "$prov"; t1=$(date +%s)
  pid="$(cat "$W/cli.pid" 2>/dev/null)"
  eq "T9: $prov: a hanging CLI is killed after AIB_LOGIN_CLI_TIMEOUT_S (returns within 12 s, rc 1, store untouched)" "$([ $(( t1 - t0 )) -le 12 ] && echo bounded)|$RC|$([ "$before" = "$(cat "$cf_")" ] && echo same)" "bounded|1|same"
  eq "T9: $prov: …and the hung CLI process is gone" "$([ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null && echo dead)" dead
done
rm -f "$W/cli.mode"
SVC_="$SRC_ROOT/deploy/systemd/aib-login-refresh@.service"
eq "T9: the refresher unit bounds a run itself: TimeoutStartSec= is set to a positive number of seconds" "$(grep -E '^TimeoutStartSec=[1-9][0-9]*(s|min)?$' "$SVC_" 2>/dev/null | wc -l | tr -d ' ')" 1

# --- T10 (M2) the refresher never overwrites a newer human login -------------------------------------------------------------------------
reset; mk_claude $(( LNOW + 100 )); echo racing > "$W/cli.mode"
lrun -- "$REF" claude-code
cur="$(cat "$LROOT/claude-code/.credentials.json")"
eq "T10: claude: a login published while the ping runs survives (store keeps at-HUMAN, not the refresher's older-lineage tokens), rc 0" "$RC|$(printf '%s' "$cur" | grep -c 'at-HUMAN')|$(printf '%s' "$cur" | grep -c 'at-NEW')" "0|1|0"
eq "T10: …and nothing stray is left" "$(ls -A "$LROOT/claude-code" | tr '\n' ' ')" ".credentials.json "
reset; mk_codex $(( LNOW + 100 )); echo racing > "$W/cli.mode"
lrun -- "$REF" codex
cur="$(cat "$LROOT/codex/auth.json")"
eq "T10: codex: a login published while the refresh runs survives, rc 0" "$RC|$(printf '%s' "$cur" | grep -c 'jwt-HUMAN')|$(printf '%s' "$cur" | grep -c 'rt-NEW')" "0|1|0"
rm -f "$W/cli.mode"

# --- T11 (K2) codex: the observable outcome only ---------------------------------------------------------------------------------------
# The codex fake refreshes only inside the last 300 s of the access token. The mechanism (a lever in the private copy, a re-armed timer, ...) is the
# builder's. Pinned: simulate the timer ticking every cadence for 6 h; right BEFORE every tick (the worst moment of each interval) the stored token must still leave a full turn (floor = max turn
# 900 + margin 300 + slack 600) so no turn is ever refused by the broker/adapter floor.
remaining_codex() { python3 -I - "$LROOT/codex/auth.json" "$1" <<'PY'
import base64, json, sys
d = json.load(open(sys.argv[1])); p = d["tokens"]["access_token"].split(".")[1]
print(json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))["exp"] - int(sys.argv[2]))
PY
}
reset; rm -f "$LROOT/codex/auth.json"; mk_codex $(( LNOW + 3600 )); cc="$C"; lowest=999999; ticks=0
for n in $(seq 1 $(( 21600 / cc ))); do
  tk=$(( LNOW + n * cc )); echo "$tk" > "$W/cli.now"
  rem="$(remaining_codex "$tk")"                       # validity left JUST BEFORE this tick = the worst moment of the interval before it
  [ "$rem" -ge "$lowest" ] 2>/dev/null || lowest="$rem"; ticks=$(( ticks + 1 ))
  lrun AIB_LOGIN_NOW="$tk" -- "$REF" codex
done
echo "$LNOW" > "$W/cli.now"
if [ "${lowest:-0}" -ge 1800 ] 2>/dev/null; then ok "T11: codex: over $ticks ticks the stored token keeps >= 1800 s before each tick (lowest ${lowest}s) — the store is refreshed before the floor is hit"; else no "T11: codex: the stored token must keep >= 1800 s right before every tick (lowest seen ${lowest}s over $ticks ticks)"; fi

# --- T12 (Riker M8) the refresher does not trust a store file it does not own ------------------------------------------------------------------
# The store dir is group-writable for the role accounts. A credential file owned by anybody else than the expected owner (default: the refresher's
# own effective uid; seam AIB_LOGIN_STORE_OWNER, same name as the codex adapter) is never fed to a CLI nor re-published: rc 78, no CLI call.
other_user="$(getent passwd 0 | cut -d: -f1)"; [ "$(id -u)" -ne 0 ] || other_user="nobody"
reset; rm -f "$LROOT/claude-code/.credentials.json"; mk_claude $(( LNOW + 100 )); before="$(cat "$LROOT/claude-code/.credentials.json")"
lrun AIB_LOGIN_STORE_OWNER="$other_user" -- "$REF" claude-code
eq "T12: claude: a credential file owned by someone else => rc 78, no CLI call, store untouched" "$RC|$(clog | wc -l | tr -d ' ')|$([ "$before" = "$(cat "$LROOT/claude-code/.credentials.json")" ] && echo same)" "78|0|same"
reset; rm -f "$LROOT/codex/auth.json"; mk_codex $(( LNOW + 100 ))
lrun AIB_LOGIN_STORE_OWNER="$other_user" -- "$REF" codex
eq "T12: codex: the same" "$RC|$(clog | wc -l | tr -d ' ')" "78|0"
reset; mk_codex $(( LNOW + 100 )); lrun AIB_LOGIN_STORE_OWNER="$(id -un)" -- "$REF" codex
eq "T12: guard — with the matching owner the refresh runs" "$RC|$(clog | wc -l | tr -d ' ')" "0|1"

printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
