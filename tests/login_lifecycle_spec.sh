#!/usr/bin/env bash
# ai-bobnet — RED spec for the login lifecycle: the login unit, `agentctl login`, the code channel (Supervisor slice S1c;
# design v3 G4, v3.1 H4/H5/H6, E9 "A now": Claude browser login; Codex device flow).
#
# WHAT THIS PINS
#   bin/aib-login <provider>           the ExecStart of aib-login@<provider>.service (User=aib-broker; the only process that creates a login).
#     It serves ONE request: the newest `login.requested` record for <provider> in $AIB_CONTROL_LOG without a terminal record
#     ({"event":"login.requested","verb":"login-start","target":<provider>,"caller":C,"actor":A}). Audit events it appends (same
#     seq allocator + lock as every writer): login.started | login.rejected{reason} | login.code_accepted | login.code_rejected{reason}
#     | login.succeeded | login.failed{reason}, each with provider, req (the requested seq), caller (the requester) and, where it
#     exists, vorgang. THE CODE IS NEVER IN ANY RECORD.
#     Gate (only for a requester `gateway:*`; `human:*` is unrestricted): the status file state must be expiring|expired|absent, else
#     login.rejected reason=not_due; and at most one gateway-started login per AIB_LOGIN_START_INTERVAL_S per provider (state in
#     AIB_LOGIN_STATE_DIR; a rejected request does not consume the slot), else reason=rate_limited. A rejected run exits 0 (v3.4 K8; was 77: with OnFailure= a policy rejection must not page ops), starts no CLI.
#     Claude (adapter argv `auth login`, CLAUDE_CONFIG_DIR = a private temp dir, the CLI runs on a PTY the unit holds; the unit turns the
#     tty echo OFF and redacts anyway):
#       - finds the first https URL the CLI prints; appends to the SERVER outbox
#         `alarm:login_required provider:claude-code vorgang:<32 hex> url:<url> expires_at:<ISO of the vorgang window end>`;
#       - writes status state `pending` (other fields kept) and opens the unix socket $AIB_LOGIN_SOCK_DIR/login-<provider>.sock (mode 0660);
#       - protocol: ONE JSON line in {"provider","vorgang","code","received_at":<epoch float>} -> ONE JSON line out {"ok":true}|{"ok":false,"reason":R}.
#         The caller is attested by SO_PEERCRED (uid) -> AIB_IDENTITY_CMD; only `gateway:*` may submit. Reasons: unauthorized | vorgang_unknown
#         | bad_code (charset [A-Za-z0-9#_-], 1..256 bytes) | stale (now - received_at > AIB_LOGIN_CODE_FRESH_S) | already_used.
#         Any rejection leaves the vorgang OPEN; the first accepted code CONSUMES it (single use, journaled as login.code_accepted).
#       - the accepted code is typed into the PTY once; the unit waits for the CLI. On rc 0 it publishes the credential into the store (tmp + rename,
#         0640, dir untouched), writes login.meta.json {logged_in_at: now, login_expires_at: now + AIB_LOGIN_LIFETIME_S, account_id: the id
#         the CLI left in its private .claude.json oauthAccount.accountUuid}, appends login.succeeded, removes the socket and the private dir, exits 0.
#         CLI rc != 0 => login.failed reason=cli_failed, store untouched, exit 1.
#       - window: no accepted code within AIB_LOGIN_WINDOW_S => the CLI is killed, login.failed reason=timeout, server alarm
#         `alarm:login_failed provider:claude-code reason:timeout`, store untouched, exit 1.
#       - capture hygiene: the code is absent from _control.jsonl, the server outbox, the status file, the unit's stdout/stderr (the journal) and the
#         unit's PTY capture file $AIB_LOGIN_STATE_DIR/<provider>.pty.log, even though the fake CLI echoes what it reads.
#     Codex (argv `login --device-auth`, CODEX_HOME private): the first https URL and the user code (`[A-Z0-9]{4}-[A-Z0-9]{4}`) go out as
#       `alarm:login_required provider:codex url:<url> user_code:<code>`; no vorgang, no socket; the unit waits for the CLI and publishes as above.
#   bin/agentctl login status [<provider>]   prints JSON (one object per line): {"provider","state","expires_at","account_label","account_id_hint"}
#       from $AIB_LOGIN_STATUS_DIR/<p>.json (missing => state absent) + the deployment label; reads NOTHING from the store (works with the store unreadable).
#   bin/agentctl login start <provider>      callers human:* and gateway:* only (role:* => 77 unauthorized, ctl.rejected); provider must be claude-code
#       or codex (else 64). It appends `login.requested` {provider, caller, actor} to $AIB_CONTROL_LOG, runs `<systemctl> start aib-login@<provider>.service`,
#       then waits (AIB_CTL_WAIT_S) for login.started (rc 0) | login.rejected (rc 77) | login.failed (rc 69) carrying its req; nothing in time => rc 124.
#
#   Expected on the unbuilt tree: bin/aib-login and the `login` verbs do not exist.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/fixtures/login_harness.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-llife.XXXXXX")"
trap 'ulife_stop; sup_cleanup' EXIT
lw_world l
UNIT_BIN="$ENGINE/bin/aib-login"
FP="$WORK/fakeprivate"; mkdir -p "$FP"                         # what the fake CLI saw: outside every scanned tree
CODE='LEAK-CODE_12345#abcDEF'

cat > "$W/fakes/claude" <<FAKE
#!/usr/bin/env bash
fp="$FP"; printf 'argv=%s cfg=%s\n' "\$*" "\${CLAUDE_CONFIG_DIR:-}" >> "\$fp/cli.log"; echo \$\$ > "\$fp/cli.pid"
[ "\$*" = "auth login" ] || exit 64
echo "Open this URL to sign in: https://claude.example.test/oauth/authorize?state=zz9&code_challenge=abc"
printf 'Paste code here > '
stty -a 2>/dev/null | tr ' ' '\\n' | grep -E '^-?echo\$' > "\$fp/echo.log"
IFS= read -r line
printf '%s\n' "\$line" >> "\$fp/typed.log"
echo "got: \$line"                                               # a CLI that echoes what it read
[ "\$line" = "$CODE" ] || { echo "Invalid code"; exit 1; }
mkdir -p "\$CLAUDE_CONFIG_DIR"
printf '{"claudeAiOauth":{"accessToken":"at-LOGIN-$SENT","refreshToken":"rt-LOGIN-$SENT","expiresAt":%s000}}' "\$(( \$(date +%s) + 3600 ))" > "\$CLAUDE_CONFIG_DIR/.credentials.json"; chmod 600 "\$CLAUDE_CONFIG_DIR/.credentials.json"
printf '{"oauthAccount":{"accountUuid":"uuid-aaaa-beef1234"}}' > "\$CLAUDE_CONFIG_DIR/.claude.json"
echo "Login successful"
FAKE
cat > "$W/fakes/codex" <<FAKE
#!/usr/bin/env bash
fp="$FP"; printf 'argv=%s cfg=%s\n' "\$*" "\${CODEX_HOME:-}" >> "\$fp/cli.log"
[ "\$*" = "login --device-auth" ] || exit 64
echo "Open https://auth.example.test/device and enter the code ABCD-EFGH"
sleep 0.6
mkdir -p "\$CODEX_HOME"; printf '{"tokens":{"access_token":"jwt-$SENT","refresh_token":"rt-$SENT","account_id":"acct-0000d00d"}}' > "\$CODEX_HOME/auth.json"
echo "Logged in"
FAKE
chmod +x "$W/fakes/claude" "$W/fakes/codex"
LENV+=(AIB_CLAUDE_BIN="$W/fakes/claude" AIB_CODEX_BIN="$W/fakes/codex" AIB_LOGIN_WINDOW_S=30 AIB_LOGIN_CODE_FRESH_S=60 AIB_LOGIN_START_INTERVAL_S=3600)

# a login.requested record, as agentctl writes it: lreq <provider> <caller> [actor] -> echoes the seq
lreq() { python3 -I - "$CLOG" "$1" "$2" "${3:-}" <<'PY'
import json, sys, datetime, fcntl
path, prov, caller, actor = sys.argv[1:5]
lock = open(path + ".lock", "a"); fcntl.flock(lock, fcntl.LOCK_EX)
seq = 0
try:
    for l in open(path):
        if l.strip(): seq = max(seq, json.loads(l)["seq"])
except FileNotFoundError: pass
rec = {"seq": seq + 1, "ts": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"), "event": "login.requested", "verb": "login-start",
       "target": prov, "provider": prov, "caller": caller, "actor": actor}
open(path, "a").write(json.dumps(rec) + "\n"); print(seq + 1)
PY
}
# sendcode <provider> <vorgang> <code> [age_s] -> prints the reply line (empty on a connect failure)
sendcode() { python3 -I - "$LSOCK/login-$1.sock" "$1" "$2" "$3" "${4:-0}" <<'PY'
import json, socket, sys, time
sock, prov, vg, code, age = sys.argv[1:6]
try:
    s = socket.socket(socket.AF_UNIX); s.settimeout(10); s.connect(sock)
    s.sendall((json.dumps({"provider": prov, "vorgang": vg, "code": code, "received_at": time.time() - float(age)}) + "\n").encode())
    print(s.makefile().readline().strip())
except Exception as e:
    print("ERR", type(e).__name__)
PY
}
reply_ok() { printf '%s' "$1" | grep -q '"ok": *true'; }
reply_reason() { printf '%s' "$1" | python3 -I -c 'import json,sys;print(json.loads(sys.stdin.read()).get("reason",""))' 2>/dev/null; }
UPID=""
ustart() { # ustart <provider> [VAR=val...]
  local p="$1"; shift; : > "$W/unit.out"; : > "$W/unit.err"
  env -i PATH="$W/fakebin:$PATH" HOME="$W/home-login" LANG=C TZ=UTC "${LENV[@]}" AIBOBNET_REGISTRY="$ENGINE/registry.json" "$@" \
    "$UNIT_BIN" "$p" >"$W/unit.out" 2>"$W/unit.err" & UPID=$!
}
ulife_stop() { [ -z "${UPID:-}" ] || { kill -TERM "$UPID" 2>/dev/null; wait "$UPID" 2>/dev/null; UPID=""; }; }
uwait() { WAIT_DEAD_OK=1 wait_for "${1:-10}" bash -c "! kill -0 $UPID 2>/dev/null"; local r=0; wait "$UPID" 2>/dev/null || r=$?; UPID=""; URC=$r; }
# uwf <seconds> <cmd...> — poll until the command succeeds; gives up at once when the unit under test is gone (keeps a RED run fast)
uwf() { local t="$1" i; shift; for ((i=0;i<t*20;i++)); do "$@" >/dev/null 2>&1 && return 0; [ -n "$UPID" ] && kill -0 "$UPID" 2>/dev/null || return 1; sleep 0.05; done; return 1; }
vorg() { SO | grep "alarm:login_required provider:$1" | tail -1 | grep -o 'vorgang:[0-9a-f]*' | cut -d: -f2; }
has_vorg() { [ -n "$(vorg "$1")" ]; }
ev() { python3 -I "$SJ" count "$CLOG" "$1"; }
evf() { cf "$1" "${3:--1}" "$2"; }
fresh() { lw_clean; rm -f "$LROOT/claude-code/".* "$LROOT/claude-code/"* "$LROOT/codex/"* 2>/dev/null; : > "$CLOG"; : > "$FP/typed.log"; rm -f "$FP/cli.log" "$FP/cli.pid"; as human:operator; }

# --- T1 claude happy path -------------------------------------------------------------------------------------------------------------------------
fresh; lreq claude-code human:operator >/dev/null
ustart claude-code
uwf 15 has_vorg claude-code
V="$(vorg claude-code)"; line="$(SO | grep 'alarm:login_required provider:claude-code' | tail -1)"
eq "T1: the vorgang id is 32 hex chars (128 bit)" "$(printf '%s' "$V" | grep -Ec '^[0-9a-f]{32}$')" 1
has "T1: the alarm carries the URL" "$line" "url:https://claude.example.test/oauth/authorize?state=zz9&code_challenge=abc"
has "T1: …to the human ops, from the login unit" "$line" "| to:human:ops | state:PERSISTED | alarm:login_required provider:claude-code vorgang:$V "
eq "T1: the alarm names the window end (30 s of window => within a minute)" "$(printf '%s' "$line" | grep -Ec 'expires_at:20..-..-..T..:..:..Z')" 1
uwf 10 bash -c "[ -S '$LSOCK/login-claude-code.sock' ]"
eq "T1: the socket exists, mode 0660" "$([ -S "$LSOCK/login-claude-code.sock" ] && echo sock)|$(mode_of "$LSOCK/login-claude-code.sock")" "sock|660"
eq "T1: status is pending while the vorgang is open" "$(python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["state"])' "$LSTAT/claude-code.json" 2>/dev/null)" pending
as gateway:gw
R="$(sendcode claude-code "$V" "$CODE")"
eq "T1: a fresh code from the gateway is accepted" "$(reply_ok "$R" && echo ok)" ok
uwait 15
eq "T1: the unit exits 0" "$URC" 0
eq "T1: the CLI was called as 'auth login' and got the code once" "$(grep -c '^argv=auth login ' "$FP/cli.log")|$(cat "$FP/typed.log")" "1|$CODE"
cr="$LROOT/claude-code/.credentials.json"
eq "T1: credential published: 0640, new token, dir mode untouched, no stray files" "$(mode_of "$cr")|$(grep -c "at-LOGIN-$SENT" "$cr")|$(mode_of "$LROOT/claude-code")|$(ls -A "$LROOT/claude-code" | tr '\n' ' ')" "640|1|750|.credentials.json login.meta.json "
eq "T1: login.meta.json: 0640, logged_in_at=now, login_expires_at=now+lifetime, account id from the CLI" "$(mode_of "$LROOT/claude-code/login.meta.json")|$(python3 -I -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d["logged_in_at"],d["login_expires_at"],d["account_id"])' "$LROOT/claude-code/login.meta.json" 2>/dev/null)" "640|$LNOW $(( LNOW + 1000000 )) uuid-aaaa-beef1234"
eq "T1: audit trail: started, code_accepted, succeeded (one each) in this order" "$(python3 -I - "$CLOG" <<'PY'
import json, sys
print(",".join(r["event"] for r in map(json.loads, open(sys.argv[1])) if r["event"].startswith("login.") and r["event"] != "login.requested"))
PY
)" "login.started,login.code_accepted,login.succeeded"
eq "T1: …each carries provider and caller; accepted/succeeded carry the vorgang" "$(evf login.started provider)|$(evf login.started caller)|$(evf login.code_accepted vorgang)|$(evf login.code_accepted caller)" "claude-code|human:operator|$V|gateway:gw"
eq "T1: socket and private config dir are gone" "$(test -f "$FP/cli.log" && echo ran)|$([ ! -e "$LSOCK/login-claude-code.sock" ] && echo gone)|$([ ! -e "$(sed 's/.* cfg=//' "$FP/cli.log" | head -1)" ] && echo gone)" "ran|gone|gone"
eq "T1: the code is in NO capture: audit log, outbox, status, store, unit stdout/stderr, PTY capture file" "$URC|$(leaks "$CODE" "$CLOG" "$OUTBOX" "$LSTAT" "$LROOT" "$LSTATE" "$W/unit.out" "$W/unit.err")" "0|0"
eq "T1: …nor does any token leak into the audit log, outbox, status or unit output" "$(test -s "$cr" && echo have)|$(leaks "$SENT" "$CLOG" "$OUTBOX" "$LSTAT" "$W/unit.out" "$W/unit.err")" "have|0"
eq "T1: the PTY capture file (if kept) exists with no code in it" "$(if test -f "$LSTATE/claude-code.pty.log"; then grep -c "$CODE" "$LSTATE/claude-code.pty.log" || true; else echo nofile; fi)" 0

# --- T2 rejections leave the vorgang open ---------------------------------------------------------------------------------------------------------
fresh; lreq claude-code human:operator >/dev/null; ustart claude-code
uwf 15 has_vorg claude-code; V="$(vorg claude-code)"; uwf 10 bash -c "[ -S '$LSOCK/login-claude-code.sock' ]"
as human:operator;  R="$(sendcode claude-code "$V" "$CODE")"; eq "T2: a non-gateway caller is rejected (unauthorized)" "$(reply_reason "$R")" unauthorized
as role:aib-agent;  R="$(sendcode claude-code "$V" "$CODE")"; eq "T2: an agent role account is rejected (unauthorized)" "$(reply_reason "$R")" unauthorized
as gateway:gw
R="$(sendcode claude-code deadbeefdeadbeefdeadbeefdeadbeef "$CODE")"; eq "T2: a wrong vorgang => vorgang_unknown" "$(reply_reason "$R")" vorgang_unknown
R="$(sendcode claude-code "$V" 'bad code!')"; eq "T2: a code outside the charset => bad_code" "$(reply_reason "$R")" bad_code
R="$(sendcode claude-code "$V" "$(head -c 300 /dev/zero | tr '\0' a)")"; eq "T2: an over-long code => bad_code" "$(reply_reason "$R")" bad_code
R="$(sendcode claude-code "$V" "$CODE" 120)"; eq "T2: a code older than the 60 s freshness => stale" "$(reply_reason "$R")" stale
eq "T2: nothing was typed into the PTY by any rejected attempt" "$(test -f "$FP/cli.log" && echo called)|$(wc -c < "$FP/typed.log" | tr -d ' ')" "called|0"
eq "T2: the rejections are audited with reasons, the vorgang and the caller; the code is not" "$(ev login.code_rejected)|$(evf login.code_rejected reason 1)|$(evf login.code_rejected reason 5)|$(evf login.code_rejected reason 6)" "6|unauthorized|bad_code|stale"
eq "T2: …and the unit is still waiting" "$(kill -0 "$UPID" 2>/dev/null && echo waiting)" waiting
R="$(sendcode claude-code "$V" "$CODE")"; eq "T2: after all that the right code still works (rejections do not consume)" "$(reply_ok "$R" && echo ok)" ok
uwait 15; eq "T2: …and the unit succeeds" "$URC" 0
eq "T2: no code in any capture after the rejections either" "$URC|$(leaks "$CODE" "$CLOG" "$OUTBOX" "$LSTAT" "$LROOT" "$LSTATE" "$W/unit.out" "$W/unit.err")" "0|0"

# --- T3 vorgang ids are single-use across runs ---------------------------------------------------------------------------------------------------------
V1="$V"; fresh; lreq claude-code human:operator >/dev/null; ustart claude-code
uwf 15 has_vorg claude-code; V2="$(vorg claude-code)"; uwf 10 bash -c "[ -S '$LSOCK/login-claude-code.sock' ]"; as gateway:gw
eq "T3: a new run mints a new vorgang id" "$([ -n "$V2" ] && [ "$V1" != "$V2" ] && echo new)" new
R="$(sendcode claude-code "$V1" "$CODE")"; eq "T3: the previous run's id is rejected" "$(reply_reason "$R")" vorgang_unknown
R="$(sendcode claude-code "$V2" "WRONG-CODE")"; eq "T3: a well-formed but wrong code is accepted by the channel (the CLI judges it)" "$(reply_ok "$R" && echo ok)" ok
uwait 15
eq "T3: …the CLI rejects it: login.failed cli_failed, exit 1, store untouched" "$URC|$(evf login.failed reason)|$(ls "$LROOT/claude-code" | wc -l | tr -d ' ')" "1|cli_failed|0"
eq "T3: …a server alarm login_failed was raised" "$(son login_failed)" 1

# --- T4 the vorgang window --------------------------------------------------------------------------------------------------------------------------------
fresh; lreq claude-code human:operator >/dev/null; ustart claude-code AIB_LOGIN_WINDOW_S=1
uwait 15
eq "T4: no code within the window => exit 1, login.failed reason=timeout" "$URC|$(evf login.failed reason)" "1|timeout"
eq "T4: …a login_failed alarm with reason:timeout, the CLI process is gone, the store is untouched, no socket left" "$(SO | grep -c 'alarm:login_failed provider:claude-code reason:timeout')|$(kill -0 "$(cat "$FP/cli.pid" 2>/dev/null)" 2>/dev/null && echo alive || echo dead)|$(ls "$LROOT/claude-code" | wc -l | tr -d ' ')|$([ ! -e "$LSOCK/login-claude-code.sock" ] && echo gone)" "1|dead|0|gone"

# --- T4b a login CLI that cannot start: a terminal login.failed reason=cli_missing with an alarm, never a traceback or "timeout" ----------------------
for pv in claude-code:AIB_CLAUDE_BIN codex:AIB_CODEX_BIN; do
  p="${pv%%:*}"; var="${pv##*:}"
  fresh; lreq "$p" human:operator >/dev/null; ustart "$p" "$var=$W/no-such-cli"; uwait 15
  eq "T4b: $p with a missing CLI => exit 1, login.failed reason=cli_missing, a matching alarm, store untouched" "$URC|$(evf login.failed reason)|$(SO | grep -c "alarm:login_failed provider:$p reason:cli_missing")|$(ls "$LROOT/$p" 2>/dev/null | wc -l | tr -d ' ')" "1|cli_missing|1|0"
  has "T4b: …stderr names the binary that could not run" "$(cat "$W/unit.err" 2>/dev/null)" "cannot run $W/no-such-cli"
  hasnt "T4b: …and carries no traceback" "$(cat "$W/unit.err" 2>/dev/null)" "Traceback"
done
fresh; lreq claude-code human:operator >/dev/null; ustart claude-code AIB_LOGIN_WINDOW_S=1800
uwf 15 has_vorg claude-code
eq "T4: the default window is 30 min (alarm expires_at ~1800 s ahead)" "$(SO | grep -o 'expires_at:[^ ]*' | head -1 | cut -d: -f2- | xargs -I{} date -u -d {} +%s | awk -v n="$(date +%s)" '{d=$1-n; print (d>1700 && d<=1800)?"ok":"bad:" d}')" ok
ulife_stop

# --- T5 codex device flow ---------------------------------------------------------------------------------------------------------------------------------
fresh; lreq codex human:operator >/dev/null; ustart codex
uwait 15
line="$(SO | grep 'alarm:login_required provider:codex' | head -1)"
has "T5: the alarm carries URL and user code" "$line" "alarm:login_required provider:codex url:https://auth.example.test/device user_code:ABCD-EFGH"
hasnt "T5: …and no vorgang (no return path)" "$line" "vorgang:"
eq "T5: no socket was ever needed; the unit exits 0; auth.json published 0640 with the CLI's content" "$URC|$(ls "$LSOCK" | grep -c 'login-codex')|$(mode_of "$LROOT/codex/auth.json")|$(grep -c "jwt-$SENT" "$LROOT/codex/auth.json")" "0|0|640|1"
eq "T5: login.started + login.succeeded audited, meta written with the account id" "$(ev login.started)|$(ev login.succeeded)|$(python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["account_id"])' "$LROOT/codex/login.meta.json" 2>/dev/null)" "1|1|acct-0000d00d"
eq "T5: the CLI argv was exactly 'login --device-auth'" "$(grep -c '^argv=login --device-auth ' "$FP/cli.log")" 1

# --- T6 gateway start gating: due-only, 1/h ---------------------------------------------------------------------------------------------------------------
gate() { # gate <state> -> the unit's rc for a gateway request
  local saved_rate=""; [ ! -f "$LSTATE/start-claude-code.json" ] || saved_rate="$(cat "$LSTATE/start-claude-code.json")"
  fresh; [ -z "$saved_rate" ] || printf '%s' "$saved_rate" > "$LSTATE/start-claude-code.json"
  lreq claude-code gateway:gw gateway-peer:hub1 >/dev/null
  [ "$1" = none ] || printf '{"provider":"claude-code","state":"%s","expires_at":null,"label":"","id_hint":"","checked_at":"x"}' "$1" > "$LSTAT/claude-code.json"
  ustart claude-code AIB_LOGIN_WINDOW_S=1 AIB_LOGIN_NOW="${2:-$LNOW}"; uwait 15
}
gate ok; eq "T6: a gateway request on a healthy login => login.rejected not_due, exit 0 (v3.4 K8: a policy rejection is no unit failure), CLI not called" "$URC|$(evf login.rejected reason)|$(evf login.rejected caller)|$(test -f "$FP/cli.log" && echo called || echo uncalled)" "0|not_due|gateway:gw|uncalled"
for s in expiring expired absent none; do rm -rf "${LSTATE:?}"/*; gate $s; eq "T6: …state '$s' is due: the login starts" "$(ev login.started)|$(ev login.rejected)" "1|0"; done
rm -rf "${LSTATE:?}"/*; gate expiring "$LNOW"; gate expiring $(( LNOW + 100 ))
eq "T6: a second gateway start within the hour => rate_limited (exit 0 per v3.4 K8, no CLI call)" "$URC|$(evf login.rejected reason)" "0|rate_limited"
gate expiring $(( LNOW + 3600 )); eq "T6: …after AIB_LOGIN_START_INTERVAL_S it is allowed again" "$(ev login.started)" 1
rm -rf "${LSTATE:?}"/*; gate ok; gate expiring; eq "T6: a not_due rejection does not consume the hourly slot" "$(ev login.started)" 1
fresh; lreq claude-code human:operator >/dev/null; printf '{"provider":"claude-code","state":"ok","expires_at":null,"label":"","id_hint":"","checked_at":"x"}' > "$LSTAT/claude-code.json"
ustart claude-code AIB_LOGIN_WINDOW_S=1; uwait 15
eq "T6: a HUMAN may log in again even when the login is healthy" "$(ev login.started)|$(ev login.rejected)" "1|0"

# --- T7 agentctl login status ------------------------------------------------------------------------------------------------------------------------------
fresh; deploy_accounts '{"claude-code":{"label":"Interim: PO account"}}'
printf '{"provider":"claude-code","state":"expiring","expires_at":"2026-12-01T00:00:00Z","label":"stale label","id_hint":"c0de","checked_at":"x"}' > "$LSTAT/claude-code.json"
chmod 000 "$LROOT/claude-code"
lrun -- "$ENGINE/bin/agentctl" login status claude-code
eq "T7: status prints the JSON object (label from the CURRENT deployment config), reads nothing from the store" "$RC|$(printf '%s' "$OUT" | python3 -I -c 'import json,sys;d=json.loads(sys.stdin.read());print(d["provider"],d["state"],d["expires_at"],d["account_label"],d["account_id_hint"],sorted(d)==sorted(["provider","state","expires_at","account_label","account_id_hint"]))' 2>/dev/null)" "0|claude-code expiring 2026-12-01T00:00:00Z Interim: PO account c0de True"
chmod 750 "$LROOT/claude-code"
lrun -- "$ENGINE/bin/agentctl" login status codex
eq "T7: a provider without a status file is state absent" "$RC|$(printf '%s' "$OUT" | python3 -I -c 'import json,sys;d=json.loads(sys.stdin.read());print(d["state"],d["expires_at"],repr(d["account_label"]))' 2>/dev/null)" "0|absent None ''"
lrun -- "$ENGINE/bin/agentctl" login status
eq "T7: without a provider: one JSON object per line for every status file" "$(printf '%s\n' "$OUT" | grep -c '^{')" 1
lrun -- "$ENGINE/bin/agentctl" login status nope; eq "T7: an unknown provider => 64" "$RC" 64
eq "T7: no token in the output" "$RC|$(printf '%s%s' "$OUT" "$ERR" | grep -c "$SENT")" "64|0"

# --- T8 agentctl login start -----------------------------------------------------------------------------------------------------------------------------------
cat > "$W/fakes/systemctl" <<'FAKE'
#!/usr/bin/env bash
w=$(cd -P "$(dirname "$0")/.." && pwd); printf '%s\n' "$*" >> "$w/systemctl.log"
ans=$(cat "$w/unit.answer" 2>/dev/null)
[ -z "$ans" ] || python3 -I - "$w/standup/_control.jsonl" "$ans" <<'PY'
import json, sys, fcntl
p, ev = sys.argv[1], sys.argv[2]
lock = open(p + ".lock", "a"); fcntl.flock(lock, fcntl.LOCK_EX)
rs = [json.loads(l) for l in open(p) if l.strip()]
req = [r for r in rs if r["event"] == "login.requested"][-1]
rec = {"seq": max(r["seq"] for r in rs) + 1, "ts": "2026-01-01T00:00:00Z", "event": ev, "req": req["seq"], "provider": req["provider"], "caller": req["caller"], "reason": "not_due"}
open(p, "a").write(json.dumps(rec) + "\n")
PY
exit 0
FAKE
chmod +x "$W/fakes/systemctl"
st_run() { fresh; as "$1"; : > "$W/systemctl.log"; [ -z "${2:-}" ] && rm -f "$W/unit.answer" || echo "$2" > "$W/unit.answer"; lrun AIB_CTL_WAIT_S=1 -- "$ENGINE/bin/agentctl" login start "${3:-claude-code}"; }
st_run human:operator login.started
eq "T8: human: login.requested audited (provider, caller), the unit started, rc 0 on login.started" "$RC|$(cf login.requested -1 provider)|$(cf login.requested -1 caller)|$(syslog)" "0|claude-code|human:operator|start aib-login@claude-code.service"
st_run human:operator login.rejected;  eq "T8: login.rejected from the unit => rc 77" "$RC" 77
st_run human:operator login.failed;    eq "T8: login.failed from the unit => rc 69" "$RC" 69
st_run human:operator "";              eq "T8: no terminal record in time => rc 124 (the request stays audited)" "$RC|$(ev login.requested)" "124|1"
st_run gateway:gw login.started;       eq "T8: a gateway caller may request a login" "$RC|$(cf login.requested -1 caller)" "0|gateway:gw"
st_run role:aib-agent login.started;   eq "T8: an agent role account may NOT (77), nothing started, ctl.rejected audited" "$RC|$(syslog | wc -l | tr -d ' ')|$(ev ctl.rejected)|$(cf ctl.rejected -1 reason)" "77|0|1|unauthorized"
st_run human:operator login.started nope; eq "T8: an unknown provider => 64, nothing started" "$RC|$(syslog | wc -l | tr -d ' ')" "64|0"

# --- T9 unit texts ------------------------------------------------------------------------------------------------------------------------------------------------
SVC="$SRC_ROOT/deploy/systemd/aib-login@.service"; sv() { grep -v '^[[:space:]]*#' "$SVC" 2>/dev/null; }
eq "T9: aib-login@.service: Type=simple, User=aib-broker, OnFailure alarm" "$(sv | grep -cx -e 'Type=simple' -e 'User=aib-broker' -e 'OnFailure=aib-alarm@%n.service')" 3
case "$(sv | grep '^ExecStart=' | head -1)" in ExecStart=/*/bin/aib-login\ %i) ok "T9: ExecStart= absolute path to bin/aib-login %i";; *) no "T9: ExecStart= absolute path to bin/aib-login %i";; esac
eq "T9: StandardOutput/StandardError are not a TTY capture of the PTY (no StandardInput=tty)" "$([ -f "$SVC" ] && sv | grep -c '^StandardInput=tty')" 0
eq "T9: NO RuntimeDirectory= (v3.4 K3: systemd would delete the shared /run/aib on every stop; it was pinned =aib before); no credential-looking Environment=" "$([ -f "$SVC" ] && sv | grep -c '^RuntimeDirectory=')|$(sv | grep -ciE '^Environment=.*(TOKEN|KEY|SECRET|PASSWORD|CODE)')" "0|0"

# =====================================================================================================================================
# Gate round 1 delta (v3.4): K3 (units), K4 (device-auth streams), K8 (rc 0 for policy outcomes), M1 (accepted-connection timeout),
# Dexter (PTY capture mode), Marvin G4 (tty echo off while the code is typed).
# =====================================================================================================================================

# --- T10 (K3) none of the login machinery's units may own /run/aib --------------------------------------------------------------------------
for u in aib-login@.service aib-login-refresh@.service aib-login-watch.service; do
  eq "T10: $u has no RuntimeDirectory= (systemd would remove the shared /run/aib on stop)" "$([ -f "$SRC_ROOT/deploy/systemd/$u" ] && grep -v '^[[:space:]]*#' "$SRC_ROOT/deploy/systemd/$u" | grep -c '^RuntimeDirectory')|$([ -f "$SRC_ROOT/deploy/systemd/$u" ] && echo present)" "0|present"
done

# --- T11 (K8) no request / policy rejections are exit 0 with an audit record -------------------------------------------------------------
fresh; ustart claude-code AIB_LOGIN_WINDOW_S=1; uwait 15
eq "T11: a start without any login.requested record => exit 0, no CLI call, ONE audit record login.rejected reason=no_request" "$URC|$(test -f "$FP/cli.log" && echo called || echo uncalled)|$(ev login.rejected)|$(evf login.rejected reason)" "0|uncalled|1|no_request"

# --- T12 (M1) a silent connection cannot block the code socket ------------------------------------------------------------------------------
fresh; lreq claude-code human:operator >/dev/null; ustart claude-code
uwf 15 has_vorg claude-code; V="$(vorg claude-code)"; uwf 10 bash -c "[ -S '$LSOCK/login-claude-code.sock' ]"; as gateway:gw
python3 -I - "$LSOCK/login-claude-code.sock" <<'PY' &
import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); time.sleep(8)      # connects and sends nothing
PY
HOLD=$!; sleep 0.5
t0=$(date +%s); R="$(sendcode claude-code "$V" "$CODE")"; t1=$(date +%s)
eq "T12: …while a peer sits silent on the socket, the right code is still accepted within 8 s" "$(reply_ok "$R" && echo ok)|$([ $(( t1 - t0 )) -le 8 ] && echo prompt)" "ok|prompt"
kill "$HOLD" 2>/dev/null; wait "$HOLD" 2>/dev/null; uwait 15

# --- T13 (Dexter) PTY capture file: never world/group readable ---------------------------------------------------------------------------
cap="$LSTATE/claude-code.pty.log"
eq "T13: the PTY capture file (if kept) is mode 0600 (it holds a live authorize URL with state + challenge)" "$(if test -f "$cap"; then mode_of "$cap"; else echo nofile; fi | sed 's/^nofile$/600/')" 600

# --- T14 (Marvin G4) the tty echo is OFF while the code is typed ---------------------------------------------------------------------------
fresh; lreq claude-code human:operator >/dev/null; rm -f "$FP/echo.log"; ustart claude-code
uwf 15 has_vorg claude-code; V="$(vorg claude-code)"; uwf 10 bash -c "[ -S '$LSOCK/login-claude-code.sock' ]"; as gateway:gw
R="$(sendcode claude-code "$V" "$CODE")"; uwait 15
eq "T14: the CLI's controlling tty had echo disabled when it read the code" "$(tr -d '\n' < "$FP/echo.log" 2>/dev/null)" "-echo"

# --- T15 (K4) codex device-auth streams: the alarm exists WHILE the CLI runs; the window kills the process group -------------------------
cat > "$W/fakes/codex-slow" <<FAKE
#!/usr/bin/env bash
fp="$FP"; echo \$\$ > "\$fp/slow.pid"
printf '\033[1;36mhttps://auth.example.test/device\033[0m\n'
printf 'Enter the code \033[1mABCD-EFGH\033[0m\n'
sleep 300 &
echo \$! > "\$fp/slow.child"
wait
FAKE
chmod +x "$W/fakes/codex-slow"
fresh; rm -f "$FP/slow.pid" "$FP/slow.child"; lreq codex human:operator >/dev/null
ustart codex AIB_CODEX_BIN="$W/fakes/codex-slow" AIB_LOGIN_WINDOW_S=4
uwf 3 bash -c "SO() { cat '$OUTBOX/_server/outbox.md' 2>/dev/null; }; SO | grep -q 'alarm:login_required provider:codex'"
line="$(SO | grep 'alarm:login_required provider:codex' | tail -1)"
alive=""; [ -s "$FP/slow.pid" ] && kill -0 "$(cat "$FP/slow.pid")" 2>/dev/null && alive=running
eq "T15: the login_required alarm (ANSI-stripped URL + user code) was raised while the CLI was still running" "$alive|$(printf '%s' "$line" | grep -c 'url:https://auth.example.test/device user_code:ABCD-EFGH$')" "running|1"
uwait 15
sleep 0.3
eq "T15: at the window end the unit exits 1 with login.failed reason=timeout" "$URC|$(evf login.failed reason)|$(son login_failed)" "1|timeout|1"
eq "T15: …and the whole process group is gone (the CLI AND its child)" "$(kill -0 "$(cat "$FP/slow.pid" 2>/dev/null)" 2>/dev/null && echo cli-alive || echo cli-dead)|$(kill -0 "$(cat "$FP/slow.child" 2>/dev/null)" 2>/dev/null && echo child-alive || echo child-dead)" "cli-dead|child-dead"
eq "T15: …store untouched" "$(ls -A "$LROOT/codex" | wc -l | tr -d ' ')" 0
kill "$(cat "$FP/slow.child" 2>/dev/null)" "$(cat "$FP/slow.pid" 2>/dev/null)" 2>/dev/null; true     # a RED run must not leave the fake behind

# --- T16 (K6) the code socket belongs to the gateway group, mode 0660 -----------------------------------------------------------------------
# Socket group = AIB_LOGIN_SOCK_GROUP (a group name or a numeric gid), default `aib-gateway` (only gateway accounts, never a role account or a human).
eq "T16: the unit's default socket group is named aib-gateway" "$(grep -c 'aib-gateway' "$UNIT_BIN" 2>/dev/null | awk '{print ($1>0)?"named":"absent"}')" named
other_group=""; for g in $(id -G); do [ "$g" != "$(id -g)" ] && { other_group="$g"; break; }; done
if [ -z "$other_group" ]; then
  printf 'ok   - (skipped: the test user has no supplementary group, so a socket group different from its primary one cannot be shown here)\n'
else
  fresh; lreq claude-code human:operator >/dev/null; ustart claude-code AIB_LOGIN_SOCK_GROUP="$other_group"
  uwf 15 has_vorg claude-code; uwf 10 bash -c "[ -S '$LSOCK/login-claude-code.sock' ]"
  eq "T16: the socket is 0660 and its group is the configured one (not the unit's primary group)" "$(stat -c '%a %g' "$LSOCK/login-claude-code.sock" 2>/dev/null)" "660 $other_group"
  ulife_stop
fi
if [ "$(id -u)" -ne 0 ] || ! command -v setpriv >/dev/null 2>&1; then
  printf 'ok   - (skipped: needs root and setpriv - the two-uid socket reachability test runs on the VM)\n'
else
  # broker uid 64211, gateway group 64212 (member uid 64213), an unrelated uid 64214.
  # The unit must itself be a member of the gateway group (production: SupplementaryGroups=aib-gateway): chown(socket, -1, gid) by a non-root
  # process only works for a group it is in. Without --groups the unit hit EPERM, which the bind block's `except OSError` turns into login.failed timeout.
  fresh; chmod -R a+rwX "$WORK" 2>/dev/null; chmod a+x "$W/fakes/claude"; lreq claude-code human:operator >/dev/null
  env -i PATH="$W/fakebin:$PATH" HOME="$W/home-login" LANG=C TZ=UTC "${LENV[@]}" AIBOBNET_REGISTRY="$ENGINE/registry.json" AIB_LOGIN_SOCK_GROUP=64212 \
    setpriv --reuid=64211 --regid=64211 --groups=64212 "$UNIT_BIN" claude-code >"$W/unit.out" 2>"$W/unit.err" & UPID=$!
  uwf 15 bash -c "[ -S '$LSOCK/login-claude-code.sock' ]"
  conn() { setpriv --reuid="$1" --regid="$2" --clear-groups python3 -I -c 'import socket,sys
s=socket.socket(socket.AF_UNIX)
try:
    s.connect(sys.argv[1]); print("connected")
except PermissionError:
    print("denied")
except Exception as e:
    print(type(e).__name__)' "$LSOCK/login-claude-code.sock"; }
  eq "T16 (VM, two uids): a member of the gateway group connects; an unrelated uid is denied" "$(conn 64213 64212)|$(conn 64214 64214)" "connected|denied"
  ulife_stop
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
