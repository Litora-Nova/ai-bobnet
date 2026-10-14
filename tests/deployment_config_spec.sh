#!/usr/bin/env bash
# ai-bobnet — RED spec for the per-deployment configuration surface (Supervisor slice S1b; design B14, PO decision E3:
# "customer code / comms secrets on a host = per-deployment configuration").
#
# WHAT THIS PINS
#   The file (`AIB_DEPLOYMENT_CONFIG`, default /etc/aib/deployment.json) is read by lib/aibobnet.sh:
#       aib_deployment_valid            rc 0 iff the file is a VALID configuration
#       aib_deployment_allow <key>      rc 0 allowed | 1 denied | 2 unknown key;  key = customer_code | comms_secrets
#   FAIL-CLOSED: missing, unreadable, empty, unparseable, wrongly typed, incomplete, duplicate-key or group/other-WRITABLE file
#   => not valid => every allow is denied. VALID means: a JSON object with a non-empty string `deployment_id`, an `allow` object
#   whose `customer_code` and `comms_secrets` are JSON booleans (strings/numbers are NOT booleans), and — when present —
#   `profile` a string, `allowed_projects` an array of strings, `role_map` an object of string -> string.
#   The registry cannot override it: `projects.<p>.data_class` (internal|customer, default internal, anything else is treated as
#   customer) only says what a project IS; the deployment says what the host MAY run.
#   Enforcement points:
#     - PDP (aib_authorize_launch): snapshot fields `data_class` and `deploy_customer_code`; a non-internal project with
#       deploy_customer_code != true => deny with reason containing `deployment_denied`. An absent data_class means internal
#       (old snapshots keep working). aib_build_pdp_snapshot_record takes OPTIONAL 9th/10th args (data_class, deploy_customer_code)
#       and then emits `data_class=` / `deploy_customer_code=` lines; with 8 args the output is byte-identical to today.
#     - the broker handler answers `end=denied` naming deployment_denied for such a launch, whatever the request says.
#     - bin/aib-supervisor refuses to start (exit 78 = "a restart cannot help", journal supervisor.refused reason
#       `deployment_denied`, an outbox alarm, no READY=1) for an agent of a `customer` project when customer_code is not allowed,
#       and for a `protected: gateway` agent when comms_secrets is not allowed. Other agents are unaffected.
#       (design v1 wrote "exit 0"; the S1a exit-code table in tests/fixtures/sup_harness.sh makes the refusal class 78.)
#   Not pinned (S1c): role_map consumption, an `account` field. Not pinned: allowed_projects enforcement (design lists the field only).
#
#   Expected on the unbuilt tree: the functions do not exist, the PDP ignores the fields, the supervisor never reads the config.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/fixtures/ctl_harness.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-deploy.XXXXXX")"
trap sup_cleanup EXIT
mkdir -p "$WORK/lib"
DC_SEAMS=1; DC_OWNER="$(id -u)"   # test files are owned by the test user; production demands uid 0 (T2b)
dcfg() { env -i PATH="$PATH" ${DC_SEAMS:+AIB_TEST_SEAMS=$DC_SEAMS} ${DC_OWNER:+AIB_DEPLOYMENT_OWNER_UID=$DC_OWNER} ${1:+AIB_DEPLOYMENT_CONFIG="$1"} bash -c '. "$1/lib/aibobnet.sh"; shift; "$@"' _ "$SRC_ROOT" "${@:2}" >/dev/null 2>&1; }
rc_of() { local r=0; "$@" || r=$?; echo "$r"; }
good='{"deployment_id":"acme-prod-1","profile":"team-host","allow":{"customer_code":true,"comms_secrets":false},"allowed_projects":["acme"],"role_map":{"T1":"aib-agent","T2":"aib-dev"}}'
put() { printf '%s' "$2" > "$WORK/$1"; chmod 644 "$WORK/$1"; }

# --- T1 a valid file answers per key ---------------------------------------------------------------
put ok.json "$good"
eq "T1: valid file: aib_deployment_valid => 0" "$(rc_of dcfg "$WORK/ok.json" aib_deployment_valid)" 0
eq "T1: customer_code=true => allowed (0)" "$(rc_of dcfg "$WORK/ok.json" aib_deployment_allow customer_code)" 0
eq "T1: comms_secrets=false => denied (1)" "$(rc_of dcfg "$WORK/ok.json" aib_deployment_allow comms_secrets)" 1
eq "T1: an unknown key => 2" "$(rc_of dcfg "$WORK/ok.json" aib_deployment_allow root_shell)" 2
put flip.json '{"deployment_id":"d","allow":{"customer_code":false,"comms_secrets":true}}'
eq "T1: …and the other way round (customer denied, comms allowed)" "$(rc_of dcfg "$WORK/flip.json" aib_deployment_allow customer_code)|$(rc_of dcfg "$WORK/flip.json" aib_deployment_allow comms_secrets)" "1|0"

# --- T2 fail closed: every broken shape denies everything ---------------------------------------------
BAD_NAMES=()
badcase() { # badcase <name> <content>
  BAD_NAMES+=("$1")
  put "$1.json" "$2"
  eq "T2: $1 => not valid (1)" "$(rc_of dcfg "$WORK/$1.json" aib_deployment_valid)" 1
  eq "T2: …customer_code denied" "$(rc_of dcfg "$WORK/$1.json" aib_deployment_allow customer_code)" 1
  eq "T2: …comms_secrets denied" "$(rc_of dcfg "$WORK/$1.json" aib_deployment_allow comms_secrets)" 1
}
badcase empty ''
badcase garbage 'this is not json'
badcase truncated '{"deployment_id":"d","allow":{"customer_code":tr'
badcase array '[{"deployment_id":"d"}]'
badcase empty_object '{}'
badcase no_allow '{"deployment_id":"d"}'
badcase no_id '{"allow":{"customer_code":true,"comms_secrets":true}}'
badcase empty_id '{"deployment_id":"","allow":{"customer_code":true,"comms_secrets":true}}'
badcase string_bool '{"deployment_id":"d","allow":{"customer_code":"true","comms_secrets":true}}'
badcase number_bool '{"deployment_id":"d","allow":{"customer_code":1,"comms_secrets":true}}'
badcase missing_comms '{"deployment_id":"d","allow":{"customer_code":true}}'
badcase bad_projects '{"deployment_id":"d","allow":{"customer_code":true,"comms_secrets":true},"allowed_projects":"acme"}'
badcase bad_role_map '{"deployment_id":"d","allow":{"customer_code":true,"comms_secrets":true},"role_map":["aib-agent"]}'
badcase bad_role_value '{"deployment_id":"d","allow":{"customer_code":true,"comms_secrets":true},"role_map":{"T1":5}}'
badcase dup_key '{"deployment_id":"d","allow":{"customer_code":false,"comms_secrets":false},"allow":{"customer_code":true,"comms_secrets":true}}'
put ww.json "$good"; chmod 666 "$WORK/ww.json"
eq "T2: a world-writable file is not trusted (class config.executable.write) => not valid" "$(rc_of dcfg "$WORK/ww.json" aib_deployment_valid)|$(rc_of dcfg "$WORK/ww.json" aib_deployment_allow customer_code)" "1|1"
put gw.json "$good"; chmod 664 "$WORK/gw.json"
eq "T2: …nor a group-writable one" "$(rc_of dcfg "$WORK/gw.json" aib_deployment_valid)" 1
put ur.json "$good"; chmod 000 "$WORK/ur.json"
eq "T2: an unreadable file => denied" "$(rc_of dcfg "$WORK/ur.json" aib_deployment_valid)|$(rc_of dcfg "$WORK/ur.json" aib_deployment_allow customer_code)" "1|1"
eq "T2: a missing file => denied" "$(rc_of dcfg "$WORK/nope.json" aib_deployment_valid)|$(rc_of dcfg "$WORK/nope.json" aib_deployment_allow customer_code)" "1|1"
eq "T2: AIB_DEPLOYMENT_CONFIG unset => the default path /etc/aib/deployment.json (absent on a dev box) => denied" "$(rc_of dcfg "" aib_deployment_allow customer_code)" 1

# --- T2b ONE owner rule: only root (uid 0) may own the file; the override is a gated test seam ---------------------------------
put own.json "$good"
DC_OWNER=""; DC_SEAMS=""
eq "T2b: a file owned by a non-root user is NOT valid on a real engine (no seam, default owner uid 0)" "$(rc_of dcfg "$WORK/own.json" aib_deployment_valid)|$(rc_of dcfg "$WORK/own.json" aib_deployment_allow customer_code)" "1|1"
DC_OWNER="$(id -u)"; DC_SEAMS=""
eq "T2b: …the owner override is IGNORED without AIB_TEST_SEAMS=1" "$(rc_of dcfg "$WORK/own.json" aib_deployment_valid)" 1
DC_OWNER="$(id -u)"; DC_SEAMS=1
eq "T2b: …with the seam gate open the named owner is accepted" "$(rc_of dcfg "$WORK/own.json" aib_deployment_valid)|$(rc_of dcfg "$WORK/own.json" aib_deployment_allow customer_code)" "0|0"
DC_OWNER="$(( $(id -u) + 1 ))"; DC_SEAMS=1
eq "T2b: …and a file owned by anybody ELSE than the named owner is refused" "$(rc_of dcfg "$WORK/own.json" aib_deployment_valid)" 1
DC_OWNER="$(id -u)"; DC_SEAMS=1

# --- T3 the PDP (pure) ----------------------------------------------------------------------------------
. "$SRC_ROOT/lib/aibobnet.sh"
req() { printf 'agent_uid=acme-core\nsandbox=read-only\ncwd=/w\ntimeout=1200\nlabel=l'; }
snapx() { # snapx <extra lines...>
  printf 'clearance=t2\nprovider=codex\neffort=low\nadapter=/a/b\ncap_sandbox=read-only\ncap_tier=t3\ncap_effort=high\ncap_timeout=900'
  local l; for l in "$@"; do printf '\n%s' "$l"; done
}
pdp() { aib_authorize_launch "$(req)" "$(snapx "$@")" >/dev/null 2>&1; PDP_RC=$?; }
pdp; eq "T3: a snapshot WITHOUT data_class is unchanged: allow" "$AIB_VERDICT_DECISION" allow
pdp data_class=internal deploy_customer_code=false; eq "T3: internal project, customer_code=false: allow" "$AIB_VERDICT_DECISION" allow
pdp data_class=customer deploy_customer_code=true;  eq "T3: customer project, customer_code=true: allow" "$AIB_VERDICT_DECISION" allow
pdp data_class=customer deploy_customer_code=false
eq "T3: customer project, customer_code=false: deny" "$AIB_VERDICT_DECISION" deny
has "T3: …reason deployment_denied" "$AIB_VERDICT_REASONS" deployment_denied
eq "T3: …a deny leaves no effective authority" "$AIB_VERDICT_EFFECTIVE_SANDBOX|$([ "$PDP_RC" -ne 0 ] && echo nonzero)" "|nonzero"
pdp data_class=customer; eq "T3: customer project with NO deploy_customer_code field: deny (fail closed)" "$AIB_VERDICT_DECISION" deny
pdp data_class=customer deploy_customer_code=yes; eq "T3: …a non-'true' value is not true: deny" "$AIB_VERDICT_DECISION" deny
pdp data_class=secret deploy_customer_code=false; eq "T3: an unknown data_class is treated as customer: deny" "$AIB_VERDICT_DECISION" deny
pdp data_class= deploy_customer_code=false; eq "T3: an EMPTY data_class is not 'absent': deny" "$AIB_VERDICT_DECISION" deny
old="$(aib_build_pdp_snapshot_record t2 codex low /a/b read-only t3 high 900)"
want="$(printf 'clearance=t2\nprovider=codex\neffort=low\nadapter=/a/b\ncap_sandbox=read-only\ncap_tier=t3\ncap_effort=high\ncap_timeout=900')"
eq "T3: the 8-arg snapshot builder is byte-identical to today" "$old" "$want"
new="$(aib_build_pdp_snapshot_record t2 codex low /a/b read-only t3 high 900 customer true)"
eq "T3: the 10-arg form appends data_class and deploy_customer_code" "$new" "$want
data_class=customer
deploy_customer_code=true"

# --- T4 the broker handler denies a launch for a customer project --------------------------------------------
ctl_world handler; ctl_registry customer
frame() { printf 'op=launch\nagent_uid=acme-core\ncwd_bytes=0\nlabel_bytes=0\nprompt_bytes=5\n\nhallo'; }
hand() { env -i PATH="$PATH" HOME="$W" AIB_TEST_SEAMS=1 AIB_DEPLOYMENT_OWNER_UID="$ME_UID" AIBOBNET_REGISTRY="$ENGINE/registry.json" AIB_EVENT_ROOT="$W/event-root" ${1:+AIB_DEPLOYMENT_CONFIG="$1"} "$ENGINE/bin/aib-broker-handler" 2>/dev/null; }
put cfg_no.json '{"deployment_id":"d","allow":{"customer_code":false,"comms_secrets":false}}'
resp="$(frame | hand "$WORK/cfg_no.json")"
has "T4: customer project + customer_code=false => end=denied" "$resp" "end=denied"
has "T4: …naming deployment_denied" "$resp" "deployment_denied"
hasnt "T4: …and nothing was enacted" "$resp" "enacted=yes"
resp="$(frame | hand "$WORK/nope.json")"
has "T4: customer project + MISSING config => end=denied" "$resp" "end=denied"
has "T4: …naming deployment_denied" "$resp" "deployment_denied"
resp="$(frame | hand "$WORK/garbage.json")"
has "T4: customer project + INVALID config => end=denied" "$resp" "end=denied"
has "T4: …naming deployment_denied" "$resp" "deployment_denied"

# --- T4b a project WITHOUT data_class is customer (registry level fails closed; the old-snapshot rule of T3 is unchanged) ------------
ctl_world handler2; ctl_registry -
resp="$(frame | hand "$WORK/cfg_no.json")"
has "T4b: no data_class + customer_code=false => end=denied" "$resp" "end=denied"
has "T4b: …naming deployment_denied" "$resp" "deployment_denied"
resp="$(frame | hand "$WORK/nope.json")"
has "T4b: no data_class + MISSING config => end=denied" "$resp" "end=denied"
has "T4b: …naming deployment_denied" "$resp" "deployment_denied"

# --- T5 the supervisor refuses what the deployment does not allow ---------------------------------------------------
refuse_case() { # refuse_case <label> <data_class> <agent> <config-file|""> <want: refused|runs>
  ctl_world "r$RANDOM"; ctl_registry "$2"; as human:operator
  CTLENV=("${CTLENV[@]/AIB_DEPLOYMENT_CONFIG=*/AIB_DEPLOYMENT_CONFIG=$4}")
  : > "$W/notify.log"
  start_sup "$3" "${CTLENV[@]}"; sp=$SUP_PID
  local jr="$W/state/$3/journal.jsonl"
  if [ "$5" = refused ]; then
    wait_exit "$sp"; local rc=$RC; SUP_PID=""
    eq "T5: $1 => exit 78" "$rc" 78
    eq "T5: …journal supervisor.refused reason deployment_denied" "$(python3 -I "$SJ" field "$jr" supervisor.refused 1 reason)" deployment_denied
    eq "T5: …no READY=1" "$([ "$rc" = 78 ] && grep -cx 'READY=1' "$W/notify.log")" 0
    has "T5: …an outbox alarm for the team" "$(cat "$OUTBOX/acme-engine/outbox.md" 2>/dev/null)" "alarm:deployment_denied agent:$3"
    has "T5: …addressed to the human of the team" "$(cat "$OUTBOX/acme-engine/outbox.md" 2>/dev/null)" "| to:human:acme-engine | state:PERSISTED | "
  else
    wait_for 10 grep -qx 'READY=1' "$W/notify.log"
    eq "T5: $1 => starts (READY=1)" "$(grep -cx 'READY=1' "$W/notify.log")" 1
    eq "T5: …no refusal, no alarm" "$(python3 -I "$SJ" count "$jr" supervisor.refused)|$(cat "$OUTBOX/acme-engine/outbox.md" 2>/dev/null | wc -l | tr -d ' ')" "0|0"
    stop_sup
  fi
}
put cfg_cust.json '{"deployment_id":"d","allow":{"customer_code":true,"comms_secrets":false}}'
put cfg_comms.json '{"deployment_id":"d","allow":{"customer_code":false,"comms_secrets":true}}'
refuse_case "customer project, customer_code=false" customer acme-core "$WORK/cfg_no.json" refused
refuse_case "customer project, MISSING config" customer acme-core "$WORK/nope.json" refused
refuse_case "customer project, INVALID config" customer acme-core "$WORK/garbage.json" refused
refuse_case "customer project, customer_code=true" customer acme-core "$WORK/cfg_cust.json" runs
refuse_case "internal project, MISSING config (nothing to deny)" internal acme-core "$WORK/nope.json" runs
refuse_case "protected gateway agent, comms_secrets=false" internal acme-gate "$WORK/cfg_cust.json" refused
refuse_case "protected gateway agent, MISSING config" internal acme-gate "$WORK/nope.json" refused
refuse_case "protected gateway agent, comms_secrets=true" internal acme-gate "$WORK/cfg_comms.json" runs
refuse_case "protected GUARDIAN agent needs no comms secrets" internal acme-guard "$WORK/nope.json" runs
refuse_case "project WITHOUT data_class, customer_code=false" - acme-core "$WORK/cfg_no.json" refused
refuse_case "project WITHOUT data_class, MISSING config" - acme-core "$WORK/nope.json" refused
refuse_case "project WITHOUT data_class, customer_code=true" - acme-core "$WORK/cfg_cust.json" runs

# --- T6 ONE validator: the supervisor refuses exactly what the shell side calls invalid (same files, same verdict) ----------------
# every T2 bad shape (including wrongly typed profile/allowed_projects/role_map the supervisor used to ignore) => refused
for n in "${BAD_NAMES[@]}"; do refuse_case "validator parity: $n" customer acme-core "$WORK/$n.json" refused; done
put parity_ok.json "$good"
refuse_case "validator parity: the full valid file" customer acme-core "$WORK/parity_ok.json" runs
for m in 664 666 660 622 002 020; do
  put "mode$m.json" "$good"; chmod "$m" "$WORK/mode$m.json"
  refuse_case "group/other-WRITABLE deployment file (mode $m)" customer acme-core "$WORK/mode$m.json" refused
done
put mode400.json "$good"; chmod 400 "$WORK/mode400.json"
refuse_case "read-only owner-only mode 400 is fine" customer acme-core "$WORK/mode400.json" runs
mkdir -p "$WORK/adir"; refuse_case "a directory is not a deployment file" customer acme-core "$WORK/adir" refused
# owner: the supervisor applies the SAME owner rule (default root; override only behind the seam gate)
refuse_owner() { # refuse_owner <label> <seam flag|""> <owner uid|""> <want>
  ctl_world "o$RANDOM"; ctl_registry customer; as human:operator
  CTLENV=("${CTLENV[@]/AIB_DEPLOYMENT_CONFIG=*/AIB_DEPLOYMENT_CONFIG=$WORK/parity_ok.json}")
  CTLENV=("${CTLENV[@]/AIB_TEST_SEAMS=*/AIB_TEST_SEAMS=$2}"); CTLENV=("${CTLENV[@]/AIB_DEPLOYMENT_OWNER_UID=*/AIB_DEPLOYMENT_OWNER_UID=$3}")
  : > "$W/notify.log"; start_sup acme-core "${CTLENV[@]}"; local sp=$SUP_PID
  if [ "$4" = refused ]; then wait_exit "$sp"; SUP_PID=""; eq "T6: $1 => exit 78" "$RC" 78
  else wait_for 10 grep -qx 'READY=1' "$W/notify.log"; eq "T6: $1 => starts" "$(grep -cx 'READY=1' "$W/notify.log")" 1; stop_sup; fi
}
refuse_owner "file owned by a non-root user, no seam gate (default owner 0)" "" "" refused
refuse_owner "owner override IGNORED without AIB_TEST_SEAMS=1" "" "$ME_UID" refused
refuse_owner "gate open, matching owner uid" 1 "$ME_UID" runs
refuse_owner "gate open, WRONG owner uid" 1 "$((ME_UID + 1))" refused

printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
