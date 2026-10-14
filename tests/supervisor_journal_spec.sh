#!/usr/bin/env bash
# ai-bobnet — RED spec for the supervisor journal's crash safety and single-writer rule
# (Supervisor slice S1a-2, delta round 1; review findings on torn tails and the missing writer lock).
#
# WHAT THIS PINS
#   - Tail repair: a kill or power loss mid-append leaves a PARTIAL final line (no trailing newline).
#     At boot that single trailing fragment is truncated away and a `journal.repaired {dropped_bytes}`
#     record is appended (seq continues from the last good record); the supervisor then runs normally.
#   - Nothing else is "repaired": a corrupt line in the middle, or a corrupt final line that DID end in
#     a newline, means the journal cannot be trusted — the supervisor exits 78 (EX_CONFIG: restart cannot
#     help, unit RestartPreventExitStatus=78) and leaves the file byte-for-byte untouched.
#   - Single writer: the process holds an exclusive flock on <state>/supervisor.lock for its whole life,
#     INCLUDING across the in-process re-exec (no gap in which a second instance could slip in). A second
#     instance for the same agent exits 78 without writing to the journal (it must not interleave seq).
#
#   Expected on the unbuilt-for-this-delta tree: the torn tail makes the supervisor exit instead of
#   repairing, and no lock file exists.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/fixtures/sup_harness.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-supjrn.XXXXXX")"
trap sup_cleanup EXIT
ts="2026-01-01T00:00:00Z"
good() { printf '{"seq":1,"ts":"%s","event":"supervisor.started","pid":1,"reexec":false}\n{"seq":2,"ts":"%s","event":"supervisor.stopping"}\n{"seq":3,"ts":"%s","event":"supervisor.started","pid":2,"reexec":false}\n' "$ts" "$ts" "$ts"; }
sum() { cksum < "$JOURNAL"; }

# --- T1 torn tail is truncated and journalled -----------------------------------------
sup_world torn
frag='{"seq":4,"ts":"2026-01-01T00:00:01Z","event":"turn.sta'
{ good; printf '%s' "$frag"; } > "$JOURNAL"
start_sup
wait_for 8 lj_is state READY
eq "T1: the supervisor runs after a torn tail (READY)" "$(lj state)" READY
eq "T1: …the fragment is gone from the file" "$(grep -c 'turn.sta' "$JOURNAL")" 0
eq "T1: …every line parses and seq is 1,2,3,… gap-free" "$(python3 -I "$SJ" valid "$JOURNAL")" ok
eq "T1: journal.repaired journalled once" "$(jcount journal.repaired)" 1
eq "T1: …with the dropped byte count" "$(jfield journal.repaired 1 dropped_bytes)" "${#frag}"
eq "T1: …as the next seq after the last good record" "$(python3 -I "$SJ" first "$JOURNAL" journal.repaired dropped_bytes "${#frag}")" 4
eq "T1: the earlier good records are untouched" "$(head -n 3 "$JOURNAL" | cksum)" "$(good | cksum)"
stop_sup

# --- T2 anything else that does not parse is NOT repaired -----------------------------
sup_world mid
{ head -n 1 <(good); printf 'this is not json\n'; tail -n 1 <(good); } > "$JOURNAL"; before="$(sum)"
start_sup; sp=$SUP_PID; wait_exit "$sp"; rc=$RC; SUP_PID=""
eq "T2: a corrupt line in the MIDDLE => exit 78" "$rc" 78
eq "T2: …the journal is left byte-for-byte untouched" "$(sum)" "$before"
sup_world endnl
{ good; printf '{"seq":4,"ts":"x","ev\n'; } > "$JOURNAL"; before="$(sum)"
start_sup; sp=$SUP_PID; wait_exit "$sp"; rc=$RC; SUP_PID=""
eq "T2: a corrupt FINAL line that ended in a newline => exit 78" "$rc" 78
eq "T2: …the journal is left byte-for-byte untouched" "$(sum)" "$before"
eq "T2: …and no READY=1 was sent" "$([ "$rc" = 78 ] && grep -cx 'READY=1' "$W/notify.log")" 0

# --- T3 single writer ------------------------------------------------------------------
sup_world lock
start_sup; first=$SUP_PID
wait_for 8 lj_is state READY
if flock -n "$STATE/supervisor.lock" true 2>/dev/null; then no "T3: the running supervisor holds <state>/supervisor.lock"; else
  [ -e "$STATE/supervisor.lock" ] && ok "T3: the running supervisor holds <state>/supervisor.lock" || no "T3: the running supervisor holds <state>/supervisor.lock (no such file)"; fi
before="$(sum)"; lines="$(wc -l < "$JOURNAL")"
start_sup; second=$SUP_PID; SUP_PID=$first
wait_exit "$second"; rc=$RC
eq "T3: a second instance for the same agent exits 78" "$rc" 78
eq "T3: …and wrote nothing to the journal (no interleaved seq)" "$(wc -l < "$JOURNAL")" "$lines"
eq "T3: …the first instance is unharmed" "$(lj state)" READY
# the lock survives the in-process re-exec
kill -USR1 "$first"
wait_for 8 bash -c "[ \"\$(python3 -I '$SJ' count '$JOURNAL' supervisor.started)\" -ge 2 ]"
wait_for 8 lj_is state READY
if flock -n "$STATE/supervisor.lock" true 2>/dev/null; then no "T3: the lock is still held after the re-exec"; else ok "T3: the lock is still held after the re-exec"; fi
start_sup; second=$SUP_PID; SUP_PID=$first
wait_exit "$second"; rc=$RC
eq "T3: …so a second instance is still refused after the re-exec (exit 78)" "$rc" 78
stop_sup
if flock -n "$STATE/supervisor.lock" true 2>/dev/null; then ok "T3: the lock is released when the supervisor stops"; else no "T3: the lock is released when the supervisor stops"; fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
