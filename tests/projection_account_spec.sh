#!/usr/bin/env bash
# ai-bobnet — RED spec for the account block of the visibility projection (Supervisor slice S1c; design v3 G6, v3.1 H7).
# Extends tests/projection_supervisor_spec.sh, which pins `supervisor.account` as null "until S1c" for a world with no login data; that spec is unchanged.
#
# WHAT THIS PINS
#   agents[uid].supervisor.account (for a `mode: supervised` agent) becomes
#       null                                                         when the agent's project provider has neither an `accounts.<provider>` entry
#                                                                    in the deployment config nor a login status file
#       {"provider":P,"state":S,"label":L,"id_hint":H}               otherwise — exactly these four keys
#   P = the registry provider of the agent's project; S/H = `state`/`id_hint` of $AIB_LOGIN_STATUS_DIR/<P>.json (absent file => state "absent",
#   id_hint ""); L = deployment `accounts.<P>.label` ("" when none). Seams (gate AIB_TEST_SEAMS=1, no `.aib-installed`): AIB_DEPLOYMENT_CONFIG,
#   AIB_DEPLOYMENT_OWNER_UID, AIB_LOGIN_STATUS_DIR. An INVALID deployment config yields label "" (fail closed), never a crash.
#   Nothing else of the status file is copied: a planted `email`, `token` or any other key never reaches the projection (whitelist, not blacklist).
#   Agents that are not supervised keep `supervisor: null`. The dashboard/projection contract elsewhere is untouched.
#
#   Expected on the unbuilt tree: account stays null for everybody.
set -uo pipefail
SRC_ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
PROJECT_BIN="$SRC_ROOT/bin/project"; JGET="$SRC_ROOT/tests/fixtures/projection_jget.py"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-projacc.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
no(){ fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; }
eq(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2' want '$3')"; fi; }
jg() { python3 -I "$JGET" "$OUT" "$1"; }
HOMEDIR="$WORK/home"; STANDUP="$WORK/standup"; SUPROOT="$WORK/sup"; EVR="$WORK/events"; LSTAT="$WORK/login-status"
mkdir -p "$HOMEDIR" "$STANDUP/inbox" "$SUPROOT" "$EVR/attempts" "$WORK/fakebin" "$LSTAT"
REG="$WORK/registry.json"
cat > "$REG" <<JSON
{ "schema_version": 5,
  "providers": { "claude-code": { "adapter": "/bin/true", "cap_sandbox": "workspace-write", "cap_tier": "t2", "cap_effort": "high", "cap_timeout": "900" },
                 "codex":       { "adapter": "/bin/true", "cap_sandbox": "workspace-write", "cap_tier": "t2", "cap_effort": "high", "cap_timeout": "900" } },
  "projects": { "acme":  { "home": "$HOMEDIR", "standup_dir": "$STANDUP", "mux_session": "acme",  "provider": "claude-code", "model": "m", "effort": "low" },
                "bolt":  { "home": "$HOMEDIR", "standup_dir": "$STANDUP", "mux_session": "bolt",  "provider": "codex",       "model": "m", "effort": "low" } },
  "agents": {
    "acme-core": { "mode": "supervised", "project": "acme", "profile": "engine-dev", "clearance": "t2" },
    "bolt-core": { "mode": "supervised", "project": "bolt", "profile": "engine-dev", "clearance": "t2" },
    "acme-solo": { "mode": "oneshot",    "project": "acme", "profile": "engine-dev", "clearance": "t2" }
  } }
JSON
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/fakebin/systemctl"; chmod +x "$WORK/fakebin/systemctl"
DEP="$WORK/deployment.json"
printf '{"deployment_id":"acme-dev-1","allow":{"customer_code":true,"comms_secrets":true},"accounts":{"claude-code":{"label":"Interim: PO account"}}}' > "$DEP"; chmod 644 "$DEP"
printf '{"provider":"claude-code","state":"expiring","expires_at":"2026-12-01T00:00:00Z","label":"stale","id_hint":"c0de","checked_at":"x","email":"leak@example.test","token":"SECRET-TOKEN-xyz"}' > "$LSTAT/claude-code.json"
OUT="$WORK/out.json"
proj() { RC=0; env -i PATH="$WORK/fakebin:$PATH" TZ=UTC AIB_TEST_SEAMS=1 AIB_DEPLOYMENT_OWNER_UID="$(id -u)" AIB_DEPLOYMENT_CONFIG="$1" AIB_LOGIN_STATUS_DIR="$LSTAT" \
    AIBOBNET_REGISTRY="$REG" AIB_PROJECTION_ROOT="$WORK/proj" AIB_EVENT_ROOT="$EVR" AIB_SUP_STATE_ROOT="$SUPROOT" "$PROJECT_BIN" "${2:-acme}" --stdout > "$OUT" 2>"$WORK/err" || RC=$?; }
acc() { python3 -I -c 'import json,sys;a=json.load(open(sys.argv[1]))["agents"][sys.argv[2]]["supervisor"]["account"];print("null" if a is None else json.dumps(a,sort_keys=True))' "$OUT" "$1" 2>/dev/null; }

proj "$DEP"
eq "T0: bin/project runs" "$RC" 0
eq "T1: account = provider, state and id_hint from the status file, label from the deployment — exactly four keys" "$(acc acme-core)" '{"id_hint": "c0de", "label": "Interim: PO account", "provider": "claude-code", "state": "expiring"}'
eq "T1: the label of the CURRENT deployment wins over the (stale) label in the status file" "$(jg agents.acme-core.supervisor.account.label)" "Interim: PO account"
eq "T1: nothing else of the status file reaches the projection (no email, no token)" "$(grep -c -e 'leak@example' -e 'SECRET-TOKEN' "$OUT")" 0
eq "T1: a oneshot agent keeps supervisor null" "$(jg agents.acme-solo.supervisor)" null
proj "$DEP" bolt; eq "T1: an agent whose provider has no accounts entry and no status file => account null (and the run succeeds)" "$RC|$(acc bolt-core)" "0|null"
printf '{"provider":"codex","state":"ok","expires_at":null,"label":"","id_hint":"beef","checked_at":"x"}' > "$LSTAT/codex.json"
proj "$DEP" bolt
eq "T2: a status file alone (no accounts entry) is enough: label empty" "$(acc bolt-core)" '{"id_hint": "beef", "label": "", "provider": "codex", "state": "ok"}'
rm -f "$LSTAT/claude-code.json"; proj "$DEP"
eq "T2: an accounts entry without a status file => state absent, id_hint empty" "$(acc acme-core)" '{"id_hint": "", "label": "Interim: PO account", "provider": "claude-code", "state": "absent"}'
printf 'not json' > "$WORK/bad.json"; chmod 644 "$WORK/bad.json"; proj "$WORK/bad.json"
eq "T2: an invalid deployment config => label \"\" (fail closed), the projection still runs" "$RC|$(jg agents.acme-core.supervisor.account.label)" "0|"
printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
