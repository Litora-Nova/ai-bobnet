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
DI="$(grep -l 'AIB_SUP_STATE_ROOT' "$U"/aib-broker@.service.d/*.example 2>/dev/null | grep -v 'site.conf.example' | head -1)"
eq "T3: a broker drop-in example for S1c is shipped (next to site.conf.example)" "$([ -n "$DI" ] && echo present)" present
dt="$(body "${DI:-/nonexistent}")"
for k in AIB_SUP_STATE_ROOT= AIB_ROLE_UID= AIB_ROLE_GID= AIB_ROLE_UIDS=; do has "T3: sets $k" "$dt" "$k"; done
for k in AmbientCapabilities CapabilityBoundingSet; do
  v="$(printf '%s\n' "$dt" | grep "^$k=" | tr '\n' ' ')"
  eq "T3: $k= names CAP_SETUID and CAP_SETGID" "$(printf '%s' "$v" | grep -c CAP_SETUID)|$(printf '%s' "$v" | grep -c CAP_SETGID)" "1|1"
done
eq "T3: SupplementaryGroups=aib-login (the broker reads the shared store)" "$(printf '%s\n' "$dt" | grep -c '^SupplementaryGroups=.*aib-login')" 1
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

printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
