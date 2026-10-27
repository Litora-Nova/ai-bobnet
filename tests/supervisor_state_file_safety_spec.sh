#!/usr/bin/env bash
# ai-bobnet — supervisor state access never follows role-account-controlled links.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/fixtures/sup_harness.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-supstate.XXXXXX")"
trap sup_cleanup EXIT

snapshot() { stat -c '%a:%s:%Y' "$1"; cksum < "$1"; }

# --- T1 a planted journal symlink is refused without touching its target ----------
sup_world journal-symlink
protected="$W/protected"
printf '{"seq":1,"ts":"2026-01-01T00:00:00Z","event":"supervisor.stopping"}\n' > "$protected"
chmod 0600 "$protected"
before="$(snapshot "$protected")"
ln -s "$protected" "$JOURNAL"
start_sup; sp=$SUP_PID; wait_exit "$sp"; rc=$RC; SUP_PID=""
eq "T1: a symlinked journal is a fatal state refusal" "$rc" 78
eq "T1: the symlink target's mode and content are unchanged" "$(snapshot "$protected")" "$before"
has "T1: the refusal names the unsafe journal" "$(cat "$W/sup.out")" "journal.jsonl"

# --- T2 a stale live tmp symlink is unlinked, never followed ----------------------
sup_world live-tmp-symlink
protected="$W/protected"
printf 'operator data\n' > "$protected"
chmod 0600 "$protected"
before="$(snapshot "$protected")"
ln -s "$protected" "$STATE/.live.424242.tmp"
STATE_DIRECTORY="$STATE" python3 -I - "$ENGINE/lib/aib_supervisor.py" <<'PY'
import importlib.util
import os
import sys

spec = importlib.util.spec_from_file_location("aib_supervisor", sys.argv[1])
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

supervisor = module.Supervisor(module.Path(sys.argv[1]).resolve().parent.parent, "acme-core")
module.os.getpid = lambda: 424242
supervisor.write_live()
PY
eq "T2: the tmp symlink target's mode and content are unchanged" "$(snapshot "$protected")" "$before"
if [ -f "$LIVE" ] && [ ! -L "$LIVE" ]; then
  ok "T2: live.json is replaced with a regular file"
else
  no "T2: live.json is replaced with a regular file"
fi

# --- T3 a multiply-linked journal is refused without touching the other name ------
sup_world journal-hardlink
protected="$W/protected"
: > "$protected"
chmod 0600 "$protected"
ln "$protected" "$JOURNAL"
before="$(snapshot "$protected")"
start_sup; sp=$SUP_PID; wait_exit "$sp"; rc=$RC; SUP_PID=""
eq "T3: a hardlinked journal is a fatal state refusal" "$rc" 78
eq "T3: the other hardlink's mode and content are unchanged" "$(snapshot "$protected")" "$before"
has "T3: the refusal names the unsafe journal" "$(cat "$W/sup.out")" "journal.jsonl"

# --- T4 a planted live-state symlink is refused without reading its target --------
sup_world live-symlink
protected="$W/protected-live"
printf '{"seq":987654321,"secret":"LIVE-SYMLINK-SECRET"}\n' > "$protected"
chmod 0600 "$protected"
before="$(snapshot "$protected")"
ln -s "$protected" "$LIVE"
start_sup; sp=$SUP_PID; wait_exit "$sp"; rc=$RC; SUP_PID=""
eq "T4: a symlinked live.json is a fatal state refusal" "$rc" 78
eq "T4: the live.json symlink target is unchanged" "$(snapshot "$protected")" "$before"
has "T4: the refusal names the unsafe live state" "$(cat "$W/sup.out")" "live.json"

# --- T5 an in-flight turn-output symlink fails the turn without disclosure --------
sup_world turn-output-symlink
protected="$W/protected-output"
sentinel="TURN-OUTPUT-SYMLINK-SECRET"
printf '%s already in use\n' "$sentinel" > "$protected"
chmod 0600 "$protected"
m_send m-1 "replace my output path"
plan "1|0.5|benign provider failure"
start_sup AIB_SUP_BACKOFF_BASE_S=5 AIB_SUP_BACKOFF_CAP_S=5
wait_for 8 lj_is state WORKING
attempt_id="$(lj turn.attempt_id)"
turn_output="$STATE/.turn-$attempt_id.out"
wait_for 8 test -f "$turn_output"
rm -f -- "$turn_output"
ln -s "$protected" "$turn_output"
wait_for 8 bash -c "[ \"\$(python3 -I '$SJ' count '$JOURNAL' turn.ended)\" -ge 1 ]"
eq "T5: refused turn output is a provider failure with a clear reason" \
  "$(jfield turn.ended 1 class)|$(jfield turn.ended 1 reason)" \
  "provider_failure|unsafe_turn_output"
observed="$(printf 'journal\n'; cat "$JOURNAL" 2>/dev/null; printf 'transcript\n'; cat "$TRANSCRIPT" 2>/dev/null; printf 'message-state\n'; m_state m-1; m_dlq)"
hasnt "T5: symlink-target content reaches no journal, transcript, or message result" "$observed" "$sentinel"
eq "T5: the refused output does not complete the message" "$(m_state m-1)" SEEN
kill -0 "$SUP_PID" 2>/dev/null && ok "T5: a bad turn output does not exit the supervisor" || no "T5: a bad turn output does not exit the supervisor"
stop_sup

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
