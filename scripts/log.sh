#!/usr/bin/env bash
# ai-bobnet — fail-loud heartbeat logger.
# Usage: log.sh <agent_uid> <busy|idle|blocked|done> "<one line>"
#   Requires a resolvable context (agent_uid -> project -> standup_dir from the registry).
#   Missing/ambiguous -> error + hint; NEVER a default dir.
#   Appends to <standup_dir>/<agent_uid>.log. agent_uid is canonical; persona is display-only.
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
status="${2:-}"
msg="${3:-}"
if [ -z "$agent" ] || [ -z "$status" ] || [ -z "$msg" ]; then
  aib_die 64 'usage: log.sh <agent_uid> <busy|idle|blocked|done> "<one line>"'
fi
case "$status" in
  busy|idle|blocked|done) ;;
  *) aib_die 64 "invalid status '$status' (expected: busy|idle|blocked|done)";;
esac

aib_check_registry

aib_split_agent "$agent"                      # -> AIB_PROJECT_UID (fail-loud if unresolvable)
standup_dir="$(aib_project_field "$AIB_PROJECT_UID" standup_dir)"

# Standalone log.sh stays registry-authenticated. Managed callers bypass this
# front door and pass their already-resolved process-local bundle directly to the
# same primitive, so their heartbeat path never reopens mutable registry state.
aib_log_resolved "$standup_dir" "$agent" "$status" "$msg"
