# ai-bobnet — shared hermetic harness for the shared-login specs (Supervisor slice S1c; sourced, never run on its own).
# Builds on tests/fixtures/ctl_harness.sh (ok/no/eq/has/hasnt, ctl_world, CTLENV, the control audit helpers).
#
# ===== THE INTERFACE THIS HARNESS PINS FOR THE S1c LOGIN MACHINERY (design v3 / v3.1 / v3.2 / E9, 2026-10-20) =====
# Store (one login per provider per server).  Provider keys are the registry/adapters names: `claude-code`, `codex`.
#   $AIB_LOGIN_ROOT/<provider>/              dir 0750, owner aib-broker, group aib-login  (default root /var/lib/aib/login)
#   claude-code/.credentials.json            {"claudeAiOauth":{"accessToken","refreshToken","expiresAt"(ms),"refreshTokenExpiresAt"(ms, optional)...}}
#   codex/auth.json                          {"tokens":{"access_token"(JWT),"refresh_token","account_id"},"last_refresh":...}
#   <provider>/login.meta.json               written by the login unit, 0640: {"logged_in_at":<epoch>,"login_expires_at":<epoch>,"account_id":"<id>"}
#   credential files are 0640 (never wider), written by tmp + rename in the same directory. Exactly ONE writer refreshes them: the
#   refresher (`bin/aib-login-refresh`, unit aib-login-refresh@<provider>, User=aib-broker). A child never writes the store.
# Test seams (honoured ONLY when AIB_TEST_SEAMS=1 and the engine root holds no `.aib-installed`, same gate as agentctl/aib-gw):
#   AIB_LOGIN_ROOT          store root                                  (default /var/lib/aib/login)
#   AIB_LOGIN_STATUS_DIR    status files <provider>.json, 0644          (default /run/aib/login-status)
#   AIB_LOGIN_STATE_DIR     watch dedupe + gateway rate-limit state     (default /var/lib/aib/login-state)
#   AIB_LOGIN_SOCK_DIR      login-<provider>.sock lives here            (default /run/aib)
#   AIB_LOGIN_REQ_DIR       request spool (design v3.7 P1/P2)           (default /run/aib/login-requests; dir mode 1733, owned by the broker)
#                           `agentctl login start` creates <provider>.<seq>.<8 hex>.req there (O_EXCL|O_NOFOLLOW, 0644, {"seq","provider"}); bin/aib-login
#                           takes the request and the CALLER (= identity_for(st_uid of the file)) ONLY from here, never from _control.jsonl.
#   AIB_LOGIN_REQ_MAX_AGE_S requests older than this (mtime) are removed unused (default 600; design v3.7.1 Q3)
#   AIB_LOGIN_NOW           epoch seconds replacing the clock of the ONE-SHOT tools (watch, refresher, token tool, adapter preflight)
#   AIB_DEPLOYMENT_CONFIG / AIB_OUTBOX_ROOT / AIB_CONTROL_LOG / AIB_IDENTITY_CMD / AIB_SYSTEMCTL: as in ctl_harness.sh
#   AIB_CLAUDE_BIN / AIB_CODEX_BIN   the wrapped CLI (fakes here)
# Cadence/margin NUMBERS are parameters (real token lifetimes are not measured yet); production defaults live in ONE place (the
# tools), the specs always pass explicit values:
#   AIB_LOGIN_LIFETIME_S        login lifetime recorded by the login unit             (default 4838400 = 8 weeks)
#   AIB_LOGIN_EXPIRING_S        watch: state `expiring` when remaining <= this         (default 259200 = 72 h)
#   AIB_LOGIN_REEMIT_S          watch: same state again emits at most once per this    (default 86400)
#   AIB_LOGIN_ACCESS_LIFETIME_S access-token lifetime (cadence derives from it)        (default 3600)
#   AIB_LOGIN_MARGIN_S          the CLI's own proactive-refresh margin                 (default 300; observed)
#   AIB_LOGIN_SLACK_S           extra slack above the margin                           (default 600)
#   AIB_LOGIN_MAX_TURN_S        longest turn a child may run                           (default 900)
#   AIB_LOGIN_WINDOW_S          login vorgang window                                   (default 1800 = 30 min)
#   AIB_LOGIN_CODE_FRESH_S      max age of a code between gateway receipt and typing   (default 60)
#   AIB_LOGIN_START_INTERVAL_S  gateway-started logins: at most one per this           (default 3600)
# Server outbox: $AIB_OUTBOX_ROOT/_server/outbox.md, same line format as a team outbox, `to:human:ops`, written only by aib-broker's tools.

. "$(dirname "${BASH_SOURCE[0]}")/ctl_harness.sh"

LNOW=1800000000                       # fixed epoch for the one-shot tools
SENT="SECRET-TOKEN-0123456789abcdef"  # a sentinel that must never leak into a status file, an alarm, an audit record or a capture

# lw_world <tag> — a control world plus the login directories; sets LROOT LSTAT LSTATE LSOCK LENV[]
lw_world() {
  ctl_world "$1"
  LROOT="$W/login"; LSTAT="$W/login-status"; LSTATE="$W/login-state"; LSOCK="$W/run"
  mkdir -p "$LROOT/claude-code" "$LROOT/codex" "$LSTAT" "$LSTATE" "$LSOCK" "$W/home-login"
  chmod 750 "$LROOT" "$LROOT/claude-code" "$LROOT/codex"; chmod 755 "$LSTAT"
  LREQ="$W/login-requests"; mkdir -p "$LREQ"; chmod 1733 "$LREQ"
  LENV=("${CTLENV[@]}" AIB_LOGIN_REQ_DIR="$LREQ" AIB_LOGIN_ROOT="$LROOT" AIB_LOGIN_STATUS_DIR="$LSTAT" AIB_LOGIN_STATE_DIR="$LSTATE" AIB_LOGIN_SOCK_DIR="$LSOCK"
        AIB_LOGIN_NOW="$LNOW" AIB_LOGIN_LIFETIME_S=1000000 AIB_LOGIN_EXPIRING_S=259200 AIB_LOGIN_REEMIT_S=86400
        AIB_LOGIN_ACCESS_LIFETIME_S=3600 AIB_LOGIN_MARGIN_S=300 AIB_LOGIN_SLACK_S=600 AIB_LOGIN_MAX_TURN_S=900)
}
# b64u — base64url without padding on stdin
b64u() { base64 -w0 | tr '+/' '-_' | tr -d '='; }
jwt() { # jwt <exp-epoch> -> a three-part JWT whose payload carries exp (the signature is junk: nobody verifies it here)
  printf '%s.%s.%s' "$(printf '{"alg":"none"}' | b64u)" "$(printf '{"exp":%s,"https://api.openai.com/auth":{"chatgpt_account_id":"acct-x"}}' "$1" | b64u)" "sig-$SENT"
}
# mk_claude <access-expires-epoch> [login-end-epoch] — store credential for claude-code (0640)
mk_claude() {
  local extra=""; [ -z "${2:-}" ] || extra=",\"refreshTokenExpiresAt\":$(( $2 * 1000 ))"
  printf '{"claudeAiOauth":{"accessToken":"at-%s","refreshToken":"rt-%s","expiresAt":%s%s,"scopes":["user:inference"],"subscriptionType":"max"}}' \
    "$SENT" "$SENT" "$(( $1 * 1000 ))" "$extra" > "$LROOT/claude-code/.credentials.json"
  chmod 640 "$LROOT/claude-code/.credentials.json"
}
# mk_codex <access-exp-epoch> [account-id] — store credential for codex (0640)
mk_codex() {
  printf '{"tokens":{"access_token":"%s","refresh_token":"rt-%s","account_id":"%s"},"last_refresh":"2026-01-01T00:00:00Z"}' \
    "$(jwt "$1")" "$SENT" "${2:-acct-0000c0de}" > "$LROOT/codex/auth.json"
  chmod 640 "$LROOT/codex/auth.json"
}
# mk_meta <provider> <logged-in-at> <login-expires-at> [account-id]
mk_meta() {
  printf '{"logged_in_at":%s,"login_expires_at":%s,"account_id":"%s"}' "$2" "$3" "${4:-acct-0000c0de}" > "$LROOT/$1/login.meta.json"
  chmod 640 "$LROOT/$1/login.meta.json"
}
# deploy_accounts <json for "accounts"> — rewrite the deployment config with an accounts object (root-owned semantics: 0644, our uid)
deploy_accounts() {
  printf '{"deployment_id":"acme-dev-1","profile":"dev","allow":{"customer_code":true,"comms_secrets":true},"accounts":%s}' "$1" > "$DEPLOY"; chmod 644 "$DEPLOY"
}
# lenv <cmd...> — run under the hermetic login environment; RC OUT ERR
lrun() {
  local extra=(); while [ $# -gt 0 ] && [ "$1" != "--" ]; do extra+=("$1"); shift; done; [ "${1:-}" = "--" ] && shift
  RC=0; OUT="$(env -i PATH="$W/fakebin:$PATH" HOME="$W/home-login" LANG=C TZ=UTC "${LENV[@]}" AIBOBNET_REGISTRY="$ENGINE/registry.json" "${extra[@]}" \
      timeout 60 "$@" 2>"$W/lrun.err")" || RC=$?
  ERR="$(cat "$W/lrun.err" 2>/dev/null)"
}
SO() { cat "$OUTBOX/_server/outbox.md" 2>/dev/null; }          # the server outbox
son() { SO | grep -c "alarm:$1"; }                             # count of alarm lines of a kind
mode_of() { stat -c %a "$1" 2>/dev/null; }
# leaks <needle> <paths...> -> number of files that contain the needle (0 = clean); grep -r over dirs
leaks() { local n="$1"; shift; grep -rlF -- "$n" "$@" 2>/dev/null | wc -l | tr -d ' '; }
# setmode <path> <octal> — an exact mode (plain chmod keeps setgid on a directory for 4-digit numeric modes)
setmode() { python3 -I -c 'import os,sys; os.chmod(sys.argv[1], int(sys.argv[2], 8))' "$1" "$2"; }
lw_clean() { rm -rf "${OUTBOX:?}"/* "${LSTATE:?}"/* "${LSTAT:?}"/* "${LREQ:?}"/* "$LREQ"/.[!.]*; mkdir -p "$OUTBOX" "$LREQ"; setmode "$LREQ" 1733; }
# spool_put <provider> <seq> [json-content] [file-mode] [rand] — one request file named <provider>.<seq>.<8 hex>.req (design v3.7.1 Q1), created like agentctl does
# (O_CREAT|O_EXCL|O_NOFOLLOW, owner = us, default 0644); rand defaults to 8 random hex chars; content defaults to {"seq":<seq>,"provider":"<provider>"}
spool_put() { python3 -I - "$LREQ" "$1" "$2" "${3:-}" "${4:-644}" "${5:-}" <<'PY'
import json, os, secrets, sys
d, prov, seq, content, mode, rand = sys.argv[1:7]
if not content: content = json.dumps({"seq": int(seq), "provider": prov})
if not rand: rand = secrets.token_hex(4)
fd = os.open(os.path.join(d, "%s.%s.%s.req" % (prov, seq, rand)), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
os.fchmod(fd, int(mode, 8)); os.write(fd, content.encode()); os.close(fd)
PY
}
   # reset outbox + watch state + status files
