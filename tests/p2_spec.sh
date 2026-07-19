#!/usr/bin/env bash
# ai-bobnet — P2 black-box acceptance (CONTRACT-adapter.md §5).
# Proves, against a synthetic engine copy + white-label registry (acme, beta) under a temp dir,
# driving ONLY the public CLI (launched via bin/run-agent) and the localhost HTTP adapter:
#   A. Wakeup:        PERSISTED -> bin/wakeup -> NOTIFIED + recipient ping captured (stub hook);
#                     idempotent (2nd wakeup = no re-notify / no re-ping); bounded (exhausted -> dlq).
#   B. Adapter parity: each /send /inbox /seen /done /fail /state /dlq yields the SAME journal
#                     state as the equivalent bin/message call (adapter == CLI).
#   C. Hardening:     binds 127.0.0.1 only; missing/wrong auth token rejected; NO default token.
#   D. Journal authority: with the daemon stopped, the P1 CLI still sends/reads/transitions fully.
# Pure bash/awk core; python3 stdlib ONLY for the daemon (and as this test's HTTP client).
set -uo pipefail

# --- locate the engine under test (this repo) --------------------------------
SRC_ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)

WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-p2.XXXXXX")"
ENGINE="$WORK/engine"
STATE="$WORK/state"
mkdir -p "$ENGINE" "$STATE/acme" "$STATE/beta"

# Copy the engine tree so registry discovery is fully path-based (no env override).
cp -R "$SRC_ROOT/bin" "$SRC_ROOT/scripts" "$SRC_ROOT/lib" "$ENGINE/"

# Since P0.5 an Agent is a registry object: every uid driven below must be declared here.
cat > "$ENGINE/registry.json" <<JSON
{
  "schema_version": 2,
  "projects": {
    "acme": { "home": "$STATE/acme", "standup_dir": "$STATE/acme/standup", "mux_session": "acme" },
    "beta": { "home": "$STATE/beta", "standup_dir": "$STATE/beta/standup", "mux_session": "beta" }
  },
  "agents": {
    "acme-core":   { "project": "acme", "profile": "engine-dev", "clearance": "t2" },
    "acme-watch":  { "project": "acme", "profile": "watch",      "clearance": "t1" },
    "beta-review": { "project": "beta", "profile": "review",     "clearance": "t1" }
  }
}
JSON

RUN="$ENGINE/bin/run-agent"
MSG="$ENGINE/bin/message"
WAKE="$ENGINE/bin/wakeup"
BUS="$ENGINE/bin/bus"

# --- cleanup: stop any daemon we started, then remove the temp tree ----------
cleanup() {
  for rf in "$STATE"/*/standup/.bus/*.json; do
    [ -f "$rf" ] || continue
    pid="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("pid",""))' "$rf" 2>/dev/null || true)"
    [ -n "${pid:-}" ] && kill "$pid" 2>/dev/null || true
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

# Drive the CLI as a given agent — each call a fresh (scrubbed, re-resolved) process.
m() { local agent="$1"; shift; "$RUN" "$agent" -- "$MSG" "$@"; }

# --- tiny assertion harness (same style as tests/p0_spec.sh + p1_spec.sh) -----
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
no(){ fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; }
assert_ok(){   local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else no "$d (expected success)"; fi; }
assert_fail(){ local d="$1"; shift; if "$@" >/dev/null 2>&1; then no "$d (expected failure)"; else ok "$d"; fi; }
assert_streq(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2' want '$3')"; fi; }
assert_grep(){ if printf '%s\n' "$2" | grep -qF -- "$3"; then ok "$1"; else no "$1 (missing '$3' in: $2)"; fi; }
assert_ngrep(){ if printf '%s\n' "$2" | grep -qF -- "$3"; then no "$1 (unexpected '$3' in: $2)"; else ok "$1"; fi; }
assert_file_has(){ if grep -qF -- "$3" "$2" 2>/dev/null; then ok "$1"; else no "$1 (missing '$3' in $2)"; fi; }
assert_absent_dir(){ if [ -e "$1" ]; then no "$2 ($1 exists)"; else ok "$2"; fi; }

# ============================================================================ #
# A. WAKEUP notifier
# ============================================================================ #
# Capturing stub hooks — record (agent, session, id) so the ping is provable in-test.
HOOK_OK="$WORK/hook_ok.sh"; HOOK_LOG="$WORK/hook_ok.log"
cat > "$HOOK_OK" <<EOF
#!/usr/bin/env bash
printf '%s|%s|%s\n' "\$1" "\$2" "\$3" >> "$HOOK_LOG"
exit 0
EOF
HOOK_FAIL="$WORK/hook_fail.sh"; FAIL_LOG="$WORK/hook_fail.log"
cat > "$HOOK_FAIL" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$3" >> "$FAIL_LOG"
exit 1
EOF
chmod +x "$HOOK_OK" "$HOOK_FAIL"

# wake <actor> <target> <hook> [max]  — hook/max set on the wakeup command itself,
# because run-agent scrubs the ambient AIBOBNET_* routing namespace by design.
wake() {
  local actor="$1" target="$2" hook="$3" max="${4:-3}"
  "$RUN" "$actor" -- env AIBOBNET_WAKEUP_HOOK="$hook" AIBOBNET_WAKEUP_MAX_ATTEMPTS="$max" \
    "$WAKE" "$target"
}

beta_review="$STATE/beta/standup/inbox/beta-review.md"

# A1. PERSISTED -> wakeup -> NOTIFIED + ping captured
w1="$(m acme-core send beta-review "please review PR 7" --id wk-1)"
assert_streq "wakeup: message starts PERSISTED" "$(m beta-review state wk-1)" "PERSISTED"
wake acme-watch beta-review "$HOOK_OK" >/dev/null 2>&1
assert_streq "wakeup: PERSISTED -> NOTIFIED after wakeup" "$(m beta-review state wk-1)" "NOTIFIED"
assert_file_has "wakeup: NOTIFIED event recorded (by = actor)" "$beta_review" "id:wk-1 | event:NOTIFIED | by:acme-watch"
assert_grep "wakeup: recipient pinged via hook (agent+session+id captured)" \
  "$(cat "$HOOK_LOG")" "beta-review|beta|wk-1"

# A2. idempotent: a 2nd wakeup does NOT re-notify and does NOT re-ping
wake acme-watch beta-review "$HOOK_OK" >/dev/null 2>&1
assert_streq "wakeup: exactly one NOTIFIED event (idempotent)" \
  "$(grep -cF "id:wk-1 | event:NOTIFIED" "$beta_review")" "1"
assert_streq "wakeup: hook pinged exactly once (no re-ping of NOTIFIED)" \
  "$(grep -c . "$HOOK_LOG")" "1"

# A3. bounded -> dead-letter: a never-acked ping is retried up to N, then dlq'd
m acme-core send beta-review "unreachable node" --id wk-dead >/dev/null
wake acme-watch beta-review "$HOOK_FAIL" 3 >/dev/null 2>&1   # attempt 1
assert_streq "wakeup(bounded): still PERSISTED after failure 1" "$(m beta-review state wk-dead)" "PERSISTED"
wake acme-watch beta-review "$HOOK_FAIL" 3 >/dev/null 2>&1   # attempt 2
assert_streq "wakeup(bounded): still PERSISTED after failure 2" "$(m beta-review state wk-dead)" "PERSISTED"
wake acme-watch beta-review "$HOOK_FAIL" 3 >/dev/null 2>&1   # attempt 3 -> exhausted
assert_streq "wakeup(bounded): FAILED after exhausting the budget" "$(m beta-review state wk-dead)" "FAILED"
assert_grep "wakeup(bounded): dead-letter surfaces in dlq" "$(m beta-review dlq)" "id:wk-dead"
assert_ngrep "wakeup(bounded): dead-letter not in open inbox" "$(m beta-review inbox)" "id:wk-dead"
fails_before="$(grep -c . "$FAIL_LOG")"
wake acme-watch beta-review "$HOOK_FAIL" 3 >/dev/null 2>&1   # 4th wakeup: terminal -> no re-ping
assert_streq "wakeup(bounded): dead-lettered message is never re-pinged" \
  "$(grep -c . "$FAIL_LOG")" "$fails_before"

# ============================================================================ #
# B. ADAPTER PARITY — the bus (running AS beta-review) == bin/message
# ============================================================================ #
BUS_TOKEN="p2-secret-token"
BUS_PORT="$("$RUN" beta-review -- env AIBOBNET_BUS_TOKEN="$BUS_TOKEN" "$BUS" start 2>/dev/null)"
assert_grep "adapter: start prints a numeric port" "$BUS_PORT" "$(printf '%s' "$BUS_PORT" | tr -cd 0-9)"

# HTTP client (python3 stdlib) -> prints "CODE <single-line-json-body>".
http() { # METHOD PATH TOKEN [JSON-BODY]
  python3 - "$BUS_PORT" "$@" <<'PY'
import sys, urllib.request, urllib.error
port, method, path, token = sys.argv[1:5]
data = sys.argv[5].encode() if len(sys.argv) > 5 and sys.argv[5] else None
req = urllib.request.Request("http://127.0.0.1:%s%s" % (port, path), data=data, method=method)
if token:
    req.add_header("X-Aibobnet-Token", token)
if data is not None:
    req.add_header("Content-Type", "application/json")
try:
    r = urllib.request.urlopen(req)
    print(r.status, r.read().decode())
except urllib.error.HTTPError as e:
    print(e.code, e.read().decode())
PY
}
jfield() { printf '%s' "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1],""))' "$2"; }

# B1. /send parity: bus-as-beta-review and CLI-as-beta-review both persist to acme-core
r="$(http POST /send "$BUS_TOKEN" '{"to":"acme-core","body":"parity send","id":"ps-http"}')"
assert_streq "parity(send): HTTP /send returns 200" "${r%% *}" "200"
assert_streq "parity(send): HTTP /send echoes the id" "$(jfield "${r#* }" id)" "ps-http"
m beta-review send acme-core "parity send" --id ps-cli >/dev/null
assert_streq "parity(send): HTTP and CLI produce the SAME state" \
  "$(m acme-core state ps-http)" "$(m acme-core state ps-cli)"
assert_streq "parity(send): that shared state is PERSISTED" "$(m acme-core state ps-http)" "PERSISTED"

# B2. /inbox parity: bus inbox lists the same OPEN ids the CLI does
m acme-core send beta-review "for inbox A" --id in-a >/dev/null
m acme-core send beta-review "for inbox B" --id in-b >/dev/null
r="$(http GET /inbox "$BUS_TOKEN")"
bus_inbox="${r#* }"
cli_inbox="$(m beta-review inbox)"
assert_grep "parity(inbox): HTTP inbox includes in-a" "$bus_inbox" "in-a"
assert_grep "parity(inbox): HTTP inbox includes in-b" "$bus_inbox" "in-b"
assert_grep "parity(inbox): CLI inbox includes in-a"  "$cli_inbox" "in-a"
assert_grep "parity(inbox): CLI inbox includes in-b"  "$cli_inbox" "in-b"

# B3. /seen parity
m acme-core send beta-review "seen via http" --id sn-http >/dev/null
m acme-core send beta-review "seen via cli"  --id sn-cli  >/dev/null
http POST /seen "$BUS_TOKEN" '{"id":"sn-http"}' >/dev/null
m beta-review seen sn-cli >/dev/null
assert_streq "parity(seen): HTTP and CLI both reach SEEN" \
  "$(m beta-review state sn-http)" "$(m beta-review state sn-cli)"
assert_streq "parity(seen): that state is SEEN" "$(m beta-review state sn-http)" "SEEN"

# B4. /done parity
m acme-core send beta-review "done via http" --id dn-http >/dev/null
m acme-core send beta-review "done via cli"  --id dn-cli  >/dev/null
http POST /done "$BUS_TOKEN" '{"id":"dn-http"}' >/dev/null
m beta-review done dn-cli >/dev/null
assert_streq "parity(done): HTTP and CLI both reach PROCESSED" \
  "$(m beta-review state dn-http)" "$(m beta-review state dn-cli)"
assert_streq "parity(done): that state is PROCESSED" "$(m beta-review state dn-http)" "PROCESSED"

# B5. /fail parity (+ /state + /dlq)
m acme-core send beta-review "fail via http" --id fl-http >/dev/null
m acme-core send beta-review "fail via cli"  --id fl-cli  >/dev/null
http POST /fail "$BUS_TOKEN" '{"id":"fl-http","reason":"downstream down"}' >/dev/null
m beta-review fail fl-cli "downstream down" >/dev/null
assert_streq "parity(fail): HTTP and CLI both reach FAILED" \
  "$(m beta-review state fl-http)" "$(m beta-review state fl-cli)"
r="$(http GET /state/fl-http "$BUS_TOKEN")"
assert_streq "parity(state): HTTP /state == CLI state" \
  "$(jfield "${r#* }" state)" "$(m beta-review state fl-http)"
r="$(http GET /dlq "$BUS_TOKEN")"
bus_dlq="${r#* }"
assert_grep "parity(dlq): HTTP dlq surfaces the http-failed msg"  "$bus_dlq" "fl-http"
assert_grep "parity(dlq): HTTP dlq surfaces the cli-failed msg"   "$bus_dlq" "fl-cli"
assert_grep "parity(dlq): CLI dlq agrees (http-failed msg)"       "$(m beta-review dlq)" "fl-http"

# ============================================================================ #
# C. HARDENING
# ============================================================================ #
r="$(http GET /inbox "wrong-token")"
assert_streq "hardening: wrong token -> 401" "${r%% *}" "401"
r="$(http GET /inbox "")"
assert_streq "hardening: missing token -> 401" "${r%% *}" "401"

# bind is loopback-only: the runtime record proves the daemon bound 127.0.0.1
rt="$STATE/beta/standup/.bus/beta-review.json"
assert_file_has "hardening: daemon bound 127.0.0.1 (runtime record)" "$rt" '"host": "127.0.0.1"'
assert_ngrep "hardening: token is never written to disk" "$(cat "$rt")" "$BUS_TOKEN"
# source-level guards: loopback constant present, wildcard bind absent, no outbound client
assert_grep  "hardening: source binds 127.0.0.1" "$(grep -F 'HOST =' "$BUS")" "127.0.0.1"
assert_ngrep "hardening: source never binds 0.0.0.0" "$(cat "$BUS")" "0.0.0.0"
assert_ngrep "hardening: no outbound HTTP client in the daemon" "$(cat "$BUS")" "urlopen"

# NO default token: a start with the token unset must refuse (and start nothing)
assert_fail "hardening: start without a token is refused (no default)" \
  "$RUN" acme-core -- env -u AIBOBNET_BUS_TOKEN "$BUS" start
assert_absent_dir "$STATE/acme/standup/.bus/acme-core.json" \
  "hardening: refused start created no runtime record"

# ============================================================================ #
# D. JOURNAL AUTHORITY — daemon stopped, the P1 CLI still fully works
# ============================================================================ #
"$RUN" beta-review -- env AIBOBNET_BUS_TOKEN="$BUS_TOKEN" "$BUS" stop >/dev/null 2>&1
# the daemon is down; the CLI still sends, reads, and transitions against the journal
ja="$(m acme-core send beta-review "after daemon down" --id ja-1)"
assert_streq "authority: CLI send works with daemon stopped" "$ja" "ja-1"
assert_grep  "authority: CLI inbox works with daemon stopped" "$(m beta-review inbox)" "id:ja-1"
m beta-review seen ja-1 >/dev/null
m beta-review done ja-1 >/dev/null
assert_streq "authority: CLI transitions to terminal with daemon stopped" \
  "$(m beta-review state ja-1)" "PROCESSED"
# and requests now fail (nothing listening) — the adapter really is gone, not silently faked
r="$(http GET /inbox "$BUS_TOKEN" 2>/dev/null || printf 'DOWN')"
assert_grep "authority: adapter truly stopped (no HTTP after stop)" "$r" "DOWN"

# ============================================================================ #
# summary
# ============================================================================ #
total=$((pass+fail))
printf '\n%d checks: %d ok / %d fail\n' "$total" "$pass" "$fail"
[ "$fail" -eq 0 ]
