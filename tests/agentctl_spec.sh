#!/usr/bin/env bash
# ai-bobnet — RED spec for bin/agentctl, the client side of the control plane (Supervisor slice S1b;
# design B7/B10 + v2 amendments F5b/F7/F8). The EXECUTOR side (the supervisor re-checking and acting) is
# tests/supervisor_ctl_spec.sh; the gateway wrapper is tests/aib_gw_spec.sh.
#
# WHAT THIS PINS (interface + exit codes + record shapes: the header of tests/fixtures/ctl_harness.sh)
#   - usage: `agentctl <verb> <uid> [--force] [--hard] [--fresh] [--reason "<text>"]`, verbs status | neustart | feierabend |
#     standup | abschalten | start | reset-brake | say | attach. Unknown verb / bad uid / unknown flag => 64, nothing written,
#     systemctl never called. Unknown or oneshot target => 66. `--hard`/`--fresh` exist for neustart only.
#   - IDENTITY comes from the kernel uid (via AIB_IDENTITY_CMD), never from an argument: AIBOBNET_ACTOR is recorded as the
#     `actor` claim beside `caller`, and no `--caller`/`--as`/`--from` flag exists.
#   - AUDIT BEFORE ACTION: ctl.requested {seq,verb,target,caller,actor,reason,force,hard,fresh} is appended (one flock'ed seq
#     allocator, gap-free even under concurrency) and only THEN the request file `<uid>.<seq>.<verb>` is written. If the audit
#     append fails: exit 73, no request file, no systemctl call.
#   - AUTHORIZATION table (agentctl layer; the supervisor repeats it): status = every known identity; neustart|feierabend|standup =
#     human | gateway | role-account caller whose actor claim names a registry agent with `lead: "true"`; abschalten|start|reset-brake
#     = human only (a gateway and a lead are refused); say|attach = human (say also gateway). Refusals are AUDITED as ctl.rejected
#     (req null) and exit 77, no request file.
#   - `protected` agents (guardian|gateway) can never be abschalten'ed: exit 77, ctl.rejected reason `protected`, even for a human
#     with --force; no request file, no systemctl.
#   - abschalten / start go through the systemctl seam with EXACT argv `disable --now aib-agent@<uid>.service` /
#     `enable --now aib-agent@<uid>.service`; `standup` on a stopped unit first runs `start aib-agent@<uid>.service`.
#   - status: read-only, no audit, no request file, works on a stopped unit (no live.json => state=STOPPED), `key=value` lines.
#   - say: appends `from:human:<login>` PERSISTED to the target's inbox (login from the identity, never an argument).
#   - attach: local REPL in the caller's own terminal: prints the transcript tail, follows it, every typed line becomes a `say`.
#
#   Expected on the unbuilt tree: bin/agentctl does not exist, so everything fails for that one reason.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/fixtures/ctl_harness.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-agentctl.XXXXXX")"
trap sup_cleanup EXIT
trap "" PIPE                                      # attach (T10) writes into a FIFO whose reader may be gone

# --- T1 usage: nothing is written, systemd is never touched -----------------------------------
ctl_world usage; as human:operator
for args in "" "frobnicate acme-core" "neustart" "neustart ACME" "neustart ../x" "neustart acme-core --caller human:root" "neustart acme-core --bogus" \
            "standup acme-core --hard" "abschalten acme-core --fresh" "status" "say acme-core" "say acme-core ''"; do
  # shellcheck disable=SC2086
  eval "ctl AIB_CTL_WAIT_S=0.3 -- $args"
  eq "T1: '${args:-<none>}' => 64" "$RC" 64
done
eq "T1: …nothing written: no audit record, no request file, systemctl never called" "$RC|$([ ! -s "$CLOG" ] && echo none)|$(ctl_files | tr -d ' ')|$(wc -c < "$W/systemctl.log" | tr -d ' ')" "64|none||0"
ctl AIB_CTL_WAIT_S=0.3 -- neustart acme-ghost
eq "T1: an unknown target => 66" "$RC" 66
ctl AIB_CTL_WAIT_S=0.3 -- neustart acme-solo
eq "T1: a oneshot (not supervised) target => 66" "$RC" 66
eq "T1: …neither is audited nor queued" "$RC|$([ ! -s "$CLOG" ] && echo none)|$(ctl_files | tr -d ' ')" "66|none|"

# --- T2 identity from the uid, claim recorded beside it -------------------------------------
ctl_world ident; as human:operator
ctl AIB_CTL_WAIT_S=0.3 AIBOBNET_ACTOR=mallory -- neustart acme-core --reason "maintenance window"
eq "T2: no terminal record (no supervisor) => 124" "$RC" 124
eq "T2: exactly one ctl.requested" "$(cc ctl.requested)" 1
eq "T2: …caller is the kernel identity" "$(cf ctl.requested 1 caller)" human:operator
eq "T2: …the claimed actor is recorded, not trusted" "$(cf ctl.requested 1 actor)" mallory
eq "T2: …verb" "$(cf ctl.requested 1 verb)" neustart
eq "T2: …target" "$(cf ctl.requested 1 target)" acme-core
eq "T2: …reason" "$(cf ctl.requested 1 reason)" "maintenance window"
eq "T2: …flags default false" "$(cf ctl.requested 1 force)|$(cf ctl.requested 1 hard)|$(cf ctl.requested 1 fresh)" "false|false|false"
case "$(cf ctl.requested 1 ts)" in 20??-??-??T??:??:??*Z) ok "T2: …ts is ISO-8601 UTC";; *) no "T2: …ts is ISO-8601 UTC (got '$(cf ctl.requested 1 ts)')";; esac
eq "T2: …seq is 1" "$(cf ctl.requested 1 seq)" 1
eq "T2: the request file is <uid>.<seq>.<verb>" "$(ctl_files | tr -d ' ')" "acme-core.1.neustart"
as role:aib-agent
ctl AIB_CTL_WAIT_S=0.3 AIBOBNET_ACTOR=human:operator -- abschalten acme-sib
eq "T2: a role account claiming to be a human is still refused (77)" "$RC" 77
eq "T2: …caller stays the kernel identity" "$(cf ctl.rejected 1 caller)" role:aib-agent
for f in force hard fresh; do
  as human:operator; ctl AIB_CTL_WAIT_S=0.3 -- neustart acme-sib "--$f"
  eq "T2: --$f is recorded as $f:true in the audit record" "$(cf ctl.requested -1 "$f")" true
done

# --- T3 audit before action ------------------------------------------------------------------
ctl_world audit; as human:operator
mkdir "$CLOG"                                    # the append target is unusable (a directory)
ctl AIB_CTL_WAIT_S=0.3 -- feierabend acme-core
eq "T3: audit append fails => exit 73" "$RC" 73
eq "T3: …and NO request file exists" "$RC|$(ctl_files | tr -d ' ')" "73|"
ctl AIB_CTL_WAIT_S=0.3 -- start acme-core
eq "T3: start with a failing audit => 73 as well" "$RC" 73
eq "T3: …and systemctl was not called" "$RC|$(wc -c < "$W/systemctl.log" | tr -d ' ')" "73|0"
rmdir "$CLOG"
# one allocator under concurrency: 8 parallel callers => seq 1..8 once each, 8 request files
for i in 1 2 3 4 5 6 7 8; do ( ctl AIB_CTL_WAIT_S=0.3 -- standup acme-sib >/dev/null 2>&1 ) & done; wait
eq "T3: 8 concurrent calls write 8 gap-free, unique audit seqs" "$(CL valid "$CLOG")|$(cc ctl.requested)" "ok|8"
eq "T3: …and 8 request files, one per seq" "$(ls "$CTL" | sort -t. -k2 -n | tr '\n' ' ')" "acme-sib.1.standup acme-sib.2.standup acme-sib.3.standup acme-sib.4.standup acme-sib.5.standup acme-sib.6.standup acme-sib.7.standup acme-sib.8.standup "

# --- T4 the authorization matrix (agentctl layer) ---------------------------------------------
# identity|actor|verb  ->  expect  ok (queued: 124 without a supervisor) | deny (77, audited ctl.rejected unauthorized, no file)
ctl_world authz
row() { # row <identity> <actor> <verb> <ok|deny>
  : > "$CLOG"; rm -f "${CTL:?}"/*; : > "$W/systemctl.log"; printf '%s=%s\n' "$ME_UID" "$1" > "$IDMAP"
  ctl AIB_CTL_WAIT_S=0.3 AIBOBNET_ACTOR="$2" -- "$3" acme-sib
  local want_rc=124; [ "$4" = deny ] && want_rc=77
  case "$3" in start|status) [ "$4" = ok ] && want_rc=0;; esac          # no supervisor round trip
  eq "T4: $1 actor='${2:-}' $3 => $4" "$RC" "$want_rc"
  if [ "$4" = deny ]; then
    eq "T4: …audited as ctl.rejected unauthorized, caller $1" "$(cf ctl.rejected 1 reason)|$(cf ctl.rejected 1 caller)" "unauthorized|$1"
    eq "T4: …no request file, no systemctl" "$RC|$(ctl_files | tr -d ' ')|$(wc -c < "$W/systemctl.log" | tr -d ' ')" "77||0"
  fi
}
for v in neustart feierabend standup; do
  row human:operator "" $v ok;   row gateway:gw "" $v ok
  row role:aib-agent acme-core $v ok                                     # lead claim: registry lead=true
  row role:aib-agent acme-sib $v deny; row role:aib-agent "" $v deny; row role:aib-agent acme-ghost $v deny; row unknown:1234 "" $v deny
done
for v in abschalten start reset-brake; do
  row human:operator "" $v ok
  row gateway:gw "" $v deny; row role:aib-agent acme-core $v deny; row role:aib-agent "" $v deny; row unknown:1234 "" $v deny
done
row human:operator "" status ok; row role:aib-agent "" status ok; row gateway:gw "" status ok; row unknown:1234 "" status deny

# --- T5 protected agents are never abschalten'ed ---------------------------------------------
ctl_world prot; as human:operator
for t in acme-guard acme-gate; do
  ctl AIB_CTL_WAIT_S=0.3 -- abschalten "$t" --force
  eq "T5: abschalten $t --force (human) => 77" "$RC" 77
  eq "T5: …audited reason protected" "$(cf ctl.rejected -1 reason)|$(cf ctl.rejected -1 target)" "protected|$t"
done
eq "T5: …no request file, no systemctl at all" "$RC|$(ctl_files | tr -d ' ')|$(wc -c < "$W/systemctl.log" | tr -d ' ')" "77||0"
ctl AIB_CTL_WAIT_S=0.3 -- start acme-guard
eq "T5: start of a protected agent is fine (it never stops it)" "$RC" 0

# --- T6 systemd goes through the seam, exact command lines -----------------------------------
ctl_world sysd; as human:operator
ctl -- start acme-core
eq "T6: start => rc 0" "$RC" 0
eq "T6: …exact argv: enable --now" "$(grep -v '^is-active' "$W/systemctl.log")" "enable --now aib-agent@acme-core.service"
eq "T6: …audit has requested -> unit -> done in this order" "$(python3 -I - "$CLOG" <<'PY'
import json, sys
print(",".join(json.loads(l)["event"] for l in open(sys.argv[1])))
PY
)" "ctl.requested,ctl.unit,ctl.done"
eq "T6: …ctl.unit carries unit, action, rc and req" "$(cf ctl.unit 1 unit)|$(cf ctl.unit 1 action)|$(cf ctl.unit 1 rc)|$(cf ctl.unit 1 req)" "aib-agent@acme-core.service|enable --now|0|1"
: > "$W/systemctl.log"; echo 5 > "$W/systemctl.rc"
ctl -- start acme-sib
eq "T6: a failing systemctl => exit 69" "$RC" 69
eq "T6: …the failure is audited (ctl.unit rc 5) and no second ctl.done exists" "$(cf ctl.unit -1 rc)|$(cc ctl.done)" "5|1"
rm -f "$W/systemctl.rc"; : > "$W/systemctl.log"; echo inactive > "$W/unit.state"
ctl AIB_CTL_WAIT_S=0.3 -- standup acme-core
eq "T6: standup on a stopped unit starts it first (exact argv)" "$(grep -v '^is-active' "$W/systemctl.log")" "start aib-agent@acme-core.service"
eq "T6: …and still queues the request" "$(ctl_files | tr -d ' ')" "acme-core.6.standup"
: > "$W/systemctl.log"; rm -f "${CTL:?}"/*
ctl -- abschalten acme-sib
eq "T6: abschalten of a stopped unit disables it directly (rc 0)" "$RC" 0
eq "T6: …exact argv: disable --now" "$(grep -v '^is-active' "$W/systemctl.log")" "disable --now aib-agent@acme-sib.service"
eq "T6: …no request file (nobody to ask)" "$RC|$(ctl_files | tr -d ' ')" "0|"

# --- T7 end to end with a real supervisor: terminal record, file cleanup, abschalten ----------
ctl_world e2e; as human:operator
start_sup acme-core "${CTLENV[@]}"
wait_for 10 lj_is state READY
ctl -- neustart acme-core
eq "T7: neustart round trip => rc 0" "$RC" 0
has "T7: …agentctl prints the terminal record" "$OUT" "ctl.done"
eq "T7: …audit order: requested, accepted, done" "$(python3 -I - "$CLOG" <<'PY'
import json, sys
print(",".join(json.loads(l)["event"] for l in open(sys.argv[1])))
PY
)" "ctl.requested,ctl.accepted,ctl.done"
eq "T7: …agentctl removed its own request file after the terminal record" "$RC|$(ctl_files | tr -d ' ')" "0|"
: > "$W/systemctl.log"
ctl -- abschalten acme-core
eq "T7: abschalten round trip => rc 0" "$RC" 0
wait_exit "$SUP_PID"; eq "T7: …the supervisor stopped by itself (exit 0, no restart)" "$RC" 0; SUP_PID=""
eq "T7: …exactly one systemctl effect: disable --now" "$(grep -v '^is-active' "$W/systemctl.log")" "disable --now aib-agent@acme-core.service"
eq "T7: …audit: done (stopping), then unit rc 0" "$(cf ctl.done -1 result)|$(cf ctl.unit -1 action)|$(cf ctl.unit -1 rc)" "stopping|disable --now|0"

# --- T8 status ---------------------------------------------------------------------------------
ctl_world status; as human:operator
ctl -- status acme-core
eq "T8: status on a stopped unit with no live.json => rc 0" "$RC" 0
has "T8: …state=STOPPED" "$OUT" "state=STOPPED"
has "T8: …unit_state from the systemctl seam" "$OUT" "unit_state=active"
eq "T8: status wrote no audit and no request file" "$RC|$([ ! -s "$CLOG" ] && echo none)|$(ctl_files | tr -d ' ')" "0|none|"
mkdir -p "$W/state/acme-core"
mklive() { # mklive <age_s> <interval> <state> <off_duty>
  python3 -I - "$W/state/acme-core/live.json" "$1" "$2" "$3" "$4" <<'PY'
import json, sys, datetime
p, age, iv, st, od = sys.argv[1:6]
ts = (datetime.datetime.utcnow() - datetime.timedelta(seconds=float(age))).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump({"seq": 7, "ts": ts, "interval_s": float(iv), "pid": 1, "state": st, "state_reason": "", "turn": None,
           "brake": {"consecutive": 2, "tripped_at": None}, "session_id": None, "turns_in_session": 0, "off_duty": od == "true"}, open(p, "w"))
PY
}
m_send st-1 "open one"; m_send st-2 "open two"
mklive 1 30 READY false
ctl -- status acme-core
has "T8: state from live.json" "$OUT" "state=READY"
has "T8: …fresh tick is healthy" "$OUT" "health=healthy"
has "T8: …brake counter" "$OUT" "brake_consecutive=2"
has "T8: …off_duty flag" "$OUT" "off_duty=false"
has "T8: …open inbox count" "$OUT" "inbox_open=2"
has "T8: …tick age is reported (whole seconds)" "$OUT" "tick_age_s="
mklive 200 30 READY false
ctl -- status acme-core
has "T8: a tick older than 3x its interval is unhealthy whatever the state says" "$OUT" "health=unhealthy"
mklive 1 30 WAITING true
ctl -- status acme-core
has "T8: off_duty=true is shown" "$OUT" "off_duty=true"

# --- T9 say ----------------------------------------------------------------------------------
ctl_world say; as human:operator
ctl AIBOBNET_ACTOR=mallory -- say acme-core 'hello  "world" $HOME `id` ; * |'
eq "T9: say => rc 0" "$RC" 0
sid="$(printf '%s' "$OUT" | tr -d '[:space:]')"
case "$sid" in ?*) ok "T9: …prints the new message id";; *) no "T9: …prints the new message id";; esac
line="$(grep -F "id:$sid " "$INBOX" 2>/dev/null)"
has "T9: the line is from:human:<login> (identity, not the claim)" "$line" "| from:human:operator |"
has "T9: …to the target" "$line" "| to:acme-core"
has "T9: …PERSISTED" "$line" "| state:PERSISTED | "
has "T9: …body verbatim, no shell evaluation" "$line" '| hello  "world" $HOME `id` ; * |'
eq "T9: …bin/message sees it as PERSISTED" "$(m_state "$sid")" PERSISTED
as role:aib-agent; ctl -- say acme-core "nope"
eq "T9: a role account may not say (77)" "$RC" 77
as gateway:gw; ctl -- say acme-core "via gateway"
eq "T9: a gateway may say" "$RC" 0

# --- T10 attach: local REPL, follows the transcript, typed lines become `say` ---------------------
ctl_world attach; as human:operator
mkdir -p "$STANDUP/transcripts"; printf 'turn one output\nturn two output\n' > "$TRANSCRIPT"
mkfifo "$W/stdin.fifo"
( env -i PATH="$W/fakebin:$PATH" HOME="$W/home-ctl" LANG=C TZ=UTC "${CTLENV[@]}" AIBOBNET_REGISTRY="$ENGINE/registry.json" \
    "$ENGINE/bin/agentctl" attach acme-core < "$W/stdin.fifo" > "$W/attach.out" 2>&1; echo $? > "$W/attach.rc" ) &
APID=$!
exec 7> "$W/stdin.fifo"
WAIT_DEAD_OK=1 wait_for 10 grep -q 'turn two output' "$W/attach.out"
has "T10: attach shows the existing transcript" "$(cat "$W/attach.out" 2>/dev/null)" "turn two output"
printf 'a fresh line after attach\n' >> "$TRANSCRIPT"
WAIT_DEAD_OK=1 wait_for 10 grep -q 'a fresh line after attach' "$W/attach.out"
has "T10: …and follows new transcript lines" "$(cat "$W/attach.out" 2>/dev/null)" "a fresh line after attach"
printf 'please look at the failing test\n' >&7
WAIT_DEAD_OK=1 wait_for 10 grep -qF 'please look at the failing test' "$INBOX"
has "T10: a typed line becomes a say from the human's own identity" "$(grep -F 'please look' "$INBOX" 2>/dev/null)" "| from:human:operator | to:acme-core"
exec 7>&-
WAIT_DEAD_OK=1 wait_for 10 test -s "$W/attach.rc"
eq "T10: EOF on stdin ends the session cleanly (rc 0)" "$(cat "$W/attach.rc" 2>/dev/null)" 0
eq "T10: …no follower process is left behind" "$(cat "$W/attach.rc" 2>/dev/null)|$(pgrep -f "tail.*$TRANSCRIPT" | wc -l | tr -d ' ')" "0|0"
wait "$APID" 2>/dev/null
as role:aib-agent
ctl -- attach acme-core < /dev/null
eq "T10: a role account may not attach (77)" "$RC" 77

printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
