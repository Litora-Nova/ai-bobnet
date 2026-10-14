# ai-bobnet — shared hermetic harness for the control-plane specs (sourced, never run on its own).
# Builds on tests/fixtures/sup_harness.sh (the supervisor world) and adds the S1b seams.
#
# ===== THE INTERFACE THIS HARNESS PINS FOR bin/agentctl, bin/aib-gw AND THE SUPERVISOR'S CONTROL SIDE (S1b) =====
# env seams (unit/test supplied; every one has a production default, none is request-derived):
#   AIB_CTL_DIR            request directory                     (default /run/aib/ctl, root:aib-ctl 1770)
#   AIB_CONTROL_LOG        audit log `_control.jsonl`            (default /srv/aib/standup/_control.jsonl)
#                          the single seq allocator lock is `${AIB_CONTROL_LOG}.lock` (flock), held by EVERY writer
#   AIB_IDENTITY_CMD       `<cmd> <numeric uid>` -> one line `human:<login>` | `role:<account>` | `gateway:<account>`
#                          (anything else / empty / rc!=0 = `unknown:<uid>`). Production default resolves the uid with getent
#                          and group membership. agentctl calls it with its own euid; the supervisor with the REQUEST FILE'S OWNER uid.
#                          No flag, no env var and no argument of agentctl can choose the caller (`AIBOBNET_ACTOR` is a recorded CLAIM).
#   AIB_SYSTEMCTL          the systemctl command                 (default `systemctl`; the ONLY way agentctl touches systemd)
#   AIB_SUP_STATE_ROOT     <root>/<uid>/live.json for `status`   (already read by bin/project)
#   AIB_CTL_WAIT_S         how long agentctl waits for a terminal record (default 30; decimals; the specs use 0.5..8)
#   AIB_SUP_CANCEL_GRACE_S grace before `neustart --force` / `abschalten --force` cancels a running turn (default 30)
#   AIB_OUTBOX_ROOT        per-team outbox root                  (default /srv/aib/outbox)
#   AIB_DEPLOYMENT_CONFIG  deployment configuration file         (default /etc/aib/deployment.json)
#
# OPEN (not pinned, needs a PO/Remote-Bob decision): `status` and the projection read <state>/live.json, but the unit template sets
#   StateDirectoryMode=0700 and the unit runs as the (role) account, so neither a human's agentctl nor the aib-broker projection
#   user can read it. The specs run everything under one uid and therefore do NOT cover this.
#
# ===== AUDIT LOG `_control.jsonl` (JSON Lines, ONE seq allocator for agentctl AND every supervisor: 1,2,3,... gap-free) =====
#   {"seq":N,"ts":"<ISO UTC>","event":"ctl.requested","verb":V,"target":UID,"caller":ID,"actor":CLAIM|"","reason":TEXT|"",
#    "force":bool,"hard":bool,"fresh":bool}
#   {"seq":N,...,"event":"ctl.rejected","req":<requested seq>|null,"verb":V,"target":UID,"caller":ID,"reason":R}
#        R in protected | unauthorized | unaudited | busy | unknown_verb      (agentctl-side refusals have req=null)
#   {"seq":N,...,"event":"ctl.accepted"|"ctl.done","req":<requested seq>,"verb":V,"target":UID,"result":TEXT}
#   {"seq":N,...,"event":"ctl.unit","req":<requested seq>,"unit":"aib-agent@<uid>.service","action":"disable --now"|"enable --now"|"start","rc":N}
# request file: $AIB_CTL_DIR/<uid>.<seq>.<verb>   (seq = the ctl.requested seq; file CONTENT is ignored; the audit record is the truth,
#   including its force/hard/fresh flags). Written ONLY after the ctl.requested record is durable.
# agentctl exit codes: 0 done | 64 usage | 66 unknown or not-supervised target | 69 systemctl failed | 73 audit append failed (nothing
#   else happened) | 75 refused busy (WORKING without --force) | 77 refused (protected / unauthorized / unaudited) | 124 no terminal record in time.
# supervisor control side: polls $AIB_CTL_DIR every AIB_SUP_POLL_S for files of ITS uid, journals `ctl.consumed {req}` for every file it has
#   handled (a consumed seq is never re-run, also across crash+restart; the file may stay, the dir is sticky), and writes the terminal
#   records to BOTH its own journal.jsonl and $AIB_CONTROL_LOG (same event names).

. "$(dirname "${BASH_SOURCE[0]}")/sup_harness.sh"
ME_UID="$(id -u)"
CL() { python3 -I "$SJ" "$@"; }               # CL count <file> <event> | field <file> <event> <n> <key> | valid <file>
cc()  { CL count "$CLOG" "$1"; }
cf()  { CL field "$CLOG" "$1" "$2" "$3"; }

# ctl_registry — schema-5 registry for the control specs: lead/protected/data_class are FLAT strings (the reader exposes depth-2 strings only)
#   acme-core (supervised, lead) · acme-sib (supervised) · acme-guard (protected guardian) · acme-gate (protected gateway) · acme-solo (oneshot)
ctl_registry() { # ctl_registry [data_class] [extra project fields]
  local dc="${1:-internal}"
  cat > "$ENGINE/registry.json" <<JSON
{ "schema_version": 5,
  "providers": { "acme": { "adapter": "$SRC_ROOT/adapters/codex", "cap_sandbox": "workspace-write",
                           "cap_tier": "t2", "cap_effort": "high", "cap_timeout": "900" } },
  "projects": { "acme": { "home": "$HOMEDIR", "standup_dir": "$STANDUP", "mux_session": "acme", "data_class": "$dc",
                          "provider": "acme", "model": "team/model-v2", "effort": "low" } },
  "teams": { "acme-engine": { "project": "acme", "model": "team/model-v2" } },
  "agents": {
    "acme-core":  { "mode": "supervised", "lead": "true", "project": "acme", "team_uid": "acme-engine", "profile": "engine-dev", "clearance": "t2" },
    "acme-sib":   { "mode": "supervised", "lead": "false", "project": "acme", "team_uid": "acme-engine", "profile": "engine-dev", "clearance": "t2" },
    "acme-guard": { "mode": "supervised", "protected": "guardian", "project": "acme", "team_uid": "acme-engine", "profile": "engine-dev", "clearance": "t2" },
    "acme-gate":  { "mode": "supervised", "protected": "gateway", "project": "acme", "team_uid": "acme-engine", "profile": "engine-dev", "clearance": "t2" },
    "acme-solo":  { "mode": "oneshot", "project": "acme", "team_uid": "acme-engine", "profile": "engine-dev", "clearance": "t2" }
  } }
JSON
}

# ctl_world <tag> — a supervisor world plus the control seams; sets CTL CLOG IDMAP OUTBOX DEPLOY CTLENV[]
ctl_world() {
  sup_world "$1"; ctl_registry
  CTL="$W/ctl"; CLOG="$STANDUP/_control.jsonl"; IDMAP="$W/identity.map"; OUTBOX="$W/outbox"; DEPLOY="$W/deployment.json"
  mkdir -p "$CTL" "$OUTBOX"; chmod 1770 "$CTL"; : > "$IDMAP"; echo active > "$W/unit.state"; : > "$W/systemctl.log"
  cat > "$W/fakes/identity" <<'FAKE'
#!/usr/bin/env bash
w=$(cd -P "$(dirname "$0")/.." && pwd)
v=$(grep "^$1=" "$w/identity.map" | head -1 | cut -d= -f2-)
printf '%s\n' "${v:-unknown:$1}"
FAKE
  cat > "$W/fakes/systemctl" <<'FAKE'
#!/usr/bin/env bash
# recorder: one line per call, exactly the argv. `is-active` answers from $W/unit.state; everything else rc from $W/systemctl.rc
w=$(cd -P "$(dirname "$0")/.." && pwd)
printf '%s\n' "$*" >> "$w/systemctl.log"
if [ "$1" = is-active ]; then s=$(cat "$w/unit.state"); echo "$s"; [ "$s" = active ]; exit; fi
exit "$(cat "$w/systemctl.rc" 2>/dev/null || echo 0)"
FAKE
  chmod +x "$W/fakes/identity" "$W/fakes/systemctl"
  printf '{"deployment_id":"acme-dev-1","profile":"dev","allow":{"customer_code":true,"comms_secrets":true}}' > "$DEPLOY"; chmod 644 "$DEPLOY"
  CTLENV=(AIB_CTL_DIR="$CTL" AIB_CONTROL_LOG="$CLOG" AIB_IDENTITY_CMD="$W/fakes/identity" AIB_SYSTEMCTL="$W/fakes/systemctl"
          AIB_SUP_STATE_ROOT="$W/state" AIB_OUTBOX_ROOT="$OUTBOX" AIB_DEPLOYMENT_CONFIG="$DEPLOY" AIB_SUP_CANCEL_GRACE_S=0.3 AIB_CTL_WAIT_S=8)
}
as() { printf '%s=%s\n' "$ME_UID" "$1" > "$IDMAP"; }     # as human:operator | role:aib-agent | gateway:gw

# ctl [VAR=val ...] -- <agentctl args...>  -> RC OUT ERR (hermetic env, 60 s ceiling)
ctl() {
  local extra=(); while [ $# -gt 0 ] && [ "$1" != "--" ]; do extra+=("$1"); shift; done; [ "${1:-}" = "--" ] && shift
  RC=0; OUT="$(env -i PATH="$W/fakebin:$PATH" HOME="$W/home-ctl" LANG=C TZ=UTC "${CTLENV[@]}" AIBOBNET_REGISTRY="$ENGINE/registry.json" "${extra[@]}" \
      timeout 60 "$ENGINE/bin/agentctl" "$@" 2>"$W/ctl.err")" || RC=$?
  ERR="$(cat "$W/ctl.err" 2>/dev/null)"
}
ctl_files() { ls "$CTL" 2>/dev/null | tr '\n' ' '; }
syslog() { cat "$W/systemctl.log" 2>/dev/null; }
# a hand-made audit record (the executor must accept ONLY records it finds here): audit <verb> <target> <caller> [actor] [extra json fields]
audit() { python3 -I - "$CLOG" "$1" "$2" "$3" "${4:-}" "${5:-}" <<'PY'
import json, sys, datetime, fcntl
path, verb, target, caller, actor, extra = sys.argv[1:7]
lock = open(path + ".lock", "a")
fcntl.flock(lock, fcntl.LOCK_EX)
seq = 0
try:
    for line in open(path):
        if line.strip():
            seq = max(seq, json.loads(line)["seq"])
except FileNotFoundError:
    pass
rec = {"seq": seq + 1, "ts": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"), "event": "ctl.requested", "verb": verb,
       "target": target, "caller": caller, "actor": actor, "reason": "", "force": False, "hard": False, "fresh": False}
if extra:
    rec.update(json.loads(extra))
with open(path, "a") as f:
    f.write(json.dumps(rec) + "\n")
print(seq + 1)
PY
}
drop() { : > "$CTL/$1.$2.$3"; }                       # drop <uid> <seq> <verb>  — a request file
done_for() { [ "$(python3 -I "$SJ" first "$CLOG" ctl.done req "$1")" != "" ]; }
rej_for()  { [ "$(python3 -I "$SJ" first "$CLOG" ctl.rejected req "$1")" != "" ]; }
rejreason() { # rejreason <req> -> reason of the ctl.rejected record whose req == <req>
  python3 -I - "$CLOG" "$1" <<'PY'
import json, sys
for l in open(sys.argv[1]):
    r = json.loads(l)
    if r.get("event") == "ctl.rejected" and str(r.get("req")) == sys.argv[2]:
        print(r.get("reason")); break
PY
}
