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

# ADDED (gate delta D1, Ikarus HIGH): a NUL byte in the body must never shift which
# bytes land in which declared block. `read -N n` drops a NUL from the variable
# WITHOUT counting it toward n, so it kept consuming input until n bytes were
# actually STORED — Ikarus' exact repro below returned cwd=A label=B prompt=C, rc=0,
# against a body that declared 3 bytes and carried 4 (`\0ABC`).
if { printf 'op=launch\nagent_uid=acme-dev\ncwd_bytes=1\nlabel_bytes=1\nprompt_bytes=1\n\n'; printf '\0ABC'; } \
   | ( aib_wire_read_request ) >/dev/null 2>&1
then no "Ikarus' exact NUL-shift frame is refused"
else ok "Ikarus' exact NUL-shift frame is refused"
fi
if { printf 'op=launch\nagent_uid=acme-dev\nlabel_bytes=3\nprompt_bytes=2\n\n'; printf 'a\0bhi'; } \
   | ( aib_wire_read_request ) >/dev/null 2>&1
then no "a NUL inside a label-only frame is refused"
else ok "a NUL inside a label-only frame is refused"
fi
if { printf 'op=launch\nagent_uid=acme-dev\nprompt_bytes=3\n\n'; printf 'a\0b'; } \
   | ( aib_wire_read_request ) >/dev/null 2>&1
then no "a NUL inside a prompt-only frame is refused"
else ok "a NUL inside a prompt-only frame is refused"
fi

# ADDED (gate delta R1, Ikarus HIGH: same class as D1, the OTHER path through this
# function): a NUL inside a RECORD-LINE TOKEN was silently dropped by `read -r` per
# line, before the control-character check ever saw it — `agent_uid=acme-<NUL>dev`
# arrived as the different token "acme-dev". Ikarus' exact repro below returned
# rc=0 agent_uid=<acme-dev>.
if { printf 'op=launch\nagent_uid=acme-'; printf '\0'; printf 'dev\nprompt_bytes=2\n\nhi'; } \
   | ( aib_wire_read_request ) >/dev/null 2>&1
then no "Ikarus' exact NUL-in-record-line-token frame is refused"
else ok "Ikarus' exact NUL-in-record-line-token frame is refused"
fi
if { printf 'op=lau'; printf '\0'; printf 'nch\nagent_uid=acme-dev\nprompt_bytes=2\n\nhi'; } \
   | ( aib_wire_read_request ) >/dev/null 2>&1
then no "a NUL inside the op= token is refused"
else ok "a NUL inside the op= token is refused"
fi
if { printf 'op=launch\nagent_uid=acme-dev\nprompt_bytes=1'; printf '\0'; printf '\n\nhi'; } \
   | ( aib_wire_read_request ) >/dev/null 2>&1
then no "a NUL inside a _bytes header value is refused"
else ok "a NUL inside a _bytes header value is refused"
fi

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
# RM-3 slice 2 delta (gate finding, Ikarus D2): aib_contain_cwd now resolves with
# `realpath -e` (existence required), so every fixture here is a REAL directory under
# $WORK — a literal "/srv/ws" that does not exist on the test host would now be
# refused not_found before the containment question is ever reached.
CONTAIN_ROOT="$WORK/contain-root"
mkdir -p "$CONTAIN_ROOT/sub"
# A real, existing directory OUTSIDE $CONTAIN_ROOT (an ancestor of it, under $WORK) —
# stands in for the old "/etc" in the outside-the-root case.
CONTAIN_OUTSIDE="$WORK/contain-outside"
mkdir -p "$CONTAIN_OUTSIDE"

eq "a cwd inside the derived root is accepted" \
  "$(aib_contain_cwd "$CONTAIN_ROOT" "$CONTAIN_ROOT/sub" && printf '%s' "$AIB_CWD_RESOLVED")" \
  "$CONTAIN_ROOT/sub"
if aib_contain_cwd "$CONTAIN_ROOT" "$CONTAIN_OUTSIDE" >/dev/null 2>&1; then no "a cwd outside the root is refused"; else ok "a cwd outside the root is refused"; fi
if aib_contain_cwd "$CONTAIN_ROOT" "$CONTAIN_ROOT/sub/../../contain-outside" >/dev/null 2>&1
then no "traversal out of the root is refused after resolution"
else ok "traversal out of the root is refused after resolution"
fi
eq "an absent cwd falls back to the derived root" \
  "$(aib_contain_cwd "$CONTAIN_ROOT" "" && printf '%s' "$AIB_CWD_RESOLVED")" "$CONTAIN_ROOT"

# ADDED (gate delta D2): a cwd that does not exist yet is refused, not lexically
# accepted — this is the "cwd exists" assurance moving behind the seam.
if aib_contain_cwd "$CONTAIN_ROOT" "$CONTAIN_ROOT/does-not-exist" >/dev/null 2>&1
then no "a nonexistent cwd is refused"
else ok "a nonexistent cwd is refused"
fi
eq "…and the reason is not_found" \
  "$( aib_contain_cwd "$CONTAIN_ROOT" "$CONTAIN_ROOT/does-not-exist" >/dev/null 2>&1; printf '%s' "$AIB_CONTAIN_CWD_REASON" )" \
  "not_found"

# ADDED (gate delta D2): a symlink INSIDE the root that points OUTSIDE it is refused
# — realpath -e fully resolves the symlink, so the comparison is against the real
# target, never the string path of the link itself.
ln -s "$CONTAIN_OUTSIDE" "$CONTAIN_ROOT/link-out"
if aib_contain_cwd "$CONTAIN_ROOT" "$CONTAIN_ROOT/link-out" >/dev/null 2>&1
then no "a symlink inside the root pointing outside it is refused"
else ok "a symlink inside the root pointing outside it is refused"
fi

# ADDED (gate delta D2): a symlink INSIDE the root that points to somewhere else
# INSIDE the root is accepted, resolved to its real target (not the link's own path).
mkdir -p "$CONTAIN_ROOT/real-target"
ln -s "$CONTAIN_ROOT/real-target" "$CONTAIN_ROOT/link-in"
eq "a symlink inside the root pointing inside it is accepted, resolved" \
  "$(aib_contain_cwd "$CONTAIN_ROOT" "$CONTAIN_ROOT/link-in" && printf '%s' "$AIB_CWD_RESOLVED")" \
  "$CONTAIN_ROOT/real-target"

# ADDED (gate delta D3): root "/" must accept its own descendants — the naive
# "$resolved_root/*" pattern built "//*" for root "/", which nothing starting with a
# single "/" can ever match.
eq "root / accepts a real descendant (D3)" \
  "$(aib_contain_cwd / /etc && printf '%s' "$AIB_CWD_RESOLVED")" "/etc"

# --- 5b. required fields at the wire (gate delta D6, Riker MEDIUM) ----------
# A frame missing `agent_uid` or `op` used to pass the wire and only fail three
# layers downstream (as a resolver "incident" or a handler "unknown_operation") — a
# caller mistake reported as if the broker itself could not decide something.
if printf 'op=launch\nprompt_bytes=2\n\nhi' | ( aib_wire_read_request ) >/dev/null 2>&1
then no "a frame without agent_uid is refused at the wire"
else ok "a frame without agent_uid is refused at the wire"
fi
if printf 'agent_uid=acme-dev\nprompt_bytes=2\n\nhi' | ( aib_wire_read_request ) >/dev/null 2>&1
then no "a frame without op is refused at the wire"
else ok "a frame without op is refused at the wire"
fi

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
# A REAL sibling directory sharing FIXTURE_HOME's string prefix (D2/gate delta:
# aib_contain_cwd now requires existence, so a boundary fixture must exist too, or
# it is refused not_found before the boundary check is ever reached).
mkdir -p "${FIXTURE_HOME}2"
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
    "acme-bad-baddev": { "project": "acme-bad", "profile": "engine-dev", "clearance": "t2" },
    "acme-orphan": { "project": "no-such-project", "profile": "engine-dev", "clearance": "t2" },
    "acme-badclr": { "project": "acme", "profile": "engine-dev", "clearance": "bogus" }
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

# ADDED (gate delta D2): a cwd that does not exist is a DIFFERENT denial from one
# outside the root — the handler must not collapse the two into one reason string.
resp="$(frame2 "${FIXTURE_HOME}/does-not-exist" "" "hallo" "op=launch" "agent_uid=acme-dev" \
        | AIBOBNET_REGISTRY="$FIXTURE_REG" "$SRC_ROOT/bin/aib-broker-handler" 2>/dev/null)"
has "a nonexistent cwd is denied through the handler" "$resp" "end=denied"
has "…naming the reason distinctly"                   "$resp" "reason=cwd_not_found"

# ADDED: the /srv/ws2 boundary case (a path-component boundary, not a string prefix)
# reproduced through the handler end-to-end, against the fixture's own derived root.
resp="$(frame2 "${FIXTURE_HOME}2" "" "hallo" "op=launch" "agent_uid=acme-dev" \
        | AIBOBNET_REGISTRY="$FIXTURE_REG" "$SRC_ROOT/bin/aib-broker-handler" 2>/dev/null)"
has "a sibling directory sharing the root's string prefix is still outside it" \
  "$resp" "reason=cwd_outside_root"

# ADDED (should-fix LOW, Riker): unknown_operation now exits 3 like every other
# denied answer in this handler — it was the one leftover from slice 1 still exiting 2.
resp="$(printf 'op=frobnicate\nagent_uid=acme-dev\nprompt_bytes=2\n\nhi' \
        | "$SRC_ROOT/bin/aib-broker-handler" 2>/dev/null)"; op_rc=$?
has "an unrecognised op is denied"                       "$resp" "reason=unknown_operation"
eq "…and exits 3, matching every other denied answer"    "$op_rc" "3"

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

# ADDED (gate delta D5, Marvin surviving mutant): the handler's registry_config
# mapping (bin/aib-broker-handler, the rc=3-non-"unknown agent_uid" branch AND the
# catch-all "*" branch) had no assertion standing guard on it — swapping `error` for
# `denied` on either line passed the whole 22-file suite unchanged. Two distinct
# fixtures reach the two distinct lines: an agent naming a project the registry does
# not have (rc=3, message names an unknown PROJECT, not an unknown AGENT — the exact
# other branch of the overloaded exit code 3), and an agent whose clearance is a
# well-formed but invalid token (rc=4, the true catch-all, neither 2 nor 3).
resp="$(frame2 "" "" "hallo" "op=launch" "agent_uid=acme-orphan" \
        | AIBOBNET_REGISTRY="$FIXTURE_REG" "$SRC_ROOT/bin/aib-broker-handler" 2>/dev/null)"
has "an agent naming an unknown project answers error, not denied" "$resp" "end=error"
has "…naming the reason (rc=3, not-unknown-agent-uid branch)"      "$resp" "reason=registry_config"

resp="$(frame2 "" "" "hallo" "op=launch" "agent_uid=acme-badclr" \
        | AIBOBNET_REGISTRY="$FIXTURE_REG" "$SRC_ROOT/bin/aib-broker-handler" 2>/dev/null)"
has "an agent with an invalid clearance token answers error, not denied" "$resp" "end=error"
has "…naming the reason (rc=4, the catch-all branch)"                    "$resp" "reason=registry_config"

# ADDED (gate delta D5): a registry containing a raw NUL byte is the OTHER half of
# "registry unavailable" (Marvin, LOW: hand-verified correct but previously unpinned)
# — a distinct rc=2 codepath (_aib_load_registry_snapshot's NUL guard) from the
# missing-file case already covered above.
NUL_REG="$WORK/nul-registry.json"
printf '{"schema_version"' > "$NUL_REG"
printf '\0' >> "$NUL_REG"
printf ': 4}' >> "$NUL_REG"
resp="$(frame2 "" "" "hallo" "op=launch" "agent_uid=acme-dev" \
        | AIBOBNET_REGISTRY="$NUL_REG" "$SRC_ROOT/bin/aib-broker-handler" 2>/dev/null)"
has "a NUL-byte registry answers error, not denied" "$resp" "end=error"
has "…naming the reason"                            "$resp" "reason=registry_unavailable"

# --- 9. wire/PDP boundary coverage (should-fix MEDIUM, Marvin) --------------
# The gate audit found the slice-2 wire additions covered on the happy paths and the
# smuggling checks, but not at their declared boundaries. Every value below is
# constructed, never guessed, so a future change to any of the four limits fails
# exactly the assertion that names it.
rep(){ printf "%${1}s" '' | tr ' ' a; }

lbl256="$(rep 256)"; lbl257="$(rep 257)"
out="$(frame2 "" "$lbl256" "hi" "op=launch" "agent_uid=acme-dev" \
       | { aib_wire_read_request && printf '%s' "$AIB_REQ_LABEL"; })"
eq "label at exactly AIB_WIRE_LABEL_MAX (256) is accepted" "${#out}" "256"
if frame2 "" "$lbl257" "hi" "op=launch" "agent_uid=acme-dev" | ( aib_wire_read_request ) >/dev/null 2>&1
then no "label one over AIB_WIRE_LABEL_MAX (257) is refused"
else ok "label one over AIB_WIRE_LABEL_MAX (257) is refused"
fi

cwd4096="$(rep 4096)"; cwd4097="$(rep 4097)"
out="$(frame2 "$cwd4096" "" "hi" "op=launch" "agent_uid=acme-dev" \
       | { aib_wire_read_request && printf '%s' "$AIB_REQ_CWD"; })"
eq "cwd at exactly AIB_WIRE_CWD_MAX (4096) is accepted" "${#out}" "4096"
if frame2 "$cwd4097" "" "hi" "op=launch" "agent_uid=acme-dev" | ( aib_wire_read_request ) >/dev/null 2>&1
then no "cwd one over AIB_WIRE_CWD_MAX (4097) is refused"
else ok "cwd one over AIB_WIRE_CWD_MAX (4097) is refused"
fi

out="$(printf 'op=launch\nagent_uid=acme-dev\ntimeout=86400\nprompt_bytes=2\n\nhi' \
       | { aib_wire_read_request && printf '%s' "$AIB_REQ_TIMEOUT"; })"
eq "timeout at exactly AIB_WIRE_TIMEOUT_MAX (86400) is accepted" "$out" "86400"
if printf 'op=launch\nagent_uid=acme-dev\ntimeout=86401\nprompt_bytes=2\n\nhi' \
   | ( aib_wire_read_request ) >/dev/null 2>&1
then no "timeout one over AIB_WIRE_TIMEOUT_MAX (86401) is refused"
else ok "timeout one over AIB_WIRE_TIMEOUT_MAX (86401) is refused"
fi
if printf 'op=launch\nagent_uid=acme-dev\ntimeout=0\nprompt_bytes=2\n\nhi' \
   | ( aib_wire_read_request ) >/dev/null 2>&1
then no "timeout=0 is refused at the wire (must be positive)"
else ok "timeout=0 is refused at the wire (must be positive)"
fi

# explicit <field>_bytes=0 vs the header being absent entirely (SPEC-wire-format,
# "Two edges" — the code comments call this out; nothing pinned it by name).
out_absent="$(printf 'op=launch\nagent_uid=acme-dev\nprompt_bytes=2\n\nhi' \
              | { aib_wire_read_request && printf '[%s]' "${AIB_REQ_CWD:-}"; })"
out_explicit0="$(printf 'op=launch\nagent_uid=acme-dev\ncwd_bytes=0\nprompt_bytes=2\n\nhi' \
                 | { aib_wire_read_request && printf '[%s]' "${AIB_REQ_CWD:-}"; })"
eq "explicit cwd_bytes=0 behaves exactly like an absent header" "$out_explicit0" "$out_absent"
out_absent_lbl="$(printf 'op=launch\nagent_uid=acme-dev\nprompt_bytes=2\n\nhi' \
                   | { aib_wire_read_request && printf '[%s]' "${AIB_REQ_LABEL:-}"; })"
out_explicit0_lbl="$(printf 'op=launch\nagent_uid=acme-dev\nlabel_bytes=0\nprompt_bytes=2\n\nhi' \
                      | { aib_wire_read_request && printf '[%s]' "${AIB_REQ_LABEL:-}"; })"
eq "explicit label_bytes=0 behaves exactly like an absent header" "$out_explicit0_lbl" "$out_absent_lbl"

# a repeated <field>_bytes header on one of the NEW slice-2 fields specifically —
# broker_wire_spec.sh only pins this generically, presumably on op/agent_uid.
if printf 'op=launch\nagent_uid=acme-dev\ncwd_bytes=1\ncwd_bytes=1\nprompt_bytes=2\n\nXhi' \
   | ( aib_wire_read_request ) >/dev/null 2>&1
then no "a repeated cwd_bytes header is refused"
else ok "a repeated cwd_bytes header is refused"
fi

# absent sandbox at the wire-reader UNIT level (section 7 only verified this
# indirectly, end-to-end, via the handler's own read-only default).
out="$(printf 'op=launch\nagent_uid=acme-dev\nprompt_bytes=2\n\nhi' \
       | { aib_wire_read_request && printf '[%s]' "${AIB_REQ_SANDBOX:-}"; })"
eq "an absent sandbox comes back empty at the wire-reader level" "$out" "[]"

# cap_timeout absent / non-numeric fed directly to a hand-built snapshot record, the
# way authorize_launch_spec.sh already does for cap_sandbox/cap_tier/cap_effort —
# broker_authorize_spec.sh had only ever exercised a VALID cap_timeout via the
# resolver end-to-end.
boundary_req="agent_uid=acme-dev
sandbox=workspace-write
timeout=60"
snap_no_captimeout="clearance=t2
provider=acme
effort=medium
adapter=/opt/aib/adapters/acme
cap_sandbox=workspace-write
cap_tier=t2
cap_effort=high"
aib_authorize_launch "$boundary_req" "$snap_no_captimeout" >/dev/null 2>&1
eq "an absent cap_timeout denies config (2)" "${AIB_VERDICT_CODE:-}" "2"
snap_bad_captimeout="${snap_no_captimeout}
cap_timeout=bogus"
aib_authorize_launch "$boundary_req" "$snap_bad_captimeout" >/dev/null 2>&1
eq "a non-numeric cap_timeout denies config (2)" "${AIB_VERDICT_CODE:-}" "2"

# timeout exactly equal to cap_timeout: not "over" (must not clamp/note), not
# "absent" (must not silently take the cap by the absent-branch instead) — only
# over-cap and under-cap were pinned before this.
snap_cap900="${snap_no_captimeout}
cap_timeout=900"
req_at_cap="${boundary_req/timeout=60/timeout=900}"
aib_authorize_launch "$req_at_cap" "$snap_cap900" >/dev/null 2>&1
eq "timeout exactly at the cap is left alone"      "${AIB_VERDICT_EFFECTIVE_TIMEOUT:-}" "900"
hasnt "…and no clamp is reported for an exact match" "${AIB_VERDICT_REASONS:-}" "timeout"

printf '\nbroker_authorize_spec: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
