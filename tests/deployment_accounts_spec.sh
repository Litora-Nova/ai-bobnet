#!/usr/bin/env bash
# ai-bobnet — RED spec for `accounts` in the deployment configuration (Supervisor slice S1c; design v3 G6, v3.1 H2, E9) plus the
# installed-host owner-seam guard that the S1b gate asked for.
#
# WHAT THIS PINS
#   deployment.json gains an OPTIONAL top-level `accounts` object: { "<provider>": { "label"?, "credential_mode"?, "credential_source"? } }
#     provider key  [a-z0-9]+(-[a-z0-9]+)*  (the registry/adapter names: claude-code, codex)
#     label         string, 0..64 characters, printable only (no control characters, so no newline/tab/escape); non-ASCII printable is fine
#     credential_mode    "file" | "fd" | "shared" | "proxy"   ("proxy" is only a RESERVED value until S1d; the validator accepts it)
#     credential_source  "login" | "setup_token"              (E9: `setup_token` is the reserved seam for a later Claude credential)
#   Anything else in an account (an unknown key, a wrong type, a bad enum value, an over-long/unprintable label, a non-object account, a bad
#   provider key, a duplicate key) makes the WHOLE file invalid — same fail-closed rule as every other field (all allow checks => denied).
#   No `accounts` at all stays valid (S1b files keep working).
#   lib/aibobnet.sh gains   aib_deployment_account <provider> <field>   field = label | credential_mode | credential_source
#     rc 0 and the value on stdout when the VALID file declares it (an empty label prints an empty line and rc 0);
#     rc 1, no output, when the file is invalid, the provider or the field is not declared; rc 2 for a field name outside the three.
#   Guard (S1b gate, Marvin): on an INSTALLED engine (`<engine root>/.aib-installed` present) AIB_DEPLOYMENT_OWNER_UID is ignored even with
#     AIB_TEST_SEAMS=1 — a file owned by the test user is NOT a valid deployment config there.
#
#   Expected on the unbuilt tree: `accounts` is not validated (unknown keys are ignored) and aib_deployment_account does not exist.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/fixtures/ctl_harness.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-depacc.XXXXXX")"
trap sup_cleanup EXIT
mkdir -p "$WORK/lib"
OWN="$(id -u)"
dcfg() { env -i PATH="$PATH" AIB_TEST_SEAMS=1 AIB_DEPLOYMENT_OWNER_UID="$OWN" AIB_DEPLOYMENT_CONFIG="$1" bash -c '. "$1/lib/aibobnet.sh"; shift; "$@"' _ "$SRC_ROOT" "${@:2}" 2>/dev/null; }
rc_of() { local r=0; "$@" >/dev/null || r=$?; echo "$r"; }
put() { printf '%s' "$2" > "$WORK/$1"; chmod 644 "$WORK/$1"; }
base='"deployment_id":"acme-dev-1","allow":{"customer_code":true,"comms_secrets":false}'
wrap() { printf '{%s,"accounts":%s}' "$base" "$1"; }

# --- T1 valid accounts ------------------------------------------------------------------------------------------------------------------------------
put ok.json "$(wrap '{"claude-code":{"label":"Interim: PO account","credential_mode":"fd","credential_source":"login"},"codex":{"credential_mode":"shared"}}')"
eq "T1: a valid accounts object keeps the file valid" "$(rc_of dcfg "$WORK/ok.json" aib_deployment_valid)" 0
eq "T1: label" "$(dcfg "$WORK/ok.json" aib_deployment_account claude-code label)" "Interim: PO account"
eq "T1: credential_mode / credential_source" "$(dcfg "$WORK/ok.json" aib_deployment_account claude-code credential_mode)|$(dcfg "$WORK/ok.json" aib_deployment_account claude-code credential_source)" "fd|login"
eq "T1: another provider" "$(dcfg "$WORK/ok.json" aib_deployment_account codex credential_mode)" shared
eq "T1: an undeclared field of a declared provider => rc 1, no output" "$(rc_of dcfg "$WORK/ok.json" aib_deployment_account codex label)|$(dcfg "$WORK/ok.json" aib_deployment_account codex label)" "1|"
eq "T1: an undeclared provider => rc 1" "$(rc_of dcfg "$WORK/ok.json" aib_deployment_account other label)" 1
eq "T1: a field name outside the three => rc 2" "$(rc_of dcfg "$WORK/ok.json" aib_deployment_account codex token)" 2
put none.json "{$base}"
eq "T1: no accounts at all: valid, and every lookup is rc 1" "$(rc_of dcfg "$WORK/none.json" aib_deployment_valid)|$(rc_of dcfg "$WORK/none.json" aib_deployment_account codex label)" "0|1"
put empty.json "$(wrap '{}')"; eq "T1: an empty accounts object is valid" "$(rc_of dcfg "$WORK/empty.json" aib_deployment_valid)" 0
put emptylabel.json "$(wrap '{"codex":{"label":""}}')"
eq "T1: an empty label is allowed (rc 0, empty line)" "$(rc_of dcfg "$WORK/emptylabel.json" aib_deployment_account codex label)|$(dcfg "$WORK/emptylabel.json" aib_deployment_account codex label | wc -l | tr -d ' ')" "0|1"
put uni.json "$(wrap '{"codex":{"label":"Büro Köln – Test"}}')"
eq "T1: non-ASCII printable text is a fine label" "$(dcfg "$WORK/uni.json" aib_deployment_account codex label)" "Büro Köln – Test"
put l64.json "$(wrap "{\"codex\":{\"label\":\"$(head -c 64 /dev/zero | tr '\0' x)\"}}")"
eq "T1: a 64-character label is the maximum that is valid" "$(rc_of dcfg "$WORK/l64.json" aib_deployment_valid)" 0
for m in file fd shared proxy; do put m.json "$(wrap "{\"codex\":{\"credential_mode\":\"$m\"}}")"; eq "T1: credential_mode '$m' is valid" "$(rc_of dcfg "$WORK/m.json" aib_deployment_valid)" 0; done
for s in login setup_token; do put s.json "$(wrap "{\"claude-code\":{\"credential_source\":\"$s\"}}")"; eq "T1: credential_source '$s' is valid" "$(rc_of dcfg "$WORK/s.json" aib_deployment_valid)" 0; done

# --- T2 fail closed ------------------------------------------------------------------------------------------------------------------------------------
bad() { # bad <label> <accounts-json>
  put bad.json "$(wrap "$2")"
  eq "T2: $1 => file invalid, customer_code denied, account lookup rc 1" "$(rc_of dcfg "$WORK/bad.json" aib_deployment_valid)|$(rc_of dcfg "$WORK/bad.json" aib_deployment_allow customer_code)|$(rc_of dcfg "$WORK/bad.json" aib_deployment_account codex label)" "1|1|1"
}
bad "accounts is an array" '[]'
bad "accounts is a string" '"x"'
bad "accounts is null" 'null'
bad "an account is a string" '{"codex":"x"}'
bad "an account is null" '{"codex":null}'
bad "an unknown key in an account" '{"codex":{"label":"x","token":"abc"}}'
bad "a numeric label" '{"codex":{"label":5}}'
bad "a null label" '{"codex":{"label":null}}'
bad "a 65-character label" "{\"codex\":{\"label\":\"$(head -c 65 /dev/zero | tr '\0' x)\"}}"
bad "a newline in the label" '{"codex":{"label":"a\nb"}}'
bad "a tab in the label" '{"codex":{"label":"a\tb"}}'
bad "an escape character in the label" '{"codex":{"label":"a\u001bb"}}'
bad "a DEL character in the label" '{"codex":{"label":"a\u007fb"}}'
bad "a bad credential_mode" '{"codex":{"credential_mode":"banana"}}'
bad "an upper-case credential_mode" '{"codex":{"credential_mode":"FD"}}'
bad "a non-string credential_mode" '{"codex":{"credential_mode":1}}'
bad "a bad credential_source" '{"claude-code":{"credential_source":"env"}}'
bad "a provider key with a slash" '{"../codex":{"label":"x"}}'
bad "an upper-case provider key" '{"Codex":{"label":"x"}}'
bad "an empty provider key" '{"":{"label":"x"}}'
bad "a duplicate provider key" '{"codex":{"label":"a"},"codex":{"label":"b"}}'
bad "a duplicate field in an account" '{"codex":{"label":"a","label":"b"}}'

# --- T3 the owner seam is ignored on an installed engine ---------------------------------------------------------------------------------------------
mkdir -p "$WORK/inst/lib"; cp "$SRC_ROOT/lib/"* "$WORK/inst/lib/"
instrc() { env -i PATH="$PATH" AIB_TEST_SEAMS=1 AIB_DEPLOYMENT_OWNER_UID="$OWN" AIB_DEPLOYMENT_CONFIG="$WORK/ok.json" bash -c '. "$1/lib/aibobnet.sh"; aib_deployment_valid' _ "$WORK/inst" >/dev/null 2>&1; echo $?; }
eq "T3: engine WITHOUT the install marker: the seam names our uid as owner => valid" "$(instrc)" 0
: > "$WORK/inst/.aib-installed"
eq "T3: engine WITH .aib-installed: AIB_TEST_SEAMS=1 + AIB_DEPLOYMENT_OWNER_UID are ignored => a test-user-owned file is NOT valid" "$(instrc)" 1

printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
