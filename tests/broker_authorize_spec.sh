#!/usr/bin/env bash
# ai-bobnet — RM-3 broker, slice 2: authorize moves behind the seam.
#
# WHAT THIS PINS
#   The handler stops refusing unconditionally. It builds a request from the frame, takes the
#   snapshot from the BROKER'S OWN registry (§2: "the snapshot comes from the broker's own
#   registry, never from the caller"), and answers with a verdict.
#
#   Three assurances live only in bin/launch-agent today. Verified against the PDP on 2026-08-16:
#   the timeout form check, the cwd existence check, and the refusal of danger-full-access. Slice 2
#   is where they either move behind the boundary or are recorded as deliberately given up. This
#   spec fixes which is which:
#     timeout  -> MOVES, and needs BOTH halves: form (digits + range) and cap min(requested, cap).
#     cwd      -> MOVES, as containment: resolved, then required to sit inside the registry-derived
#                 root (SPEC-wire-format). Absent means the derived root.
#     sandbox  -> the CLAMP is the contracted behaviour (§3) and stays a clamp. The wrapper's extra
#                 refusal is deliberately NOT moved: clamping to the declared capability grants no
#                 authority the caller did not already have, and it leaves a record where a refusal
#                 leaves an argument. That is a behaviour decision, not a strictness dial — see the
#                 third category in SPEC-wire-format.
#
#   The transport failure domain is new: across a socket every call can fail with a permission
#   error, a timeout or an absent broker. Those must be distinguishable from a denial at the client,
#   which is what the terminal status line is for.
set -uo pipefail

SRC_ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
# shellcheck source=lib/aibobnet.sh
. "$SRC_ROOT/lib/aibobnet.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-authz.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
no(){ fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; }
eq(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2' want '$3')"; fi; }
has(){ if printf '%s\n' "$2" | grep -qF -- "$3"; then ok "$1"; else no "$1 (missing '$3')"; fi; }
hasnt(){ if printf '%s\n' "$2" | grep -qF -- "$3"; then no "$1 (unexpected '$3')"; else ok "$1"; fi; }

# --- 1. the frame carries the fields the wire-format spec assigns to slice 2 ---
# Record lines gain sandbox and timeout; cwd and label are length-prefixed blocks, in the fixed
# order cwd, label, prompt. A reader that counts bytes cannot recover from another order.
frame2(){ # frame2 <cwd> <label> <prompt> <record-line>...
  local c="$1" l="$2" p="$3"; shift 3; local r
  for r in "$@"; do printf '%s\n' "$r"; done
  printf 'cwd_bytes=%s\nlabel_bytes=%s\nprompt_bytes=%s\n\n' \
    "$(printf '%s' "$c" | wc -c)" "$(printf '%s' "$l" | wc -c)" "$(printf '%s' "$p" | wc -c)"
  printf '%s%s%s' "$c" "$l" "$p"
}
out="$(frame2 "/srv/ws" "nightly" "hallo" "op=launch" "agent_uid=acme-dev" "sandbox=workspace-write" "timeout=600" \
       | { aib_wire_read_request && printf '%s|%s|%s|%s|%s' \
           "${AIB_REQ_CWD:-}" "${AIB_REQ_LABEL:-}" "${AIB_REQ_PROMPT:-}" "${AIB_REQ_SANDBOX:-}" "${AIB_REQ_TIMEOUT:-}"; })"
eq "all four new fields arrive, blocks split by count" "$out" "/srv/ws|nightly|hallo|workspace-write|600"

out="$(frame2 "" "" "nur prompt" "op=launch" "agent_uid=acme-dev" | { aib_wire_read_request && printf '[%s][%s][%s]' \
       "${AIB_REQ_CWD:-}" "${AIB_REQ_LABEL:-}" "${AIB_REQ_PROMPT:-}"; })"
eq "empty blocks stay empty and do not shift the order" "$out" "[][][nur prompt]"

# --- 2. sandbox is an enum at the wire, narrower than the token rule ----------
if printf 'op=launch\nagent_uid=acme-dev\nsandbox=wide-open\nprompt_bytes=2\n\nhi' \
   | ( aib_wire_read_request ) >/dev/null 2>&1; then no "an unknown sandbox value is refused"; else ok "an unknown sandbox value is refused"; fi

# --- 3. timeout: BOTH halves, and the cap is a min, never a max --------------
if printf 'op=launch\nagent_uid=acme-dev\ntimeout=banana\nprompt_bytes=2\n\nhi' \
   | ( aib_wire_read_request ) >/dev/null 2>&1; then no "a non-numeric timeout is refused at the wire"; else ok "a non-numeric timeout is refused at the wire"; fi

req="agent_uid=acme-dev
sandbox=workspace-write
timeout=999999"
snap="clearance=t2
provider=acme
effort=medium
adapter=/opt/aib/adapters/acme
cap_sandbox=workspace-write
cap_tier=t2
cap_effort=high
cap_timeout=900"
aib_authorize_launch "$req" "$snap" >/dev/null 2>&1
eq "an over-long timeout is capped to the declared cap" "${AIB_VERDICT_EFFECTIVE_TIMEOUT:-}" "900"
req_short="${req/timeout=999999/timeout=60}"
aib_authorize_launch "$req_short" "$snap" >/dev/null 2>&1
eq "a shorter timeout is left alone — min, never max" "${AIB_VERDICT_EFFECTIVE_TIMEOUT:-}" "60"

# --- 4. sandbox stays a CLAMP, and the clamp is visible in the verdict -------
req_danger="${req/sandbox=workspace-write/sandbox=danger-full-access}"
aib_authorize_launch "$req_danger" "$snap" >/dev/null 2>&1
eq "danger-full-access is clamped, not refused (§3)" "${AIB_VERDICT_DECISION:-}" "allow"
eq "…and the effective sandbox is the declared capability" "${AIB_VERDICT_EFFECTIVE_SANDBOX:-}" "workspace-write"
has "…and the clamp is recorded, so the attempt leaves a trace" "${AIB_VERDICT_REASONS:-}" "sandbox"

# --- 5. cwd is contained against the registry-derived root, never trusted ----
eq "a cwd inside the derived root is accepted"  "$(aib_contain_cwd "/srv/ws" "/srv/ws/sub" && printf '%s' "$AIB_CWD_RESOLVED")" "/srv/ws/sub"
if aib_contain_cwd "/srv/ws" "/etc" >/dev/null 2>&1; then no "a cwd outside the root is refused"; else ok "a cwd outside the root is refused"; fi
if aib_contain_cwd "/srv/ws" "/srv/ws/../etc" >/dev/null 2>&1; then no "traversal out of the root is refused after resolution"; else ok "traversal out of the root is refused after resolution"; fi
eq "an absent cwd falls back to the derived root" "$(aib_contain_cwd "/srv/ws" "" && printf '%s' "$AIB_CWD_RESOLVED")" "/srv/ws"

# --- 6. the snapshot is the broker's, never the caller's (§2) ---------------
if printf 'op=launch\nagent_uid=acme-dev\nclearance=t4\nprompt_bytes=2\n\nhi' \
   | ( aib_wire_read_request ) >/dev/null 2>&1; then no "a caller cannot smuggle clearance across the seam"; else ok "a caller cannot smuggle clearance across the seam"; fi
if printf 'op=launch\nagent_uid=acme-dev\ncap_sandbox=danger-full-access\nprompt_bytes=2\n\nhi' \
   | ( aib_wire_read_request ) >/dev/null 2>&1; then no "a caller cannot smuggle a capability across the seam"; else ok "a caller cannot smuggle a capability across the seam"; fi

# --- 7. the handler answers with a verdict, not a blanket refusal -----------
# A fixture registry, written into $WORK and selected via AIBOBNET_REGISTRY — the
# actual override this codebase honours (not AIB_REGISTRY_FILE, which nothing reads).
# Schema 4, project home under $WORK (so aib_contain_cwd has a real derived root to
# resolve against), one provider carrying all four capabilities including cap_timeout.
FIXTURE_HOME="$WORK/home-acme"
mkdir -p "$FIXTURE_HOME"
FIXTURE_REG="$WORK/registry.json"
cat > "$FIXTURE_REG" <<JSON
{
  "schema_version": 4,
  "providers": {
    "acme": {
      "adapter": "/opt/acme/adapters/acme",
      "cap_sandbox": "workspace-write",
      "cap_tier": "t2",
      "cap_effort": "high",
      "cap_timeout": "900"
    },
    "acme-bad": {
      "adapter": "/opt/acme/adapters/acme-bad",
      "cap_sandbox": "workspace-write",
      "cap_tier": "bogus",
      "cap_effort": "high",
      "cap_timeout": "900"
    }
  },
  "projects": {
    "acme": {
      "home": "$FIXTURE_HOME",
      "standup_dir": "$WORK/standup",
      "mux_session": "acme",
      "provider": "acme",
      "model": "example-model",
      "effort": "medium"
    },
    "acme-bad": {
      "home": "$FIXTURE_HOME",
      "standup_dir": "$WORK/standup",
      "mux_session": "acme-bad",
      "provider": "acme-bad",
      "model": "example-model",
      "effort": "medium"
    }
  },
  "teams": {},
  "agents": {
    "acme-dev": { "project": "acme", "profile": "engine-dev", "clearance": "t2" },
    "acme-bad-baddev": { "project": "acme-bad", "profile": "engine-dev", "clearance": "t2" }
  }
}
JSON

# Assert the POSITIVE outcome, not the absence of a word. An earlier draft checked that
# "not_implemented" was gone and passed for the wrong reason: the parser rejected the new fields, so
# the handler never ran at all. A refusal upstream must not look like success downstream.
resp="$(frame2 "" "" "hallo" "op=launch" "agent_uid=acme-dev" | AIBOBNET_REGISTRY="$FIXTURE_REG" "$SRC_ROOT/bin/aib-broker-handler" 2>/dev/null)"
has "the handler returns a decision"                  "$resp" "decision="
has "…and terminates with a verdict, not an error"    "$resp" "end=ok"
hasnt "…and no longer refuses unconditionally"        "$resp" "not_implemented"
has "…and never mistakes a verdict for a launch"      "$resp" "enacted=no"

# ADDED (not in the original RED spec): a deny is `end=denied`, never `end=ok` — the
# earlier assertion only pins the allow path, and a handler that always said `end=ok`
# would still pass it. acme-bad-baddev resolves against a provider whose cap_tier is
# a well-formed but invalid JSON string ("bogus") — the resolver only requires the
# field to be present, so this reaches the PDP, which denies it (config, 2), exactly
# as tests/authorize_launch_spec.sh pins for a direct call ("invalid cap_tier").
resp="$(frame2 "" "" "hallo" "op=launch" "agent_uid=acme-bad-baddev" \
        | AIBOBNET_REGISTRY="$FIXTURE_REG" "$SRC_ROOT/bin/aib-broker-handler" 2>/dev/null)"
has "a PDP deny answers end=denied, not end=ok"        "$resp" "end=denied"
has "…and the decision says deny"                      "$resp" "decision=deny"

# ADDED: cwd outside the registry-derived root is a rejection at the seam, distinct
# from a PDP deny — SPEC-wire-format's "cwd stops carrying authority".
resp="$(frame2 "/etc" "" "hallo" "op=launch" "agent_uid=acme-dev" \
        | AIBOBNET_REGISTRY="$FIXTURE_REG" "$SRC_ROOT/bin/aib-broker-handler" 2>/dev/null)"
has "a cwd outside the derived root is denied"         "$resp" "end=denied"
has "…naming the reason"                               "$resp" "reason=cwd_outside_root"

# ADDED: the /srv/ws2 boundary case (a path-component boundary, not a string prefix)
# reproduced through the handler end-to-end, against the fixture's own derived root.
resp="$(frame2 "${FIXTURE_HOME}2" "" "hallo" "op=launch" "agent_uid=acme-dev" \
        | AIBOBNET_REGISTRY="$FIXTURE_REG" "$SRC_ROOT/bin/aib-broker-handler" 2>/dev/null)"
has "a sibling directory sharing the root's string prefix is still outside it" \
  "$resp" "reason=cwd_outside_root"

# --- 8. the transport failure domain is distinguishable from a denial -------
# A denial is a decision; a broker that cannot decide is an incident. A caller that cannot tell
# them apart will retry a denial or accept an outage as a refusal. AIBOBNET_REGISTRY is the real
# override (AIB_REGISTRY_FILE, used in an earlier draft, is honoured by nothing in this codebase).
resp="$(printf 'op=launch\nagent_uid=acme-dev\nprompt_bytes=2\n\nhi' | AIBOBNET_REGISTRY=/nonexistent "$SRC_ROOT/bin/aib-broker-handler" 2>/dev/null)"
has "an unreachable registry answers error, not denied" "$resp" "end=error"
has "…naming the reason"                                "$resp" "reason=registry_unavailable"

# ADDED: an agent_uid absent from an otherwise-healthy registry is a denial, not an
# incident — the broker CAN decide, and the decision is no.
resp="$(frame2 "" "" "hallo" "op=launch" "agent_uid=acme-ghost" \
        | AIBOBNET_REGISTRY="$FIXTURE_REG" "$SRC_ROOT/bin/aib-broker-handler" 2>/dev/null)"
has "an unknown agent_uid answers denied, not error"    "$resp" "end=denied"
has "…naming the reason"                                "$resp" "reason=unknown_agent"

printf '\nbroker_authorize_spec: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
