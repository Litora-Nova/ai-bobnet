#!/usr/bin/env bash
# ai-bobnet — RED spec for the login request spool (design v3.7 P1/P2/P3; Riker F1: `_control.jsonl` is appendable by every aib-shared member, so a
# forged `login.requested caller=human:x` used to skip the gateway due/rate gate).
#
# WHAT THIS PINS
#   P1  `agentctl login start <provider>` creates exactly ONE request file  $AIB_LOGIN_REQ_DIR/<provider>.<seq>.req  (seam; default /run/aib/login-requests)
#       with O_CREAT|O_EXCL|O_NOFOLLOW, mode 0644, content {"seq":N,"provider":"<provider>"} (no caller), seq = the seq of the audit record
#       `login.requested`, which is still appended to the log (event shape unchanged). A pre-existing file or symlink at that name is never followed or
#       overwritten: agentctl fails (non-zero), starts nothing. A rejected caller (not human:/gateway:) creates no file.
#   P2  `bin/aib-login <provider>` reads ONLY the spool: regular, non-symlink files named <provider>.<decimal seq>.req (fstat after an O_NOFOLLOW open),
#       newest by numeric seq; the caller is identity_for(st_uid of that file) (AIB_IDENTITY_CMD seam); a `caller` inside the content is ignored.
#       Only `human:` / `gateway:` may log in; anything else => login.rejected reason=unauthorized (CLI not called). The gateway gate (not_due / rate_limited)
#       applies to a gateway:* file owner. Every request file of THAT provider it has read (older ones too) is unlinked; other providers' files stay.
#       At most 64 directory entries are looked at per run: a fuller spool is a refusal with an alarm, never a hang.
#       The spool must exist, be owned by the unit's own uid (the broker) and have mode exactly 1733, else `login.failed reason=spool` + alarm, CLI not called.
#   P3  `_control.jsonl` is NOT read by aib-login: a forged login.requested (any caller), or a forged terminal record for the spool request's seq, has no
#       effect. A spool file without any audit record is served normally.
#
#   Expected on the v3.6 tree: the unit still takes request and caller from the log, agentctl writes no spool file.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/fixtures/login_harness.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-lspool.XXXXXX")"
trap sup_cleanup EXIT
lw_world p
UNIT_BIN="$ENGINE/bin/aib-login"; AGENTCTL="$ENGINE/bin/agentctl"
FP="$WORK/fakeprivate"; mkdir -p "$FP"
cat > "$W/fakes/codex" <<FAKE
#!/usr/bin/env bash
fp="$FP"; printf 'argv=%s\n' "\$*" >> "\$fp/cli.log"
echo "Open https://auth.example.test/device and enter the code ABCD-EFGH"
mkdir -p "\$CODEX_HOME"; printf '{"tokens":{"access_token":"jwt-$SENT","refresh_token":"rt-$SENT","account_id":"acct-0000d00d"}}' > "\$CODEX_HOME/auth.json"
echo "Logged in"
FAKE
chmod +x "$W/fakes/codex"
LENV+=(AIB_CODEX_BIN="$W/fakes/codex" AIB_LOGIN_WINDOW_S=30 AIB_LOGIN_START_INTERVAL_S=3600)
ev() { CL count "$CLOG" "$1"; }
evf() { cf "$1" "${3:--1}" "$2"; }
fresh() { lw_clean; rm -rf "$LROOT/codex/"* "$LROOT/claude-code/"* 2>/dev/null; : > "$CLOG"; rm -f "$FP/cli.log"; as human:operator; }
cli_called() { [ -f "$FP/cli.log" ] && echo called || echo uncalled; }
# urun <provider> [VAR=val...] — the login unit, synchronous, 20 s ceiling (a hang shows as rc 124 and fails the check, not the suite)
urun() { local p="$1"; shift; URC=0; env -i PATH="$W/fakebin:$PATH" HOME="$W/home-login" LANG=C TZ=UTC "${LENV[@]}" AIBOBNET_REGISTRY="$ENGINE/registry.json" "$@" \
  timeout 20 "$UNIT_BIN" "$p" >"$W/unit.out" 2>"$W/unit.err" || URC=$?; }
# forge <event> <req> <caller> [provider] — what any aib-shared member can append to the audit log
forge() { python3 -I - "$CLOG" "$1" "$2" "$3" "${4:-codex}" <<'PY'
import json, sys, fcntl
path, ev, req, caller, prov = sys.argv[1:6]
lock = open(path + ".lock", "a"); fcntl.flock(lock, fcntl.LOCK_EX)
seq = 0
for l in open(path):
    if l.strip(): seq = max(seq, json.loads(l)["seq"])
rec = {"seq": seq + 1, "ts": "2026-01-01T00:00:00Z", "event": ev, "verb": "login-start", "target": prov, "provider": prov, "caller": caller, "actor": "", "req": int(req)}
if ev == "login.requested": rec.pop("req")
open(path, "a").write(json.dumps(rec) + "\n")
PY
}
spool_files() { ls -A "$LREQ" | LC_ALL=C sort | tr '\n' ' '; }

# --- T1 (P1) agentctl creates the request file --------------------------------------------------------------------------------------------------------
fresh; as human:operator
lrun AIB_CTL_WAIT_S=0.3 -- "$AGENTCTL" login start codex
seq="$(evf login.requested seq)"
eq "T1: exactly one spool file <provider>.<seq>.req, seq = the audit record's seq" "$(spool_files)" "codex.$seq.req "
f="$LREQ/codex.$seq.req"
eq "T1: …a regular file, mode 0644, owned by the caller" "$([ -f "$f" ] && [ ! -L "$f" ] && echo regular)|$(mode_of "$f")|$(stat -c %u "$f" 2>/dev/null)" "regular|644|$ME_UID"
eq "T1: …content is exactly {seq, provider}: no caller, no actor" "$(python3 -I -c 'import json,sys;d=json.load(open(sys.argv[1]));print(sorted(d), d["seq"]==int(sys.argv[2]), d["provider"])' "$f" "$seq" 2>/dev/null)" "['provider', 'seq'] True codex"
eq "T1: …and the audit record login.requested is still in the log with the caller" "$(ev login.requested)|$(evf login.requested caller)" "1|human:operator"
# the next request must not reuse or follow anything at its name
fresh; as human:operator; : > "$CLOG"; forge login.requested 0 human:operator codex >/dev/null; next=$(( $(evf login.requested seq 0) + 1 )); : > "$W/systemctl.log"
ln -s "$WORK/symlink-target" "$LREQ/codex.$next.req"
lrun AIB_CTL_WAIT_S=0.3 -- "$AGENTCTL" login start codex
eq "T1: a symlink already sitting at the request name is not followed: rc != 0, its target is not created, the unit is not started" "$([ "$RC" -ne 0 ] && echo failed)|$([ -e "$WORK/symlink-target" ] && echo created || echo untouched)|$(syslog | grep -c '^start ')" "failed|untouched|0"
fresh; as human:operator; forge login.requested 0 human:operator codex >/dev/null; next=$(( $(evf login.requested seq 0) + 1 )); : > "$W/systemctl.log"
printf 'PLANTED' > "$LREQ/codex.$next.req"
lrun AIB_CTL_WAIT_S=0.3 -- "$AGENTCTL" login start codex
eq "T1: a file already at the name is not overwritten (O_EXCL): rc != 0, content kept, unit not started" "$([ "$RC" -ne 0 ] && echo failed)|$(cat "$LREQ/codex.$next.req")|$(syslog | grep -c '^start ')" "failed|PLANTED|0"
fresh; as role:aib-agent
lrun AIB_CTL_WAIT_S=0.3 -- "$AGENTCTL" login start codex
eq "T1: guard — an agent role account is refused (77) and creates no request file" "$RC|$(spool_files)" "77|"

# --- T2 (P3) the core regression: the log can no longer start or skip anything -----------------------------------------------------------------------
fresh; forge login.requested 0 human:x codex
urun codex
eq "T2: a FORGED login.requested caller=human:x in _control.jsonl, empty spool => login.rejected no_request, CLI not called, rc 0" "$URC|$(cli_called)|$(ev login.rejected)|$(evf login.rejected reason)" "0|uncalled|1|no_request"
fresh; printf '{"provider":"codex","state":"ok","expires_at":null,"label":"","id_hint":"","checked_at":"x"}' > "$LSTAT/codex.json"
as gateway:gw; spool_put codex 5; forge login.requested 0 human:x codex
urun codex
eq "T2: a forged human:x record does not lift the gate: the real owner is gateway:gw on a healthy login => not_due, caller gateway:gw, CLI not called" "$URC|$(cli_called)|$(evf login.rejected reason)|$(evf login.rejected caller)" "0|uncalled|not_due|gateway:gw"
fresh; printf '{"provider":"codex","state":"ok","expires_at":null,"label":"","id_hint":"","checked_at":"x"}' > "$LSTAT/codex.json"
as gateway:gw; spool_put codex 5 '{"seq":5,"provider":"codex","caller":"human:x"}'
urun codex
eq "T2: a \`caller\` inside the file content is ignored (owner wins)" "$(cli_called)|$(evf login.rejected reason)|$(evf login.rejected caller)" "uncalled|not_due|gateway:gw"
fresh; as human:operator; spool_put codex 9; forge login.rejected 9 human:operator codex
urun codex
eq "T2: a forged TERMINAL record for the spool request's seq does not suppress it: the login starts" "$(cli_called)|$(evf login.started req)" "called|9"
fresh; as human:operator; spool_put codex 4
urun codex
eq "T2: a spool request with NO audit record is served normally (the audit file is a report stream)" "$URC|$(cli_called)|$(ev login.started)|$(evf login.started caller)" "0|called|1|human:operator"
fresh; as gateway:gw; spool_put codex 6
urun codex
eq "T2: a due gateway request (state absent) starts, caller gateway:gw from the file owner" "$(cli_called)|$(evf login.started req)|$(evf login.started caller)" "called|6|gateway:gw"

# --- T3 (P2) caller from st_uid, nothing but human/gateway may log in --------------------------------------------------------------------------------
for who in role:aib-agent unknown:$ME_UID; do
  fresh; as "$who"; spool_put codex 3
  urun codex
  eq "T3: owner identity '$who' => login.rejected unauthorized, caller recorded, CLI not called" "$URC|$(cli_called)|$(evf login.rejected reason)|$(evf login.rejected caller)|$(evf login.rejected req)" "0|uncalled|unauthorized|$who|3"
done
fresh; : > "$IDMAP"; spool_put codex 3
urun codex
eq "T3: an owner uid the identity command cannot resolve (unknown:<uid>) => unauthorized" "$(cli_called)|$(evf login.rejected reason)" "uncalled|unauthorized"

# --- T4 (P2) which entries count ----------------------------------------------------------------------------------------------------------------------------
fresh; as human:operator; spool_put codex 3; spool_put codex 7; spool_put codex 10; spool_put codex 9; spool_put claude-code 12
urun codex
eq "T4: the newest by NUMERIC seq wins (10 over 9 and 7)" "$(evf login.started req)|$(cli_called)" "10|called"
eq "T4: …every codex request file it read is unlinked (older ones too); another provider's file stays" "$(spool_files)" "claude-code.12.req "
fresh; as human:operator; spool_put claude-code 5
urun codex
eq "T4: a request for another provider is not served by this unit (no_request) and is left alone" "$(cli_called)|$(evf login.rejected reason)|$(spool_files)" "uncalled|no_request|claude-code.5.req "
fresh; as human:operator
printf '{"seq":5,"provider":"codex"}' > "$WORK/real.req"
ln -s "$WORK/real.req" "$LREQ/codex.5.req"
urun codex
eq "T4: a SYMLINK named like a request is not a request (even to a valid file we own): no_request, CLI not called" "$(cli_called)|$(evf login.rejected reason)" "uncalled|no_request"
fresh; as human:operator; mkdir "$LREQ/codex.5.req"
urun codex
eq "T4: a directory named like a request is not a request" "$(cli_called)|$(evf login.rejected reason)" "uncalled|no_request"
fresh; as human:operator
for n in codex.abc.req codex.5.txt .codex.5.req codex.5.req~ codex.-5.req codex.5.6.req codex..req codexx.5.req codex.5.req.bak; do printf '{"seq":5,"provider":"codex"}' > "$LREQ/$n"; done
urun codex
eq "T4: names that are not <provider>.<decimal>.req are ignored (no_request, CLI not called)" "$(cli_called)|$(evf login.rejected reason)" "uncalled|no_request"
fresh; as human:operator; mkfifo "$LREQ/codex.5.req"
urun codex
eq "T4: a FIFO named like a request is not a request and does not hang the unit" "$URC|$(cli_called)|$(evf login.rejected reason)" "0|uncalled|no_request"
rm -f "$LREQ/codex.5.req"

# --- T5 (P2) the 64-entry bound -----------------------------------------------------------------------------------------------------------------------------
fresh; as human:operator
for n in $(seq 1 80); do spool_put codex "$n"; done
urun codex
eq "T5: a spool with 80 entries is a refusal, not a hang: the unit ends in time (rc != 124), CLI not called" "$([ "$URC" -ne 124 ] && echo bounded)|$(cli_called)" "bounded|uncalled"
eq "T5: …with a terminal audit record for codex (login.failed or login.rejected) and an alarm in the server outbox" "$(( $(ev login.failed) + $(ev login.rejected) ))|$([ "$(SO | grep -c 'alarm:')" -ge 1 ] && echo alarm)" "1|alarm"
fresh; as human:operator
for n in $(seq 1 60); do spool_put codex "$n"; done
urun codex
eq "T5: guard — 60 entries (under the bound) are served: the newest (60) starts" "$(cli_called)|$(evf login.started req)" "called|60"

# --- T6 (P2) the spool itself is checked, fail closed -------------------------------------------------------------------------------------------------------
fresh; as human:operator; spool_put codex 3; rmdir_ok=0; rm -rf "$LREQ"
urun codex
eq "T6: a missing spool => login.failed reason=spool, alarm, CLI not called" "$(cli_called)|$(evf login.failed reason)|$([ "$(son login_failed)" -ge 1 ] && echo alarm)" "uncalled|spool|alarm"
mkdir -p "$LREQ"; setmode "$LREQ" 1733
for badmode in 755 777 1777 700 1700 2733 3733; do
  fresh; as human:operator; spool_put codex 3; setmode "$LREQ" "$badmode"
  urun codex
  eq "T6: spool mode $badmode (not exactly 1733) => login.failed reason=spool, CLI not called, request not consumed" "$(cli_called)|$(evf login.failed reason)|$(ls -A "$LREQ" 2>/dev/null | wc -l | tr -d ' ')" "uncalled|spool|1"
  setmode "$LREQ" 1733
done
fresh; as human:operator; spool_put codex 3
urun codex
eq "T6: guard — mode 1733 and our own ownership is accepted" "$(cli_called)|$(ev login.failed)" "called|0"

# --- T7 (P2) VM block: a real foreign owner uid (root only) -----------------------------------------------------------------------------------------------
if [ "$ME_UID" -ne 0 ]; then
  printf 'ok   - (skipped: T7 needs root - real st_uid of another account and a spool dir owned by someone else; run this spec as root on the dev VM)\n'
else
  fresh; printf '{"provider":"codex","state":"ok","expires_at":null,"label":"","id_hint":"","checked_at":"x"}' > "$LSTAT/codex.json"
  printf '%s=gateway:gw\n' 65534 > "$IDMAP"; spool_put codex 5 '{"seq":5,"provider":"codex","caller":"human:x"}'; chown 65534:65534 "$LREQ/codex.5.req"
  forge login.requested 0 human:x codex
  urun codex
  eq "T7 (root): a file really owned by uid 65534 (mapped gateway:gw) is gated as gateway:gw whatever the log and the content say" "$(cli_called)|$(evf login.rejected reason)|$(evf login.rejected caller)" "uncalled|not_due|gateway:gw"
  fresh; printf '%s=human:other\n' 65534 > "$IDMAP"; spool_put codex 5; chown 65534:65534 "$LREQ/codex.5.req"
  urun codex
  eq "T7 (root): …and a file owned by 65534 mapped human:other starts as human:other" "$(cli_called)|$(evf login.started caller)" "called|human:other"
  fresh; as human:operator; spool_put codex 3; chown 65534:65534 "$LREQ"; setmode "$LREQ" 1733
  urun codex
  eq "T7 (root): a spool directory owned by someone other than the unit's uid => login.failed reason=spool, CLI not called" "$(cli_called)|$(evf login.failed reason)" "uncalled|spool"
  chown "$ME_UID" "$LREQ"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
