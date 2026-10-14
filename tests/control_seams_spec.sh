#!/usr/bin/env bash
# ai-bobnet — RED spec: the test seams of bin/agentctl and bin/aib-gw are dead on an INSTALLED engine
# (S1b delta, gate finding F5: env-supplied AIB_IDENTITY_CMD / AIB_CONTROL_LOG / AIBOBNET_REGISTRY would let any caller
# pick its own identity, audit log and registry).
#
# THE RULE (lead decision, documented in tests/fixtures/ctl_harness.sh): the seams are honoured only when
#   AIB_TEST_SEAMS=1  AND  the engine root has NO install marker `<engine root>/.aib-installed`.
# Otherwise the production defaults apply and nothing the seams point at is touched. AIBOBNET_ACTOR (a recorded claim) is not a seam.
#
# WHAT THIS PINS
#   - no AIB_TEST_SEAMS: agentctl neustart with every seam pointed at a scratch world => the scratch audit log, ctl dir and fake
#     systemctl are NEVER touched, and the exit is neither 0 nor 124 (it fails on the real defaults).
#   - AIB_TEST_SEAMS=1 but the install marker present: same.
#   - AIB_TEST_SEAMS=1, no marker: the seams work (guard; this is how every other control spec runs).
#   - aib-gw: same gate for AIB_AGENTCTL / AIB_GW_PEERS / AIB_CONTROL_LOG / AIB_IDENTITY_CMD: the fake agentctl is never called.
#   - the gate value must be exactly "1" ("0", "", "true" do not open it).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/fixtures/ctl_harness.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-seams.XXXXXX")"
trap sup_cleanup EXIT
ctl_world seams; as human:operator
printf 'hub1\n' > "$W/peers"
cat > "$W/fakes/agentctl" <<'FAKE'
#!/usr/bin/env bash
w=$(cd -P "$(dirname "$0")/.." && pwd); echo "$*" >> "$w/agentctl.calls"; exit 0
FAKE
chmod +x "$W/fakes/agentctl"
touched() { printf '%s|%s|%s' "$([ -s "$CLOG" ] && echo log)" "$(ls "$CTL" | wc -l | tr -d ' ')" "$(wc -c < "$W/systemctl.log" | tr -d ' ')"; }
reset_world() { : > "$CLOG"; rm -f "${CTL:?}"/* "$W/agentctl.calls"; : > "$W/systemctl.log"; rm -f "$ENGINE/.aib-installed"; }
ctl_gate() { # ctl_gate <AIB_TEST_SEAMS value or ->  -> RC; seams ALL pointed at the scratch world
  local g=(); [ "$1" = - ] || g=(AIB_TEST_SEAMS="$1")
  RC=0; env -i PATH="$W/fakebin:$PATH" HOME="$W/home-ctl" LANG=C TZ=UTC "${g[@]}" AIB_CTL_DIR="$CTL" AIB_CONTROL_LOG="$CLOG" AIB_IDENTITY_CMD="$W/fakes/identity" \
    AIB_SYSTEMCTL="$W/fakes/systemctl" AIB_SUP_STATE_ROOT="$W/state" AIB_OUTBOX_ROOT="$OUTBOX" AIB_CTL_WAIT_S=0.3 AIBOBNET_REGISTRY="$ENGINE/registry.json" \
    timeout 30 "$ENGINE/bin/agentctl" neustart acme-core >/dev/null 2>&1 || RC=$?
}
reset_world; ctl_gate 1
eq "S1: gate open (AIB_TEST_SEAMS=1, no marker): the seams work (queued, no supervisor => 124)" "$RC|$(ls "$CTL" | wc -l | tr -d ' ')|$([ -s "$CLOG" ] && echo log)" "124|1|log"
for g in - 0 "" true 2; do
  reset_world; ctl_gate "$g"
  r=$RC; eq "S2: AIB_TEST_SEAMS='${g}' keeps the gate shut: the scratch world is untouched" "$(touched)" "|0|0"
  case "$r" in 0|124) no "S2: …and agentctl did not 'succeed' on the real defaults (rc $r)";; *) ok "S2: …and agentctl failed on the real defaults (rc $r)";; esac
done
reset_world; : > "$ENGINE/.aib-installed"; ctl_gate 1
r=$RC; eq "S3: AIB_TEST_SEAMS=1 on an engine WITH the install marker: seams ignored, scratch world untouched" "$(touched)" "|0|0"
case "$r" in 0|124) no "S3: …rc $r is not a success";; *) ok "S3: …agentctl failed on the real defaults (rc $r)";; esac
rm -f "$ENGINE/.aib-installed"

# aib-gw ------------------------------------------------------------------------------------------------------------------------------
gw_gate() { # gw_gate <AIB_TEST_SEAMS value or -> [marker]
  : > "$W/agentctl.calls"; : > "$CLOG"; rm -f "$ENGINE/.aib-installed"; [ "${2:-}" = marker ] && : > "$ENGINE/.aib-installed"
  local g=(); [ "$1" = - ] || g=(AIB_TEST_SEAMS="$1")
  RC=0; env -i PATH="$W/fakebin:$PATH" HOME="$W/home-ctl" LANG=C "${g[@]}" AIB_CONTROL_LOG="$CLOG" AIB_IDENTITY_CMD="$W/fakes/identity" AIB_AGENTCTL="$W/fakes/agentctl" \
    AIB_GW_PEERS="$W/peers" SSH_ORIGINAL_COMMAND="status acme-core" timeout 20 "$ENGINE/bin/aib-gw" --id hub1 >/dev/null 2>&1 || RC=$?
}
gw_refused() { # refused (77, or 73 when its own audit cannot be written on the real defaults) and NOTHING of the scratch world touched
  case "$RC" in 77|73) ok "$1 (refused, rc $RC)";; *) no "$1 (rc $RC, expected a refusal 77/73)";; esac
  eq "$1: …fake agentctl never called, scratch audit log untouched" "$RC|$(wc -l < "$W/agentctl.calls" | tr -d ' ')|$([ -s "$CLOG" ] && echo log)" "$RC|0|"
}
gw_gate 1
eq "G1: gate open: the fake agentctl is called (guard)" "$RC|$(wc -l < "$W/agentctl.calls" | tr -d ' ')" "0|1"
for g in - 0 ""; do
  gw_gate "$g"
  gw_refused "G2: AIB_TEST_SEAMS='${g}': the peer list and the agentctl seam are ignored"
done
gw_gate 1 marker
gw_refused "G3: install marker present: same, even with AIB_TEST_SEAMS=1"
rm -f "$ENGINE/.aib-installed"

printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
