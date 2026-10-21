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
#   Design v3.7.1 (gate round 1) changes, all pinned here:
#   Q1  names are <provider>.<seq>.<8 hex>.req (agentctl adds 8 random hex chars and retries O_EXCL on EEXIST, so a pre-created name cannot block it); the
#       unit scans at most 1024 entries, REMOVES every entry that is unusable (symlink, FIFO, empty dir, wrong name, content seq != name seq, owner not
#       human:/gateway:, or owner uid in AIB_ROLE_UIDS) when it can, skips (never counts) what it cannot remove, chooses the newest only among AUTHORIZED
#       entries; none => login.rejected reason=no_request; scan limit hit before an authorized entry => login.failed reason=spool_full + alarm.
#   Q3  a request older than AIB_LOGIN_REQ_MAX_AGE_S (default 600 s, by mtime) is removed and never used.
#   Q4  a request owned by a uid in AIB_ROLE_UIDS is refused and removed whatever identity_for says (EnvironmentFile=-/etc/aib/role.env on the unit: s1c_deploy).
#   Q6  exact scan boundary, a symlinked spool dir => reason=spool, content seq != name seq => unusable.
#   FLIPS vs the first v3.7 pin (each marked "FLIPPED" below): 64 -> 1024 entries; a non-human/gateway owner is now `no_request` + removed (was
#   `unauthorized` with the caller recorded); old-form names <provider>.<seq>.req are wrong names; a planted name no longer blocks agentctl.
#
#   Expected on the v3.7 tree (aee50d4): names without the random part, 64-entry bound, unauthorized rejection, no expiry, no role-uid check.
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
LENV+=(AIB_CODEX_BIN="$W/fakes/codex" AIB_LOGIN_WINDOW_S=30 AIB_LOGIN_START_INTERVAL_S=3600 AIB_LOGIN_REQ_MAX_AGE_S=999999999)
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
nspool() { ls -A "$LREQ" 2>/dev/null | wc -l | tr -d ' '; }
# spool_bulk <kind> <n> — n unusable-but-present entries: junkfile (wrong-named plain files, removable) | fulldir (non-empty directories: NOT removable by the unit)
spool_bulk() { python3 -I - "$LREQ" "$1" "$2" <<'PY'
import os, sys
d, kind, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
for i in range(n):
    p = os.path.join(d, "%s%d" % ("junk." if kind == "junkfile" else "dir", i))
    if kind == "junkfile": open(p, "w").close()
    else: os.mkdir(p); open(os.path.join(p, "x"), "w").close()
PY
}
# age_file <path> <seconds> — set the mtime that many seconds into the past
age_file() { python3 -I -c 'import os,sys,time; t=time.time()-float(sys.argv[2]); os.utime(sys.argv[1], (t, t))' "$1" "$2"; }
only_req() { ls -A "$LREQ" | grep -E '^codex\.[0-9]+\.[0-9a-f]{8}\.req$'; }

# --- T1 (P1) agentctl creates the request file --------------------------------------------------------------------------------------------------------
fresh; as human:operator
lrun AIB_CTL_WAIT_S=0.3 -- "$AGENTCTL" login start codex
seq="$(evf login.requested seq)"
eq "T1: exactly one spool file <provider>.<seq>.<8 hex>.req (v3.7.1 Q1), seq = the audit record's seq" "$(spool_files | sed -E "s/^codex\.$seq\.[0-9a-f]{8}\.req \$/codex.$seq.RAND.req/")" "codex.$seq.RAND.req"
f="$LREQ/$(only_req)"
eq "T1: …a regular file, mode 0644, owned by the caller" "$([ -f "$f" ] && [ ! -L "$f" ] && echo regular)|$(mode_of "$f")|$(stat -c %u "$f" 2>/dev/null)" "regular|644|$ME_UID"
eq "T1: …content is exactly {seq, provider}: no caller, no actor" "$(python3 -I -c 'import json,sys;d=json.load(open(sys.argv[1]));print(sorted(d), d["seq"]==int(sys.argv[2]), d["provider"])' "$f" "$seq" 2>/dev/null)" "['provider', 'seq'] True codex"
eq "T1: …and the audit record login.requested is still in the log with the caller" "$(ev login.requested)|$(evf login.requested caller)" "1|human:operator"
# FLIPPED (v3.7.1 Q1): a name planted in the spool can no longer block agentctl - the random part makes the name unpredictable (and EEXIST is retried up to
# 5 times). The first v3.7 pin expected a failure (rc != 0, nothing started) when a symlink/file sat at <provider>.<seq>.req; now the start goes ahead, the
# planted entries are neither followed nor overwritten, and the new request file is created next to them.
# (The EEXIST retry itself needs a randomness seam and cannot be driven from outside; not pinned.)
fresh; as human:operator; forge login.requested 0 human:operator codex >/dev/null; next=$(( $(evf login.requested seq 0) + 1 )); : > "$W/systemctl.log"
ln -s "$WORK/symlink-target" "$LREQ/codex.$next.req"; printf 'PLANTED' > "$LREQ/codex.$next.deadbeef.req.keep"
lrun AIB_CTL_WAIT_S=0.3 -- "$AGENTCTL" login start codex
eq "T1: planted entries at/near the request name do not block the start: the unit is started, a fresh request file exists, nothing was followed or overwritten" "$(syslog | grep -c '^start ')|$(only_req | wc -l | tr -d ' ')|$([ -e "$WORK/symlink-target" ] && echo created || echo untouched)|$(cat "$LREQ/codex.$next.deadbeef.req.keep")" "1|1|untouched|PLANTED"
fresh; as human:operator; lrun AIB_CTL_WAIT_S=0.3 -- "$AGENTCTL" login start codex; a1="$(only_req)"; lrun AIB_CTL_WAIT_S=0.3 -- "$AGENTCTL" login start codex; a2="$(only_req | grep -vxF "$a1")"
eq "T1: two starts give two distinct files whose random parts differ" "$(printf '%s\n%s\n' "$a1" "$a2" | sed -E 's/^codex\.[0-9]+\.//; s/\.req$//' | sort -u | wc -l | tr -d ' ')" 2
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

# --- T3 (P2, FLIPPED by v3.7.1 Q1) entries of a caller that may not log in are unusable: removed, and the result is no_request --------------------------
# The first v3.7 pin expected `login.rejected reason=unauthorized` with the caller recorded for a role/unknown owner. Q1: an entry whose owner maps to anything but
# human:/gateway: is removed like any junk and the newest is chosen among AUTHORIZED entries only; with none left the answer is reason=no_request. (The reason
# `unauthorized` stays for nothing in the spool path.) Reason for the flip: a rejection per junk file would let any local account spam audit records and
# alarms; removal keeps the spool usable.
for who in role:aib-agent unknown:$ME_UID; do
  fresh; as "$who"; spool_put codex 3
  urun codex
  eq "T3: owner identity '$who' => entry removed, login.rejected reason=no_request, CLI not called" "$URC|$(cli_called)|$(evf login.rejected reason)|$(nspool)" "0|uncalled|no_request|0"
done
fresh; : > "$IDMAP"; spool_put codex 3
urun codex
eq "T3: an owner uid the identity command cannot resolve (unknown:<uid>) => removed, no_request" "$(cli_called)|$(evf login.rejected reason)|$(nspool)" "uncalled|no_request|0"

# --- T3b (Q4) a uid in AIB_ROLE_UIDS is refused by uid, whatever the identity command says --------------------------------------------------------------
fresh; as human:operator; spool_put codex 3
urun codex AIB_ROLE_UIDS="$ME_UID,60001"
eq "T3b: our uid is a role uid (AIB_ROLE_UIDS) although identity_for says human:operator => removed, no_request, CLI not called" "$(cli_called)|$(evf login.rejected reason)|$(nspool)" "uncalled|no_request|0"
fresh; as gateway:gw; spool_put codex 3
urun codex AIB_ROLE_UIDS="60001,$ME_UID"
eq "T3b: …also for a gateway-mapped uid, and wherever it sits in the list" "$(cli_called)|$(evf login.rejected reason)" "uncalled|no_request"
fresh; as human:operator; spool_put codex 3
urun codex AIB_ROLE_UIDS="60001,$(( ME_UID + 1 )),1${ME_UID}"
eq "T3b: guard — a list that does not contain our uid (neighbours and a textual superset only) does not refuse" "$(cli_called)|$(evf login.started req)" "called|3"
fresh; as human:operator; spool_put codex 3
urun codex AIB_ROLE_UIDS=
eq "T3b: guard — an empty AIB_ROLE_UIDS refuses nothing" "$(cli_called)" called

# --- T4 (P2) which entries count ----------------------------------------------------------------------------------------------------------------------------
fresh; as human:operator; spool_put codex 3; spool_put codex 7; spool_put codex 10; spool_put codex 9; spool_put claude-code 12
urun codex
eq "T4: the newest by NUMERIC seq wins (10 over 9 and 7)" "$(evf login.started req)|$(cli_called)" "10|called"
eq "T4: …every codex request file it read is unlinked (older ones too); another provider's file stays" "$(spool_files | sed -E 's/\.[0-9a-f]{8}\.req/.RAND.req/')" "claude-code.12.RAND.req "
fresh; as human:operator; spool_put claude-code 5
urun codex
eq "T4: a request for another provider is not served by this unit (no_request) and is left alone" "$(cli_called)|$(evf login.rejected reason)|$(spool_files | sed -E 's/\.[0-9a-f]{8}\.req/.RAND.req/')" "uncalled|no_request|claude-code.5.RAND.req "
fresh; as human:operator
printf '{"seq":5,"provider":"codex"}' > "$WORK/real.req"
ln -s "$WORK/real.req" "$LREQ/codex.5.deadbeef.req"
urun codex
eq "T4: a SYMLINK named like a request is not a request (even to a valid file we own): no_request, CLI not called; the link is removed, its target is not" "$(cli_called)|$(evf login.rejected reason)|$(nspool)|$([ -e "$WORK/real.req" ] && echo target-kept)" "uncalled|no_request|0|target-kept"
fresh; as human:operator; mkdir "$LREQ/codex.5.deadbeef.req"
urun codex
eq "T4: an EMPTY directory named like a request is not a request and is removed (Q1)" "$(cli_called)|$(evf login.rejected reason)|$(nspool)" "uncalled|no_request|0"
fresh; as human:operator; mkdir "$LREQ/codex.5.deadbeef.req"; : > "$LREQ/codex.5.deadbeef.req/x"; spool_put codex 6
urun codex
eq "T4: a NON-empty directory cannot be removed: it is skipped (not served, not fatal) and the real request beside it is served" "$(cli_called)|$(evf login.started req)|$([ -d "$LREQ/codex.5.deadbeef.req" ] && echo dir-left)" "called|6|dir-left"
fresh; as human:operator
for n in codex.5.req codex.abc.deadbeef.req codex.5.deadbeef.txt .codex.5.deadbeef.req codex.5.deadbeef.req~ codex.-5.deadbeef.req codex.5.6.deadbeef.req codex..deadbeef.req codexx.5.deadbeef.req codex.5.deadbeef.req.bak codex.5.DEADBEEF.req codex.5.deadbee.req codex.5.deadbeef0.req codex.5.deadbeeg.req; do printf '{"seq":5,"provider":"codex"}' > "$LREQ/$n"; done
urun codex
eq "T4: names that are not <provider>.<decimal>.<8 lowercase hex>.req (incl. the old two-part form) are wrong names: no_request, CLI not called, all removed" "$(cli_called)|$(evf login.rejected reason)|$(nspool)" "uncalled|no_request|0"
fresh; as human:operator; mkfifo "$LREQ/codex.5.deadbeef.req"
urun codex
eq "T4: a FIFO named like a request is not a request, does not hang the unit, and is removed" "$URC|$(cli_called)|$(evf login.rejected reason)|$(nspool)" "0|uncalled|no_request|0"
# Q6: the content seq must equal the name's seq
fresh; as human:operator; spool_put codex 5 '{"seq":6,"provider":"codex"}'
urun codex
eq "T4: (Q6) content seq 6 under a file named ...5... => unusable: removed, no_request, CLI not called" "$(cli_called)|$(evf login.rejected reason)|$(nspool)" "uncalled|no_request|0"
fresh; as human:operator; spool_put codex 5 '{"seq":6,"provider":"codex"}'; spool_put codex 4
urun codex
eq "T4: (Q6) …a mismatching file beside a good one: the good one (seq 4) is served" "$(evf login.started req)" 4
# Q3: expiry by mtime
fresh; as human:operator; spool_put codex 3; age_file "$LREQ/$(only_req)" 700
urun codex AIB_LOGIN_REQ_MAX_AGE_S=      # empty = the default (600 s); the spec LENV pins a huge window otherwise
eq "T4: (Q3) a request 700 s old (default max age 600 s) is removed unused: no_request, CLI not called" "$(cli_called)|$(evf login.rejected reason)|$(nspool)" "uncalled|no_request|0"
fresh; as human:operator; spool_put codex 3; age_file "$LREQ/$(only_req)" 500
urun codex AIB_LOGIN_REQ_MAX_AGE_S=
eq "T4: (Q3) …500 s old is within the default window and is served" "$(cli_called)|$(evf login.started req)" "called|3"
fresh; as human:operator; spool_put codex 3; age_file "$LREQ/$(only_req)" 150
urun codex AIB_LOGIN_REQ_MAX_AGE_S=100
eq "T4: (Q3) AIB_LOGIN_REQ_MAX_AGE_S=100: 150 s old is removed" "$(cli_called)|$(evf login.rejected reason)|$(nspool)" "uncalled|no_request|0"
fresh; as human:operator; spool_put codex 3; age_file "$LREQ/$(only_req)" 50
urun codex AIB_LOGIN_REQ_MAX_AGE_S=100
eq "T4: (Q3) …50 s old is served" "$(cli_called)" called
fresh; as human:operator; spool_put codex 3; age_file "$LREQ/$(only_req)" 5000; spool_put codex 4
urun codex AIB_LOGIN_REQ_MAX_AGE_S=
eq "T4: (Q3) an expired older request does not shadow or block a fresh newer one (4 served, both gone)" "$(evf login.started req)|$(nspool)" "4|0"

# --- T5 (P2, FLIPPED by v3.7.1 Q1/Q6) the scan bound is 1024 entries ------------------------------------------------------------------------------
# FLIPPED: the first pin refused a spool of 80 valid requests (bound 64). The bound is now 1024: 80 requests are served (newest wins) and all are consumed.
fresh; as human:operator
for n in $(seq 1 80); do spool_put codex "$n"; done
urun codex
eq "T5: (FLIPPED, was refused at 64) a spool with 80 valid requests is served: the newest (80) starts, every file consumed" "$(cli_called)|$(evf login.started req)|$(nspool)" "called|80|0"
# exact boundary, made deterministic by having NO authorized entry among the junk (directory order is unspecified)
fresh; as human:operator; spool_bulk junkfile 1024
urun codex
eq "T5: (Q6) exactly 1024 junk entries, all scanned => login.rejected no_request (not spool_full), CLI not called" "$([ "$URC" -ne 124 ] && echo bounded)|$(cli_called)|$(evf login.rejected reason)|$(ev login.failed)" "bounded|uncalled|no_request|0"
eq "T5: …and the junk was removed" "$(nspool)" 0
fresh; as human:operator; spool_bulk junkfile 1025
urun codex
eq "T5: (Q6) 1025 junk entries => the limit is hit before any authorized entry: login.failed reason=spool_full, CLI not called, in time" "$([ "$URC" -ne 124 ] && echo bounded)|$(cli_called)|$(evf login.failed reason)" "bounded|uncalled|spool_full"
eq "T5: …with an alarm in the server outbox" "$([ "$(son login_failed)" -ge 1 ] && echo alarm)" alarm
fresh; as human:operator; spool_bulk junkfile 1023; spool_put codex 7
urun codex
eq "T5: (Q6) 1023 junk + 1 authorized = 1024 entries: all scanned, the request is served" "$(cli_called)|$(evf login.started req)" "called|7"
fresh; as human:operator; spool_bulk fulldir 1100; spool_put codex 8
urun codex
eq "T5: (Q1) 1100 non-empty directories (not removable) are skipped and NOT counted against the limit: the request among them is served" "$([ "$URC" -ne 124 ] && echo bounded)|$(cli_called)|$(evf login.started req)" "bounded|called|8"
fresh; as human:operator
for n in $(seq 1 60); do spool_put codex "$n"; done
urun codex
eq "T5: guard — 60 entries are served: the newest (60) starts" "$(cli_called)|$(evf login.started req)" "called|60"

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
fresh; as human:operator; spool_put codex 3; REAL_SPOOL="$WORK/real-spool"; rm -rf "$REAL_SPOOL"; mkdir "$REAL_SPOOL"; setmode "$REAL_SPOOL" 1733; mv "$LREQ/"* "$REAL_SPOOL/"; rmdir "$LREQ"; ln -s "$REAL_SPOOL" "$LREQ"
urun codex
eq "T6: (Q6) the spool path is a SYMLINK to a valid 1733 directory we own => login.failed reason=spool, CLI not called" "$(cli_called)|$(evf login.failed reason)" "uncalled|spool"
rm -f "$LREQ"; mkdir "$LREQ"; setmode "$LREQ" 1733
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
  fresh; printf '%s=role:aib-agent\n%s=human:operator\n' 65534 0 > "$IDMAP"; spool_put codex 5; spool_put codex 9; chown 65534:65534 "$(ls -d "$LREQ"/codex.9.*)"
  urun codex
  eq "T7 (root): (Q1) the NEWEST entry (9, owned by a role uid) is unauthorized and is removed; the newest AUTHORIZED one (5, owned by root->human) is served" "$(evf login.started req)|$(evf login.started caller)|$(nspool)" "5|human:operator|0"
  fresh; printf '%s=human:other\n' 65534 > "$IDMAP"; spool_put codex 5; chown 65534:65534 "$LREQ/"codex.5.*
  urun codex AIB_ROLE_UIDS=65534
  eq "T7 (root): (Q4) a file really owned by a role uid is refused whatever the identity command says (human:other)" "$(cli_called)|$(evf login.rejected reason)" "uncalled|no_request"
  fresh; as human:operator; spool_put codex 3; chown 65534:65534 "$LREQ"; setmode "$LREQ" 1733
  urun codex
  eq "T7 (root): a spool directory owned by someone other than the unit's uid => login.failed reason=spool, CLI not called" "$(cli_called)|$(evf login.failed reason)" "uncalled|spool"
  chown "$ME_UID" "$LREQ"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
