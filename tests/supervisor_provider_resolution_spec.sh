#!/usr/bin/env bash
# ai-bobnet — supervisor provider binding follows the managed resolver's
# agent -> direct team -> project precedence.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/fixtures/sup_harness.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-supprovider.XXXXXX")"
trap sup_cleanup EXIT

sup_world precedence
cat > "$ENGINE/registry.json" <<JSON
{ "schema_version": 5,
  "providers": {
    "team-provider": { "adapter": "$SRC_ROOT/adapters/codex", "cap_sandbox": "workspace-write",
                       "cap_tier": "t2", "cap_effort": "high", "cap_timeout": "1" },
    "project-provider": { "adapter": "$SRC_ROOT/adapters/codex", "cap_sandbox": "workspace-write",
                          "cap_tier": "t2", "cap_effort": "high", "cap_timeout": "5" }
  },
  "projects": { "acme": { "home": "$HOMEDIR", "standup_dir": "$STANDUP", "mux_session": "acme", "data_class": "internal",
                            "provider": "project-provider", "model": "team/model-v2", "effort": "low" } },
  "teams": { "acme-engine": { "project": "acme", "provider": "team-provider", "model": "team/model-v2" } },
  "agents": {
    "acme-core": { "mode": "supervised", "project": "acme", "team_uid": "acme-engine", "profile": "engine-dev", "clearance": "t2" }
  } }
JSON

observed="$(env -i PATH="$PATH" HOME="$W" LANG=C TZ=UTC \
  STATE_DIRECTORY="$STATE" AIBOBNET_REGISTRY="$ENGINE/registry.json" \
  python3 -I - "$ENGINE" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
sys.path.insert(0, str(root / "lib"))
from aib_supervisor import Supervisor

supervisor = Supervisor(root, "acme-core")
reason = supervisor.configure()
print(f"{reason or 'ok'}|{supervisor.provider_uid}|{supervisor.cap_timeout}")
PY
)"
eq "team provider overrides the project provider for supervisor cap_timeout" "$observed" "ok|team-provider|1"

sup_world shared-bound 3600
deployment="$W/deployment.json"
printf '%s\n' '{"deployment_id":"test","allow":{"customer_code":false,"comms_secrets":false},"accounts":{"acme":{"credential_mode":"shared"}}}' > "$deployment"
chmod 644 "$deployment"
observed="$(env -i PATH="$PATH" HOME="$W" LANG=C TZ=UTC \
  STATE_DIRECTORY="$STATE" AIBOBNET_REGISTRY="$ENGINE/registry.json" \
  AIB_DEPLOYMENT_CONFIG="$deployment" AIB_TEST_SEAMS=1 AIB_DEPLOYMENT_OWNER_UID="$(id -u)" \
  python3 -I - "$ENGINE" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
sys.path.insert(0, str(root / "lib"))
from aib_supervisor import Supervisor

supervisor = Supervisor(root, "acme-core")
reason = supervisor.configure()
print(f"{reason or 'ok'}|{supervisor.provider_uid}|{supervisor.cap_timeout}")
PY
)"
eq "a shared-login provider clamps the supervisor cap_timeout" "$observed" "ok|acme|900"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
