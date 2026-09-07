#!/usr/bin/env bash
# ai-bobnet — RM-3 broker, slice 5: `high_water` anchor + admission capacity.
#
# WHAT THIS PINS
#   `docs/CONTRACT-mediation.md` §5/§5.1 specified the anchor's ordering and its two
#   distinguishable failure cases but deliberately left its storage location, absence
#   behaviour, and any capacity control unspecified ("no predecessor", §7). This file
#   pins the maintainer's slice-5 design (`standup/_design_rm3-slice5.md` v2, decisions
#   H1-H8) as revised against an architecture consult (`standup/_advisor_rm3-slice5.md`,
#   findings F1-F17) and recorded in ADR-0006 (`docs/decisions/0006-anchor-and-capacity.md`,
#   read that file's Alternatives/Consequences sections for the reasoning behind each
#   pin below — this header restates only the interfaces).
#
#   THE INTERFACES THIS SPEC PINS (the builder must provide them to this shape):
#
#     aib_event_commit <events_path> <lock_path> <event_type> <envelope_kv> \
#                       <payload_json> [decided_event_id] [anchor_mode]
#
#   `anchor_mode` is a NEW, OPTIONAL 7th positional argument. The literal value `anchor`
#   maintains a `<events_path>.high_water` anchor for that one commit call — read,
#   validated, and (on success) advanced under the SAME lock the commit already takes.
#   Any other value, including absent (every existing 6-argument call site in the
#   codebase, including this file's own `commit_plain` helper below), commits exactly as
#   it does on the unbuilt tree today: no anchor file is read, created, or touched. This
#   is the proposal ADR-0006 part A fixes as the call shape; the builder implements this
#   signature, not a different one, because every assertion below that drives
#   `aib_event_commit` directly is positional against it.
#
#     bin/anchor <events_path> {status|reanchor [--accept-truncation]}
#
#   `status` reads the stream (read-only) and the anchor file and reports both values and
#   their relationship, mutating neither. `reanchor` rewrites the anchor to the stream's
#   current highest committed seq; WITHOUT `--accept-truncation` it must refuse and touch
#   nothing; WITH it, it takes the stream's own lock, writes one journal line naming the
#   operator (`$USER`) and the old/new anchor values, and never touches the stream file
#   itself. This file does not pin `status`'s or the journal line's exact text beyond
#   what individual assertions below name explicitly (a proposal, not yet a contract) —
#   it pins the file's existence, its argument handling, and its side effects.
#
#     AIB_BROKER_CAPACITY (unit env, default 12 if unset) and AIB_BROKER_MAX_CONNECTIONS
#     (unit env, ADR-0006's own flagged resolution — ask the maintainer to confirm this
#     variable before treating §16 below as settled) gate `bin/aib-broker-handler`
#     BEFORE any registry read: leases live at
#     `<AIB_EVENT_ROOT>/<project_uid>/attempts/<agent_uid>.<n>` (`<n>` the smallest free
#     index below the cap), `project_uid` derived SYNTACTICALLY from the
#     already-wire-validated `agent_uid` prefix (never a registry lookup — this is the
#     invariant that makes an over-capacity answer cheap; F15), counted and created under
#     `<AIB_EVENT_ROOT>/<project_uid>/attempts/attempts.lock`. Over capacity:
#     `end=error reason=over_capacity`, handler exit 2, no registry read, no PDP call, no
#     stream lock, no `attempt.decided` record. This is a per-PROJECT ceiling shared by
#     every agent in that project (ADR-0006 part B), not per-agent and not per-broker.
#
#   NOTE ON F11/F17's "admission deny record" pins: H6 (v2, this design) does not write
#   ANY decided record on an over-capacity answer — admission runs strictly before
#   authorize, so there is no verdict, no `effective_*` block, and therefore no
#   deny-record-shape hazard for F11 to name. This spec pins the equivalent protection
#   directly: "no new decided record exists after an over-capacity answer" (§12 below)
#   supersedes F17's "effective_* null on a folded deny record" pin, which does not apply
#   to this design. F10's "max_attempts absent at agent/team/project" pin likewise does
#   not apply: H6 never resolves a per-agent binding field at all (no
#   `_aib_resolve_binding_field` call for capacity), so there is no absent-field case.
#
#   Expected on the unbuilt tree: mostly FAIL. `aib_event_commit`'s 7th argument does not
#   exist yet (extra arguments are silently ignored by bash's positional-parameter
#   handling, so anchor-mode calls behave exactly like plain calls — no anchor file is
#   ever created, which is precisely what most anchor assertions below catch).
#   `bin/anchor` does not exist (command-not-found, exit 127). `bin/aib-broker-handler`
#   performs no capacity check at all, so every capacity assertion that expects
#   `over_capacity` fails, and some "should still work" assertions (e.g. stale leases not
#   blocking admission) trivially pass — noted inline where that happens.
set -uo pipefail

SRC_ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
# shellcheck source=lib/aibobnet.sh
. "$SRC_ROOT/lib/aibobnet.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-anchorcap.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
no(){ fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; }
skip(){ pass=$((pass+1)); printf 'ok   - (skipped: %s)\n' "$1"; }
eq(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2' want '$3')"; fi; }
has(){ if printf '%s\n' "$2" | grep -qF -- "$3"; then ok "$1"; else no "$1 (missing '$3')"; fi; }
hasnt(){ if printf '%s\n' "$2" | grep -qF -- "$3"; then no "$1 (unexpected '$3')"; else ok "$1"; fi; }

# =============================================================================
# Fixtures
# =============================================================================
FIXTURE_HOME="$WORK/home-acme"
FIXTURE_STANDUP="$FIXTURE_HOME/standup"
FIXTURE_WS="$FIXTURE_HOME/ws"
mkdir -p "$FIXTURE_WS" "$FIXTURE_STANDUP"
EVENT_ROOT="$WORK/event-root"
mkdir -p "$EVENT_ROOT/acme"
ln -s "$EVENT_ROOT/acme" "$FIXTURE_STANDUP/events"
EVENTS_FILE="$EVENT_ROOT/acme/main.events"
EVENTS_LOCK="$EVENT_ROOT/acme/main.events.lock"
ANCHOR_FILE="${EVENTS_FILE}.high_water"

ENVELOPE_KV="project_uid=acme
actor_type=service
actor_id=aib-broker
agent_uid=acme-core
team_uid=acme-engine
session_id=acme-broker"

seed_kv() {
  printf 'decision=allow\ncode=0\nreasons=\npid=%s\nprompt_len=1\nprompt_sha256=deadbeef' "$$"
}
# commit_plain — the EXISTING 6-argument call shape: no anchor_mode at all. Every
# assertion using this proves "unchanged behaviour when the caller does not opt in".
commit_plain() {
  local payload; payload="$(aib_event_compose_decided_payload "$(seed_kv)")"
  aib_event_commit "$EVENTS_FILE" "$EVENTS_LOCK" attempt.decided "$ENVELOPE_KV" "$payload"
}
# commit_anchored — the NEW 7th argument, literal `anchor`: the broker's own call shape.
commit_anchored() {
  local payload; payload="$(aib_event_compose_decided_payload "$(seed_kv)")"
  aib_event_commit "$EVENTS_FILE" "$EVENTS_LOCK" attempt.decided "$ENVELOPE_KV" "$payload" "" anchor
}

reset_stream() {
  rm -f "$EVENTS_FILE" "$EVENTS_LOCK" "$ANCHOR_FILE"
  rm -f "$WORK"/journal-* "$WORK"/commit-err-* 2>/dev/null || true
}

current_max_seq() {
  aib_event_scan "$EVENTS_FILE" >/dev/null
  printf '%s' "$AIB_EVENT_SCAN_HIGHEST_SEQ"
}

# A restricted PATH containing only symlinks to the tools aib_event_commit's anchor
# path might legitimately need, MINUS one named tool — simulates "this host's PATH does
# not offer a capable <tool>" without disturbing the real PATH for anything else in this
# process (only used inside a `PATH=... ( subshell )`, never exported globally).
build_path_without() { # build_path_without <hidden-tool> <dest-dir>
  local hide="$1" dir="$2" tool t
  mkdir -p "$dir"
  for tool in bash flock cksum truncate mkdir cat rm dirname mktemp sync grep sed \
              awk tr wc sha256sum env sleep realpath true false printf mv chmod; do
    [ "$tool" = "$hide" ] && continue
    t="$(command -v "$tool" 2>/dev/null)" || continue
    ln -sf "$t" "$dir/$tool" 2>/dev/null || true
  done
  printf '%s' "$dir"
}

# =============================================================================
# 1. A broker-mode (anchor_mode=anchor) commit advances the anchor to the new seq.
# =============================================================================
reset_stream
commit_anchored >/dev/null 2>"$WORK/err-1"
eq "an anchored commit succeeds on a fresh stream" "$?" 0
if [ -e "$ANCHOR_FILE" ]; then
  ok "the anchor file exists after the first anchored commit"
  eq "…and holds the new highest seq (1)" "$(cat "$ANCHOR_FILE" 2>/dev/null)" "1"
else
  no "the anchor file exists after the first anchored commit"
  no "…and holds the new highest seq (1) (file missing)"
fi
commit_anchored >/dev/null 2>>"$WORK/err-1"
eq "a second anchored commit advances the anchor again" "$(cat "$ANCHOR_FILE" 2>/dev/null)" "2"

# =============================================================================
# 2. a > m: refuse the append, leave the stream untouched.
# =============================================================================
reset_stream
commit_anchored >/dev/null 2>/dev/null   # seq 1, anchor=1
printf '99' > "$ANCHOR_FILE"             # simulate truncation/replacement: anchor ahead of the stream
before_bytes="$(wc -c < "$EVENTS_FILE")"
( commit_anchored ) >"$WORK/out-2" 2>"$WORK/err-2"
rc2=$?
eq "a > m refuses the append (nonzero exit)" "$([ "$rc2" -ne 0 ] && printf refused || printf accepted)" refused
eq "…the stream is byte-for-byte untouched" "$(wc -c < "$EVENTS_FILE")" "$before_bytes"
eq "…the anchor file is untouched too" "$(cat "$ANCHOR_FILE")" "99"

# =============================================================================
# 3. a < m: advance to m, journal the lag, proceed with the append.
# =============================================================================
reset_stream
commit_anchored >/dev/null 2>/dev/null   # seq 1
commit_anchored >/dev/null 2>/dev/null   # seq 2, anchor=2
printf '1' > "$ANCHOR_FILE"              # simulate: crash after append, before anchor write, on a PRIOR commit
commit_anchored >"$WORK/out-3" 2>"$WORK/err-3"
rc3=$?
eq "a < m still succeeds (advances, does not refuse)" "$rc3" 0
eq "…the anchor advances to the new highest seq (3)" "$(cat "$ANCHOR_FILE")" "3"
if grep -qi 'lag\|anchor' "$WORK/err-3" 2>/dev/null; then
  ok "…a lag/anchor line is journaled to stderr, naming the discrepancy"
else
  no "…a lag/anchor line is journaled to stderr, naming the discrepancy"
fi
lag_in_stream="$(aib_event_scan "$EVENTS_FILE" | grep -c 'lag' || true)"
eq "…the lag record itself never enters the event stream (CONTRACT-mediation §5.1: not the object under examination)" "${lag_in_stream:-0}" "0"

# =============================================================================
# 4. Absent anchor -> create at m, log once as a migration; a pre-slice-5 stream
#    (committed entirely via commit_plain, never anchored before) commits normally
#    the first time it is anchored.
# =============================================================================
reset_stream
commit_plain >/dev/null 2>/dev/null   # seq 1 — plain, exactly as every pre-slice-5 caller does today
commit_plain >/dev/null 2>/dev/null   # seq 2 — still plain
if [ -e "$ANCHOR_FILE" ]; then no "no anchor file exists yet — this stream predates anchoring"
else ok "no anchor file exists yet — this stream predates anchoring"; fi
commit_anchored >"$WORK/out-4" 2>"$WORK/err-4"
rc4=$?
eq "the first anchored commit against a pre-existing, never-anchored stream succeeds" "$rc4" 0
eq "…and creates the anchor at the CURRENT highest committed seq before this commit's own append (2), not the post-append seq" \
  "$(printf '%s' "${AIB_EVENT_SCAN_HIGHEST_SEQ:-unset}")" "2"
if grep -qi 'migrat\|no predecessor\|absent' "$WORK/err-4" 2>/dev/null; then
  ok "…the migration is logged once (CONTRACT-mediation §7 'no predecessor', restated per-stream)"
else
  no "…the migration is logged once (CONTRACT-mediation §7 'no predecessor', restated per-stream)"
fi
eq "…the anchor now reflects the post-commit highest seq (3)" "$(cat "$ANCHOR_FILE" 2>/dev/null)" "3"

# =============================================================================
# 5. Corrupt/empty anchor: incident, refuse. (Safe only because of §7's temp-fsync
#    discipline — an empty durable anchor can only mean tampering or a bug, per ADR-0006.)
# =============================================================================
reset_stream
commit_anchored >/dev/null 2>/dev/null
: > "$ANCHOR_FILE"   # empty — the "torn write" shape that must never legitimately occur
before_bytes5="$(wc -c < "$EVENTS_FILE")"
( commit_anchored ) >"$WORK/out-5a" 2>"$WORK/err-5a"
rc5a=$?
eq "an empty anchor refuses the append (incident, not a benign reset)" "$([ "$rc5a" -ne 0 ] && printf refused || printf accepted)" refused
eq "…the stream stays untouched" "$(wc -c < "$EVENTS_FILE")" "$before_bytes5"

printf 'not-a-number' > "$ANCHOR_FILE"
( commit_anchored ) >"$WORK/out-5b" 2>"$WORK/err-5b"
rc5b=$?
eq "a non-integer anchor also refuses (incident)" "$([ "$rc5b" -ne 0 ] && printf refused || printf accepted)" refused

# =============================================================================
# 6. Torn tail never advances the anchor. The scan already excludes an uncommitted
#    (unterminated) final record from HIGHEST_SEQ, and the anchor check runs AFTER the
#    torn-tail truncate (§5.1's ordering) — so a torn record past the anchor must never
#    read as a > m.
# =============================================================================
reset_stream
commit_anchored >/dev/null 2>/dev/null   # seq 1, anchor=1
commit_anchored >/dev/null 2>/dev/null   # seq 2, anchor=2
# Hand-craft an uncommitted (no trailing LF) record at seq 3, simulating a crash mid-append
# BEFORE this file's own fsync/anchor-advance ever ran — the anchor must still read 2.
printf '3 1 1 {}' >> "$EVENTS_FILE"   # deliberately malformed/unterminated; no LF
eq "the anchor was never touched by the crash that left the torn tail" "$(cat "$ANCHOR_FILE")" "2"
commit_anchored >"$WORK/out-6" 2>"$WORK/err-6"
rc6=$?
eq "the next anchored commit succeeds (truncates the torn tail first, THEN checks the anchor)" "$rc6" 0
eq "…it reuses seq 3 (the torn record was never real)" "$(printf '%s' "$AIB_EVENT_COMMIT_SEQ")" "3"
eq "…and the anchor advances cleanly to 3, never having seen a false a>m from the torn tail" \
  "$(cat "$ANCHOR_FILE")" "3"

# =============================================================================
# 7. Atomicity: the anchor is written via a temp file in the same directory, fully
#    fsynced, then renamed — a crash between temp-write and rename must never leave a
#    torn/partial value observable AS the anchor, and a stray temp file left behind by
#    such a crash must never be misread as the live anchor by `bin/anchor status` or by
#    a subsequent commit. Proposal (ADR-0006 part A): the temp name is
#    `<events_path>.high_water.XXXXXX` (mktemp-style, same directory) — the builder may
#    choose a different exact pattern, but it MUST be distinguishable from the final
#    name by every reader, which is what the assertions below actually pin.
# =============================================================================
reset_stream
commit_anchored >/dev/null 2>/dev/null   # anchor=1
# Simulate a crash between temp-write and rename: drop a stray temp candidate carrying a
# clearly-wrong value, alongside the real, still-correct anchor.
printf '999999' > "${ANCHOR_FILE}.XXXXXX.stray-simulated-crash"
eq "the real anchor is unaffected by a stray temp file next to it" "$(cat "$ANCHOR_FILE")" "1"
( commit_anchored ) >"$WORK/out-7" 2>"$WORK/err-7"
eq "a subsequent commit still succeeds — the stray temp is never read as the live anchor" "$?" 0
eq "…and the anchor reflects the real commit history (2), never the stray value (999999)" \
  "$(cat "$ANCHOR_FILE")" "2"
if [ -x "$SRC_ROOT/bin/anchor" ]; then
  status_out="$("$SRC_ROOT/bin/anchor" "$EVENTS_FILE" status 2>"$WORK/anchor-status-err-7")"
  hasnt "bin/anchor status never reports the stray temp's value" "$status_out" "999999"
else
  no "bin/anchor status never reports the stray temp's value (bin/anchor does not exist yet)"
fi

# =============================================================================
# 8. Missing `sync` capability fails closed at commit entry — never a bare-`sync`
#    fallback. Two sub-cases: sync entirely absent from PATH, and a `sync` present but
#    incapable of file arguments (simulating a pre-8.24 or non-GNU sync).
# =============================================================================
reset_stream
NO_SYNC_PATH="$(build_path_without sync "$WORK/path-no-sync")"
( PATH="$NO_SYNC_PATH" commit_anchored ) >"$WORK/out-8a" 2>"$WORK/err-8a"
rc8a=$?
eq "sync entirely absent from PATH fails closed (nonzero)" "$([ "$rc8a" -ne 0 ] && printf refused || printf accepted)" refused
if grep -qi 'sync' "$WORK/err-8a" 2>/dev/null; then
  ok "…and the message names sync as the missing dependency (aib_die 6 style)"
else
  no "…and the message names sync as the missing dependency (aib_die 6 style)"
fi

# A `sync` that answers success for NO arguments (the bare/flush-everything shape) but
# fails when given a file argument (simulating a sync that CANNOT do what the anchor
# needs). The probe must recognise this as incapable and refuse — and, critically, must
# never itself fall back to calling the argument-less form.
BARE_SYNC_DIR="$WORK/path-bare-sync"
BARE_SYNC_MARKER="$WORK/bare-sync-was-called"
BARE_SYNC_BIN="$(build_path_without sync "$BARE_SYNC_DIR")"
cat > "$BARE_SYNC_DIR/sync" <<EOF
#!/usr/bin/env bash
if [ "\$#" -eq 0 ]; then printf called >> "$BARE_SYNC_MARKER"; exit 0; fi
exit 1
EOF
chmod +x "$BARE_SYNC_DIR/sync"
reset_stream
( PATH="$BARE_SYNC_BIN" commit_anchored ) >"$WORK/out-8b" 2>"$WORK/err-8b"
rc8b=$?
eq "an incapable (file-argument-rejecting) sync fails closed too" "$([ "$rc8b" -ne 0 ] && printf refused || printf accepted)" refused
if [ -e "$BARE_SYNC_MARKER" ]; then
  no "…and it NEVER silently falls back to the argument-less form (marker exists — it was called)"
else
  ok "…and it NEVER silently falls back to the argument-less form"
fi

# =============================================================================
# 9. Wrapper opt-in: `commit_plain` (no 7th argument — every existing wrapper call
#    site's shape today) writes NO anchor file, ever; only the literal `anchor` 7th
#    argument does. This is the library-level half of AIBOBNET_EVENT_ANCHOR=1 — the
#    wrapper's own env-to-argument translation lives in bin/launch-agent, out of this
#    file's scope (docs-only for that binary this slice; CONTRACT-execution-binding.md
#    §8.8 documents the intended translation).
# =============================================================================
reset_stream
commit_plain >/dev/null 2>/dev/null
commit_plain >/dev/null 2>/dev/null
if [ -e "$ANCHOR_FILE" ]; then no "repeated plain (non-opted-in) commits never create an anchor file"
else ok "repeated plain (non-opted-in) commits never create an anchor file"; fi
commit_anchored >/dev/null 2>/dev/null
if [ -e "$ANCHOR_FILE" ]; then ok "…but the very next opted-in (anchor) commit creates one immediately"
else no "…but the very next opted-in (anchor) commit creates one immediately"; fi

# =============================================================================
# 10. `bin/anchor status` — reports the anchor and the stream's own highest seq without
#     mutating either.
# =============================================================================
reset_stream
commit_anchored >/dev/null 2>/dev/null
commit_anchored >/dev/null 2>/dev/null
if [ -x "$SRC_ROOT/bin/anchor" ]; then
  before_anchor="$(cat "$ANCHOR_FILE")"; before_stream_bytes="$(wc -c < "$EVENTS_FILE")"
  status_out="$("$SRC_ROOT/bin/anchor" "$EVENTS_FILE" status 2>"$WORK/anchor-status-err-10")"
  has "status reports the anchor value" "$status_out" "2"
  has "status reports the stream's highest seq" "$status_out" "2"
  eq "status does not mutate the anchor" "$(cat "$ANCHOR_FILE")" "$before_anchor"
  eq "status does not mutate the stream" "$(wc -c < "$EVENTS_FILE")" "$before_stream_bytes"
else
  no "status reports the anchor value (bin/anchor does not exist yet)"
  no "status reports the stream's highest seq (bin/anchor does not exist yet)"
  no "status does not mutate the anchor (bin/anchor does not exist yet)"
  no "status does not mutate the stream (bin/anchor does not exist yet)"
fi

# =============================================================================
# 11. `bin/anchor reanchor` refuses without --accept-truncation; with it, rewrites the
#     anchor to the stream's current highest seq, journals the operator, and never
#     touches the stream.
# =============================================================================
reset_stream
commit_anchored >/dev/null 2>/dev/null   # anchor=1
printf '99' > "$ANCHOR_FILE"             # a truncation/replacement an operator now wants to accept
if [ -x "$SRC_ROOT/bin/anchor" ]; then
  before_stream11="$(wc -c < "$EVENTS_FILE")"
  "$SRC_ROOT/bin/anchor" "$EVENTS_FILE" reanchor >"$WORK/out-11a" 2>"$WORK/err-11a"
  rc11a=$?
  eq "reanchor without --accept-truncation refuses (nonzero)" "$([ "$rc11a" -ne 0 ] && printf refused || printf accepted)" refused
  eq "…and leaves the anchor exactly as it was (99)" "$(cat "$ANCHOR_FILE")" "99"

  "$SRC_ROOT/bin/anchor" "$EVENTS_FILE" reanchor --accept-truncation >"$WORK/out-11b" 2>"$WORK/err-11b"
  rc11b=$?
  eq "reanchor --accept-truncation succeeds" "$rc11b" 0
  eq "…and rewrites the anchor to the stream's current highest seq (1)" "$(cat "$ANCHOR_FILE" 2>/dev/null)" "1"
  eq "…the stream itself is untouched by reanchor (byte-identical)" "$(wc -c < "$EVENTS_FILE")" "$before_stream11"
  if [ -n "${USER:-}" ] && grep -qF "$USER" "$WORK/err-11b" 2>/dev/null; then
    ok "…and the journal line names the operator (\$USER)"
  else
    no "…and the journal line names the operator (\$USER)"
  fi
  commit_anchored >"$WORK/out-11c" 2>"$WORK/err-11c"
  eq "a repaired stream accepts an anchored commit again afterwards" "$?" 0
else
  no "reanchor without --accept-truncation refuses (bin/anchor does not exist yet)"
  no "…and leaves the anchor exactly as it was (bin/anchor does not exist yet)"
  no "reanchor --accept-truncation succeeds (bin/anchor does not exist yet)"
  no "…and rewrites the anchor to the stream's current highest seq (bin/anchor does not exist yet)"
  no "…the stream itself is untouched by reanchor (bin/anchor does not exist yet)"
  no "…and the journal line names the operator (bin/anchor does not exist yet)"
  no "a repaired stream accepts an anchored commit again afterwards (bin/anchor does not exist yet)"
fi

# =============================================================================
# 11b. F6's own worked example: a stream anchored by the WRAPPER's own opt-in path is
#      refused after an external truncation of the STREAM (not the anchor), and the
#      documented repair restores it. This is the scenario ADR-0006 says "is most likely
#      to be written last and tested never" — pinned here so it cannot be.
# =============================================================================
reset_stream
commit_anchored >/dev/null 2>/dev/null   # seq 1, anchor=1
commit_anchored >/dev/null 2>/dev/null   # seq 2, anchor=2
commit_anchored >/dev/null 2>/dev/null   # seq 3, anchor=3
: > "$EVENTS_FILE"   # external truncation of the STREAM itself (e.g. a `git clean` on standup/)
( commit_anchored ) >"$WORK/out-11d" 2>"$WORK/err-11d"
rc11d=$?
eq "a launch against a truncated stream fails closed (anchor > new max)" \
  "$([ "$rc11d" -ne 0 ] && printf refused || printf accepted)" refused
if [ -x "$SRC_ROOT/bin/anchor" ]; then
  "$SRC_ROOT/bin/anchor" "$EVENTS_FILE" reanchor --accept-truncation >/dev/null 2>"$WORK/err-11e"
  commit_anchored >"$WORK/out-11f" 2>"$WORK/err-11f"
  eq "…and the documented repair (reanchor --accept-truncation) restores service" "$?" 0
else
  no "…and the documented repair (reanchor --accept-truncation) restores service (bin/anchor does not exist yet)"
fi

# =============================================================================
# Capacity fixtures — driven through the real bin/aib-broker-handler, black-box, the
# same idiom tests/broker_enact_spec.sh §8/§9 already use for deny/allow.
# =============================================================================
STUB_BIN="$WORK/stub-bin"
mkdir -p "$STUB_BIN"
ADAPTER="$STUB_BIN/codex"
LANDLOCK_STUB="$STUB_BIN/landlock-exec"
SENTINEL="$WORK/provider-called"

cat > "$LANDLOCK_STUB" <<'STUB'
#!/usr/bin/env bash
if [ -n "${LL_STATUS_FD-}" ]; then eval "exec ${LL_STATUS_FD}>&-"; fi
exec "$@"
STUB
chmod +x "$LANDLOCK_STUB"

cat > "$ADAPTER" <<STUB
#!/usr/bin/env bash
printf 'called\n' >> "$SENTINEL"
exec python3 -c 'import os
fds = []
for entry in os.listdir("/proc/self/fd"):
    try: os.fstat(int(entry))
    except OSError: continue
    fds.append(int(entry))
print("PROVIDER_FDS=" + " ".join(map(str, sorted(fds))))'
STUB
chmod +x "$ADAPTER"

FIXTURE_REG="$WORK/registry.json"
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
  "teams": { "acme-engine": { "project": "acme", "model": "team/model-v2" } },
  "agents": {
    "acme-core": {
      "project": "acme", "team_uid": "acme-engine", "profile": "engine-dev",
      "clearance": "t2", "effort": "high"
    }
  }
}
JSON

UNREADABLE_REG="$WORK/registry-unreadable.json"
cp "$FIXTURE_REG" "$UNREADABLE_REG"
chmod 000 "$UNREADABLE_REG"

frame() { # frame <cwd> <label> <prompt> <record-line>...
  local c="$1" l="$2" p="$3"; shift 3; local r
  for r in "$@"; do printf '%s\n' "$r"; done
  printf 'cwd_bytes=%s\nlabel_bytes=%s\nprompt_bytes=%s\n\n' \
    "$(printf '%s' "$c" | wc -c)" "$(printf '%s' "$l" | wc -c)" "$(printf '%s' "$p" | wc -c)"
  printf '%s%s%s' "$c" "$l" "$p"
}

ATTEMPTS_DIR="$EVENT_ROOT/acme/attempts"

reset_capacity() {
  rm -rf "$ATTEMPTS_DIR" "$EVENTS_FILE" "$EVENTS_LOCK" "$ANCHOR_FILE"
  mkdir -p "$ATTEMPTS_DIR"
  rm -f "$SENTINEL"
}

# hold_lease <agent_uid> <index> -> prints the holder's pid; the caller is responsible
# for `kill` at the end of its section. Blocks (with a bounded retry) until the lock is
# actually observed held, so the capacity section below never races its own fixture.
hold_lease() {
  local agent="$1" n="$2"
  local f="$ATTEMPTS_DIR/${agent}.${n}"
  # stdout/stderr explicitly redirected: an unredirected background job inside a
  # $( ) capture would keep that pipe open (bash waits for EOF from every writer,
  # not just the immediate command), silently blocking the caller for the full
  # sleep duration.
  ( exec 9>>"$f"; flock 9; sleep 60 ) </dev/null >/dev/null 2>&1 &
  local holder=$!
  local i=0
  while [ "$i" -lt 50 ]; do
    if ! ( exec 8>>"$f"; flock -n 8 ) 2>/dev/null; then
      break   # could not take the lock -> the holder above genuinely holds it
    fi
    sleep 0.05
    i=$((i+1))
  done
  printf '%s' "$holder"
}

# release_lease <pid> — SIGKILL and a bounded poll, never `wait`: the holder is a
# grandchild of this shell (backgrounded from inside a $( ) subshell that has since
# exited), not a direct job of it, and `wait <non-child-pid>` is not reliable across
# bash builds — some poll indefinitely instead of returning promptly.
release_lease() {
  local pid="$1" i=0
  kill -KILL "$pid" 2>/dev/null || true
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 100 ]; do
    sleep 0.05
    i=$((i+1))
  done
}

# =============================================================================
# 12. N leases held (N == AIB_BROKER_CAPACITY) -> the next connection answers
#     over_capacity, touching neither the registry (pointed unreadable) nor the stream
#     (no new attempt.decided record).
# =============================================================================
reset_capacity
holder12="$(hold_lease acme-core 1)"
before_seq12="$(current_max_seq)"
resp12="$(frame "$FIXTURE_WS" "cap-test" "hallo" "op=launch" "agent_uid=acme-core" \
  | AIBOBNET_REGISTRY="$UNREADABLE_REG" AIB_CONFINE_BIN="$LANDLOCK_STUB" AIB_EVENT_ROOT="$EVENT_ROOT" \
    AIB_BROKER_CAPACITY=1 "$SRC_ROOT/bin/aib-broker-handler" 2>"$WORK/handler-err-12")"
has "1 lease held, capacity 1: the next launch answers over_capacity" "$resp12" "reason=over_capacity"
has "…and the frame still ends with end=error" "$resp12" "end=error"
hasnt "…never reason=registry_unavailable (the unreadable registry was never opened)" "$resp12" "registry_unavailable"
if [ -e "$SENTINEL" ]; then no "…the provider is never touched"; else ok "…the provider is never touched"; fi
eq "…no new attempt.decided record was written (stream highest seq unchanged)" \
  "$(current_max_seq)" "$before_seq12"
release_lease "$holder12"

# =============================================================================
# 13. A lease held by a SIGKILLed handler is released — the kernel drops the flock the
#     instant its last fd closes, admitting the next attempt.
# =============================================================================
reset_capacity
holder13="$(hold_lease acme-core 1)"
release_lease "$holder13"
resp13="$(frame "$FIXTURE_WS" "cap-test" "hallo" "op=launch" "agent_uid=acme-core" \
  | AIBOBNET_REGISTRY="$FIXTURE_REG" AIB_CONFINE_BIN="$LANDLOCK_STUB" AIB_EVENT_ROOT="$EVENT_ROOT" \
    AIB_BROKER_CAPACITY=1 "$SRC_ROOT/bin/aib-broker-handler" 2>"$WORK/handler-err-13")"
hasnt "a SIGKILLed holder's slot is released — the next attempt is admitted, not refused" "$resp13" "over_capacity"

# =============================================================================
# 14. A stale (unlocked, no live holder) lease file is ignored for the count and
#     removed, never treated as an occupied slot.
# =============================================================================
reset_capacity
: > "$ATTEMPTS_DIR/acme-core.1"   # a plain file: nobody holds its flock — a crash-left stale name
resp14="$(frame "$FIXTURE_WS" "cap-test" "hallo" "op=launch" "agent_uid=acme-core" \
  | AIBOBNET_REGISTRY="$FIXTURE_REG" AIB_CONFINE_BIN="$LANDLOCK_STUB" AIB_EVENT_ROOT="$EVENT_ROOT" \
    AIB_BROKER_CAPACITY=1 "$SRC_ROOT/bin/aib-broker-handler" 2>"$WORK/handler-err-14")"
hasnt "a stale unlocked lease file does not count against capacity" "$resp14" "over_capacity"
if [ -e "$ATTEMPTS_DIR/acme-core.1" ]; then
  no "…and the stale file is removed as part of the same admission pass"
else
  ok "…and the stale file is removed as part of the same admission pass"
fi

# =============================================================================
# 15. The lease fd is not visible inside the confined provider (direct /proc listing,
#     no command substitution). NOTE: on the unbuilt tree this already "passes" — no
#     lease fd exists yet to leak, since capacity is not implemented at all. It is
#     pinned so it STAYS true once leases exist: the existing pre-exec fd-hygiene loop
#     in _aib_enact_exec_child_confined (lib/aibobnet.sh) already closes every
#     descriptor except 0/1/2/9 before exec — a lease fd opened on any OTHER number is
#     covered by that loop with no change to it required (ADR-0006 part B; consult F7c).
# =============================================================================
reset_capacity
resp15="$(frame "$FIXTURE_WS" "cap-test" "hallo" "op=launch" "agent_uid=acme-core" \
  | AIBOBNET_REGISTRY="$FIXTURE_REG" AIB_CONFINE_BIN="$LANDLOCK_STUB" AIB_EVENT_ROOT="$EVENT_ROOT" \
    AIB_BROKER_CAPACITY=4 "$SRC_ROOT/bin/aib-broker-handler" 2>"$WORK/handler-err-15")"
if command -v python3 >/dev/null 2>&1; then
  eq "an admitted (under-capacity) launch's provider sees only 0/1/2 — no lease fd, whatever number it lands on" \
    "$(grep '^PROVIDER_FDS=' <<<"$resp15")" 'PROVIDER_FDS=0 1 2'
else
  skip "provider fd probe requires python3 (docs/CONFINEMENT.md notes this is the one optional runtime dependency; absent here)"
fi

# =============================================================================
# 16. AIB_BROKER_CAPACITY unset -> default 12 (bracketed from both sides); a configured
#     value >= AIB_BROKER_MAX_CONNECTIONS is refused at handler START with a journal
#     line, before the wire is even read.
# =============================================================================
reset_capacity
holders16a=()
for i in 1 2 3 4 5 6 7 8 9 10 11; do holders16a+=("$(hold_lease acme-core "$i")"); done
resp16a="$(frame "$FIXTURE_WS" "cap-test" "hallo" "op=launch" "agent_uid=acme-core" \
  | AIBOBNET_REGISTRY="$FIXTURE_REG" AIB_CONFINE_BIN="$LANDLOCK_STUB" AIB_EVENT_ROOT="$EVENT_ROOT" \
    "$SRC_ROOT/bin/aib-broker-handler" 2>"$WORK/handler-err-16a")"
hasnt "11 held, AIB_BROKER_CAPACITY unset: still admitted (default > 11)" "$resp16a" "over_capacity"
for p in "${holders16a[@]}"; do release_lease "$p"; done
reset_capacity
holders16b=()
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do holders16b+=("$(hold_lease acme-core "$i")"); done
resp16b="$(frame "$FIXTURE_WS" "cap-test" "hallo" "op=launch" "agent_uid=acme-core" \
  | AIBOBNET_REGISTRY="$FIXTURE_REG" AIB_CONFINE_BIN="$LANDLOCK_STUB" AIB_EVENT_ROOT="$EVENT_ROOT" \
    "$SRC_ROOT/bin/aib-broker-handler" 2>"$WORK/handler-err-16b")"
has "12 held, AIB_BROKER_CAPACITY unset: refused (default == 12, not higher)" "$resp16b" "reason=over_capacity"
for p in "${holders16b[@]}"; do release_lease "$p"; done

reset_capacity
resp16c="$(frame "$FIXTURE_WS" "cap-test" "hallo" "op=launch" "agent_uid=acme-core" \
  | AIBOBNET_REGISTRY="$FIXTURE_REG" AIB_CONFINE_BIN="$LANDLOCK_STUB" AIB_EVENT_ROOT="$EVENT_ROOT" \
    AIB_BROKER_CAPACITY=16 AIB_BROKER_MAX_CONNECTIONS=16 "$SRC_ROOT/bin/aib-broker-handler" 2>"$WORK/handler-err-16c")"
if [ -e "$SENTINEL" ]; then no "AIB_BROKER_CAPACITY == AIB_BROKER_MAX_CONNECTIONS: the handler never serves ANY connection"
else ok "AIB_BROKER_CAPACITY == AIB_BROKER_MAX_CONNECTIONS: the handler never serves ANY connection"; fi
if grep -qi 'AIB_BROKER_CAPACITY\|MAX_CONNECTIONS' "$WORK/handler-err-16c" 2>/dev/null; then
  ok "…and a journal line names the misconfiguration at handler start"
else
  no "…and a journal line names the misconfiguration at handler start"
fi

reset_capacity
resp16d="$(frame "$FIXTURE_WS" "cap-test" "hallo" "op=launch" "agent_uid=acme-core" \
  | AIBOBNET_REGISTRY="$FIXTURE_REG" AIB_CONFINE_BIN="$LANDLOCK_STUB" AIB_EVENT_ROOT="$EVENT_ROOT" \
    AIB_BROKER_CAPACITY=20 AIB_BROKER_MAX_CONNECTIONS=16 "$SRC_ROOT/bin/aib-broker-handler" 2>"$WORK/handler-err-16d")"
if [ -e "$SENTINEL" ]; then no "AIB_BROKER_CAPACITY > AIB_BROKER_MAX_CONNECTIONS: also refused at start"
else ok "AIB_BROKER_CAPACITY > AIB_BROKER_MAX_CONNECTIONS: also refused at start"; fi

# =============================================================================
# 17. path-safety invariant this design depends on (consult F15): the project scope for
#     the lease directory comes from the agent_uid's OWN validated <project_uid>-<key>
#     shape, never from a value that could traverse out of <AIB_EVENT_ROOT>/<project>/
#     attempts/. Pinned directly against the existing validator so a later refactor that
#     accepts a project scope from elsewhere breaks this test, not silently.
# =============================================================================
( aib_validate_agent_uid "acme-../../etc" ) >/dev/null 2>&1
eq "a traversal-shaped agent_uid is already rejected by the existing validator (invariant this design relies on)" "$?" 4
( aib_validate_agent_uid "acme-core" ) >/dev/null 2>&1
eq "…while an ordinary agent_uid still validates" "$?" 0

printf '\nbroker_anchor_capacity_spec: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
