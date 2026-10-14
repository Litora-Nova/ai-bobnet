#!/usr/bin/env bash
# ai-bobnet — RED spec: the session-id check must not depend on the caller's locale (S1a follow-up S3, carried into S1b).
# Found on the S1a-2 delta: under LC_ALL=en_US.UTF-8, bash's `[[ $s =~ ^[0-9a-f]{8}-... ]]` lets accented letters through the
# FIRST uuid group (é, ä sort between 0-9 and a-f in that collation), so `éf2b8c1e-9d4a-4e6b-8a7c-1b2d3e4f5a6b` passes
# bin/launch-agent's validation and reaches the broker (rc 69 instead of the usage error 64). The ids that reach the broker frame,
# the journal and the provider argv must be byte-exact canonical lower-case hex in EVERY locale.
#
# WHAT THIS PINS
#   bin/launch-agent --supervised --session <sid> under LC_ALL=en_US.UTF-8 (skipped with a stated reason when that locale is
#   not installed): a sid whose FIRST group (and, as a guard, each other group) contains a non-ASCII or non-hex character
#   is refused with rc 64 and the broker client is never called — for `<uuid>` and `new:<uuid>`. Good ids still pass.
#   The same for the two adapters' own `session-turn` check (exit 65), run with that locale.
#   (The C-locale variants are already pinned by tests/launch_agent_supervised_spec.sh.)
set -uo pipefail
SRC_ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
LA="$SRC_ROOT/bin/launch-agent"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-locale.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
no(){ fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; }
eq(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2' want '$3')"; fi; }

LOC=""; for l in en_US.UTF-8 en_US.utf8 de_DE.UTF-8 de_DE.utf8; do
  if locale -a 2>/dev/null | grep -qix "${l/UTF-8/utf8}"; then LOC="$l"; break; fi
done
if [ -z "$LOC" ]; then printf 'skip - no accent-collating UTF-8 locale installed on this host; the C-locale cases are in launch_agent_supervised_spec\n'; printf '\n0 passed, 0 failed\n'; exit 0; fi

mkdir -p "$WORK/cwd"
cat > "$WORK/client" <<'FAKE'
#!/usr/bin/env bash
w=$(cd -P "$(dirname "$0")" && pwd)
cat > "$w/frame.bin"; echo x >> "$w/client.calls"
printf 'end=ok\nexit_class=ok\n'
FAKE
chmod +x "$WORK/client"
UU=3f2b8c1e-9d4a-4e6b-8a7c-1b2d3e4f5a6b
run() { rm -f "$WORK/client.calls" "$WORK/frame.bin"; RC=0; env -i PATH="$PATH" HOME="$WORK" LC_ALL="$LOC" AIB_BROKER_CLIENT="$WORK/client" \
    "$LA" --as acme-core --cwd "$WORK/cwd" --prompt hi --supervised --session "$1" >/dev/null 2>&1 || RC=$?; CALLS=$(cat "$WORK/client.calls" 2>/dev/null | wc -l | tr -d ' '); }

run "$UU"; eq "good uuid under $LOC => 0 and one broker call" "$RC|$CALLS" "0|1"
run "new:$UU"; eq "good new:uuid under $LOC => 0 and one broker call" "$RC|$CALLS" "0|1"
bad_group() { # bad_group <group index 1..5> <replacement char> -> uuid with the FIRST character of that group replaced
  python3 -I - "$UU" "$1" "$2" <<'PY'
import sys
u, i, c = sys.argv[1], int(sys.argv[2]), sys.argv[3]
g = u.split("-"); g[i-1] = c + g[i-1][1:]; print("-".join(g))
PY
}
for ch in é ä ö ü ß À; do
  for g in 1 2 3 4 5; do
    sid="$(bad_group "$g" "$ch")"
    run "$sid"; eq "group $g starting with '$ch' is refused under $LOC (64, broker untouched)" "$RC|$CALLS" "64|0"
  done
done
sid="$(bad_group 1 é)"; run "new:$sid"; eq "new:<uuid> with é in the first group is refused too" "$RC|$CALLS" "64|0"
for ch in G Z B; do sid="$(bad_group 1 $ch)"; run "$sid"; eq "'$ch' in the first group is refused under $LOC" "$RC|$CALLS" "64|0"; done

# the adapters' own check (they run with a scrubbed env in production, but the closed ABI must hold in any locale)
cat > "$WORK/fake-provider" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
chmod +x "$WORK/fake-provider"; mkdir -p "$WORK/h/.codex" "$WORK/h/.claude"
adapter_rc() { # adapter_rc <adapter> <sid>
  local r=0; env -i PATH="$PATH" HOME="$WORK/h" LC_ALL="$LOC" AIB_CODEX_BIN="$WORK/fake-provider" AIB_CLAUDE_BIN="$WORK/fake-provider" \
    "$SRC_ROOT/adapters/$1" session-turn "$2" -m m -s read-only -c 'model_reasoning_effort="low"' -c 'approval_policy="never"' -- hi </dev/null >/dev/null 2>&1 || r=$?; echo "$r"
}
for a in codex claude-code; do
  eq "adapter $a: é in the first group is refused under $LOC (65)" "$(adapter_rc "$a" "$(bad_group 1 é)")" 65
  eq "adapter $a: ä in the first group of new:<uuid> is refused (65)" "$(adapter_rc "$a" "new:$(bad_group 1 ä)")" 65
done
printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
