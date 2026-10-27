#!/usr/bin/env bash
# ai-bobnet — supervisor state writes never follow role-account-controlled links.
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

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
