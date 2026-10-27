#!/usr/bin/env bash
# ai-bobnet — supervisor state files stay readable under a restrictive service umask.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/fixtures/sup_harness.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-supmode.XXXXXX")"
trap sup_cleanup EXIT

sup_world modes
old_umask="$(umask)"
umask 077
start_sup
umask "$old_umask"
wait_for 5 lj_is state READY
eq "journal.jsonl is mode 0644 under umask 077" "$(stat -c '%a' "$JOURNAL")" 644
eq "live.json is mode 0644 under umask 077" "$(stat -c '%a' "$LIVE")" 644
stop_sup

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
