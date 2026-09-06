#!/usr/bin/env bash
# ai-bobnet — RM-3 broker, slice 3: commit + enactment (§2 steps 3-4).
#
# WHAT THIS PINS
#   Slice 2 stopped at authorize: every allow answered `enacted=no`, no provider process
#   ever started. This spec pins step 3 (enactment, including §2.1 confinement) and
#   step 4 (commit attempt.ended), in the maintainer's own decisions after the RM-3
#   slice-3 architecture consult (standup/_design_rm3-slice3.md v2,
#   standup/_advisor_rm3-slice3.md).
#
#   THE CALL CONTRACT THIS SPEC PINS (the builder must provide it to this shape):
#
#     aib_enact_launch <enact-record> <prompt> <events-path> <lock-path> \
#                       <envelope-kv> <decided-event-id> [mode]
#
#   SPEC-FIXTURE CORRECTION (this file, this commit): the enact-record originally
#   carried `prompt=<text>` as a record LINE. Prompts are multi-line free text, and a
#   newline-keyed record cannot carry them without corrupting on the first embedded
#   newline — the same reason the wire itself length-prefixes prompt rather than
#   putting it on a record line (SPEC-wire-format.md, field classification table).
#   The ABI is corrected here, before any implementation exists: prompt is its own
#   positional argument, never a `prompt=` line in <enact-record>. `[mode]` is an
#   OPTIONAL 7th argument this file never passes (so every call below exercises the
#   default) — it exists so bin/launch-agent's in-process, unconfined enactment can
#   share this same function without an unset AIB_CONFINE_BIN reading as "confinement
#   unavailable" (see docs/CONFINEMENT.md and the builder's report for the exact
#   values and default).
#
#   writes ONLY the chunk section and the terminal line of the response frame
#   (docs/SPEC-wire-format.md, "Response frame") to its stdout — the prologue
#   (decision/effective_*/cwd/reasons/decided_event_id/enacted=yes) is the caller's
#   job, written before enactment starts, because everything in it is already known
#   from the verdict. On return it publishes AIB_ENACT_EXIT_CLASS, AIB_ENACT_STAGE,
#   AIB_ENACT_ENDED_EVENT_ID (house AIB_VERDICT_*-style globals) and has committed
#   exactly one attempt.ended record, causally bound to <decided-event-id>, over
#   <events-path>/<lock-path> with the given <envelope-kv>.
#
#   <enact-record> (newline key=value, same idiom as the PDP's request/snapshot
#   records): adapter (absolute path) · root (the registry-derived Landlock root,
#   i.e. AIB_HOME) · cwd (the ALREADY-AUTHORIZED resolved cwd — re-checked here, not
#   trusted) · sandbox / effort / model / timeout (all EFFECTIVE, already clamped).
#   prompt is NOT in the record (see the spec-fixture correction above) — it is the
#   dedicated 2nd positional argument, exactly once, never re-derived from the record.
#
#   Confinement configuration is deliberately NOT in the record: AIB_CONFINE_BIN is
#   unit-environment-only (CONFINEMENT.md), never request- or registry-supplied, so
#   this spec sets it as an exported environment variable, matching how the real
#   service unit would.
#
#   D-A / D-A2 (pre-flight, pluggable, fail-closed confinement): the provider is
#   exec'd ONLY through $AIB_CONFINE_BIN. Before spawning it, a pre-flight call
#   (LL_RO=/ LL_RW=<tmp> $AIB_CONFINE_BIN /bin/true) must succeed or nothing else
#   runs. A helper failure before exec is reported over LL_STATUS_FD, not the exit
#   code, because exec never returns and the child then owns the whole exit-code
#   space.
#   D-B2 (positive lists, registry-only): LL_RW = <home>:/tmp:/var/tmp:/dev,
#   LL_RO = / (slice-3 divergence, documented). The request contributes nothing.
#   D-C (order): cd -> pwd -P re-check against root -> exec helper. The decided
#   event is already committed before any of this runs.
#   D-K (stage): attempt.ended gains exit.stage in
#   confine|cwd|exec|provider, always present, so a helper-side refusal is never
#   read as a provider failure.
#   D-H (response frame): opaque length-prefixed chunks, terminal line, exactly one
#   end= and it is last.
#   D-I (connection = attempt lifetime): a disconnect while the provider is silent
#   is detected on the next write (EPIPE) and reaps the child rather than leaving it
#   orphaned or leaving the decided record without a terminal one.
#
#   Expected on the unbuilt tree: mostly FAIL. aib_enact_launch does not exist yet,
#   so every section that calls it fails the same way slice 2's RED spec failed
#   before authorize existed — command-not-found, not a subtler bug. What already
#   passes: the composer/schema-fold checks that only need today's aib_event_commit,
#   and the compiled helper's OWN failure path on this Landlock-less host (which
#   needs no broker code at all — see §1).
set -uo pipefail

SRC_ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
# shellcheck source=lib/aibobnet.sh
. "$SRC_ROOT/lib/aibobnet.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-enact.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
no(){ fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; }
skip(){ pass=$((pass+1)); printf 'ok   - (skipped: %s)\n' "$1"; }
eq(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2' want '$3')"; fi; }
has(){ if printf '%s\n' "$2" | grep -qF -- "$3"; then ok "$1"; else no "$1 (missing '$3')"; fi; }
hasnt(){ if printf '%s\n' "$2" | grep -qF -- "$3"; then no "$1 (unexpected '$3')"; else ok "$1"; fi; }
# reachable_under <label> <colon-separated-positive-list> <path> — a real
# Landlock grant on a directory covers every path beneath it; a plain
# substring check (what `has` does) cannot express that; it can only find a
# path that was listed VERBATIM, which is not what "reachable under a
# hierarchical grant" means. This is the correct check for "does this
# positive list make <path> reachable", used once below where FIXTURE_STANDUP
# (a subdirectory of FIXTURE_HOME, never listed on its own) must be
# reachable BECAUSE its parent is on the list, per ADR-0005.
reachable_under() {
  local label="$1" list="$2" path="$3" entry rest="$2"
  while [ -n "$rest" ]; do
    entry="${rest%%:*}"
    case "$rest" in *:*) rest="${rest#*:}";; *) rest="";; esac
    case "$path" in "$entry"|"$entry"/*) ok "$label"; return;; esac
  done
  no "$label (no entry in '$list' covers '$path')"
}

# grep -c returns exit 1 on zero matches (not an error) but still prints "0" — a bare
# `grep -c ... || printf 0` therefore double-appends on that legitimate case. These
# normalize to a single clean count regardless of "file absent" vs. "file present with
# zero matches" vs. "pattern absent from a piped string".
count_matches_in_file(){ # count_matches_in_file <pattern> <file>
  local n; n="$(grep -c -- "$1" "$2" 2>/dev/null)"; printf '%s' "${n:-0}"
}
count_matches_in_string(){ # count_matches_in_string <pattern> <string>
  local n; n="$(printf '%s\n' "$2" | grep -c -- "$1" 2>/dev/null)"; printf '%s' "${n:-0}"
}
file_byte_count(){ [ -e "$1" ] && wc -c < "$1" || printf 0; }
file_line_count(){ [ -e "$1" ] && wc -l < "$1" || printf 0; }
# count_real_terminal_end_lines <file> — a chunk-FRAME-AWARE count of `^end=`
# lines in the TERMINAL section only, skipping every chunk by its declared
# byte count rather than scanning for a separator. `count_matches_in_file`
# cannot be used for this: it is a bare `grep -c`, and the whole point of the
# chunk-endok fixture below is a chunk whose PAYLOAD contains the literal
# line `end=ok` — a naive line-oriented count over the raw file necessarily
# (and correctly, for THAT tool) finds two, which is not a frame corruption,
# it is exactly what "reader counts, never scans" (SPEC-wire-format.md) is
# there to make harmless. This is the reader that actually honours that rule,
# used only for this one assertion; no NUL-bearing fixture ever needs it.
count_real_terminal_end_lines() {
  local content n header
  content="$(<"$1")"
  while :; do
    case "$content" in
      chunk_bytes=*)
        header="${content%%$'\n'*}"
        n="${header#chunk_bytes=}"
        content="${content#*$'\n'$'\n'}"
        if [ "$n" = 0 ]; then
          count_matches_in_string '^end=' "$content"
          return
        fi
        content="${content:$n}"
        ;;
      *) printf 'not-a-chunk-frame'; return ;;
    esac
  done
}

# =============================================================================
# Fixtures
# =============================================================================

# Registry layout: standup_dir INSIDE home (D-B/ADR-0005's exact hazard shape),
# AIB_EVENT_ROOT a sibling tree entirely OUTSIDE home (the broker-owned location
# ADR-0005 moves the stream to). <standup_dir>/events is the reader symlink ADR-0005
# says provisioning maintains — created here so a stub adapter can prove "decided
# committed before I started" by reading through the SAME path a real reader would.
FIXTURE_HOME="$WORK/home-acme"
FIXTURE_STANDUP="$FIXTURE_HOME/standup"
FIXTURE_WS="$FIXTURE_HOME/ws"
mkdir -p "$FIXTURE_WS" "$FIXTURE_STANDUP"
EVENT_ROOT="$WORK/event-root"
mkdir -p "$EVENT_ROOT/acme"
ln -s "$EVENT_ROOT/acme" "$FIXTURE_STANDUP/events"
EVENTS_FILE="$EVENT_ROOT/acme/main.events"
EVENTS_LOCK="$EVENT_ROOT/acme/main.events.lock"

STUB_BIN="$WORK/stub-bin"
mkdir -p "$STUB_BIN"
ADAPTER="$STUB_BIN/codex"
LANDLOCK_STUB="$STUB_BIN/landlock-exec"

SENTINEL="$WORK/provider-called"
ARGV_OUT="$WORK/argv"
LL_LOG="$WORK/ll-invocations"   # append-only: every stub-helper call, incl. pre-flight

# --- the stub confinement helper: the CLI contract, not the syscalls -----------
# Logs every invocation (mode included, so the pre-flight call is visible too),
# honours LL_STATUS_FD exactly like the real helper is specified to (silent+empty
# on success, one line before a non-zero exit on failure), and either execs its
# argument (ok) or refuses before ever reaching exec (fail modes never exec).
adapter_conf_write() {
  local mode="${1:-ok}" rc="${2:-7}" sleep_s="${3:-0}"
  cat > "$STUB_BIN/adapter.conf" <<EOF
STUB_SENTINEL='$SENTINEL'
STUB_ARGV_OUT='$ARGV_OUT'
STUB_MODE='$mode'
STUB_RC='$rc'
STUB_SLEEP='$sleep_s'
EOF
}
landlock_conf_write() {
  local mode="${1:-ok}" counter="${2:-}"
  cat > "$STUB_BIN/landlock.conf" <<EOF
STUB_LL_MODE='$mode'
STUB_LL_LOG='$LL_LOG'
STUB_LL_COUNTER='$counter'
EOF
}

cat > "$LANDLOCK_STUB" <<'STUB'
#!/usr/bin/env bash
_cfg="$(cd "$(dirname "$0")" && pwd)/landlock.conf"
[ -f "$_cfg" ] && . "$_cfg"
{
  printf 'call mode=%s\n' "${STUB_LL_MODE:-ok}"
  printf 'LL_RO=%s\n' "${LL_RO-<unset>}"
  printf 'LL_RW=%s\n' "${LL_RW-<unset>}"
  printf 'argv=%s\n' "$*"
  printf 'pwd=%s\n' "$(pwd -P)"
  printf '---\n'
} >> "${STUB_LL_LOG:-/dev/null}"
case "${STUB_LL_MODE:-ok}" in
  ok)
    # R1 (gate delta 2, Riker HIGH / Ikarus MEDIUM): mirror the FIXED real-helper
    # ordering, not the old buggy one. Save the ORIGINAL stderr as fd 3 BEFORE the
    # LL_STDERR_FD redirect (src/landlock-exec.c now does the equivalent with a
    # CLOEXEC'd dup()) — every diagnostic this stub emits AFTER the redirect (i.e.
    # only the "exec target missing" one below) goes to fd 3, the journal, never
    # to fd 2, which by then belongs to the provider's relay.
    exec 3>&2
    # D2 (gate delta): dup2 the named fd onto 2 — after every diagnostic the block
    # above already emitted (flushed to STUB_LL_LOG by this point), but BEFORE we
    # know whether the upcoming exec will even succeed.
    if [ -n "${LL_STDERR_FD-}" ]; then eval "exec 2>&${LL_STDERR_FD}"; fi
    # execvp's own failure path, reproduced without relying on bash's `exec`
    # builtin's own stderr message (which bash would send to whatever fd 2
    # already is — i.e. exactly the leak this fixture exists to catch — instead
    # of letting us choose the journal deliberately, the way real execvp()'s
    # errno-based failure lets src/landlock-exec.c choose).
    if ! command -v "$1" >/dev/null 2>&1 && [ ! -x "$1" ]; then
      if [ -n "${LL_STATUS_FD-}" ]; then
        printf 'exec: %s: No such file or directory\n' "$1" >&"${LL_STATUS_FD}"
      fi
      printf 'landlock-exec: exec %s: No such file or directory\n' "$1" >&3
      exit 127
    fi
    # CLOEXEC on success: close the status fd, write nothing, THEN exec.
    if [ -n "${LL_STATUS_FD-}" ]; then eval "exec ${LL_STATUS_FD}>&-"; fi
    exec "$@"
    ;;
  preflight-fail)
    if [ -n "${LL_STATUS_FD-}" ]; then
      printf 'stub: confinement unavailable\n' >&"${LL_STATUS_FD}"
    fi
    exit 3
    ;;
  fail-second-call)
    # Marvin (gate delta, should-fix): the pre-flight call (against a
    # throwaway tmp dir) and the REAL launch call are two SEPARATE
    # invocations of this same stub — succeed on the first (so the
    # pre-flight passes and the real attempt is actually made), fail on
    # every one after (so the post-preflight LL_STATUS_FD branch — "the
    # helper installed confinement but failed independently of the
    # pre-flight" — gets real coverage instead of always being caught
    # earlier by the pre-flight itself).
    _n=0
    [ -f "${STUB_LL_COUNTER:-/dev/null}" ] && read -r _n < "$STUB_LL_COUNTER"
    _n=$((_n+1))
    printf '%s' "$_n" > "${STUB_LL_COUNTER:-/dev/null}"
    if [ "$_n" -eq 1 ]; then
      if [ -n "${LL_STATUS_FD-}" ]; then eval "exec ${LL_STATUS_FD}>&-"; fi
      exec "$@"
    fi
    if [ -n "${LL_STATUS_FD-}" ]; then
      printf 'stub: restrict_self failed on the real launch\n' >&"${LL_STATUS_FD}"
    fi
    exit 3
    ;;
esac
STUB
chmod +x "$LANDLOCK_STUB"

# --- the stub provider (adapter) — conf-beside-the-binary, env -i-safe ---------
cat > "$ADAPTER" <<'STUB'
#!/usr/bin/env bash
_cfg="$(cd "$(dirname "$0")" && pwd)/adapter.conf"
[ -f "$_cfg" ] && . "$_cfg"
printf 'called\n' >> "$STUB_SENTINEL"
: > "$STUB_ARGV_OUT"
for a in "$@"; do printf '[%s]\n' "$a" >> "$STUB_ARGV_OUT"; done
case "${STUB_MODE:-ok}" in
  ok) printf 'STUB_PROVIDER_OK\n'; exit 0;;
  err) printf 'stub failure\n' >&2; exit "${STUB_RC:-7}";;
  sleep) sleep "${STUB_SLEEP:-5}"; exit 0;;
  silent-hang)
    # D3 (gate delta, Ikarus, HIGH): a single-process hang only tests "the
    # direct child got killed" — the orphan class the fix targets is a
    # GRANDCHILD surviving a single-pid TERM. Fork one, with the same
    # marker in its own argv (so pgrep -f "$DISC_MARKER" finds it too), and
    # hang here as well: a group-kill must catch both, a single-pid kill
    # only ever caught the parent.
    if [ "${1:-}" != --grandchild ]; then
      "$0" --grandchild "$@" &
    fi
    while :; do sleep 1; done
    ;;
  silent-hang-term-trap)
    # R2 (gate delta 2, Riker HIGH / Ikarus HIGH): silent-hang's grandchild
    # dies from the ordinary TERM disposition, same as its parent, so it never
    # stresses escalation CANCELLATION — only "did the group TERM reach
    # everyone". This grandchild explicitly ignores TERM (a realistic
    # daemonizing-or-adversarial child); the direct/leader process still does
    # NOT trap TERM, so it dies immediately and normally from the group
    # signal. Only the killer job's own KILL, delivered after its full grace
    # period, can end the grandchild — proving cancellation is gated on the
    # GROUP being empty, not on the leader's own exit.
    if [ "${1:-}" != --grandchild ]; then
      "$0" --grandchild "$@" &
      while :; do sleep 1; done
    else
      trap '' TERM
      while :; do sleep 1; done
    fi
    ;;
  chunk-nul)
    printf 'before'; printf '\0'; printf 'after'
    exit 0
    ;;
  chunk-endok)
    printf 'noise\nend=ok\nmore noise\n'
    exit 0
    ;;
  assert-decided)
    if grep -qF "\"event_id\":\"${AIBOBNET_ATTEMPT_ID:-NOPE}\"" \
         "${AIBOBNET_STANDUP_DIR:-/nonexistent}/events/main.events" 2>/dev/null
    then printf 'DECIDED_FOUND\n'; else printf 'DECIDED_MISSING\n'; fi
    exit 0
    ;;
  trickle)
    # Marvin (gate delta, should-fix, Gap 5): a provider ACTIVELY producing
    # chunks when the reader disconnects — the only existing disconnect
    # fixture (silent-hang) never reaches a real write attempt at all, so
    # `trap '' PIPE` and the write-checked relay loop it protects have no
    # fixture that would notice their removal. Write real output on a fixed
    # cadence, well past the reader's disconnect, so the relay's OWN next
    # write (not the idle-tick poll) is what discovers the gone client.
    for _i in 1 2 3 4 5 6 7 8 9 10; do
      printf 'trickle-%s\n' "$_i"
      sleep 0.3
    done
    exit 0
    ;;
  early-close)
    # Marvin (gate delta, should-fix, edge): closes ITS OWN stdout (so the
    # relay sees true EOF almost immediately) but keeps running afterward —
    # the terminal record must reflect the EVENTUAL exit the manager's
    # `wait` blocks for, not whatever was true at EOF time.
    exec 1>&-
    sleep 1
    exit 0
    ;;
esac
STUB
chmod +x "$ADAPTER"

# Envelope + effective values common to most fixtures below.
ENVELOPE_KV="project_uid=acme
actor_type=service
actor_id=aib-broker
agent_uid=acme-core
team_uid=acme-engine
session_id=acme-broker"

# SPEC-FIXTURE GAP (found while building, fixed the same way as the ABI
# correction at the top of this file — an addition, no assertion weakened):
# aib_event_commit already refuses an attempt.ended whose decided-event-id was
# never persisted ("attempt.ended requires a persisted prior attempt.decided
# event_id" — lib/aibobnet.sh, and this file's own header says as much:
# "the decided event is already committed before any of this runs"). The
# literal `test-decided-N` strings below were never actually committed as
# attempt.decided records in $EVENTS_FILE, so every direct aib_enact_launch
# call in §4 onward would refuse its own attempt.ended commit before this
# correction — not a subtler behavioural gap, the same "the precondition was
# never built" shape as the ABI issue. `reset_run` deliberately does not
# touch $EVENTS_FILE (records accumulate across this section on purpose —
# see the fold fixture in §3 for the same pattern with its own file), so a
# fresh decided record is seeded immediately before each call that needs one.
seed_decided() {
  local kv payload
  kv="$(printf 'decision=allow\ncode=0\nreasons=\npid=%s\nprompt_len=1\nprompt_sha256=deadbeef' "$$")"
  payload="$(aib_event_compose_decided_payload "$kv")"
  aib_event_commit "$EVENTS_FILE" "$EVENTS_LOCK" attempt.decided "$ENVELOPE_KV" "$payload" >/dev/null 2>&1
  printf '%s' "$AIB_EVENT_COMMIT_EVENT_ID"
}

base_enact_record() { # base_enact_record <cwd>
  printf 'adapter=%s\nroot=%s\ncwd=%s\nsandbox=workspace-write\neffort=high\nmodel=team/model-v2\ntimeout=5' \
    "$ADAPTER" "$FIXTURE_HOME" "$1"
}
# base_prompt [text] — the corresponding default prompt, now a call argument, never
# a record line (see the spec-fixture correction at the top of this file).
base_prompt() { printf '%s' "${1:-hello}"; }

reset_run() {
  rm -f "$SENTINEL" "$ARGV_OUT"
  : > "$LL_LOG"
}

# =============================================================================
# 1. The compiled real helper's OWN failure path (D-A2), needs no broker code —
#    the one part of docs/CONFINEMENT.md this Landlock-less host can genuinely
#    exercise for real, not through a stub.
# =============================================================================
CC_BIN="$(command -v cc || command -v gcc || true)"
if [ -n "$CC_BIN" ]; then
  REAL_HELPER="$WORK/real-landlock-exec"
  if "$CC_BIN" -O2 -o "$REAL_HELPER" "$SRC_ROOT/src/landlock-exec.c" 2>"$WORK/cc-err"; then
    STATUS_OUT="$WORK/real-status"
    : > "$STATUS_OUT"
    LL_RO=/ LL_RW="$WORK" LL_STATUS_FD=9 "$REAL_HELPER" /bin/true 9>"$STATUS_OUT"
    real_rc=$?
    eq "compiled helper exits 3 when Landlock is unavailable on this host" "$real_rc" "3"
    if [ -s "$STATUS_OUT" ]; then
      ok "…and LL_STATUS_FD carries a non-empty reason (D-A2)"
    else
      no "…and LL_STATUS_FD carries a non-empty reason (D-A2) (status fd was empty — src/landlock-exec.c does not write it yet)"
    fi
  else
    no "src/landlock-exec.c compiles with $CC_BIN ($(cat "$WORK/cc-err" | tr '\n' ' '))"
  fi
else
  skip "no cc"
  skip "no cc"
fi

# =============================================================================
# 2. aib_event_compose_ended_payload gains exit.stage (D-K) — no aib_enact_launch
#    needed, this is the composer alone.
# =============================================================================
stage_payload="$(aib_event_compose_ended_payload "exit_class=io-refused
exit_code=126
stage=confine")"
has "the ended payload composer emits exit.stage (D-K)" "$stage_payload" '"stage":"confine"'

stage_payload_provider="$(aib_event_compose_ended_payload "exit_class=provider-failure
exit_code=3
stage=provider")"
has "…for every exit class, not only confinement refusals" "$stage_payload_provider" '"stage":"provider"'

# D5 (gate delta, Ikarus, MEDIUM): stage is REQUIRED, not merely accepted — a
# missing/empty stage on a new record is a writer bug (direct-mode's two
# pre-enactment IO-hygiene refusals were shipping stage:null), never a legal
# "unknown". The composer fails closed rather than silently nulling it.
( aib_event_compose_ended_payload "exit_class=ok" ) >/dev/null 2>&1
eq "the composer refuses a missing stage, fail-closed (D5)" "$?" "2"
( aib_event_compose_ended_payload $'exit_class=ok\nstage=' ) >/dev/null 2>&1
eq "…and an explicitly empty stage, the same way" "$?" "2"

# =============================================================================
# 3. Old + new event schema fold (D-K) — a version-1 record and a hand-built
#    version-2 record (exit.stage present) in the SAME stream, both foldable.
#    aib_event_commit takes the payload JSON directly, so this needs no lib
#    change to construct — only the reader-tolerance claim is what is pinned.
# =============================================================================
FOLD_EVENTS="$WORK/fold/main.events"
FOLD_LOCK="$WORK/fold/main.events.lock"
mkdir -p "$WORK/fold"
fold_envelope="project_uid=fold
actor_type=service
actor_id=aib-broker
agent_uid=fold-core"
old_decided_payload="$(aib_event_compose_decided_payload "decision=allow
code=0
reasons=
pid=$$
prompt_len=1
prompt_sha256=deadbeef")"
aib_event_commit "$FOLD_EVENTS" "$FOLD_LOCK" attempt.decided "$fold_envelope" "$old_decided_payload" >/dev/null 2>&1
old_decided_id="$AIB_EVENT_COMMIT_EVENT_ID"
# D5 (gate delta, Ikarus, MEDIUM): the composer now REFUSES a missing/empty
# stage (fail closed) — every real writer supplies one. A genuine schema-
# version-1 record (pre-slice-3, no stage key at all) can no longer be built
# through the composer, so this fold fixture builds the v1 shape by hand,
# exactly like the v2 shape two lines below already does.
old_ended_payload='{"exit":{"class":"ok","code":null,"signal":null}}'
AIB_EVENT_SCHEMA_VERSION=1 aib_event_commit "$FOLD_EVENTS" "$FOLD_LOCK" attempt.ended "$fold_envelope" "$old_ended_payload" "$old_decided_id" >/dev/null 2>&1

new_decided_payload="$(aib_event_compose_decided_payload "decision=allow
code=0
reasons=
pid=$$
prompt_len=1
prompt_sha256=deadbeef")"
aib_event_commit "$FOLD_EVENTS" "$FOLD_LOCK" attempt.decided "$fold_envelope" "$new_decided_payload" >/dev/null 2>&1
new_decided_id="$AIB_EVENT_COMMIT_EVENT_ID"
# Hand-built version-2-shaped payload: aib_event_commit takes payload_json
# directly, so this needs no change to the composer to construct.
new_ended_payload='{"exit":{"class":"io-refused","code":126,"signal":null,"stage":"confine"}}'
AIB_EVENT_SCHEMA_VERSION=2 aib_event_commit "$FOLD_EVENTS" "$FOLD_LOCK" attempt.ended "$fold_envelope" "$new_ended_payload" "$new_decided_id" >/dev/null 2>&1

fold_out="$(aib_event_scan "$FOLD_EVENTS")"
eq "fold: scan status is ok across a schema-version-1/2 mixed stream" "$AIB_EVENT_SCAN_STATUS" "ok"
has "fold: the old-version ended record is still present" "$fold_out" "$old_decided_id"
has "fold: the new-version ended record (with exit.stage) is present" "$fold_out" "$new_decided_id"
has "fold: the new record's stage survives the scan untouched" "$fold_out" '"stage":"confine"'

# =============================================================================
# 4. aib_enact_launch — direct lib-level pins
# =============================================================================

# Named separately from every assertion below it: on the unbuilt tree this is the
# ONE line that explains why several "never runs the provider" checks in this
# section pass trivially (command-not-found refuses everything, for the wrong
# reason) rather than because the refusal logic exists yet. Once this flips green,
# those checks start meaning what their text says.
if command -v aib_enact_launch >/dev/null 2>&1 || type aib_enact_launch >/dev/null 2>&1; then
  ok "aib_enact_launch is defined (the checks below test its behaviour, not its absence)"
else
  no "aib_enact_launch is defined (the checks below test its behaviour, not its absence) — not built yet"
fi

# --- 4a. no exec without the helper -----------------------------------------
# NOT `enact_out="$(...)"`: a command substitution forks a subshell, and NO
# implementation of aib_enact_launch could ever make a global assignment made
# inside a subshell visible back here — bash forbids it categorically, not as
# an implementation gap. `enact_out` is unused below either way; a plain
# foreground call with a file redirect (the same pattern every OTHER section
# of this file already uses) is both correct and enough.
reset_run
unset AIB_CONFINE_BIN 2>/dev/null || true
AIB_CONFINE_BIN="" aib_enact_launch "$(base_enact_record "$FIXTURE_WS")" "$(base_prompt)" \
  "$EVENTS_FILE" "$EVENTS_LOCK" "$ENVELOPE_KV" "$(seed_decided)" >"$WORK/resp-4a" 2>"$WORK/enact-err-4a"
enact_rc=$?
if [ -e "$SENTINEL" ]; then no "an unset AIB_CONFINE_BIN never runs the provider"
else ok "an unset AIB_CONFINE_BIN never runs the provider"; fi
eq "…and the enactment fails closed (nonzero)" "$([ "$enact_rc" -ne 0 ] && printf nonzero || printf zero)" "nonzero"

# --- pre-flight failure (D-A): confinement unavailable -> io-refused/confine ---
reset_run
landlock_conf_write preflight-fail
adapter_conf_write ok
# NOT `enact_out="$(...)"`, same reason as 4a above — and this section reads
# AIB_ENACT_EXIT_CLASS/AIB_ENACT_STAGE right after, which a subshell call
# would leave permanently empty regardless of what the function does.
AIB_CONFINE_BIN="$LANDLOCK_STUB" aib_enact_launch "$(base_enact_record "$FIXTURE_WS")" "$(base_prompt)" \
  "$EVENTS_FILE" "$EVENTS_LOCK" "$ENVELOPE_KV" "$(seed_decided)" >"$WORK/resp-4b" 2>"$WORK/enact-err-4b"
if [ -e "$SENTINEL" ]; then no "a failed pre-flight never runs the provider (D-A)"
else ok "a failed pre-flight never runs the provider (D-A)"; fi
eq "…and AIB_ENACT_EXIT_CLASS is io-refused" "${AIB_ENACT_EXIT_CLASS:-}" "io-refused"
eq "…and AIB_ENACT_STAGE is confine, not provider (D-K)" "${AIB_ENACT_STAGE:-}" "confine"
has "…the pre-flight call itself targets /bin/true, not the real adapter" "$(<"$LL_LOG")" "argv=/bin/true"
# Gate delta (should-fix, now fixed): a client checking only stage= has to know
# the enum by heart to react. reason= spells it out on the wire itself, ahead
# of ended_event_id= (Ikarus' preflight repro expects exactly this string).
has "…and the wire names reason=confinement_unavailable, not just stage=confine" \
  "$(<"$WORK/resp-4b")" "reason=confinement_unavailable"

# =============================================================================
# --- 4c. LL_RW is composed from the registry snapshot only; a request cwd
#     cannot widen it (SPEC-wire-format :82) ---------------------------------
# =============================================================================
reset_run
landlock_conf_write ok
adapter_conf_write ok
mkdir -p "$FIXTURE_WS/sub-a" "$FIXTURE_WS/sub-b"
AIB_CONFINE_BIN="$LANDLOCK_STUB" aib_enact_launch "$(base_enact_record "$FIXTURE_WS/sub-a")" "$(base_prompt)" \
  "$EVENTS_FILE" "$EVENTS_LOCK" "$ENVELOPE_KV" "$(seed_decided)" >/dev/null 2>"$WORK/enact-err-4c1"
ll_rw_a="$(grep '^LL_RW=' "$LL_LOG" | tail -1)"
reset_run
AIB_CONFINE_BIN="$LANDLOCK_STUB" aib_enact_launch "$(base_enact_record "$FIXTURE_WS/sub-b")" "$(base_prompt)" \
  "$EVENTS_FILE" "$EVENTS_LOCK" "$ENVELOPE_KV" "$(seed_decided)" >/dev/null 2>"$WORK/enact-err-4c2"
ll_rw_b="$(grep '^LL_RW=' "$LL_LOG" | tail -1)"
# Guard against the comparison below passing vacuously because the helper was never
# invoked at all (both sides empty) — a real assertion needs a real value on the table.
if [ -n "$ll_rw_a" ]; then ok "LL_RW= was actually composed and logged by the helper (not an empty no-op)"
else no "LL_RW= was actually composed and logged by the helper (not an empty no-op)"; fi
eq "a different (but equally valid) request cwd does not change the composed LL_RW" "$ll_rw_a" "$ll_rw_b"
has "LL_RW carries the registry-derived home" "$ll_rw_a" "$FIXTURE_HOME"
has "LL_RW carries /tmp:/var/tmp:/dev per CONFINEMENT.md's positive list" "$ll_rw_a" "/tmp"
has "…/var/tmp" "$ll_rw_a" "/var/tmp"
has "…/dev" "$ll_rw_a" "/dev"

# --- 4d. LL_RW excludes AIB_EVENT_ROOT even though standup_dir sits INSIDE
#     home (D-B / ADR-0005's exact hazard) -------------------------------------
hasnt "LL_RW never contains the broker's event root, even though standup_dir is under home" \
  "$ll_rw_a" "$EVENT_ROOT"
# SPEC-FIXTURE CORRECTION (found while building; addition, nothing weakened —
# same class as the two documented at the top of this file): `has` is a plain
# substring search, and FIXTURE_STANDUP ("$FIXTURE_HOME/standup") is never
# listed on the positive list VERBATIM — only its parent $FIXTURE_HOME is
# (asserted two lines above). A literal-substring check for FIXTURE_STANDUP
# can therefore never pass under ANY composition that follows CONFINEMENT.md's
# own list ("LL_RW = <home>:/tmp:/var/tmp:/dev" — home only, not every
# subtree). `reachable_under` (added above) is the check ADR-0005's own claim
# actually needs: standup_dir is reachable BECAUSE home, its parent, is
# granted — the same hierarchical-grant property Landlock itself provides and
# a substring search cannot express.
reachable_under "…while standup_dir itself (a real agent-writable subtree of home) IS reachable" \
  "$ll_rw_a" "$FIXTURE_STANDUP"

# --- 4e. cwd re-check: a symlink swapped in AFTER authorize, BEFORE exec -----
# (SPEC-wire-format "Order is part of the requirement" / gate delta D2 obligation)
SWAP_ROOT="$WORK/swap-root"
SWAP_OUTSIDE="$WORK/swap-outside"
mkdir -p "$SWAP_ROOT" "$SWAP_OUTSIDE"
mkdir -p "$SWAP_ROOT/sub"
aib_contain_cwd "$SWAP_ROOT" "$SWAP_ROOT/sub" >/dev/null 2>&1
authorized_cwd="$AIB_CWD_RESOLVED"   # = "$SWAP_ROOT/sub", authorized while a real dir
rm -rf "$SWAP_ROOT/sub"
ln -s "$SWAP_OUTSIDE" "$SWAP_ROOT/sub"   # swapped to point OUTSIDE root, same path string
reset_run
landlock_conf_write ok
adapter_conf_write ok
swap_record="$(printf 'adapter=%s\nroot=%s\ncwd=%s\nsandbox=workspace-write\neffort=high\nmodel=team/model-v2\ntimeout=5' \
  "$ADAPTER" "$SWAP_ROOT" "$authorized_cwd")"
AIB_CONFINE_BIN="$LANDLOCK_STUB" aib_enact_launch "$swap_record" "$(base_prompt)" \
  "$EVENTS_FILE" "$EVENTS_LOCK" "$ENVELOPE_KV" "$(seed_decided)" >"$WORK/resp-4e" 2>"$WORK/enact-err-4e"
if [ -e "$SENTINEL" ]; then no "a cwd swapped to point outside root after authorize never runs the adapter (D2/D-C)"
else ok "a cwd swapped to point outside root after authorize never runs the adapter (D2/D-C)"; fi
eq "…classified stage=cwd, not confine or provider" "${AIB_ENACT_STAGE:-}" "cwd"
eq "…and exit_class is io-refused" "${AIB_ENACT_EXIT_CLASS:-}" "io-refused"
has "…the terminal line on the wire names stage=cwd" "$(<"$WORK/resp-4e")" "stage=cwd"
has "…and reason=cwd_moved, so a client need not know the stage enum by heart" \
  "$(<"$WORK/resp-4e")" "reason=cwd_moved"

# =============================================================================
# 5. Successful enactment: helper receives the right shape, adapter runs once,
#    chunk framing carries opaque bytes intact.
# =============================================================================
reset_run
landlock_conf_write ok
adapter_conf_write ok
AIB_CONFINE_BIN="$LANDLOCK_STUB" aib_enact_launch "$(base_enact_record "$FIXTURE_WS")" "$(base_prompt "make it so")" \
  "$EVENTS_FILE" "$EVENTS_LOCK" "$ENVELOPE_KV" "$(seed_decided)" >"$WORK/resp-5" 2>"$WORK/enact-err-5"
eq "a clean allow runs the provider exactly once" "$(file_line_count "$SENTINEL")" "1"
has "…the resolved cwd is where the child actually starts (pwd -P, logged by the helper)" \
  "$(grep '^pwd=' "$LL_LOG" | tail -1)" "$FIXTURE_WS"
eq "…exit class is ok" "${AIB_ENACT_EXIT_CLASS:-}" "ok"
eq "…stage is provider" "${AIB_ENACT_STAGE:-}" "provider"
has "…the relayed chunk carries the provider's actual output" "$(<"$WORK/resp-5")" "STUB_PROVIDER_OK"
has "…exactly one end= line, and it says ok" "$(<"$WORK/resp-5")" "end=ok"
end_count="$(count_matches_in_file '^end=' "$WORK/resp-5")"
eq "…exactly one end= total, never a second one" "$end_count" "1"
last_line="$(tail -1 "$WORK/resp-5" 2>/dev/null)"
has "…end= is the LAST line of the frame" "$last_line" "end="

# --- 5b. a multi-line prompt reaches the adapter byte-exact ------------------
# The whole reason for the spec-fixture correction at the top of this file: a
# newline-keyed enact-record cannot carry free text containing its own key
# separator. Proving the fix means proving a prompt WITH embedded newlines
# survives as the single argv token the adapter receives, unfolded and
# untruncated at the first newline — not just that a one-line "hello" works.
reset_run
landlock_conf_write ok
adapter_conf_write ok
MULTILINE_PROMPT=$'first line\nsecond line\nthird line, no trailing newline'
AIB_CONFINE_BIN="$LANDLOCK_STUB" aib_enact_launch "$(base_enact_record "$FIXTURE_WS")" "$MULTILINE_PROMPT" \
  "$EVENTS_FILE" "$EVENTS_LOCK" "$ENVELOPE_KV" "$(seed_decided)" >"$WORK/resp-5b" 2>"$WORK/enact-err-5b"
argv_captured="$(<"$ARGV_OUT")"
has "a multi-line prompt's first line reaches the adapter" "$argv_captured" "first line"
has "…its second line, still inside the SAME argv token (not a record split)" "$argv_captured" "second line"
has "…and its last line, with no silent truncation at the last newline" \
  "$argv_captured" "third line, no trailing newline"

# =============================================================================
# 6. Exit-class mapping carries stage=provider, so a provider's OWN exit 3/127
#    is never misread as a confinement refusal (advisor finding on D-A/D-C).
# =============================================================================
reset_run
landlock_conf_write ok
adapter_conf_write err 3
AIB_CONFINE_BIN="$LANDLOCK_STUB" aib_enact_launch "$(base_enact_record "$FIXTURE_WS")" "$(base_prompt)" \
  "$EVENTS_FILE" "$EVENTS_LOCK" "$ENVELOPE_KV" "$(seed_decided)" >"$WORK/resp-6a" 2>"$WORK/enact-err-6a"
eq "a provider exiting 3 is provider-failure, never confine (advisor: exit code is not reservable)" \
  "${AIB_ENACT_EXIT_CLASS:-}" "provider-failure"
eq "…and its stage is provider" "${AIB_ENACT_STAGE:-}" "provider"
# D2 (gate delta, Ikarus, HIGH): SPEC-wire-format's "stream" is stdout AND
# stderr, both relayed to the caller as opaque chunks — only the HELPER's own
# diagnostics (never the provider's) stay off the wire. LL_STDERR_FD makes
# the stub dup2 its exec target's stderr onto fd 1 last, after every line the
# stub itself already logged to STUB_LL_LOG.
has "…and the provider's OWN stderr reaches the wire as a chunk (D2)" "$(<"$WORK/resp-6a")" "stub failure"
hasnt "…while the helper's own diagnostics still never do" "$(<"$WORK/resp-6a")" "landlock-exec:"

# --- 6a2. R1 (gate delta 2, Riker HIGH / Ikarus MEDIUM): execvp itself failing
#     AFTER a successful confinement setup — the LL_STDERR_FD dup2 has already
#     happened by then, so the helper's OWN "exec failed" diagnostic must go
#     through LL_STATUS_FD/the journal, never leak onto the wire the way the
#     provider's real stderr legitimately does above. This is the exact
#     sub-case 84/84 green missed in the delta round: confinement succeeds,
#     LL_STDERR_FD is set, and THEN the adapter path itself is missing.
# =============================================================================
reset_run
landlock_conf_write ok
adapter_conf_write ok
MISSING_ADAPTER="$STUB_BIN/does-not-exist-xyz"
missing_adapter_record="$(printf 'adapter=%s
root=%s
cwd=%s
sandbox=workspace-write
effort=high
model=team/model-v2
timeout=5'   "$MISSING_ADAPTER" "$FIXTURE_HOME" "$FIXTURE_WS")"
AIB_CONFINE_BIN="$LANDLOCK_STUB" aib_enact_launch "$missing_adapter_record" "$(base_prompt)"   "$EVENTS_FILE" "$EVENTS_LOCK" "$ENVELOPE_KV" "$(seed_decided)" >"$WORK/resp-6a2" 2>"$WORK/enact-err-6a2"
eq "…classified stage=exec, the helper installed confinement but execvp itself failed"   "${AIB_ENACT_STAGE:-}" "exec"
eq "…and exit_class is io-refused" "${AIB_ENACT_EXIT_CLASS:-}" "io-refused"
hasnt "…the exec-failure diagnostic (with the adapter's absolute path) never reaches the wire (R1)"   "$(<"$WORK/resp-6a2")" "$MISSING_ADAPTER"
hasnt "…nor the literal 'landlock-exec:' prefix at all" "$(<"$WORK/resp-6a2")" "landlock-exec:"
has "…while the SAME diagnostic DOES reach the broker's own journal stream"   "$(<"$WORK/enact-err-6a2")" "landlock-exec: exec $MISSING_ADAPTER"

reset_run
adapter_conf_write err 127
AIB_CONFINE_BIN="$LANDLOCK_STUB" aib_enact_launch "$(base_enact_record "$FIXTURE_WS")" "$(base_prompt)" \
  "$EVENTS_FILE" "$EVENTS_LOCK" "$ENVELOPE_KV" "$(seed_decided)" >"$WORK/resp-6b" 2>"$WORK/enact-err-6b"
eq "a provider exiting 127 is io-refused, but stage=provider (not confine)" \
  "${AIB_ENACT_EXIT_CLASS:-}" "io-refused"
eq "…its stage is provider, distinguishing it from a helper-side io-refused" "${AIB_ENACT_STAGE:-}" "provider"

reset_run
adapter_conf_write sleep 0 5
timeout_record="$(printf 'adapter=%s\nroot=%s\ncwd=%s\nsandbox=workspace-write\neffort=high\nmodel=team/model-v2\ntimeout=1' \
  "$ADAPTER" "$FIXTURE_HOME" "$FIXTURE_WS")"
AIB_CONFINE_BIN="$LANDLOCK_STUB" aib_enact_launch "$timeout_record" "$(base_prompt)" \
  "$EVENTS_FILE" "$EVENTS_LOCK" "$ENVELOPE_KV" "$(seed_decided)" >"$WORK/resp-6c" 2>"$WORK/enact-err-6c"
eq "a provider outliving the effective timeout is classified timeout" "${AIB_ENACT_EXIT_CLASS:-}" "timeout"
has "…exit_code=124 on the wire" "$(<"$WORK/resp-6c")" "exit_code=124"

# --- 6d. Marvin (gate delta, should-fix): the post-preflight LL_STATUS_FD
#     discriminator, independent of the dedicated pre-flight call ------------
reset_run
LL_COUNTER="$WORK/ll-call-count"
rm -f "$LL_COUNTER"
landlock_conf_write fail-second-call "$LL_COUNTER"
adapter_conf_write ok
AIB_CONFINE_BIN="$LANDLOCK_STUB" aib_enact_launch "$(base_enact_record "$FIXTURE_WS")" "$(base_prompt)" \
  "$EVENTS_FILE" "$EVENTS_LOCK" "$ENVELOPE_KV" "$(seed_decided)" >"$WORK/resp-6d" 2>"$WORK/enact-err-6d"
if [ -e "$SENTINEL" ]; then no "a helper that fails independently AFTER a successful pre-flight never runs the adapter"
else ok "a helper that fails independently AFTER a successful pre-flight never runs the adapter"; fi
eq "…and is classified io-refused" "${AIB_ENACT_EXIT_CLASS:-}" "io-refused"
eq "…stage=confine, never mistaken for the provider's own exit (the discriminator this slice adds)" \
  "${AIB_ENACT_STAGE:-}" "confine"
has "…the pre-flight itself still targeted /bin/true, not the adapter, before this failure" \
  "$(grep '^argv=' "$LL_LOG" | head -1)" "/bin/true"
# Every section from here on relies on the landlock stub's config carrying
# over from whichever section last set it (none of them re-call
# landlock_conf_write on their own) — restore "ok" explicitly so this
# fixture's own state does not leak into everything after it.
landlock_conf_write ok

# =============================================================================
# 7. Chunk bytes are opaque: a NUL inside a chunk, and a chunk containing the
#    literal line "end=ok", must not disturb the frame (D-H, and the advisor's
#    "proves the reader counts, not scans").
# =============================================================================
reset_run
adapter_conf_write chunk-nul
AIB_CONFINE_BIN="$LANDLOCK_STUB" aib_enact_launch "$(base_enact_record "$FIXTURE_WS")" "$(base_prompt)" \
  "$EVENTS_FILE" "$EVENTS_LOCK" "$ENVELOPE_KV" "$(seed_decided)" >"$WORK/resp-7a" 2>"$WORK/enact-err-7a"
body_bytes="$(file_byte_count "$WORK/resp-7a")"
if [ "$body_bytes" -gt 0 ] && grep -qaF 'before' "$WORK/resp-7a" && grep -qaF 'after' "$WORK/resp-7a"; then
  ok "a NUL byte inside a chunk survives to the far side of the frame intact"
else
  no "a NUL byte inside a chunk survives to the far side of the frame intact"
fi

reset_run
adapter_conf_write chunk-endok
AIB_CONFINE_BIN="$LANDLOCK_STUB" aib_enact_launch "$(base_enact_record "$FIXTURE_WS")" "$(base_prompt)" \
  "$EVENTS_FILE" "$EVENTS_LOCK" "$ENVELOPE_KV" "$(seed_decided)" >"$WORK/resp-7b" 2>"$WORK/enact-err-7b"
# SPEC-FIXTURE CORRECTION (found while building; addition, nothing weakened,
# same class as the others documented at the top of this file):
# `count_matches_in_file` is a bare `grep -c` over the raw file — against
# THIS fixture's whole point (a chunk payload whose bytes spell out the
# literal line `end=ok`) it necessarily counts two, correctly, for what it
# is. That is not this assertion's question. `count_real_terminal_end_lines`
# (added above) is the chunk-aware count "reader counts, never scans" is
# actually about.
end_lines="$(count_real_terminal_end_lines "$WORK/resp-7b")"
eq "a chunk containing the literal line 'end=ok' does not create a second end= (reader counts, never scans)" \
  "$end_lines" "1"
tail_last="$(tail -1 "$WORK/resp-7b" 2>/dev/null)"
has "…and the REAL terminal end= is still the actual last line" "$tail_last" "end="

# =============================================================================
# 8. Deny path: decided-only, no chunk section, response ends with end=denied
#    (this section drives bin/aib-broker-handler directly, wire-level, since
#    "deny never enacts" is a handler-level property, not aib_enact_launch's).
# =============================================================================
FIXTURE_REG="$WORK/registry.json"
mkdir -p "${FIXTURE_HOME}2"
cat > "$FIXTURE_REG" <<JSON
{
  "schema_version": 4,
  "providers": {
    "acme": {
      "adapter": "$ADAPTER",
      "cap_sandbox": "workspace-write",
      "cap_tier": "t2",
      "cap_effort": "high",
      "cap_timeout": "900"
    }
  },
  "projects": {
    "acme": {
      "home": "$FIXTURE_HOME",
      "standup_dir": "$FIXTURE_STANDUP",
      "mux_session": "acme",
      "provider": "acme",
      "model": "team/model-v2",
      "effort": "low"
    }
  },
  "teams": {
    "acme-engine": { "project": "acme", "model": "team/model-v2" }
  },
  "agents": {
    "acme-core": {
      "project": "acme",
      "team_uid": "acme-engine",
      "profile": "engine-dev",
      "clearance": "t2",
      "effort": "high"
    }
  }
}
JSON

frame2() { # frame2 <cwd> <label> <prompt> <record-line>...
  local c="$1" l="$2" p="$3"; shift 3; local r
  for r in "$@"; do printf '%s\n' "$r"; done
  printf 'cwd_bytes=%s\nlabel_bytes=%s\nprompt_bytes=%s\n\n' \
    "$(printf '%s' "$c" | wc -c)" "$(printf '%s' "$l" | wc -c)" "$(printf '%s' "$p" | wc -c)"
  printf '%s%s%s' "$c" "$l" "$p"
}

reset_run
resp_deny="$(frame2 "" "" "hallo" "op=launch" "agent_uid=acme-ghost" \
  | AIBOBNET_REGISTRY="$FIXTURE_REG" AIB_CONFINE_BIN="$LANDLOCK_STUB" AIB_EVENT_ROOT="$EVENT_ROOT" \
    "$SRC_ROOT/bin/aib-broker-handler" 2>"$WORK/handler-err-8")"
if [ -e "$SENTINEL" ]; then no "a deny never enacts — the provider is never touched"
else ok "a deny never enacts — the provider is never touched"; fi
hasnt "…the deny response carries no chunk_bytes= section" "$resp_deny" "chunk_bytes="
has "…and it still ends with end=denied" "$resp_deny" "end=denied"

# =============================================================================
# 9. Full allow through the wire: decided committed BEFORE the adapter starts
#    (the adapter checks for its own decided record itself, not the test after
#    the fact), and ended is causally bound to it.
# =============================================================================
reset_run
adapter_conf_write assert-decided
resp_allow="$(frame2 "$FIXTURE_WS" "nightly" "hallo" "op=launch" "agent_uid=acme-core" \
  | AIBOBNET_REGISTRY="$FIXTURE_REG" AIB_CONFINE_BIN="$LANDLOCK_STUB" AIB_EVENT_ROOT="$EVENT_ROOT" \
    "$SRC_ROOT/bin/aib-broker-handler" 2>"$WORK/handler-err-9")"
has "the decided record exists BEFORE the adapter runs — the adapter checked itself, live" \
  "$resp_allow" "DECIDED_FOUND"
hasnt "…never DECIDED_MISSING" "$resp_allow" "DECIDED_MISSING"

decided_id="$(printf '%s\n' "$resp_allow" | sed -n 's/^decided_event_id=//p' | head -1)"
ended_id="$(printf '%s\n' "$resp_allow" | sed -n 's/^ended_event_id=//p' | head -1)"
if [ -n "$decided_id" ] && [ -n "$ended_id" ]; then
  ok "the response names both a decided_event_id and an ended_event_id"
  fold_check="$(aib_event_scan "$EVENTS_FILE")"
  has "…and the durable stream's ended record is causally bound to that exact decided id" \
    "$fold_check" "\"causation_id\":\"$decided_id\""
else
  no "the response names both a decided_event_id and an ended_event_id"
  no "…and the durable stream's ended record is causally bound to that exact decided id (no ids to check)"
fi
eq "exactly one end= on the full wire response too" \
  "$(count_matches_in_string '^end=' "$resp_allow")" "1"
# Marvin (gate delta, should-fix): ADR-0005's whole reason to exist is that
# LL_RW must never reach the event root — the ONLY existing assertion for
# that (§4d) runs against a bare aib_enact_launch call where AIB_EVENT_ROOT
# was never set at all, so it could not observe the hazard either way. This
# one drives the REAL handler, with AIB_EVENT_ROOT genuinely exported exactly
# as the systemd unit sets it, and inspects the stub's own logged LL_RW.
hasnt "…and LL_RW composed through the REAL handler never contains AIB_EVENT_ROOT (ADR-0005, Marvin)" \
  "$(grep '^LL_RW=' "$LL_LOG" | tail -1)" "$EVENT_ROOT"

# =============================================================================
# 10. Broker-created heartbeat log is group-writable (D-G): a broker-owned
#     umask must not lock the agent account out of its own heartbeat file.
# =============================================================================
reset_run
adapter_conf_write ok
HB_STANDUP="$WORK/hb-standup"
mkdir -p "$HB_STANDUP"
( umask 0002; aib_log_resolved "$HB_STANDUP" "acme-core" busy "codex-run: enactment test" )
HB_FILE="$HB_STANDUP/acme-core.log"
if [ -e "$HB_FILE" ]; then
  hb_perm="$(stat -c '%a' "$HB_FILE" 2>/dev/null || stat -f '%Lp' "$HB_FILE" 2>/dev/null)"
  # The GROUP write bit is the middle of the last three octal digits — not the last
  # digit (that's "other", a different question entirely).
  hb_group_digit="${hb_perm: -2:1}"
  case "$hb_group_digit" in
    2|3|6|7) ok "a heartbeat log written under umask 0002 stays group-writable (D-G)";;
    *) no "a heartbeat log written under umask 0002 stays group-writable (D-G) (mode was $hb_perm)";;
  esac
else
  no "a heartbeat log written under umask 0002 stays group-writable (D-G) (log was never created)"
fi

# =============================================================================
# 11. Disconnect while the provider is silent -> aborted, and the reaped
#     manager tree leaves no orphan (D-I). D3 (gate delta, Ikarus, HIGH): the
#     original fixture used FIXED SLEEPS as its only synchronisation, and
#     failed 57/1 under load — flaky, not just slow. This version polls two
#     real signals instead of guessing timing: $SENTINEL (written by every
#     stub-adapter mode, including silent-hang, before it goes silent) to
#     know the provider actually started, and the persisted ended record
#     (bounded poll) to know the abort actually completed, BEFORE checking
#     for an orphan — checking concurrently with the kill would race the
#     escalation timer.
# =============================================================================
if command -v pgrep >/dev/null 2>&1 && command -v mkfifo >/dev/null 2>&1; then
  reset_run
  DISC_MARKER="$WORK/disconnect-marker-$$"
  adapter_conf_write silent-hang
  FIFO="$WORK/resp-fifo"
  rm -f "$FIFO"; mkfifo "$FIFO"
  disc_decided="$(seed_decided)"
  (
    AIB_CONFINE_BIN="$LANDLOCK_STUB" aib_enact_launch "$(base_enact_record "$FIXTURE_WS")" "$(base_prompt "$DISC_MARKER")" \
      "$EVENTS_FILE" "$EVENTS_LOCK" "$ENVELOPE_KV" "$disc_decided" \
      >"$FIFO" 2>"$WORK/enact-err-11"
  ) &
  enact_bg_pid=$!
  exec 8<"$FIFO"
  disc_deadline=$((SECONDS+10))
  while [ ! -s "$SENTINEL" ] && [ "$SECONDS" -lt "$disc_deadline" ]; do sleep 0.05; done
  if [ -s "$SENTINEL" ]; then ok "…the provider actually started before the disconnect (deterministic sync)"
  else no "…the provider actually started before the disconnect (deterministic sync) (never wrote its sentinel)"; fi
  exec 8<&-         # the client disconnects: reader closed, no end= ever read
  # S1 load-proof (gate delta 3): bumped from 10s to 25s — under 2-way parallel
  # load plus CPU noise, the TERM-then-confirm-group-empty sequence (S1b) can
  # genuinely take longer than 10s of wall-clock time to become VISIBLE purely
  # from host-level scheduling contention, not from any defect (the very next
  # assertion below, and a live `ps` check, both confirm no orphan survives
  # either way) — this bound only needs to be generous, not tight.
  disc_deadline=$((SECONDS+25))
  disc_ended_seen=0
  while [ "$SECONDS" -lt "$disc_deadline" ]; do
    if aib_event_scan "$EVENTS_FILE" >/dev/null 2>&1 && \
       printf '%s\n' "$AIB_EVENT_SCAN_ENDED_IDS" | grep -qxF "$disc_decided"; then
      disc_ended_seen=1; break
    fi
    sleep 0.1
  done
  if [ "$disc_ended_seen" -eq 1 ]; then ok "…the ended record appears within a bounded poll after disconnect"
  else no "…the ended record appears within a bounded poll after disconnect (timed out)"; fi
  # pgrep runs AFTER the ended record is confirmed, never concurrently with the
  # kill (D3) — and against BOTH the direct child and its grandchild, proving
  # the fix is tree-wide, not single-pid.
  if pgrep -f "$DISC_MARKER" >/dev/null 2>&1; then
    no "a client disconnect while the provider is silent leaves no orphaned provider, tree-wide (D-I, D3)"
  else
    ok "a client disconnect while the provider is silent leaves no orphaned provider, tree-wide (D-I, D3)"
  fi
  wait "$enact_bg_pid" 2>/dev/null || true
  fold_disc="$(aib_event_scan "$EVENTS_FILE")"
  has "…and the attempt is recorded aborted, not left open forever" "$fold_disc" '"class":"aborted"'
  pkill -f "$DISC_MARKER" >/dev/null 2>&1 || true
else
  skip "no pgrep/mkfifo on this host"
  skip "no pgrep/mkfifo on this host"
  skip "no pgrep/mkfifo on this host"
  skip "no pgrep/mkfifo on this host"
fi

# =============================================================================
# 11c. R2 (gate delta 2, Riker HIGH / Ikarus HIGH): a grandchild that ignores
#     TERM must still be reached — by KILL, after the real 10s grace period —
#     proving escalation-cancellation is gated on the process GROUP being
#     empty, not on the leader's own exit. §11's grandchild dies from the
#     ordinary TERM disposition and never stresses this; this one explicitly
#     traps TERM away, so nothing but the killer's own group-KILL can end it.
#     Genuinely takes ~10s (the real grace period, not shortened for the
#     test) — that IS the assertion: cancelling early is exactly the bug.
# =============================================================================
if command -v pgrep >/dev/null 2>&1 && command -v mkfifo >/dev/null 2>&1; then
  reset_run
  TRAP_MARKER="$WORK/trap-term-marker-$$"
  adapter_conf_write silent-hang-term-trap
  FIFO3="$WORK/resp-fifo3"
  rm -f "$FIFO3"; mkfifo "$FIFO3"
  trap_decided="$(seed_decided)"
  (
    AIB_CONFINE_BIN="$LANDLOCK_STUB" aib_enact_launch "$(base_enact_record "$FIXTURE_WS")" "$(base_prompt "$TRAP_MARKER")"       "$EVENTS_FILE" "$EVENTS_LOCK" "$ENVELOPE_KV" "$trap_decided"       >"$FIFO3" 2>"$WORK/enact-err-11c"
  ) &
  trap_bg_pid=$!
  exec 7<"$FIFO3"
  trap_start_deadline=$((SECONDS+10))
  while [ ! -s "$SENTINEL" ] && [ "$SECONDS" -lt "$trap_start_deadline" ]; do sleep 0.05; done
  if [ -s "$SENTINEL" ]; then ok "…the TERM-trapping provider actually started before the disconnect"
  else no "…the TERM-trapping provider actually started before the disconnect (never wrote its sentinel)"; fi
  exec 7<&-   # disconnect: triggers TERM to the whole group, then (after the
              # grandchild survives it) KILL after the real 10s grace period
  # Bounded poll generous enough to cover the full 10s grace plus margin —
  # this is the one fixture in the file that is SUPPOSED to take that long.
  trap_deadline=$((SECONDS+20))
  trap_ended_seen=0
  while [ "$SECONDS" -lt "$trap_deadline" ]; do
    if aib_event_scan "$EVENTS_FILE" >/dev/null 2>&1 &&        printf '%s
' "$AIB_EVENT_SCAN_ENDED_IDS" | grep -qxF "$trap_decided"; then
      trap_ended_seen=1; break
    fi
    sleep 0.2
  done
  if [ "$trap_ended_seen" -eq 1 ]; then ok "…the ended record appears once the group is actually reaped"
  else no "…the ended record appears once the group is actually reaped (timed out)"; fi
  if pgrep -f "$TRAP_MARKER" >/dev/null 2>&1; then
    no "…and the TERM-ignoring grandchild is eventually reached by KILL, tree-wide (R2)"
  else
    ok "…and the TERM-ignoring grandchild is eventually reached by KILL, tree-wide (R2)"
  fi
  wait "$trap_bg_pid" 2>/dev/null || true
  has "…and the record names KILL, not TERM, as what actually ended it" \
    "$(aib_event_scan "$EVENTS_FILE")" '"signal":"KILL"'
  pkill -f "$TRAP_MARKER" >/dev/null 2>&1 || true
else
  skip "no pgrep/mkfifo on this host"
  skip "no pgrep/mkfifo on this host"
  skip "no pgrep/mkfifo on this host"
  skip "no pgrep/mkfifo on this host"
fi

# =============================================================================
# 11b. Marvin (gate delta, should-fix, Gap 5): disconnect WHILE the provider
#     is actively streaming, not silent — the other half of D-I. This is the
#     one that actually exercises `trap '' PIPE` and the relay loop's checked
#     write: without either, a write to the closed pipe would kill the whole
#     function on an ordinary SIGPIPE instead of returning EPIPE.
# =============================================================================
if command -v pgrep >/dev/null 2>&1 && command -v mkfifo >/dev/null 2>&1; then
  reset_run
  TRICKLE_MARKER="$WORK/trickle-marker-$$"
  adapter_conf_write trickle
  FIFO2="$WORK/resp-fifo2"
  rm -f "$FIFO2"; mkfifo "$FIFO2"
  trickle_decided="$(seed_decided)"
  (
    AIB_CONFINE_BIN="$LANDLOCK_STUB" aib_enact_launch "$(base_enact_record "$FIXTURE_WS")" "$(base_prompt "$TRICKLE_MARKER")" \
      "$EVENTS_FILE" "$EVENTS_LOCK" "$ENVELOPE_KV" "$trickle_decided" \
      >"$FIFO2" 2>"$WORK/enact-err-11b"
  ) &
  trickle_bg_pid=$!
  exec 9<"$FIFO2"
  # Read exactly the FIRST chunk header + its bytes (deterministic: the
  # adapter writes "trickle-1\n" then sleeps, well before writing more), then
  # disconnect while it is still mid-stream.
  IFS= read -r _hdr <&9
  case "$_hdr" in
    chunk_bytes=*) : ;;
    *) no "trickle fixture: unexpected first line '$_hdr'" ;;
  esac
  IFS= read -r _blank <&9 || true
  IFS= read -r _first_chunk_line <&9 || true
  exec 9<&-   # disconnect mid-stream, provider still producing output
  # S1 load-proof (gate delta 3): same reasoning as the disconnect fixture above.
  trickle_deadline=$((SECONDS+25))
  trickle_ended_seen=0
  while [ "$SECONDS" -lt "$trickle_deadline" ]; do
    if aib_event_scan "$EVENTS_FILE" >/dev/null 2>&1 && \
       printf '%s\n' "$AIB_EVENT_SCAN_ENDED_IDS" | grep -qxF "$trickle_decided"; then
      trickle_ended_seen=1; break
    fi
    sleep 0.1
  done
  if [ "$trickle_ended_seen" -eq 1 ]; then ok "a mid-stream disconnect still reaches a terminal ended record (Gap 5)"
  else no "a mid-stream disconnect still reaches a terminal ended record (Gap 5) (timed out)"; fi
  if pgrep -f "$TRICKLE_MARKER" >/dev/null 2>&1; then
    no "…and leaves no orphaned provider either"
  else
    ok "…and leaves no orphaned provider either"
  fi
  wait "$trickle_bg_pid" 2>/dev/null || true
  trickle_fold="$(aib_event_scan "$EVENTS_FILE")"
  has "…recorded aborted, not left open forever" "$trickle_fold" '"class":"aborted"'
  pkill -f "$TRICKLE_MARKER" >/dev/null 2>&1 || true
else
  skip "no pgrep/mkfifo on this host"
  skip "no pgrep/mkfifo on this host"
  skip "no pgrep/mkfifo on this host"
fi

# =============================================================================
# 12. D8 (gate delta, Ikarus, MEDIUM): an attempt.ended commit failure AFTER
#     the provider already ran must still close the wire with exactly one
#     terminal end= — never a positive-length chunk followed by bare EOF.
#     Reproduced exactly like Ikarus's repro: commit a real decided record,
#     corrupt the stream with an unparsable terminated line, then run a
#     provider that succeeds — the ended commit itself must now fail.
# =============================================================================
reset_run
adapter_conf_write ok
INCIDENT_EVENTS="$WORK/incident/main.events"
INCIDENT_LOCK="$WORK/incident/main.events.lock"
mkdir -p "$WORK/incident"
# seed_decided() commits against $EVENTS_FILE, not this dedicated stream — this
# fixture needs its OWN stream (with its OWN decided record) so the corruption
# below cannot also poison $EVENTS_FILE for every section after this one.
incident_kv="$(printf 'decision=allow\ncode=0\nreasons=\npid=%s\nprompt_len=1\nprompt_sha256=deadbeef' "$$")"
incident_payload="$(aib_event_compose_decided_payload "$incident_kv")"
aib_event_commit "$INCIDENT_EVENTS" "$INCIDENT_LOCK" attempt.decided "$ENVELOPE_KV" "$incident_payload" >/dev/null 2>&1
incident_decided="$AIB_EVENT_COMMIT_EVENT_ID"
printf 'corrupt terminated record\n' >> "$INCIDENT_EVENTS"
AIB_CONFINE_BIN="$LANDLOCK_STUB" aib_enact_launch "$(base_enact_record "$FIXTURE_WS")" "$(base_prompt)" \
  "$INCIDENT_EVENTS" "$INCIDENT_LOCK" "$ENVELOPE_KV" "$incident_decided" \
  >"$WORK/resp-12" 2>"$WORK/enact-err-12"
incident_rc=$?
eq "an ended-commit failure after the provider ran is reported nonzero" \
  "$([ "$incident_rc" -ne 0 ] && printf nonzero || printf zero)" "nonzero"
has "…the response still closes the chunk section" "$(<"$WORK/resp-12")" "chunk_bytes=0"
has "…and ends with a flat reason=event_store_unavailable / end=error, never a bare EOF" \
  "$(<"$WORK/resp-12")" "reason=event_store_unavailable"
eq "…exactly one end= line, and it is error" "$(tail -1 "$WORK/resp-12" 2>/dev/null)" "end=error"
eq "…exactly one end= total" "$(count_matches_in_file '^end=' "$WORK/resp-12")" "1"

# =============================================================================
# 12b. R4 (gate delta 2, Ikarus MEDIUM): an ended-commit failure during the
#     confinement PRE-FLIGHT (before the provider was ever considered) is the
#     SAME incident, not a special case — but the pre-flight's own early-return
#     branch called aib_enact_launch__write_terminal unconditionally, so a
#     failed commit there produced empty exit_class=/stage=/ended_event_id=
#     fields and a false end=ok instead of end=error. Reproduced exactly like
#     Ikarus's repro: a corrupt stream, PLUS an unusable AIB_CONFINE_BIN so the
#     pre-flight itself refuses before the adapter is ever named.
# =============================================================================
reset_run
INCIDENT_PF_EVENTS="$WORK/incident-pf/main.events"
INCIDENT_PF_LOCK="$WORK/incident-pf/main.events.lock"
mkdir -p "$WORK/incident-pf"
incident_pf_kv="$(printf 'decision=allow
code=0
reasons=
pid=%s
prompt_len=1
prompt_sha256=deadbeef' "$$")"
incident_pf_payload="$(aib_event_compose_decided_payload "$incident_pf_kv")"
aib_event_commit "$INCIDENT_PF_EVENTS" "$INCIDENT_PF_LOCK" attempt.decided "$ENVELOPE_KV" "$incident_pf_payload" >/dev/null 2>&1
incident_pf_decided="$AIB_EVENT_COMMIT_EVENT_ID"
printf 'corrupt terminated record
' >> "$INCIDENT_PF_EVENTS"
AIB_CONFINE_BIN=/nonexistent/aib-landlock-exec aib_enact_launch "$(base_enact_record "$FIXTURE_WS")" "$(base_prompt)"   "$INCIDENT_PF_EVENTS" "$INCIDENT_PF_LOCK" "$ENVELOPE_KV" "$incident_pf_decided"   >"$WORK/resp-12b" 2>"$WORK/enact-err-12b"
incident_pf_rc=$?
eq "an ended-commit failure during the pre-flight is reported nonzero"   "$([ "$incident_pf_rc" -ne 0 ] && printf nonzero || printf zero)" "nonzero"
has "…the response still closes the chunk section" "$(<"$WORK/resp-12b")" "chunk_bytes=0"
has "…and ends with a flat reason=event_store_unavailable / end=error, never a bare EOF"   "$(<"$WORK/resp-12b")" "reason=event_store_unavailable"
eq "…exactly one end= line, and it is error" "$(tail -1 "$WORK/resp-12b" 2>/dev/null)" "end=error"
eq "…exactly one end= total" "$(count_matches_in_file '^end=' "$WORK/resp-12b")" "1"
if grep -qxF 'exit_class=' "$WORK/resp-12b"; then
  no "…never an empty exit_class= field masquerading as a real (absent) verdict"
else
  ok "…never an empty exit_class= field masquerading as a real (absent) verdict"
fi
hasnt "…and never a false end=ok" "$(<"$WORK/resp-12b")" "end=ok"

# =============================================================================
# 13. Marvin (gate delta, should-fix, edge): AIB_EVENT_ROOT is SET and its
#     project subdirectory already EXISTS, but is not writable — the other
#     branch of the handler's `mkdir -p ... || [ ! -w "$_event_dir" ]` guard;
#     only "directory absent, mkdir succeeds" had a fixture before this.
# =============================================================================
RO_EVENT_ROOT="$WORK/ro-event-root"
mkdir -p "$RO_EVENT_ROOT/acme"
chmod 0500 "$RO_EVENT_ROOT/acme"
reset_run
resp_ro="$(frame2 "$FIXTURE_WS" "" "hallo" "op=launch" "agent_uid=acme-core" \
  | AIBOBNET_REGISTRY="$FIXTURE_REG" AIB_CONFINE_BIN="$LANDLOCK_STUB" AIB_EVENT_ROOT="$RO_EVENT_ROOT" \
    "$SRC_ROOT/bin/aib-broker-handler" 2>"$WORK/handler-err-13")"
chmod 0700 "$RO_EVENT_ROOT/acme"
if [ -e "$SENTINEL" ]; then no "an existing-but-unwritable AIB_EVENT_ROOT subdir never enacts"
else ok "an existing-but-unwritable AIB_EVENT_ROOT subdir never enacts"; fi
has "…and answers error, not a silent success" "$resp_ro" "reason=event_store_unavailable"
has "…ending end=error" "$resp_ro" "end=error"

# =============================================================================
# 14. Marvin (gate delta, should-fix, edge): a provider that closes its
#     stdout early but keeps running afterward — the relay's "true EOF" is
#     structurally independent of the provider's actual process lifetime;
#     the terminal record must reflect the EVENTUAL exit, not the moment
#     stdout closed.
# =============================================================================
reset_run
adapter_conf_write early-close
AIB_CONFINE_BIN="$LANDLOCK_STUB" aib_enact_launch "$(base_enact_record "$FIXTURE_WS")" "$(base_prompt)" \
  "$EVENTS_FILE" "$EVENTS_LOCK" "$ENVELOPE_KV" "$(seed_decided)" >"$WORK/resp-14" 2>"$WORK/enact-err-14"
eq "a provider closing stdout early still runs to its real exit before the record is committed" \
  "${AIB_ENACT_EXIT_CLASS:-}" "ok"
has "…and its actual (late) exit code reaches the wire" "$(<"$WORK/resp-14")" "exit_class=ok"

# =============================================================================
# 15b. R5(b) (gate delta 2, Marvin unpinned must-fix, Ikarus MEDIUM original):
#     the confined-mode post-cd re-check reuses aib_contain_cwd (D6), already
#     confirmed correct by direct repro in the previous round — but with no
#     pin, at THIS specific call site, for either boundary case the task
#     asked for. Two things: root="/" (the exact shape a hand-rolled
#     "$resolved_root"/* glob gets wrong, since "//*" matches nothing with a
#     single leading slash) must still allow a real cwd underneath it; and
#     "/srv/ws" vs "/srv/ws2" (a literal STRING-PREFIX match would wrongly
#     treat ws2 as inside ws) must still be refused at a path-component
#     boundary, at this call site specifically, not only at the PDP's own
#     (already-covered) aib_contain_cwd call.
# =============================================================================
reset_run
landlock_conf_write ok
adapter_conf_write ok
root_slash_record="$(printf 'adapter=%s\nroot=/\ncwd=/tmp\nsandbox=read-only\neffort=high\nmodel=team/model-v2\ntimeout=5' "$ADAPTER")"
AIB_CONFINE_BIN="$LANDLOCK_STUB" aib_enact_launch "$root_slash_record" "$(base_prompt)" \
  "$EVENTS_FILE" "$EVENTS_LOCK" "$ENVELOPE_KV" "$(seed_decided)" >"$WORK/resp-15b1" 2>"$WORK/enact-err-15b1"
if [ -e "$SENTINEL" ]; then ok "root=/ with cwd=/tmp: the provider actually runs (R5b)"
else no "root=/ with cwd=/tmp: the provider actually runs (R5b) (never called — refused as outside root=/)"; fi
eq "…classified ok, not io-refused/cwd" "${AIB_ENACT_EXIT_CLASS:-}" "ok"
eq "…stage=provider" "${AIB_ENACT_STAGE:-}" "provider"

reset_run
landlock_conf_write ok
adapter_conf_write ok
SRV_WS="$WORK/srv-ws"
SRV_WS2="$WORK/srv-ws2"
mkdir -p "$SRV_WS/sub" "$SRV_WS2"
srv_boundary_record="$(printf 'adapter=%s\nroot=%s\ncwd=%s\nsandbox=read-only\neffort=high\nmodel=team/model-v2\ntimeout=5' \
  "$ADAPTER" "$SRV_WS" "$SRV_WS2")"
AIB_CONFINE_BIN="$LANDLOCK_STUB" aib_enact_launch "$srv_boundary_record" "$(base_prompt)" \
  "$EVENTS_FILE" "$EVENTS_LOCK" "$ENVELOPE_KV" "$(seed_decided)" >"$WORK/resp-15b2" 2>"$WORK/enact-err-15b2"
if [ -e "$SENTINEL" ]; then no "…/srv-ws2 is NOT inside root=/srv-ws — a string-prefix match would wrongly allow it (R5b)"
else ok "…/srv-ws2 is NOT inside root=/srv-ws — a string-prefix match would wrongly allow it (R5b)"; fi
eq "…refused at the cwd stage" "${AIB_ENACT_STAGE:-}" "cwd"
eq "…exit_class io-refused" "${AIB_ENACT_EXIT_CLASS:-}" "io-refused"

# =============================================================================
# 15. R3 (gate delta 2, Ikarus MEDIUM) + R5(a) (gate delta 2, Marvin unpinned
#     must-fix, Ikarus HIGH original): a client that disconnects at the
#     PROLOGUE boundary — before aib_enact_launch is ever called — drives the
#     REAL bin/aib-broker-handler, not aib_enact_launch directly (this is the
#     handler's own trap '' PIPE + single checked prologue printf, which live
#     strictly before enactment starts). Two things must both hold: the
#     handler must not die from a raw SIGPIPE (R5a: no automated coverage
#     existed for this at all, though the fix itself was confirmed correct by
#     direct repro), and the resulting terminal record must say what actually
#     happened — stage=transport, not stage=provider (R3: no provider was
#     ever invoked here).
# =============================================================================
if command -v mkfifo >/dev/null 2>&1; then
  reset_run
  PROLOGUE_FIFO="$WORK/prologue-disc-fifo"
  rm -f "$PROLOGUE_FIFO"; mkfifo "$PROLOGUE_FIFO"
  _pf_before_lines="$(wc -l < "$EVENTS_FILE" 2>/dev/null || printf 0)"
  (
    frame2 "$FIXTURE_WS" "nightly" "hallo" "op=launch" "agent_uid=acme-core" \
      | AIBOBNET_REGISTRY="$FIXTURE_REG" AIB_CONFINE_BIN="$LANDLOCK_STUB" AIB_EVENT_ROOT="$EVENT_ROOT" \
        "$SRC_ROOT/bin/aib-broker-handler" >"$PROLOGUE_FIFO" 2>"$WORK/handler-err-pf"
    printf '%s' "$?" > "$WORK/handler-rc-pf"
  ) &
  _pf_bg_pid=$!
  # Open the reader, then close it immediately without reading a single byte —
  # the same "connect, then vanish before any response byte is read" shape as
  # Ikarus' and Marvin's own repros. Opening the fifo for read is what lets the
  # backgrounded handler actually start running (its own stdout redirect blocks
  # until a reader appears); closing it again right away, before the handler
  # has done anything more than a registry lookup and a decided-commit, puts
  # its eventual prologue write on a connection that is already gone.
  exec 6<"$PROLOGUE_FIFO"
  exec 6<&-
  wait "$_pf_bg_pid" 2>/dev/null || true
  _pf_rc="$(cat "$WORK/handler-rc-pf" 2>/dev/null || printf 255)"
  case "$_pf_rc" in
    ''|*[!0-9]*) _pf_rc=255;;
  esac
  if [ "$_pf_rc" -lt 128 ]; then
    ok "…the handler is not killed outright by the disconnect (R5a, trap '' PIPE)"
  else
    no "…the handler is not killed outright by the disconnect (R5a, trap '' PIPE) (rc=$_pf_rc, signal death)"
  fi
  _pf_new="$(tail -n "+$((_pf_before_lines+1))" "$EVENTS_FILE" 2>/dev/null)"
  _pf_decided_n="$(printf '%s\n' "$_pf_new" | grep -c '"event_type":"attempt.decided"')"
  _pf_ended_n="$(printf '%s\n' "$_pf_new" | grep -c '"event_type":"attempt.ended"')"
  eq "…exactly one new attempt.decided record" "$_pf_decided_n" "1"
  eq "…exactly one new attempt.ended record, matched (not left open)" "$_pf_ended_n" "1"
  has "…the ended record says stage=transport, not stage=provider (R3 — no provider ever ran)" \
    "$_pf_new" '"stage":"transport"'
  hasnt "…and never claims stage=provider for a connection that never reached enactment" \
    "$_pf_new" '"stage":"provider"'
  if [ -e "$SENTINEL" ]; then
    no "…and the adapter/provider was never invoked at all"
  else
    ok "…and the adapter/provider was never invoked at all"
  fi
else
  skip "no mkfifo on this host"
  skip "no mkfifo on this host"
  skip "no mkfifo on this host"
  skip "no mkfifo on this host"
  skip "no mkfifo on this host"
  skip "no mkfifo on this host"
fi

# =============================================================================
# 15c. S1a (gate delta 3, Marvin root-cause / Ikarus HIGH): the confined exec
#     chain must lead its OWN process group with pgid == its own pid — not via
#     util-linux setsid's conditional fork-when-already-a-leader behaviour
#     (the actual root cause of the R2 orphans under load: when it forked, the
#     manager's captured provider_pid stopped being the group leader, so every
#     `kill -- "-$provider_pid"` hit an empty/wrong group while the real tree
#     survived, reparented to PID 1). Checks BOTH the leader itself and its
#     forked grandchild share one real process group.
# =============================================================================
if command -v pgrep >/dev/null 2>&1 && command -v ps >/dev/null 2>&1; then
  reset_run
  PGID_MARKER="$WORK/pgid-marker-$$"
  adapter_conf_write silent-hang
  pgid_decided="$(seed_decided)"
  AIB_CONFINE_BIN="$LANDLOCK_STUB" aib_enact_launch "$(base_enact_record "$FIXTURE_WS")" "$(base_prompt "$PGID_MARKER")" \
    "$EVENTS_FILE" "$EVENTS_LOCK" "$ENVELOPE_KV" "$pgid_decided" \
    >"$WORK/resp-pgid" 2>"$WORK/enact-err-pgid" &
  pgid_bg_pid=$!
  pgid_deadline=$((SECONDS+10))
  while [ ! -s "$SENTINEL" ] && [ "$SECONDS" -lt "$pgid_deadline" ]; do sleep 0.05; done
  # A brief settle so the grandchild fork has actually happened by the time we
  # enumerate pids — the sentinel only proves the PARENT started.
  sleep 0.3
  _pgid_pids="$(pgrep -f "$PGID_MARKER" 2>/dev/null)"
  _pgid_count="$(printf '%s\n' "$_pgid_pids" | grep -c .)"
  if [ "$_pgid_count" -ge 2 ]; then
    ok "…both the leader and its forked grandchild are found (sanity)"
  else
    no "…both the leader and its forked grandchild are found (sanity) (found $_pgid_count)"
  fi
  _pgid_ref="" _pgid_all_same=1 _pgid_leader_found=0
  for _p in $_pgid_pids; do
    _this_pgid="$(ps -o pgid= -p "$_p" 2>/dev/null | tr -d ' ')"
    [ -n "$_this_pgid" ] || continue
    if [ -z "$_pgid_ref" ]; then _pgid_ref="$_this_pgid"; fi
    [ "$_this_pgid" = "$_pgid_ref" ] || _pgid_all_same=0
    [ "$_p" != "$_this_pgid" ] || _pgid_leader_found=1
  done
  if [ "$_pgid_all_same" -eq 1 ]; then
    ok "…the leader and its grandchild share ONE real process group (S1a)"
  else
    no "…the leader and its grandchild share ONE real process group (S1a) (pgids differed)"
  fi
  if [ "$_pgid_leader_found" -eq 1 ]; then
    ok "…that group has a REAL leader among the confined chain (pgid == a member's own pid), not setsid's fork"
  else
    no "…that group has a REAL leader among the confined chain (pgid == a member's own pid), not setsid's fork"
  fi
  pkill -9 -f "$PGID_MARKER" >/dev/null 2>&1 || true
  wait "$pgid_bg_pid" 2>/dev/null || true
else
  skip "no pgrep/ps on this host"
  skip "no pgrep/ps on this host"
  skip "no pgrep/ps on this host"
fi

# =============================================================================
# 16. LOW (gate delta 2, Ikarus): a confined run's escalation-marker temp file
#     (aibobnet-escalated.*) must not survive the run — not just on the
#     escalated path (already covered structurally by the run itself), but on
#     the ordinary, nothing-went-wrong path too, since it is created
#     unconditionally up front and only ever WRITTEN to conditionally.
# =============================================================================
reset_run
landlock_conf_write ok
adapter_conf_write ok
_marker_before="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -type f -name 'aibobnet-escalated.*' 2>/dev/null | wc -l)"
AIB_CONFINE_BIN="$LANDLOCK_STUB" aib_enact_launch "$(base_enact_record "$FIXTURE_WS")" "$(base_prompt)" \
  "$EVENTS_FILE" "$EVENTS_LOCK" "$ENVELOPE_KV" "$(seed_decided)" >"$WORK/resp-16" 2>"$WORK/enact-err-16"
_marker_after="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -type f -name 'aibobnet-escalated.*' 2>/dev/null | wc -l)"
eq "a confined run leaves no escalation-marker temp file behind (LOW)" "$_marker_after" "$_marker_before"

printf '\nbroker_enact_spec: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
