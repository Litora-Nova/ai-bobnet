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
#     aib_enact_launch <enact-record> <events-path> <lock-path> <envelope-kv> \
#                       <decided-event-id>
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
#   trusted) · sandbox / effort / model / timeout (all EFFECTIVE, already clamped) ·
#   prompt.
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
  local mode="${1:-ok}"
  cat > "$STUB_BIN/landlock.conf" <<EOF
STUB_LL_MODE='$mode'
STUB_LL_LOG='$LL_LOG'
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
    # Proves no orphan: unique in argv/`ps` via $STUB_SENTINEL's own path.
    while :; do sleep 1; done
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

base_enact_record() { # base_enact_record <cwd> [prompt-mode-as-prompt-text]
  printf 'adapter=%s\nroot=%s\ncwd=%s\nsandbox=workspace-write\neffort=high\nmodel=team/model-v2\ntimeout=5\nprompt=%s' \
    "$ADAPTER" "$FIXTURE_HOME" "$1" "${2:-hello}"
}

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
old_ended_payload="$(aib_event_compose_ended_payload "exit_class=ok")"
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
reset_run
unset AIB_CONFINE_BIN 2>/dev/null || true
enact_out="$(AIB_CONFINE_BIN="" aib_enact_launch "$(base_enact_record "$FIXTURE_WS")" \
  "$EVENTS_FILE" "$EVENTS_LOCK" "$ENVELOPE_KV" "test-decided-1" 2>"$WORK/enact-err-4a")"
enact_rc=$?
if [ -e "$SENTINEL" ]; then no "an unset AIB_CONFINE_BIN never runs the provider"
else ok "an unset AIB_CONFINE_BIN never runs the provider"; fi
eq "…and the enactment fails closed (nonzero)" "$([ "$enact_rc" -ne 0 ] && printf nonzero || printf zero)" "nonzero"

# --- pre-flight failure (D-A): confinement unavailable -> io-refused/confine ---
reset_run
landlock_conf_write preflight-fail
adapter_conf_write ok
enact_out="$(AIB_CONFINE_BIN="$LANDLOCK_STUB" aib_enact_launch "$(base_enact_record "$FIXTURE_WS")" \
  "$EVENTS_FILE" "$EVENTS_LOCK" "$ENVELOPE_KV" "test-decided-2" 2>"$WORK/enact-err-4b")"
if [ -e "$SENTINEL" ]; then no "a failed pre-flight never runs the provider (D-A)"
else ok "a failed pre-flight never runs the provider (D-A)"; fi
eq "…and AIB_ENACT_EXIT_CLASS is io-refused" "${AIB_ENACT_EXIT_CLASS:-}" "io-refused"
eq "…and AIB_ENACT_STAGE is confine, not provider (D-K)" "${AIB_ENACT_STAGE:-}" "confine"
has "…the pre-flight call itself targets /bin/true, not the real adapter" "$(<"$LL_LOG")" "argv=/bin/true"

# =============================================================================
# --- 4c. LL_RW is composed from the registry snapshot only; a request cwd
#     cannot widen it (SPEC-wire-format :82) ---------------------------------
# =============================================================================
reset_run
landlock_conf_write ok
adapter_conf_write ok
mkdir -p "$FIXTURE_WS/sub-a" "$FIXTURE_WS/sub-b"
AIB_CONFINE_BIN="$LANDLOCK_STUB" aib_enact_launch "$(base_enact_record "$FIXTURE_WS/sub-a")" \
  "$EVENTS_FILE" "$EVENTS_LOCK" "$ENVELOPE_KV" "test-decided-3a" >/dev/null 2>"$WORK/enact-err-4c1"
ll_rw_a="$(grep '^LL_RW=' "$LL_LOG" | tail -1)"
reset_run
AIB_CONFINE_BIN="$LANDLOCK_STUB" aib_enact_launch "$(base_enact_record "$FIXTURE_WS/sub-b")" \
  "$EVENTS_FILE" "$EVENTS_LOCK" "$ENVELOPE_KV" "test-decided-3b" >/dev/null 2>"$WORK/enact-err-4c2"
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
has "…while standup_dir itself (a real agent-writable subtree of home) IS reachable" \
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
swap_record="$(printf 'adapter=%s\nroot=%s\ncwd=%s\nsandbox=workspace-write\neffort=high\nmodel=team/model-v2\ntimeout=5\nprompt=hello' \
  "$ADAPTER" "$SWAP_ROOT" "$authorized_cwd")"
AIB_CONFINE_BIN="$LANDLOCK_STUB" aib_enact_launch "$swap_record" \
  "$EVENTS_FILE" "$EVENTS_LOCK" "$ENVELOPE_KV" "test-decided-4e" >"$WORK/resp-4e" 2>"$WORK/enact-err-4e"
if [ -e "$SENTINEL" ]; then no "a cwd swapped to point outside root after authorize never runs the adapter (D2/D-C)"
else ok "a cwd swapped to point outside root after authorize never runs the adapter (D2/D-C)"; fi
eq "…classified stage=cwd, not confine or provider" "${AIB_ENACT_STAGE:-}" "cwd"
eq "…and exit_class is io-refused" "${AIB_ENACT_EXIT_CLASS:-}" "io-refused"
has "…the terminal line on the wire names stage=cwd" "$(<"$WORK/resp-4e")" "stage=cwd"

# =============================================================================
# 5. Successful enactment: helper receives the right shape, adapter runs once,
#    chunk framing carries opaque bytes intact.
# =============================================================================
reset_run
landlock_conf_write ok
adapter_conf_write ok
AIB_CONFINE_BIN="$LANDLOCK_STUB" aib_enact_launch "$(base_enact_record "$FIXTURE_WS" "make it so")" \
  "$EVENTS_FILE" "$EVENTS_LOCK" "$ENVELOPE_KV" "test-decided-5" >"$WORK/resp-5" 2>"$WORK/enact-err-5"
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

# =============================================================================
# 6. Exit-class mapping carries stage=provider, so a provider's OWN exit 3/127
#    is never misread as a confinement refusal (advisor finding on D-A/D-C).
# =============================================================================
reset_run
landlock_conf_write ok
adapter_conf_write err 3
AIB_CONFINE_BIN="$LANDLOCK_STUB" aib_enact_launch "$(base_enact_record "$FIXTURE_WS")" \
  "$EVENTS_FILE" "$EVENTS_LOCK" "$ENVELOPE_KV" "test-decided-6a" >"$WORK/resp-6a" 2>"$WORK/enact-err-6a"
eq "a provider exiting 3 is provider-failure, never confine (advisor: exit code is not reservable)" \
  "${AIB_ENACT_EXIT_CLASS:-}" "provider-failure"
eq "…and its stage is provider" "${AIB_ENACT_STAGE:-}" "provider"

reset_run
adapter_conf_write err 127
AIB_CONFINE_BIN="$LANDLOCK_STUB" aib_enact_launch "$(base_enact_record "$FIXTURE_WS")" \
  "$EVENTS_FILE" "$EVENTS_LOCK" "$ENVELOPE_KV" "test-decided-6b" >"$WORK/resp-6b" 2>"$WORK/enact-err-6b"
eq "a provider exiting 127 is io-refused, but stage=provider (not confine)" \
  "${AIB_ENACT_EXIT_CLASS:-}" "io-refused"
eq "…its stage is provider, distinguishing it from a helper-side io-refused" "${AIB_ENACT_STAGE:-}" "provider"

reset_run
adapter_conf_write sleep 0 5
timeout_record="$(printf 'adapter=%s\nroot=%s\ncwd=%s\nsandbox=workspace-write\neffort=high\nmodel=team/model-v2\ntimeout=1\nprompt=hello' \
  "$ADAPTER" "$FIXTURE_HOME" "$FIXTURE_WS")"
AIB_CONFINE_BIN="$LANDLOCK_STUB" aib_enact_launch "$timeout_record" \
  "$EVENTS_FILE" "$EVENTS_LOCK" "$ENVELOPE_KV" "test-decided-6c" >"$WORK/resp-6c" 2>"$WORK/enact-err-6c"
eq "a provider outliving the effective timeout is classified timeout" "${AIB_ENACT_EXIT_CLASS:-}" "timeout"
has "…exit_code=124 on the wire" "$(<"$WORK/resp-6c")" "exit_code=124"

# =============================================================================
# 7. Chunk bytes are opaque: a NUL inside a chunk, and a chunk containing the
#    literal line "end=ok", must not disturb the frame (D-H, and the advisor's
#    "proves the reader counts, not scans").
# =============================================================================
reset_run
adapter_conf_write chunk-nul
AIB_CONFINE_BIN="$LANDLOCK_STUB" aib_enact_launch "$(base_enact_record "$FIXTURE_WS")" \
  "$EVENTS_FILE" "$EVENTS_LOCK" "$ENVELOPE_KV" "test-decided-7a" >"$WORK/resp-7a" 2>"$WORK/enact-err-7a"
body_bytes="$(file_byte_count "$WORK/resp-7a")"
if [ "$body_bytes" -gt 0 ] && grep -qaF 'before' "$WORK/resp-7a" && grep -qaF 'after' "$WORK/resp-7a"; then
  ok "a NUL byte inside a chunk survives to the far side of the frame intact"
else
  no "a NUL byte inside a chunk survives to the far side of the frame intact"
fi

reset_run
adapter_conf_write chunk-endok
AIB_CONFINE_BIN="$LANDLOCK_STUB" aib_enact_launch "$(base_enact_record "$FIXTURE_WS")" \
  "$EVENTS_FILE" "$EVENTS_LOCK" "$ENVELOPE_KV" "test-decided-7b" >"$WORK/resp-7b" 2>"$WORK/enact-err-7b"
end_lines="$(count_matches_in_file '^end=' "$WORK/resp-7b")"
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
# 11. Disconnect while the provider is silent -> aborted, and the reaped child
#     leaves no orphan (D-I). Timing-sensitive by nature (advisor: detection is
#     on the next write); generous sleeps to keep it deterministic under load.
# =============================================================================
if command -v pgrep >/dev/null 2>&1 && command -v mkfifo >/dev/null 2>&1; then
  reset_run
  DISC_MARKER="$WORK/disconnect-marker-$$"
  adapter_conf_write silent-hang
  FIFO="$WORK/resp-fifo"
  rm -f "$FIFO"; mkfifo "$FIFO"
  (
    AIB_CONFINE_BIN="$LANDLOCK_STUB" aib_enact_launch "$(base_enact_record "$FIXTURE_WS" "$DISC_MARKER")" \
      "$EVENTS_FILE" "$EVENTS_LOCK" "$ENVELOPE_KV" "test-decided-11" \
      >"$FIFO" 2>"$WORK/enact-err-11"
  ) &
  enact_bg_pid=$!
  exec 8<"$FIFO"
  sleep 0.3        # let the provider actually start and go silent
  exec 8<&-         # the client disconnects: reader closed, no end= ever read
  sleep 2           # give the abort path time to notice on its next write attempt
  if pgrep -f "$DISC_MARKER" >/dev/null 2>&1; then
    no "a client disconnect while the provider is silent leaves no orphaned provider (D-I)"
  else
    ok "a client disconnect while the provider is silent leaves no orphaned provider (D-I)"
  fi
  wait "$enact_bg_pid" 2>/dev/null || true
  fold_disc="$(aib_event_scan "$EVENTS_FILE")"
  has "…and the attempt is recorded aborted, not left open forever" "$fold_disc" '"class":"aborted"'
  pkill -f "$DISC_MARKER" >/dev/null 2>&1 || true
else
  skip "no pgrep/mkfifo on this host"
  skip "no pgrep/mkfifo on this host"
fi

printf '\nbroker_enact_spec: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
