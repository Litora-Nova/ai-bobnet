#!/usr/bin/env bash
# ai-bobnet — RM-2 Lane A: the framed-event primitive.
#
# Direct, fail-closed coverage for the audit-grade JSON encoder, the %N guard, the
# frozen decided/ended payload composers, the top-level field extractor, the read-only
# frame scanner/validator, and aib_event_commit (the serialising append broker with
# in-lock seq allocation, in-lock identity composition, uncommitted-tail truncation,
# corrupt-stream fail-closed, and at-most-one attempt.ended). Every case that trips
# aib_die runs in a disposable subshell because aib_die intentionally exits.
set -uo pipefail

SRC_ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
REPO_ROOT="$SRC_ROOT"
# shellcheck source=lib/aibobnet.sh
. "$REPO_ROOT/lib/aibobnet.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-event-commit.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
no() { fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; }
assert_streq()   { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2' want '$3')"; fi; }
assert_neq()     { if [ "$2" != "$3" ]; then ok "$1"; else no "$1 (got '$2' == '$3')"; fi; }
assert_nonzero() { if [ "$2" -ne 0 ]; then ok "$1"; else no "$1 (got rc 0)"; fi; }
assert_zero()    { if [ "$2" -eq 0 ]; then ok "$1"; else no "$1 (got rc $2)"; fi; }
assert_contains(){ case "$2" in *"$3"*) ok "$1";; *) no "$1 ('$2' has no '$3')";; esac; }
assert_missing() { case "$2" in *"$3"*) no "$1 ('$2' still has '$3')";; *) ok "$1";; esac; }

# json part of a framed record line -> stdout
frame_json() {
  local line="$1"
  [[ "$line" =~ ^[0-9]+\ [0-9]+\ [0-9]+\ (.*)$ ]] && printf '%s' "${BASH_REMATCH[1]}"
}
frame_seq() { local line="$1"; printf '%s' "${line%% *}"; }

# -----------------------------------------------------------------------------
# 1. audit-grade JSON encoder — every control byte encoded, never passed raw
# -----------------------------------------------------------------------------
assert_streq 'aib_json escapes backslash' "$(aib_json 'a\b')" '"a\\b"'
assert_streq 'aib_json escapes quote'     "$(aib_json 'a"b')" '"a\"b"'
assert_streq 'aib_json encodes newline'   "$(aib_json "$(printf 'a\nb')")" '"a\nb"'
assert_streq 'aib_json encodes tab'       "$(aib_json "$(printf 'a\tb')")" '"a\tb"'
assert_streq 'aib_json encodes CR'        "$(aib_json "$(printf 'a\rb')")" '"a\rb"'
# a raw U+0001 must become \u0001, never appear raw in the output
enc_ctrl="$(aib_json "$(printf 'x\001y')")"
assert_streq 'aib_json encodes U+0001 as backslash-u-0001' "$enc_ctrl" '"x\u0001y"'
case "$enc_ctrl" in *$'\001'*) no 'aib_json leaks a raw control byte';; *) ok 'aib_json leaks no raw control byte';; esac
assert_streq 'aib_json passes UTF-8 through' "$(aib_json 'grüße-λ')" '"grüße-λ"'

# -----------------------------------------------------------------------------
# 2. %N guard (display-only occurred_at; identity never depends on the clock)
# -----------------------------------------------------------------------------
assert_streq 'guard accepts real nanoseconds' "$(_aib_guard_ns 123456789)" '123456789'
( _aib_guard_ns N ) >/dev/null 2>&1; assert_nonzero 'guard rejects literal N fail-closed' "$?"
( _aib_guard_ns '' ) >/dev/null 2>&1; assert_nonzero 'guard rejects empty fraction' "$?"
now="$(aib_event_now)"
case "$now" in
  20*T*Z) ok 'aib_event_now looks like ISO-8601 UTC';;
  *) no "aib_event_now shape '$now'";;
esac
assert_missing 'aib_event_now has no literal N' "$now" 'N'

# -----------------------------------------------------------------------------
# 3. decided payload composer — shape + null/empty semantics
# -----------------------------------------------------------------------------
# ALLOW: effective values present, resolved present
allow_kv=$'decision=allow\ncode=0\nreasons=\nprovider_resolved=codex\nprovider_source=agent:acme-worker\nprovider_effective=codex\nmodel_resolved=gpt-5\nmodel_source=team:acme-core\nmodel_effective=gpt-5\neffort_resolved=high\neffort_source=project:acme\neffort_effective=high\nsandbox_requested=workspace-write\nsandbox_effective=read-only\nadapter_raw=/abs/codex\nadapter_effective=/abs/codex\nadapter_source=provider:codex\npid=4242\nprompt_len=17\nprompt_sha256=deadbeef\nlabel=hello world\nlabel_len=11'
allow_pay="$(aib_event_compose_decided_payload "$allow_kv")"
assert_contains 'decided allow carries decision' "$allow_pay" '"decision":"allow"'
assert_contains 'decided allow effective effort present' "$allow_pay" '"effective":"high"'
assert_contains 'decided allow sandbox clamped' "$allow_pay" '"sandbox":{"requested":"workspace-write","effective":"read-only"}'
assert_contains 'decided allow adapter effective path present' "$allow_pay" '"effective_path":"/abs/codex"'
assert_contains 'decided allow label encoded' "$allow_pay" '"label":"hello world"'
assert_missing 'decided has no exit field' "$allow_pay" '"exit"'

# DENY: effective omitted by caller -> null, but resolved stays present (distinguishable)
deny_kv=$'decision=deny\ncode=127\nreasons=provider resolves no adapter\nprovider_resolved=ghost\nprovider_source=agent:acme-worker'
deny_pay="$(aib_event_compose_decided_payload "$deny_kv")"
assert_contains 'deny code 127' "$deny_pay" '"code":127'
assert_contains 'deny provider resolved present' "$deny_pay" '"resolved":"ghost"'
assert_contains 'deny provider effective is null' "$deny_pay" '"effective":null'
assert_contains 'deny adapter effective_path null' "$deny_pay" '"effective_path":null'

( aib_event_compose_decided_payload $'decision=maybe\ncode=0' ) >/dev/null 2>&1
assert_nonzero 'decided rejects unknown decision' "$?"
( aib_event_compose_decided_payload $'decision=allow\ncode=x' ) >/dev/null 2>&1
assert_nonzero 'decided rejects non-numeric code' "$?"

# -----------------------------------------------------------------------------
# 4. ended payload composer — closed exit enum, presumed-dead forbidden
# -----------------------------------------------------------------------------
ended_pay="$(aib_event_compose_ended_payload $'exit_class=provider-failure\nexit_code=7')"
assert_contains 'ended carries exit class' "$ended_pay" '"class":"provider-failure"'
assert_contains 'ended carries exit code' "$ended_pay" '"code":7'
assert_contains 'ended signal null when absent' "$ended_pay" '"signal":null'
ended_ok="$(aib_event_compose_ended_payload $'exit_class=ok')"
assert_contains 'ended ok code null when absent' "$ended_ok" '"code":null'
( aib_event_compose_ended_payload $'exit_class=presumed-dead' ) >/dev/null 2>&1
assert_nonzero 'ended rejects presumed-dead fail-closed' "$?"
( aib_event_compose_ended_payload $'exit_class=bogus' ) >/dev/null 2>&1
assert_nonzero 'ended rejects unknown exit class' "$?"

# -----------------------------------------------------------------------------
# 5. top-level field extractor ignores a nested spoof in payload
# -----------------------------------------------------------------------------
spoof='{"event_id":"acme-main-1","event_type":"attempt.ended","payload":{"attempt_id":"SPOOF","event_type":"attempt.decided"},"attempt_id":"acme-main-1"}'
assert_streq 'extractor reads top-level event_type' "$(aib_event_field "$spoof" event_type)" 'attempt.ended'
assert_streq 'extractor reads top-level attempt_id, not the nested spoof' "$(aib_event_field "$spoof" attempt_id)" 'acme-main-1'
assert_streq 'extractor reads top-level event_id' "$(aib_event_field "$spoof" event_id)" 'acme-main-1'

# -----------------------------------------------------------------------------
# 6. aib_event_commit — first decided: framing + in-lock identity composition
# -----------------------------------------------------------------------------
S1="$WORK/s1"; mkdir -p "$S1"
aib_event_stream_paths "$S1"
EV="$AIB_EVENT_FILE"; LK="$AIB_EVENT_LOCK"
env_dec=$'project_uid=acme\nactor_type=service\nactor_id=launch-agent\nagent_uid=acme-worker'
pay_dec="$(aib_event_compose_decided_payload "$allow_kv")"

aib_event_commit "$EV" "$LK" attempt.decided "$env_dec" "$pay_dec"
assert_streq 'first commit seq is 1' "$AIB_EVENT_COMMIT_SEQ" '1'
assert_streq 'first commit event_id derived from seq' "$AIB_EVENT_COMMIT_EVENT_ID" 'acme-main-1'
line1="$(sed -n '1p' "$EV")"
assert_streq 'framed prefix seq token is 1' "$(frame_seq "$line1")" '1'
json1="$(frame_json "$line1")"
# recompute crc/len over exactly the json bytes and compare to the frame prefix
read -r _s pcrc plen _rest <<<"$line1"
set -- $(printf '%s' "$json1" | cksum); rcrc="$1"; rlen="$2"
assert_streq 'frame crc matches json bytes' "$pcrc" "$rcrc"
assert_streq 'frame len matches json bytes' "$plen" "$rlen"
assert_streq 'decided attempt_id == event_id' "$(aib_event_field "$json1" attempt_id)" 'acme-main-1'
assert_streq 'decided correlation_id == event_id' "$(aib_event_field "$json1" correlation_id)" 'acme-main-1'
assert_streq 'decided causation_id == event_id' "$(aib_event_field "$json1" causation_id)" 'acme-main-1'
assert_streq 'envelope actor_id present' "$(aib_event_field "$json1" actor_id)" 'launch-agent'
assert_streq 'envelope schema_version present' "$(aib_event_field "$json1" event_type)" 'attempt.decided'

# second commit advances the seq under the lock
aib_event_commit "$EV" "$LK" attempt.decided "$env_dec" "$pay_dec"
assert_streq 'second commit seq is 2' "$AIB_EVENT_COMMIT_SEQ" '2'
assert_streq 'second commit event_id is acme-main-2' "$AIB_EVENT_COMMIT_EVENT_ID" 'acme-main-2'

# a caller MUST NOT pre-compose an identity field
( aib_event_commit "$EV" "$LK" attempt.decided $'project_uid=acme\nactor_type=service\nactor_id=x\nevent_id=forged-1' "$pay_dec" ) >/dev/null 2>&1
assert_nonzero 'commit rejects a pre-composed event_id in the envelope' "$?"
( aib_event_commit "$EV" "$LK" attempt.decided $'project_uid=acme\nactor_type=service\nactor_id=x\nattempt_id=forged' "$pay_dec" ) >/dev/null 2>&1
assert_nonzero 'commit rejects a pre-composed attempt_id in the envelope' "$?"

# -----------------------------------------------------------------------------
# 7. uncommitted tail: truncate in place, resume at the right seq
# -----------------------------------------------------------------------------
S2="$WORK/s2"; mkdir -p "$S2"
aib_event_stream_paths "$S2"
EV2="$AIB_EVENT_FILE"; LK2="$AIB_EVENT_LOCK"
aib_event_commit "$EV2" "$LK2" attempt.decided "$env_dec" "$pay_dec"   # seq 1 (terminated)
size_after_one=$(wc -c < "$EV2")
printf '2 999 999 {"torn":true' >> "$EV2"   # unterminated garbage tail (no LF)
aib_event_commit "$EV2" "$LK2" attempt.decided "$env_dec" "$pay_dec"   # must truncate then append seq 2
assert_streq 'writer resumes at seq 2 after truncating the torn tail' "$AIB_EVENT_COMMIT_SEQ" '2'
assert_missing 'the torn bytes are gone from the stream' "$(cat "$EV2")" '"torn":true'
nlines=$(wc -l < "$EV2")
assert_streq 'stream has exactly two committed records' "$nlines" '2'
# read-only scan agrees the stream is clean after recovery
aib_event_scan "$EV2" >/dev/null
assert_streq 'scan status ok after recovery' "$AIB_EVENT_SCAN_STATUS" 'ok'
assert_streq 'scan next_seq is 3' "$AIB_EVENT_SCAN_NEXT_SEQ" '3'

# -----------------------------------------------------------------------------
# 8. corrupt (terminated crc mismatch) — fail-closed for BOTH writer and fold
# -----------------------------------------------------------------------------
S3="$WORK/s3"; mkdir -p "$S3"
aib_event_stream_paths "$S3"
EV3="$AIB_EVENT_FILE"; LK3="$AIB_EVENT_LOCK"
aib_event_commit "$EV3" "$LK3" attempt.decided "$env_dec" "$pay_dec"   # seq 1
# a fully TERMINATED record whose crc is wrong
printf '2 111 999 {"corrupt":true}\n' >> "$EV3"
( aib_event_scan "$EV3" >/dev/null ) ; scan_rc=$?
aib_event_scan "$EV3" >/dev/null 2>&1 || true
assert_streq 'fold reports the stream corrupt' "$AIB_EVENT_SCAN_STATUS" 'corrupt'
( aib_event_commit "$EV3" "$LK3" attempt.decided "$env_dec" "$pay_dec" ) >/dev/null 2>&1
assert_nonzero 'writer refuses to append onto a corrupt stream' "$?"
assert_missing 'writer wrote no new record onto the corrupt stream' "$(cat "$EV3")" 'acme-main-2'

# a shifted/garbled prefix (non-object body) is corrupt too
S3b="$WORK/s3b"; mkdir -p "$S3b"; aib_event_stream_paths "$S3b"; EV3b="$AIB_EVENT_FILE"; LK3b="$AIB_EVENT_LOCK"
mkdir -p "$(dirname "$EV3b")"
printf '1 0 5 hello\n' >> "$EV3b"
aib_event_scan "$EV3b" >/dev/null 2>&1 || true
assert_streq 'non-object body is corrupt' "$AIB_EVENT_SCAN_STATUS" 'corrupt'

# -----------------------------------------------------------------------------
# 9. at-most-one attempt.ended per attempt_id (in-lock broker rule)
# -----------------------------------------------------------------------------
S4="$WORK/s4"; mkdir -p "$S4"
aib_event_stream_paths "$S4"
EV4="$AIB_EVENT_FILE"; LK4="$AIB_EVENT_LOCK"
aib_event_commit "$EV4" "$LK4" attempt.decided "$env_dec" "$pay_dec"   # seq 1
decided_id="$AIB_EVENT_COMMIT_EVENT_ID"
end_pay="$(aib_event_compose_ended_payload $'exit_class=ok')"
aib_event_commit "$EV4" "$LK4" attempt.ended "$env_dec" "$end_pay" "$decided_id"   # seq 2
assert_streq 'ended commit gets its own seq 2' "$AIB_EVENT_COMMIT_SEQ" '2'
end_json="$(frame_json "$(sed -n '2p' "$EV4")")"
assert_streq 'ended attempt_id == decided event_id' "$(aib_event_field "$end_json" attempt_id)" "$decided_id"
assert_streq 'ended causation_id == decided event_id' "$(aib_event_field "$end_json" causation_id)" "$decided_id"
assert_streq 'ended event_id is its own (seq 2)' "$(aib_event_field "$end_json" event_id)" 'acme-main-2'
# a second ended for the SAME attempt must be refused fail-closed, no third record
( aib_event_commit "$EV4" "$LK4" attempt.ended "$env_dec" "$end_pay" "$decided_id" ) >/dev/null 2>&1
assert_nonzero 'second attempt.ended is refused fail-closed' "$?"
assert_streq 'stream still has exactly two records' "$(wc -l < "$EV4")" '2'
# an ended for a DIFFERENT attempt is allowed
aib_event_commit "$EV4" "$LK4" attempt.decided "$env_dec" "$pay_dec"   # seq 3
did2="$AIB_EVENT_COMMIT_EVENT_ID"
aib_event_commit "$EV4" "$LK4" attempt.ended "$env_dec" "$end_pay" "$did2"   # seq 4
assert_streq 'a different attempt may end (seq 4)' "$AIB_EVENT_COMMIT_SEQ" '4'
( aib_event_commit "$EV4" "$LK4" attempt.ended "$env_dec" "$end_pay" ) >/dev/null 2>&1
assert_nonzero 'attempt.ended without a decided id is refused' "$?"

# -----------------------------------------------------------------------------
# 10. lost inner seq gap -> degraded, non-blocking; writer resumes above highest
# -----------------------------------------------------------------------------
S5="$WORK/s5"; mkdir -p "$S5"
aib_event_stream_paths "$S5"
EV5="$AIB_EVENT_FILE"; LK5="$AIB_EVENT_LOCK"
aib_event_commit "$EV5" "$LK5" attempt.decided "$env_dec" "$pay_dec"   # seq 1
# forge a valid seq-3 record (gap at 2) with a correct frame
j3='{"event_id":"acme-main-3","event_type":"attempt.decided","payload":{}}'
set -- $(printf '%s' "$j3" | cksum); c3="$1"; l3="$2"
printf '3 %s %s %s\n' "$c3" "$l3" "$j3" >> "$EV5"
aib_event_scan "$EV5" >/dev/null 2>&1 || true
assert_streq 'inner seq gap is degraded not corrupt' "$AIB_EVENT_SCAN_STATUS" 'degraded'
assert_streq 'degraded next_seq is above the highest valid seq' "$AIB_EVENT_SCAN_NEXT_SEQ" '4'
aib_event_commit "$EV5" "$LK5" attempt.decided "$env_dec" "$pay_dec"
assert_streq 'writer resumes at seq 4 on a degraded stream' "$AIB_EVENT_COMMIT_SEQ" '4'

# -----------------------------------------------------------------------------
# 11. finite lock timeout — a held lock fails loudly, never hangs
# -----------------------------------------------------------------------------
S6="$WORK/s6"; mkdir -p "$S6"
aib_event_stream_paths "$S6"
EV6="$AIB_EVENT_FILE"; LK6="$AIB_EVENT_LOCK"
mkdir -p "$(dirname "$LK6")"
exec {holdfd}>>"$LK6"
flock -x "$holdfd"
( AIBOBNET_EVENT_LOCK_TIMEOUT=1 aib_event_commit "$EV6" "$LK6" attempt.decided "$env_dec" "$pay_dec" ) >/dev/null 2>&1
lock_rc=$?
flock -u "$holdfd"; exec {holdfd}>&-
assert_nonzero 'commit fails when the lock is held past the timeout' "$lock_rc"
assert_streq 'no record was written while the lock was contended' "$(wc -l < "$EV6" 2>/dev/null || echo 0)" '0'
# after the lock is released, a commit succeeds
aib_event_commit "$EV6" "$LK6" attempt.decided "$env_dec" "$pay_dec"
assert_streq 'commit succeeds once the lock is free' "$AIB_EVENT_COMMIT_SEQ" '1'

# -----------------------------------------------------------------------------
# 12. missing runtime input / dependency guards
# -----------------------------------------------------------------------------
( aib_event_commit "$EV" "$LK" bogus.type "$env_dec" "$pay_dec" ) >/dev/null 2>&1
assert_nonzero 'unknown event_type is refused' "$?"
( aib_event_commit "$EV" "$LK" attempt.decided $'actor_type=service\nactor_id=x' "$pay_dec" ) >/dev/null 2>&1
assert_nonzero 'missing project_uid is refused' "$?"
( aib_event_commit "$EV" "$LK" attempt.decided $'project_uid=acme\nactor_id=x' "$pay_dec" ) >/dev/null 2>&1
assert_nonzero 'missing actor_type is refused' "$?"
( aib_event_commit "$EV" "$LK" attempt.decided $'project_uid=acme\nactor_type=service' "$pay_dec" ) >/dev/null 2>&1
assert_nonzero 'missing actor_id is refused (§B7)' "$?"
( aib_event_commit "$EV" "$LK" attempt.decided "$env_dec" 'not-an-object' ) >/dev/null 2>&1
assert_nonzero 'non-object payload is refused' "$?"

total=$((pass+fail))
printf '\n%d checks: %d ok / %d fail\n' "$total" "$pass" "$fail"
[ "$fail" -eq 0 ]
