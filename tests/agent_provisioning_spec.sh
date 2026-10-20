#!/usr/bin/env bash
# ai-bobnet — RED spec for the provisioning helpers of S1c: team/server outbox dirs, per-agent state-dir ACLs, and the OnFailure alarm
# (Supervisor slice S1c; design v3 G7/G8, v3.1 H7: "Directory ACL g:aib-ops:x + default ACL on /var/lib/aib-sup/<uid> and the transcript dir";
# G8: "team outbox dirs created at registry registration", "OnFailure alarm unit").
#
# WHAT THIS PINS
#   bin/aib-outbox-init                 (run by provisioning / after a registry change; seams AIBOBNET_REGISTRY, AIB_OUTBOX_ROOT, gate as everywhere)
#     creates $AIB_OUTBOX_ROOT/<team_uid> for the team_uid of EVERY agent whose registry mode is `supervised` (a team that only has oneshot agents
#     gets none), mode with the group-write bit set and no world-write bit (the role accounts of the team write their alarms there), and
#     $AIB_OUTBOX_ROOT/_server with NO group/world write (only aib-broker writes the server outbox). Idempotent; an existing outbox.md is never
#     touched; a team_uid outside [a-z0-9]+(-[a-z0-9]+)* is skipped (rc 65 at the end, the other dirs are still created); an existing SYMLINK
#     where a dir belongs => rc 78 for that entry, nothing written through it; an unreadable registry => rc 66.
#   bin/aib-agent-dirs <uid>            (unit: ExecStartPre=+/…/bin/aib-agent-dirs %i; seams AIB_SUP_STATE_ROOT (default /var/lib/aib-sup),
#     AIB_STANDUP_DIR (default /srv/aib/standup), AIB_OPS_GROUP (default aib-ops), AIB_SETFACL (default setfacl))
#     ensures <root>/<uid> exists as a real directory (never follows/creates through a symlink: rc 78) and $AIB_STANDUP_DIR/transcripts exists,
#     then runs EXACTLY these setfacl calls, in this order (the unit's StateDirectoryMode stays 0700, the ACL adds traverse for the human group):
#         -m g:<grp>:--x <root>/<uid>          -d -m g:<grp>:r-x <root>/<uid>
#         -m g:<grp>:--x <standup>/transcripts -d -m g:<grp>:r-x <standup>/transcripts
#         -m g:<grp>:r-- <root>/<uid>/live.json      (only when that file exists)
#     uid must match [a-z0-9]+(-[a-z0-9]+)+ else rc 64 and nothing is created or run. A failing setfacl => rc 69.
#   bin/aib-unit-alarm <failed unit name>   (unit aib-alarm@.service: Type=oneshot, User=aib-broker, ExecStart=/…/bin/aib-unit-alarm %I)
#     aib-agent@<uid>.service           -> a line in the agent's TEAM outbox (from registry): from:aib-alarm | to:human:<team> | state:PERSISTED |
#                                          alarm:unit_failed agent:<uid> unit:aib-agent@<uid>.service        (unknown agent -> the server outbox, to:human:ops)
#     aib-login@<p>.service, aib-login-refresh@<p>.service
#                                       -> SERVER outbox (_server): alarm:login_failed provider:<p> unit:<name>
#     aib-login-watch.service           -> SERVER outbox: alarm:login_failed unit:aib-login-watch.service
#     anything else / a malformed name  -> rc 64, nothing written. rc 0 on every line written. One line per call (no dedupe: systemd calls it once per failure).
#   Units (text): deploy/systemd/aib-alarm@.service as above; deploy/systemd/aib-agent@.service has OnFailure=aib-alarm@%n.service in [Unit] and
#     the ExecStartPre= above in [Service] (the leading `+` = full privileges so it can set ACLs; the supervisor itself stays unprivileged).
#
#   Expected on the unbuilt tree: none of the three tools nor aib-alarm@.service exist.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/fixtures/ctl_harness.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-prov.XXXXXX")"
trap sup_cleanup EXIT
ctl_world p
mode_of() { stat -c %a "$1" 2>/dev/null; }
REG2="$W/registry2.json"
cat > "$REG2" <<JSON
{ "schema_version": 5,
  "providers": { "acme": { "adapter": "$SRC_ROOT/adapters/codex", "cap_sandbox": "workspace-write", "cap_tier": "t2", "cap_effort": "high", "cap_timeout": "900" } },
  "projects": { "acme": { "home": "$HOMEDIR", "standup_dir": "$STANDUP", "mux_session": "acme", "data_class": "internal", "provider": "acme", "model": "m", "effort": "low" } },
  "teams": { "acme-engine": { "project": "acme", "model": "m" } },
  "agents": {
    "acme-core": { "mode": "supervised", "project": "acme", "team_uid": "acme-engine", "profile": "engine-dev", "clearance": "t2" },
    "acme-ops":  { "mode": "supervised", "project": "acme", "team_uid": "acme-ops",    "profile": "engine-dev", "clearance": "t2" },
    "acme-old":  { "mode": "oneshot",    "project": "acme", "team_uid": "acme-legacy", "profile": "engine-dev", "clearance": "t2" },
    "acme-bad":  { "mode": "supervised", "project": "acme", "team_uid": "Acme/..",     "profile": "engine-dev", "clearance": "t2" }
  } }
JSON
init() { RC=0; OUT="$(env -i PATH="$PATH" HOME="$W/home-ctl" "${CTLENV[@]}" AIBOBNET_REGISTRY="${1:-$REG2}" AIB_OUTBOX_ROOT="$OUTBOX" timeout 30 "$ENGINE/bin/aib-outbox-init" 2>"$W/init.err")" || RC=$?; ERR="$(cat "$W/init.err")"; }

# --- T1 outbox dirs -------------------------------------------------------------------------------------------------------------------------------------
rm -rf "${OUTBOX:?}"; mkdir -p "$OUTBOX"; init
eq "T1: supervised teams + _server are created; oneshot-only team and the unsafe name are not; the unsafe name makes rc 65" "$RC|$(LC_ALL=C ls "$OUTBOX" | tr '\n' ' ')" "65|_server acme-engine acme-ops "
eq "T1: team dirs are group-writable and not world-writable" "$(for d in acme-engine acme-ops; do m=$(stat -c %a "$OUTBOX/$d"); echo $(( (8#$m & 8#020) != 0 )) $(( (8#$m & 8#002) != 0 )); done | tr '\n' ' ')" "1 0 1 0 "
eq "T1: _server is neither group- nor world-writable" "$(m=$(stat -c %a "$OUTBOX/_server" 2>/dev/null); echo $(( (8#${m:-777} & 8#022) != 0 )))" 0
printf 'keep me\n' > "$OUTBOX/acme-engine/outbox.md"; init
eq "T1: idempotent; an existing outbox.md is untouched" "$(cat "$OUTBOX/acme-engine/outbox.md")|$(ls "$OUTBOX" | wc -l | tr -d ' ')" "keep me|3"
rm -rf "${OUTBOX:?}/acme-ops"; ln -s "$W" "$OUTBOX/acme-ops"; init
eq "T1: a symlink where a team dir belongs => rc 78 and nothing is written through it" "$RC|$(ls "$W/outbox" >/dev/null 2>&1; ls -A "$OUTBOX/acme-ops/" 2>/dev/null | grep -c '^outbox.md$')" "78|0"
init "$W/no-such-registry"; eq "T1: an unreadable registry => rc 66" "$RC" 66

# --- T2 aib-agent-dirs -------------------------------------------------------------------------------------------------------------------------------------
cat > "$W/fakes/setfacl" <<'FAKE'
#!/usr/bin/env bash
w=$(cd -P "$(dirname "$0")/.." && pwd); printf '%s\n' "$*" >> "$w/setfacl.log"; exit "$(cat "$w/setfacl.rc" 2>/dev/null || echo 0)"
FAKE
chmod +x "$W/fakes/setfacl"
SR="$W/sup-root"; SD="$W/standup2"; GRP="$(id -gn)"
dirs() { RC=0; : > "$W/setfacl.log"; OUT="$(env -i PATH="$PATH" HOME="$W/home-ctl" AIB_TEST_SEAMS=1 AIB_SUP_STATE_ROOT="$SR" AIB_STANDUP_DIR="$SD" AIB_OPS_GROUP="$GRP" AIB_SETFACL="$W/fakes/setfacl" \
    timeout 30 "$ENGINE/bin/aib-agent-dirs" "$@" 2>"$W/dirs.err")" || RC=$?; ERR="$(cat "$W/dirs.err")"; }
rm -rf "$SR" "$SD"; mkdir -p "$SR" "$SD"
dirs acme-core
eq "T2: state dir 0700 and transcripts dir created" "$RC|$(mode_of "$SR/acme-core")|$([ -d "$SD/transcripts" ] && echo dir)" "0|700|dir"
eq "T2: exactly the four pinned setfacl calls, in order (no live.json yet)" "$(cat "$W/setfacl.log")" "-m g:$GRP:--x $SR/acme-core
-d -m g:$GRP:r-x $SR/acme-core
-m g:$GRP:--x $SD/transcripts
-d -m g:$GRP:r-x $SD/transcripts"
echo '{}' > "$SR/acme-core/live.json"; dirs acme-core
eq "T2: with a live.json a fifth call grants the human group read on it" "$(tail -1 "$W/setfacl.log")|$(wc -l < "$W/setfacl.log" | tr -d ' ')" "-m g:$GRP:r-- $SR/acme-core/live.json|5"
dirs acme-core; eq "T2: idempotent (same calls, rc 0)" "$RC|$(wc -l < "$W/setfacl.log" | tr -d ' ')" "0|5"
for bad in 'ACME' '../x' 'a' 'a b' 'acme_core' ''; do dirs "$bad"; eq "T2: uid '$bad' => rc 64, nothing run or created" "$RC|$(wc -c < "$W/setfacl.log" | tr -d ' ')" "64|0"; done
rm -rf "${SR:?}/acme-sib"; ln -s "$W" "$SR/acme-sib"; dirs acme-sib
eq "T2: a symlink in place of the state dir => rc 78, no setfacl" "$RC|$(wc -c < "$W/setfacl.log" | tr -d ' ')" "78|0"
echo 1 > "$W/setfacl.rc"; dirs acme-core; eq "T2: a failing setfacl => rc 69" "$RC" 69; rm -f "$W/setfacl.rc"

# --- T3 aib-unit-alarm ---------------------------------------------------------------------------------------------------------------------------------------
rm -rf "${OUTBOX:?}"; mkdir -p "$OUTBOX"; init
ua() { RC=0; OUT="$(env -i PATH="$PATH" HOME="$W/home-ctl" "${CTLENV[@]}" AIBOBNET_REGISTRY="$REG2" AIB_OUTBOX_ROOT="$OUTBOX" timeout 30 "$ENGINE/bin/aib-unit-alarm" "$@" 2>"$W/ua.err")" || RC=$?; ERR="$(cat "$W/ua.err")"; }
TO() { cat "$OUTBOX/$1/outbox.md" 2>/dev/null; }
ua aib-agent@acme-core.service
line="$(TO acme-engine | tail -1)"
eq "T3: a failed agent unit => one line in ITS team outbox" "$RC|$(TO acme-engine | wc -l | tr -d ' ')" "0|1"
case "$line" in 20??-??-??T??:??:??*Z\ \|\ id:alarm-*) ok "T3: …ISO UTC timestamp and an id";; *) no "T3: …ISO UTC timestamp and an id (got '$line')";; esac
has "T3: …format" "$line" "| from:aib-alarm | to:human:acme-engine | state:PERSISTED | alarm:unit_failed agent:acme-core unit:aib-agent@acme-core.service"
ua aib-agent@acme-ops.service; eq "T3: another team, another outbox" "$(TO acme-ops | grep -c 'unit_failed agent:acme-ops')|$(TO acme-engine | wc -l | tr -d ' ')" "1|1"
ua aib-agent@acme-ghost.service
eq "T3: an agent the registry does not know => the SERVER outbox, to:human:ops" "$RC|$(TO _server | grep -c '| to:human:ops | state:PERSISTED | alarm:unit_failed agent:acme-ghost unit:aib-agent@acme-ghost.service')" "0|1"
ua aib-login-refresh@claude-code.service
has "T3: a failed refresher => login_failed in the server outbox" "$(TO _server | tail -1)" "| to:human:ops | state:PERSISTED | alarm:login_failed provider:claude-code unit:aib-login-refresh@claude-code.service"
ua aib-login@codex.service; has "T3: a failed login unit => login_failed" "$(TO _server | tail -1)" "alarm:login_failed provider:codex unit:aib-login@codex.service"
ua aib-login-watch.service; has "T3: a failed watch => login_failed without a provider" "$(TO _server | tail -1)" "alarm:login_failed unit:aib-login-watch.service"
n="$(find "$OUTBOX" -type f | xargs cat | wc -l)"
for bad in sshd.service 'aib-agent@.service' 'aib-agent@A.service' 'aib-agent@a/b.service' 'aib-login@x;y.service' '' 'aib-agent@acme-core.socket'; do
  ua "$bad"; eq "T3: '$bad' => rc 64, nothing written" "$RC|$(find "$OUTBOX" -type f | xargs cat | wc -l | tr -d ' ')" "64|$n"
done

# --- T4 unit texts ----------------------------------------------------------------------------------------------------------------------------------------------
AL="$SRC_ROOT/deploy/systemd/aib-alarm@.service"; AG="$SRC_ROOT/deploy/systemd/aib-agent@.service"
sec() { awk -v s="[$2]" '/^\[/{on=($0==s)} on' "$1" 2>/dev/null | grep -v '^[[:space:]]*#' | grep -v '^\['; }
eq "T4: aib-alarm@.service is oneshot, User=aib-broker" "$(sec "$AL" Service | grep -cx -e 'Type=oneshot' -e 'User=aib-broker')" 2
case "$(sec "$AL" Service | grep '^ExecStart=' | head -1)" in ExecStart=/*/bin/aib-unit-alarm\ %I) ok "T4: ExecStart= absolute path to bin/aib-unit-alarm %I (unescaped instance)";; *) no "T4: ExecStart= absolute path to bin/aib-unit-alarm %I";; esac
eq "T4: aib-agent@.service: OnFailure=aib-alarm@%n.service in [Unit] (not [Service])" "$(sec "$AG" Unit | grep -c '^OnFailure=aib-alarm@%n.service$')|$(sec "$AG" Service | grep -c '^OnFailure=')" "1|0"
es="$(sec "$AG" Service | grep '^ExecStartPre=' | head -1)"
case "$es" in ExecStartPre=+/*/bin/aib-agent-dirs\ %i) ok "T4: ExecStartPre=+<abs>/bin/aib-agent-dirs %i in [Service]";; *) no "T4: ExecStartPre=+<abs>/bin/aib-agent-dirs %i (got '$es')";; esac
eq "T4: the supervisor itself still has NoNewPrivileges and StateDirectoryMode=0700" "$(sec "$AG" Service | grep -cx -e 'NoNewPrivileges=yes' -e 'StateDirectoryMode=0700')" 2

printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
