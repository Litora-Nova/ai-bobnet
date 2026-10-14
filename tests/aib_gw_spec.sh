#!/usr/bin/env bash
# ai-bobnet — RED spec for bin/aib-gw, the forced-command gateway seam (Supervisor slice S1b; design B11, hermes-gw lineage).
# Whether an external comms hub calls it is E7's decision; this slice only builds and pins the seam.
#
# WHAT THIS PINS
#   Invocation: the gateway account's authorized_keys says `command="aib-gw --id <peer>"`; the wanted command arrives in
#   $SSH_ORIGINAL_COMMAND as ONE line. Seams: AIB_AGENTCTL (command to hand off to; default <repo>/bin/agentctl),
#   AIB_GW_PEERS (file, one allowed peer id per line; missing/unreadable/empty = nobody is allowed), AIB_CONTROL_LOG,
#   AIB_IDENTITY_CMD (the audit `caller` of a refusal).
#   Accepted forms, exactly:  status <uid> | standup <uid> | feierabend <uid> | neustart <uid> | say <uid> <text...>
#     - handed to agentctl as argv `verb uid` (say: `say uid text`, the text VERBATIM as ONE argument: runs of spaces, `*`, `$HOME`,
#       `;`, backticks and quotes stay literal, nothing is globbed or evaluated — `set -f`, no eval), with env AIBOBNET_ACTOR=gateway-peer:<id>.
#     - agentctl's exit code is the gateway's exit code.
#   Refused (agentctl is NOT called; the refusal is audited as ctl.rejected with actor gateway-peer:<id> and caller from the
#   identity command):
#     - 77  verb not on the whitelist — abschalten, start, reset-brake, attach, anything else, also in another case (`STATUS`);
#           reason `gateway_verb_denied`.  abschalten is never reachable, with or without flags.
#     - 77  peer id not in AIB_GW_PEERS (or no list at all); reason `gateway_peer_denied`.
#     - 64  malformed: no/empty SSH_ORIGINAL_COMMAND, [no `--id` / an id outside [a-z0-9_-]{1,32}: 64 too, but unattributable so not audited], a uid outside
#           [a-z0-9]+(-[a-z0-9]+)+, a missing uid, extra tokens after a non-say verb (flags included), a newline or NUL or other
#           control character anywhere, command or say-text longer than 4096 bytes, an empty say text; reason `gateway_malformed`.
#   Never executes anything from the command string: `status $(touch PWNED)` is just malformed.
#
#   Expected on the unbuilt tree: bin/aib-gw does not exist.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/fixtures/ctl_harness.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-gw.XXXXXX")"
trap sup_cleanup EXIT
ctl_world gw; as gateway:gw
printf 'hub1\nhub2\n' > "$W/peers"
cat > "$W/fakes/agentctl" <<'FAKE'
#!/usr/bin/env bash
w=$(cd -P "$(dirname "$0")/.." && pwd)
{ printf 'ARGC=%s\n' "$#"; for a in "$@"; do printf 'ARG=%s\n' "$a"; done; printf 'ACTOR=%s\n---\n' "${AIBOBNET_ACTOR:-}"; } >> "$w/agentctl.calls"
exit "$(cat "$w/agentctl.rc" 2>/dev/null || echo 0)"
FAKE
chmod +x "$W/fakes/agentctl"
mkdir -p "$W/cwd"; : > "$W/cwd/file-a"; : > "$W/cwd/file-b"
gw() { # gw <peer-args> <command-string>   (the command goes in SSH_ORIGINAL_COMMAND)
  local peerargs="$1" cmd="$2"; : > "$W/agentctl.calls"; : > "$CLOG"; rm -f "$W/cwd/PWNED"
  RC=0; OUT="$(cd "$W/cwd" && env -i PATH="$W/fakebin:$PATH" HOME="$W/home-ctl" LANG=C "${CTLENV[@]}" AIB_AGENTCTL="$W/fakes/agentctl" \
      AIB_GW_PEERS="${GWPEERS:-$W/peers}" SSH_ORIGINAL_COMMAND="$cmd" timeout 20 "$ENGINE/bin/aib-gw" $peerargs 2>"$W/gw.err")" || RC=$?
  ERR="$(cat "$W/gw.err")"; CALLS="$(cat "$W/agentctl.calls")"
}
nocall() { [ -z "$CALLS" ]; }

# --- T1 whitelisted verbs are handed to agentctl, nothing else changes --------------------------------
for v in status standup feierabend neustart; do
  gw "--id hub1" "$v acme-core"
  eq "T1: '$v acme-core' => rc 0" "$RC" 0
  eq "T1: …argv is exactly '$v acme-core', actor gateway-peer:hub1" "$CALLS" "ARGC=2
ARG=$v
ARG=acme-core
ACTOR=gateway-peer:hub1
---"
done
printf '3\n' > "$W/agentctl.rc"; gw "--id hub2" "status acme-sib"
eq "T1: agentctl's exit code is the gateway's (3)" "$RC" 3
eq "T1: …actor names the peer (hub2)" "$(printf '%s' "$CALLS" | grep '^ACTOR=')" "ACTOR=gateway-peer:hub2"
rm -f "$W/agentctl.rc"

# --- T2 say: the text is one literal argument ------------------------------------------------------------------
txt='hello  "world" $HOME `id` ; * ?  > out | x'
gw "--id hub1" "say acme-core $txt"
eq "T2: say => rc 0" "$RC" 0
eq "T2: …argv: say, uid, the text verbatim as ONE argument (no glob, no expansion)" "$CALLS" "ARGC=3
ARG=say
ARG=acme-core
ARG=$txt
ACTOR=gateway-peer:hub1
---"
gw "--id hub1" "say acme-core \$(touch PWNED)"
eq "T2: a command substitution in say text is data: no file was created, text passed literally" "$([ ! -e "$W/cwd/PWNED" ] && echo clean)|$(printf '%s' "$CALLS" | grep -c 'ARG=\$(touch PWNED)')" "clean|1"

# --- T3 the whitelist: abschalten and friends are unreachable ------------------------------------------------------
for c in "abschalten acme-core" "abschalten acme-core --force" "start acme-core" "reset-brake acme-core" "attach acme-core" "STATUS acme-core" \
         "frobnicate acme-core" "bash -c id" "/bin/sh" "rm -rf /"; do
  gw "--id hub1" "$c"
  eq "T3: '$c' => 77" "$RC" 77
  eq "T3: …agentctl not called, refusal audited gateway_verb_denied (actor hub1)" "$([ -z "$CALLS" ] && echo uncalled)|$(cf ctl.rejected -1 reason)|$(cf ctl.rejected -1 actor)" "uncalled|gateway_verb_denied|gateway-peer:hub1"
done
eq "T3: …the refusal's caller comes from the identity command" "$(cf ctl.rejected -1 caller)" "gateway:gw"

# --- T4 peers --------------------------------------------------------------------------------------------------------------
gw "--id mallory" "status acme-core"
eq "T4: a peer not in the allow-list => 77 gateway_peer_denied, agentctl not called" "$RC|$([ -z "$CALLS" ] && echo uncalled)|$(cf ctl.rejected -1 reason)" "77|uncalled|gateway_peer_denied"
GWPEERS="$W/no-such-file" gw "--id hub1" "status acme-core"
eq "T4: no allow-list file => nobody is allowed (77)" "$RC|$([ -z "$CALLS" ] && echo uncalled)" "77|uncalled"
: > "$W/empty-peers"; GWPEERS="$W/empty-peers" gw "--id hub1" "status acme-core"
eq "T4: an empty allow-list => nobody is allowed (77)" "$RC|$([ -z "$CALLS" ] && echo uncalled)" "77|uncalled"
printf 'hub1\n' > "$W/peers1"; GWPEERS="$W/peers1" gw "--id hub" "status acme-core"
eq "T4: a peer id is matched whole, not as a prefix (hub vs hub1)" "$RC" 77
GWPEERS="" ; unset GWPEERS

# --- T5 malformed input -------------------------------------------------------------------------------------------------------
mal() { # mal <label> <peer-args> <cmd>
  gw "$2" "$3"
  eq "T5: $1 => 64" "$RC" 64
  eq "T5: …agentctl not called, audited gateway_malformed" "$([ -z "$CALLS" ] && echo uncalled)|$(cf ctl.rejected -1 reason)" "uncalled|gateway_malformed"
}
mal "empty command" "--id hub1" ""
mal "no uid" "--id hub1" "status"
mal "bad uid" "--id hub1" "status ACME"
mal "uid with a semicolon" "--id hub1" "status acme-core;id"
mal "extra token after a non-say verb" "--id hub1" "status acme-core extra"
mal "flags are not accepted (neustart --hard)" "--id hub1" "neustart acme-core --hard"
mal "command substitution as uid" "--id hub1" 'status $(touch PWNED)'
mal "say with an empty text" "--id hub1" "say acme-core"
mal "embedded newline" "--id hub1" "$(printf 'status acme-core\nneustart acme-sib')"
mal "tab control character" "--id hub1" "$(printf 'say acme-core a\tb')"
mal "escape control character" "--id hub1" "$(printf 'say acme-core a\033[2Jb')"
mal "over-long command (>4096 bytes)" "--id hub1" "say acme-core $(head -c 5000 /dev/zero | tr '\0' x)"
gw "--id hub1" "say acme-core $(head -c 4000 /dev/zero | tr '\0' x)"
eq "T5: a 4000-byte say text is under the cap and goes through (and nothing was created)" "$RC|$([ ! -e "$W/cwd/PWNED" ] && echo clean)" "0|clean"
mal_unattributable() { # no usable peer id => nothing to attribute: refused with 64, agentctl not called (audit not required)
  gw "$2" "$3"; eq "T5: $1 => 64, agentctl not called" "$RC|$([ -z "$CALLS" ] && echo uncalled)" "64|uncalled"
}
mal_unattributable "no --id" "" "status acme-core"
mal_unattributable "empty --id" "--id ''" "status acme-core"
mal_unattributable "id with a slash" "--id ../x" "status acme-core"
gw "--id hub1 --extra" "status acme-core"
eq "T5: an unknown gateway option => 64" "$RC" 64
env -i PATH="$W/fakebin:$PATH" "${CTLENV[@]}" AIB_AGENTCTL="$W/fakes/agentctl" AIB_GW_PEERS="$W/peers" "$ENGINE/bin/aib-gw" --id hub1 >/dev/null 2>&1 </dev/null; rc=$?
eq "T5: SSH_ORIGINAL_COMMAND unset (an interactive login attempt) => 64" "$rc" 64

printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
