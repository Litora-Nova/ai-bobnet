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
#     3. all capabilities (permitted, effective, inheritable, ambient, bounding) are cleared, no_new_privs stays set,  4. CMD is exec'd.
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
ll AIB_ROLE_UIDS="50,${ME}0" -- --uid "${ME}0" --gid "$MG" "${touch_cmd[@]}" 2>/dev/null; eq "T1: a uid that is only a textual prefix/suffix of a listed one is not listed" "$RC|$(ran)|$(uidmsg)" "3|not-run|1"
ll AIB_ROLE_UIDS="${ME}1,2${ME}" -- --uid "$ME" --gid "$MG" "${touch_cmd[@]}";           eq "T1: …(whole-token match: $ME vs ${ME}1,2$ME)" "$RC|$(ran)|$(uidmsg)" "3|not-run|1"
ll AIB_ROLE_UIDS="$ME" -- --uid "$ME" --uid "$ME" --gid "$MG" "${touch_cmd[@]}";        eq "T1: a repeated option => exit 2" "$RC|$(ran)" "2|not-run"

# --- T2 what a permitted switch does (needs Landlock; as non-root only the identity-preserving switch is possible) ----------------------------------
ll -- /bin/true
if [ "$RC" -ne 0 ]; then
  skip "T2: Landlock is not usable on this host (plain 'landlock-exec /bin/true' => rc $RC: $(printf '%s' "$ERR" | head -c 120)) — behavioural switch cases"
else
  ll AIB_ROLE_UIDS="5000,$ME" -- --uid "$ME" --gid "$MG" /bin/sh -c ": > '$SENT'; id -u; id -g; grep -E '^(CapEff|CapPrm|CapInh|CapAmb|CapBnd|NoNewPrivs):' /proc/self/status; env | grep -cE '^(AIB_ROLE_UIDS|LL_)'"
  eq "T2: a listed uid (our own: the no-op switch a non-root caller can make) runs CMD as that uid/gid" "$RC|$(printf '%s\n' "$OUT" | sed -n 1,2p | tr '\n' ' ')" "0|$ME $MG "
  eq "T2: …with ALL capability sets empty (incl. bounding) and no_new_privs set" "$(printf '%s\n' "$OUT" | grep -E '^Cap(Eff|Prm|Inh|Amb|Bnd):' | awk '{print $2}' | sort -u | tr '\n' ' ')|$(printf '%s\n' "$OUT" | grep '^NoNewPrivs:' | awk '{print $2}')" "0000000000000000 |1"
  eq "T2: …the child sees neither AIB_ROLE_UIDS nor LL_*" "$(printf '%s\n' "$OUT" | tail -1)" 0
  ll AIB_ROLE_UIDS="$ME" -- --uid "$ME" --gid "$MG" /bin/sh -c ": > '$WORK/outside/x' 2>/dev/null && echo wrote || echo denied; : > '$WORK/rw/x' && echo rw-ok"
  eq "T2: Landlock still binds after the switch: write outside LL_RW denied, inside allowed" "$(printf '%s\n' "$OUT" | tr '\n' ' ')" "denied rw-ok "
  ll AIB_ROLE_UIDS="$ME" -- /bin/sh -c "echo plain-$ME"
  eq "T2: without --uid the helper behaves as before (CMD runs, nothing refused even with the list set)" "$RC|$OUT" "0|plain-$ME"
  if [ "$(id -u)" -ne 0 ]; then
    skip "T2: real privilege drop (setgroups + setgid + setuid to another account, caps cleared) needs root; run this spec as root on the dev VM"
  else
    ll AIB_ROLE_UIDS="65534" -- --uid 65534 --gid 65534 /bin/sh -c "id -u; id -g; id -G; grep '^CapEff:' /proc/self/status | awk '{print \$2}'"
    eq "T2 (root): drops to 65534:65534, supplementary groups emptied to the gid alone, CapEff empty" "$RC|$(printf '%s\n' "$OUT" | tr '\n' ' ')" "0|65534 65534 65534 0000000000000000 "
    ll AIB_ROLE_UIDS="65534" -- --uid 65534 --gid 65534 /bin/sh -c ": > '$WORK/outside/y' 2>/dev/null && echo wrote || echo denied"
    eq "T2 (root): …and Landlock was installed BEFORE the drop: the dropped child cannot write outside LL_RW" "$OUT" denied
    ll AIB_ROLE_UIDS="65534" -- --uid 65534 --gid 65534 /bin/sh -c 'kill -0 1 2>/dev/null; id -u'
    eq "T2 (root): a child cannot get uid 0 back (setuid(0) is denied)" "$(ll AIB_ROLE_UIDS=65534 -- --uid 65534 --gid 65534 /usr/bin/python3 -c 'import os
try:
    os.setuid(0); print("regained")
except PermissionError: print("denied")'; printf '%s' "$OUT")" denied
  fi
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
