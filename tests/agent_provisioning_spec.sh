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
#     AIB_STANDUP_DIR (default /srv/aib/standup), AIB_OPS_GROUP (default aib-ops), AIB_BROKER_GROUP (default aib-broker),
#     AIB_SETFACL (default setfacl))
#     ensures <root> is a real 0755 directory owned by the executing uid:gid (root:root in the unit), <root>/<uid> is a real directory
#     (never follows/creates through a symlink: rc 78), and $AIB_STANDUP_DIR/transcripts exists. It also creates
#     <standup>/<uid>.log as a regular 0664 file owned by the standup directory owner and group. An existing regular log keeps its group/mode,
#     but is chowned to the standup directory owner; a symlink is refused (rc 78). This prevents Linux fs.protected_regular=2 from rejecting
#     cross-writer O_CREAT opens in the sticky shared standup directory. Then it runs EXACTLY these setfacl calls, in this order:
#         -m g:<grp>:--x <root>/<uid>          -m g:<broker-grp>:--x <root>/<uid>
#                                                -d -m g:<grp>:r-x <root>/<uid>
#         -m g:<grp>:--x <standup>/transcripts -d -m g:<grp>:r-x <standup>/transcripts
#         -m g:<grp>:r-- <root>/<uid>/live.json      (only when that file exists)
#     uid must match [a-z0-9]+(-[a-z0-9]+)+ else rc 64 and nothing is created or run. A failing setfacl => rc 69.
#   bin/aib-unit-alarm <failed unit name>   (unit aib-alarm@.service: Type=oneshot, User=aib-broker, ExecStart=/…/bin/aib-unit-alarm %i; v3.4 K1, was %I)
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
SR="$W/sup-root"; SD="$W/standup2"; GRP="$(id -gn)"; BROKER_GRP="aib-broker-test"
dirs() { RC=0; : > "$W/setfacl.log"; OUT="$(env -i PATH="$PATH" HOME="$W/home-ctl" AIB_TEST_SEAMS=1 AIB_SUP_STATE_ROOT="$SR" AIB_STANDUP_DIR="$SD" AIB_OPS_GROUP="$GRP" AIB_BROKER_GROUP="$BROKER_GRP" AIB_SETFACL="$W/fakes/setfacl" \
    timeout 30 "$ENGINE/bin/aib-agent-dirs" "$@" 2>"$W/dirs.err")" || RC=$?; ERR="$(cat "$W/dirs.err")"; }
rm -rf "$SR" "$SD"; mkdir -p "$SD"
dirs acme-core
eq "T2: state root is created 0755 and owned by the helper uid:gid (root:root in the unit)" "$(stat -c '%a %u:%g' "$SR")" "755 $(id -u):$(id -g)"
eq "T2: state dir 0700 and transcripts dir created" "$RC|$(mode_of "$SR/acme-core")|$([ -d "$SD/transcripts" ] && echo dir)" "0|700|dir"
eq "T2: heartbeat log is a real 0664 file owned by the standup directory owner:group" "$([ -f "$SD/acme-core.log" ] && [ ! -L "$SD/acme-core.log" ] && stat -c '%a %u:%g' "$SD/acme-core.log")" "664 $(stat -c '%u:%g' "$SD")"
eq "T2: exactly the five pinned setfacl calls, in order (no live.json yet)" "$(cat "$W/setfacl.log")" "-m g:$GRP:--x $SR/acme-core
-m g:$BROKER_GRP:--x $SR/acme-core
-d -m g:$GRP:r-x $SR/acme-core
-m g:$GRP:--x $SD/transcripts
-d -m g:$GRP:r-x $SD/transcripts"
echo '{}' > "$SR/acme-core/live.json"; dirs acme-core
eq "T2: with a live.json a sixth call grants the human group read on it" "$(tail -1 "$W/setfacl.log")|$(wc -l < "$W/setfacl.log" | tr -d ' ')" "-m g:$GRP:r-- $SR/acme-core/live.json|6"
dirs acme-core; eq "T2: idempotent (same calls, rc 0)" "$RC|$(wc -l < "$W/setfacl.log" | tr -d ' ')" "0|6"
chmod 604 "$SD/acme-core.log"; before_group="$(stat -c %g "$SD/acme-core.log")"; dirs acme-core
eq "T2: an existing same-owner heartbeat keeps its mode and group" "$(stat -c '%a %g' "$SD/acme-core.log")" "604 $before_group"
rm -f "$SD/acme-core.log"; printf 'sentinel\n' > "$W/heartbeat-target"; ln -s "$W/heartbeat-target" "$SD/acme-core.log"; dirs acme-core
eq "T2: a symlinked heartbeat is refused without touching its target" "$RC|$(cat "$W/heartbeat-target")" "78|sentinel"
rm -f "$SD/acme-core.log"
if [ "$(id -u)" -eq 0 ]; then
  printf 'foreign\n' > "$SD/acme-core.log"; chown 64211:64212 "$SD/acme-core.log"; chmod 604 "$SD/acme-core.log"; dirs acme-core
  eq "T2 (root): a foreign-owned heartbeat is re-owned to the standup owner while group/mode stay unchanged" "$(stat -c '%a %u:%g' "$SD/acme-core.log")" "604 $(stat -c %u "$SD"):64212"
else
  printf 'ok   - (skipped: not root - constructing a foreign-owned heartbeat needs root; creation, preservation, and symlink refusal are covered)\n'
fi
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
case "$(sec "$AL" Service | grep '^ExecStart=' | head -1)" in ExecStart=/*/bin/aib-unit-alarm\ %i) ok "T4: ExecStart= absolute path to bin/aib-unit-alarm %i (v3.4 K1: the RAW instance; %I would turn every '-' of the failed unit's name into '/')";; *) no "T4: ExecStart= absolute path to bin/aib-unit-alarm %i (v3.4 K1; was %I, which contradicts systemd)";; esac
# T4b (K1) the specifier round trip. OnFailure=aib-alarm@%n.service puts the failed unit's name into the instance RAW; %i hands it back unchanged, %I
# applies systemd's unescape ('-' -> '/'). Simulate the expansion of the shipped ExecStart with systemd-escape itself and require the name to arrive intact.
if ! command -v systemd-escape >/dev/null 2>&1; then
  printf 'ok   - (skipped: systemd-escape is not installed on this host - the specifier round trip needs it; the text pin above still holds)\n'
else
  arg="$(sec "$AL" Service | grep '^ExecStart=' | head -1 | awk '{print $NF}')"
  for inst in 'aib-agent@foo-bar.service' 'aib-login-refresh@claude-code.service' 'aib-login-watch.service'; do
    case "$arg" in %i) got="$inst";; %I) got="$(systemd-escape --unescape -- "$inst")";; *) got="?$arg";; esac
    eq "T4b: ExecStart argument '$arg' delivers '$inst' to aib-unit-alarm unchanged" "$got" "$inst"
  done
  eq "T4b: the Description= does not use %I either (it would show a mangled name)" "$(sec "$AL" Unit | grep -c '%I')" 0
fi
eq "T4: aib-agent@.service: OnFailure=aib-alarm@%n.service in [Unit] (not [Service])" "$(sec "$AG" Unit | grep -c '^OnFailure=aib-alarm@%n.service$')|$(sec "$AG" Service | grep -c '^OnFailure=')" "1|0"
es="$(sec "$AG" Service | grep '^ExecStartPre=' | head -1)"
case "$es" in ExecStartPre=+/*/bin/aib-agent-dirs\ %i) ok "T4: ExecStartPre=+<abs>/bin/aib-agent-dirs %i in [Service]";; *) no "T4: ExecStartPre=+<abs>/bin/aib-agent-dirs %i (got '$es')";; esac
eq "T4: the supervisor still has NoNewPrivileges and systemd does not own its state directory" "$(sec "$AG" Service | grep -cx -e 'NoNewPrivileges=yes')|$(sec "$AG" Service | grep -c '^StateDirectory')" "1|0"

# --- T5 (K7) aib-agent-dirs prepares the ROLE account's home (S1c) -------------------------------------------------------------------------------
# With AIB_ROLE_UID/AIB_ROLE_GID set (the same variables the broker uses; decimal, uid >= 1000) the helper also
#   - chowns <root>/<uid> to that uid:gid (mode stays 0700),
#   - creates <root>/<uid>/.claude and <root>/<uid>/.codex as real directories, 0700, owned by the role account (never through a symlink: rc 78),
#   - creates the symlink <root>/<uid>/.codex/auth.json -> $AIB_LOGIN_ROOT/codex/auth.json (default /var/lib/aib/login; dangling is fine: the login
#     may not exist yet; an existing correct link is left alone). Without AIB_ROLE_UID none of this happens (S1c off = today's behaviour).
LR="$W/login-root"; RU="$(id -u)"; RG="$(id -g)"; [ "$RU" -ge 1000 ] || RU=""
rdirs() { RC=0; : > "$W/setfacl.log"; OUT="$(env -i PATH="$PATH" HOME="$W/home-ctl" AIB_TEST_SEAMS=1 AIB_SUP_STATE_ROOT="$SR" AIB_STANDUP_DIR="$SD" AIB_OPS_GROUP="$GRP" AIB_BROKER_GROUP="$BROKER_GRP" AIB_SETFACL="$W/fakes/setfacl" AIB_LOGIN_ROOT="$LR" "$@" \
    timeout 30 "$ENGINE/bin/aib-agent-dirs" acme-core 2>"$W/dirs.err")" || RC=$?; ERR="$(cat "$W/dirs.err")"; }
rm -rf "$SR" "$SD" "$LR"; mkdir -p "$SR" "$SD" "$LR"
rdirs
eq "T5: without AIB_ROLE_UID nothing of the role setup happens (no .claude/.codex)" "$RC|$([ -e "$SR/acme-core/.claude" ] || [ -e "$SR/acme-core/.codex" ] && echo created || echo none)" "0|none"
if [ -z "$RU" ]; then
  printf 'ok   - (skipped: this test user has uid < 1000, so its own ids are not a valid AIB_ROLE_UID - the role-setup cases need a normal account)\n'
else
  rm -rf "$SR" "$SD"; mkdir -p "$SR" "$SD"
  rdirs AIB_ROLE_UID="$RU" AIB_ROLE_GID="$RG"
  d="$SR/acme-core"
  eq "T5: role setup: rc 0, state dir 0700 and owned by the role uid:gid" "$RC|$(stat -c '%a %u:%g' "$d")" "0|700 $RU:$RG"
  eq "T5: ….claude and .codex are real 0700 dirs owned by the role account" "$(for x in .claude .codex; do [ -d "$d/$x" ] && [ ! -L "$d/$x" ] && stat -c '%a %u:%g' "$d/$x"; done | tr '\n' ',')" "700 $RU:$RG,700 $RU:$RG,"
  eq "T5: ….codex/auth.json is a symlink to the shared store (dangling is fine)" "$([ -L "$d/.codex/auth.json" ] && readlink "$d/.codex/auth.json")" "$LR/codex/auth.json"
  eq "T5: …the setfacl calls include the broker search ACL (still exactly five)" "$(wc -l < "$W/setfacl.log" | tr -d ' ')" 5
  rdirs AIB_ROLE_UID="$RU" AIB_ROLE_GID="$RG"
  eq "T5: idempotent (rc 0, link unchanged)" "$RC|$(readlink "$d/.codex/auth.json")" "0|$LR/codex/auth.json"
  rm -rf "$d/.claude"; ln -s "$W" "$d/.claude"; rdirs AIB_ROLE_UID="$RU" AIB_ROLE_GID="$RG"
  eq "T5: a symlink where .claude belongs => rc 78 (nothing is created or chowned through it)" "$RC" 78
  rm -f "$d/.claude"
  for bad in 0 999 abc -1 '1000 1001'; do
    rm -rf "$SR/acme-core"; rdirs AIB_ROLE_UID="$bad" AIB_ROLE_GID="$RG"
    eq "T5: AIB_ROLE_UID='$bad' is not a valid role uid => rc 64, no state dir touched" "$RC|$([ -e "$SR/acme-core" ] && echo created || echo none)" "64|none"
  done
fi
if [ "$(id -u)" -ne 0 ]; then
  printf 'ok   - (skipped: not root - chowning to a DIFFERENT uid needs root; the own-uid cases above cover the logic, the VM run covers the cross-uid case)\n'
else
  rm -rf "$SR" "$SD"; mkdir -p "$SR" "$SD"; rdirs AIB_ROLE_UID=64211 AIB_ROLE_GID=64211
  eq "T5 (root): the state dir, .claude and .codex belong to the role uid" "$RC|$(stat -c '%u:%g' "$SR/acme-core" "$SR/acme-core/.claude" "$SR/acme-core/.codex" | tr '\n' ' ')" "0|64211:64211 64211:64211 64211:64211 "
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
