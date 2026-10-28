#!/usr/bin/env bash
# D1b worker boundary: per-attempt intents, board snapshot, broker confinement,
# terminal attempt identity, and provider-neutral adapter environment.
set -uo pipefail

ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/aib-task-intent.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
pass=0 fail=0
ok(){ pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
no(){ fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; }
eq(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2' want '$3')"; fi; }
has(){ case "$2" in *"$3"*) ok "$1";; *) no "$1 (missing '$3')";; esac; }
hasnt(){ case "$2" in *"$3"*) no "$1 (unexpected '$3')";; *) ok "$1";; esac; }

HOME_DIR="$WORK/home"; mkdir -p "$HOME_DIR/.aib/intents"; chmod 700 "$HOME_DIR/.aib" "$HOME_DIR/.aib/intents"
ATTEMPT=acme-main-17
call(){ RC=0; OUT=$(env -i HOME="$HOME_DIR" PATH="$ROOT/bin:$PATH" AIB_ATTEMPT_ID="$ATTEMPT" "$ROOT/bin/task-intent" "$@" 2>"$WORK/err") || RC=$?; ERR=$(<"$WORK/err"); }

call report t-aaaaaaaaaaaa done --result msg:result --reason complete -- 'finished safely'
eq 'report appends successfully' "$RC" 0
call continue t-aaaaaaaaaaaa -- 'more work remains'
eq 'continue appends successfully' "$RC" 0
call progress t-aaaaaaaaaaaa -- 'checkpoint'
eq 'progress is the report-progress convenience verb' "$RC" 0
INTENTS="$HOME_DIR/.aib/intents/$ATTEMPT.jsonl"
shape=$(python3 -I - "$INTENTS" <<'PY'
import json, sys
rows=[json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
print("|".join(f"{r['attempt_id']}:{r['verb']}:{r.get('state','')}:{r['task_id']}" for r in rows))
PY
)
eq 'each record carries the broker attempt and closed worker shape' "$shape" 'acme-main-17:report:done:t-aaaaaaaaaaaa|acme-main-17:continue::t-aaaaaaaaaaaa|acme-main-17:report:progress:t-aaaaaaaaaaaa'
eq 'intent file stays private' "$(stat -c %a "$INTENTS")" 600

printf '%s\n' '{"highest_seq":4,"tasks":[{"task_id":"t-aaaaaaaaaaaa","state":"IN_PROGRESS"}]}' > "$HOME_DIR/.aib/board.json"
chmod 600 "$HOME_DIR/.aib/board.json"
call list
eq 'list reads only the supervisor board snapshot' "$RC|$OUT" '0|{"highest_seq":4,"tasks":[{"task_id":"t-aaaaaaaaaaaa","state":"IN_PROGRESS"}]}'
RC=0; env -i HOME="$HOME_DIR" PATH="$ROOT/bin:$PATH" "$ROOT/bin/task-intent" continue t-aaaaaaaaaaaa -- x >/dev/null 2>"$WORK/no-attempt" || RC=$?
eq 'a missing broker attempt fails closed' "$RC" 78
ln -s "$WORK/escape" "$HOME_DIR/.aib/intents/evil-main-1.jsonl"
RC=0; env -i HOME="$HOME_DIR" PATH="$ROOT/bin:$PATH" AIB_ATTEMPT_ID=evil-main-1 "$ROOT/bin/task-intent" continue t-aaaaaaaaaaaa -- x >/dev/null 2>&1 || RC=$?
eq 'the client refuses a planted intent symlink' "$RC|$([ -e "$WORK/escape" ] && echo escaped || echo contained)" '78|contained'

# Provisioning owns the path; no aib-tasks ACL is requested by D1b carryover.
STATE_ROOT="$WORK/state"; STANDUP="$WORK/standup"; mkdir -p "$STATE_ROOT" "$STANDUP"
RC=0; env AIB_TEST_SEAMS=1 AIB_SUP_STATE_ROOT="$STATE_ROOT" AIB_STANDUP_DIR="$STANDUP" \
  AIB_ROLE_UID="$(id -u)" AIB_ROLE_GID="$(id -g)" AIB_SETFACL=/bin/true \
  "$ROOT/bin/aib-agent-dirs" acme-dev1 || RC=$?
eq 'aib-agent-dirs creates role-owned private .aib/intents' "$RC|$(stat -c '%a:%u:%g' "$STATE_ROOT/acme-dev1/.aib" "$STATE_ROOT/acme-dev1/.aib/intents" | tr '\n' ' ')" \
  "0|700:$(id -u):$(id -g) 700:$(id -u):$(id -g) "

# Both adapters must preserve the broker-minted env and resolve the worker CLI.
mkdir -p "$HOME_DIR/.claude" "$HOME_DIR/.codex" "$WORK/fake"
chmod 700 "$HOME_DIR/.claude" "$HOME_DIR/.codex"
printf '{}' > "$HOME_DIR/.claude/.credentials.json"; printf '{}' > "$HOME_DIR/.codex/auth.json"
chmod 600 "$HOME_DIR/.claude/.credentials.json" "$HOME_DIR/.codex/auth.json"
cat > "$WORK/fake/provider" <<'SH'
#!/usr/bin/env bash
printf 'attempt=%s\nintent=%s\n' "${AIB_ATTEMPT_ID:-}" "$(command -v task-intent 2>/dev/null)"
cat >/dev/null
SH
chmod +x "$WORK/fake/provider"
for provider in claude-code codex; do
  var=AIB_CLAUDE_BIN; [ "$provider" = codex ] && var=AIB_CODEX_BIN
  RC=0; OUT=$(cd "$WORK" && env -i HOME="$HOME_DIR" PATH="$ROOT/bin:$PATH" AIB_ATTEMPT_ID="$ATTEMPT" "$var=$WORK/fake/provider" \
    "$ROOT/adapters/$provider" exec -m example -s read-only -c 'model_reasoning_effort="low"' -c 'approval_policy="never"' -- prompt 2>"$WORK/adapter.err") || RC=$?
  eq "$provider adapter preserves AIB_ATTEMPT_ID" "$RC|$(printf '%s\n' "$OUT" | sed -n '1p')" "0|attempt=$ATTEMPT"
  eq "$provider adapter can resolve bin/task-intent" "$(printf '%s\n' "$OUT" | sed -n '2p')" "intent=$ROOT/bin/task-intent"
done

# Exercise the actual run_confined LL_RW construction, not a copied constant.
. "$ROOT/lib/aibobnet.sh"
PROJ="$WORK/project"; EV="$WORK/events"; STUB="$WORK/confine"; mkdir -p "$PROJ" "$EV" "$STUB" "$STATE_ROOT/acme-dev1/.codex"
chmod 700 "$STATE_ROOT/acme-dev1/.codex"
cat > "$STUB/landlock" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$LL_RW" > "${AIB_LL_LOG:-$(dirname "$0")/ll-rw}"
[ -z "${LL_STATUS_FD:-}" ] || eval "exec ${LL_STATUS_FD}>&-"
exec "$@"
SH
cat > "$STUB/adapter" <<'SH'
#!/usr/bin/env bash
printf 'provider-output\n'
SH
chmod +x "$STUB/landlock" "$STUB/adapter"
EVENTS="$EV/main.events"; LOCK="$EV/main.events.lock"; : > "$EVENTS"; : > "$LOCK"
ENV_KV=$'project_uid=acme\nactor_type=service\nactor_id=aib-broker\nagent_uid=acme-dev1\nteam_uid=acme-engine\nsession_id=acme'
PAYLOAD=$(aib_event_compose_decided_payload $'decision=allow\ncode=0\nreasons=\npid=1\nprompt_len=1\nprompt_sha256=deadbeef')
aib_event_commit "$EVENTS" "$LOCK" attempt.decided "$ENV_KV" "$PAYLOAD" >/dev/null; DECIDED=$AIB_EVENT_COMMIT_EVENT_ID
REC=$(printf 'adapter=%s\nstate_dir=.codex\nroot=%s\ncwd=%s\nsandbox=read-only\neffort=low\nmodel=example\ntimeout=5\nprovider=codex' "$STUB/adapter" "$PROJ" "$PROJ")
RESP=$(env HOME="$WORK/broker" PATH="$ROOT/bin:$PATH" AIB_TEST_SEAMS=1 AIB_SUP_STATE_ROOT="$STATE_ROOT" \
  AIB_VERDICT_ENV_ALLOW='HOME PATH' AIB_CONFINE_BIN="$STUB/landlock" \
  bash -c '. "$1/lib/aibobnet.sh"; aib_enact_launch "$2" x "$3" "$4" "$5" "$6"' _ "$ROOT" "$REC" "$EVENTS" "$LOCK" "$ENV_KV" "$DECIDED")
LL_RW=$(<"$STUB/ll-rw")
has 'real LL_RW includes the private .aib path' "$LL_RW" "$STATE_ROOT/acme-dev1/.aib"
has 'read-only still permits intents independent of provider sandbox flags' "$LL_RW" "$STATE_ROOT/acme-dev1/.aib"
hasnt 'read-only omits the project write grant' "$LL_RW" "$PROJ"
has 'terminal frame returns the broker attempt id' "$RESP" "attempt_id=$DECIDED"

# Sandbox-dependent proof: skip only when this kernel/toolchain cannot exercise Landlock.
if command -v cc >/dev/null 2>&1 && cc -O2 -Wall -Wextra -o "$WORK/landlock-exec" "$ROOT/src/landlock-exec.c" 2>/dev/null; then
  mkdir -p "$WORK/ll-home/.aib" "$WORK/ll-project"
  set +e
  LL_RO=/ LL_RW="$WORK/ll-home/.aib" "$WORK/landlock-exec" /bin/bash -c 'touch "$1/allowed"; touch "$2/denied"' _ "$WORK/ll-home/.aib" "$WORK/ll-project" >/dev/null 2>&1
  ll_rc=$?; set -e
  if [ -e "$WORK/ll-home/.aib/allowed" ] && [ ! -e "$WORK/ll-project/denied" ]; then
    ok 'SANDBOX-DEPENDENT: Landlock bounds read-only work while leaving task intents writable'
  elif [ "$ll_rc" -eq 3 ] || [ "$ll_rc" -eq 78 ] || [ "$ll_rc" -eq 126 ]; then
    printf 'ok   - SANDBOX-DEPENDENT SKIP: Landlock unavailable on this kernel (rc %s)\n' "$ll_rc"
  else
    no "SANDBOX-DEPENDENT: Landlock boundary (rc $ll_rc)"
  fi
else
  printf 'ok   - SANDBOX-DEPENDENT SKIP: compiler unavailable\n'
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
