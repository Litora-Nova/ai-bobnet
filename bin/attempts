#!/usr/bin/env bash
# ai-bobnet — RM-2 read-only attempt fold over the framed audit stream.
# Usage: attempts <agent_uid>
#
# The agent selects one already-managed project snapshot and therefore its canonical
# standup_dir. This command never acquires the writer lock and never mutates the stream.
set -euo pipefail

_src="${BASH_SOURCE[0]}"
while [ -h "$_src" ]; do
  _dir=$(cd -P "$(dirname "$_src")" >/dev/null 2>&1 && pwd)
  _src=$(readlink "$_src")
  case "$_src" in /*) ;; *) _src="$_dir/$_src";; esac
done
_dir=$(cd -P "$(dirname "$_src")" >/dev/null 2>&1 && pwd)
REPO_ROOT=$(cd -P "$_dir/.." >/dev/null 2>&1 && pwd)
# shellcheck source=lib/aibobnet.sh
. "$REPO_ROOT/lib/aibobnet.sh"

agent="${1:-}"
[ "$#" -eq 1 ] && [ -n "$agent" ] || aib_die 64 "usage: attempts <agent_uid>"

_mktemp_bin="$(command -v mktemp)" ||
  aib_die 6 "required runtime dependency not found: mktemp (coreutils)"

aib_resolve_managed_agent "$agent"
aib_event_stream_paths "$AIB_STANDUP_DIR"

scan_output="$("$_mktemp_bin" "${TMPDIR:-/tmp}/aibobnet-attempt-fold.XXXXXX")" ||
  aib_die 2 "cannot create attempt-fold scan buffer"
cleanup() { rm -f -- "$scan_output" 2>/dev/null || true; }
trap cleanup EXIT

# aib_event_scan intentionally emits intact prefix records while classifying the whole
# stream. Preserve its globals by calling it in this shell, but consume NOTHING until
# the status gate has accepted the complete scan.
set +e
aib_event_scan "$AIB_EVENT_FILE" > "$scan_output"
scan_rc=$?
set -e
[ "$scan_rc" -eq 0 ] || aib_die "$scan_rc" "event stream scan failed"
if [ "$AIB_EVENT_SCAN_STATUS" = corrupt ]; then
  aib_die 2 "event stream is corrupt (${AIB_EVENT_SCAN_CORRUPT_REASON}) — refusing partial attempt fold"
fi

declare -a attempt_order=()
declare -A attempt_decision=()
declare -A attempt_pid=()
declare -A attempt_state=()
declare -A attempt_exit_code=()
declare -A attempt_ended=()

while IFS=$'\t' read -r seq json; do
  [ -n "$seq" ] && [ -n "$json" ] ||
    aib_die 2 "scanner emitted an incomplete attempt record"
  event_type="$(aib_event_field "$json" event_type)"
  attempt_id="$(aib_event_field "$json" attempt_id)"
  case "$event_type" in
    attempt.decided)
      [ -n "$attempt_id" ] || aib_die 2 "attempt.decided has no attempt_id"
      [ -z "${attempt_state[$attempt_id]+x}" ] ||
        aib_die 2 "duplicate attempt.decided for '$attempt_id'"
      decision="$(aib_event_payload_field "$json" decision)"
      pid="$(aib_event_payload_field "$json" pid)"
      case "$decision" in allow|deny) ;; *) aib_die 2 "attempt '$attempt_id' has invalid decision '$decision'";; esac
      case "$pid" in ''|*[!0-9]*) aib_die 2 "attempt '$attempt_id' has invalid pid '$pid'";; esac
      [ "$pid" -gt 0 ] || aib_die 2 "attempt '$attempt_id' has non-positive pid '$pid'"
      attempt_order+=("$attempt_id")
      attempt_decision["$attempt_id"]="$decision"
      attempt_pid["$attempt_id"]="$pid"
      attempt_exit_code["$attempt_id"]="null"
      if [ "$decision" = deny ]; then
        attempt_state["$attempt_id"]="deny"
      else
        attempt_state["$attempt_id"]="open"
      fi
      ;;
    attempt.ended)
      [ -n "$attempt_id" ] || aib_die 2 "attempt.ended has no attempt_id"
      [ -n "${attempt_state[$attempt_id]+x}" ] ||
        aib_die 2 "attempt.ended references unknown attempt '$attempt_id'"
      [ "${attempt_decision[$attempt_id]}" = allow ] ||
        aib_die 2 "denied attempt '$attempt_id' carries an impossible ended record"
      [ -z "${attempt_ended[$attempt_id]+x}" ] ||
        aib_die 2 "duplicate attempt.ended for '$attempt_id'"
      exit_class="$(aib_event_payload_field "$json" exit.class)"
      exit_code="$(aib_event_payload_field "$json" exit.code)"
      case "$exit_class" in
        ok|provider-failure|timeout|io-refused|aborted) ;;
        *) aib_die 2 "attempt '$attempt_id' has invalid exit class '$exit_class'";;
      esac
      case "$exit_code" in
        '') ;;
        *[!0-9]*) aib_die 2 "attempt '$attempt_id' has invalid exit code '$exit_code'";;
      esac
      case "$exit_class" in
        provider-failure|timeout|io-refused)
          case "$exit_code" in ''|*[!0-9]*)
            aib_die 2 "attempt '$attempt_id' exit '$exit_class' requires a numeric code";;
          esac
          ;;
      esac
      attempt_state["$attempt_id"]="$exit_class"
      attempt_exit_code["$attempt_id"]="${exit_code:-null}"
      attempt_ended["$attempt_id"]=1
      ;;
    *)
      ;;
  esac
done < "$scan_output"

# Reader-side display classification only. kill -0 is deliberately a liveness hint,
# not terminal truth: PID reuse can make a dead attempt look open. No recovery writer
# exists here and no event is ever appended.
for attempt_id in "${attempt_order[@]}"; do
  if [ "${attempt_state[$attempt_id]}" = open ]; then
    if ! kill -0 "${attempt_pid[$attempt_id]}" 2>/dev/null; then
      attempt_state["$attempt_id"]="presumed-dead"
    fi
  fi
done

if [ "$AIB_EVENT_SCAN_STATUS" = degraded ]; then
  integrity=lost
else
  integrity=ok
fi
printf 'stream_status:%s | integrity:%s | highest_seq:%s | next_seq:%s | uncommitted_tail:%s\n' \
  "$AIB_EVENT_SCAN_STATUS" "$integrity" "$AIB_EVENT_SCAN_HIGHEST_SEQ" \
  "$AIB_EVENT_SCAN_NEXT_SEQ" "$AIB_EVENT_SCAN_TORN_TAIL"
for attempt_id in "${attempt_order[@]}"; do
  printf 'attempt_id:%s | state:%s | decision:%s | pid:%s | exit_code:%s\n' \
    "$attempt_id" "${attempt_state[$attempt_id]}" "${attempt_decision[$attempt_id]}" \
    "${attempt_pid[$attempt_id]}" "${attempt_exit_code[$attempt_id]}"
done
