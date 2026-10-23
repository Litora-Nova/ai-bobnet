#!/usr/bin/env bash
# ai-bobnet — registry path policy for installed engines and test seams.
set -uo pipefail

SRC_ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-regpath.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
pass=0 fail=0
ok() { printf 'ok   - %s\n' "$1"; pass=$((pass + 1)); }
no() { printf 'FAIL - %s\n' "$1"; fail=$((fail + 1)); }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2', want '$3')"; fi; }

mkdir -p "$WORK/installed/lib" "$WORK/dev/lib" "$WORK/outbox"
cp "$SRC_ROOT/lib/aib_control.py" "$WORK/installed/lib/"
cp "$SRC_ROOT/lib/aib_control.py" "$WORK/dev/lib/"
: > "$WORK/installed/.aib-installed"

resolve() { # resolve <engine> <seams value or -> <registry env value or ->
  local engine=$1 seams=$2 registry=$3 env_args=()
  [ "$seams" = - ] || env_args+=(AIB_TEST_SEAMS="$seams")
  [ "$registry" = - ] || env_args+=(AIBOBNET_REGISTRY="$registry")
  env -i PATH="$PATH" "${env_args[@]}" python3 -I - "$engine/lib/aib_control.py" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("aib_control_under_test", sys.argv[1])
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
print(module.registry_path())
PY
}

evil="$WORK/evil-registry.json"
fixture="$WORK/fixture-registry.json"
eq "installed engine always resolves the production registry and ignores the env seam" \
  "$(resolve "$WORK/installed" 1 "$evil" 2>/dev/null)" "/opt/aib/registry.json"
eq "test seams in an uninstalled tree honour AIBOBNET_REGISTRY" \
  "$(resolve "$WORK/dev" 1 "$fixture" 2>/dev/null)" "$fixture"
eq "test seams without AIBOBNET_REGISTRY keep the engine-root fallback" \
  "$(resolve "$WORK/dev" 1 - 2>/dev/null)" "$WORK/dev/registry.json"
eq "plain development ignores AIBOBNET_REGISTRY and keeps the engine-root fallback" \
  "$(resolve "$WORK/dev" - "$evil" 2>/dev/null)" "$WORK/dev/registry.json"

# Pin every affected Python caller to the one policy function. The helper tests above
# cover installed/dev selection; these checks prevent a caller from reintroducing its
# own ROOT/registry.json fallback beside the shared policy.
for caller in bin/agentctl bin/aib-outbox-init bin/aib-unit-alarm lib/aib_supervisor.py; do
  calls=$(grep -c 'registry_path(' "$SRC_ROOT/$caller" 2>/dev/null || true)
  fallbacks=$(grep -c 'AIBOBNET_REGISTRY.*registry\.json' "$SRC_ROOT/$caller" 2>/dev/null || true)
  eq "$caller uses the shared registry resolver with no private fallback" "$calls|$fallbacks" "1|0"
done

# Guard the existing seam behavior through the three executable entry points.
mkdir -p "$WORK/standup/inbox" "$WORK/fakebin"
cat > "$fixture" <<JSON
{ "schema_version": 5,
  "projects": { "acme": { "home": "$WORK/home", "standup_dir": "$WORK/standup", "mux_session": "acme" } },
  "agents": { "acme-core": { "mode": "supervised", "project": "acme", "team_uid": "acme-engine" } } }
JSON
cat > "$WORK/fakebin/identity" <<'SH'
#!/usr/bin/env bash
printf 'human:operator\n'
SH
cat > "$WORK/fakebin/systemctl" <<'SH'
#!/usr/bin/env bash
printf 'inactive\n'
SH
chmod +x "$WORK/fakebin/identity" "$WORK/fakebin/systemctl"

agentctl_out=$(env -i PATH="$WORK/fakebin:$PATH" HOME="$WORK" AIB_TEST_SEAMS=1 \
  AIBOBNET_REGISTRY="$fixture" AIB_IDENTITY_CMD="$WORK/fakebin/identity" \
  AIB_SYSTEMCTL="$WORK/fakebin/systemctl" AIB_SUP_STATE_ROOT="$WORK/state" \
  "$SRC_ROOT/bin/agentctl" status acme-core 2>/dev/null)
eq "agentctl seam mode reads the env-selected registry" \
  "$(printf '%s\n' "$agentctl_out" | grep -c '^state=STOPPED$')" "1"

env -i PATH="$PATH" HOME="$WORK" AIB_TEST_SEAMS=1 AIBOBNET_REGISTRY="$fixture" \
  AIB_OUTBOX_ROOT="$WORK/outbox" "$SRC_ROOT/bin/aib-outbox-init" >/dev/null 2>&1
eq "aib-outbox-init seam mode reads the env-selected registry" \
  "$([ -d "$WORK/outbox/acme-engine" ] && echo yes)" "yes"

env -i PATH="$PATH" HOME="$WORK" AIB_TEST_SEAMS=1 AIBOBNET_REGISTRY="$fixture" \
  AIB_OUTBOX_ROOT="$WORK/outbox" "$SRC_ROOT/bin/aib-unit-alarm" aib-agent@acme-core.service >/dev/null 2>&1
eq "aib-unit-alarm seam mode reads the env-selected registry" \
  "$(grep -c 'to:human:acme-engine' "$WORK/outbox/acme-engine/outbox.md" 2>/dev/null || true)" "1"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
