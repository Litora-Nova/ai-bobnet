#!/usr/bin/env bash
# Task-stream causation ids are the replay boundary across supervisor crashes.
set -uo pipefail
ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/aib-task-causation.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
pass=0 fail=0
ok(){ pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
no(){ fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; }
eq(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2' want '$3')"; fi; }

TASK_ROOT="$WORK/tasks"; mkdir -p "$TASK_ROOT/acme/bodies" "$WORK/home" "$WORK/standup"
: > "$TASK_ROOT/acme/tasks.events"; : > "$TASK_ROOT/acme/tasks.events.lock"
chmod 2750 "$TASK_ROOT/acme" "$TASK_ROOT/acme/bodies"; chmod 640 "$TASK_ROOT/acme/tasks.events" "$TASK_ROOT/acme/tasks.events.lock"
cat > "$WORK/registry.json" <<JSON
{"schema_version":5,"providers":{"acme":{"adapter":"$ROOT/adapters/codex"}},"projects":{"acme":{"home":"$WORK/home","standup_dir":"$WORK/standup","provider":"acme"}},"teams":{"acme-engine":{"project":"acme"}},"agents":{"acme-lead":{"mode":"supervised","lead":"true","project":"acme","team_uid":"acme-engine","profile":"lead","clearance":"t2"},"acme-core":{"mode":"supervised","project":"acme","team_uid":"acme-engine","profile":"worker","clearance":"t2"}}}
JSON
printf '#!/usr/bin/env bash\nprintf "root:root\\n"\n' > "$WORK/identity"; chmod +x "$WORK/identity"
printf 'body\n' > "$WORK/body"
task(){ RC=0; OUT=$(env AIB_TEST_SEAMS=1 AIB_TASK_ROOT="$TASK_ROOT" AIBOBNET_REGISTRY="$WORK/registry.json" AIB_IDENTITY_CMD="$WORK/identity" "$ROOT/bin/task" "$@" 2>"$WORK/err") || RC=$?; ERR=$(<"$WORK/err"); }
common=(--project acme --team acme-engine --actor-type human --actor-id operator --via ctl:1 --requester human:operator)
task run-create "${common[@]}" --causation-id create-run --run-id r-aaaaaaaaaaaa
task create "${common[@]}" --causation-id create-task --run-id r-aaaaaaaaaaaa --intent-n 1 --source-msg-id msg-task --assignee acme-core --title Build --body-ref msg:task --body-file "$WORK/body"
TASK_ID=${OUT#task_id=}

service=(--project acme --team acme-engine --actor-type service --actor-id supervisor:acme-core --run-id r-aaaaaaaaaaaa --task-id "$TASK_ID")
task start "${service[@]}" --causation-id start-task-a1
first_rc=$RC; before=$(wc -l < "$TASK_ROOT/acme/tasks.events"); first_id="acme-tasks-$before"
task start "${service[@]}" --causation-id start-task-a1
duplicate_id=$(printf '%s\n' "$OUT" | sed -n 's/^event_id=//p')
duplicate_flag=$(printf '%s\n' "$OUT" | sed -n 's/^duplicate=//p')
eq 'an accepted causation replay returns rc 0 and the original event id without append' "$first_rc|$RC|$duplicate_id|$duplicate_flag|$(wc -l < "$TASK_ROOT/acme/tasks.events")" "0|0|$first_id|true|$before"

task start "${service[@]}" --causation-id rejected-start-a1
rejected_rc=$RC; rejected_err=$ERR; rejected_lines=$(wc -l < "$TASK_ROOT/acme/tasks.events")
task start "${service[@]}" --causation-id rejected-start-a1
eq 'a rejected causation replay returns the same rc and reason without a second task.rejected' "$rejected_rc|$RC|$ERR|$(wc -l < "$TASK_ROOT/acme/tasks.events")" "77|77|$rejected_err|$rejected_lines"

task report "${service[@]}" --causation-id start-task-a1 --state failed --reason turn_failed
eq 'reusing a causation for another event type is rejected without append' "$RC|$ERR|$(wc -l < "$TASK_ROOT/acme/tasks.events")" "77|ai-bobnet: task request rejected: causation_conflict|$rejected_lines"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
