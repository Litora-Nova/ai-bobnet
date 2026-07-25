#!/usr/bin/env bash
# ai-bobnet — RM-2 Lane C: scanner-owned payload access + read-only attempt fold.
set -uo pipefail

SRC_ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
REPO_ROOT="$SRC_ROOT"
ATTEMPTS="$SRC_ROOT/bin/attempts"
# shellcheck source=lib/aibobnet.sh
. "$REPO_ROOT/lib/aibobnet.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-attempts.XXXXXX")"
STATE="$WORK/state"
STANDUP="$STATE/acme/standup"
REG="$WORK/registry.json"
mkdir -p "$STANDUP"
trap 'rm -rf "$WORK"' EXIT

cat > "$REG" <<EOF
{
  "schema_version": 4,
  "providers": {
    "codex": {
      "adapter": "/bin/true",
      "cap_sandbox": "workspace-write",
      "cap_tier": "t3",
      "cap_effort": "high"
    }
  },
  "projects": {
    "acme": {
      "home": "$STATE/acme",
      "standup_dir": "$STANDUP",
      "mux_session": "acme",
      "provider": "codex",
      "model": "project-model",
      "effort": "low"
    }
  },
  "agents": {
    "acme-core": {
      "project": "acme",
      "profile": "engine-dev",
      "clearance": "t2"
    }
  }
}
EOF

pass=0
fail=0
ok() { pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
no() { fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; }
eq() { [ "$2" = "$3" ] && ok "$1" || no "$1 (got '$2' want '$3')"; }
has() { case "$2" in *"$3"*) ok "$1";; *) no "$1 (missing '$3')";; esac; }
hasnt() { case "$2" in *"$3"*) no "$1 (unexpected '$3')";; *) ok "$1";; esac; }

# The additive frozen-A API owns nested payload parsing. Top-level and nested spoof
# keys must never override the canonical payload path.
helper_decided='{"decision":"top-spoof","pid":999,"payload":{"decision":"allow","pid":4242,"nested":{"decision":"deny","pid":7}}}'
helper_ended='{"class":"top-spoof","code":99,"payload":{"exit":{"class":"timeout","code":124},"other":{"class":"ok","code":0}}}'
helper_null='{"payload":{"exit":{"class":"ok","code":null}}}'
eq "payload accessor reads payload.decision, not a spoof" \
  "$(aib_event_payload_field "$helper_decided" decision 2>/dev/null)" "allow"
eq "payload accessor reads numeric payload.pid" \
  "$(aib_event_payload_field "$helper_decided" pid 2>/dev/null)" "4242"
eq "payload accessor reads payload.exit.class" \
  "$(aib_event_payload_field "$helper_ended" exit.class 2>/dev/null)" "timeout"
eq "payload accessor reads numeric payload.exit.code" \
  "$(aib_event_payload_field "$helper_ended" exit.code 2>/dev/null)" "124"
eq "payload accessor maps JSON null to empty" \
  "$(aib_event_payload_field "$helper_null" exit.code 2>/dev/null)" ""

aib_event_stream_paths "$STANDUP"
EVENTS="$AIB_EVENT_FILE"
LOCK="$AIB_EVENT_LOCK"
ENVELOPE=$'project_uid=acme\nactor_type=service\nactor_id=launch-agent\nagent_uid=acme-core'
LAST_ID=""

reset_stream() {
  rm -rf "$STANDUP/events"
  aib_event_stream_paths "$STANDUP"
  EVENTS="$AIB_EVENT_FILE"
  LOCK="$AIB_EVENT_LOCK"
}

commit_decided() {
  local decision="$1" code="$2" pid="$3" label="$4" kv payload
  kv="$(printf 'decision=%s\ncode=%s\nreasons=\nprovider_resolved=codex\nprovider_source=project:acme\nmodel_resolved=project-model\nmodel_source=project:acme\neffort_resolved=low\neffort_source=project:acme\nsandbox_requested=read-only\nadapter_raw=/bin/true\nadapter_source=provider:codex\npid=%s\nprompt_len=1\nprompt_sha256=00\nlabel=%s\nlabel_len=%s' \
    "$decision" "$code" "$pid" "$label" "${#label}")"
  if [ "$decision" = allow ]; then
    kv="${kv}"$'\n''provider_effective=codex
model_effective=project-model
effort_effective=low
sandbox_effective=read-only
adapter_effective=/bin/true'
  fi
  payload="$(aib_event_compose_decided_payload "$kv")"
  aib_event_commit "$EVENTS" "$LOCK" attempt.decided "$ENVELOPE" "$payload"
  LAST_ID="$AIB_EVENT_COMMIT_EVENT_ID"
}

commit_ended() {
  local decided_id="$1" exit_class="$2" exit_code="${3-}" signal="${4-}"
  local kv="exit_class=$exit_class" payload
  [ -z "$exit_code" ] || kv="${kv}"$'\n'"exit_code=$exit_code"
  [ -z "$signal" ] || kv="${kv}"$'\n'"signal=$signal"
  payload="$(aib_event_compose_ended_payload "$kv")"
  aib_event_commit "$EVENTS" "$LOCK" attempt.ended "$ENVELOPE" "$payload" "$decided_id"
}

RUN_OUT=""
RUN_ERR=""
RUN_RC=0
run_attempts() {
  RUN_OUT=""
  RUN_ERR=""
  RUN_RC=0
  RUN_OUT="$(AIBOBNET_REGISTRY="$REG" "$ATTEMPTS" acme-core 2>"$WORK/attempts.err")" || RUN_RC=$?
  RUN_ERR="$(cat "$WORK/attempts.err" 2>/dev/null)"
}

# Full state fold in one stream.
reset_stream
commit_decided allow 0 "$$" ok; ok_id="$LAST_ID"; commit_ended "$ok_id" ok
commit_decided deny 127 "$$" deny; deny_id="$LAST_ID"
commit_decided allow 0 "$$" timeout; timeout_id="$LAST_ID"; commit_ended "$timeout_id" timeout 124
commit_decided allow 0 "$$" io-refused; io_id="$LAST_ID"; commit_ended "$io_id" io-refused 127
commit_decided allow 0 "$$" aborted; aborted_id="$LAST_ID"; commit_ended "$aborted_id" aborted "" TERM
commit_decided allow 0 "$$" provider-failure; provider_id="$LAST_ID"; commit_ended "$provider_id" provider-failure 7
commit_decided allow 0 "$$" open; open_id="$LAST_ID"
commit_decided allow 0 99999999 presumed-dead; dead_id="$LAST_ID"
before_cksum="$(cksum "$EVENTS")"
run_attempts
after_cksum="$(cksum "$EVENTS")"

eq "attempts reader exists and is executable" "$([ -x "$ATTEMPTS" ] && printf yes || printf no)" yes
eq "attempts fold succeeds" "$RUN_RC" 0
has "ok stream reports intact integrity" "$RUN_OUT" "stream_status:ok | integrity:ok"
has "ended ok folds terminally" "$RUN_OUT" "attempt_id:$ok_id | state:ok | decision:allow"
has "single-record deny folds terminally" "$RUN_OUT" "attempt_id:$deny_id | state:deny | decision:deny"
has "timeout carries its exit code" "$RUN_OUT" "attempt_id:$timeout_id | state:timeout | decision:allow | pid:$$ | exit_code:124"
has "io-refused carries its exit code" "$RUN_OUT" "attempt_id:$io_id | state:io-refused | decision:allow | pid:$$ | exit_code:127"
has "aborted folds terminally" "$RUN_OUT" "attempt_id:$aborted_id | state:aborted | decision:allow"
has "provider failure carries its exit code" "$RUN_OUT" "attempt_id:$provider_id | state:provider-failure | decision:allow | pid:$$ | exit_code:7"
has "live allow without ended remains open" "$RUN_OUT" "attempt_id:$open_id | state:open | decision:allow"
has "missing PID is classified presumed-dead" "$RUN_OUT" "attempt_id:$dead_id | state:presumed-dead | decision:allow"
eq "reader never mutates the event stream" "$after_cksum" "$before_cksum"

# Critical corrupt gate: scanner may have emitted the first record, but the reader
# must inspect status before consuming it and therefore print no partial verdict.
reset_stream
commit_decided allow 0 "$$" partial; partial_id="$LAST_ID"
printf '2 0 2 {}\n' >> "$EVENTS"
run_attempts
eq "corrupt stream is refused fail-closed" "$RUN_RC" 2
eq "corrupt stream emits no partial fold" "$RUN_OUT" ""
has "corrupt refusal explains the stream status" "$RUN_ERR" "event stream is corrupt"
hasnt "corrupt refusal never leaks the valid prefix attempt" "$RUN_OUT" "$partial_id"

# A valid inner gap is degraded/lost, but its intact records remain foldable.
reset_stream
commit_decided allow 0 "$$" gap-one; gap_one_id="$LAST_ID"
commit_decided allow 0 "$$" removed; removed_id="$LAST_ID"
commit_decided allow 0 "$$" gap-three; gap_three_id="$LAST_ID"
sed -n '1p;3p' "$EVENTS" > "$WORK/gapped.events"
cat "$WORK/gapped.events" > "$EVENTS"
run_attempts
eq "degraded stream still folds" "$RUN_RC" 0
has "degraded stream is clearly marked lost" "$RUN_OUT" "stream_status:degraded | integrity:lost"
has "degraded fold keeps the first intact attempt" "$RUN_OUT" "attempt_id:$gap_one_id | state:open"
has "degraded fold keeps the later intact attempt" "$RUN_OUT" "attempt_id:$gap_three_id | state:open"
hasnt "degraded fold cannot invent the lost attempt" "$RUN_OUT" "attempt_id:$removed_id"

# Unterminated final bytes are reported as an uncommitted tail and never folded.
reset_stream
commit_decided allow 0 "$$" intact; intact_id="$LAST_ID"
printf '2 999 999 {"uncommitted":true' >> "$EVENTS"
run_attempts
eq "uncommitted tail does not block intact fold" "$RUN_RC" 0
has "uncommitted tail is reported clearly" "$RUN_OUT" "uncommitted_tail:1"
has "intact record before torn tail is folded" "$RUN_OUT" "attempt_id:$intact_id | state:open"
hasnt "unterminated bytes never enter the fold" "$RUN_OUT" '"uncommitted":true'

total=$((pass+fail))
printf '\n%d checks: %d ok / %d fail\n' "$total" "$pass" "$fail"
[ "$fail" -eq 0 ]
