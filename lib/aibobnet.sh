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

# Legacy queries are always file-backed. Snapshot selection must never depend on
# ambient shell/environment state: only aib_resolve_agent_snapshot enters the
# separate internal snapshot path below.
aib_registry_awk() {
  local sect="$1" op="$2" uid="${3:-}" field="${4:-}" reg
  reg="$(aib_registry_file)"
  [ -r "$reg" ] || aib_die 2 "registry not found or unreadable: $reg"
  awk -v sect="$sect" -v op="$op" -v uid="$uid" -v field="$field" "$_AIB_AWK" "$reg"
}

# Internal managed-resolution path. Its dynamically scoped state is initialized
# and replaced by aib_resolve_agent_snapshot before any query can reach here.
_aib_load_registry_snapshot() {
  _AIB_RESOLVER_REGISTRY="$(aib_registry_file)"
  [ -r "$_AIB_RESOLVER_REGISTRY" ] ||
    aib_die 2 "registry not found or unreadable: $_AIB_RESOLVER_REGISTRY"
  _AIB_RESOLVER_SNAPSHOT="$(<"$_AIB_RESOLVER_REGISTRY")" ||
    aib_die 2 "cannot read registry snapshot: $_AIB_RESOLVER_REGISTRY"
}

_aib_snapshot_awk() {
  local sect="$1" op="$2" uid="${3:-}" field="${4:-}"
  printf '%s\n' "$_AIB_RESOLVER_SNAPSHOT" |
    awk -v sect="$sect" -v op="$op" -v uid="$uid" -v field="$field" "$_AIB_AWK"
}

# Validate the registry ONCE, loudly, at the top level of every entrypoint. Every
# query re-runs the same structural pass (defence in depth), but a query is often
# consumed in `if !` or `$( )`, where a die could not abort — so the clear, actionable
# message has to come from here.
_aib_check_registry_with() {
  local query="$1" reg="$2" rc=0
  "$query" projects validate "" "" || rc=$?
  case "$rc" in
    0) ;;
    6) aib_die 2 "registry is not valid JSON (unterminated string, invalid escape, bad structure, or trailing data) — refusing to resolve identity from it: $reg";;
    7) aib_die 2 "registry has a duplicate key in one object — refusing to guess which one wins: $reg";;
    10) aib_die 2 "registry uses a \\u escape in an OBJECT KEY, which this parser cannot decode. The file is valid JSON — write keys as raw UTF-8 (a key is identity-relevant, so it is never guessed): $reg";;
    11) aib_die 2 "registry schema_version must be the JSON number 2, 3, or 4 at the top level — refusing an absent, mistyped, or unsupported schema: $reg";;
    12) aib_die 2 "registry contains a JSON string escape that decodes to an ASCII control character — refusing unsafe line/path data: $reg";;
    *) aib_die 2 "registry failed validation (code $rc): $reg";;
  esac
}

aib_check_registry() {
  local reg
  reg="$(aib_registry_file)"
  _aib_check_registry_with aib_registry_awk "$reg"
}

_aib_check_registry_snapshot() {
  _aib_check_registry_with _aib_snapshot_awk "$_AIB_RESOLVER_REGISTRY"
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
  # exact JSON numbers 2, 3, and 4 at depth 1 select grammars implemented by this
  # reader; a nested lookalike, a string value, or an unknown version must fail
  # closed. Schema 4 adds the provider adapter map + declared capabilities on top of
  # the schema-3 execution binding — an old reader that knows only 2/3 still rejects it.
  schema_seen=0; sdepth=0
  for (j=1; j<=ntok; j++) {
    if (ty[j]=="P" && (tok[j]=="{" || tok[j]=="[")) { sdepth++; continue }
    if (ty[j]=="P" && (tok[j]=="}" || tok[j]=="]")) { sdepth--; continue }
    if (sdepth==1 && ty[j]=="S" && tok[j]=="schema_version" && ty[j+1]=="P" && tok[j+1]==":") {
      schema_seen=1
      if (ty[j+2]!="V" || (tok[j+2]!="2" && tok[j+2]!="3" && tok[j+2]!="4")) exit 11
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

_aib_snapshot_query() {
  _aib_snapshot_awk "$1" "$2" "${3:-}" "${4:-}"
}

aib_registry_schema_version() {
  aib_registry_query projects schema
}

_aib_snapshot_schema_version() {
  _aib_snapshot_query projects schema
}

aib_require_project() {
  local p="$1"
  if ! aib_registry_query projects has "$p"; then
    aib_die 3 "unknown project_uid: '$p' (not in registry). Known: $(aib_registry_query projects keys | tr '\n' ' ')"
  fi
}

# _aib_project_field_with <query_fn> <project_uid> <field>
_aib_project_field_with() {
  local query="$1" p="$2" f="$3" v rc=0
  v="$("$query" projects field "$p" "$f")" || rc=$?
  [ "$rc" -ne 8 ]  || aib_die 2 "registry: project '$p' field '$f' is not a JSON string"
  [ "$rc" -ne 10 ] || aib_die 2 "registry: project '$p' field '$f' uses a \\u escape this parser cannot decode — write it as raw UTF-8 (refusing to act on a half-decoded value)"
  if [ "$rc" -ne 0 ] || [ -z "$v" ]; then
    aib_die 3 "registry: project '$p' has no usable field '$f'"
  fi
  printf '%s\n' "$v"
}

aib_project_field() {
  _aib_project_field_with aib_registry_query "$1" "$2"
}

_aib_snapshot_project_field() {
  _aib_project_field_with _aib_snapshot_query "$1" "$2"
}

# _aib_agent_field_with <query_fn> <agent_uid> <field>
_aib_agent_field_with() {
  local query="$1" a="$2" f="$3" v rc=0
  v="$("$query" agents field "$a" "$f")" || rc=$?
  [ "$rc" -ne 8 ]  || aib_die 2 "registry: agent '$a' field '$f' is not a JSON string"
  [ "$rc" -ne 10 ] || aib_die 2 "registry: agent '$a' field '$f' uses a \\u escape this parser cannot decode — write it as raw UTF-8 (refusing to act on a half-decoded value)"
  if [ "$rc" -ne 0 ] || [ -z "$v" ]; then
    aib_die 3 "registry: agent '$a' has no usable field '$f'"
  fi
  printf '%s\n' "$v"
}

aib_agent_field() {
  _aib_agent_field_with aib_registry_query "$1" "$2"
}

# Read an optional field from the active registry snapshot without confusing
# absence with an invalid present value. Returns 4 only for true absence; every
# present-empty, non-string, or undecodable value fails closed here.
_aib_snapshot_field() {
  local sect="$1" uid="$2" field="$3" label="$4" value rc=0
  value="$(_aib_snapshot_query "$sect" field "$uid" "$field")" || rc=$?
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
_aib_split_agent_with() {
  local query="$1" agent="$2" project profile clearance key
  aib_validate_agent_uid "$agent"                      # shape validation ONLY

  if ! "$query" agents has "$agent"; then
    aib_die 3 "unknown agent_uid '$agent' (not in registry)"
  fi

  # `project` is mandatory and authoritative — never guessed from the prefix.
  project="$(_aib_agent_field_with "$query" "$agent" project)"
  aib_validate_token "$project" project_uid
  if ! "$query" projects has "$project"; then
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
  profile="$(_aib_agent_field_with "$query" "$agent" profile)"
  aib_validate_token "$profile" profile
  clearance="$(_aib_agent_field_with "$query" "$agent" clearance)"
  aib_validate_clearance "$clearance" "clearance of agent '$agent'"

  AIB_PROJECT_UID="$project"
  AIB_AGENT_KEY="$key"
  AIB_PROFILE="$profile"
  AIB_CLEARANCE="$clearance"
}

aib_split_agent() {
  _aib_split_agent_with aib_registry_query "$1"
}

_aib_split_agent_snapshot() {
  _aib_split_agent_with _aib_snapshot_query "$1"
}

# Resolve one binding field independently through agent -> direct team -> project.
# Sets AIB_RESOLVED_VALUE and AIB_RESOLVED_SOURCE. All lookups use the caller's
# immutable resolver-owned snapshot; only a truly absent field falls through.
_aib_resolve_binding_field() {
  local field="$1" agent="$2" team="$3" project="$4"

  if _aib_snapshot_field agents "$agent" "$field" "agent '$agent'"; then
    AIB_RESOLVED_VALUE="$AIB_SNAPSHOT_FIELD_VALUE"
    AIB_RESOLVED_SOURCE="agent:$agent"
    return 0
  fi
  if [ -n "$team" ] && _aib_snapshot_field teams "$team" "$field" "team '$team'"; then
    AIB_RESOLVED_VALUE="$AIB_SNAPSHOT_FIELD_VALUE"
    AIB_RESOLVED_SOURCE="team:$team"
    return 0
  fi
  if _aib_snapshot_field projects "$project" "$field" "project '$project'"; then
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
  # Initialize both resolver-owned values locally before the canonical file read;
  # same-named ambient variables can neither select nor supply snapshot authority.
  local _AIB_RESOLVER_REGISTRY="" _AIB_RESOLVER_SNAPSHOT=""

  case "$mode" in
    legacy|managed) ;;
    *) aib_die 64 "invalid resolver mode '$mode' (expected: legacy|managed)";;
  esac

  _aib_load_registry_snapshot
  _aib_check_registry_snapshot
  schema="$(_aib_snapshot_schema_version)" || aib_die 2 "registry: cannot read schema_version"
  # Execution binding lives in schema 3 and 4 alike. Schema 4 additionally carries the
  # provider adapter map + declared capabilities (resolved below); whether the adapter
  # is actually present is a POLICY question the PDP decides, not a schema-number branch
  # here — a schema-3 registry simply resolves an empty adapter and the gate denies it.
  if [ "$mode" = managed ]; then
    case "$schema" in
      3|4) ;;
      *) aib_die 3 "managed execution binding requires registry schema_version 3 or 4 (found $schema)";;
    esac
  fi

  _aib_split_agent_snapshot "$agent"
  AIB_AGENT_UID="$agent"
  AIB_REGISTRY_SCHEMA_VERSION="$schema"
  AIB_TEAM_UID=""
  AIB_PROVIDER=""
  AIB_PROVIDER_SOURCE=""
  AIB_MODEL=""
  AIB_MODEL_SOURCE=""
  AIB_EFFORT=""
  AIB_EFFORT_SOURCE=""
  # Schema-4 provider adapter map + declared capabilities. Empty on schema 2/3 (no
  # adapter map): the PDP treats an empty adapter as a fail-closed missing-adapter deny.
  AIB_ADAPTER_PATH=""
  AIB_ADAPTER_SOURCE=""
  AIB_CAP_SANDBOX=""
  AIB_CAP_TIER=""
  AIB_CAP_EFFORT=""

  AIB_HOME="$(_aib_snapshot_project_field "$AIB_PROJECT_UID" home)"
  AIB_STANDUP_DIR="$(_aib_snapshot_project_field "$AIB_PROJECT_UID" standup_dir)"
  AIB_MUX_SESSION="$(_aib_snapshot_project_field "$AIB_PROJECT_UID" mux_session)"
  AIB_INBOX_PATH="${AIB_STANDUP_DIR}/inbox/${agent}.md"

  # Schema 2 remains a legacy identity/context format. It never invents binding.
  case "$schema" in
    3|4) ;;
    *) return 0;;
  esac

  if _aib_snapshot_field agents "$agent" team_uid "agent '$agent'"; then
    team="$AIB_SNAPSHOT_FIELD_VALUE"
    aib_validate_team_uid "$team" "$AIB_PROJECT_UID"
    if ! _aib_snapshot_query teams has "$team"; then
      aib_die 3 "registry: agent '$agent' names unknown direct team '$team'"
    fi
    if ! _aib_snapshot_field teams "$team" project "team '$team'"; then
      aib_die 3 "registry: team '$team' has no project"
    fi
    team_project="$AIB_SNAPSHOT_FIELD_VALUE"
    aib_validate_token "$team_project" "project of team '$team'"
    [ "$team_project" = "$AIB_PROJECT_UID" ] || aib_die 5 \
      "registry inconsistent: team '$team' belongs to project '$team_project', not '$AIB_PROJECT_UID'"
    AIB_TEAM_UID="$team"
  fi

  _aib_resolve_binding_field provider "$agent" "$team" "$AIB_PROJECT_UID"
  provider="$AIB_RESOLVED_VALUE"; provider_source="$AIB_RESOLVED_SOURCE"
  aib_validate_provider "$provider"

  _aib_resolve_binding_field model "$agent" "$team" "$AIB_PROJECT_UID"
  model="$AIB_RESOLVED_VALUE"; model_source="$AIB_RESOLVED_SOURCE"
  aib_validate_model "$model"

  _aib_resolve_binding_field effort "$agent" "$team" "$AIB_PROJECT_UID"
  effort="$AIB_RESOLVED_VALUE"; effort_source="$AIB_RESOLVED_SOURCE"
  aib_validate_effort "$effort"

  AIB_PROVIDER="$provider"
  AIB_PROVIDER_SOURCE="$provider_source"
  AIB_MODEL="$model"
  AIB_MODEL_SOURCE="$model_source"
  AIB_EFFORT="$effort"
  AIB_EFFORT_SOURCE="$effort_source"

  # Schema 4: resolve the provider's adapter path + declared capabilities from the
  # top-level `providers` map (keyed by provider name). These are DECLARED registry
  # data, never runtime-probed. They form the trusted half of the snapshot the PDP
  # consumes; the PDP — not this resolver — decides whether they authorise a launch.
  [ "$schema" = 4 ] || return 0
  _aib_resolve_provider_caps "$provider"
}

# _aib_resolve_provider_caps <provider> — read providers.<provider>.{adapter,
# cap_sandbox,cap_tier,cap_effort} from the active snapshot into AIB_ADAPTER_PATH /
# AIB_CAP_*. A provider absent from the map is fail-closed (the map is the authority
# for what a provider may do); each present field must be a decodable JSON string.
_aib_resolve_provider_caps() {
  local provider="$1"
  if ! _aib_snapshot_query providers has "$provider"; then
    aib_die 3 "registry: provider '$provider' is not declared in the schema-4 adapter map"
  fi
  _aib_snapshot_field providers "$provider" adapter "provider '$provider'" ||
    aib_die 3 "registry: provider '$provider' has no adapter path in the adapter map"
  AIB_ADAPTER_PATH="$AIB_SNAPSHOT_FIELD_VALUE"
  AIB_ADAPTER_SOURCE="provider:$provider"
  _aib_snapshot_field providers "$provider" cap_sandbox "provider '$provider'" ||
    aib_die 3 "registry: provider '$provider' declares no cap_sandbox capability"
  AIB_CAP_SANDBOX="$AIB_SNAPSHOT_FIELD_VALUE"
  _aib_snapshot_field providers "$provider" cap_tier "provider '$provider'" ||
    aib_die 3 "registry: provider '$provider' declares no cap_tier capability"
  AIB_CAP_TIER="$AIB_SNAPSHOT_FIELD_VALUE"
  _aib_snapshot_field providers "$provider" cap_effort "provider '$provider'" ||
    aib_die 3 "registry: provider '$provider' declares no cap_effort capability"
  AIB_CAP_EFFORT="$AIB_SNAPSHOT_FIELD_VALUE"
}

aib_resolve_managed_agent() {
  aib_resolve_agent_snapshot "$1" managed
}

# --- Policy Decision Point (PDP) ----------------------------------------------
# aib_authorize_launch <request-record> <snapshot-record>
#
# The single authority for a managed launch, and a PURE decision function: it reads
# NOTHING from disk, PATH, cwd, or the environment. Every input arrives in the two
# newline-delimited key=value records; the verdict is deterministic over them. That
# purity is what lets RM-3 move this identical function behind a process boundary
# (broker daemon / own uid / container entrypoint): sourced today, exec'd tomorrow,
# identical contract. It MUST NOT call aib_registry_file or any snapshot helper —
# it consumes the already-resolved snapshot value it is handed, and nothing else.
#
#   request  keys:  agent_uid · sandbox (requested) · cwd · timeout · label
#   snapshot keys:  clearance · provider · effort · adapter (absolute) ·
#                   cap_sandbox (ceiling) · cap_tier · cap_effort  (all DECLARED
#                   registry data, resolved by aib_resolve_managed_agent, never probed)
#
# Authority lives ONLY here: the sandbox ceiling, min(clearance, cap_tier), and the
# effort cap are computed in this function and nowhere else — the PEP (launch-agent /
# codex-run) consumes the verdict and does the launch, it never re-decides.
#
# Publishes the verdict via AIB_VERDICT_* globals (house style):
#   AIB_VERDICT_DECISION             allow | deny
#   AIB_VERDICT_CODE                 0 on allow; else the exit code the PEP should use
#                                    (64 refusal · 2 config/IO · 127 adapter-not-found)
#   AIB_VERDICT_REASONS              '; '-joined causes (deny reasons, or allow-time clamps)
#   AIB_VERDICT_EFFECTIVE_CLEARANCE  min(clearance, cap_tier)      (empty on deny)
#   AIB_VERDICT_EFFECTIVE_SANDBOX    min(requested, cap_sandbox)   (empty on deny)
#   AIB_VERDICT_EFFECTIVE_EFFORT     min(effort, cap_effort)       (empty on deny)
#   AIB_VERDICT_ADAPTER_PATH         the absolute adapter path     (empty on deny)
#   AIB_VERDICT_ENV_ALLOW            child-env allow-list (see AIB_ENV_ALLOW_DEFAULT)
#   AIB_VERDICT_PROVIDER · _AGENT_UID   echoed for the record
#   AIB_VERDICT_RECORD               one-line JSON, managed_launch_binding shape family,
#                                    so RM-2's durable Attempt audit reuses the schema.

# Child environment is CONSTRUCTED from this allow-list (Lane B's `env -i`), never
# scrubbed by denylist — a denylist is never complete, and RM-3's confined environment
# is allow-list-constructed by definition. This default is the STRUCTURAL FLOOR only:
# Lane B finalises the exact set from an empirical `env -i` smoke launch (at minimum
# HOME, a sanitized PATH, and the provider-auth var that today leaks in SILENTLY by
# inheritance — none named anywhere yet). TO BE FINALISED BY LANE B; not complete.
AIB_ENV_ALLOW_DEFAULT="HOME PATH"

# _aib_record_field <record> <key> -> value on stdout; rc 0 present, rc 1 absent.
# Newline-delimited key=value; the FIRST '=' splits (a value may contain '='). Pure
# parameter expansion: no here-string, no subshell, no temp file — deterministic over
# the input string alone, so the purity claim holds even under `env -i`.
_aib_record_field() {
  local key="$2" rest="$1" line
  while [ -n "$rest" ]; do
    line="${rest%%$'\n'*}"
    case "$rest" in
      *$'\n'*) rest="${rest#*$'\n'}";;
      *) rest="";;
    esac
    case "$line" in
      "$key="*) printf '%s' "${line#"$key="}"; return 0;;
    esac
  done
  return 1
}

# _aib_rank <tier|sandbox|effort> <token> -> sets _AIB_RANK (0 = unknown/invalid).
# The three total orders the PDP takes minima over. Forkless (no subshell).
_aib_rank() {
  case "$1:$2" in
    tier:t1) _AIB_RANK=1;; tier:t2) _AIB_RANK=2;; tier:t3) _AIB_RANK=3;; tier:t4) _AIB_RANK=4;;
    sandbox:read-only) _AIB_RANK=1;; sandbox:workspace-write) _AIB_RANK=2;;
    sandbox:danger-full-access) _AIB_RANK=3;;
    effort:low) _AIB_RANK=1;; effort:medium) _AIB_RANK=2;; effort:high) _AIB_RANK=3;;
    effort:max) _AIB_RANK=4;;
    *) _AIB_RANK=0;;
  esac
}

# Deny/clamp accumulators mutate the caller's dynamically-scoped locals (deny, code,
# reasons) — the same dynamic-scope idiom the journal decider uses. First deny wins
# the code because the checks are ordered by severity (127 > 2 > 64).
_aib_verdict_deny() {
  reasons="${reasons:+$reasons; }$2"
  [ "$deny" -eq 1 ] || code="$1"
  deny=1
}
_aib_verdict_note() {
  reasons="${reasons:+$reasons; }$1"
}

aib_authorize_launch() {
  local request="${1-}" snapshot="${2-}"
  local agent_uid req_sandbox cwd timeout label
  local clearance provider effort adapter cap_sandbox cap_tier cap_effort
  local deny=0 code=0 reasons=""
  local eff_clearance="" eff_sandbox="" eff_effort=""
  local rreq rcap

  # --- unpack both records (pure; an absent optional field is empty) -----------
  agent_uid="$(_aib_record_field "$request" agent_uid)"   || agent_uid=""
  req_sandbox="$(_aib_record_field "$request" sandbox)"   || req_sandbox=""
  cwd="$(_aib_record_field "$request" cwd)"               || cwd=""
  timeout="$(_aib_record_field "$request" timeout)"       || timeout=""
  label="$(_aib_record_field "$request" label)"           || label=""
  clearance="$(_aib_record_field "$snapshot" clearance)"  || clearance=""
  provider="$(_aib_record_field "$snapshot" provider)"    || provider=""
  effort="$(_aib_record_field "$snapshot" effort)"        || effort=""
  adapter="$(_aib_record_field "$snapshot" adapter)"      || adapter=""
  cap_sandbox="$(_aib_record_field "$snapshot" cap_sandbox)" || cap_sandbox=""
  cap_tier="$(_aib_record_field "$snapshot" cap_tier)"    || cap_tier=""
  cap_effort="$(_aib_record_field "$snapshot" cap_effort)" || cap_effort=""

  # --- deny checks, ordered by severity (adapter 127 > config 2 > refusal 64) --
  # Adapter map is the authority for what a provider may run: an absent adapter is a
  # fail-closed missing-adapter deny (the PEP maps this to exit 127), and it also
  # subsumes the "unknown provider" case (an unknown provider resolves no adapter).
  if [ -z "$adapter" ]; then
    _aib_verdict_deny 127 "provider '${provider:-?}' resolves no adapter path (unknown provider or empty adapter map entry)"
  else
    case "$adapter" in
      /*) ;;
      *) _aib_verdict_deny 2 "adapter path '$adapter' is not absolute (the adapter map must hold an absolute, cwd-independent path)";;
    esac
  fi

  # Declared capabilities must be present and well-formed — they bound the authority.
  _aib_rank sandbox "$cap_sandbox"
  [ "$_AIB_RANK" -ne 0 ] || _aib_verdict_deny 2 "provider '${provider:-?}' declares no valid sandbox capability (cap_sandbox='$cap_sandbox')"
  _aib_rank tier "$cap_tier"
  [ "$_AIB_RANK" -ne 0 ] || _aib_verdict_deny 2 "provider '${provider:-?}' declares no valid tier capability (cap_tier='$cap_tier')"
  _aib_rank effort "$cap_effort"
  [ "$_AIB_RANK" -ne 0 ] || _aib_verdict_deny 2 "provider '${provider:-?}' declares no valid effort capability (cap_effort='$cap_effort')"

  # Request/identity form (input hygiene the caller also enforces; re-checked here so
  # the PDP is safe to call in isolation and under RM-3's process boundary).
  [ -n "$agent_uid" ] || _aib_verdict_deny 64 "request names no agent_uid"
  _aib_rank sandbox "$req_sandbox"
  [ "$_AIB_RANK" -ne 0 ] || _aib_verdict_deny 64 "requested sandbox '$req_sandbox' is not a recognised mode"
  _aib_rank tier "$clearance"
  [ "$_AIB_RANK" -ne 0 ] || _aib_verdict_deny 64 "agent clearance '$clearance' is not a recognised tier"
  _aib_rank effort "$effort"
  [ "$_AIB_RANK" -ne 0 ] || _aib_verdict_deny 64 "resolved effort '$effort' is not a recognised level"

  if [ "$deny" -eq 0 ]; then
    # --- allow path: every effective value is a min(request/registry, capability) --
    # Clamping (not denial) is the whole point of a min: the launch proceeds at the
    # lower, safer bound. A request above a ceiling never GRANTS the higher value.
    local rc1 rc2
    _aib_rank tier "$clearance"; rc1="$_AIB_RANK"
    _aib_rank tier "$cap_tier";  rc2="$_AIB_RANK"
    if [ "$rc1" -le "$rc2" ]; then eff_clearance="$clearance"
    else eff_clearance="$cap_tier"; _aib_verdict_note "clearance '$clearance' exceeds provider tier ceiling '$cap_tier'; clamped to '$cap_tier'"; fi

    _aib_rank sandbox "$req_sandbox"; rreq="$_AIB_RANK"
    _aib_rank sandbox "$cap_sandbox"; rcap="$_AIB_RANK"
    if [ "$rreq" -le "$rcap" ]; then eff_sandbox="$req_sandbox"
    else eff_sandbox="$cap_sandbox"; _aib_verdict_note "requested sandbox '$req_sandbox' exceeds provider ceiling '$cap_sandbox'; clamped to '$cap_sandbox'"; fi

    _aib_rank effort "$effort";     rc1="$_AIB_RANK"
    _aib_rank effort "$cap_effort"; rc2="$_AIB_RANK"
    if [ "$rc1" -le "$rc2" ]; then eff_effort="$effort"
    else eff_effort="$cap_effort"; _aib_verdict_note "effort '$effort' exceeds provider cap '$cap_effort'; clamped to '$cap_effort'"; fi
  fi

  # --- publish the verdict -----------------------------------------------------
  AIB_VERDICT_AGENT_UID="$agent_uid"
  AIB_VERDICT_PROVIDER="$provider"
  AIB_VERDICT_REASONS="$reasons"
  AIB_VERDICT_ENV_ALLOW="$AIB_ENV_ALLOW_DEFAULT"
  if [ "$deny" -eq 1 ]; then
    AIB_VERDICT_DECISION="deny"
    AIB_VERDICT_CODE="$code"
    AIB_VERDICT_EFFECTIVE_CLEARANCE=""
    AIB_VERDICT_EFFECTIVE_SANDBOX=""
    AIB_VERDICT_EFFECTIVE_EFFORT=""
    AIB_VERDICT_ADAPTER_PATH=""
  else
    AIB_VERDICT_DECISION="allow"
    AIB_VERDICT_CODE=0
    AIB_VERDICT_EFFECTIVE_CLEARANCE="$eff_clearance"
    AIB_VERDICT_EFFECTIVE_SANDBOX="$eff_sandbox"
    AIB_VERDICT_EFFECTIVE_EFFORT="$eff_effort"
    AIB_VERDICT_ADAPTER_PATH="$adapter"
  fi

  AIB_VERDICT_RECORD="$(printf '{"event":"launch_verdict","agent_uid":%s,"provider":%s,"decision":%s,"code":%s,"effective_clearance":%s,"effective_sandbox":%s,"effective_effort":%s,"adapter_path":%s}' \
    "$(aib_json "$AIB_VERDICT_AGENT_UID")" \
    "$(aib_json "$AIB_VERDICT_PROVIDER")" \
    "$(aib_json "$AIB_VERDICT_DECISION")" \
    "$AIB_VERDICT_CODE" \
    "$(aib_json "$AIB_VERDICT_EFFECTIVE_CLEARANCE")" \
    "$(aib_json "$AIB_VERDICT_EFFECTIVE_SANDBOX")" \
    "$(aib_json "$AIB_VERDICT_EFFECTIVE_EFFORT")" \
    "$(aib_json "$AIB_VERDICT_ADAPTER_PATH")")"

  [ "$deny" -eq 0 ]
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
