#!/usr/bin/env bash
# ai-bobnet — RED spec for what the broker's run_confined (aib_enact_launch, confined mode) hands the provider in S1c: a per-agent HOME,
# the role-account switch arguments, and the credential mode (Supervisor slice S1c; design v3 G7, v3.1 H1/H2, v3.2 J1/J2, E9).
# The child env is, as today, the PDP-verdict allow-list (AIB_VERDICT_ENV_ALLOW="HOME PATH" here) plus broker-derived extras.
# Same scaffold as tests/adapter_codex_spec.sh Block C: a stub confinement helper that logs how it is called, then execs the "adapter".
#
# WHAT THIS PINS (all new behaviour is conditional; with none of the new env set, Block C of adapter_codex_spec stays byte-identical)
#   Per-agent HOME. When AIB_SUP_STATE_ROOT is set (unit env; seam-gated like every seam: AIB_TEST_SEAMS=1 and no `.aib-installed`; production
#   default /var/lib/aib-sup) the confined provider chain gets
#       HOME=<AIB_SUP_STATE_ROOT>/<agent_uid>      agent_uid = the BROKER-validated envelope key `agent_uid` (never anything from the request record)
#   and the pre-flight + LL_RW use $HOME/<state_dir> of THAT home (so `.codex`/`.claude` history is per agent and never the broker's own).
#   An agent_uid outside [a-z0-9]+(-[a-z0-9]+)+, or a per-agent home / state dir that is missing or a symlink, refuses the launch before the
#   provider runs. A `home=`/`HOME=` key in the enact record is ignored (it cannot choose the home).
#   LL_RW never contains the shared login store (/var/lib/aib/login or AIB_LOGIN_ROOT); LL_RO stays `/` (the store is only READ, via the
#   symlink or the fd).
#   Role-account switch: when the broker unit sets AIB_ROLE_UID and AIB_ROLE_GID the helper is called as
#       <confine-bin> --uid <AIB_ROLE_UID> --gid <AIB_ROLE_GID> <adapter> ...     with AIB_ROLE_UIDS (the unit's allow-list) in the helper's env;
#   without them the argv has no such options and AIB_ROLE_UIDS is not passed.
#   Credential mode: the chain's env (besides HOME/PATH) gains, derived by the broker — never from the request —
#       AIB_TURN_TIMEOUT_S = the record's timeout          (always)
#       AIB_CREDENTIAL_MODE = accounts.<provider>.credential_mode of the deployment config ("file" when none), provider = the record key `provider`
#       shared:  AIB_LOGIN_STORE_PATH = <AIB_LOGIN_ROOT>/<provider>/<auth file of that provider>   (codex: auth.json)
#       fd:      the broker runs `bin/aib-login-token <provider> [--source <credential_source>]` (default source `login`), opens the token on fd 3 of the
#                helper/adapter chain (read-only, NOT inherited by anything else) and sets AIB_CREDENTIAL_FD=3. If the token tool refuses (exit != 0)
#                the provider is NOT started and the response shows a refusal (end=error or end=refused …) that contains no token.
#       proxy:   reserved (S1d): the provider is not started.
#
#   Expected on the unbuilt tree: run_confined keeps the broker's HOME, passes no role switch and no credential env.
set -uo pipefail
SRC_ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
. "$SRC_ROOT/lib/aibobnet.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aibobnet-rchome.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
no(){ fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; }
eq(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2' want '$3')"; fi; }
has(){ case "$2" in *"$3"*) ok "$1";; *) no "$1 (missing '$3' in: ${2:0:300})";; esac; }
hasnt(){ case "$2" in *"$3"*) no "$1 (unexpected '$3')";; *) ok "$1";; esac; }
SENT="SECRET-TOKEN-0123456789abcdef"

BROKER_HOME="$WORK/broker-home"; STATE_ROOT="$WORK/sup"; LROOT="$WORK/login"; PROJ="$WORK/project"; EV="$WORK/events"; STUB="$WORK/stub"
mkdir -p "$BROKER_HOME/.codex" "$STATE_ROOT/acme-core/.codex" "$STATE_ROOT/acme-core/.claude" "$LROOT/codex" "$LROOT/claude-code" "$PROJ" "$EV" "$STUB"
chmod 700 "$BROKER_HOME/.codex" "$STATE_ROOT/acme-core/.codex" "$STATE_ROOT/acme-core/.claude"
LOG="$WORK/ll.log"; PRIV="$WORK/provider-private"; mkdir -p "$PRIV"
cat > "$STUB/landlock-exec" <<'STUB'
#!/usr/bin/env bash
# logs how it is called, drops --uid/--gid like the real helper (without switching), execs the rest
{ printf 'ARGV=%s\n' "$*"; printf 'HOME=%s\nLL_RO=%s\nLL_RW=%s\nAIB_ROLE_UIDS=%s\n' "${HOME-<unset>}" "${LL_RO-<unset>}" "${LL_RW-<unset>}" "${AIB_ROLE_UIDS-<unset>}"; echo '---'; } >> "$(cd "$(dirname "$0")" && cat log.path)"
[ -z "${LL_STATUS_FD-}" ] || eval "exec ${LL_STATUS_FD}>&-"
if [ "${1-}" = --uid ]; then shift 4; fi
unset AIB_ROLE_UIDS
exec "$@"
STUB
echo "$LOG" > "$STUB/log.path"
cat > "$STUB/provider" <<'STUB'
#!/usr/bin/env bash
priv="$(cd "$(dirname "$0")" && cat priv.path)"
{ env | grep -E '^(HOME|AIB_[A-Z_]+)=' | sort; echo '---'; } >> "$priv/env.log"
fd="${AIB_CREDENTIAL_FD:-}"; if [ -n "$fd" ]; then eval "cat <&$fd" > "$priv/fd.content" 2>/dev/null; python3 -I -c 'import os; xs=os.listdir("/proc/self/fd"); print(" ".join(sorted((x for x in xs if os.path.exists("/proc/self/fd/"+x)),key=int)),end=" ")' > "$priv/fds"; fi
echo ran >> "$priv/ran"
exit 0
STUB
echo "$PRIV" > "$STUB/priv.path"; chmod +x "$STUB/landlock-exec" "$STUB/provider"
EVF="$EV/main.events"; EVL="$EV/main.events.lock"
KV() { printf 'project_uid=acme\nactor_type=service\nactor_id=aib-broker\nagent_uid=%s\nteam_uid=acme-engine\nsession_id=acme-broker' "${1:-acme-core}"; }
DEP="$WORK/deployment.json"
dep() { printf '{"deployment_id":"acme-dev-1","allow":{"customer_code":true,"comms_secrets":true},"accounts":%s}' "$1" > "$DEP"; chmod 644 "$DEP"; }
dep '{}'
launch() { # launch <agent_uid> <record-extra-lines> [VAR=val...]  -> RESP
  local uid="$1" extra="$2"; shift 2
  : > "$LOG"; rm -f "$PRIV/ran" "$PRIV/env.log" "$PRIV/fd.content" "$PRIV/fds"
  local kv decided payload rec
  kv="$(printf 'decision=allow\ncode=0\nreasons=\npid=%s\nprompt_len=1\nprompt_sha256=deadbeef' "$$")"
  payload="$(aib_event_compose_decided_payload "$kv")"
  aib_event_commit "$EVF" "$EVL" attempt.decided "$(KV "$uid")" "$payload" >/dev/null 2>&1; decided="$AIB_EVENT_COMMIT_EVENT_ID"
  rec="$(printf 'adapter=%s\nroot=%s\ncwd=%s\nsandbox=workspace-write\neffort=high\nmodel=team/model-v2\ntimeout=5%s' "$STUB/provider" "$PROJ" "$PROJ" "${extra:+$'\n'$extra}")"
  RESP="$(env HOME="$BROKER_HOME" AIB_VERDICT_ENV_ALLOW="HOME PATH" AIB_CONFINE_BIN="$STUB/landlock-exec" AIB_TEST_SEAMS=1 AIB_DEPLOYMENT_OWNER_UID="$(id -u)" AIB_DEPLOYMENT_CONFIG="$DEP" "$@" \
      bash -c '. "$1/lib/aibobnet.sh"; shift; aib_enact_launch "$@"' _ "$SRC_ROOT" "$rec" hello "$EVF" "$EVL" "$(KV "$uid")" "$decided" 2>"$WORK/err")"
}
ll_field() { grep "^$1=" "$LOG" | tail -1 | sed "s/^$1=//"; }
provider_ran() { [ -s "$PRIV/ran" ] && echo ran || echo not-run; }
penv() { grep -m1 "^$1=" "$PRIV/env.log" 2>/dev/null | cut -d= -f2-; }

# --- T1 per-agent HOME ---------------------------------------------------------------------------------------------------------------------------------
launch acme-core "" AIB_SUP_STATE_ROOT="$STATE_ROOT"
eq "T1: the confined chain runs with HOME=<state root>/<agent uid>, not the broker's" "$(ll_field HOME)|$(penv HOME)|$(provider_ran)" "$STATE_ROOT/acme-core|$STATE_ROOT/acme-core|ran"
has "T1: LL_RW carries the per-agent state dir" "$(ll_field LL_RW)" "$STATE_ROOT/acme-core/.codex"
hasnt "T1: …and not the broker's own .codex" "$(ll_field LL_RW)" "$BROKER_HOME/.codex"
launch acme-core "home=$WORK/evil
HOME=$WORK/evil" AIB_SUP_STATE_ROOT="$STATE_ROOT"
eq "T1: home=/HOME= keys in the enact record cannot choose the home" "$(ll_field HOME)" "$STATE_ROOT/acme-core"
for bad in '../x' 'ACME' 'a' 'acme core' 'acme-core/../acme-core'; do
  launch "$bad" "" AIB_SUP_STATE_ROOT="$STATE_ROOT"
  eq "T1: envelope agent_uid '$bad' => provider not started, chain not entered" "$(provider_ran)|$(grep -c ARGV "$LOG")" "not-run|0"
done
mkdir -p "$STATE_ROOT/acme-nostate"; launch acme-nostate "" AIB_SUP_STATE_ROOT="$STATE_ROOT"
eq "T1: an agent whose per-agent state dir is missing => refused, provider not started" "$(provider_ran)" not-run
ln -s "$STATE_ROOT/acme-core" "$STATE_ROOT/acme-link"; launch acme-link "" AIB_SUP_STATE_ROOT="$STATE_ROOT"
eq "T1: a symlinked per-agent home => refused, provider not started" "$(provider_ran)" not-run
launch acme-core "" AIB_SUP_STATE_ROOT="$STATE_ROOT" AIB_LOGIN_ROOT="$LROOT"
eq "T1: the login store is never in LL_RW (and LL_RO is /)" "$(printf '%s' "$(ll_field LL_RW)" | grep -c -e "$LROOT" -e /var/lib/aib/login)|$(ll_field LL_RO)" "0|/"
launch acme-core ""
eq "T1: guard — without AIB_SUP_STATE_ROOT the chain keeps the broker's HOME (Block C of adapter_codex_spec)" "$(ll_field HOME)" "$BROKER_HOME"

# --- T2 role-account switch arguments -------------------------------------------------------------------------------------------------------------------
launch acme-core "" AIB_SUP_STATE_ROOT="$STATE_ROOT" AIB_ROLE_UID=5001 AIB_ROLE_GID=5002 AIB_ROLE_UIDS=5001,5003
case "$(ll_field ARGV)" in "--uid 5001 --gid 5002 $STUB/provider exec "*) ok "T2: helper argv starts with --uid 5001 --gid 5002, then the adapter and its normal ABI";; *) no "T2: helper argv starts with --uid/--gid (got '$(ll_field ARGV)')";; esac
eq "T2: the unit's allow-list reaches the helper's env" "$(ll_field AIB_ROLE_UIDS)" "5001,5003"
eq "T2: …but not the provider chain" "$(penv AIB_ROLE_UIDS)|$(provider_ran)" "|ran"
launch acme-core "" AIB_SUP_STATE_ROOT="$STATE_ROOT"
case "$(ll_field ARGV)" in "$STUB/provider exec "*) ok "T2: without AIB_ROLE_UID/GID the argv has no role options";; *) no "T2: without AIB_ROLE_UID/GID the argv has no role options (got '$(ll_field ARGV)')";; esac
launch acme-core "" AIB_SUP_STATE_ROOT="$STATE_ROOT" AIB_ROLE_UID=5001
eq "T2: AIB_ROLE_UID without AIB_ROLE_GID => refused (half a switch is none), provider not started" "$(provider_ran)" not-run
launch acme-core "" AIB_SUP_STATE_ROOT="$STATE_ROOT" AIB_ROLE_UID=abc AIB_ROLE_GID=5002 AIB_ROLE_UIDS=abc
eq "T2: a non-numeric role uid => refused, provider not started" "$(provider_ran)" not-run

# --- T3 credential mode: env derived by the broker ---------------------------------------------------------------------------------------------------------
launch acme-core "provider=codex" AIB_SUP_STATE_ROOT="$STATE_ROOT"
eq "T3: no accounts entry => AIB_CREDENTIAL_MODE=file, AIB_TURN_TIMEOUT_S = the record's timeout, no store path, no fd" "$(penv AIB_CREDENTIAL_MODE)|$(penv AIB_TURN_TIMEOUT_S)|$(penv AIB_LOGIN_STORE_PATH)|$(penv AIB_CREDENTIAL_FD)" "file|5||"
dep '{"codex":{"credential_mode":"shared"}}'
launch acme-core "provider=codex
AIB_CREDENTIAL_MODE=file" AIB_SUP_STATE_ROOT="$STATE_ROOT" AIB_LOGIN_ROOT="$LROOT"
eq "T3: shared => AIB_CREDENTIAL_MODE=shared and the store path of the provider's auth file; a request key cannot override it" "$(penv AIB_CREDENTIAL_MODE)|$(penv AIB_LOGIN_STORE_PATH)" "shared|$LROOT/codex/auth.json"
dep '{"codex":{"credential_mode":"proxy"}}'
launch acme-core "provider=codex" AIB_SUP_STATE_ROOT="$STATE_ROOT"
eq "T3: proxy (reserved) => the provider is not started" "$(provider_ran)" not-run

# --- T4 credential mode fd (Claude) ----------------------------------------------------------------------------------------------------------------------------
printf '{"claudeAiOauth":{"accessToken":"at-%s","refreshToken":"rt-x","expiresAt":%s000}}' "$SENT" "$(( $(date +%s) + 100000 ))" > "$LROOT/claude-code/.credentials.json"; chmod 640 "$LROOT/claude-code/.credentials.json"
dep '{"claude-code":{"credential_mode":"fd"}}'
launch acme-core "provider=claude-code" AIB_SUP_STATE_ROOT="$STATE_ROOT" AIB_LOGIN_ROOT="$LROOT" AIB_LOGIN_MARGIN_S=300 AIB_LOGIN_SLACK_S=600
eq "T4: fd mode: AIB_CREDENTIAL_MODE=fd, AIB_CREDENTIAL_FD=3, and the provider reads the access token from fd 3" "$(penv AIB_CREDENTIAL_MODE)|$(penv AIB_CREDENTIAL_FD)|$(cat "$PRIV/fd.content" 2>/dev/null)" "fd|3|at-$SENT"
eq "T4: …fd 3 is the only extra descriptor the provider chain holds (0,1,2 and 3)" "$(tr ' ' '\n' < "$PRIV/fds" 2>/dev/null | grep -E '^[0-9]+$' | sort -n | tr '\n' ' ')" "0 1 2 3 "
eq "T4: the token is in neither the response nor the helper log nor the chain env" "$(printf '%s' "$RESP" | grep -c "$SENT")|$(grep -c "$SENT" "$LOG")|$(grep -c "$SENT" "$PRIV/env.log" 2>/dev/null)" "0|0|0"
printf 'setup-%s' "$SENT" > "$LROOT/claude-code/setup-token"; chmod 640 "$LROOT/claude-code/setup-token"
dep '{"claude-code":{"credential_mode":"fd","credential_source":"setup_token"}}'
launch acme-core "provider=claude-code" AIB_SUP_STATE_ROOT="$STATE_ROOT" AIB_LOGIN_ROOT="$LROOT"
eq "T4: credential_source setup_token (reserved seam) hands the setup-token file over the same fd" "$(cat "$PRIV/fd.content" 2>/dev/null)" "setup-$SENT"
dep '{"claude-code":{"credential_mode":"fd"}}'
printf '{"claudeAiOauth":{"accessToken":"at-%s","refreshToken":"rt-x","expiresAt":%s000}}' "$SENT" "$(( $(date +%s) + 60 ))" > "$LROOT/claude-code/.credentials.json"
launch acme-core "provider=claude-code" AIB_SUP_STATE_ROOT="$STATE_ROOT" AIB_LOGIN_ROOT="$LROOT"
eq "T4: a token inside the preflight floor => the token tool refuses, provider NOT started, no token in the response" "$(provider_ran)|$(printf '%s' "$RESP" | grep -c "$SENT")" "not-run|0"

# --- T5 (Riker M7) a token refusal reaches the supervisor as a LOGIN condition, not as a generic launch failure --------------------------------
# aib-login-token exits 78 with `hint:login` on ITS stderr, which stays in the broker's journal. The terminal the client receives must carry the
# marker and the 78 class, otherwise the supervisor sees "io-refused confine 126", counts a brake and never auto-heals after the re-login (F6).
printf '{"claudeAiOauth":{"accessToken":"at-%s","refreshToken":"rt-x","expiresAt":%s000}}' "$SENT" "$(( $(date +%s) + 60 ))" > "$LROOT/claude-code/.credentials.json"
launch acme-core "provider=claude-code" AIB_SUP_STATE_ROOT="$STATE_ROOT" AIB_LOGIN_ROOT="$LROOT"
eq "T5: an expired/near-expiry login: the response carries exit_code=78 and the hint:login marker, provider not started" "$(printf '%s' "$RESP" | grep -c '^exit_code=78$')|$(printf '%s' "$RESP" | grep -c 'hint:login')|$(provider_ran)" "1|1|not-run"
eq "T5: …and still no token in the response" "$(printf '%s' "$RESP" | grep -c "$SENT")" 0

printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
