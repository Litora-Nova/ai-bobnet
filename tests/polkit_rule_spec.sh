#!/usr/bin/env bash
# ai-bobnet — RED spec for the polkit rule that lets HUMANS (group aib-ops) start/stop/enable/disable agent units
# (Supervisor slice S1b; v2 amendment F5b: "abschalten/start = systemctl disable --now / enable --now through polkit, no sudoers,
# no NOPASSWD, no marker in agent-writable space"). The rule text is the deliverable; provisioning (Remote Bob) installs it as
# /etc/polkit-1/rules.d/50-aib-agents.rules.
#
# WHAT THIS PINS
#   File deploy/polkit/50-aib-agents.rules, evaluated (node, when available — otherwise the textual pins only, with a stated skip)
#   against a synthetic action + subject (tests/fixtures/polkit_eval.js):
#     - YES only for  org.freedesktop.systemd1.manage-units       with verb start|stop
#                     org.freedesktop.systemd1.manage-unit-files  with verb enable|disable
#       on a unit matching ^aib-agent@[a-z0-9-]+\.service$ (anchored), for a subject in group `aib-ops`.
#     - everything else is NOT_HANDLED (null): other verbs (restart, reload, try-restart, kill, mask, link, set-property, edit...),
#       other units (sshd.service, the bare template aib-agent@.service, aib-broker@x.service, aib-agent@A.service, drop-in names,
#       trailing junk), other actions (reboot), and any subject outside aib-ops (an agent role account is never in aib-ops;
#       provisioning asserts it, and the rule names NO account at all).
#   Text pins: the rule uses action.lookup("unit") and action.lookup("verb") and subject.isInGroup("aib-ops"), contains the
#   literal regex, never returns polkit.Result.YES outside a branch that checks all three, and no role-account name appears.
#   Repo pins: nothing under deploy/ mentions NOPASSWD or ships a sudoers file.
#
#   Expected on the unbuilt tree: the rules file does not exist.
set -uo pipefail
SRC_ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
RULES="$SRC_ROOT/deploy/polkit/50-aib-agents.rules"; EVAL="$SRC_ROOT/tests/fixtures/polkit_eval.js"
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
no(){ fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; }
eq(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2' want '$3')"; fi; }
has(){ case "$2" in *"$3"*) ok "$1";; *) no "$1 (missing '$3')";; esac; }
hasnt(){ [ -n "$2" ] || { no "$1 (empty subject: file missing?)"; return; }; case "$2" in *"$3"*) no "$1 (unexpected '$3')";; *) ok "$1";; esac; }

TEXT="$(cat "$RULES" 2>/dev/null)"
has "text: manage-units action" "$TEXT" 'org.freedesktop.systemd1.manage-units'
has "text: manage-unit-files action" "$TEXT" 'org.freedesktop.systemd1.manage-unit-files'
has "text: reads the unit via action.lookup" "$TEXT" 'action.lookup("unit")'
has "text: reads the verb via action.lookup" "$TEXT" 'action.lookup("verb")'
has "text: group check" "$TEXT" 'subject.isInGroup("aib-ops")'
has "text: the anchored unit regex" "$TEXT" '^aib-agent@[a-z0-9-]+\.service$'
for v in start stop enable disable; do has "text: names the verb $v" "$TEXT" "\"$v\""; done
for bad in aib-dev aib-broker NOPASSWD; do
  hasnt "text: does not mention '$bad'" "$TEXT" "$bad"
done
eq "text: exactly one polkit.Result.YES (a single guarded grant)" "$(printf '%s' "$TEXT" | grep -c 'polkit.Result.YES')" 1
eq "text: a rules file is plain JS: no 'sudo', no shell escape" "$(printf '%s' "$TEXT" | grep -ciE 'sudo|child_process|exec\(')|$([ -n "$TEXT" ] && echo present)" "0|present"
eq "repo: nothing under deploy/ mentions NOPASSWD" "$(grep -rl NOPASSWD "$SRC_ROOT/deploy" 2>/dev/null | wc -l | tr -d ' ')|$([ -f "$RULES" ] && echo present)" "0|present"
eq "repo: no sudoers file is shipped" "$(find "$SRC_ROOT/deploy" -iname '*sudoers*' 2>/dev/null | wc -l | tr -d ' ')|$([ -f "$RULES" ] && echo present)" "0|present"

if ! command -v node >/dev/null 2>&1; then
  printf 'skip - behavioural polkit cases: node is not installed on this host (the textual pins above still hold)\n'
else
  P="org.freedesktop.systemd1.manage-units"; F="org.freedesktop.systemd1.manage-unit-files"; U="aib-agent@acme-core.service"
  ev() { node "$EVAL" "$RULES" "$1" "$2" "$3" "$4" 2>&1; }
  eq "eval: ops member may start an agent unit" "$(ev $P $U start aib-ops)" yes
  eq "eval: …stop" "$(ev $P $U stop aib-ops)" yes
  eq "eval: …enable (unit files)" "$(ev $F $U enable aib-ops)" yes
  eq "eval: …disable (unit files)" "$(ev $F $U disable aib-ops)" yes
  eq "eval: a digit/dash instance name works" "$(ev $P aib-agent@acme-core-2.service start aib-ops)" yes
  for v in restart reload try-restart kill reload-or-restart; do eq "eval: manage-units verb '$v' is NOT granted" "$(ev $P $U $v aib-ops)" null; done
  for v in mask unmask link set-property preset revert; do eq "eval: manage-unit-files verb '$v' is NOT granted" "$(ev $F $U $v aib-ops)" null; done
  eq "eval: start on the unit-files action is not granted" "$(ev $F $U start aib-ops)" null
  eq "eval: enable on the manage-units action is not granted" "$(ev $P $U enable aib-ops)" null
  eq "eval: a non-member is not granted (start)" "$(ev $P $U start users)" null
  eq "eval: …nor a subject with NO groups (disable)" "$(ev $F $U disable '')" null
  for u in sshd.service aib-agent@.service aib-broker@x.service aib-agent@A.service aib-agent@a_b.service xaib-agent@a.service \
           aib-agent@a.service.d aib-agent@a.socket 'aib-agent@a.service ' ''; do
    eq "eval: unit '$u' is NOT granted" "$(ev $P "$u" start aib-ops)" null
  done
  eq "eval: a newline-suffixed unit name is NOT granted (anchoring)" "$(ev $P "aib-agent@a.service
x" start aib-ops)" null
  eq "eval: an unrelated action is NOT granted" "$(ev org.freedesktop.login1.reboot $U start aib-ops)" null
  eq "eval: …nor power-off" "$(ev org.freedesktop.login1.power-off $U stop aib-ops)" null
fi
printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
