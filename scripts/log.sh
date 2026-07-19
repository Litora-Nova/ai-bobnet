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

# Encode the free-text message so it can never be misread as structure: newlines/CR
# collapse to a space (the journal is one heartbeat per line — an embedded newline
# would otherwise split one call into two physical lines, the second one entirely
# attacker-worded and indistinguishable from a real heartbeat to any line-oriented
# reader), and every '|' becomes '%7C' (so a crafted message cannot forge extra
# `TS | agent | status | msg` field boundaries either). Same pattern as bin/message's
# _sanitize_line (encoding, not escaping, is what stays unambiguous for readers this
# script does not control — a dashboard, a grep, a human). agent/status are already
# restricted tokens (registry uid / fixed enum), so only msg needs this.
_sanitize_line() {
  local s="$1"
  s="${s//$'\n'/ }"
  s="${s//$'\r'/ }"
  s="${s//|/%7C}"
  printf '%s' "$s"
}

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

mkdir -p "$standup_dir" || aib_die 2 "cannot create standup_dir: $standup_dir"
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
msg="$(_sanitize_line "$msg")"
printf '%s | %s | %s | %s\n' "$ts" "$agent" "$status" "$msg" >> "$standup_dir/$agent.log"
