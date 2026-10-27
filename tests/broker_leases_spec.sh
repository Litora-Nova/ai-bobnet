#!/usr/bin/env bash
# ai-bobnet — RED spec for the broker's read-only `leases` op and `.sup.` lease names
# (Supervisor slice S1a-1).
#
# WHAT THIS PINS
#   A supervisor that restarts must learn whether a provider turn it started before the crash is
#   still running, WITHOUT a second source of truth and without the broker leaking anything else.
#
#   - `op=leases` + `agent_uid=<label>` answers `supervised=<n>` and `other=<m>`: the number of
#     LIVE (flock-held) leases for that label only, split into supervised (`<uid>.sup.<n>`) and
#     other (`<uid>.<n>`). Nothing else about the broker, other agents or the registry appears.
#   - It is read-only: it creates no lease, does not count toward capacity, and still answers when
#     the pool is full.
#   - A supervised launch request creates `<uid>.sup.<n>` instead of `<uid>.<n>`; the stale-lease
#     sweep and the live count recognise the new name; garbage names are still ignored.
#   - An unknown or malformed agent_uid fails exactly like `launch` does (denied/unknown_agent,
#     malformed_request).
#
#   Expected on the unbuilt tree: `leases` is an unknown operation (denied), the wire refuses the
#   supervised-launch field, and `.sup.` names are not leases to the sweep. Garbage-name and
#   plain-launch assertions already hold and are regression guards.
#
#   DESIGN POINT RESOLVED HERE (assumption, to be confirmed by the builder):
#     the request field marking a supervised launch is `lease_class=supervised` (token field,
#     allow-listed at the wire; any other value is refused as malformed_request).
set -uo pipefail
export AIB_TEST_SEAMS=1
export AIB_TEST_PEER_UID=0

SRC_ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
HANDLER="$SRC_ROOT/bin/aib-broker-handler"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-leases.XXXXXX")"
holders=()
cleanup() { local p; for p in "${holders[@]:-}"; do [ -z "$p" ] || kill "$p" 2>/dev/null; done; rm -rf "$WORK"; }
trap cleanup EXIT

pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
no(){ fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; }
eq(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2' want '$3')"; fi; }
has(){ if printf '%s\n' "$2" | grep -qxF -- "$3"; then ok "$1"; else no "$1 (missing line '$3')"; fi; }
hasnt(){ if printf '%s\n' "$2" | grep -qF -- "$3"; then no "$1 (unexpected '$3')"; else ok "$1"; fi; }

EVENT_ROOT="$WORK/events"; ATT="$EVENT_ROOT/attempts"
HOME_DIR="$WORK/home"; STANDUP="$WORK/standup"
mkdir -p "$ATT" "$HOME_DIR" "$STANDUP"
REG="$WORK/registry.json"
cat > "$REG" <<JSON
{
  "schema_version": 4,
  "providers": { "acme": { "adapter": "$SRC_ROOT/adapters/codex", "cap_sandbox": "workspace-write",
                           "cap_tier": "t2", "cap_effort": "high", "cap_timeout": "900" } },
  "projects": { "acme": { "home": "$HOME_DIR", "standup_dir": "$STANDUP", "mux_session": "acme",
                          "provider": "acme", "model": "team/model-v2", "effort": "low" } },
  "teams": { "acme-engine": { "project": "acme", "model": "team/model-v2" } },
  "agents": {
    "acme-core":  { "project": "acme", "team_uid": "acme-engine", "profile": "engine-dev", "clearance": "t2", "effort": "high" },
    "acme-other": { "project": "acme", "team_uid": "acme-engine", "profile": "engine-dev", "clearance": "t2", "effort": "high" }
  }
}
JSON

# send <registry> <capacity> <record-line>...  (prompt_bytes=0 frame) -> stdout = response; RC = handler rc
RC=0
send() {
  local reg="$1" cap="$2" r; shift 2
  { for r in "$@"; do printf '%s\n' "$r"; done; printf 'prompt_bytes=0\n\n'; } \
    | env -i PATH="$PATH" AIBOBNET_REGISTRY="$reg" AIB_EVENT_ROOT="$EVENT_ROOT" AIB_BROKER_CAPACITY="$cap" \
        "$HANDLER" 2>/dev/null
}
run() { RC=0; OUT="$(send "$@")" || RC=$?; }

hold() { # hold <lease-name> — a live (flock-held) lease file, as a running turn would hold
  local f="$ATT/$1" i
  ( exec 9>>"$f"; flock -x 9; exec sleep 300 ) & holders+=("$!")
  for ((i=0;i<150;i++)); do ( exec 8>>"$f"; flock -n 8 ) || return 0; sleep .02; done
  no "setup: lease $1 became live"
}
lease_names() { ( cd "$ATT" && ls -A 2>/dev/null | grep -vE '^(attempts\.lock|\.live)' | sort | tr '\n' ' ' ); }

# --- T13 the leases op -------------------------------------------------------
hold acme-core.sup.0; hold acme-core.sup.1; hold acme-core.0
hold acme-other.0; hold acme-other.sup.0
: > "$ATT/acme-core.sup.5"       # stale (nobody holds it): not live, must not be counted
before="$(lease_names)"
run "$REG" 20 op=leases agent_uid=acme-core
eq "T13: leases answers ok (rc 0)" "$RC" 0
has "T13: supervised = live sup leases of that label only" "$OUT" "supervised=2"
has "T13: other = live plain leases of that label only" "$OUT" "other=1"
has "T13: terminal line is end=ok" "$OUT" "end=ok"
eq "T13: exactly supervised, other, end — no other data" "$(printf '%s\n' "$OUT" | grep -v '^$' | sed 's/=.*//' | sort | tr '\n' ' ')" "end other supervised "
hasnt "T13: other agents' labels are not mentioned" "$OUT" "acme-other"
run "$REG" 20 op=leases agent_uid=acme-other
has "T13: another label sees its own count (supervised=1)" "$OUT" "supervised=1"
has "T13: …and its own other count (other=1)" "$OUT" "other=1"
# read-only: no lease created, none removed by this op
eq "T13: the op creates no lease file" "$(lease_names | tr ' ' '\n' | grep -c 'acme-core.sup.5')" 1
after="$(lease_names)"
eq "T13: the set of lease files is unchanged by the op" "$after" "$before"

# at capacity the op still answers, and it never takes a slot
run "$REG" 5 op=leases agent_uid=acme-core
has "T13: works when the pool is full (live=5 >= capacity 5)" "$OUT" "supervised=2"
run /nonexistent 5 op=launch agent_uid=acme-core
has "T13: …while a launch at the same moment is over_capacity" "$OUT" "reason=over_capacity"

# no live lease for a registered label: zeros, still ok
run "$REG" 20 op=leases agent_uid=acme-other
run "$REG" 20 op=leases agent_uid=acme-core
for p in "${holders[@]}"; do kill "$p" 2>/dev/null; done; wait 2>/dev/null; holders=()
run "$REG" 20 op=leases agent_uid=acme-core
has "T13: nothing live -> supervised=0" "$OUT" "supervised=0"
has "T13: nothing live -> other=0" "$OUT" "other=0"
find "$ATT" -mindepth 1 -delete

# does not count toward capacity: three leases calls, then a launch is still admitted to the registry stage
hold acme-other.0
for i in 1 2 3; do run "$REG" 2 op=leases agent_uid=acme-core; done
run /nonexistent 2 op=launch agent_uid=acme-core
has "T13: leases calls left no slot taken (launch passes admission, fails later at the registry)" "$OUT" "reason=registry_unavailable"
for p in "${holders[@]}"; do kill "$p" 2>/dev/null; done; wait 2>/dev/null; holders=()
find "$ATT" -mindepth 1 -delete

# --- T14 the .sup. name is a lease; garbage still is not ----------------------
: > "$ATT/acme-core.sup.3"        # stale supervised lease -> swept
: > "$ATT/acme-core.7"            # stale plain lease -> swept (baseline)
garbage=(acme-core.sup.x acme-core.sup. acme-core.sup.1.2 acme-core.supx.1 acme-core.sup Acme-core.sup.1 acme.sup.1 acme-core..sup.1 acme-core.sup.sup.1)
for g in "${garbage[@]}"; do : > "$ATT/$g"; done
run /nonexistent 20 op=launch agent_uid=acme-core
if [ -e "$ATT/acme-core.sup.3" ]; then no "T14: a stale <uid>.sup.<n> lease is swept"; else ok "T14: a stale <uid>.sup.<n> lease is swept"; fi
if [ -e "$ATT/acme-core.7" ]; then no "T14: a stale plain lease is still swept (baseline)"; else ok "T14: a stale plain lease is still swept (baseline)"; fi
for g in "${garbage[@]}"; do
  if [ -e "$ATT/$g" ]; then ok "T14: garbage name '$g' is left alone"; else no "T14: garbage name '$g' is left alone"; fi
done
find "$ATT" -mindepth 1 -delete
hold acme-core.sup.0
run /nonexistent 1 op=launch agent_uid=acme-other
has "T14: a LIVE .sup. lease counts toward capacity" "$OUT" "reason=over_capacity"
for p in "${holders[@]}"; do kill "$p" 2>/dev/null; done; wait 2>/dev/null; holders=()
find "$ATT" -mindepth 1 -delete

# --- T15 unknown / malformed uid fails exactly like launch -------------------
run "$REG" 20 op=launch agent_uid=acme-ghost;  l_rc=$RC; l_out="$OUT"
run "$REG" 20 op=leases agent_uid=acme-ghost
eq "T15: unknown uid -> same rc as launch" "$RC" "$l_rc"
has "T15: unknown uid -> end=denied" "$OUT" "end=denied"
has "T15: unknown uid -> reason=unknown_agent" "$OUT" "reason=unknown_agent"
hasnt "T15: …and no count is disclosed" "$OUT" "supervised="
run "$REG" 20 op=launch agent_uid="Not A Token";  l_rc=$RC
run "$REG" 20 op=leases agent_uid="Not A Token"
eq "T15: malformed uid -> same rc as launch" "$RC" "$l_rc"
has "T15: malformed uid -> reason=malformed_request" "$OUT" "reason=malformed_request"
run "$REG" 20 op=leases
has "T15: missing agent_uid -> end=error" "$OUT" "end=error"
hasnt "T15: …no count disclosed" "$OUT" "supervised="
# a registry that cannot be read is an incident, not an empty answer
run /nonexistent 20 op=leases agent_uid=acme-core
has "T15: unreadable registry -> reason=registry_unavailable (never zeros)" "$OUT" "reason=registry_unavailable"

# --- T16 lease naming by request class ---------------------------------------
find "$ATT" -mindepth 1 -delete
run /nonexistent 20 op=launch agent_uid=acme-core lease_class=supervised
eq "T16: a supervised launch creates <uid>.sup.0" "$(lease_names)" "acme-core.sup.0 "
find "$ATT" -mindepth 1 -delete
run /nonexistent 20 op=launch agent_uid=acme-core
eq "T16: a plain launch creates the old name <uid>.0" "$(lease_names)" "acme-core.0 "
find "$ATT" -mindepth 1 -delete
hold acme-core.sup.0
run /nonexistent 20 op=launch agent_uid=acme-core lease_class=supervised
has "T16: the next supervised lease takes the smallest free .sup. index" "$(lease_names | tr ' ' '\n')" "acme-core.sup.1"
run /nonexistent 20 op=launch agent_uid=acme-core
has "T16: a plain launch beside a live .sup.0 still takes <uid>.0 (separate namespace)" "$(lease_names | tr ' ' '\n')" "acme-core.0"
run /nonexistent 20 op=launch agent_uid=acme-core lease_class=bogus
has "T16: an unknown lease_class is refused at the wire" "$OUT" "reason=malformed_request"
for p in "${holders[@]}"; do kill "$p" 2>/dev/null; done; wait 2>/dev/null; holders=()

printf '\nbroker_leases_spec: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
