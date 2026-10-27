#!/usr/bin/env bash
# ai-bobnet — RED spec for what S1c must SHIP so that a fresh host works (Supervisor slice S1c, gate round 1; design v3.4 K3, K6, K7, Riker M4/M5/H3,
# Dexter HIGH). Text-level pins (the files are the deliverable; provisioning installs them) plus a polkit evaluation where node exists.
#
# WHAT THIS PINS
#   K3  No unit of the login machinery owns /run/aib: aib-login@, aib-login-refresh@ and aib-login-watch carry no RuntimeDirectory= (systemd would
#       delete the shared /run/aib - broker.sock, ctl/, login-status/ - on every stop). The directories come from a shipped tmpfiles snippet.
#   K7  deploy/tmpfiles.d/aib-login.conf (type `d` lines, whitespace separated: Type Path Mode User Group Age):
#         /var/lib/aib/login        2770  aib-broker  aib-login
#         /var/lib/aib/login-state  owner aib-broker, not group/world writable
#         /run/aib/login-status     owner aib-broker, world-readable and traversable (the status files are 0644), not writable by others
#         /run/aib/login            owner aib-broker, group aib-gateway, no access for others (the code socket directory)
#       A broker drop-in EXAMPLE (any deploy/systemd/aib-broker@.service.d/*.example other than site.conf.example) that sets AIB_SUP_STATE_ROOT,
#       AIB_ROLE_UID, AIB_ROLE_GID, AIB_ROLE_UIDS, AmbientCapabilities= and CapabilityBoundingSet= naming CAP_SETUID and CAP_SETGID, and
#       SupplementaryGroups=aib-login. ReadWritePaths=/ReadOnlyPaths= entries in the three login units that point at directories created at runtime
#       (/run/aib/login*, /var/lib/aib/login*, /srv/aib/outbox/_server) carry the `-` prefix, so a fresh host does not fail with 226/NAMESPACE.
#   K6  polkit: members of group aib-gateway may `start` aib-login@<provider>.service and NOTHING else - not stop/restart, not enable, not
#       aib-agent@, not aib-login-refresh@, not the bare template; aib-ops keeps what it had. The grant lives in a rules file of deploy/polkit/
#       (every *.rules file is evaluated in name order, first non-null result wins, like polkit does).
#   Dexter  docs/CONFINEMENT.md states the documented divergence of the shared subscription login (store location + mode, readable by every agent,
#       the token handed over by fd, API-key mode restores "never sees") and no longer says the uid switch is unbuilt.
#
#   Expected on the unbuilt tree: RuntimeDirectory=aib is still there, deploy/tmpfiles.d and the drop-in example do not exist, the units' paths have
#   no `-`, there is no gateway grant, and the docs still call the switch pending.
set -uo pipefail
SRC_ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
no(){ fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; }
eq(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2' want '$3')"; fi; }
has(){ case "$2" in *"$3"*) ok "$1";; *) no "$1 (missing '$3')";; esac; }
D="$SRC_ROOT/deploy"; U="$D/systemd"
body() { grep -v '^[[:space:]]*#' "$1" 2>/dev/null; }

# --- T1 (K3) -----------------------------------------------------------------------------------------------------------------------------------
for u in aib-login@.service aib-login-refresh@.service aib-login-watch.service; do
  eq "T1: $u has no RuntimeDirectory=" "$([ -f "$U/$u" ] && body "$U/$u" | grep -c '^RuntimeDirectory')|$([ -f "$U/$u" ] && echo present)" "0|present"
done

# --- T2 (K7) tmpfiles ---------------------------------------------------------------------------------------------------------------------------
TF="$D/tmpfiles.d/aib-login.conf"
eq "T2: deploy/tmpfiles.d/aib-login.conf is shipped" "$([ -f "$TF" ] && echo present)" present
line() { body "$TF" | awk -v p="$1" '$1=="d" && $2==p {print; exit}'; }
fld() { printf '%s' "$1" | awk -v n="$2" '{print $n}'; }
l="$(line /var/lib/aib/login)"
eq "T2: /var/lib/aib/login: d, 2770, aib-broker, aib-login" "$(fld "$l" 3) $(fld "$l" 4) $(fld "$l" 5)" "2770 aib-broker aib-login"
l="$(line /var/lib/aib/login-state)"; m="$(fld "$l" 3)"
eq "T2: /var/lib/aib/login-state: owned by aib-broker, not group/world writable" "$(fld "$l" 4)|$([ -n "$m" ] && echo $(( (8#$m & 8#022) != 0 )))" "aib-broker|0"
l="$(line /run/aib/login-status)"; m="$(fld "$l" 3)"
eq "T2: /run/aib/login-status: owned by aib-broker, others may read+traverse (r-x) but not write" "$(fld "$l" 4)|$([ -n "$m" ] && echo $(( (8#$m & 8#005) == 8#005 )) $(( (8#$m & 8#002) != 0 )))" "aib-broker|1 0"
l="$(line /run/aib/login)"; m="$(fld "$l" 3)"
eq "T2: /run/aib/login: aib-broker:aib-gateway, group may traverse, others get nothing" "$(fld "$l" 4):$(fld "$l" 5)|$([ -n "$m" ] && echo $(( (8#$m & 8#010) != 0 )) $(( (8#$m & 8#007) != 0 )))" "aib-broker:aib-gateway|1 0"

# --- T3 (K7) broker drop-in example ---------------------------------------------------------------------------------------------------------------
DI="$(grep -l 'CAP_SETUID' "$U"/aib-broker@.service.d/*.example 2>/dev/null | grep -v 'site.conf.example' | head -1)"
eq "T3: a broker drop-in example for S1c is shipped (next to site.conf.example)" "$([ -n "$DI" ] && echo present)" present
dt="$(body "${DI:-/nonexistent}")"
# FLIPPED in v3.5 (L2/N2, Garfield): the role ids are no longer set by Environment= lines of this drop-in (aib-agent-dirs, run by another unit, never saw
# them); they live in ONE /etc/aib/role.env that the drop-in and the aib-agent@ unit both read via EnvironmentFile= (pinned in T7 below).
eq "T3: (v3.5 flip) the drop-in sets none of the role keys itself, it reads them from role.env" "$(printf '%s\n' "$dt" | grep -Ec '^Environment=.*(AIB_SUP_STATE_ROOT|AIB_ROLE_UID|AIB_ROLE_GID|AIB_ROLE_UIDS|AIB_ROLE_GROUPS)=')|$(printf '%s\n' "$dt" | grep -c '^EnvironmentFile=')" "0|1"
for k in AmbientCapabilities CapabilityBoundingSet; do
  v="$(printf '%s\n' "$dt" | grep "^$k=" | tr '\n' ' ')"
  eq "T3: $k= names CAP_SETUID and CAP_SETGID" "$(printf '%s' "$v" | grep -c CAP_SETUID)|$(printf '%s' "$v" | grep -c CAP_SETGID)" "1|1"
done
eq "T3: SupplementaryGroups=aib-login (the broker reads the shared store)" "$(printf '%s\n' "$dt" | grep -c '^SupplementaryGroups=.*aib-login')" 1
eq "T3: the broker mount namespace allows role-account agent homes to persist provider sessions" "$(printf '%s\n' "$dt" | grep '^ReadWritePaths=' | cut -d= -f2- | tr ' ' '\n' | grep -Fxc /var/lib/aib-sup)" 1
has "T3: the drop-in documents that its writable root must follow AIB_SUP_STATE_ROOT" "$(cat "${DI:-/nonexistent}" 2>/dev/null)" "AIB_SUP_STATE_ROOT"
eq "T3: the example is an example: it resets nothing (no empty ReadWritePaths=) and names no NOPASSWD" "$(printf '%s\n' "$dt" | grep -Ec '^ReadWritePaths=$|NOPASSWD')" 0

# --- T4 (K7/M5) optional runtime dirs are `-` prefixed -----------------------------------------------------------------------------------------------
for u in aib-login@.service aib-login-refresh@.service aib-login-watch.service; do
  bad="$(body "$U/$u" | grep -E '^(ReadWritePaths|ReadOnlyPaths)=' | cut -d= -f2- | tr ' ' '\n' | grep -E '^(/run/aib/login|/var/lib/aib/login|/srv/aib/outbox/_server)' | wc -l | tr -d ' ')"
  eq "T4: $u: every runtime-created ReadWritePaths/ReadOnlyPaths entry has the '-' prefix (0 unprefixed)" "$bad|$([ -f "$U/$u" ] && echo present)" "0|present"
done

# --- T5 (K6) polkit: the gateway may start aib-login@<p>, nothing else ----------------------------------------------------------------------------------------
RULES_ALL="$(cat "$D"/polkit/*.rules 2>/dev/null)"
has "T5: a rule names group aib-gateway" "$RULES_ALL" 'isInGroup("aib-gateway")'
has "T5: …and the anchored login-unit regex for it" "$RULES_ALL" '^aib-login@[a-z0-9-]+\.service$'
EVAL="$SRC_ROOT/tests/fixtures/polkit_eval.js"
if ! command -v node >/dev/null 2>&1; then
  printf 'ok   - (skipped: node is not installed on this host - the behavioural polkit cases need it; the text pins above still hold)\n'
else
  P="org.freedesktop.systemd1.manage-units"; F="org.freedesktop.systemd1.manage-unit-files"
  ev() { local r f; for f in "$D"/polkit/*.rules; do r="$(node "$EVAL" "$f" "$1" "$2" "$3" "$4" 2>&1)"; [ "$r" = null ] || { printf '%s' "$r"; return; }; done; echo null; }
  for u in aib-login@claude-code.service aib-login@codex.service; do
    eq "T5: gateway may start $u" "$(ev $P $u start aib-gateway)" yes
    eq "T5: …but not stop/restart/kill it" "$(ev $P $u stop aib-gateway)|$(ev $P $u restart aib-gateway)|$(ev $P $u kill aib-gateway)" "null|null|null"
    eq "T5: …nor enable/disable it (unit files)" "$(ev $F $u enable aib-gateway)|$(ev $F $u disable aib-gateway)" "null|null"
    eq "T5: a subject in neither group may not start it" "$(ev $P $u start users)" null
  done
  for u in aib-agent@acme-core.service aib-login-refresh@claude-code.service aib-login-watch.service aib-login@.service aib-login@A.service aib-broker@x.service sshd.service 'aib-login@a.service.d'; do
    eq "T5: gateway may NOT start $u" "$(ev $P "$u" start aib-gateway)" null
  done
  eq "T5: the gateway group does not gain the ops rights (stop an agent unit)" "$(ev $P aib-agent@acme-core.service stop aib-gateway)" null
  eq "T5: guard — aib-ops keeps start+stop on agent and login units" "$(ev $P aib-agent@acme-core.service start aib-ops)|$(ev $P aib-login@codex.service stop aib-ops)" "yes|yes"
  eq "T5: guard — a member of both groups still gets what each grants" "$(ev $P aib-login@codex.service start aib-ops,aib-gateway)" yes
fi

# --- T6 (Dexter HIGH) the docs tell the truth ------------------------------------------------------------------------------------------------------------------
DOC="$(tr '\n' ' ' < "$SRC_ROOT/docs/CONFINEMENT.md" 2>/dev/null | tr -s ' ')"
has "T6: CONFINEMENT.md has a dated 'Documented divergence: shared subscription login' section" "$DOC" "Documented divergence: shared subscription login"
has "T6: …says where the store lives and its mode" "$DOC" "/var/lib/aib/login"
has "T6: …says every agent of the server can read the shared login" "$(printf '%s' "$DOC" | tr 'A-Z' 'a-z')" "every agent"
has "T6: …names API-key mode as what restores 'never sees'" "$DOC" "API-key"
eq "T6: …and no longer claims the role-uid switch is unbuilt ('does not build the switch' / 'pending slice')" "$(printf '%s' "$DOC" | grep -c -e 'does not build the switch' -e 'the role-uid switch is a pending slice')" 0

# --- T7 (design v3.5 L2/N2) ONE role EnvironmentFile ---------------------------------------------------------------------------------------------------
# /etc/aib/role.env (root:root 0644) carries AIB_ROLE_UID, AIB_ROLE_GID, AIB_ROLE_UIDS, AIB_ROLE_GROUPS, AIB_SUP_STATE_ROOT. It is read via EnvironmentFile=
# by BOTH the broker drop-in and the unit that runs aib-agent-dirs (aib-agent@), so the chown of the per-agent dirs and the broker's switch use the same ids.
# Shipped as deploy/role.env.example (the installer, prox-init, writes the real one). The broker reference is mandatory (no `-`: a missing file must stop
# the broker, not silently run it without the switch); the agent unit may take it optionally.
RE="$D/role.env.example"
eq "T7: deploy/role.env.example is shipped" "$([ -f "$RE" ] && echo present)" present
rbody() { body "$RE" | sed '/^[[:space:]]*$/d'; }
rkey() { rbody | grep "^$1=" | head -1 | cut -d= -f2-; }
eq "T7: every non-comment line is KEY=value (EnvironmentFile syntax: no 'Environment=', no 'export')" "$(rbody | grep -vc '^[A-Z][A-Z0-9_]*=[^[:space:]]*$')|$(rbody | wc -l | tr -d ' ')" "0|5"
eq "T7: …exactly the five keys, once each" "$(rbody | cut -d= -f1 | LC_ALL=C sort | tr '\n' ' ')" "AIB_ROLE_GID AIB_ROLE_GROUPS AIB_ROLE_UID AIB_ROLE_UIDS AIB_SUP_STATE_ROOT "
isid() { case "$1" in ''|*[!0-9]*) return 1;; esac; [ "$1" -ge 1000 ]; }
islist() { local x; [ -n "$1" ] || return 1; for x in $(printf '%s' "$1" | tr ',' ' '); do isid "$x" || return 1; done; case "$1" in ,*|*,|*,,*) return 1;; esac; }
isid "$(rkey AIB_ROLE_UID)" && ok "T7: AIB_ROLE_UID is a decimal uid >= 1000" || no "T7: AIB_ROLE_UID is a decimal uid >= 1000 (got '$(rkey AIB_ROLE_UID)')"
isid "$(rkey AIB_ROLE_GID)" && ok "T7: AIB_ROLE_GID is a decimal gid >= 1000" || no "T7: AIB_ROLE_GID is a decimal gid >= 1000 (got '$(rkey AIB_ROLE_GID)')"
islist "$(rkey AIB_ROLE_UIDS)" && ok "T7: AIB_ROLE_UIDS is a strict decimal comma list, each >= 1000" || no "T7: AIB_ROLE_UIDS is a strict decimal comma list (got '$(rkey AIB_ROLE_UIDS)')"
# FLIPPED in v3.6 (M1): groups had ">= 1000" (v3.5 L1); the shared groups are system groups (gid < 1000), the control is the allow-list. Now: strict decimal, != 0.
isgid() { case "$1" in ''|*[!0-9]*) return 1;; esac; [ "$1" -ne 0 ]; }
glist() { local x; [ -n "$1" ] || return 1; for x in $(printf '%s' "$1" | tr ',' ' '); do isgid "$x" || return 1; done; case "$1" in ,*|*,|*,,*) return 1;; esac; }
glist "$(rkey AIB_ROLE_GROUPS)" && ok "T7: AIB_ROLE_GROUPS is a strict decimal comma list, each != 0" || no "T7: AIB_ROLE_GROUPS is a strict decimal comma list, each != 0 (got '$(rkey AIB_ROLE_GROUPS)')"
case ",$(rkey AIB_ROLE_UIDS)," in *",$(rkey AIB_ROLE_UID),"*) ok "T7: AIB_ROLE_UID is one of AIB_ROLE_UIDS (the helper's allow-list)";; *) no "T7: AIB_ROLE_UID is one of AIB_ROLE_UIDS";; esac
case "$(rkey AIB_SUP_STATE_ROOT)" in /?*) ok "T7: AIB_SUP_STATE_ROOT is an absolute path";; *) no "T7: AIB_SUP_STATE_ROOT is an absolute path (got '$(rkey AIB_SUP_STATE_ROOT)')";; esac
RTXT="$([ -f "$RE" ] && tr "\n" " " < "$RE" | tr -s " ")"
has "T7: the example's comments name the install path /etc/aib/role.env" "$RTXT" "/etc/aib/role.env"
has "T7: …and its ownership root:root and mode 0644" "$RTXT" "root:root"
has "T7: …(mode)" "$RTXT" "0644"
eq "T7: the broker drop-in reads it with EnvironmentFile=/etc/aib/role.env (mandatory, no '-')" "$(printf '%s\n' "$dt" | grep -c '^EnvironmentFile=/etc/aib/role.env$')" 1
eq "T7: the aib-agent@ unit (it runs aib-agent-dirs) reads the same file" "$(body "$U/aib-agent@.service" | grep -Ec '^EnvironmentFile=-?/etc/aib/role.env$')" 1
eq "T7: …in its [Service] section, so ExecStartPre sees it" "$(awk '/^\[/{s=$0} /^EnvironmentFile=/{print s}' "$U/aib-agent@.service" 2>/dev/null | sort -u)" "[Service]"
eq "T7: …and aib-agent@ does not set the role keys by Environment= (one source)" "$(body "$U/aib-agent@.service" | grep -Ec '^Environment=.*(AIB_SUP_STATE_ROOT|AIB_ROLE_UID|AIB_ROLE_GID|AIB_ROLE_UIDS|AIB_ROLE_GROUPS)=')" 0

# --- T8 (design v3.5 L3/N3) login/refresh units outlive their own CLI calls --------------------------------------------------------------------------------
# TimeoutStartSec >= 2 x AIB_LOGIN_CLI_TIMEOUT_S + 60 s (the Codex refresh can run two CLIs, features list + app-server, each bounded by the CLI timeout).
# The CLI timeout is DERIVED: an Environment=AIB_LOGIN_CLI_TIMEOUT_S= of the unit, else the default in bin/aib-login-refresh.
dur_s() { awk -v v="$1" 'BEGIN{ if (match(v,/^[0-9]+/)==0) {print "x"; exit} n=substr(v,1,RLENGTH); u=substr(v,RLENGTH+1); gsub(/ /,"",u);
  if (u==""||u=="s"||u=="sec"||u=="second"||u=="seconds") m=1; else if (u=="m"||u=="min"||u=="minute"||u=="minutes") m=60; else if (u=="h"||u=="hr"||u=="hour"||u=="hours") m=3600; else {print "x"; exit}
  print n*m }'; }
DEF="$(grep -o 'integer("AIB_LOGIN_CLI_TIMEOUT_S", *[0-9]*' "$SRC_ROOT/bin/aib-login-refresh" 2>/dev/null | grep -o '[0-9]*$' | head -1)"
case "$DEF" in ''|*[!0-9]*) no "T8: could not derive the default AIB_LOGIN_CLI_TIMEOUT_S from bin/aib-login-refresh (got '$DEF')";; *) ok "T8: derived default AIB_LOGIN_CLI_TIMEOUT_S=$DEF from bin/aib-login-refresh";; esac
for u in aib-login@.service aib-login-refresh@.service; do
  cli="$(body "$U/$u" | sed -n 's/^Environment=.*AIB_LOGIN_CLI_TIMEOUT_S=\([0-9]*\).*/\1/p' | head -1)"; cli="${cli:-$DEF}"
  ts="$(dur_s "$(body "$U/$u" | grep '^TimeoutStartSec=' | tail -1 | cut -d= -f2-)")"
  need=$(( 2 * ${cli:-0} + 60 ))
  case "$ts$cli" in *x*|'') no "T8: $u: TimeoutStartSec / CLI timeout not derivable (ts '$ts', cli '$cli')";;
    *) if [ "$ts" -ge "$need" ]; then ok "T8: $u: TimeoutStartSec ${ts}s >= 2 x ${cli}s + 60 = ${need}s"; else no "T8: $u: TimeoutStartSec ${ts}s must be >= 2 x ${cli}s + 60 = ${need}s"; fi;; esac
done

# --- T9 (Remote Bob finding) timers must also start on their own ---------------------------------------------------------------------------------------
# OnUnitActiveSec= alone never fires if the service never ran (fresh boot / fresh enable). Both timers need OnBootSec= and OnActiveSec=, each a positive
# value at most the OnUnitActiveSec interval, and the interval itself stays unchanged (refresh 1799 s = the tool's cadence, watch 1 h).
for spec in "aib-login-refresh@.timer:1799" "aib-login-watch.timer:3600"; do
  tn="${spec%%:*}"; want="${spec##*:}"; tb="$(body "$U/$tn")"
  val() { printf '%s\n' "$tb" | grep "^$1=" | head -1 | cut -d= -f2-; }
  iv="$(dur_s "$(val OnUnitActiveSec)")"; bs="$(dur_s "$(val OnBootSec)")"; as="$(dur_s "$(val OnActiveSec)")"
  eq "$tn: OnUnitActiveSec stays ${want}s" "$iv" "$want"
  for k in "OnBootSec:$bs" "OnActiveSec:$as"; do
    kv="${k#*:}"
    case "$kv" in ''|x|*[!0-9]*) no "T9: $tn carries ${k%%:*}= with a parseable value (got '$kv')";;
      *) if [ "$kv" -gt 0 ] && [ "$kv" -le "$want" ]; then ok "T9: $tn: ${k%%:*}=${kv}s is positive and <= ${want}s"; else no "T9: $tn: ${k%%:*}=${kv}s must be in 1..${want}s"; fi;; esac
  done
done

# --- T10 (design v3.7 P1/P2) the login request spool is provisioned ---------------------------------------------------------------------------------------
# tmpfiles: `d /run/aib/login-requests 1733 aib-broker aib-broker -` (any uid can create a request, nobody can list, sticky: only the owner of a file or
# the directory owner can remove it). The login unit unlinks the requests it has read, so it must be able to write there (a `-` prefixed ReadWritePaths
# entry, like the other runtime-created directories of T4).
l="$(line /run/aib/login-requests)"
eq "T10: tmpfiles: d /run/aib/login-requests 1733 aib-broker aib-broker -" "$(fld "$l" 1) $(fld "$l" 2) $(fld "$l" 3) $(fld "$l" 4) $(fld "$l" 5) $(fld "$l" 6)" "d /run/aib/login-requests 1733 aib-broker aib-broker -"
eq "T10: aib-login@.service may write the spool (ReadWritePaths has -/run/aib/login-requests, '-' prefixed)" "$(body "$U/aib-login@.service" | grep -E '^ReadWritePaths=' | cut -d= -f2- | tr ' ' '\n' | grep -Fxc -e '-/run/aib/login-requests')" 1

# --- T11 (design v3.7.1 Q4/Q5) role uids by uid, docs tell the residuals ---------------------------------------------------------------------------------
# Q4: the login unit reads the same role.env as the broker (optional `-`: a host without role accounts has none), so AIB_ROLE_UIDS reaches bin/aib-login.
eq "T11: aib-login@.service reads EnvironmentFile=-/etc/aib/role.env" "$(body "$U/aib-login@.service" | grep -c '^EnvironmentFile=-/etc/aib/role.env$')" 1
eq "T11: …in its [Service] section, and without setting the role keys by Environment=" "$(awk '/^\[/{s=$0} /^EnvironmentFile=/{print s}' "$U/aib-login@.service" 2>/dev/null | sort -u)|$(body "$U/aib-login@.service" | grep -Ec '^Environment=.*AIB_ROLE_')" "[Service]|0"
# Q5: CONFINEMENT.md states the availability residual of the spool and the scope of the project-root guard (wording is the design's; case-insensitive)
DOCL="$(printf '%s' "$DOC" | tr 'A-Z' 'a-z')"
has "T11: CONFINEMENT.md states the spool residual: local accounts can delay a login" "$DOCL" "delay a login"
has "T11: …but never start or authorize one" "$DOCL" "never start or authorize"
has "T11: …and that the project-root guard (P5) covers configured and resolvable directories only" "$DOCL" "configured and resolvable"
has "T11: …naming the spool directory" "$DOC" "/run/aib/login-requests"

# --- T12 role-switched adapter placement ----------------------------------------------------------------------------------------------------
PROVIDERS="$SRC_ROOT/docs/PROVIDERS.md"
eq "T12: both provider adapter rows are root:aib-shared 0750" \
  "$(grep -Ec '^\| Adapter \| `/opt/aib/adapters/(codex|claude-code)` \| root:aib-shared 0750,' "$PROVIDERS")" 2
eq "T12: no provider adapter row still grants execute only to aib-broker" \
  "$(grep -Ec '^\| Adapter \| `/opt/aib/adapters/.*root:aib-broker 0750' "$PROVIDERS")" 0

printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
