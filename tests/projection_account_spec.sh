#!/usr/bin/env bash
# ai-bobnet — RED spec for the account block of the visibility projection (Supervisor slice S1c; design v3 G6, v3.1 H7).
# Extends tests/projection_supervisor_spec.sh, which pins `supervisor.account` as null "until S1c" for a world with no login data; that spec is unchanged.
#
# WHAT THIS PINS
#   agents[uid].supervisor.account (for a `mode: supervised` agent) becomes
#       null                                                         when the agent's effective provider has neither an `accounts.<provider>` entry
#                                                                    in the deployment config nor a login status file
#       {"provider":P,"state":S,"label":L,"id_hint":H}               otherwise — exactly these four keys
#   P = the agent's effective registry provider (agent -> direct team -> project, matching launch resolution); S/H = `state`/`id_hint` of
#   $AIB_LOGIN_STATUS_DIR/<P>.json (absent file => state "absent",
#   id_hint ""); L = deployment `accounts.<P>.label` ("" when none). Seams (gate AIB_TEST_SEAMS=1, no `.aib-installed`): AIB_DEPLOYMENT_CONFIG,
#   AIB_DEPLOYMENT_OWNER_UID, AIB_LOGIN_STATUS_DIR. An INVALID deployment config yields label "" (fail closed), never a crash.
#   Nothing else of the status file is copied: a planted `email`, `token` or any other key never reaches the projection (whitelist, not blacklist).
#   Agents that are not supervised keep `supervisor: null`. The dashboard/projection contract elsewhere is untouched.
#
#   S2a (agent view, design A3): the block gains `expires_at` and `checked_at`, so it has exactly SIX keys
#       {"provider","state","label","id_hint","expires_at","checked_at"}
#   expires_at/checked_at come from the status file; a value is passed through verbatim iff it is a string of the form YYYY-MM-DDTHH:MM:SSZ
#   (a real calendar instant, UTC `Z`); anything else (non-string, empty, date only, garbage, impossible date) becomes null; a missing
#   status file gives null/null. FLIPS of earlier expectations (design-driven, additive keys): the three exact-block checks T1/T2 now expect
#   the two extra keys (the old fixtures carry checked_at "x" => null). Nothing else of the status file leaks (unchanged).
#
#   Expected on the unbuilt tree: account stays null for everybody; the S2a block (T5) is RED because the keys do not exist yet.
#
#   S2a round 2 (design v2): R1 the status file's times may carry a fraction (the writer emits whole seconds today, other writers may not):
#   YYYY-MM-DDTHH:MM:SS[.f+]Z passes as whole seconds, "…SS.Z" (fraction without digits) is garbage => null. R5 `id_hint` is clamped to its
#   LAST 4 characters (shorter values unchanged). A `state` string outside absent|ok|expiring|expired|pending becomes "absent" (projection-layer whitelist).
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
    "bolt-claude": { "mode": "supervised", "project": "bolt", "provider": "claude-code", "profile": "engine-dev", "clearance": "t2" },
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
eq "T1: account = provider, state and id_hint from the status file, label from the deployment — exactly six keys (S2a: expires_at/checked_at added; the fixture's checked_at "x" is garbage => null)" "$(acc acme-core)" '{"checked_at": null, "expires_at": "2026-12-01T00:00:00Z", "id_hint": "c0de", "label": "Interim: PO account", "provider": "claude-code", "state": "expiring"}'
eq "T1: the label of the CURRENT deployment wins over the (stale) label in the status file" "$(jg agents.acme-core.supervisor.account.label)" "Interim: PO account"
eq "T1: nothing else of the status file reaches the projection (no email, no token)" "$(grep -c -e 'leak@example' -e 'SECRET-TOKEN' "$OUT")" 0
eq "T1: a oneshot agent keeps supervisor null" "$(jg agents.acme-solo.supervisor)" null
proj "$DEP" bolt; eq "T1: an agent whose provider has no accounts entry and no status file => account null (and the run succeeds)" "$RC|$(acc bolt-core)" "0|null"
eq "T1: an agent override selects its effective provider's account, not the project's provider" "$(acc bolt-claude)" '{"checked_at": null, "expires_at": "2026-12-01T00:00:00Z", "id_hint": "c0de", "label": "Interim: PO account", "provider": "claude-code", "state": "expiring"}'
printf '{"provider":"codex","state":"ok","expires_at":null,"label":"","id_hint":"beef","checked_at":"x"}' > "$LSTAT/codex.json"
proj "$DEP" bolt
eq "T2: a status file alone (no accounts entry) is enough: label empty (S2a: plus expires_at null, checked_at garbage => null)" "$(acc bolt-core)" '{"checked_at": null, "expires_at": null, "id_hint": "beef", "label": "", "provider": "codex", "state": "ok"}'
rm -f "$LSTAT/claude-code.json"; proj "$DEP"
eq "T2: an accounts entry without a status file => state absent, id_hint empty (S2a: expires_at/checked_at null)" "$(acc acme-core)" '{"checked_at": null, "expires_at": null, "id_hint": "", "label": "Interim: PO account", "provider": "claude-code", "state": "absent"}'
printf 'not json' > "$WORK/bad.json"; chmod 644 "$WORK/bad.json"; proj "$WORK/bad.json"
eq "T2: an invalid deployment config => label \"\" (fail closed), the projection still runs" "$RC|$(jg agents.acme-core.supervisor.account.label)" "0|"

# T5 (S2a A3): ISO pass-through, garbage => null, missing file
ex() { python3 -I -c 'import json,sys;a=json.load(open(sys.argv[1]))["agents"]["acme-core"]["supervisor"]["account"];print("null" if a is None else json.dumps([a.get("expires_at","MISSING"),a.get("checked_at","MISSING")]))' "$OUT" 2>/dev/null; }
printf '{"provider":"claude-code","state":"ok","expires_at":"2026-12-01T09:30:00Z","label":"x","id_hint":"c0de","checked_at":"2026-10-21T08:15:42Z"}' > "$LSTAT/claude-code.json"; proj "$DEP"
eq "T5: valid ISO UTC expires_at and checked_at pass through verbatim" "$(ex)" '["2026-12-01T09:30:00Z", "2026-10-21T08:15:42Z"]'
for bad in '"x"' '12345' '""' '"2026-12-01"' '"2026-13-45T99:00:00Z"' '"tomorrow at noon"' 'true' '["2026-12-01T00:00:00Z"]' '"2026-12-01T00:00:00Zjunk"' '"2026-12-01T00:00:00.5Zjunk"'; do
  printf '{"provider":"claude-code","state":"ok","expires_at":%s,"label":"x","id_hint":"c0de","checked_at":%s}' "$bad" "$bad" > "$LSTAT/claude-code.json"; proj "$DEP"
  eq "T5: garbage $bad => expires_at and checked_at null (and the run succeeds)" "$RC|$(ex)" '0|[null, null]'
done
printf '{"provider":"claude-code","state":"ok","expires_at":null,"label":"x","id_hint":"c0de"}' > "$LSTAT/claude-code.json"; proj "$DEP"
eq "T5: expires_at null and checked_at key missing in the status file => both null" "$(ex)" '[null, null]'
printf '{"provider":"claude-code","state":"expired","expires_at":"2026-10-20T00:00:00Z","label":"x","id_hint":"c0de","checked_at":"2026-10-21T00:00:00Z"}' > "$LSTAT/claude-code.json"; proj "$DEP"
eq "T5: an expired state keeps its expires_at (the past instant is data, not an error)" "$(jg agents.acme-core.supervisor.account.state)|$(ex)" 'expired|["2026-10-20T00:00:00Z", "2026-10-21T00:00:00Z"]'
rm -f "$LSTAT/claude-code.json"; proj "$DEP"
eq "T5: missing status file (accounts entry only) => state absent, expires_at/checked_at null" "$(jg agents.acme-core.supervisor.account.state)|$(ex)" 'absent|[null, null]'
printf 'not json at all' > "$LSTAT/claude-code.json"; proj "$DEP"
eq "T5: an unparsable status file never crashes the projection" "$RC" 0

# T6 (S2a v2 R1): fractions are accepted and emitted as whole seconds
for pair in '"2026-12-01T09:30:00.250Z"|"2026-12-01T09:30:00Z"' '"2026-12-01T09:30:00.5Z"|"2026-12-01T09:30:00Z"' '"2026-12-01T09:30:00.123456Z"|"2026-12-01T09:30:00Z"' '"2026-12-01T09:30:00.Z"|null'; do
  in="${pair%%|*}"; want="${pair#*|}"
  printf '{"provider":"claude-code","state":"ok","expires_at":%s,"label":"x","id_hint":"c0de","checked_at":%s}' "$in" "$in" > "$LSTAT/claude-code.json"; proj "$DEP"
  eq "T6: time $in => $want (both fields)" "$RC|$(ex)" "0|[$want, $want]" ; done
# T7 (S2a v2 R5): id_hint clamped to its last 4 characters
hint() { printf '{"provider":"claude-code","state":"ok","expires_at":null,"label":"x","id_hint":%s}' "$1" > "$LSTAT/claude-code.json"; proj "$DEP"; jg agents.acme-core.supervisor.account.id_hint; }
eq "T7: a 12-char id_hint is clamped to its last 4 characters" "$(hint '"0123456789ab"')" "89ab"
eq "T7: a 5-char id_hint is clamped to its last 4 characters" "$(hint '"abcde"')" "bcde"
eq "T7: a 4-char id_hint is unchanged" "$(hint '"c0de"')" "c0de"
eq "T7: a 3-char id_hint is unchanged" "$(hint '"c0d"')" "c0d"
eq "T7: an empty id_hint stays empty" "$(hint '""')" ""
eq "T7: a non-string id_hint becomes empty" "$(hint '12345')" ""
# T8 (S2a v2 R7): the state whitelist lives in the projection
st() { printf '{"provider":"claude-code","state":%s,"expires_at":null,"label":"x","id_hint":"c0de"}' "$1" > "$LSTAT/claude-code.json"; proj "$DEP"; jg agents.acme-core.supervisor.account.state; }
for s in ok expiring expired pending absent; do eq "T8: state $s passes" "$(st "\"$s\"")" "$s"; done
eq "T8: an unknown state string becomes absent" "$(st '"weird"')" absent
eq "T8: a state with a different case becomes absent" "$(st '"OK"')" absent
eq "T8: a non-string state becomes absent" "$(st '7')" absent
rm -f "$LSTAT/claude-code.json"

printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
