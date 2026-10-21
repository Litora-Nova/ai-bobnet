#!/usr/bin/env bash
# ai-bobnet — RED spec for the login watch, the status file and the server outbox (Supervisor slice S1c; design v3 G5/G6, v3.1 H6/H7).
#
# WHAT THIS PINS
#   bin/aib-login-watch [<provider>...]   one-shot (unit aib-login-watch.service + hourly .timer, User=aib-broker, READ-ONLY on the store).
#   No argument = every provider directory under $AIB_LOGIN_ROOT. Per provider it computes
#       state        absent   no credential file in the store
#                    expired  login end <= now
#                    expiring login end - now <= AIB_LOGIN_EXPIRING_S (boundary inclusive)
#                    ok       otherwise
#       login end    Claude: claudeAiOauth.refreshTokenExpiresAt (ms) when present, else login.meta.json `login_expires_at`;
#                    Codex:  login.meta.json `login_expires_at` (its file has no refresh-token expiry).
#       id hint      last 4 characters of the account id: Codex tokens.account_id, Claude login.meta.json `account_id`; never an e-mail.
#       label        deployment.json accounts.<provider>.label ("" when none).
#   and writes $AIB_LOGIN_STATUS_DIR/<provider>.json (mode 0644, written tmp + rename):
#       {"provider":P,"state":S,"expires_at":"<ISO UTC>"|null,"label":L,"id_hint":H,"checked_at":"<ISO UTC>"}   — NEVER a token.
#   Alarms (server outbox $AIB_OUTBOX_ROOT/_server/outbox.md, line format of a team outbox, from:aib-login-watch, to:human:ops,
#   state:PERSISTED, body `alarm:<kind> provider:<p> expires_at:<ISO>`), de-duplicated on STATE TRANSITION (not on expires_at):
#       ok|absent -> expiring            => login_expiring (once)
#       ok|expiring|absent -> expired    => login_expired  (once)   [absent -> absent and ok -> ok emit nothing]
#       the same alert state again       => at most one re-emit per AIB_LOGIN_REEMIT_S (daily), none before
#       back to ok (a re-login), then expiring again => a NEW transition: emits again
#   State needed for this lives in AIB_LOGIN_STATE_DIR. Nothing is ever written into a team outbox. The store is not modified.
#
#   Expected on the unbuilt tree: bin/aib-login-watch does not exist.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/fixtures/login_harness.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-lwatch.XXXXXX")"
trap sup_cleanup EXIT
lw_world w
WATCH="$ENGINE/bin/aib-login-watch"
deploy_accounts '{"claude-code":{"label":"Interim: PO account"}}'
H=3600
st() { python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2]))' "$LSTAT/$1.json" "$2" 2>/dev/null; }
watch() { lrun "$@" -- "$WATCH" ${WP:-}; }

# --- T1 states and the boundary ---------------------------------------------------------------------------------------------------------
mk_claude $(( LNOW + 3600 )); mk_meta claude-code $(( LNOW - 100 )) $(( LNOW + 300*H ))
WP=claude-code watch
eq "T1: far login end => ok" "$RC|$(st claude-code state)" "0|ok"
mk_meta claude-code $(( LNOW - 100 )) $(( LNOW + 72*H + 1 ))
WP=claude-code watch; eq "T1: 72 h + 1 s left => still ok" "$(st claude-code state)" ok
mk_meta claude-code $(( LNOW - 100 )) $(( LNOW + 72*H ))
WP=claude-code watch; eq "T1: exactly 72 h left => expiring (inclusive)" "$(st claude-code state)" expiring
mk_meta claude-code $(( LNOW - 100 )) $(( LNOW + 1 ))
WP=claude-code watch; eq "T1: 1 s left => expiring" "$(st claude-code state)" expiring
mk_meta claude-code $(( LNOW - 100 )) "$LNOW"
WP=claude-code watch; eq "T1: login end == now => expired" "$(st claude-code state)" expired
rm -f "$LROOT/claude-code/.credentials.json"
WP=claude-code watch; eq "T1: no credential file => absent" "$(st claude-code state)" absent
mk_claude $(( LNOW + 3600 )); mk_meta claude-code 1 $(( LNOW + 100 ))
WP=claude-code watch AIB_LOGIN_EXPIRING_S=100; eq "T1: the 72 h threshold is a parameter (100 s => 100 s left is expiring)" "$(st claude-code state)" expiring
mk_claude $(( LNOW + 3600 )) $(( LNOW + 10*H )); mk_meta claude-code 1 $(( LNOW + 300*H ))
WP=claude-code watch; eq "T1: Claude's own refreshTokenExpiresAt wins over the meta file (10 h left => expiring)" "$(st claude-code state)" expiring

# --- T2 the status file: shape, mode, no secrets ----------------------------------------------------------------------------------------
mk_claude $(( LNOW + 3600 )); mk_meta claude-code $(( LNOW - 100 )) $(( LNOW + 300*H )) acct-0000c0de
WP=claude-code watch; f="$LSTAT/claude-code.json"
eq "T2: status file mode 0644" "$(mode_of "$f")" 644
eq "T2: keys are exactly provider,state,expires_at,label,id_hint,checked_at" "$(python3 -I -c 'import json,sys;print(",".join(sorted(json.load(open(sys.argv[1])))))' "$f" 2>/dev/null)" "checked_at,expires_at,id_hint,label,provider,state"
eq "T2: label from the deployment config, id_hint = last 4 of the account id" "$(st claude-code label)|$(st claude-code id_hint)" "Interim: PO account|c0de"
want_iso="$(date -u -d "@$(( LNOW + 300*H ))" +%Y-%m-%dT%H:%M:%SZ)"
eq "T2: expires_at is the login end as ISO UTC; checked_at is the clock" "$(st claude-code expires_at)|$(st claude-code checked_at)" "$want_iso|$(date -u -d "@$LNOW" +%Y-%m-%dT%H:%M:%SZ)"
eq "T2: no token anywhere (status file, stdout, stderr)" "$([ -f "$f" ] && printf '%s%s%s' "$(cat "$f")" "$OUT" "$ERR" | grep -c -e "$SENT" -e 'at-' -e 'rt-')" 0
mk_codex $(( LNOW + 3600 )) acct-9999beef; mk_meta codex 1 $(( LNOW + 300*H )) acct-9999beef; WP=codex watch
eq "T2: a provider without an accounts entry gets label \"\"; id_hint from the meta" "$(st codex label)|$(st codex id_hint)" "|beef"
mk_codex $(( LNOW + 3600 )) acct-1111f00d; rm -f "$LROOT/codex/login.meta.json"
WP=codex watch; eq "T2: codex id_hint falls back to tokens.account_id when there is no meta" "$(st codex id_hint)" "f00d"
eq "T2: the status file never carries an e-mail address" "$([ -f "$f" ] && grep -c '@' "$f")" 0
rm -f "$LSTAT"/*.json; WP="" watch
eq "T2: no argument = every provider directory" "$(ls "$LSTAT" | tr '\n' ' ')" "claude-code.json codex.json "

# --- T3 the store is read-only for the watch ----------------------------------------------------------------------------------------------
mk_claude $(( LNOW + 3600 )); mk_meta claude-code 1 $(( LNOW + 300*H ))
sum_before="$(cd "$LROOT" && find . -type f -exec sha256sum {} + | sort)"; mt_before="$(cd "$LROOT" && find . -printf '%p %T@\n' | sort)"
WP=claude-code watch
eq "T3: store bytes and mtimes unchanged" "$([ "$sum_before" = "$(cd "$LROOT" && find . -type f -exec sha256sum {} + | sort)" ] && echo same)|$([ "$mt_before" = "$(cd "$LROOT" && find . -printf '%p %T@\n' | sort)" ] && echo same)" "same|same"
chmod -R a-w "$LROOT"; WP=claude-code watch; eq "T3: it also works on a read-only store" "$RC|$(st claude-code state)" "0|ok"; chmod -R u+w "$LROOT"

# --- T4 server outbox, transition dedupe ----------------------------------------------------------------------------------------------------
lw_clean
setend() { mk_claude $(( LNOW + 3600 )); mk_meta claude-code 1 "$1"; }
tick() { WP=claude-code watch AIB_LOGIN_NOW="${1:-$LNOW}"; }
setend $(( LNOW + 300*H )); tick
eq "T4: ok on first sight emits nothing" "$(SO | wc -l | tr -d ' ')" 0
setend $(( LNOW + 70*H )); tick
eq "T4: ok -> expiring emits one login_expiring" "$(son login_expiring)|$(son login_expired)" "1|0"
line="$(SO | grep alarm:login_expiring | head -1)"
case "$line" in 20??-??-??T??:??:??*Z\ \|\ id:alarm-*) ok "T4: line starts with ISO UTC + id";; *) no "T4: line starts with ISO UTC + id (got '$line')";; esac
has "T4: from the watch, to the human ops, PERSISTED" "$line" "| from:aib-login-watch | to:human:ops | state:PERSISTED | "
has "T4: body names kind, provider and the login end" "$line" "alarm:login_expiring provider:claude-code expires_at:$(date -u -d "@$(( LNOW + 70*H ))" +%Y-%m-%dT%H:%M:%SZ)"
tick $(( LNOW + 3600 )); tick $(( LNOW + 7200 ))
eq "T4: the next ticks (same state) do not repeat it" "$(son login_expiring)" 1
tick $(( LNOW + 86400 ))
eq "T4: after AIB_LOGIN_REEMIT_S it is repeated once" "$(son login_expiring)" 2
tick $(( LNOW + 86400 + 60 ))
eq "T4: …and then quiet again" "$(son login_expiring)" 2
setend $(( LNOW + 86400 + 100 )); tick $(( LNOW + 86400 + 200 ))
eq "T4: the login end moving while expiring is not a new transition" "$(son login_expiring)" 2
setend $(( LNOW + 86400 )); tick $(( LNOW + 86400 + 300 ))
eq "T4: expiring -> expired emits one login_expired" "$(son login_expired)" 1
tick $(( LNOW + 86400 + 400 )); eq "T4: …once" "$(son login_expired)" 1
setend $(( LNOW + 300*H + 90000 )); tick $(( LNOW + 90000 ))
eq "T4: a re-login (back to ok) emits nothing" "$(son login_expired)|$(son login_expiring)" "1|2"
setend $(( LNOW + 90000 + 60*H )); tick $(( LNOW + 90000 + 1 ))
eq "T4: ok -> expiring AGAIN is a new transition: emits again" "$(son login_expiring)" 3
lw_clean; setend "$LNOW"; tick
eq "T4: ok/absent -> expired directly emits login_expired" "$(son login_expired)|$(son login_expiring)" "1|0"
eq "T4: ids are unique" "$(SO | awk -F' [|] ' '{print $2}' | sort | uniq -d | wc -l | tr -d ' ')|$(SO | wc -l | tr -d ' ')" "0|1"
lw_clean; rm -f "$LROOT/claude-code/.credentials.json"; tick; tick $(( LNOW + 90000 ))
eq "T4: absent -> absent emits nothing, ever" "$(SO | wc -l | tr -d ' ')|$(st claude-code state)" "0|absent"
lw_clean; setend $(( LNOW + 60*H )); tick
eq "T4: only the _server outbox exists; no team outbox is touched or created" "$(ls "$OUTBOX" | tr '\n' ' ')" "_server "

# --- T5 an unusable server outbox does not stop the status file ---------------------------------------------------------------------------------
lw_clean; printf 'a file where the server dir should be' > "$OUTBOX/_server"
setend $(( LNOW + 60*H )); tick
eq "T5: the status file is still written (alarms are best effort)" "$(st claude-code state)" expiring

# --- T6 unit texts ------------------------------------------------------------------------------------------------------------------------------------
SVC="$SRC_ROOT/deploy/systemd/aib-login-watch.service"; TMR="$SRC_ROOT/deploy/systemd/aib-login-watch.timer"
sv() { grep -v '^[[:space:]]*#' "$SVC" 2>/dev/null; }
eq "T6: oneshot, User=aib-broker, OnFailure alarm" "$(sv | grep -cx -e 'Type=oneshot' -e 'User=aib-broker' -e 'OnFailure=aib-alarm@%n.service')" 3
case "$(sv | grep '^ExecStart=' | head -1)" in ExecStart=/*/bin/aib-login-watch) ok "T6: ExecStart= absolute path to bin/aib-login-watch";; *) no "T6: ExecStart= absolute path to bin/aib-login-watch";; esac
eq "T6: the store is read-only for the watch (ReadOnlyPaths= names /var/lib/aib/login)" "$(sv | grep '^ReadOnlyPaths=' | grep -c '/var/lib/aib/login')" 1
eq "T6: hourly timer, installable" "$(grep -c -e '^OnUnitActiveSec=1h$' -e '^WantedBy=timers.target$' "$TMR" 2>/dev/null)" 2

printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
