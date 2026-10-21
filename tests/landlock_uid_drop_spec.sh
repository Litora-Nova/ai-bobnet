#!/usr/bin/env bash
# ai-bobnet — RED spec for the role-account switch in the confinement helper src/landlock-exec.c
# (Supervisor slice S1c; design v3 G7 = B12(2) + v2-F5a: `landlock-exec --uid/--gid`, AIB_ROLE_UIDS allow-list, setuid AFTER restrict_self, caps cleared).
#
# WHAT THIS PINS
#   Invocation:   landlock-exec [--uid N --gid N] CMD [ARGS...]      (the options come first; without them nothing changes)
#   Policy (env AIB_ROLE_UIDS = comma-separated decimal uids, set by the broker unit; unset/empty = nobody is allowed):
#     - --uid and --gid must come together, both unsigned decimal integers, once each            else exit 2 (usage), CMD not run
#     - uid 0 and gid 0 are refused ALWAYS, even if listed                                         exit 3 (confinement refused), CMD not run
#     - uid not in AIB_ROLE_UIDS                                                                   exit 3, CMD not run
#     - the refusal is decided BEFORE any Landlock work (so it is the same on a kernel without Landlock) and goes to stderr and, when LL_STATUS_FD is open, to that fd as one line `confine: ...` mentioning the word `uid`
#   Mechanics on success (order matters):
#     1. the Landlock ruleset is installed (restrict_self) FIRST,  2. then setgroups(0), setgid, setuid to the requested ids,
#     3. capabilities are cleared (permitted, effective, inheritable, ambient; the bounding set too where the caller may drop it: root / CAP_SETPCAP),
#        no_new_privs stays set,  4. CMD is exec'd.
#        Design v3.3: without CAP_SETPCAP the bounding set cannot be dropped; the helper then continues ONLY IF after the switch no_new_privs=1 and
#        CapPrm/CapEff/CapInh/CapAmb are all zero (a residual CapBnd is harmless then); otherwise it refuses with exit 3.
#     The child sees neither AIB_ROLE_UIDS nor LL_*; the Landlock rules still bind it after the id switch.
#   Specs that need the kernel's Landlock or real root skip with a stated reason; the pure policy refusals run everywhere.
#
#   Expected on the unbuilt tree: the helper treats `--uid` as the command to exec.
set -uo pipefail
SRC_ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-lluid.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
no(){ fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; }
skip(){ printf 'ok   - (skipped: %s)\n' "$1"; }
eq(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2' want '$3')"; fi; }
has(){ case "$2" in *"$3"*) ok "$1";; *) no "$1 (missing '$3' in: ${2:0:200})";; esac; }

CC="$(command -v cc || command -v gcc || true)"
if [ -z "$CC" ] || ! "$CC" -O2 -o "$WORK/ll" "$SRC_ROOT/src/landlock-exec.c" 2>"$WORK/cc.err"; then
  skip "no C compiler (or src/landlock-exec.c does not compile: $(head -c 200 "$WORK/cc.err" 2>/dev/null)) — nothing in this spec can run"
  printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]; exit
fi
ME="$(id -u)"; MG="$(id -g)"; SENT="$WORK/ran"; mkdir -p "$WORK/rw" "$WORK/outside"
# DAC must not be the reason for a denial: the dirs are world-writable (sticky) and $WORK is traversable, so only Landlock can deny a write
chmod o+x "$WORK"; chmod 1777 "$WORK/rw" "$WORK/outside"
# ll [env...] -- args...  -> RC OUT ERR STATUS (fd 3 = status channel)
ll() {
  local extra=(); while [ $# -gt 0 ] && [ "$1" != "--" ]; do extra+=("$1"); shift; done; shift
  : > "$WORK/status"; rm -f "$SENT"; RC=0
  OUT="$(env -i PATH="$PATH" LL_RO=/ LL_RW="$WORK/rw:/tmp" LL_STATUS_FD=3 "${extra[@]}" "$WORK/ll" "$@" 3>"$WORK/status" 2>"$WORK/err")" || RC=$?
  ERR="$(cat "$WORK/err")"; STATUS="$(cat "$WORK/status")"
}
uidmsg() { printf '%s
%s' "$STATUS" "$ERR" | grep -ci 'uid' | awk '{print ($1>0)?1:0}'; }
ran() { [ -e "$SENT" ] && echo ran || echo not-run; }
touch_cmd=(/bin/sh -c ": > '$SENT'")

# --- T1 policy refusals (no Landlock needed: they happen before anything is installed) -------------------------------------------------------------
ll AIB_ROLE_UIDS="$ME,5000" -- --uid "$ME" "${touch_cmd[@]}";                          eq "T1: --uid without --gid => exit 2, CMD not run" "$RC|$(ran)" "2|not-run"
ll AIB_ROLE_UIDS="$ME,5000" -- --gid "$MG" "${touch_cmd[@]}";                          eq "T1: --gid without --uid => exit 2, CMD not run" "$RC|$(ran)" "2|not-run"
for bad in -1 abc 1.5 '' 0x10 ' 5' 99999999999999999999; do
  ll AIB_ROLE_UIDS="$ME" -- --uid "$bad" --gid "$MG" "${touch_cmd[@]}";                 eq "T1: --uid '$bad' (not an unsigned decimal) => exit 2, CMD not run" "$RC|$(ran)" "2|not-run"
done
ll AIB_ROLE_UIDS="$ME" -- --uid "$ME" --gid abc "${touch_cmd[@]}";                      eq "T1: a bad --gid => exit 2, CMD not run" "$RC|$(ran)" "2|not-run"
ll AIB_ROLE_UIDS="0,$ME" -- --uid 0 --gid "$MG" "${touch_cmd[@]}";                      eq "T1: uid 0 is refused even when listed => exit 3, CMD not run" "$RC|$(ran)|$(uidmsg)" "3|not-run|1"
has "T1: …the refusal reaches the status fd and mentions uid" "$STATUS" "confine:"; has "T1: …and says uid" "$STATUS" "uid"
ll AIB_ROLE_UIDS="$ME" -- --uid "$ME" --gid 0 "${touch_cmd[@]}";                        eq "T1: gid 0 is refused => exit 3, CMD not run" "$RC|$(ran)|$(uidmsg)" "3|not-run|1"
ll AIB_ROLE_UIDS="5000,5001" -- --uid "$ME" --gid "$MG" "${touch_cmd[@]}";              eq "T1: a uid outside AIB_ROLE_UIDS => exit 3, CMD not run" "$RC|$(ran)|$(uidmsg)" "3|not-run|1"
has "T1: …stderr says why" "$ERR" "uid"
ll -- --uid "$ME" --gid "$MG" "${touch_cmd[@]}";                                        eq "T1: AIB_ROLE_UIDS unset => nobody allowed (exit 3)" "$RC|$(ran)|$(uidmsg)" "3|not-run|1"
ll AIB_ROLE_UIDS= -- --uid "$ME" --gid "$MG" "${touch_cmd[@]}";                         eq "T1: AIB_ROLE_UIDS empty => nobody allowed (exit 3)" "$RC|$(ran)|$(uidmsg)" "3|not-run|1"
ll AIB_ROLE_UIDS="50,${ME}00" -- --uid "${ME}0" --gid "$MG" "${touch_cmd[@]}" 2>/dev/null; eq "T1: a uid that is only a textual prefix/suffix of a listed one is not listed" "$RC|$(ran)|$(uidmsg)" "3|not-run|1"
ll AIB_ROLE_UIDS="${ME}1,2${ME}" -- --uid "$ME" --gid "$MG" "${touch_cmd[@]}";           eq "T1: …(whole-token match: $ME vs ${ME}1,2$ME)" "$RC|$(ran)|$(uidmsg)" "3|not-run|1"
ll AIB_ROLE_UIDS="$ME" -- --uid "$ME" --uid "$ME" --gid "$MG" "${touch_cmd[@]}";        eq "T1: a repeated option => exit 2" "$RC|$(ran)" "2|not-run"
# gate round 1 (Marvin G1/G2): the floor is numeric, and a neighbouring uid is not the listed one
for low in 999 33 1; do
  ll AIB_ROLE_UIDS="$low,$ME" -- --uid "$low" --gid "$low" "${touch_cmd[@]}";           eq "T1: uid $low (< 1000, system range) is refused even when listed => exit 3, CMD not run" "$RC|$(ran)|$(uidmsg)" "3|not-run|1"
done
ll AIB_ROLE_UIDS="$ME" -- --uid "$(( ME + 1 ))" --gid "$MG" "${touch_cmd[@]}";           eq "T1: uid ME+1 requested while only ME is listed => exit 3 (numeric, not textual, neighbour)" "$RC|$(ran)|$(uidmsg)" "3|not-run|1"
ll AIB_ROLE_UIDS="$(( ME + 1 ))" -- --uid "$ME" --gid "$MG" "${touch_cmd[@]}";           eq "T1: …and the other way round (ME requested, ME+1 listed)" "$RC|$(ran)|$(uidmsg)" "3|not-run|1"
ll AIB_ROLE_UIDS="$(( ME / 10 * 10 ))" -- --uid "$ME" --gid "$MG" "${touch_cmd[@]}"
[ "$(( ME / 10 * 10 ))" = "$ME" ] && skip "T1: decade neighbour is ME itself on this host" || eq "T1: …a uid in the same decade (ME/10 equal) is not the listed one" "$RC|$(ran)|$(uidmsg)" "3|not-run|1"

# --- T1g (design v3.5 L1) `--groups <gid,...>`: strict, allow-listed by the unit env AIB_ROLE_GROUPS, decided before any Landlock work --------------------
# Invocation: landlock-exec --uid U --gid G [--groups g1,g2,...] CMD...   (--groups only together with --uid/--gid; at most once)
#   malformed list (not strict decimal, empty element, spaces, sign, hex, overflow, empty list)   => exit 2 (usage), CMD not run
#   gid 0, a gid not in AIB_ROLE_GROUPS (whole-token match), AIB_ROLE_GROUPS unset/empty => exit 3, CMD not run, message names `group`
#   v3.6 M1: NO numeric floor for groups (system groups such as aib-shared have gids < 1000): a listed gid 1..999 passes the group policy.
groupmsg() { printf '%s\n%s' "$STATUS" "$ERR" | grep -ci 'group' | awk '{print ($1>0)?1:0}'; }
# The policy checks use the caller as the role uid; as root that is uid 0, which the uid policy refuses first. Root runs cover
# the real switch in T3/T4, so T1g runs as non-root only.
if [ "$ME" -ne 0 ]; then
UG=(--uid "$ME" --gid "$MG")
ll AIB_ROLE_UIDS="$ME" AIB_ROLE_GROUPS="5000,5001" -- --groups 5000 "${touch_cmd[@]}";           eq "T1g: --groups without --uid/--gid => exit 2, CMD not run" "$RC|$(ran)" "2|not-run"
for bad in '' abc -1 +5000 1e3 0x3e8 ' 5000' '5000 ' '5000,' ',5000' '5000,,5001' '5000 5001' '5000;5001' '5000.5' 99999999999999999999 '5000,abc'; do
  ll AIB_ROLE_UIDS="$ME" AIB_ROLE_GROUPS="5000,5001" -- "${UG[@]}" --groups "$bad" "${touch_cmd[@]}"; eq "T1g: --groups '$bad' (not a strict decimal comma list) => exit 2, CMD not run" "$RC|$(ran)" "2|not-run"
done
ll AIB_ROLE_UIDS="$ME" AIB_ROLE_GROUPS="5000,5001" -- "${UG[@]}" --groups 5000 --groups 5001 "${touch_cmd[@]}"; eq "T1g: a repeated --groups => exit 2, CMD not run" "$RC|$(ran)" "2|not-run"
ll AIB_ROLE_UIDS="$ME" AIB_ROLE_GROUPS="5000,5001" -- "${UG[@]}" --groups 5002 "${touch_cmd[@]}";    eq "T1g: a gid outside AIB_ROLE_GROUPS => exit 3, CMD not run, the refusal names the group" "$RC|$(ran)|$(groupmsg)" "3|not-run|1"
has "T1g: …the refusal reaches the status fd as one confine: line" "$STATUS" "confine:"
has "T1g: …and that line says group" "$STATUS" "group"
ll AIB_ROLE_UIDS="$ME" AIB_ROLE_GROUPS="5000,5001" -- "${UG[@]}" --groups 5000,5002 "${touch_cmd[@]}"; eq "T1g: one listed + one unlisted gid => exit 3 (all-or-nothing), CMD not run" "$RC|$(ran)|$(groupmsg)" "3|not-run|1"
ll AIB_ROLE_UIDS="$ME" -- "${UG[@]}" --groups 5000 "${touch_cmd[@]}";                                 eq "T1g: AIB_ROLE_GROUPS unset => nobody allowed (exit 3)" "$RC|$(ran)|$(groupmsg)" "3|not-run|1"
ll AIB_ROLE_UIDS="$ME" AIB_ROLE_GROUPS= -- "${UG[@]}" --groups 5000 "${touch_cmd[@]}";                 eq "T1g: AIB_ROLE_GROUPS empty => nobody allowed (exit 3)" "$RC|$(ran)|$(groupmsg)" "3|not-run|1"
ll AIB_ROLE_UIDS="$ME" AIB_ROLE_GROUPS="0,5000" -- "${UG[@]}" --groups 0 "${touch_cmd[@]}";           eq "T1g: gid 0 is refused even when listed => exit 3" "$RC|$(ran)|$(groupmsg)" "3|not-run|1"
ll AIB_ROLE_UIDS="$ME" AIB_ROLE_GROUPS="5000,0" -- "${UG[@]}" --groups 5000,0 "${touch_cmd[@]}";       eq "T1g: …also as the second element of the list" "$RC|$(ran)|$(groupmsg)" "3|not-run|1"
# FLIPPED in v3.6 (M1): v3.5 L1 refused a listed gid < 1000. On the VM aib-shared / aib-login / aib-gateway are system groups (gid < GID_MIN), so the floor
# would refuse exactly the groups the role needs; the control is the allow-list. A listed low gid is NOT refused by the group policy: no usage error, no
# `group` refusal. (Without Landlock on this host the helper then stops later with "unavailable"; with Landlock the CMD runs.)
for low in 999 989 33 1; do
  ll AIB_ROLE_UIDS="$ME" AIB_ROLE_GROUPS="$low,5000" -- "${UG[@]}" --groups "$low" "${touch_cmd[@]}"
  case "$RC" in 0) post="ran:$(ran)";; 3) post="landlock:$(printf '%s' "$ERR" | grep -c 'unavailable')";; *) post="other:$RC";; esac
  eq "T1g: (v3.6) a listed gid $low (< 1000) passes the group policy: not exit 2, no group refusal" "$(groupmsg)|$post" "0|$(case "$RC" in 0) echo ran:ran;; *) echo landlock:1;; esac)"
done
ll AIB_ROLE_UIDS="$ME" AIB_ROLE_GROUPS="5000" -- "${UG[@]}" --groups 989 "${touch_cmd[@]}"
eq "T1g: …while the same low gid UNLISTED is still refused (exit 3, group message)" "$RC|$(groupmsg)" "3|1"
ll AIB_ROLE_UIDS="$ME" AIB_ROLE_GROUPS="0,989" -- "${UG[@]}" --groups 989,0 "${touch_cmd[@]}"
eq "T1g: …and a 0 entry in the allow-list never makes gid 0 usable (exit 3)" "$RC|$(ran)|$(groupmsg)" "3|not-run|1"
ll AIB_ROLE_UIDS="$ME" AIB_ROLE_GROUPS="50000" -- "${UG[@]}" --groups 5000 "${touch_cmd[@]}";         eq "T1g: whole-token match: 5000 is not in '50000'" "$RC|$(ran)|$(groupmsg)" "3|not-run|1"
ll AIB_ROLE_UIDS="$ME" AIB_ROLE_GROUPS="5000" -- "${UG[@]}" --groups 50000 "${touch_cmd[@]}";         eq "T1g: …nor 50000 in '5000'" "$RC|$(ran)|$(groupmsg)" "3|not-run|1"
ll AIB_ROLE_UIDS="$ME" AIB_ROLE_GROUPS="15000,25000" -- "${UG[@]}" --groups 5000 "${touch_cmd[@]}";    eq "T1g: …nor 5000 in '15000,25000' (suffix)" "$RC|$(ran)|$(groupmsg)" "3|not-run|1"
ll AIB_ROLE_UIDS="$ME" AIB_ROLE_GROUPS="5001" -- "${UG[@]}" --groups 5000 "${touch_cmd[@]}";           eq "T1g: …nor a numeric neighbour (5000 requested, 5001 listed)" "$RC|$(ran)|$(groupmsg)" "3|not-run|1"
ll AIB_ROLE_UIDS="5000" AIB_ROLE_GROUPS="5000" -- "${UG[@]}" --groups 5000 "${touch_cmd[@]}";           eq "T1g: a good group list does not rescue an unlisted uid (the uid policy still refuses, exit 3)" "$RC|$(ran)|$(uidmsg)" "3|not-run|1"
else
  skip "T1g: the group policy checks use the caller as the role uid and run as non-root only (root: see T3/T4)"
fi

# --- T2 what a permitted switch does (needs Landlock; as non-root only the identity-preserving switch is possible) ----------------------------------
ll -- /bin/true
if [ "$RC" -ne 0 ]; then
  skip "T2: Landlock is not usable on this host (plain 'landlock-exec /bin/true' => rc $RC: $(printf '%s' "$ERR" | head -c 120)) — behavioural switch cases"
else
  if [ "$ME" -eq 0 ]; then
    skip "T2: the own-uid switch is the non-root path (uid 0 is refused by policy, T1); root runs the drop block below"
  else
  ll AIB_ROLE_UIDS="5000,$ME" -- --uid "$ME" --gid "$MG" /bin/sh -c "touch '$SENT'; id -u; id -g; grep -E '^(CapEff|CapPrm|CapInh|CapAmb|NoNewPrivs):' /proc/self/status; env | grep -cE '^(AIB_ROLE_UIDS|LL_)' || true"
  eq "T2: a listed uid (our own: the no-op switch a non-root caller can make) => rc 0, CMD runs as that uid/gid" "$RC|$(printf '%s\n' "$OUT" | sed -n 1,2p | tr '\n' ' ')|$(ran)" "0|$ME $MG |ran"
  eq "T2: …CapPrm/CapEff/CapInh/CapAmb all empty and no_new_privs set (CapBnd not asserted: v3.3)" "$(printf '%s\n' "$OUT" | grep -E '^Cap(Eff|Prm|Inh|Amb):' | awk '{print $2}' | sort -u | tr '\n' ' ')|$(printf '%s\n' "$OUT" | grep -c '^Cap\(Eff\|Prm\|Inh\|Amb\):')|$(printf '%s\n' "$OUT" | grep '^NoNewPrivs:' | awk '{print $2}')" "0000000000000000 |4|1"
  eq "T2: …the child sees neither AIB_ROLE_UIDS nor LL_*" "$(printf '%s\n' "$OUT" | tail -1)" 0
  rm -f "$WORK/outside/c" "$WORK/outside/x" "$WORK/rw/x"
  touch "$WORK/outside/c" 2>/dev/null && echo wrote > "$WORK/ctl" || echo denied > "$WORK/ctl"
  eq "T2: control: WITHOUT the helper the same write outside succeeds (DAC allows it, so a denial below is Landlock)" "$(cat "$WORK/ctl")" wrote
  ll AIB_ROLE_UIDS="$ME" -- --uid "$ME" --gid "$MG" /bin/sh -c "if touch '$WORK/outside/x' 2>/dev/null; then echo wrote; else echo denied; fi; if touch '$WORK/rw/x'; then echo rw-ok; else echo rw-denied; fi"
  eq "T2: Landlock still binds after the switch: write outside LL_RW denied, inside allowed" "$(printf '%s\n' "$OUT" | tr '\n' ' ')" "denied rw-ok "
  fi
  ll AIB_ROLE_UIDS="$ME" -- /bin/sh -c "echo plain-$ME"
  eq "T2: without --uid the helper behaves as before (CMD runs, nothing refused even with the list set)" "$RC|$OUT" "0|plain-$ME"
  if [ "$(id -u)" -ne 0 ]; then
    skip "T2: real privilege drop (setgroups + setgid + setuid to another account, caps cleared) needs root; run this spec as root on the dev VM"
  else
    ll AIB_ROLE_UIDS="65534" -- --uid 65534 --gid 65534 /bin/sh -c "id -u; id -g; id -G; grep -E '^(CapEff|CapPrm|CapInh|CapAmb|CapBnd):' /proc/self/status | awk '{print \$2}' | sort -u | tr '\n' ' '; grep '^NoNewPrivs:' /proc/self/status | awk '{print \$2}'"
    eq "T2 (root): drops to 65534:65534, supplementary groups emptied to the gid alone, ALL cap sets incl. CapBnd empty, no_new_privs 1" "$RC|$(printf '%s\n' "$OUT" | tr '\n' ' ')" "0|65534 65534 65534 0000000000000000 1 "
    rm -f "$WORK/outside/y"
    "$CC" -x c -O2 -o "$WORK/asuid" - <<'CEOF' 2>/dev/null
#include <unistd.h>
#include <grp.h>
int main(int c,char**v){ if(setgroups(0,0)||setgid(65534)||setuid(65534)) return 99; execvp(v[1],v+1); return 98; }
CEOF
    if [ -x "$WORK/asuid" ]; then
      RC=0; "$WORK/asuid" touch "$WORK/outside/y" 2>/dev/null || RC=$?
      eq "T2 (root): control: as 65534 WITHOUT the helper the write outside succeeds (DAC allows it)" "$RC|$([ -e "$WORK/outside/y" ] && echo there)" "0|there"
    else
      no "T2 (root): control: could not build the uid-switch helper for the DAC control"
    fi
    rm -f "$WORK/outside/y"
    ll AIB_ROLE_UIDS="65534" -- --uid 65534 --gid 65534 /bin/sh -c "if touch '$WORK/outside/y' 2>/dev/null; then echo wrote; else echo denied; fi"
    eq "T2 (root): …and Landlock was installed BEFORE the drop: the dropped child cannot write outside LL_RW (DAC would allow it)" "$OUT" denied
    ll AIB_ROLE_UIDS="65534" -- --uid 65534 --gid 65534 /bin/sh -c 'kill -0 1 2>/dev/null; id -u'
    eq "T2 (root): a child cannot get uid 0 back (setuid(0) is denied)" "$(ll AIB_ROLE_UIDS=65534 -- --uid 65534 --gid 65534 /usr/bin/python3 -c 'import os
try:
    os.setuid(0); print("regained")
except PermissionError: print("denied")'; printf '%s' "$OUT")" denied
  fi
fi

# --- T3 (design v3.5 L1) supplementary groups: setgroups(list) -> setgid -> setuid after restrict_self; without --groups they stay empty ---------------
# Needs real root and a Landlock kernel (skips cleanly otherwise). The group ids need not exist on the host; the probe reads getgroups(2) in the child.
GRP='import os; print(" ".join(map(str, sorted(os.getgroups()))))'
if [ "$ME" -ne 0 ]; then
  skip "T3: the supplementary-group switch needs root; run this spec as root on the dev VM"
else
  ll -- /bin/true
  if [ "$RC" -ne 0 ]; then
    skip "T3: Landlock is not usable on this host (rc $RC) — behavioural group cases"
  else
    ll AIB_ROLE_UIDS=65534 AIB_ROLE_GROUPS="60001,60002,60003" -- --uid 65534 --gid 65534 /usr/bin/python3 -I -c "$GRP"
    eq "T3 (root): WITHOUT --groups the supplementary list stays empty, even with AIB_ROLE_GROUPS set in the env" "$RC|$OUT" "0|"
    ll AIB_ROLE_UIDS=65534 AIB_ROLE_GROUPS="60001,60002,60003" -- --uid 65534 --gid 65534 --groups 60001,60002 /usr/bin/python3 -I -c "$GRP"
    eq "T3 (root): --groups 60001,60002 => the child's supplementary groups are exactly those two" "$RC|$OUT" "0|60001 60002"
    ll AIB_ROLE_UIDS=65534 AIB_ROLE_GROUPS="60001,60002,60003" -- --uid 65534 --gid 65534 --groups 60003 /usr/bin/python3 -I -c "$GRP"
    eq "T3 (root): a single group" "$RC|$OUT" "0|60003"
    ll AIB_ROLE_UIDS=65534 AIB_ROLE_GROUPS="60001,60002,60003" -- --uid 65534 --gid 65534 --groups 60002,60001 /usr/bin/python3 -I -c "$GRP"
    eq "T3 (root): the order of the list does not matter" "$RC|$OUT" "0|60001 60002"
    ll AIB_ROLE_UIDS=65534 AIB_ROLE_GROUPS="60001,60002" -- --uid 65534 --gid 65534 --groups 60001 /usr/bin/python3 -I -c 'import os
for g in ([0], [60001, 60002]):
    try:
        os.setgroups(g); print("changed")
    except PermissionError: print("denied")'
    eq "T3 (root): after the switch the child cannot change its groups (setgroups denied, caps cleared)" "$OUT" "$(printf 'denied\ndenied')"
    ll AIB_ROLE_UIDS=65534 AIB_ROLE_GROUPS="60001" -- --uid 65534 --gid 65534 --groups 60001 /bin/sh -c 'env | grep -cE "^(AIB_ROLE_UIDS|AIB_ROLE_GROUPS|LL_)" || true'
    eq "T3 (root): the child sees none of AIB_ROLE_UIDS / AIB_ROLE_GROUPS / LL_*" "$OUT" 0
    ll AIB_ROLE_UIDS=65534 AIB_ROLE_GROUPS="60001" -- --uid 65534 --gid 65534 --groups 60001 /bin/sh -c "if touch '$WORK/outside/g' 2>/dev/null; then echo wrote; else echo denied; fi"
    eq "T3 (root): Landlock still binds the child that carries supplementary groups (restrict_self came first)" "$OUT" denied
    ll AIB_ROLE_UIDS=65534 AIB_ROLE_GROUPS="60001" -- --uid 65534 --gid 65534 --groups 60001,60009 /bin/sh -c ": > '$SENT'"
    eq "T3 (root): an unlisted gid in the list refuses BEFORE anything is switched: exit 3, CMD not run" "$RC|$(ran)" "3|not-run"
  fi
fi

# --- T4 (design v3.5 L1) VM cross-uid acceptance ------------------------------------------------------------------------------------------------------
# Env-gated like the other VM cases: AIB_VM_ROLE_USER=<the real role account>, run as root on the VM where the groups aib-shared and aib-login exist.
# As that account, through the helper with --groups "<aib-shared>,<aib-login>": read a token buffer and a codex store (group aib-login), append to
# _control.jsonl and to the team outbox (group aib-shared). The fixtures are fakes made here (no real credentials).
RU="${AIB_VM_ROLE_USER:-}"
if [ -z "$RU" ]; then
  skip "T4: the VM cross-uid acceptance needs AIB_VM_ROLE_USER=<role account> (root, on the VM with groups aib-shared and aib-login)"
elif [ "$ME" -ne 0 ]; then
  no "T4: AIB_VM_ROLE_USER is set but the spec does not run as root"
else
  RUID="$(id -u "$RU" 2>/dev/null)"; RGID="$(id -g "$RU" 2>/dev/null)"
  SG="$(getent group aib-shared | cut -d: -f3)"; LG="$(getent group aib-login | cut -d: -f3)"
  if [ -z "$RUID" ] || [ -z "$SG" ] || [ -z "$LG" ] || [ "$RUID" -lt 1000 ]; then
    no "T4: AIB_VM_ROLE_USER='$RU' needs a uid >= 1000 and the groups aib-shared / aib-login to exist (uid '$RUID', shared '$SG', login '$LG')"
  else
    VMD="$WORK/vm"; mkdir -p "$VMD/login/codex" "$VMD/shared/outbox"; chmod o+x "$WORK" "$VMD"
    chown root:aib-login "$VMD/login" "$VMD/login/codex"; chmod 2770 "$VMD/login" "$VMD/login/codex"
    printf 'fake-claude-token-buffer' > "$VMD/login/claude.buf"; printf '{"fake":"codex-store"}' > "$VMD/login/codex/auth.json"
    chown root:aib-login "$VMD/login/claude.buf" "$VMD/login/codex/auth.json"; chmod 640 "$VMD/login/claude.buf" "$VMD/login/codex/auth.json"
    chown root:aib-shared "$VMD/shared" "$VMD/shared/outbox"; chmod 2770 "$VMD/shared" "$VMD/shared/outbox"
    : > "$VMD/shared/_control.jsonl"; : > "$VMD/shared/outbox/team.md"
    chown root:aib-shared "$VMD/shared/_control.jsonl" "$VMD/shared/outbox/team.md"; chmod 660 "$VMD/shared/_control.jsonl" "$VMD/shared/outbox/team.md"
    cat > "$VMD/probe.sh" <<PROBE
#!/bin/sh
b=\$(cat '$VMD/login/claude.buf' 2>>'$WORK/rw/probe.err'); c=\$(cat '$VMD/login/codex/auth.json' 2>>'$WORK/rw/probe.err')
[ "\$b" = fake-claude-token-buffer ] && echo buffer-read || echo buffer-denied
[ -n "\$c" ] && echo codex-read || echo codex-denied
echo '{"k":1}' >> '$VMD/shared/_control.jsonl' 2>>'$WORK/rw/probe.err' && echo control-append || echo control-denied
echo 'line' >> '$VMD/shared/outbox/team.md' 2>>'$WORK/rw/probe.err' && echo outbox-append || echo outbox-denied
PROBE
    chmod 755 "$VMD/probe.sh"
    run_role() { # run_role [--groups list]   (the full list is always in the unit allow-list)
      local gl=(); [ $# -eq 0 ] || gl=(--groups "$2")
      ll AIB_ROLE_UIDS="$RUID" AIB_ROLE_GROUPS="$SG,$LG" LL_RW="$WORK/rw:/tmp:$VMD/shared" -- --uid "$RUID" --gid "$RGID" "${gl[@]}" "$VMD/probe.sh"
    }
    run_role
    eq "T4 (VM): control: as '$RU' WITHOUT --groups none of the four resources is reachable (DAC says no)" "$(printf '%s\n' "$OUT" | tr '\n' ' ')" "buffer-denied codex-denied control-denied outbox-denied "
    run_role --groups "$LG"
    eq "T4 (VM): …with only the aib-login group the stores are readable but the shared files are not appendable" "$(printf '%s\n' "$OUT" | tr '\n' ' ')" "buffer-read codex-read control-denied outbox-denied "
    run_role --groups "$SG,$LG"
    eq "T4 (VM): with --groups aib-shared,aib-login '$RU' reads the claude fd buffer and the codex store and appends to _control.jsonl and the team outbox" "$(printf '%s\n' "$OUT" | tr '\n' ' ')" "buffer-read codex-read control-append outbox-append "
    eq "T4 (VM): …and the appended bytes really are in the files" "$(grep -c '"k":1' "$VMD/shared/_control.jsonl")|$(grep -c '^line$' "$VMD/shared/outbox/team.md")" "1|1"
  fi
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
