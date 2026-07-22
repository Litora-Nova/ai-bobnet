# shellcheck shell=bash
# ai-bobnet — shared deterministic core library. SOURCE this, do not execute it.
#
# Contract: docs/CONTRACT.md. Runtime: bash + awk + date + util-linux flock.
# Callers MUST set REPO_ROOT (the engine root that holds registry.json + lib/) before
# sourcing, e.g. via the symlink-safe resolver snippet each bin/ + scripts/ entrypoint uses.
#
# Registry authority: the registry is the single source of truth for projects
# (home / standup_dir / mux_session) AND for agents (project / profile / clearance).
# Env is never trusted for those. An agent that is not in the registry is
# fail-closed — even if its uid prefix parses (docs/DOMAIN.md §2).

# --- fatal exit, always loud --------------------------------------------------
aib_die() {
  # aib_die <exit_code> <message...>
  local code="$1"; shift
  printf 'ai-bobnet: %s\n' "$*" >&2
  exit "$code"
}

# --- serialized journal mutation ---------------------------------------------
# aib_journal_commit <lock_path> <journal_path> <decider_fn> [args...]
#
# The decider runs while the exclusive sidecar lock is held. It MUST set:
#   AIB_JOURNAL_ACTION=append  and AIB_JOURNAL_RECORD=<one complete record>, or
#   AIB_JOURNAL_ACTION=noop
# It MAY set AIB_JOURNAL_RESULT. After a successful checked append (or no-op),
# the helper publishes that value as AIB_JOURNAL_COMMIT_RESULT; the caller may
# then print it. This prevents a caller from acknowledging an unwritten record.
#
# This is journal-local serialization for the legacy line protocols. It is not
# the future event spine: it assigns no sequence, framing, cursor, or integrity
# metadata. Locks are advisory and protect only cooperating writers.
aib_journal_commit() {
  local lock_path="${1:-}" journal_path="${2:-}" decider_fn="${3:-}"
  local _aib_lock_fd rc commit_result
  [ "$#" -ge 3 ] || aib_die 2 "journal commit requires lock path, journal path, and decider"
  shift 3

  [ -n "$lock_path" ] && [ -n "$journal_path" ] && [ -n "$decider_fn" ] ||
    aib_die 2 "journal commit requires lock path, journal path, and decider"
  [ -z "${AIB_JOURNAL_ACTIVE_LOCK:-}" ] ||
    aib_die 2 "nested journal commits are not supported"
  command -v flock >/dev/null 2>&1 ||
    aib_die 6 "required runtime dependency not found: flock (util-linux)"

  AIB_JOURNAL_COMMIT_RESULT=""
  exec {_aib_lock_fd}>>"$lock_path" || aib_die 2 "cannot open journal lock: $lock_path"
  flock -x "$_aib_lock_fd" || aib_die 2 "cannot acquire journal lock: $lock_path"

  # These locals are dynamically visible to the decider and to a sanctioned
  # external-child wrapper. The public command process owns the descriptor.
  local AIB_JOURNAL_ACTIVE_LOCK="$lock_path"
  local AIB_JOURNAL_LOCK_FD="$_aib_lock_fd"
  local AIB_JOURNAL_ACTION=""
  local AIB_JOURNAL_RECORD=""
  local AIB_JOURNAL_RESULT=""
  # A decider cannot acknowledge success directly. Unexpected output is diagnostic;
  # only the post-commit result reaches the caller after the checked mutation below.
  "$decider_fn" "$journal_path" "$@" >&2 || {
    rc=$?
    exec {_aib_lock_fd}>&- || true
    return "$rc"
  }

  case "$AIB_JOURNAL_ACTION" in
    append)
      [ -n "$AIB_JOURNAL_RECORD" ] || aib_die 2 "journal decider returned an empty append record"
      case "$AIB_JOURNAL_RECORD" in
        *$'\n'*|*$'\r'*) aib_die 2 "journal decider returned a multi-line record";;
      esac
      if ! printf '%s\n' "$AIB_JOURNAL_RECORD" >> "$journal_path"; then
        aib_die 2 "cannot append journal record: $journal_path"
      fi
      ;;
    noop)
      [ -z "$AIB_JOURNAL_RECORD" ] || aib_die 2 "journal no-op returned an append record"
      ;;
    *) aib_die 2 "journal decider returned no valid action";;
  esac

  commit_result="$AIB_JOURNAL_RESULT"
  exec {_aib_lock_fd}>&- || aib_die 2 "cannot close journal lock: $lock_path"
  AIB_JOURNAL_COMMIT_RESULT="$commit_result"
}

# --- minimal JSON string encoder (for context --json) -------------------------
aib_json() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

# Append a heartbeat from an already-resolved managed bundle without reopening
# the registry. This preserves scripts/log.sh's status and line-encoding contract;
# it does not turn the caller or run-agent into a security boundary.
aib_log_resolved() {
  local standup_dir="${1:-}" agent="${2:-}" status="${3:-}" msg="${4:-}" ts
  [ -n "$standup_dir" ] && [ -n "$agent" ] && [ -n "$status" ] && [ -n "$msg" ] ||
    aib_die 64 'usage: aib_log_resolved <standup_dir> <agent_uid> <busy|idle|blocked|done> "<one line>"'
  aib_validate_agent_uid "$agent"
  case "$status" in
    busy|idle|blocked|done) ;;
    *) aib_die 64 "invalid status '$status' (expected: busy|idle|blocked|done)";;
  esac
  case "$standup_dir" in
    *$'\n'*|*$'\r'*) aib_die 4 "invalid pre-resolved standup_dir (contains a line break)";;
  esac

  msg="${msg//$'\n'/ }"
  msg="${msg//$'\r'/ }"
  msg="${msg//|/%7C}"
  mkdir -p -- "$standup_dir" || aib_die 2 "cannot create standup_dir: $standup_dir"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s | %s | %s | %s\n' "$ts" "$agent" "$status" "$msg" >> "$standup_dir/$agent.log" ||
    aib_die 2 "cannot append heartbeat log: $standup_dir/$agent.log"
}

# --- registry location --------------------------------------------------------
# AIBOBNET_REGISTRY overrides for advanced/local use; otherwise the canonical
# location is <REPO_ROOT>/registry.json. (bin/run-agent scrubs AIBOBNET_* by
# design, so under run-agent the canonical repo-root registry is always used.)
aib_registry_file() {
  printf '%s\n' "${AIBOBNET_REGISTRY:-$REPO_ROOT/registry.json}"
}

# Read one registry generation into the calling function's dynamically scoped
# AIB_REGISTRY_SNAPSHOT. Managed resolution must never reopen the mutable file
# between identity, clearance, team, and binding lookups.
aib_load_registry_snapshot() {
  local reg
  reg="$(aib_registry_file)"
  [ -r "$reg" ] || aib_die 2 "registry not found or unreadable: $reg"
  AIB_REGISTRY_SNAPSHOT="$(<"$reg")" || aib_die 2 "cannot read registry snapshot: $reg"
}

aib_registry_awk() {
  local sect="$1" op="$2" uid="${3:-}" field="${4:-}" reg
  if [ "${AIB_REGISTRY_SNAPSHOT+x}" = x ]; then
    printf '%s\n' "$AIB_REGISTRY_SNAPSHOT" |
      awk -v sect="$sect" -v op="$op" -v uid="$uid" -v field="$field" "$_AIB_AWK"
    return
  fi
  reg="$(aib_registry_file)"
  [ -r "$reg" ] || aib_die 2 "registry not found or unreadable: $reg"
  awk -v sect="$sect" -v op="$op" -v uid="$uid" -v field="$field" "$_AIB_AWK" "$reg"
}

# Validate the registry ONCE, loudly, at the top level of every entrypoint. Every
# query re-runs the same structural pass (defence in depth), but a query is often
# consumed in `if !` or `$( )`, where a die could not abort — so the clear, actionable
# message has to come from here.
aib_check_registry() {
  local reg rc=0; reg="$(aib_registry_file)"
  aib_registry_awk projects validate "" "" || rc=$?
  case "$rc" in
    0) ;;
    6) aib_die 2 "registry is not valid JSON (unterminated string, invalid escape, bad structure, or trailing data) — refusing to resolve identity from it: $reg";;
    7) aib_die 2 "registry has a duplicate key in one object — refusing to guess which one wins: $reg";;
    10) aib_die 2 "registry uses a \\u escape in an OBJECT KEY, which this parser cannot decode. The file is valid JSON — write keys as raw UTF-8 (a key is identity-relevant, so it is never guessed): $reg";;
    11) aib_die 2 "registry schema_version must be the JSON number 2 or 3 at the top level — refusing an absent, mistyped, or unsupported schema: $reg";;
    12) aib_die 2 "registry contains a JSON string escape that decodes to an ASCII control character — refusing unsafe line/path data: $reg";;
    *) aib_die 2 "registry failed validation (code $rc): $reg";;
  esac
}

# --- registry parser (pure awk; no jq) ----------------------------------------
# Legacy schema 2 and execution-binding schema 3 share the same strict JSON reader.
# Schema 3 additively introduces teams plus provider/model/effort binding fields.
#   { "schema_version": 2,
#     "projects": { "<project_uid>": { "home":…, "standup_dir":…, "mux_session":… } },
#     "agents":   { "<agent_uid>":   { "project":…, "profile":…, "clearance":… } } }
# The top-level section is a PARAMETER (-v sect=projects|agents) so one tokenizer
# serves both. Field values must be JSON strings (flat); robust to arbitrary JSON
# whitespace. Unknown extra fields are ignored (forward-compatible, never load-bearing).
_AIB_AWK='
# --- JSON grammar validator (recursive descent over the token stream) ---------
# Balance checking alone is NOT enough: a single missing quote can re-synchronise on
# the next one, leaving brackets balanced and every string terminated while a value
# is silently WRONG (e.g. "home": "/h, "standup_dir": … makes home "/h, " and drops
# standup_dir). At the identity + clearance authority a silently wrong value is worse
# than a refusal, so the whole document must parse as JSON before anything is read.
function is_atom(s) {
  return (s=="true" || s=="false" || s=="null" ||
          s ~ /^-?(0|[1-9][0-9]*)([.][0-9]+)?([eE][-+]?[0-9]+)?$/)
}
function p_value() {
  if (pos > ntok) return 0
  if (ty[pos]=="S") { pos++; return 1 }
  if (ty[pos]=="V") { if (!is_atom(tok[pos])) return 0; pos++; return 1 }
  if (ty[pos]=="P" && tok[pos]=="{") return p_object()
  if (ty[pos]=="P" && tok[pos]=="[") return p_array()
  return 0
}
function p_object(   myid, key) {
  myid = ++nobj; pos++                                   # consume {
  if (ty[pos]=="P" && tok[pos]=="}") { pos++; return 1 }
  while (1) {
    if (ty[pos]!="S") return 0                           # a key must be a JSON string
    # A KEY is always identity-relevant, so an undecodable one is refused up front —
    # unlike a value, which is only refused where it is consumed.
    if (tund[pos]) { badkey=1; return 0 }
    key = tok[pos]
    if ((myid SUBSEP key) in kseen) { dupkey=1; return 0 }
    kseen[myid SUBSEP key] = 1
    pos++
    if (!(ty[pos]=="P" && tok[pos]==":")) return 0
    pos++
    if (!p_value()) return 0
    if (ty[pos]=="P" && tok[pos]==",") { pos++; continue }
    if (ty[pos]=="P" && tok[pos]=="}") { pos++; return 1 }
    return 0
  }
}
function p_array() {
  pos++                                                  # consume [
  if (ty[pos]=="P" && tok[pos]=="]") { pos++; return 1 }
  while (1) {
    if (!p_value()) return 0
    if (ty[pos]=="P" && tok[pos]==",") { pos++; continue }
    if (ty[pos]=="P" && tok[pos]=="]") { pos++; return 1 }
    return 0
  }
}
{ data = data $0 "\n" }
END {
  n = length(data); i = 1; ntok = 0
  while (i <= n) {
    c = substr(data, i, 1)
    if (c==" "||c=="\t"||c=="\r"||c=="\n") { i++; continue }
    if (c=="{"||c=="}"||c=="["||c=="]"||c==":"||c==",") { ntok++; tok[ntok]=c; ty[ntok]="P"; i++; continue }
    if (c=="\"") {
      s=""; i++; term=0; und=0
      while (i<=n) {
        d=substr(data,i,1)
        if (d=="\\") {
          e=substr(data,i+1,1)
          # Registry values cross into line-oriented key=value and journal protocols.
          # A decoded ASCII control byte could forge a second field/line or alter a
          # path invisibly, so valid JSON control escapes are outside this schema.
          if(e=="n"||e=="t"||e=="r"||e=="b"||e=="f") { exit 12 }
          else if(e=="\"")s=s"\""; else if(e=="\\")s=s"\\"; else if(e=="/")s=s"/";
          # \u is VALID JSON that this parser cannot decode. Rejecting the whole file
          # for it would break every registry written by a tool using json.dump(), which
          # escapes non-ASCII by default — and CONTRACT.md explicitly invites unicode in
          # display_name, a field nothing ever reads. So mark the token undecodable and
          # defer: it only kills where it is actually read (as a key, or as a consumed
          # field). Same shape as the value-type rule. Fail-closed stays where it counts.
          else if(e=="u") {
            uhex=substr(data,i+2,4)
            if (uhex !~ /^[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]$/) exit 6
            # U+0000..U+001F plus U+007F are ASCII controls even when expressed
            # through the otherwise-deferred Unicode form.
            if (uhex ~ /^00(0[0-9A-Fa-f]|1[0-9A-Fa-f])$/ || uhex ~ /^007[fF]$/) exit 12
            und=1; i+=6; continue
          }
          # Anything else is not a JSON escape at all. Taking the char verbatim silently
          # produced a DIFFERENT value than a strict reader, so the document is refused.
          else { exit 6 }
          i+=2; continue
        }
        if (d=="\"") { i++; term=1; break }
        # Unescaped U+0000..U+001F bytes are invalid inside a JSON string. `awk`
        # receives record separators through the newline re-added above, so test the
        # full portable control class rather than treating a physical LF as whitespace.
        if (d ~ /[[:cntrl:]]/) { exit 6 }
        s=s d; i++
      }
      # An unterminated string silently swallowed the rest of the file (a torn write).
      # Accepting it would let a half-written registry hand out identity and clearance.
      if (!term) { exit 6 }
      ntok++; tok[ntok]=s; ty[ntok]="S"; tund[ntok]=und; continue
    }
    s=""
    while (i<=n) {
      d=substr(data,i,1)
      if (d==" "||d=="\t"||d=="\r"||d=="\n"||d==","||d=="}"||d=="]"||d==":") break
      s=s d; i++
    }
    ntok++; tok[ntok]=s; ty[ntok]="V"; continue
  }
  # --- structural validation (fail-closed) ------------------------------------
  # The registry is the identity AND clearance authority (DOMAIN §2), so a malformed
  # file must never resolve. The whole document must parse as JSON: exactly ONE
  # top-level value, no trailing data, and no duplicate key within the same object
  # (last-write-wins would let key ORDER decide routing, clearance and memory scope).
  pos = 1; nobj = 0; dupkey = 0; badkey = 0
  if (!p_value()) { if (dupkey) exit 7; if (badkey) exit 10; exit 6 }
  if (pos <= ntok) exit 6                      # trailing data after the top-level value
  if (ty[1]!="P" || tok[1]!="{") exit 6        # the registry must be an object

  # schema_version is the compatibility gate, not decorative metadata. Only the
  # exact JSON numbers 2 and 3 at depth 1 select grammars implemented by this reader;
  # a nested lookalike, a string value, or an unknown version must fail closed.
  schema_seen=0; sdepth=0
  for (j=1; j<=ntok; j++) {
    if (ty[j]=="P" && (tok[j]=="{" || tok[j]=="[")) { sdepth++; continue }
    if (ty[j]=="P" && (tok[j]=="}" || tok[j]=="]")) { sdepth--; continue }
    if (sdepth==1 && ty[j]=="S" && tok[j]=="schema_version" && ty[j+1]=="P" && tok[j+1]==":") {
      schema_seen=1
      if (ty[j+2]!="V" || (tok[j+2]!="2" && tok[j+2]!="3")) exit 11
      schema_value=tok[j+2]
    }
  }
  if (!schema_seen) exit 11
  if (op=="validate") { exit 0 }
  if (op=="schema") { print schema_value; exit 0 }

  # Locate the requested TOP-LEVEL section (depth 1) — a nested key of the same
  # name must never be mistaken for it.
  pstart = 0; sdepth = 0
  for (j=1; j<=ntok; j++) {
    if (ty[j]=="P" && (tok[j]=="{" || tok[j]=="[")) { sdepth++; continue }
    if (ty[j]=="P" && (tok[j]=="}" || tok[j]=="]")) { sdepth--; continue }
    if (sdepth==1 && ty[j]=="S" && tok[j]==sect && ty[j+1]=="P" && tok[j+1]==":" && ty[j+2]=="P" && tok[j+2]=="{") { pstart=j+2; break }
  }
  if (pstart==0) { exit 3 }
  # Depth counts [] as well as {}. Nothing can currently reach a case where this
  # matters: the object requirement below already rejects any section entry that is
  # not an object, so no array can place content at depth 2. This is unreachable
  # redundancy and NOT the defence against MED-2 — the object requirement is; do not
  # cite this line as protection. It is kept for one reason: it makes `depth` mean
  # what its name says. Previously [] were ignored symmetrically, so the count
  # balanced by accident rather than by construction, and a refactor that relaxes the
  # object requirement would silently re-open the hole. No test covers it, because no
  # black-box input can distinguish it from its absence.
  depth=0; cur=""; nuid=0
  for (j=pstart; j<=ntok; j++) {
    if (ty[j]=="P" && (tok[j]=="{" || tok[j]=="[")) { depth++; continue }
    if (ty[j]=="P" && (tok[j]=="}" || tok[j]=="]")) {
      depth--
      if (depth==0) break
      if (depth==1) cur=""
      continue
    }
    if (ty[j]=="S" && ty[j+1]=="P" && tok[j+1]==":") {
      if (depth==1) {
        # THIS is the defence against MED-2. A section entry MUST be an object: an
        # array/string/number is not an agent or a project, so it is not registered and
        # its contents are attributed to nothing. Without it an object nested in an array
        # resolved as a full agent carrying its OWN clearance, while jq and python saw a
        # list and no agent at all — enforcement view and audit view disagreeing about
        # clearance. Covered by tests/p0_spec.sh (section 14i).
        if (ty[j+2]=="P" && tok[j+2]=="{") { cur=tok[j]; nuid++; uids[nuid]=cur; hasuid[cur]=1 }
        else cur=""
      }
      else if (depth==2 && cur!="") {
        # Keep the value, its token type AND whether it decoded. Both are enforced only
        # where a field is actually consumed, so an unknown nested/array field — or a
        # \u escape in a field nobody reads — stays forward-compatible.
        store[cur SUBSEP tok[j]]    = tok[j+2]
        storety[cur SUBSEP tok[j]]  = ty[j+2]
        storeund[cur SUBSEP tok[j]] = tund[j+2]
      }
    }
  }
  if (op=="keys") { for (k=1;k<=nuid;k++) print uids[k]; exit 0 }
  if (op=="has")  { if (hasuid[uid]) exit 0; else exit 3 }
  if (op=="field") {
    if (!hasuid[uid]) exit 3
    key = uid SUBSEP field
    if (!(key in store)) exit 4
    if (storety[key] != "S") exit 8          # consumed fields MUST be JSON strings
    if (storeund[key]) exit 10               # ...and MUST be fully decodable
    print store[key]; exit 0
  }
  exit 9
}'

# aib_registry_query <projects|agents> <keys|has|field> [uid] [field]
aib_registry_query() {
  aib_registry_awk "$1" "$2" "${3:-}" "${4:-}"
}

aib_registry_schema_version() {
  aib_registry_query projects schema
}

aib_require_project() {
  local p="$1"
  if ! aib_registry_query projects has "$p"; then
    aib_die 3 "unknown project_uid: '$p' (not in registry). Known: $(aib_registry_query projects keys | tr '\n' ' ')"
  fi
}

# aib_project_field <project_uid> <field> -> value (dies if missing/empty/mistyped)
aib_project_field() {
  local p="$1" f="$2" v rc=0
  v="$(aib_registry_query projects field "$p" "$f")" || rc=$?
  [ "$rc" -ne 8 ]  || aib_die 2 "registry: project '$p' field '$f' is not a JSON string"
  [ "$rc" -ne 10 ] || aib_die 2 "registry: project '$p' field '$f' uses a \\u escape this parser cannot decode — write it as raw UTF-8 (refusing to act on a half-decoded value)"
  if [ "$rc" -ne 0 ] || [ -z "$v" ]; then
    aib_die 3 "registry: project '$p' has no usable field '$f'"
  fi
  printf '%s\n' "$v"
}

# aib_agent_field <agent_uid> <field> -> value (dies if missing/empty/mistyped)
aib_agent_field() {
  local a="$1" f="$2" v rc=0
  v="$(aib_registry_query agents field "$a" "$f")" || rc=$?
  [ "$rc" -ne 8 ]  || aib_die 2 "registry: agent '$a' field '$f' is not a JSON string"
  [ "$rc" -ne 10 ] || aib_die 2 "registry: agent '$a' field '$f' uses a \\u escape this parser cannot decode — write it as raw UTF-8 (refusing to act on a half-decoded value)"
  if [ "$rc" -ne 0 ] || [ -z "$v" ]; then
    aib_die 3 "registry: agent '$a' has no usable field '$f'"
  fi
  printf '%s\n' "$v"
}

# Read an optional field from the active registry snapshot without confusing
# absence with an invalid present value. Returns 4 only for true absence; every
# present-empty, non-string, or undecodable value fails closed here.
aib_snapshot_field() {
  local sect="$1" uid="$2" field="$3" label="$4" value rc=0
  value="$(aib_registry_query "$sect" field "$uid" "$field")" || rc=$?
  case "$rc" in
    0)
      [ -n "$value" ] || aib_die 3 "registry: $label field '$field' is present but empty"
      AIB_SNAPSHOT_FIELD_VALUE="$value"
      return 0
      ;;
    4)
      AIB_SNAPSHOT_FIELD_VALUE=""
      return 4
      ;;
    8)  aib_die 2 "registry: $label field '$field' is not a JSON string";;
    10) aib_die 2 "registry: $label field '$field' uses a \\u escape this parser cannot decode — write it as raw UTF-8";;
    3)  aib_die 3 "registry: unknown $label";;
    *)  aib_die 2 "registry: cannot read $label field '$field' (code $rc)";;
  esac
}

# --- identity validation ------------------------------------------------------
aib_validate_token() {
  # single id token (project_uid, agent_key, profile, actor label):
  # lowercase/digit/hyphen, no edge/double hyphen
  local t="$1" what="$2"
  [ -n "$t" ] || aib_die 4 "$what is empty"
  case "$t" in
    *[!a-z0-9-]*) aib_die 4 "invalid $what '$t' (allowed: lowercase letters, digits, hyphen)";;
    -*|*-|*--*)   aib_die 4 "invalid $what '$t' (no leading/trailing/double hyphen)";;
  esac
}

aib_validate_agent_uid() {
  local a="$1"
  [ -n "$a" ] || aib_die 4 "agent_uid is empty"
  case "$a" in
    *[!a-z0-9-]*) aib_die 4 "invalid agent_uid '$a' (allowed: lowercase letters, digits, hyphen)";;
    -*|*-|*--*)   aib_die 4 "invalid agent_uid '$a' (no leading/trailing/double hyphen)";;
  esac
  case "$a" in
    *-*) : ;;  # must be <project_uid>-<agent_key>
    *)   aib_die 4 "invalid agent_uid '$a' (expected <project_uid>-<agent_key>)";;
  esac
}

aib_validate_clearance() {
  local c="$1" what="${2:-clearance}"
  case "$c" in
    t1|t2|t3|t4) ;;
    *) aib_die 4 "invalid $what '$c' (expected: t1|t2|t3|t4)";;
  esac
}

aib_validate_provider() {
  local provider="$1"
  [ "${#provider}" -le 64 ] || aib_die 4 "invalid provider '$provider' (maximum: 64 bytes)"
  aib_validate_token "$provider" provider
}

aib_validate_model() {
  local model="$1"
  [ -n "$model" ] && [ "${#model}" -le 256 ] ||
    aib_die 4 "invalid model '$model' (expected 1-256 bytes)"
  case "$model" in
    *[!A-Za-z0-9._:/-]*)
      aib_die 4 "invalid model '$model' (allowed: letters, digits, dot, underscore, colon, slash, hyphen)"
      ;;
  esac
}

# Effort semantics belong to the selected provider adapter. The core constrains
# the registry transport to a small token; Lane B applies Codex's closed enum.
aib_validate_effort() {
  local effort="$1"
  [ "${#effort}" -le 64 ] || aib_die 4 "invalid effort '$effort' (maximum: 64 bytes)"
  aib_validate_token "$effort" effort
}

aib_validate_team_uid() {
  local team="$1" project="$2" key
  aib_validate_agent_uid "$team"
  case "$team" in
    "$project"-*) key="${team#"$project"-}";;
    *) aib_die 5 "registry inconsistent: team_uid '$team' does not match project '$project'";;
  esac
  aib_validate_token "$key" team_key
}

# --- resolve an agent_uid via the registry (deterministic, fail-closed) -------
# An Agent is a REGISTRY OBJECT (DOMAIN §2): lookup is the authority, parsing is
# validation only. There is deliberately NO prefix-scan fallback — a fallback would
# re-open exactly the ambiguity ("acme" vs "acme-core") that this closes.
# Sets globals: AIB_PROJECT_UID · AIB_AGENT_KEY · AIB_PROFILE · AIB_CLEARANCE.
aib_split_agent() {
  local agent="$1" project profile clearance key
  aib_validate_agent_uid "$agent"                      # shape validation ONLY

  if ! aib_registry_query agents has "$agent"; then
    aib_die 3 "unknown agent_uid '$agent' (not in registry)"
  fi

  # `project` is mandatory and authoritative — never guessed from the prefix.
  project="$(aib_agent_field "$agent" project)"
  aib_validate_token "$project" project_uid
  if ! aib_registry_query projects has "$project"; then
    aib_die 3 "registry: agent '$agent' names unknown project '$project'"
  fi

  # The uid MUST carry its project's prefix; otherwise the registry disagrees with itself.
  case "$agent" in
    "$project"-*) key="${agent#"$project"-}";;
    *) aib_die 5 "registry inconsistent: agent_uid '$agent' does not match its project '$project'";;
  esac
  case "$key" in
    ''|*[!a-z0-9-]*|-*|*-|*--*)
      aib_die 5 "registry inconsistent: agent_uid '$agent' does not match its project '$project'";;
  esac

  # profile is MUTABLE; clearance lives on the AGENT object and never on the profile
  # (a profile swap MUST NOT change clearance — DOMAIN §2).
  profile="$(aib_agent_field "$agent" profile)"
  aib_validate_token "$profile" profile
  clearance="$(aib_agent_field "$agent" clearance)"
  aib_validate_clearance "$clearance" "clearance of agent '$agent'"

  AIB_PROJECT_UID="$project"
  AIB_AGENT_KEY="$key"
  AIB_PROFILE="$profile"
  AIB_CLEARANCE="$clearance"
}

# Resolve one binding field independently through agent -> direct team -> project.
# Sets AIB_RESOLVED_VALUE and AIB_RESOLVED_SOURCE. All lookups use the caller's
# immutable AIB_REGISTRY_SNAPSHOT; only a truly absent field falls through.
aib_resolve_binding_field() {
  local field="$1" agent="$2" team="$3" project="$4"

  if aib_snapshot_field agents "$agent" "$field" "agent '$agent'"; then
    AIB_RESOLVED_VALUE="$AIB_SNAPSHOT_FIELD_VALUE"
    AIB_RESOLVED_SOURCE="agent:$agent"
    return 0
  fi
  if [ -n "$team" ] && aib_snapshot_field teams "$team" "$field" "team '$team'"; then
    AIB_RESOLVED_VALUE="$AIB_SNAPSHOT_FIELD_VALUE"
    AIB_RESOLVED_SOURCE="team:$team"
    return 0
  fi
  if aib_snapshot_field projects "$project" "$field" "project '$project'"; then
    AIB_RESOLVED_VALUE="$AIB_SNAPSHOT_FIELD_VALUE"
    AIB_RESOLVED_SOURCE="project:$project"
    return 0
  fi
  aib_die 3 "registry: execution binding field '$field' is absent at agent, direct team, and project levels"
}

# aib_resolve_agent_snapshot <agent_uid> <legacy|managed>
#
# Reads and validates exactly one registry snapshot, then resolves identity,
# clearance, paths, direct-team membership, and (for schema 3) execution binding.
# This is a context bundle, not a security boundary or reference monitor.
aib_resolve_agent_snapshot() {
  local agent="$1" mode="${2:-legacy}" schema team="" team_project
  local provider provider_source model model_source effort effort_source
  local AIB_REGISTRY_SNAPSHOT

  case "$mode" in
    legacy|managed) ;;
    *) aib_die 64 "invalid resolver mode '$mode' (expected: legacy|managed)";;
  esac

  aib_load_registry_snapshot
  aib_check_registry
  schema="$(aib_registry_schema_version)" || aib_die 2 "registry: cannot read schema_version"
  if [ "$mode" = managed ] && [ "$schema" != 3 ]; then
    aib_die 3 "managed execution binding requires registry schema_version 3 (found $schema)"
  fi

  aib_split_agent "$agent"
  AIB_AGENT_UID="$agent"
  AIB_REGISTRY_SCHEMA_VERSION="$schema"
  AIB_TEAM_UID=""
  AIB_PROVIDER=""
  AIB_PROVIDER_SOURCE=""
  AIB_MODEL=""
  AIB_MODEL_SOURCE=""
  AIB_EFFORT=""
  AIB_EFFORT_SOURCE=""

  AIB_HOME="$(aib_project_field "$AIB_PROJECT_UID" home)"
  AIB_STANDUP_DIR="$(aib_project_field "$AIB_PROJECT_UID" standup_dir)"
  AIB_MUX_SESSION="$(aib_project_field "$AIB_PROJECT_UID" mux_session)"
  AIB_INBOX_PATH="${AIB_STANDUP_DIR}/inbox/${agent}.md"

  # Schema 2 remains a legacy identity/context format. It never invents binding.
  [ "$schema" = 3 ] || return 0

  if aib_snapshot_field agents "$agent" team_uid "agent '$agent'"; then
    team="$AIB_SNAPSHOT_FIELD_VALUE"
    aib_validate_team_uid "$team" "$AIB_PROJECT_UID"
    if ! aib_registry_query teams has "$team"; then
      aib_die 3 "registry: agent '$agent' names unknown direct team '$team'"
    fi
    if ! aib_snapshot_field teams "$team" project "team '$team'"; then
      aib_die 3 "registry: team '$team' has no project"
    fi
    team_project="$AIB_SNAPSHOT_FIELD_VALUE"
    aib_validate_token "$team_project" "project of team '$team'"
    [ "$team_project" = "$AIB_PROJECT_UID" ] || aib_die 5 \
      "registry inconsistent: team '$team' belongs to project '$team_project', not '$AIB_PROJECT_UID'"
    AIB_TEAM_UID="$team"
  fi

  aib_resolve_binding_field provider "$agent" "$team" "$AIB_PROJECT_UID"
  provider="$AIB_RESOLVED_VALUE"; provider_source="$AIB_RESOLVED_SOURCE"
  aib_validate_provider "$provider"

  aib_resolve_binding_field model "$agent" "$team" "$AIB_PROJECT_UID"
  model="$AIB_RESOLVED_VALUE"; model_source="$AIB_RESOLVED_SOURCE"
  aib_validate_model "$model"

  aib_resolve_binding_field effort "$agent" "$team" "$AIB_PROJECT_UID"
  effort="$AIB_RESOLVED_VALUE"; effort_source="$AIB_RESOLVED_SOURCE"
  aib_validate_effort "$effort"

  AIB_PROVIDER="$provider"
  AIB_PROVIDER_SOURCE="$provider_source"
  AIB_MODEL="$model"
  AIB_MODEL_SOURCE="$model_source"
  AIB_EFFORT="$effort"
  AIB_EFFORT_SOURCE="$effort_source"
}

aib_resolve_managed_agent() {
  aib_resolve_agent_snapshot "$1" managed
}

# --- optional actor label (on_behalf_of; DOMAIN §2 "Ephemeral helpers") -------
# A short-lived helper is a Session/Attempt acting on behalf of an existing Agent —
# never a new Agent. The label is audit-only and MUST NOT influence routing.
# Sets globals: AIB_ACTOR (may be empty) and AIB_ACTOR_FIELD (encoded journal suffix).
# Validation is the encoding guarantee: the token charset admits no '|' and no newline.
aib_load_actor() {
  AIB_ACTOR="${AIBOBNET_ACTOR:-}"
  AIB_ACTOR_FIELD=""
  [ -n "$AIB_ACTOR" ] || return 0
  aib_validate_token "$AIB_ACTOR" actor_label
  AIB_ACTOR_FIELD=" | actor:$AIB_ACTOR"
}

# aib_inbox_path <agent_uid> -> recipient's own inbox file (deterministic)
aib_inbox_path() {
  local agent="$1" sd
  aib_split_agent "$agent"
  sd="$(aib_project_field "$AIB_PROJECT_UID" standup_dir)"
  printf '%s/inbox/%s.md\n' "$sd" "$agent"
}
