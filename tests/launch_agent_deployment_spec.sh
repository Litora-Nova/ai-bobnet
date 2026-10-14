#!/usr/bin/env bash
# ai-bobnet — RED spec: a DIRECT launch (bin/launch-agent, no broker) honours the deployment policy too
# (S1b delta, gate finding F1: only the broker handler passed data_class/deploy_customer_code to the PDP; the launcher built the
# 8-field snapshot, so a customer-project agent launched straight from the CLI bypassed `deployment_denied`).
#
# WHAT THIS PINS
#   - bin/launch-agent builds the PDP snapshot in the 10-arg form (aib_build_pdp_snapshot_record ... data_class deploy_customer_code):
#     a launch for an agent of a project that is not `internal` is DENIED with `deployment_denied` unless the deployment allows
#     customer_code; the adapter is never executed; the exit is non-zero and the message names deployment_denied.
#   - REGISTRY-level fail closed: a project WITHOUT a data_class is treated as CUSTOMER (the old default "internal" in the
#     resolver is gone). A missing / invalid / non-root-owned deployment file denies, exactly like customer_code=false.
#   - an explicitly `internal` project launches without any deployment file; customer + customer_code=true launches.
#   (The PDP-level rule "an old snapshot RECORD without the field allows" is unchanged: deployment_config_spec T3.)
set -uo pipefail
SRC_ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
LA="$SRC_ROOT/bin/launch-agent"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-ladep.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
no(){ fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; }
eq(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2' want '$3')"; fi; }
has(){ case "$2" in *"$3"*) ok "$1";; *) no "$1 (missing '$3' in: ${2:0:200})";; esac; }

mkdir -p "$WORK/home" "$WORK/standup" "$WORK/stub" "$WORK/h"
cat > "$WORK/stub/codex" <<FAKE
#!/usr/bin/env bash
echo "called \$*" >> "$WORK/provider.calls"
cat >/dev/null; echo "stub ok"; exit 0
FAKE
chmod +x "$WORK/stub/codex"
reg() { # reg <data_class line or "">  e.g. '"data_class": "customer",'
  cat > "$WORK/registry.json" <<JSON
{ "schema_version": 5,
  "providers": { "acme": { "adapter": "$WORK/stub/codex", "cap_sandbox": "workspace-write", "cap_tier": "t3", "cap_effort": "high", "cap_timeout": "900" } },
  "projects": { "acme": { "home": "$WORK/home", "standup_dir": "$WORK/standup", "mux_session": "acme", $1 "provider": "acme", "model": "m", "effort": "low" } },
  "teams": { "acme-engine": { "project": "acme", "model": "m" } },
  "agents": { "acme-core": { "project": "acme", "team_uid": "acme-engine", "profile": "engine-dev", "clearance": "t2" } } }
JSON
}
dep() { printf '{"deployment_id":"d","allow":{"customer_code":%s,"comms_secrets":false}}' "$1" > "$WORK/dep_$1.json"; chmod 644 "$WORK/dep_$1.json"; }
dep true; dep false
launch() { # launch <deployment path or ""> -> RC OUT, provider calls counted
  : > "$WORK/provider.calls"
  RC=0; OUT="$(env -i PATH="$PATH" HOME="$WORK/h" AIBOBNET_REGISTRY="$WORK/registry.json" AIB_TEST_SEAMS=1 AIB_DEPLOYMENT_OWNER_UID="$(id -u)" \
      ${1:+AIB_DEPLOYMENT_CONFIG="$1"} "$LA" --as acme-core --cwd "$WORK/home" --prompt hi 2>&1)" || RC=$?
  CALLS="$(wc -l < "$WORK/provider.calls" | tr -d ' ')"
}
denied() { # denied <label>
  case "$RC" in 0) no "$1 (launch succeeded)";; *) ok "$1 (rc $RC)";; esac
  has "$1: …naming deployment_denied" "$OUT" deployment_denied
  eq "$1: …the provider was never executed" "$RC|$CALLS" "$RC|0"
}
reg '"data_class": "customer",'; launch "$WORK/dep_false.json"; denied "customer project, customer_code=false"
reg '"data_class": "customer",'; launch "$WORK/nope.json";        denied "customer project, MISSING deployment file"
printf 'not json' > "$WORK/bad.json"; chmod 644 "$WORK/bad.json"
reg '"data_class": "customer",'; launch "$WORK/bad.json";         denied "customer project, INVALID deployment file"
reg "";                          launch "$WORK/dep_false.json"; denied "project WITHOUT data_class, customer_code=false"
reg "";                          launch "$WORK/nope.json";        denied "project WITHOUT data_class, MISSING deployment file"
reg '"data_class": "secret",';   launch "$WORK/dep_false.json"; denied "unknown data_class, customer_code=false"
reg '"data_class": "customer",'; launch "$WORK/dep_true.json"
eq "customer project, customer_code=true => launches (guard)" "$RC|$CALLS" "0|1"
reg "";                          launch "$WORK/dep_true.json"
eq "project WITHOUT data_class, customer_code=true => launches" "$RC|$CALLS" "0|1"
reg '"data_class": "internal",'; launch ""
eq "explicit internal project, no deployment file at all => launches (guard)" "$RC|$CALLS" "0|1"
printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
