#!/usr/bin/env bash
# ai-bobnet — P3 black-box acceptance (CONTRACT-memory.md §7).
set -uo pipefail

SRC_ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-p3.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
ENGINE="$WORK/engine"; STATE="$WORK/state"
mkdir -p "$ENGINE" "$STATE/acme" "$STATE/beta"
cp -R "$SRC_ROOT/bin" "$SRC_ROOT/scripts" "$SRC_ROOT/lib" "$ENGINE/"

cat > "$ENGINE/registry.json" <<JSON
{
  "schema_version": 1,
  "shared_memory_dir": "$STATE/shared",
  "projects": {
    "acme": { "home": "$STATE/acme", "standup_dir": "$STATE/acme/standup", "mux_session": "acme" },
    "beta": { "home": "$STATE/beta", "standup_dir": "$STATE/beta/standup", "mux_session": "beta" }
  }
}
JSON

RUN="$ENGINE/bin/run-agent"; MEM="$ENGINE/bin/memory"
mem(){ local agent="$1"; shift; "$RUN" "$agent" -- "$MEM" "$@"; }

pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
no(){ fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; }
assert_ok(){ local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else no "$d (expected success)"; fi; }
assert_fail(){ local d="$1"; shift; if "$@" >/dev/null 2>&1; then no "$d (expected failure)"; else ok "$d"; fi; }
assert_streq(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2' want '$3')"; fi; }
assert_grep(){ if printf '%s\n' "$2" | grep -qF -- "$3"; then ok "$1"; else no "$1 (missing '$3' in: $2)"; fi; }
assert_ngrep(){ if printf '%s\n' "$2" | grep -qF -- "$3"; then no "$1 (unexpected '$3' in: $2)"; else ok "$1"; fi; }
assert_file_has(){ if grep -qF -- "$3" "$2" 2>/dev/null; then ok "$1"; else no "$1 (missing '$3' in $2)"; fi; }

acme_project="$STATE/acme/standup/memory/project.md"
shared_journal="$STATE/shared/shared.md"

# ============================================================================ #
# 1. Scope isolation
# ============================================================================ #
agent_id="$(mem acme-core propose --scope agent --key note "core-private" --id p3-agent-1)"
assert_streq "agent scope: explicit id is returned" "$agent_id" "p3-agent-1"
assert_grep "agent scope: recall is marked advisory" "$(mem acme-core recall --scope agent)" "advisory: "
assert_grep "agent scope: author recalls own note" "$(mem acme-core recall --scope agent)" "core-private"
assert_ngrep "agent scope: another agent cannot recall it" "$(mem acme-tests recall --scope agent)" "core-private"
assert_fail "agent scope: private item is not reviewable" mem acme-core review "$agent_id" accept

# ============================================================================ #
# 2. Project promotion requires an independent reviewer
# ============================================================================ #
project_id="$(mem acme-core propose --scope project --key fact "project-fact" --id p3-project-1)"
assert_ngrep "project: third party cannot recall proposal" "$(mem acme-tests recall --scope project)" "project-fact"
assert_grep "list: reviewer sees pending project queue" "$(mem acme-review list --state PROPOSED)" "$project_id"
assert_fail "project: author cannot self-review" mem acme-core review "$project_id" accept
assert_ok "project: independent reviewer accepts" mem acme-review review "$project_id" accept
assert_streq "project: accepted review is observable" "$(mem acme-review state "$project_id")" "REVIEWED_ACCEPT"
assert_ok "project: independent reviewer promotes" mem acme-review promote "$project_id"
assert_streq "project: promotion is observable" "$(mem acme-core state "$project_id")" "PROMOTED"
assert_grep "project: other project agent recalls promotion" "$(mem acme-tests recall --scope project)" "project-fact"
assert_grep "list: author sees promoted project item" "$(mem acme-core list --state PROMOTED)" "p3-project-1"

# ============================================================================ #
# 3. Shared trust and missing shared configuration
# ============================================================================ #
shared_id="$(mem acme-core propose --scope shared --key policy "shared-fact" --id p3-shared-1)"
assert_ngrep "shared: beta cannot recall candidate" "$(mem beta-core recall --scope shared)" "shared-fact"
assert_ok "shared: independent reviewer accepts" mem acme-review review "$shared_id" accept
assert_ok "shared: reviewer promotes" mem acme-review promote "$shared_id"
assert_grep "shared: beta recalls published memory" "$(mem beta-core recall --scope shared)" "shared-fact"
assert_grep "shared: bare acme recall includes private agent memory" "$(mem acme-core recall)" "core-private"
assert_grep "shared: bare acme recall includes promoted project memory" "$(mem acme-core recall)" "project-fact"
assert_grep "shared: bare acme recall includes promoted shared memory" "$(mem acme-core recall)" "shared-fact"
assert_grep "shared: bare beta recall includes promoted shared memory" "$(mem beta-core recall)" "shared-fact"

NO_SHARED="$WORK/no-shared-registry.json"
cat > "$NO_SHARED" <<JSON
{
  "projects": {
    "acme": { "home": "$STATE/acme", "standup_dir": "$STATE/acme/standup", "mux_session": "acme" },
    "beta": { "home": "$STATE/beta", "standup_dir": "$STATE/beta/standup", "mux_session": "beta" }
  }
}
JSON
assert_fail "shared: missing shared_memory_dir fails closed" \
  "$RUN" acme-core -- env AIBOBNET_REGISTRY="$NO_SHARED" "$MEM" propose --scope shared "must fail" --id p3-no-shared

# ============================================================================ #
# 4. Rejected proposals stay auditable and never surface in recall
# ============================================================================ #
reject_project="$(mem acme-core propose --scope project "bad-project" --id p3-reject-project)"
mem acme-review review "$reject_project" reject "unsafe" >/dev/null
assert_streq "poisoning: rejected project state is observable" "$(mem acme-core state "$reject_project")" "REVIEWED_REJECT"
assert_ngrep "poisoning: author cannot recall rejected project" "$(mem acme-core recall --scope project)" "bad-project"
assert_ngrep "poisoning: third party cannot recall rejected project" "$(mem acme-tests recall --scope project)" "bad-project"
assert_file_has "poisoning: rejected project remains auditable" "$acme_project" "id:$reject_project | event:REVIEWED_REJECT"

reject_shared="$(mem acme-core propose --scope shared "bad-shared" --id p3-reject-shared)"
mem beta-core review "$reject_shared" reject "unsafe shared" >/dev/null
assert_ngrep "poisoning: rejected shared is absent from recall" "$(mem beta-core recall --scope shared)" "bad-shared"
assert_file_has "poisoning: rejected shared remains auditable" "$shared_journal" "id:$reject_shared | event:REVIEWED_REJECT"

# ============================================================================ #
# 5. Idempotency
# ============================================================================ #
idem_id="$(mem acme-core propose --scope project "once" --id p3-idem)"
mem acme-core propose --scope project "different retry body" --id p3-idem >/dev/null
assert_streq "idempotency: retry returns explicit id" "$idem_id" "p3-idem"
assert_streq "idempotency: one proposal record" "$(grep -cF "id:p3-idem | scope:project" "$acme_project")" "1"
mem acme-review review p3-idem accept >/dev/null
mem acme-review promote p3-idem >/dev/null
assert_ok "idempotency: double promotion is a no-op" mem acme-review promote p3-idem
assert_streq "idempotency: one promotion event" "$(grep -cF "id:p3-idem | event:PROMOTED" "$acme_project")" "1"

# ============================================================================ #
# 6. Governance remains untouched
# ============================================================================ #
assert_ngrep "governance: context never invokes memory" "$(cat "$ENGINE/bin/context")" "bin/memory"
assert_ngrep "governance: inbox never invokes memory" "$(cat "$ENGINE/bin/inbox")" "bin/memory"
assert_ngrep "governance: message never invokes memory" "$(cat "$ENGINE/bin/message")" "bin/memory"

total=$((pass+fail))
printf '\n%d checks: %d ok / %d fail\n' "$total" "$pass" "$fail"
[ "$fail" -eq 0 ]
