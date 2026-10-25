# ai-bobnet — shared hermetic harness for the supervisor specs (sourced, never run on its own).
# Test fixture only. It fakes the three things the supervisor leans on and nothing else:
#   - the managed launcher        ($AIB_LAUNCH_AGENT, recording argv/stdin, scripted outcomes)
#   - the broker client           ($AIB_BROKER_CLIENT, frame on stdin -> scripted `leases` answer)
#   - systemd-notify / tmux / zellij on PATH (recorders; the mux fakes must NEVER be called)
# The supervisor itself is the real bin/aib-supervisor from a COPY of the repo (like p1_spec) so
# `bin/run-agent` / `bin/message` resolve their registry from the engine copy's registry.json.
#
# ===== THE INTERFACE THIS HARNESS PINS FOR bin/aib-supervisor (S1a-2) =====
#   bin/aib-supervisor <agent_uid>          one long-lived process; exit 0 = deliberate stop, 78 = refusal (table below)
#   env (unit/test supplied, never agent- or request-derived):
#     STATE_DIRECTORY            test-only explicit per-agent state dir; the shipped unit leaves it unset and
#                                the supervisor uses AIB_SUP_STATE_ROOT/<uid> (default /var/lib/aib-sup/<uid>)
#     AIBOBNET_REGISTRY          registry file (the unit sets it)
#     AIB_LAUNCH_AGENT           launcher command, default <repo>/bin/launch-agent
#     AIB_BROKER_CLIENT          command: broker frame on stdin -> broker response on stdout
#                                (the unit sets it to the socket client; default is the socket one)
#     NOTIFY_SOCKET              when non-empty the loop calls `systemd-notify READY=1` / `WATCHDOG=1`
#     AIB_SUP_TICK_S             liveness tick interval            (default 30)     decimals allowed
#     AIB_SUP_POLL_S             inbox journal poll interval       (default 2)
#     AIB_SUP_BACKOFF_BASE_S     inner turn backoff base, x2^n     (default 10)
#     AIB_SUP_BACKOFF_CAP_S      inner turn backoff cap            (default 600)
#     AIB_SUP_INFRA_BACKOFF_MIN_S / _MAX_S   infra-class jittered backoff bounds (default 5 / 120)
#     AIB_SUP_BLOCKED_AFTER_S    infra class this long -> heartbeat `blocked` (default 600)
#     AIB_SUP_ORPHAN_POLL_S      leases poll while ORPHANED        (default 10)
#     AIB_SUP_CALL_TIMEOUT_S     timeout for every helper subprocess the loop waits on (broker client,
#                                bin/message, bin/run-agent); NOT for the launcher turn (default 30)
#   exit codes: 0 = deliberate stop (SIGTERM); 78 (EX_CONFIG) = "will not run, a restart cannot help"
#     (unknown / oneshot agent, invalid config, journal that cannot be trusted, another instance
#     holds the lock). The unit marks 78 with RestartPreventExitStatus=78; 75 stays the
#     RestartForceExitStatus code of a future `neustart --hard`.
#   Every interval is handed to `sleep`, so a test may use 0.05. Time is therefore injectable by
#   scaling the intervals. Positive waits are poll-until-condition with generous deadlines (wait_for);
#   only NEGATIVE windows ("nothing happened") are fixed sleeps.
#   files under the resolved per-agent state directory:
#     journal.jsonl   append-only JSON Lines, one object per line, {"seq":N,"ts":"<ISO>","event":"...",...},
#                     seq = 1,2,3,... and CONTINUES across restarts and re-exec (single writer: the supervisor)
#     live.json       rewritten atomically (tmp + rename) on every tick:
#                     seq = TICK counter, strictly increasing by 1 per rewrite and CONTINUING across
#                     restarts and re-exec (read back from the previous live.json) — not the journal seq.
#                     {"seq":N,"ts":"<ISO8601 UTC>","interval_s":<tick>,"pid":P,"state":"READY",
#                      "state_reason":"","turn":null|{"msg_id","started_at","attempt_id"},
#                      "brake":{"consecutive":N,"tripped_at":null|"<ISO>"},"session_id":"<uuid>"|null,
#                      "turns_in_session":N}
#                     state in STARTING|READY|WORKING|WAITING|ORPHANED|STOPPING|FAILED (DOMAIN §3.1);
#                     state_reason in ""|capacity|infra|orphan|brake.
#   launcher call (what the loop runs per unit of work, one at a time):
#     $AIB_LAUNCH_AGENT --as <uid> --supervised --session <new:UUID|UUID> --cwd <project home> -
#     prompt on stdin; rc/stdout/stderr map as pinned in supervisor_brake_spec.sh.
#   transcript: <standup_dir>/transcripts/<uid>.log gets every turn's stdout+stderr.
# NOTE for the builder: launch-agent / the wire do not carry --supervised / --session yet. Plumbing
# them (wire field `session=`, PDP mode check, adapter argv from S1a-1) is part of S1a-2; the
# supervisor specs deliberately stop at the launcher seam.

SRC_ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)
JGET="$SRC_ROOT/tests/fixtures/projection_jget.py"
SJ="$SRC_ROOT/tests/fixtures/sup_journal.py"

pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
no(){ fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; }
eq(){
  case "$2" in ""|__MISSING__|__PARSE_ERROR__) no "$1 (no value observed: '$2')"; return;; esac   # absence never equals absence
  if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2' want '$3')"; fi
}
has(){ case "$2" in *"$3"*) ok "$1";; *) no "$1 (missing '$3' in: ${2:0:300})";; esac; }
hasnt(){ [ -n "$2" ] || { no "$1 (empty subject: nothing happened)"; return; }; case "$2" in *"$3"*) no "$1 (unexpected '$3' in: ${2:0:300})";; *) ok "$1";; esac; }
ge(){ if awk -v a="$2" -v b="$3" 'BEGIN{exit !(a+0>=b+0)}'; then ok "$1"; else no "$1 (got '$2' want >= '$3')"; fi; }

sup_cleanup() {
  [ -z "${SUP_PID:-}" ] || kill -9 "$SUP_PID" 2>/dev/null
  [ -z "${W:-}" ] || pkill -9 -f "$W/fakes/" 2>/dev/null
  [ -z "${WORK:-}" ] || rm -rf "$WORK"
}

# sup_world <tag> [cap_timeout_s] — fresh world; sets W, HOMEDIR, STANDUP, STATE, JOURNAL, LIVE, INBOX, ...
sup_world() {
  local tag="$1" cap="${2:-900}"
  W="$WORK/$tag"; rm -rf "$W"
  HOMEDIR="$W/home"; STANDUP="$W/standup"; STATE="$W/state/acme-core"
  JOURNAL="$STATE/journal.jsonl"; LIVE="$STATE/live.json"; INBOX="$STANDUP/inbox/acme-core.md"
  HBLOG="$STANDUP/acme-core.log"; TRANSCRIPT="$STANDUP/transcripts/acme-core.log"
  mkdir -p "$HOMEDIR" "$STANDUP" "$STATE" "$W/fakes" "$W/prompts"
  chmod 700 "$STATE"
  ENGINE="$W/engine"; ENGINE4="$W/engine4"
  local e; for e in "$ENGINE" "$ENGINE4"; do
    mkdir -p "$e"; cp -R "$SRC_ROOT/bin" "$SRC_ROOT/scripts" "$SRC_ROOT/lib" "$SRC_ROOT/adapters" "$e/"
  done
  sup_write_registry "$cap" ""
  # schema-4 twin: used ONLY by test helpers (send/state), so setup never depends on schema 5
  cat > "$ENGINE4/registry.json" <<JSON
{ "schema_version": 4,
  "providers": { "acme": { "adapter": "$SRC_ROOT/adapters/codex", "cap_sandbox": "workspace-write",
                           "cap_tier": "t2", "cap_effort": "high", "cap_timeout": "$cap" } },
  "projects": { "acme": { "home": "$HOMEDIR", "standup_dir": "$STANDUP", "mux_session": "acme", "data_class": "internal",
                          "provider": "acme", "model": "team/model-v2", "effort": "low" } },
  "teams": { "acme-engine": { "project": "acme", "model": "team/model-v2" } },
  "agents": {
    "acme-core": { "project": "acme", "team_uid": "acme-engine", "profile": "engine-dev", "clearance": "t2" },
    "acme-sib":  { "project": "acme", "team_uid": "acme-engine", "profile": "engine-dev", "clearance": "t2" }
  } }
JSON
  # fakes ------------------------------------------------------------------
  cat > "$W/fakes/launch-agent" <<'FAKE'
#!/usr/bin/env bash
# scripted launcher. plan lines (consumed head-first): "<rc>|<hold_s>|<text>"  (text "E:..." -> stderr)
w=$(cd -P "$(dirname "$0")/.." && pwd)
session=""; as=""; cwd=""; sup=0; extra=""
while [ $# -gt 0 ]; do
  case "$1" in
    --as) as="$2"; shift 2;; --session) session="$2"; shift 2;; --cwd) cwd="$2"; shift 2;;
    --supervised) sup=1; shift;; -) shift;; *) extra="$extra $1"; shift;;
  esac
done
n=$( ( flock 9; c=$(cat "$w/calls.n" 2>/dev/null || echo 0); echo $((c+1)) > "$w/calls.n"; echo $((c+1)) ) 9>"$w/calls.lock" )
if [ -f "$w/stdinclose" ]; then echo $$ > "$w/stdinclose.pid"; exec 0<&-; exec sleep 30; fi
prompt=$(cat); printf '%s' "$prompt" > "$w/prompts/$n"
sid="${session#new:}"
bound=0; grep -s 'session.bound' "$w/state/acme-core/journal.jsonl" | grep -qF "$sid" && bound=1
seen=$(grep -sc 'event:SEEN' "$w/standup/inbox/acme-core.md"); seen=${seen:-0}
printf '%s session=%s as=%s cwd=%s supervised=%s bound=%s seen=%s extra=%s t=%s\n' "$n" "$session" "$as" "$cwd" "$sup" "$bound" "$seen" "$extra" "$(date +%s.%N)" >> "$w/calls.log"
env | grep -E '^(TMUX|ZELLIJ)' >> "$w/mux-env.log"
line=$( ( flock 8; l=$(head -n1 "$w/plan" 2>/dev/null); sed -i 1d "$w/plan" 2>/dev/null; printf '%s' "$l" ) 8>"$w/plan.lock" )
[ -n "$line" ] || line=$(cat "$w/default" 2>/dev/null || echo '0||ok turn')
rc="${line%%|*}"; rest="${line#*|}"; hold="${rest%%|*}"; text="${rest#*|}"
if ! mkdir "$w/turn.lock" 2>/dev/null; then echo "overlap call $n" >> "$w/overlap.log"; else trap 'rmdir "$w/turn.lock" 2>/dev/null' EXIT; fi
[ -z "$hold" ] || sleep "$hold"
case "$text" in E:*) printf '%s\n' "${text#E:}" >&2;; '') ;; *) printf '%s\n' "$text";; esac
printf '%s %s\n' "$n" "$(date +%s.%N)" >> "$w/ends.log"
exit "${rc:-0}"
FAKE
  cat > "$W/fakes/broker-client" <<'FAKE'
#!/usr/bin/env bash
w=$(cd -P "$(dirname "$0")/.." && pwd)
{ cat; printf -- '---\n'; } >> "$w/frames.log"
[ ! -f "$w/leases.hang" ] || { echo $$ >> "$w/hang.pids"; exec sleep 30; }
if [ -f "$w/leases.rc" ]; then exit "$(cat "$w/leases.rc")"; fi
cat "$w/leases.answer" 2>/dev/null || printf 'supervised=0\nother=0\nend=ok\n'
FAKE
  mkdir -p "$W/fakebin"
  printf '#!/usr/bin/env bash\necho "$*" >> "%s/notify.log"\n' "$W" > "$W/fakebin/systemd-notify"
  printf '#!/usr/bin/env bash\necho "$0 $*" >> "%s/mux.log"\nexit 1\n' "$W" > "$W/fakebin/tmux"
  cp "$W/fakebin/tmux" "$W/fakebin/zellij"
  chmod +x "$W/fakes/"* "$W/fakebin/"*
  : > "$W/plan"; : > "$W/calls.log"; : > "$W/notify.log"; : > "$W/mux.log"
}

# sup_write_registry <cap_timeout> <extra agent fields for acme-core, e.g. '"session_max_turns": "2",'>
sup_write_registry() {
  local cap="$1" extra="$2"
  cat > "$ENGINE/registry.json" <<JSON
{ "schema_version": 5,
  "providers": { "acme": { "adapter": "$SRC_ROOT/adapters/codex", "cap_sandbox": "workspace-write",
                           "cap_tier": "t2", "cap_effort": "high", "cap_timeout": "$cap" } },
  "projects": { "acme": { "home": "$HOMEDIR", "standup_dir": "$STANDUP", "mux_session": "acme", "data_class": "internal",
                          "provider": "acme", "model": "team/model-v2", "effort": "low" } },
  "teams": { "acme-engine": { "project": "acme", "model": "team/model-v2" } },
  "agents": {
    "acme-core": { $extra "mode": "supervised", "project": "acme", "team_uid": "acme-engine", "profile": "engine-dev", "clearance": "t2" },
    "acme-solo": { "mode": "oneshot", "project": "acme", "team_uid": "acme-engine", "profile": "engine-dev", "clearance": "t2" },
    "acme-sib":  { "project": "acme", "team_uid": "acme-engine", "profile": "engine-dev", "clearance": "t2" }
  } }
JSON
}

# start_sup [uid] [VAR=val ...] — background supervisor, hermetic env; SUP_PID set
start_sup() {
  local uid="acme-core"; case "${1:-}" in *=*|"") ;; *) uid="$1"; shift;; esac
  local sd="$W/state/$uid"; mkdir -p "$sd"; chmod 700 "$sd"
  env -i PATH="$W/fakebin:$PATH" HOME="$W/home-sup" LANG=C TZ=UTC \
    STATE_DIRECTORY="$sd" AIBOBNET_REGISTRY="$ENGINE/registry.json" \
    AIB_LAUNCH_AGENT="$W/fakes/launch-agent" AIB_BROKER_CLIENT="$W/fakes/broker-client" \
    NOTIFY_SOCKET="$W/notify.sock" \
    AIB_SUP_TICK_S=0.1 AIB_SUP_POLL_S=0.1 AIB_SUP_BACKOFF_BASE_S=0.1 AIB_SUP_BACKOFF_CAP_S=0.4 \
    AIB_SUP_INFRA_BACKOFF_MIN_S=0.05 AIB_SUP_INFRA_BACKOFF_MAX_S=0.15 AIB_SUP_BLOCKED_AFTER_S=600 \
    AIB_SUP_ORPHAN_POLL_S=0.1 AIB_SUP_CALL_TIMEOUT_S=10 "$@" \
    "$ENGINE/bin/aib-supervisor" "$uid" >>"$W/sup.out" 2>&1 &
  SUP_PID=$!
}
stop_sup() { # SIGTERM (graceful) and reap; echoes rc
  [ -n "${SUP_PID:-}" ] || return 0
  kill -TERM "$SUP_PID" 2>/dev/null; local rc=0; wait "$SUP_PID" 2>/dev/null || rc=$?; SUP_PID=""; return "$rc"
}
crash_sup() { [ -z "${SUP_PID:-}" ] || { kill -9 "$SUP_PID" 2>/dev/null; wait "$SUP_PID" 2>/dev/null; SUP_PID=""; }; }

# wait_for <seconds> <command...> — poll every 50 ms until the command succeeds
# (gives up at once when the supervisor it started is gone, unless WAIT_DEAD_OK=1 — keeps a RED run fast)
wait_for() {
  local t="$1" i; shift
  for ((i=0;i<t*20;i++)); do
    "$@" >/dev/null 2>&1 && return 0
    if [ -n "${SUP_PID:-}" ] && [ -z "${WAIT_DEAD_OK:-}" ] && ! kill -0 "$SUP_PID" 2>/dev/null; then return 1; fi
    sleep 0.05
  done
  return 1
}

# --- helpers over files --------------------------------------------------------
lj()      { python3 -I "$JGET" "$LIVE" "$1"; }
jcount()  { python3 -I "$SJ" count "$JOURNAL" "$1"; }
jfield()  { python3 -I "$SJ" field "$JOURNAL" "$1" "$2" "$3"; }
dl()      { awk -v a="$1" -v b="$2" 'BEGIN{ if (a ~ /^-?[0-9.]+$/ && b ~ /^-?[0-9.]+$/) print a-b; else print 0 }'; }
seq_ge()  { [ "$(lj seq)" -ge "$1" ] 2>/dev/null; }
frames_ge() { [ "$(grep -c '^---$' "$W/frames.log" 2>/dev/null)" -ge "$1" ]; }
alive_hung() { local n=0 p; for p in $(cat "$W/hang.pids" 2>/dev/null); do kill -0 "$p" 2>/dev/null && n=$((n+1)); done; echo "$n"; }
wd_ge()   { [ "$(grep -cx 'WATCHDOG=1' "$W/notify.log")" -ge "$1" ]; }
# wait_exit <pid> — wait up to 8 s for a refusal/exit; RC = its status, or -1 if it had to be killed
wait_exit() { WAIT_DEAD_OK=1 wait_for 8 bash -c "! kill -0 $1 2>/dev/null"; if kill -0 "$1" 2>/dev/null; then kill -9 "$1" 2>/dev/null; wait "$1" 2>/dev/null; RC=-1; else RC=0; wait "$1" 2>/dev/null || RC=$?; fi; }
lj_is()   { [ "$(lj "$1")" = "$2" ]; }
ready_gt(){ [ "$(grep -cx 'READY=1' "$W/notify.log")" -gt "$1" ]; }
ncalls()  { wc -l < "$W/calls.log" | tr -d ' '; }
callf()   { sed -n "${1}p" "$W/calls.log" | tr ' ' '\n' | grep "^$2=" | head -1 | cut -d= -f2-; }
prompt()  { cat "$W/prompts/$1" 2>/dev/null; }
hb_status() { awk -F' [|] ' '{print $3}' "$HBLOG" 2>/dev/null | tr '\n' ' '; }

# message helpers run through the schema-4 twin so setup never depends on schema 5
m_send()  { # m_send <id> <body>  (sender acme-sib -> acme-core)
  env -i PATH="$PATH" HOME="$W" "$ENGINE4/bin/run-agent" acme-sib -- "$ENGINE4/bin/message" send acme-core "$2" --id "$1" >/dev/null
}
m_state() { env -i PATH="$PATH" HOME="$W" "$ENGINE4/bin/run-agent" acme-core -- "$ENGINE4/bin/message" state "$1" 2>/dev/null; }
m_dlq()   { env -i PATH="$PATH" HOME="$W" "$ENGINE4/bin/run-agent" acme-core -- "$ENGINE4/bin/message" dlq 2>/dev/null; }
m_inbox() { env -i PATH="$PATH" HOME="$W" "$ENGINE4/bin/run-agent" acme-core -- "$ENGINE4/bin/message" inbox 2>/dev/null; }
state_is() { [ "$(m_state "$1")" = "$2" ]; }
# a human-lane line, as `agentctl say` will write it (from:human:<login>)
m_self_handover() { # m_self_handover <id> — a handover note as the supervisor itself writes it (from = the agent)
  env -i PATH="$PATH" HOME="$W" "$ENGINE4/bin/run-agent" acme-core -- "$ENGINE4/bin/message" send acme-core "kind:handover reason:test" --id "$1" >/dev/null
}
m_human() { printf '%s | id:%s | from:human:operator | to:acme-core | state:PERSISTED | %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >> "$INBOX"; }
# set the scripted launcher outcomes (one per call, head first) / the fallback after the plan runs out
plan()    { : > "$W/plan"; local l; for l in "$@"; do printf '%s\n' "$l" >> "$W/plan"; done; }
default() { printf '%s\n' "$1" > "$W/default"; }
