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

# --- JSON string encoder (audit-grade) ----------------------------------------
# Encodes a shell string as a JSON string literal. It escapes backslash and quote
# AND every JSON control byte (U+0000–U+001F): the well-known ones via their short
# escapes (\n \t \r \b \f) and any remaining control byte via \u00XX. A NUL can never
# reach here (bash cannot hold one in a variable). Valid UTF-8 bytes ≥ U+0020 pass
# through verbatim; invalid UTF-8 is rejected fail-closed. Nothing is ever passed
# through raw that JSON requires escaped: the RM-2 audit payloads carry arbitrary
# label/reason text, so a control byte MUST be encoded, never emitted literally (which
# would also forge a second physical line and break the framed stream). LC_ALL=C makes
# the scan byte-deterministic; correctness does not depend on the locale switch taking
# effect (a lone control byte is a single byte and sorts below space in any locale).
_aib_utf8_is_valid() {
  local input="$1" LC_ALL=C length index char byte second third fourth
  case "$input" in
    *[$'\200'-$'\377']*) ;;
    *) return 0;;
  esac
  length=${#input}
  index=0
  while [ "$index" -lt "$length" ]; do
    char="${input:index:1}"
    printf -v byte '%d' "'$char"
    if [ "$byte" -le 127 ]; then
      index=$((index + 1))
      continue
    fi
    if [ "$byte" -ge 194 ] && [ "$byte" -le 223 ]; then
      [ $((index + 1)) -lt "$length" ] || return 1
      printf -v second '%d' "'${input:index+1:1}"
      [ "$second" -ge 128 ] && [ "$second" -le 191 ] || return 1
      index=$((index + 2))
      continue
    fi
    if [ "$byte" -ge 224 ] && [ "$byte" -le 239 ]; then
      [ $((index + 2)) -lt "$length" ] || return 1
      printf -v second '%d' "'${input:index+1:1}"
      printf -v third '%d' "'${input:index+2:1}"
      [ "$third" -ge 128 ] && [ "$third" -le 191 ] || return 1
      case "$byte" in
        224) [ "$second" -ge 160 ] && [ "$second" -le 191 ] || return 1;;
        237) [ "$second" -ge 128 ] && [ "$second" -le 159 ] || return 1;;
        *) [ "$second" -ge 128 ] && [ "$second" -le 191 ] || return 1;;
      esac
      index=$((index + 3))
      continue
    fi
    if [ "$byte" -ge 240 ] && [ "$byte" -le 244 ]; then
      [ $((index + 3)) -lt "$length" ] || return 1
      printf -v second '%d' "'${input:index+1:1}"
      printf -v third '%d' "'${input:index+2:1}"
      printf -v fourth '%d' "'${input:index+3:1}"
      [ "$third" -ge 128 ] && [ "$third" -le 191 ] || return 1
      [ "$fourth" -ge 128 ] && [ "$fourth" -le 191 ] || return 1
      case "$byte" in
        240) [ "$second" -ge 144 ] && [ "$second" -le 191 ] || return 1;;
        244) [ "$second" -ge 128 ] && [ "$second" -le 143 ] || return 1;;
        *) [ "$second" -ge 128 ] && [ "$second" -le 191 ] || return 1;;
      esac
      index=$((index + 4))
      continue
    fi
    return 1
  done
  return 0
}

aib_json() {
  local s="$1" out="" ch esc i len LC_ALL=C
  _aib_utf8_is_valid "$s" || aib_die 2 "JSON string input is not valid UTF-8"
  len=${#s}
  for (( i=0; i<len; i++ )); do
    ch="${s:i:1}"
    case "$ch" in
      '\') out+='\\' ;;
      '"') out+='\"' ;;
      $'\n') out+='\n' ;;
      $'\t') out+='\t' ;;
      $'\r') out+='\r' ;;
      $'\b') out+='\b' ;;
      $'\f') out+='\f' ;;
      *)
        if [[ "$ch" < " " ]]; then
          printf -v esc '\\u%04x' "'$ch"
          out+="$esc"
        else
          out+="$ch"
        fi
        ;;
    esac
  done
  printf '"%s"' "$out"
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
  # ONE registry open. `$(<file)` silently DROPS embedded NUL bytes, so a torn or
  # tampered registry could resolve identity from a value a strict reader would
  # never see — and the registry crosses into line-oriented key=value / journal
  # protocols where a decoded NUL is unsafe. `read -r -d ''` reads until the first
  # NUL: rc=0 means a NUL delimiter WAS found (reject, loud); rc>0 is the ordinary
  # EOF case where the variable now holds the complete file content. Detection is by
  # `read`'s return status alone — a bash var cannot hold a NUL, so inspecting the
  # string would need a SECOND read, exactly the double-open that deadlocked the
  # one-write FIFO seam in the retired hotfix. Stays a single redirect.
  if IFS= read -r -d '' _AIB_RESOLVER_SNAPSHOT < "$_AIB_RESOLVER_REGISTRY"; then
    aib_die 2 "registry contains a raw NUL byte — refusing unsafe identity/clearance data: $_AIB_RESOLVER_REGISTRY"
  fi
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

# Validate EVERY team key at load time, not only the one an agent happens to
# reference. Lazy per-reference validation (aib_validate_team_uid at the point of
# use) let a malformed, unreferenced team key sit silently in the registry until
# first use — RM-0 finding #3. The teams map is authority data: a team whose uid
# disagrees with its own declared project means the file is inconsistent even if no
# agent points at it yet, so it is a loud fail-closed at load. Each key is checked
# against ITS OWN declared project (a registry may carry teams for several projects).
# The while-loop stays in the current shell (here-doc, not a pipe) so aib_die's exit
# aborts the caller rather than a subshell. Snapshot-only: never re-opens the file.
_aib_validate_all_team_keys() {
  local team team_project
  # teams is optional: an absent OR empty section makes `keys` yield no lines, so
  # the loop simply never runs and there is nothing to validate.
  while IFS= read -r team; do
    [ -n "$team" ] || continue
    _aib_snapshot_field teams "$team" project "team '$team'" ||
      aib_die 3 "registry: team '$team' has no project"
    team_project="$AIB_SNAPSHOT_FIELD_VALUE"
    aib_validate_token "$team_project" "project of team '$team'"
    aib_validate_team_uid "$team" "$team_project"
  done <<EOF
$(_aib_snapshot_query teams keys)
EOF
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
  AIB_CAP_TIMEOUT=""

  AIB_HOME="$(_aib_snapshot_project_field "$AIB_PROJECT_UID" home)"
  AIB_STANDUP_DIR="$(_aib_snapshot_project_field "$AIB_PROJECT_UID" standup_dir)"
  AIB_MUX_SESSION="$(_aib_snapshot_project_field "$AIB_PROJECT_UID" mux_session)"
  AIB_INBOX_PATH="${AIB_STANDUP_DIR}/inbox/${agent}.md"

  # Schema 2 remains a legacy identity/context format. It never invents binding.
  case "$schema" in
    3|4) ;;
    *) return 0;;
  esac

  # Validate EVERY team key at load, before any binding resolution — an inconsistent
  # team key anywhere in the registry is a load-time fault, not a lazily-discovered
  # one (RM-0 finding #3).
  _aib_validate_all_team_keys

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
  # RM-3 slice 2: resource authority does not belong to the caller (§3), so the cap
  # is declared registry data like the other three, resolved the same way and
  # required the same way — not a slice-2-only special case.
  _aib_snapshot_field providers "$provider" cap_timeout "provider '$provider'" ||
    aib_die 3 "registry: provider '$provider' declares no cap_timeout capability"
  AIB_CAP_TIMEOUT="$AIB_SNAPSHOT_FIELD_VALUE"
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
#                   cap_sandbox (ceiling) · cap_tier · cap_effort · cap_timeout
#                   (all DECLARED registry data, resolved by aib_resolve_managed_agent,
#                   never probed)
#
# Authority lives ONLY here: the sandbox ceiling, min(clearance, cap_tier), the
# effort cap, and (RM-3 slice 2) the timeout cap are computed in this function and
# nowhere else — the PEP (launch-agent / codex-run) consumes the verdict and does the
# launch, it never re-decides.
#
# Publishes the verdict via AIB_VERDICT_* globals (house style):
#   AIB_VERDICT_DECISION             allow | deny
#   AIB_VERDICT_CODE                 0 on allow; else the exit code the PEP should use
#                                    (64 refusal · 2 config/IO · 127 adapter-not-found)
#   AIB_VERDICT_REASONS              '; '-joined causes (deny reasons, or allow-time clamps)
#   AIB_VERDICT_EFFECTIVE_CLEARANCE  min(clearance, cap_tier)      (empty on deny)
#   AIB_VERDICT_EFFECTIVE_SANDBOX    min(requested, cap_sandbox)   (empty on deny)
#   AIB_VERDICT_EFFECTIVE_EFFORT     min(effort, cap_effort)       (empty on deny)
#   AIB_VERDICT_EFFECTIVE_TIMEOUT    min(requested, cap_timeout); cap alone if absent
#                                    (empty on deny) — never max (§3: resource
#                                    authority does not belong to the caller)
#   AIB_VERDICT_ADAPTER_PATH         the absolute adapter path     (empty on deny)
#   AIB_VERDICT_ENV_ALLOW            child-env allow-list (see AIB_ENV_ALLOW_DEFAULT)
#   AIB_VERDICT_PROVIDER · _AGENT_UID   echoed for the record
#   AIB_VERDICT_RECORD               one-line JSON, managed_launch_binding shape family,
#                                    so RM-2's durable Attempt audit reuses the schema.

# Child environment is CONSTRUCTED from this allow-list (`env -i`), never scrubbed by
# denylist — a denylist is never complete, and RM-3's confined environment is
# allow-list-constructed by definition. The set is FINALISED (empirical `env -i` smoke
# launch): the codex adapter needs HOME (its ~/.codex config dir and file-based
# auth.json) and PATH (its node runtime + helpers). The parent PATH is passed through
# verbatim — acceptable under RM-1's cooperating-agent threat model because the adapter
# itself is resolved to an absolute path. PRECONDITION: provider auth must be
# FILE-BASED (auth.json); an env-var API key (e.g. OPENAI_API_KEY) is NOT in the
# allow-list and does not survive `env -i`, so the provider would fail auth. This is a
# documented deployment requirement (docs/CONTRACT-execution-binding.md), not a gap.
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

# _aib_valid_positive_int <value> -> rc 0 if value is one or more digits and > 0.
# `timeout` has no enum, so it does not go through _aib_rank; this is its equivalent
# form check (SPEC-wire-format: "digits + range"), used identically for the request
# value and the declared cap. No upper bound here — the cap IS the upper bound, and
# the PDP takes min(requested, cap), never max.
_aib_valid_positive_int() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -gt 0 ] 2>/dev/null
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
  local clearance provider effort adapter cap_sandbox cap_tier cap_effort cap_timeout
  local deny=0 code=0 reasons=""
  local eff_clearance="" eff_sandbox="" eff_effort="" eff_timeout=""
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
  cap_timeout="$(_aib_record_field "$snapshot" cap_timeout)" || cap_timeout=""

  # --- deny checks, ordered by severity (adapter 127 > config 2 > refusal 64) --
  # Adapter map is the authority for what a provider may run: an absent adapter is a
  # fail-closed missing-adapter deny (the PEP maps this to exit 127). On schema 3 this
  # also subsumes the "unknown provider" case (no adapter map, so the adapter resolves
  # empty). On schema 4 a provider named but absent from the `providers` map is caught
  # earlier by the resolver (exit 3, config error) and never reaches this PDP branch.
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
  # RM-3 slice 2: cap_timeout joins the other three provider capabilities. Absent or
  # malformed is a config deny, exactly like an absent/invalid cap_sandbox above —
  # resource authority does not belong to the caller, so there is no "no cap" default.
  _aib_valid_positive_int "$cap_timeout" ||
    _aib_verdict_deny 2 "provider '${provider:-?}' declares no valid timeout capability (cap_timeout='$cap_timeout')"

  # Request/identity form (input hygiene the caller also enforces; re-checked here so
  # the PDP is safe to call in isolation and under RM-3's process boundary).
  [ -n "$agent_uid" ] || _aib_verdict_deny 64 "request names no agent_uid"
  _aib_rank sandbox "$req_sandbox"
  [ "$_AIB_RANK" -ne 0 ] || _aib_verdict_deny 64 "requested sandbox '$req_sandbox' is not a recognised mode"
  _aib_rank tier "$clearance"
  [ "$_AIB_RANK" -ne 0 ] || _aib_verdict_deny 64 "agent clearance '$clearance' is not a recognised tier"
  _aib_rank effort "$effort"
  [ "$_AIB_RANK" -ne 0 ] || _aib_verdict_deny 64 "resolved effort '$effort' is not a recognised level"
  # timeout is the one OPTIONAL request field: absent means "use the cap outright",
  # not "malformed". Only a PRESENT, malformed value is a form deny (SPEC-wire-format,
  # "timeout: TWO checks are missing, not one" — this is the PDP's own half, re-checked
  # independently of whatever the wire already validated).
  if [ -n "$timeout" ]; then
    _aib_valid_positive_int "$timeout" ||
      _aib_verdict_deny 64 "requested timeout '$timeout' is not a positive integer"
  fi

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

    # timeout has no rank table (it is not an enum): compare numerically. An absent
    # request means "no opinion", so the cap applies outright — that is still a min,
    # just over a one-element set. Never max: a request above the cap is a clamp,
    # never a grant of more time than the provider declared.
    if [ -z "$timeout" ]; then
      eff_timeout="$cap_timeout"
    elif [ "$timeout" -le "$cap_timeout" ]; then
      eff_timeout="$timeout"
    else
      eff_timeout="$cap_timeout"
      _aib_verdict_note "timeout '$timeout' exceeds provider cap '$cap_timeout'; clamped to '$cap_timeout'"
    fi
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
    AIB_VERDICT_EFFECTIVE_TIMEOUT=""
    AIB_VERDICT_ADAPTER_PATH=""
  else
    AIB_VERDICT_DECISION="allow"
    AIB_VERDICT_CODE=0
    AIB_VERDICT_EFFECTIVE_CLEARANCE="$eff_clearance"
    AIB_VERDICT_EFFECTIVE_SANDBOX="$eff_sandbox"
    AIB_VERDICT_EFFECTIVE_EFFORT="$eff_effort"
    AIB_VERDICT_EFFECTIVE_TIMEOUT="$eff_timeout"
    AIB_VERDICT_ADAPTER_PATH="$adapter"
  fi

  AIB_VERDICT_RECORD="$(printf '{"event":"launch_verdict","agent_uid":%s,"provider":%s,"decision":%s,"code":%s,"effective_clearance":%s,"effective_sandbox":%s,"effective_effort":%s,"effective_timeout":%s,"adapter_path":%s}' \
    "$(aib_json "$AIB_VERDICT_AGENT_UID")" \
    "$(aib_json "$AIB_VERDICT_PROVIDER")" \
    "$(aib_json "$AIB_VERDICT_DECISION")" \
    "$AIB_VERDICT_CODE" \
    "$(aib_json "$AIB_VERDICT_EFFECTIVE_CLEARANCE")" \
    "$(aib_json "$AIB_VERDICT_EFFECTIVE_SANDBOX")" \
    "$(aib_json "$AIB_VERDICT_EFFECTIVE_EFFORT")" \
    "$(aib_json "$AIB_VERDICT_EFFECTIVE_TIMEOUT")" \
    "$(aib_json "$AIB_VERDICT_ADAPTER_PATH")")"

  [ "$deny" -eq 0 ]
}

# aib_contain_cwd <root> <cwd> -> AIB_CWD_RESOLVED; rc 0 accepted, rc 1 refused.
# On refusal, AIB_CONTAIN_CWD_REASON is one of:
#   not_found     — root or (resolved) cwd does not exist, or `realpath` is missing
#   outside_root  — both exist, but the resolved cwd is not inside the resolved root
#
# RM-3 slice 2 (SPEC-wire-format, "cwd — the field that stops carrying authority").
# `root` is the registry-derived writable area (AIB_HOME from the managed resolver);
# the REQUEST NEVER CHOOSES IT — a cage whose bars the prisoner picks is not a cage.
# `cwd` only selects where inside that already-fixed area the child starts.
#
# RM-3 slice 2 delta (gate finding, Ikarus D2, HIGH): resolution used `realpath -m`,
# which resolves a path LEXICALLY without requiring it to exist. A `cwd` naming a
# not-yet-existing path was authorised against that lexical resolution; if a symlink
# was then planted at that exact path before the later `cd`, the child would land
# wherever the symlink pointed — outside the root — a TOCTOU the authorisation step
# itself created room for. Decision (maintainer): resolution now REQUIRES existence
# (`realpath -e`), which also fully resolves any symlink components, so cwd/root are
# compared as their real, current targets, not as strings that merely look contained.
# A cwd that does not exist yet is refused (`not_found`) rather than lexically
# accepted — this is the "cwd exists" assurance moving behind the seam, exactly as
# SPEC-wire-format's "Assurances that must move with authorize" table anticipated.
#
# This closes the PLANT-BEFORE-AUTHORISE window. It does NOT close a REPLACE-AFTER-
# AUTHORISE window: a symlink swapped in at the resolved path after this function
# returns and before the later `cd` would still redirect it. That window is closed at
# enactment (slice 3), not here — see the handler header and SPEC-wire-format's
# "Order is part of the requirement" for the re-check this function's caller owes
# after `cd`, before `exec`.
#
# Both paths are resolved and the resolved cwd must sit inside the resolved root on a
# PATH-COMPONENT boundary: "/srv/ws2" is NOT inside "/srv/ws", even though it shares
# the string prefix "/srv/ws" — and root "/" DOES contain "/etc" even though "/etc"
# does not share the (empty, after stripping the trailing slash) string prefix
# character-for-character (gate finding, Ikarus D3, MEDIUM: the naive
# "$resolved_root/*" pattern built "//*' for root "/", which nothing starting with a
# single "/" can ever match). A character-class path grammar would be a guessing game
# against symlinks and normalisation; comparing resolved paths is a decision
# (SPEC-wire-format, "What containment can decide, no character class should have to
# guess"). This function decides only inside/outside; it does not install Landlock or
# change directory — those are enactment (slice 3).
aib_contain_cwd() {
  local root="${1-}" cwd="${2-}" realpath_bin resolved_root resolved_cwd root_prefix
  AIB_CWD_RESOLVED=""
  AIB_CONTAIN_CWD_REASON=""
  realpath_bin="$(command -v realpath)" || { AIB_CONTAIN_CWD_REASON="not_found"; return 1; }
  [ -n "$root" ] || { AIB_CONTAIN_CWD_REASON="not_found"; return 1; }
  # An absent cwd means the derived root, the same as an explicit empty cwd_bytes
  # block (SPEC-wire-format, "Two edges") — both resolve here rather than being an
  # unspecified edge case one layer up.
  [ -n "$cwd" ] || cwd="$root"
  resolved_root="$("$realpath_bin" -e -- "$root" 2>/dev/null)" || { AIB_CONTAIN_CWD_REASON="not_found"; return 1; }
  resolved_cwd="$("$realpath_bin" -e -- "$cwd" 2>/dev/null)" || { AIB_CONTAIN_CWD_REASON="not_found"; return 1; }
  # Root "/" resolves to "/" itself; treat it as the empty prefix so the descendant
  # pattern becomes "/*", not "//*" (which nothing with a single leading "/" matches).
  root_prefix="$resolved_root"
  [ "$root_prefix" != "/" ] || root_prefix=""
  case "$resolved_cwd" in
    "$resolved_root") : ;;
    "$root_prefix"/*) : ;;
    *) AIB_CONTAIN_CWD_REASON="outside_root"; return 1 ;;
  esac
  AIB_CWD_RESOLVED="$resolved_cwd"
  return 0
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

# =============================================================================
# RM-2 — framed event primitive (the first spine-conformant stream)
# =============================================================================
# This section is the durable-attempt-audit foundation. It is the writer AND the
# read-only scan/validate interface for one framed, sequenced stream per project.
# The legacy journals (Delivery/Memory/Heartbeat, ADR-0001) are NOT retrofitted —
# they keep their unframed line protocol. This stream is the envelope's first real
# customer, not a third ad-hoc line format.
#
# --- FROZEN SCHEMA (envelope + payload) --------------------------------------
# Stream identity: (project_uid, "main"). File: <standup_dir>/events/main.events
# with a separate sidecar lock <...>/main.events.lock. The `.events` (not `.jsonl`)
# name is deliberate: a record is NOT bare JSON, it is framed.
#
# FRAME (§B5, Tim decision B) — pure transport, parsed strictly positionally from
# line-start; a crafted body cannot push bytes before the line start, so there is no
# forgery vector, and the reader never reconstructs an envelope field from the prefix:
#
#     <seq> SP <crc> SP <len> SP <json> LF
#
#   token 1  seq   decimal, writer-assigned, monotonic +1 within the stream
#   token 2  crc   POSIX `cksum` CRC over EXACTLY the <json> bytes
#   token 3  len   byte count of EXACTLY the <json> bytes (one `cksum` yields both)
#   rest     json  the event object, starting at `{`; contains no LF/CR
#   term     LF    the LF is the commit marker: an unterminated final record is
#                  uncommitted (never ACKed), not a committed-but-corrupt one.
# The encoded JSON record is capped at AIB_EVENT_MAX_RECORD_BYTES before framing and
# append. Payload JSON crossing the broker seam must come from the frozen composers
# below; they are the JSON-validity authority because the runtime has no JSON parser.
# Both crc AND len must match: len catches a chance CRC collision or a shifted SP in
# the prefix. seq is NOT a §5 envelope field (§6 only requires it live in the source
# records — it does, in the framing layer); the reader cross-checks it against the
# seq embedded in the crc-protected event_id, tying prefix to body.
#
# ENVELOPE (DOMAIN §5, additive-only) — every field present, absent optionals emitted
# as JSON null so the shape is stable for readers:
#   event_id        "<project_uid>-main-<seq>" — deterministic from (stream, seq),
#                   host- and restart-unique WITHOUT a clock. COMPOSED IN-LOCK by the
#                   broker after seq allocation; the caller never pre-composes it (§B4).
#   event_type      "attempt.decided" | "attempt.ended"
#   occurred_at     ISO-8601 UTC, DISPLAY ONLY (§6); uniqueness never depends on it.
#   actor_type      human|agent|service|provider  (RM-2 attempts: service)
#   actor_id        REQUIRED (§B7) — the service/actor that observed the decision.
#   project_uid     the stream's project.
#   team_uid, agent_uid, session_id, run_id, task_id, gate_id, grant_id, effect_id
#                   optional envelope fields; null when not applicable (agent_uid MAY
#                   be null when actor_type≠agent, §5).
#   attempt_id      the grouping identity. For attempt.decided it EQUALS its own
#                   event_id; for attempt.ended it equals the decided event_id passed
#                   in by the caller. Inherits the under-lock seq uniqueness (§B4) —
#                   the wall-clock/PID label some callers keep is display only, never
#                   the grouping authority.
#   correlation_id  = attempt_id (groups the attempt's records).
#   causation_id    decided: its own event_id (root). ended: the decided event_id
#                   (the persisted id returned by the broker, never re-guessed, §B4).
#   schema_version  AIB_EVENT_SCHEMA_VERSION (the ENVELOPE version, not the registry's).
#   payload         the per-type object below.
#
# PAYLOAD — attempt.decided (write-ahead intent for allow; the single record for deny):
#   decision  allow|deny · code (int) · reasons (the verdict's '; '-joined text; ""=none)
#   provider/model/effort: each a {requested, resolved, source, effective} object.
#     requested is frozen as null in RM-2 because no direct CLI request exists today.
#     NULL/EMPTY
#     SEMANTICS (§B7): `resolved` is always populated (the binding is resolved before
#     the PDP), so a DENY that BLANKS `effective` to null is distinguishable from a
#     genuinely UNRESOLVED value (where `resolved` is null too). `requested` is not a
#     CLI input for these three today; the schema slot is reserved additively.
#   sandbox: {requested, effective} — the one dimension with a real CLI request.
#   adapter: {raw (the map value), effective_path (the verdict's absolute path, null on
#     deny), source}.
#   pid: the PEP parent PID (reader-side presumed-dead check) · prompt: {len, sha256}
#     — the prompt NEVER enters a record, only its length + hash (§6) · label + label_len
#     (label is user input: capped at AIB_EVENT_MAX_LABEL_BYTES and control-byte-encoded
#     here).
#   There is NO exit field on attempt.decided (omitted, not null, §B7).
#
# PAYLOAD — attempt.ended (allow-path terminal only):
#   exit: {class, code, signal, stage}. class ∈ ok|provider-failure|timeout|io-refused|
#     aborted — a genuinely observed terminal value only. `presumed-dead` is NEVER a
#     payload value (§B7): it is exclusively a reader-side fold classification of an
#     open decided(allow) whose recorded PID has vanished. The composer rejects it
#     fail-closed. `stage` (RM-3 slice 3, schema version 2, CONTRACT-execution-binding
#     §8.1, D-K) ∈ confine|cwd|exec|provider|transport|null — which phase of enactment the
#     terminal status belongs to, so a helper-side refusal is never misread as the
#     provider's own outcome. Always supplied by every real writer; `null` only on a
#     record composed under schema version 1 (pre-slice-3), which a reader folds the
#     same as "unknown", never as a refused record.
#
# QUARANTINE (§B6, fail-closed):
#   uncommitted tail — ONLY the last record AND only unterminated (no trailing LF): the
#     writer truncates main.events in place at the last intact LF boundary (the file
#     stays the single authoritative path — no rename, no second file), the bytes were
#     never ACKed so are never replayed, and the writer resumes at last-intact seq+1.
#   corrupt (fail-closed) — any TERMINATED record with crc/len mismatch, a non-object
#     body, or an unparsable line: the stream is corrupt; the fold refuses a verdict AND
#     the writer refuses the append (tail-validation under the lock fails → launch
#     fail-closed). Audit corruption is a launch-stopper by doctrine; the DoS facet is
#     bounded by the finite lock timeout below.
#   lost (inner seq gaps) — reported as `degraded` (a gap is loss, not corruption); the
#     writer resumes above the highest valid seq and does NOT block.
#   NOT detectable without an external cursor: whole-suffix / file replacement (a
#     persistent high-water anchor sits in the same trust domain — it is the RM-3 close).

# RM-3 slice 3 bumps 1 -> 2: attempt.ended payloads gain exit.stage and exit.group_empty.
# group_empty is always boolean; false records exhausted group cleanup. This is
# a deliberate, additive payload change (CONTRACT-execution-binding.md §8.1) — readers
# (aib_event_scan / bin/attempts) treat the envelope's schema_version as opaque and
# never branch on it, so a stream mixing version-1 and version-2 records folds
# unchanged either way (tests/broker_enact_spec.sh §3 pins exactly this).
AIB_EVENT_SCHEMA_VERSION=2
AIB_EVENT_STREAM_NAME="main"
AIB_EVENT_MAX_LABEL_BYTES=256
AIB_EVENT_MAX_RECORD_BYTES=65536

# aib_event_stream_paths <standup_dir> — freeze the stream path convention in ONE place
# so the writer (Lane B) and the reader (Lane C) never disagree.
# Sets AIB_EVENT_DIR / AIB_EVENT_FILE / AIB_EVENT_LOCK.
aib_event_stream_paths() {
  local standup_dir="${1:-}"
  [ -n "$standup_dir" ] || aib_die 2 "event stream requires a standup_dir"
  case "$standup_dir" in
    *$'\n'*|*$'\r'*) aib_die 2 "invalid standup_dir (contains a line break)";;
  esac
  AIB_EVENT_DIR="$standup_dir/events"
  AIB_EVENT_FILE="$AIB_EVENT_DIR/${AIB_EVENT_STREAM_NAME}.events"
  AIB_EVENT_LOCK="$AIB_EVENT_DIR/${AIB_EVENT_STREAM_NAME}.events.lock"
}

# --- occurred_at helper + %N guard (display only) ----------------------------
# `date +%N` is GNU-specific. A non-GNU date emits the literal string `N`; that must
# fail closed rather than silently poison the timestamp. Uniqueness hangs on the
# writer-assigned seq, NEVER on the clock — so this guard is about honesty of a display
# field, not identity. Kept as a pure, directly-testable unit.
_aib_guard_ns() {
  local ns="$1"
  case "$ns" in
    ''|*[!0-9]*) aib_die 6 "date +%N did not expand to nanoseconds (non-GNU date?) — refusing a non-numeric timestamp fraction";;
  esac
  printf '%s' "$ns"
}
aib_event_now() {
  local t frac
  t="$(date -u '+%Y-%m-%dT%H:%M:%S.%NZ')" || aib_die 2 "cannot read the clock"
  frac="${t#*.}"; frac="${frac%Z}"
  _aib_guard_ns "$frac" >/dev/null
  printf '%s\n' "$t"
}

# --- payload composers (freeze the payload shape in Lane A) -------------------
# Callers pass a newline-delimited key=value record; ABSENT key => JSON null, present
# key (even empty) => encoded value. This is how a DENY blanks an `effective` field:
# the caller simply omits it (null), while `resolved` stays present (distinguishable
# from unresolved). All string values go through the audit-grade encoder.
_aib_kv_json_or_null() {
  local kv="$1" key="$2" v
  if v="$(_aib_record_field "$kv" "$key")"; then aib_json "$v"; else printf 'null'; fi
}
_aib_kv_num_or_null() {
  local kv="$1" key="$2" v
  if v="$(_aib_record_field "$kv" "$key")"; then
    case "$v" in ''|*[!0-9]*) aib_die 2 "event payload field '$key' must be a non-negative integer (got '$v')";; esac
    printf '%s' "$v"
  else
    printf 'null'
  fi
}

aib_event_compose_decided_payload() {
  local kv="${1-}" decision code reasons label LC_ALL=C
  _aib_utf8_is_valid "$kv" || aib_die 2 "decided payload input is not valid UTF-8"
  decision="$(_aib_record_field "$kv" decision)" || decision=""
  case "$decision" in allow|deny) ;; *) aib_die 2 "decided payload requires decision allow|deny (got '$decision')";; esac
  code="$(_aib_record_field "$kv" code)" || code=""
  case "$code" in ''|*[!0-9]*) aib_die 2 "decided payload requires a numeric code (got '$code')";; esac
  reasons="$(_aib_record_field "$kv" reasons)" || reasons=""
  if label="$(_aib_record_field "$kv" label)"; then
    [ "${#label}" -le "$AIB_EVENT_MAX_LABEL_BYTES" ] ||
      aib_die 2 "event label exceeds ${AIB_EVENT_MAX_LABEL_BYTES}-byte cap"
  fi
  printf '{"decision":%s,"code":%s,"reasons":%s,"provider":{"requested":null,"resolved":%s,"source":%s,"effective":%s},"model":{"requested":null,"resolved":%s,"source":%s,"effective":%s},"effort":{"requested":null,"resolved":%s,"source":%s,"effective":%s},"sandbox":{"requested":%s,"effective":%s},"adapter":{"raw":%s,"effective_path":%s,"source":%s},"pid":%s,"prompt":{"len":%s,"sha256":%s},"label":%s,"label_len":%s}' \
    "$(aib_json "$decision")" "$code" "$(aib_json "$reasons")" \
    "$(_aib_kv_json_or_null "$kv" provider_resolved)" "$(_aib_kv_json_or_null "$kv" provider_source)" "$(_aib_kv_json_or_null "$kv" provider_effective)" \
    "$(_aib_kv_json_or_null "$kv" model_resolved)" "$(_aib_kv_json_or_null "$kv" model_source)" "$(_aib_kv_json_or_null "$kv" model_effective)" \
    "$(_aib_kv_json_or_null "$kv" effort_resolved)" "$(_aib_kv_json_or_null "$kv" effort_source)" "$(_aib_kv_json_or_null "$kv" effort_effective)" \
    "$(_aib_kv_json_or_null "$kv" sandbox_requested)" "$(_aib_kv_json_or_null "$kv" sandbox_effective)" \
    "$(_aib_kv_json_or_null "$kv" adapter_raw)" "$(_aib_kv_json_or_null "$kv" adapter_effective)" "$(_aib_kv_json_or_null "$kv" adapter_source)" \
    "$(_aib_kv_num_or_null "$kv" pid)" "$(_aib_kv_num_or_null "$kv" prompt_len)" "$(_aib_kv_json_or_null "$kv" prompt_sha256)" \
    "$(_aib_kv_json_or_null "$kv" label)" "$(_aib_kv_num_or_null "$kv" label_len)"
}

aib_event_compose_ended_payload() {
  local kv="${1-}" exit_class stage group_empty
  _aib_utf8_is_valid "$kv" || aib_die 2 "ended payload input is not valid UTF-8"
  exit_class="$(_aib_record_field "$kv" exit_class)" || exit_class=""
  case "$exit_class" in
    ok|provider-failure|timeout|io-refused|aborted) ;;
    presumed-dead) aib_die 2 "'presumed-dead' is a reader-side fold classification, never an event payload value (§B7)";;
    *) aib_die 2 "invalid exit_class '$exit_class' (ok|provider-failure|timeout|io-refused|aborted)";;
  esac
  # RM-3 slice 3 (CONTRACT-execution-binding.md §8.1, D-K): exit.stage distinguishes a
  # helper-side refusal from the provider's own outcome — "we never ran it" from "it
  # ran and failed". REQUIRED at this composer (gate delta, Ikarus D5, MEDIUM: a
  # missing/empty stage on a new record is a writer bug, not a legal "unknown" —
  # fail closed rather than silently emitting a null a reader cannot tell apart from
  # an honestly-old record). A genuine schema-version-1 record (pre-slice-3, no
  # stage key at all) can therefore no longer be produced through this composer —
  # tests/broker_enact_spec.sh's fold fixture builds that shape by hand instead, the
  # same way it already hand-builds the version-2 shape.
  # R3 (gate delta 2, Ikarus MEDIUM): a disconnect at the PROLOGUE boundary —
  # before enactment is ever reached — is not "the provider's own outcome"
  # (stage=provider), nor any of aib_enact_launch's own three refusal stages
  # (confine|cwd|exec). It gets its own value: the attempt ended because the
  # TRANSPORT failed before enactment started. Schema version 2 is unreleased
  # (no bump needed to extend its enum — docs/CONTRACT-execution-binding.md
  # §8.1), so this composer accepts it starting now.
  stage="$(_aib_record_field "$kv" stage)" || aib_die 2 "ended payload requires stage (confine|cwd|exec|provider|transport)"
  case "$stage" in
    confine|cwd|exec|provider|transport) ;;
    *) aib_die 2 "invalid stage '$stage' (confine|cwd|exec|provider|transport)";;
  esac
  # Ordinary writers, including paths that never started a provider, default to
  # true. Only the confined manager can report exhausted group cleanup.
  group_empty="$(_aib_record_field "$kv" group_empty)" || group_empty=true
  case "$group_empty" in
    true|false) ;;
    *) aib_die 2 "invalid group_empty '$group_empty' (true|false)";;
  esac
  printf '{"exit":{"class":%s,"code":%s,"signal":%s,"stage":%s,"group_empty":%s}}' \
    "$(aib_json "$exit_class")" \
    "$(_aib_kv_num_or_null "$kv" exit_code)" \
    "$(_aib_kv_json_or_null "$kv" signal)" \
    "$(_aib_kv_json_or_null "$kv" stage)" "$group_empty"
}

# =============================================================================
# RM-3 slice 3 — aib_enact_launch: §2 step 3 (enactment, incl. §2.1 confinement)
# + step 4 (commit attempt.ended), extracted from bin/launch-agent's PEP and
# shared with bin/aib-broker-handler. See docs/CONFINEMENT.md and
# docs/SPEC-wire-format.md ("Response frame") for the contract this implements.
# =============================================================================

# aib_enact_launch <enact-record> <prompt> <events-path> <lock-path> <envelope-kv>
#                   <decided-event-id> [mode]
#
# mode "confined" (default) — bin/aib-broker-handler's path. The provider is exec'd
#   ONLY through $AIB_CONFINE_BIN (docs/CONFINEMENT.md); this function writes ONLY
#   the chunk section and the terminal line of the response frame
#   (docs/SPEC-wire-format.md, "Response frame") to its OWN stdout — never the
#   prologue, that is the caller's job, written before this is even called.
# mode "direct" — bin/launch-agent's single-trust-domain path (§7): execs the
#   adapter directly, NEVER touches $AIB_CONFINE_BIN, and returns the provider's
#   raw merged stdout+stderr on ITS OWN stdout for the caller to capture — no wire
#   framing, because launch-agent's stdout has never been a broker connection and
#   docs/CONTRACT-codex-run.md §4 already specifies "relay to stdout" byte-for-byte.
#
# <enact-record> (newline key=value): adapter (absolute path) · root (the
# registry-derived Landlock/containment root) · cwd (already-authorized, RE-CHECKED
# here, never trusted) · sandbox / effort / model / timeout (all EFFECTIVE, already
# clamped). <prompt> is its own argument, never a record line — see the spec-fixture
# correction in tests/broker_enact_spec.sh: prompt is multi-line free text and a
# newline-keyed record cannot carry it.
#
# Ambient inputs, read rather than passed positionally (house style: both callers
# already have them from their own aib_authorize_launch call before this runs):
#   AIB_VERDICT_ENV_ALLOW      the PDP's env allow-list (today "HOME PATH").
#   AIB_ENACT_CHILD_ENV_EXTRA  optional array the CALLER pre-populates with any
#     further NAME=value strings for the child (bin/launch-agent's rich AIBOBNET_*
#     export set; the broker's own, built from its request/snapshot). This
#     function always appends AIBOBNET_ATTEMPT_ID=<decided-event-id> itself, last,
#     so it always wins over anything the caller also put in the array.
#   AIB_CONFINE_BIN            (confined mode only) unit-environment-only per
#     docs/CONFINEMENT.md — never request- or registry-supplied. Empty/unset is
#     "confinement unavailable", not "skip confinement": D-A is fail-closed.
#
# On return, publishes (house AIB_VERDICT_*-style globals):
#   AIB_ENACT_EXIT_CLASS  ok | provider-failure | timeout | io-refused | aborted
#   AIB_ENACT_STAGE       confine | cwd | exec | provider
#   AIB_ENACT_EXIT_CODE   the provider/helper's numeric status (may be empty)
#   AIB_ENACT_SIGNAL      the forwarded signal name (may be empty; exactly one of
#                         AIB_ENACT_EXIT_CODE / AIB_ENACT_SIGNAL is ever non-empty)
#   AIB_ENACT_ENDED_EVENT_ID  the committed attempt.ended event_id
#   AIB_ENACT_GROUP_EMPTY    false only when confined group cleanup was exhausted
#   AIB_ENACT_REASON      fixed refusal reason (confine -> confinement_unavailable,
#     cwd -> cwd_moved, exec -> exec_failed), or escalation_exhausted when group
#     cleanup could not be confirmed; otherwise empty
#     (docs/SPEC-wire-format.md, "Terminal lines").
# and has committed exactly one attempt.ended record, causally bound to
# <decided-event-id>, over <events-path>/<lock-path> with the given <envelope-kv>.
aib_enact_launch() {
  local enact_record="${1-}" prompt="${2-}" events_path="${3-}" lock_path="${4-}"
  local envelope_kv="${5-}" decided_id="${6-}" mode="${7:-confined}"
  local adapter root cwd_req sandbox effort model timeout_s resolved_root

  case "$mode" in confined|direct) ;; *) aib_die 2 "aib_enact_launch: invalid mode '$mode' (confined|direct)";; esac
  [ -n "$events_path" ] && [ -n "$lock_path" ] && [ -n "$decided_id" ] ||
    aib_die 2 "aib_enact_launch requires events-path, lock-path and a decided-event-id"

  adapter="$(_aib_record_field "$enact_record" adapter)" || aib_die 2 "enact record requires adapter"
  root="$(_aib_record_field "$enact_record" root)" || aib_die 2 "enact record requires root"
  cwd_req="$(_aib_record_field "$enact_record" cwd)" || cwd_req="$root"
  sandbox="$(_aib_record_field "$enact_record" sandbox)" || aib_die 2 "enact record requires sandbox"
  effort="$(_aib_record_field "$enact_record" effort)" || aib_die 2 "enact record requires effort"
  model="$(_aib_record_field "$enact_record" model)" || aib_die 2 "enact record requires model"
  timeout_s="$(_aib_record_field "$enact_record" timeout)" || aib_die 2 "enact record requires timeout"
  case "$timeout_s" in ''|*[!0-9]*) aib_die 2 "enact record timeout must be digits (got '$timeout_s')";; esac
  [ "$timeout_s" -gt 0 ] 2>/dev/null || aib_die 2 "enact record timeout must be > 0"

  local _env_bin _sleep_bin _mktemp_bin _cat_bin _wc_bin
  _env_bin="$(command -v env)" || aib_die 6 "required runtime dependency not found: env (coreutils)"
  _sleep_bin="$(command -v sleep)" || aib_die 6 "required runtime dependency not found: sleep (coreutils)"
  _mktemp_bin="$(command -v mktemp)" || aib_die 6 "required runtime dependency not found: mktemp (coreutils)"
  _cat_bin="$(command -v cat)" || aib_die 6 "required runtime dependency not found: cat (coreutils)"
  _wc_bin="$(command -v wc)" || aib_die 6 "required runtime dependency not found: wc (coreutils)"

  AIB_ENACT_EXIT_CLASS=""
  AIB_ENACT_STAGE=""
  AIB_ENACT_EXIT_CODE=""
  AIB_ENACT_SIGNAL=""
  AIB_ENACT_ENDED_EVENT_ID=""
  AIB_ENACT_REASON=""
  AIB_ENACT_GROUP_EMPTY=true
  # D8 (gate delta, Ikarus, MEDIUM): set instead of dying, confined mode only —
  # see _aib_enact_commit_ended below.
  AIB_ENACT_INCIDENT=""

  if [ "$mode" = confined ]; then
    resolved_root="$(realpath -e -- "$root" 2>/dev/null)" ||
      aib_die 2 "enact record root does not exist: $root"
  fi

  # --- child env: allow-list (ambient, from the PDP this caller already ran)
  # plus whatever the caller pre-populated, plus ATTEMPT_ID (always, always last).
  local _child_env=() _n
  for _n in ${AIB_VERDICT_ENV_ALLOW:-}; do
    [ -n "${!_n+x}" ] && _child_env+=("$_n=${!_n}")
  done
  if declare -p AIB_ENACT_CHILD_ENV_EXTRA >/dev/null 2>&1; then
    local -n _extra_ref=AIB_ENACT_CHILD_ENV_EXTRA
    [ "${#_extra_ref[@]}" -eq 0 ] || _child_env+=("${_extra_ref[@]}")
  fi
  _child_env+=("AIBOBNET_ATTEMPT_ID=$decided_id")

  local _terminal_written=0

  # _aib_enact_commit_ended <exit_class> <stage> [exit_code] [signal]
  # Dynamic-scope helper (bash has no closures — this just reads this call's
  # locals, exactly the idiom bin/launch-agent's own _pep_commit_ended already
  # used before extraction). Guards double-write, same invariant as before.
  _aib_enact_commit_ended() {
    local exit_class="$1" stage="$2" exit_code="${3-}" signal="${4-}" ended_kv ended_payload
    [ "$_terminal_written" -eq 0 ] ||
      aib_die 2 "attempt '$decided_id' already entered a terminal path"
    ended_kv="exit_class=$exit_class"$'\n'"stage=$stage"$'\n'"group_empty=$AIB_ENACT_GROUP_EMPTY"
    [ -z "$exit_code" ] || ended_kv="${ended_kv}"$'\n'"exit_code=$exit_code"
    [ -z "$signal" ] || ended_kv="${ended_kv}"$'\n'"signal=$signal"
    ended_payload="$(aib_event_compose_ended_payload "$ended_kv")"
    local _rc _committed_id _had_errexit_ce=0
    case $- in *e*) _had_errexit_ce=1;; esac
    set +e
    # D8 (gate delta, Ikarus, MEDIUM): aib_event_commit does not RETURN on most
    # failures (corrupt stream, lock timeout, …) — it calls aib_die, i.e.
    # `exit`, directly, which `set +e`/`$?` around a plain call can never catch
    # (errexit has nothing to do with an explicit exit). Running it inside a
    # command-substitution subshell means that `exit` only ends the subshell;
    # this process sees it as an ordinary nonzero $? instead of dying with it.
    # The subshell also echoes the committed event id (prefixed, so a truncated
    # or empty result from a failure that exited before the echo can never be
    # mistaken for a real id) — aib_event_commit's own diagnostics still go to
    # real stderr either way, subshell or not.
    _committed_id="$(
      aib_event_commit "$events_path" "$lock_path" attempt.ended "$envelope_kv" "$ended_payload" "$decided_id"
      printf 'OK:%s' "$AIB_EVENT_COMMIT_EVENT_ID"
    )"
    _rc=$?
    [ "$_had_errexit_ce" -eq 0 ] || set -e
    case "$_committed_id" in OK:*) [ "$_rc" -eq 0 ] || _rc=0 ;; *) [ "$_rc" -ne 0 ] || _rc=2 ;; esac
    if [ "$_rc" -ne 0 ]; then
      # Direct mode has no wire to close — aib_die (unchanged) is still the
      # right call there. Confined mode has already streamed chunks by the
      # time this runs; dying here left a positive-length chunk followed by
      # bare EOF, never a terminal line — return the incident instead and let
      # aib_enact_launch__run_confined's caller close the frame honestly with
      # end=error.
      if [ "$mode" = confined ]; then
        AIB_ENACT_INCIDENT=1
        return "$_rc"
      fi
      aib_die "$_rc" "attempt.ended commit failed"
    fi
    _terminal_written=1
    AIB_ENACT_EXIT_CLASS="$exit_class"
    AIB_ENACT_STAGE="$stage"
    AIB_ENACT_EXIT_CODE="$exit_code"
    AIB_ENACT_SIGNAL="$signal"
    AIB_ENACT_ENDED_EVENT_ID="${_committed_id#OK:}"
    # Ikarus' preflight repro expects reason=confinement_unavailable on the
    # wire, not just stage=confine — a caller that only checks stage has to
    # know the enum by heart. provider needs none: exit_class/exit_code/signal
    # already say what happened (docs/SPEC-wire-format.md, "Terminal lines").
    case "$stage" in
      confine) AIB_ENACT_REASON=confinement_unavailable;;
      cwd) AIB_ENACT_REASON=cwd_moved;;
      exec) AIB_ENACT_REASON=exec_failed;;
      provider) AIB_ENACT_REASON="";;
    esac
    if [ "$AIB_ENACT_GROUP_EMPTY" = false ]; then
      AIB_ENACT_REASON=escalation_exhausted
    fi
  }

  # _aib_enact_status_signal <128+n> -> signal name (same table as the PEP's).
  _aib_enact_status_signal() {
    case "$1" in
      129) printf 'HUP';; 130) printf 'INT';; 137) printf 'KILL';; 143) printf 'TERM';;
      *) printf 'SIGNAL-%s' "$(($1 - 128))";;
    esac
  }

  # _aib_enact_map_status <rc> -> commits the terminal record for a REAPED
  # provider status (the ordinary case: confinement + exec both succeeded, or
  # mode=direct where there is no confinement to speak of). stage=provider always.
  _aib_enact_map_status() {
    local rc="$1"
    case "$rc" in
      0) _aib_enact_commit_ended ok provider ;;
      124) _aib_enact_commit_ended timeout provider 124 ;;
      126|127) _aib_enact_commit_ended io-refused provider "$rc" ;;
      *)
        if [ "$rc" -ge 128 ]; then
          _aib_enact_commit_ended aborted provider "" "$(_aib_enact_status_signal "$rc")"
        else
          _aib_enact_commit_ended provider-failure provider "$rc"
        fi
        ;;
    esac
  }

  if [ "$mode" = direct ]; then
    aib_enact_launch__run_direct
  else
    aib_enact_launch__run_confined
  fi
  # Return status mirrors AIB_ENACT_EXIT_CLASS, not "did this function crash":
  # 0 only for a clean provider success, non-zero for every refusal/failure/
  # abort class — the caller already has the richer AIB_ENACT_* globals for
  # anything more specific than "did it work".
  [ "$AIB_ENACT_EXIT_CLASS" = ok ]
}

# --- direct mode: byte-identical reproduction of bin/launch-agent's PEP -------
# manager/watchdog/reap, minus the decision to build the argv/env (still generic
# from the enact-record + the ambient allow-list, done once in aib_enact_launch
# above) and minus the caller's own heartbeats/messages (those stay in
# bin/launch-agent, unchanged, driven by the AIB_ENACT_* globals this leaves).
aib_enact_launch__run_direct() {
  local _provider_output _provider_status_file _cwd_fail_marker
  _provider_output="$("$_mktemp_bin" "${TMPDIR:-/tmp}/aibobnet-enact.XXXXXX")" ||
    aib_die 2 "cannot create provider lifecycle buffer"
  _provider_status_file="$("$_mktemp_bin" "${TMPDIR:-/tmp}/aibobnet-enact-status.XXXXXX")" ||
    aib_die 2 "cannot create provider status buffer"
  _cwd_fail_marker="$("$_mktemp_bin" "${TMPDIR:-/tmp}/aibobnet-enact-cwdfail.XXXXXX")" ||
    aib_die 2 "cannot create cwd-check marker"
  : > "$_cwd_fail_marker"

  local _provider_manager_pid _provider_status="" _provider_status_confirmed=0
  local manager_pid_outer

  _aib_enact_exec_child_direct() {
    exec "$_env_bin" -i "${_child_env[@]}" \
      "$adapter" exec \
      -m "$model" -s "$sandbox" \
      -c "model_reasoning_effort=\"$effort\"" \
      -c 'approval_policy="never"' \
      -- "$prompt" 2>&1
  }

  _aib_enact_manager_direct() {
    set +e
    local provider_pid="" timer_pid="" killer_pid="" provider_rc=1 confirmed_rc=1
    local timed_out=0 wait_interrupted=0
    local manager_pid="$BASHPID"

    _aib_enact_forward() { local sig="$1"; wait_interrupted=1; [ -z "$provider_pid" ] || kill -s "$sig" "$provider_pid" 2>/dev/null || true; }
    _aib_enact_on_timeout() {
      timed_out=1; wait_interrupted=1
      [ -z "$provider_pid" ] || kill -TERM "$provider_pid" 2>/dev/null || true
      if [ -n "$provider_pid" ]; then
        ( "$_sleep_bin" 10; kill -KILL "$provider_pid" 2>/dev/null || true ) &
        killer_pid=$!
      fi
    }
    trap '_aib_enact_forward HUP' HUP
    trap '_aib_enact_forward INT' INT
    trap '_aib_enact_forward TERM' TERM
    trap '_aib_enact_on_timeout' USR1

    if ! cd "$cwd_req" 2>/dev/null; then
      printf 'cwd_moved\n' > "$_cwd_fail_marker" 2>/dev/null
      exit 127
    fi
    _aib_enact_exec_child_direct &
    provider_pid=$!
    ( "$_sleep_bin" "$timeout_s"; kill -USR1 "$manager_pid" 2>/dev/null || true ) &
    timer_pid=$!

    wait "$provider_pid"
    provider_rc=$?
    if [ "$wait_interrupted" -eq 1 ]; then
      while kill -0 "$provider_pid" 2>/dev/null; do
        wait "$provider_pid"
        confirmed_rc=$?
        [ "$confirmed_rc" -eq 127 ] || provider_rc="$confirmed_rc"
        kill -0 "$provider_pid" 2>/dev/null && "$_sleep_bin" 0.01
      done
    fi

    kill "$timer_pid" 2>/dev/null || true
    wait "$timer_pid" 2>/dev/null || true
    if [ -n "$killer_pid" ]; then kill "$killer_pid" 2>/dev/null || true; wait "$killer_pid" 2>/dev/null || true; fi
    [ "$timed_out" -eq 0 ] || provider_rc=124
    printf '%s\n' "$provider_rc" > "$_provider_status_file" || exit 125
    exit "$provider_rc"
  }

  _aib_enact_reap_direct() {
    local wait_status _had_errexit_rd=0
    case $- in *e*) _had_errexit_rd=1;; esac
    set +e
    wait "$_provider_manager_pid"
    wait_status=$?
    _provider_status="$wait_status"
    _provider_status_confirmed=0
    if [ -r "$_provider_status_file" ]; then
      IFS= read -r _provider_status < "$_provider_status_file"
      case "$_provider_status" in ''|*[!0-9]*) _provider_status="$wait_status";; *) _provider_status_confirmed=1;; esac
    fi
    [ "$_had_errexit_rd" -eq 0 ] || set -e
    _provider_manager_pid=""
  }

  _aib_enact_cleanup_direct() {
    [ -z "$_provider_output" ] || rm -f -- "$_provider_output" 2>/dev/null || true
    [ -z "$_provider_status_file" ] || rm -f -- "$_provider_status_file" 2>/dev/null || true
    [ -z "$_cwd_fail_marker" ] || rm -f -- "$_cwd_fail_marker" 2>/dev/null || true
  }

  # --- wrapper-level safety net: a signal or an early `exit`/aib_die reaching
  # THIS process (bin/launch-agent itself — this all runs at script scope, no
  # subshell) while the manager is still running must not strand the attempt
  # `presumed-dead` or orphan the manager. Ported from the original
  # _pep_signal_handler/_pep_exit_handler (mutation-pinned: M4 in
  # rm2_adversarial_spec.sh re-anchors here) — same guard against forging a
  # terminal record the manager's OWN confirmed status didn't earn.
  _aib_enact_signal_handler_direct() {
    trap - EXIT INT TERM HUP
    local signal="$1" original_status="$2"
    if [ "$_terminal_written" -eq 0 ] && [ -n "$_provider_manager_pid" ]; then
      kill -s "$signal" "$_provider_manager_pid" 2>/dev/null || true
      _aib_enact_reap_direct
      [ "$_provider_status_confirmed" -eq 0 ] || ( _aib_enact_map_status "$_provider_status" ) || true
    fi
    [ -z "$_provider_output" ] || cat "$_provider_output" >&2 2>/dev/null || true
    _aib_enact_cleanup_direct
    exit "$original_status"
  }
  _aib_enact_exit_handler_direct() {
    trap - EXIT INT TERM HUP
    local original_status="$1"
    if [ "$_terminal_written" -eq 0 ]; then
      if [ -n "$_provider_manager_pid" ]; then
        kill -TERM "$_provider_manager_pid" 2>/dev/null || true
        _aib_enact_reap_direct
      fi
      if [ "$_provider_status_confirmed" -eq 1 ]; then
        ( _aib_enact_map_status "$_provider_status" ) || true
      fi
    fi
    [ -z "$_provider_output" ] || cat "$_provider_output" >&2 2>/dev/null || true
    _aib_enact_cleanup_direct
    exit "$original_status"
  }
  trap '_aib_enact_exit_handler_direct "$?"' EXIT
  trap '_aib_enact_signal_handler_direct HUP "$?"' HUP
  trap '_aib_enact_signal_handler_direct INT "$?"' INT
  trap '_aib_enact_signal_handler_direct TERM "$?"' TERM

  local _had_errexit=0
  case $- in *e*) _had_errexit=1;; esac
  set +e
  _aib_enact_manager_direct >"$_provider_output" 2>&1 &
  _provider_manager_pid=$!
  _aib_enact_reap_direct
  local rc="$_provider_status"
  [ "$_had_errexit" -eq 0 ] || set -e
  trap - EXIT INT TERM HUP

  if [ "$_provider_status_confirmed" -ne 1 ]; then
    _aib_enact_cleanup_direct
    aib_die 2 "provider exited without a confirmed reaped status"
  fi

  if [ -s "$_cwd_fail_marker" ]; then
    _aib_enact_commit_ended io-refused cwd 126
  else
    _aib_enact_map_status "$rc"
  fi
  "$_cat_bin" "$_provider_output"
  _aib_enact_cleanup_direct
}

# Internal process-group probe. Kept at library scope so fixtures can replace
# it after sourcing the library, inside their own subshell. There is no request,
# environment-variable, or command-line override in the broker.
_aib_enact_wait_group_empty() {
  local _pgid="$1" _deadline_s="$2" _wge_start="$SECONDS"
  while kill -0 -- "-$_pgid" 2>/dev/null; do
    [ $((SECONDS - _wge_start)) -lt "$_deadline_s" ] || return 1
    "$_sleep_bin" 0.05
  done
  return 0
}

# --- confined mode: §2.1 confinement, response-frame chunks + terminal lines --
aib_enact_launch__run_confined() {
  local _dd_bin _timeout_bin _mkfifo_bin _realpath_bin _python_bin
  _dd_bin="$(command -v dd)" || aib_die 6 "required runtime dependency not found: dd (coreutils)"
  _timeout_bin="$(command -v timeout)" || aib_die 6 "required runtime dependency not found: timeout (coreutils)"
  _mkfifo_bin="$(command -v mkfifo)" || aib_die 6 "required runtime dependency not found: mkfifo (coreutils)"
  _realpath_bin="$(command -v realpath)" || aib_die 6 "required runtime dependency not found: realpath (coreutils)"
  # D3 (gate delta, Ikarus, HIGH), S1a (gate delta 3, Marvin root-cause / Ikarus HIGH):
  # a plain `kill -TERM $provider_pid` only reaches the direct child of the manager —
  # a provider that itself forks (or that the adapter spawns beneath it) can survive
  # that signal as a live orphan once the manager reaps its own direct child, so the
  # exec chain needs to lead its OWN new process group. Used to be util-linux `setsid`
  # for this — but `setsid` is CONDITIONAL: if the calling process happens to already
  # be a process-group leader (observed under load — the "already a leader" state is
  # a live race, not a fixed property of how this code backgrounds jobs), it forks a
  # NEW child to hold the new group instead of using the caller's own pid, so
  # `provider_pid` (captured as `$!` of the ORIGINAL, non-forked process) silently
  # stops being the group leader. Every subsequent `kill -- "-$provider_pid"` then
  # targets an empty (or wrong) group while the real exec chain, now led by setsid's
  # own fork, survives untouched — reparented to PID 1 once its actual parent exits.
  # Fixed by not depending on external, conditional behaviour at all: `set -m` in the
  # manager (below, right before backgrounding the child) makes BASH itself assign
  # the new job its own process group, deterministically, with pgid == "$!" — no
  # forking, no leader-detection heuristic, no race. setsid is dropped from the child
  # exec chain entirely: a second, redundant group-creation attempt there would only
  # reintroduce the same "am I already a leader" question one level down.
  _python_bin="$(command -v python3 2>/dev/null || true)"

  # --- D-A / D-A2: pre-flight, before ANYTHING else runs -----------------------
  local _preflight_tmp _preflight_rc=1
  if [ -n "${AIB_CONFINE_BIN:-}" ] && [ -x "$AIB_CONFINE_BIN" ]; then
    _preflight_tmp="$("$_mktemp_bin" -d "${TMPDIR:-/tmp}/aibobnet-preflight.XXXXXX")" || aib_die 2 "cannot create pre-flight tmp dir"
    LL_RO=/ LL_RW="$_preflight_tmp" "$AIB_CONFINE_BIN" /bin/true >/dev/null 2>&1
    _preflight_rc=$?
    rm -rf "$_preflight_tmp" 2>/dev/null || true
  fi
  if [ "$_preflight_rc" -ne 0 ]; then
    _aib_enact_commit_ended io-refused confine 126
    # R4 (gate delta 2, Ikarus MEDIUM): _aib_enact_commit_ended's own D8 incident
    # branch can fire right here too (event store gone/corrupt before the
    # provider ever ran, not just after) — it sets AIB_ENACT_INCIDENT and returns
    # without touching AIB_ENACT_EXIT_CLASS/STAGE/etc, so calling
    # aib_enact_launch__write_terminal unconditionally printed empty fields and
    # a false end=ok. Close the frame the same honest way every other incident
    # in this function does: a flat reason=/end=error, never fabricated content.
    if [ -n "$AIB_ENACT_INCIDENT" ]; then
      printf 'chunk_bytes=0\n\n'
      printf 'reason=event_store_unavailable\n'
      printf 'end=error\n'
      return 0
    fi
    printf 'chunk_bytes=0\n\n'
    aib_enact_launch__write_terminal
    return 0
  fi

  # --- D-B2: positive lists, registry + constants only, request contributes nothing ---
  local ll_ro="/" ll_rw="${resolved_root}:/tmp:/var/tmp:/dev"

  local _internal_fifo _status_file _cwd_fail_marker _provider_status_file _escalated_marker
  _internal_fifo="$("$_mktemp_bin" -u "${TMPDIR:-/tmp}/aibobnet-relay.XXXXXX")"
  "$_mkfifo_bin" "$_internal_fifo" || aib_die 2 "cannot create relay fifo"
  _status_file="$("$_mktemp_bin" "${TMPDIR:-/tmp}/aibobnet-status.XXXXXX")" || aib_die 2 "cannot create status buffer"
  _cwd_fail_marker="$("$_mktemp_bin" "${TMPDIR:-/tmp}/aibobnet-cwdfail.XXXXXX")" || aib_die 2 "cannot create cwd-check marker"
  _provider_status_file="$("$_mktemp_bin" "${TMPDIR:-/tmp}/aibobnet-provstatus.XXXXXX")" || aib_die 2 "cannot create provider status buffer"
  # Riker LOW (should-fix): which signal actually ended the child — TERM if it
  # obeyed the first one, KILL only if the 10s grace timer had to escalate.
  # Written by the killer job below ONLY when it finds the tree still alive.
  _escalated_marker="$("$_mktemp_bin" "${TMPDIR:-/tmp}/aibobnet-escalated.XXXXXX")" || aib_die 2 "cannot create escalation marker"
  : > "$_cwd_fail_marker"

  _aib_enact_cleanup_confined() {
    # LOW (gate delta 2, Ikarus): the escalation marker was created above but
    # never listed here — every confined run leaked one file into TMPDIR
    # forever, win or lose, escalated or not.
    rm -f -- "$_internal_fifo" "$_status_file" "$_cwd_fail_marker" "$_provider_status_file" "$_escalated_marker" 2>/dev/null || true
  }

  _aib_enact_exec_child_confined() {
    # Only stdio and the helper's status channel are part of this exec boundary.
    # Enumerate this bash process before exec, closing inherited pipes/files in
    # the child only. fd 9 remains until the helper closes it through CLOEXEC.
    local _fd
    for _fd in /proc/self/fd/[0-9]*; do
      _fd="${_fd##*/}"
      case "$_fd" in 0|1|2|9) continue;; esac
      exec {_fd}>&-
    done
    # S1a: no setsid here — the manager's own `set -m` (below) already put THIS
    # process in a fresh process group, with pgid == its own pid, at the moment it
    # was backgrounded, before this function body even started running. A second
    # group-creation attempt here would just reopen the same "am I already a group
    # leader" question setsid used to answer wrong under load. LL_STDERR_FD=1 (D2,
    # gate delta, Ikarus, HIGH): the confinement helper keeps its OWN stderr
    # wherever fd2 already points (the journal — unchanged) but dup2's the fd
    # NAMED here onto its fd 2 immediately before its execvp, so the PROVIDER's
    # stderr (after that handoff) lands on fd 1 — the same relay fifo every chunk
    # already goes through — never merged with the helper's own diagnostics,
    # because the dup2 happens strictly after them.
    exec "$_env_bin" -i "${_child_env[@]}" "LL_RO=$ll_ro" "LL_RW=$ll_rw" \
      "LL_STATUS_FD=9" "LL_STDERR_FD=1" \
      "$AIB_CONFINE_BIN" "$adapter" exec \
      -m "$model" -s "$sandbox" \
      -c "model_reasoning_effort=\"$effort\"" \
      -c 'approval_policy="never"' \
      -- "$prompt"
  }

  local _provider_manager_pid manager_pid_ref
  _aib_enact_manager_confined() {
    set +e
    local provider_pid="" timer_pid="" killer_pid="" provider_rc=1 confirmed_rc=1
    local timed_out=0 aborted_disc=0 wait_interrupted=0 group_empty=true
    local manager_pid="$BASHPID"

    _aib_enact_forward() { local sig="$1"; wait_interrupted=1; [ -z "$provider_pid" ] || kill -s "$sig" -- "-$provider_pid" 2>/dev/null || true; }
    _aib_enact_escalate() {
      # TERM the whole process group (bash job control made provider_pid its leader),
      # never just the one pid — a provider that forked before the signal
      # arrived would otherwise survive as a live orphan once the manager
      # reaps only its direct child. Deliberately no single-pid fallback: that
      # would silently reopen the exact hole this fix closes.
      [ -z "$provider_pid" ] || kill -TERM -- "-$provider_pid" 2>/dev/null || true
      if [ -n "$provider_pid" ]; then
        # >&- : this job outlives the provider by design (the whole point of
        # a 10s grace timer) and must not hold the relay fifo's write end
        # open a moment past the provider's own real exit — a bystander fd
        # on a pipe with no other writer left still blocks EOF for the
        # reader on the far side (verified empirically: without this, the
        # relay loop for a fast-exiting provider blocks until $timeout_s,
        # not until the provider actually finished).
        (
          "$_sleep_bin" 10
          # R2 (gate delta 2, Riker HIGH / Ikarus HIGH): this used to check
          # only the LEADER pid (`kill -0 "$provider_pid"`) — but the leader
          # is exactly the process that does NOT need to survive TERM to
          # defeat this check; any ordinary (non-trapping) leader dies from
          # the group TERM above like it always did, making this look like
          # "nothing left to kill" even while a TERM-ignoring descendant is
          # very much still alive in the same group. Ask about the GROUP.
          if kill -0 -- "-$provider_pid" 2>/dev/null; then
            kill -KILL -- "-$provider_pid" 2>/dev/null || true
            printf 'KILL\n' > "$_escalated_marker" 2>/dev/null || true
          fi
        ) >&- 2>&- &
        killer_pid=$!
      fi
    }
    _aib_enact_on_timeout() { timed_out=1; wait_interrupted=1; _aib_enact_escalate; }
    _aib_enact_on_disconnect() { aborted_disc=1; wait_interrupted=1; _aib_enact_escalate; }
    trap '_aib_enact_forward HUP' HUP
    trap '_aib_enact_forward INT' INT
    trap '_aib_enact_forward TERM' TERM
    trap '_aib_enact_on_timeout' USR1
    trap '_aib_enact_on_disconnect' USR2

    if ! cd "$cwd_req" 2>/dev/null; then
      printf 'cwd_moved\n' > "$_cwd_fail_marker" 2>/dev/null
      exit 126
    fi
    # D6 (gate delta, Ikarus, MEDIUM): a hand-rolled `"$resolved_root"/*` glob is
    # exactly slice 2's D3 bug reborn — when root resolves to "/", the pattern
    # becomes "//*", which nothing with a single leading slash matches, so a
    # perfectly legitimate cwd under "/" was refused as a symlink swap. Reuse
    # aib_contain_cwd's boundary logic instead of a second, independently-wrong
    # implementation of the same "is this path inside that root" question — one
    # already handles the "/" case correctly (`root_prefix` collapses to "").
    if ! aib_contain_cwd "$root" "$(pwd -P)"; then
      printf 'cwd_moved\n' > "$_cwd_fail_marker" 2>/dev/null
      exit 126
    fi

    # S1a (gate delta 3, Marvin root-cause / Ikarus HIGH): `set -m` (job control)
    # right before backgrounding, not before — enabling it earlier would also put
    # the timer/killer helper jobs below under monitor-mode job control, which
    # this function does not need and does not want to reason about. With job
    # control on, bash itself creates a NEW process group for this one background
    # job and assigns its pgid == its own pid, deterministically, at fork time —
    # no external command, no "am I already a leader" ambiguity, no race.
    set -m
    _aib_enact_exec_child_confined 9>"$_status_file" &
    provider_pid=$!
    set +m
    # >&- : same reasoning as the killer job above — this timer outlives a
    # fast provider by design and must not be an extra open writer on the
    # relay fifo once the provider itself is done with it.
    ( "$_sleep_bin" "$timeout_s"; kill -USR1 "$manager_pid" 2>/dev/null || true ) >&- 2>&- &
    timer_pid=$!

    wait "$provider_pid"
    provider_rc=$?
    if [ "$wait_interrupted" -eq 1 ]; then
      while kill -0 "$provider_pid" 2>/dev/null; do
        wait "$provider_pid"
        confirmed_rc=$?
        [ "$confirmed_rc" -eq 127 ] || provider_rc="$confirmed_rc"
        kill -0 "$provider_pid" 2>/dev/null && "$_sleep_bin" 0.01
      done
    fi

    kill "$timer_pid" 2>/dev/null || true
    wait "$timer_pid" 2>/dev/null || true
    if [ -n "$killer_pid" ]; then
      # R2 (gate delta 2, Riker HIGH / Ikarus HIGH): provider_pid (the process
      # GROUP LEADER) being confirmed reaped, just above, says nothing about
      # whether the GROUP it led is actually empty — a grandchild that traps or
      # ignores TERM (any daemonizing or adversarial child) survives the group
      # TERM untouched and is left running, unreaped, forever, if the killer job
      # is cancelled here on the leader's exit alone. `kill -0 -- "-$provider_pid"`
      # asks the kernel the right question: is ANY process still in that group?
      # If yes, let the killer's own 10s grace timer run its course for real and
      # deliver KILL — cancelling it here would silently reopen the exact orphan
      # class D3 exists to close, just via a TERM-ignoring descendant instead of
      # D3's original un-grouped single-pid kill.
      if kill -0 -- "-$provider_pid" 2>/dev/null; then
        wait "$killer_pid" 2>/dev/null || true
      else
        kill "$killer_pid" 2>/dev/null || true
        wait "$killer_pid" 2>/dev/null || true
      fi
    fi
    # S1b (gate delta 3, Ikarus HIGH): EVERY terminal path — normal exit,
    # timeout, disconnect abort — reaches here, and none of the waits above
    # actually confirm the GROUP is empty (only that the leader was reaped, and
    # that the killer job, if one ran, finished). One more bounded check, with
    # one more real escalation attempt if it's still not empty: proceeding to
    # commit while a member of the group is still alive is exactly the window
    # a reader polling the stream can catch as a false "no orphan" (Marvin's and
    # Ikarus' load repros). If it is STILL not empty after that — a process
    # stuck in an uninterruptible state is the realistic cause, since KILL was
    # already sent twice — this deliberately does not block the connection
    # forever (that would trade one incident for a worse one, a hung response);
    # it logs and reports group_empty=false alongside the reaped leader's
    # status. The parent carries that observation into the event and wire.
    if ! _aib_enact_wait_group_empty "$provider_pid" 2; then
      kill -KILL -- "-$provider_pid" 2>/dev/null || true
      if ! _aib_enact_wait_group_empty "$provider_pid" 3; then
        group_empty=false
        printf 'ai-bobnet: process group %s still had live members after a second KILL escalation; proceeding\n' \
          "$provider_pid" >&2
      fi
    fi
    if [ "$aborted_disc" -eq 1 ]; then provider_rc=143
    elif [ "$timed_out" -eq 1 ]; then provider_rc=124
    fi
    printf '%s %s\n' "$provider_rc" "$group_empty" > "$_provider_status_file" || exit 125
    exit "$provider_rc"
  }

  # _aib_enact_conn_alive — best-effort liveness probe of OUR OWN stdout (the
  # connection), WITHOUT writing a byte: a poll(2) for POLLHUP/POLLERR/POLLNVAL
  # (gate delta, Ikarus D4, MEDIUM: POLLOUT is deliberately never part of the
  # "gone" test — a writable socket with room in its buffer reports POLLOUT
  # whether or not anyone is still reading, so treating it as a liveness
  # signal would be exactly backwards). Bash has no poll/select builtin, and a
  # zero-length write(2) never raises EPIPE on Linux (verified empirically —
  # POSIX explicitly permits skipping error detection for a zero-length write,
  # and this host's kernel takes that option), so "the next write" alone
  # cannot detect a disconnect while the provider stays completely silent
  # (docs/CONFINEMENT.md's silent-hang fixture). Falls back to "assume alive"
  # (next-write detection only) when python3 is absent — a documented,
  # graceful degradation, never a hard dependency.
  #
  # Accepted latency case (SPEC-wire-format.md, "Response frame"), stated here
  # because it is a real gap, not an oversight: a peer that has only shut down
  # its OWN read half (SHUT_RD on a socket) while leaving the socket itself
  # open reports neither POLLHUP nor POLLERR to the writer — Linux does not
  # surface that half-close to the far end via poll(2) at all. Such a peer is
  # indistinguishable from one that is merely slow to read until this
  # process's next real write discovers EPIPE/ECONNRESET on its own. A full
  # close (or a shutdown of the peer's WRITE half, which is the shape an
  # abandoned response actually takes in practice) is detected within one
  # idle tick, as tested below.
  _aib_enact_conn_alive() {
    [ -n "$_python_bin" ] || return 0
    "$_python_bin" -c '
import select, sys
try:
    p = select.poll()
    p.register(1, select.POLLOUT | select.POLLERR | select.POLLHUP | select.POLLNVAL)
    for _fd, ev in p.poll(0):
        if ev & (select.POLLERR | select.POLLHUP | select.POLLNVAL):
            sys.exit(1)
except Exception:
    pass
sys.exit(0)
' 2>/dev/null
  }

  # Riker LOW (should-fix): report what actually ended the child — KILL only
  # if the 10s grace timer had to fire it (the marker _aib_enact_escalate
  # writes only when it finds the tree still alive after the grace period),
  # TERM otherwise. Never itself a source of truth about liveness — purely a
  # label on an abort this function did not decide to trigger.
  _aib_enact_abort_signal() {
    if [ -s "$_escalated_marker" ]; then printf 'KILL'; else printf 'TERM'; fi
  }

  # --- wrapper-level safety net, same reasoning as the direct-mode one above:
  # a signal reaching THIS connection's process (bin/aib-broker-handler) while
  # the manager is still running must not strand the attempt `presumed-dead`
  # or orphan the confined child. Reuses the disconnect-abort escalation
  # (USR2) rather than duplicating a second TERM-then-KILL timer.
  _aib_enact_signal_handler_confined() {
    trap - EXIT INT TERM HUP
    local original_status="$2"
    if [ "$_terminal_written" -eq 0 ] && [ -n "$_provider_manager_pid" ]; then
      kill -USR2 "$_provider_manager_pid" 2>/dev/null || true
      wait "$_provider_manager_pid" 2>/dev/null || true
      _aib_enact_commit_ended aborted provider "" "$(_aib_enact_abort_signal)"
    fi
    _aib_enact_cleanup_confined
    exit "$original_status"
  }
  _aib_enact_exit_handler_confined() {
    trap - EXIT INT TERM HUP
    local original_status="$1"
    if [ "$_terminal_written" -eq 0 ] && [ -n "$_provider_manager_pid" ]; then
      kill -USR2 "$_provider_manager_pid" 2>/dev/null || true
      wait "$_provider_manager_pid" 2>/dev/null || true
      _aib_enact_commit_ended aborted provider "" "$(_aib_enact_abort_signal)"
    fi
    _aib_enact_cleanup_confined
    exit "$original_status"
  }
  trap '_aib_enact_exit_handler_confined "$?"' EXIT
  trap '_aib_enact_signal_handler_confined HUP "$?"' HUP
  trap '_aib_enact_signal_handler_confined INT "$?"' INT
  trap '_aib_enact_signal_handler_confined TERM "$?"' TERM

  trap '' PIPE
  local _had_errexit=0
  case $- in *e*) _had_errexit=1;; esac
  set +e
  # NOT `2>&1`: the confinement helper's own pre-exec diagnostics land on
  # fd2, and CONFINEMENT.md requires those to reach the broker's journal —
  # "never merged into the provider's output stream and never appear in the
  # wire response". The real unit already gives fd2 that home
  # (`StandardError=journal` alongside `StandardOutput=socket`,
  # deploy/systemd/aib-broker@.service): fd2 here is simply left as whatever
  # this process already inherited, never redirected into the relay fifo.
  # Only fd1 (the provider's stdout, once the helper's execvp hands off) is
  # this function's job to relay.
  _aib_enact_manager_confined >"$_internal_fifo" &
  _provider_manager_pid=$!

  local _relay_fd
  exec {_relay_fd}<"$_internal_fifo"

  local _chunk_tmp _disconnected=0
  _chunk_tmp="$("$_mktemp_bin" "${TMPDIR:-/tmp}/aibobnet-chunk.XXXXXX")" || aib_die 2 "cannot create chunk buffer"
  while :; do
    : > "$_chunk_tmp"
    # NOT `if=/dev/fd/$_relay_fd`: re-opening a fifo BY PATH through the
    # /proc/self/fd magic-link — which is what an `if=` argument forces dd to
    # do — starts a FRESH open() on the underlying fifo, which then waits for
    # its OWN new writer forever, even after the real writer has already
    # closed (verified empirically on this host: it hangs past a 0.3s
    # `timeout` with the writer long gone). Redirecting the ALREADY-OPEN fd
    # onto dd's stdin is a plain fd inheritance, not a fresh open, and sees
    # EOF exactly when the writer closes, as it must.
    "$_timeout_bin" 0.3 "$_dd_bin" of="$_chunk_tmp" bs=65536 count=1 status=none 2>/dev/null <&"$_relay_fd"
    local _dd_rc=$? _n
    _n="$("$_wc_bin" -c < "$_chunk_tmp")"
    if [ "$_dd_rc" -eq 124 ]; then
      # Idle tick: the provider produced nothing this round. The one moment a
      # permanently silent provider (docs/CONFINEMENT.md's D-I fixture) can
      # ever notice a gone client — see _aib_enact_conn_alive above.
      if ! _aib_enact_conn_alive; then
        _disconnected=1
        kill -USR2 "$_provider_manager_pid" 2>/dev/null || true
        break
      fi
      continue
    fi
    if [ "$_n" -eq 0 ]; then
      break # true EOF: the provider's output side closed.
    fi
    if ! { printf 'chunk_bytes=%s\n\n' "$_n" && "$_cat_bin" "$_chunk_tmp"; } 2>/dev/null; then
      _disconnected=1
      kill -USR2 "$_provider_manager_pid" 2>/dev/null || true
      break
    fi
  done
  exec {_relay_fd}<&-
  rm -f -- "$_chunk_tmp" 2>/dev/null || true

  local wait_status
  wait "$_provider_manager_pid"
  wait_status=$?
  local _provider_status="$wait_status" _provider_status_confirmed=0 _provider_group_empty
  if [ -r "$_provider_status_file" ]; then
    IFS=' ' read -r _provider_status _provider_group_empty < "$_provider_status_file"
    case "$_provider_status" in ''|*[!0-9]*) _provider_status="$wait_status";; *) _provider_status_confirmed=1;; esac
    if [ "$_provider_status_confirmed" -eq 1 ]; then
      AIB_ENACT_GROUP_EMPTY="$_provider_group_empty"
    fi
  fi
  [ "$_had_errexit" -eq 0 ] || set -e
  trap - EXIT INT TERM HUP

  if [ "$_disconnected" -eq 1 ]; then
    _aib_enact_commit_ended aborted provider "" "$(_aib_enact_abort_signal)"
  elif [ -s "$_cwd_fail_marker" ]; then
    _aib_enact_commit_ended io-refused cwd 126
  elif [ "$_provider_status_confirmed" -ne 1 ]; then
    _aib_enact_cleanup_confined
    aib_die 2 "provider exited without a confirmed reaped status"
  elif [ -s "$_status_file" ]; then
    # Non-empty LL_STATUS_FD: the helper never reached a running provider
    # (docs/CONFINEMENT.md, D-A2). code 127 is the helper's OWN "execvp itself
    # failed" convention (CONTRACT-execution-binding.md §8.1's "(helper exit
    # 127)" parenthetical) — anything else is a pre-exec ruleset/prctl refusal.
    if [ "$_provider_status" -eq 127 ]; then
      _aib_enact_commit_ended io-refused exec 127
    else
      _aib_enact_commit_ended io-refused confine 126
    fi
  else
    _aib_enact_map_status "$_provider_status"
  fi

  # D8 (gate delta, Ikarus, MEDIUM): the ended commit itself failed (event
  # store gone/corrupt after the provider already ran) — every OTHER path
  # above already returned via `_aib_enact_commit_ended`'s incident branch
  # without touching AIB_ENACT_EXIT_CLASS, so there is no verdict to report.
  # Close the frame honestly: the chunk section still gets its closing
  # marker (whatever chunks already went out stay valid), then a flat
  # reason=/end=error — never a positive-length chunk followed by bare EOF.
  if [ -n "$AIB_ENACT_INCIDENT" ]; then
    if [ "$_disconnected" -ne 1 ]; then
      printf 'chunk_bytes=0\n\n'
      printf 'reason=event_store_unavailable\n'
      printf 'end=error\n'
    fi
    trap - PIPE
    _aib_enact_cleanup_confined
    return 0
  fi

  # A disconnected client already got the abort it earned; nothing further on
  # the wire could reach it, and every attempt would just re-discover the same
  # EPIPE for no reader (D-I: "on EPIPE ... exit", not "on EPIPE ... keep
  # writing"). The record is already committed above either way.
  if [ "$_disconnected" -ne 1 ]; then
    printf 'chunk_bytes=0\n\n'
    aib_enact_launch__write_terminal
  fi
  trap - PIPE
  _aib_enact_cleanup_confined
}

# aib_enact_launch__write_terminal — the terminal-line block of the response
# frame (docs/SPEC-wire-format.md, "Response frame", §3): exit_class, exactly
# one of exit_code=/signal= (neither, for class "ok" — matching the composer's
# own convention of nulling both when the caller never supplies them), stage,
# reason (a refusal stage or exhausted group cleanup), ended_event_id,
# and `end=ok` LAST — always "ok" here, because "end=ok on the
# response means the broker did its job, regardless of the provider's own exit
# class" (SPEC-wire-format.md, "Terminal lines"): a provider that failed, timed
# out, was aborted, or was refused before it ever ran still got a correctly
# observed-and-reported outcome. `end=error`/`end=denied` are the OTHER two
# values that function covers, both on paths that never reach this function at
# all (a wire-level incident, or a deny — bin/aib-broker-handler still calls
# `aib_wire_write_response` directly for those, unchanged).
aib_enact_launch__write_terminal() {
  printf 'exit_class=%s\n' "$AIB_ENACT_EXIT_CLASS"
  if [ -n "$AIB_ENACT_SIGNAL" ]; then
    printf 'signal=%s\n' "$AIB_ENACT_SIGNAL"
  elif [ -n "$AIB_ENACT_EXIT_CODE" ]; then
    printf 'exit_code=%s\n' "$AIB_ENACT_EXIT_CODE"
  fi
  printf 'stage=%s\n' "$AIB_ENACT_STAGE"
  if [ "$AIB_ENACT_GROUP_EMPTY" = false ]; then
    printf 'group_empty=false\n'
  fi
  if [ -n "$AIB_ENACT_REASON" ]; then
    printf 'reason=%s\n' "$AIB_ENACT_REASON"
  fi
  printf 'ended_event_id=%s\n' "$AIB_ENACT_ENDED_EVENT_ID"
  printf 'end=ok\n'
}

# --- top-level JSON field extractor (the shared reader primitive) -------------
# The runtime has no general JSON parser beyond the registry awk. This is a small,
# depth-tracking tokeniser that returns TOP-LEVEL (depth-1) string field values only —
# a nested `"attempt_id":"spoof"` inside `payload` can NEVER be mistaken for the real
# top-level field (that is what makes the at-most-one-ended check trustworthy against
# a crafted body). Strings are consumed correctly at every depth so braces inside a
# value never miscount. Non-string top-level values (numbers/null/objects) yield empty.
_AIB_EVENT_FIELD_AWK='
{ data = data $0 }
END {
  n = length(data); i = 1; depth = 0; expect = ""; curkey = ""
  while (i <= n) {
    c = substr(data, i, 1)
    if (c == "\"") {
      s = ""; i++
      while (i <= n) {
        d = substr(data, i, 1)
        if (d == "\\") {
          e = substr(data, i+1, 1)
          if (e == "n") s = s "\n"; else if (e == "t") s = s "\t"; else if (e == "r") s = s "\r"
          else if (e == "b") s = s "\b"; else if (e == "f") s = s "\f"
          else if (e == "\"") s = s "\""; else if (e == "\\") s = s "\\"; else if (e == "/") s = s "/"
          else if (e == "u") { s = s "\\u" substr(data, i+2, 4); i += 6; continue }
          else { s = s e }
          i += 2; continue
        }
        if (d == "\"") { i++; break }
        s = s d; i++
      }
      if (depth == 1) {
        if (expect == "key") { curkey = s; expect = "colon" }
        else if (expect == "value") { val[curkey] = s; curkey = ""; expect = "comma" }
      }
      continue
    }
    if (c == "{" || c == "[") {
      if (depth == 0) { depth = 1; expect = "key" }
      else { if (depth == 1 && expect == "value") { expect = "comma"; curkey = "" } depth++ }
      i++; continue
    }
    if (c == "}" || c == "]") { depth--; i++; continue }
    if (c == ":") { if (depth == 1 && expect == "colon") expect = "value"; i++; continue }
    if (c == ",") { if (depth == 1 && expect == "comma") expect = "key"; i++; continue }
    if (c == " " || c == "\t" || c == "\r" || c == "\n") { i++; continue }
    s = ""
    while (i <= n) {
      d = substr(data, i, 1)
      if (d == " " || d == "\t" || d == "\r" || d == "\n" || d == "," || d == "}" || d == "]" || d == ":") break
      s = s d; i++
    }
    if (depth == 1 && expect == "value") { curkey = ""; expect = "comma" }
    continue
  }
  printf "%s\t%s\t%s", val[k1], val[k2], val[k3]
}'

# aib_event_field <record-json> <top-level-key> -> the field value on stdout (empty if
# absent or non-string). Public so Lane C's fold consumes it instead of duplicating a
# parser. Decodes the standard short escapes; leaves \uXXXX raw (rare, not fold-relevant).
aib_event_field() {
  local json="${1-}" key="${2-}" res
  res="$(printf '%s' "$json" | awk -v k1="$key" -v k2="__aib_none1__" -v k3="__aib_none2__" "$_AIB_EVENT_FIELD_AWK")"
  printf '%s' "${res%%$'\t'*}"
}

# aib_event_payload_field <record-json> <decision|pid|exit.class|exit.code>
#
# Additive scanner-owned access to the frozen Attempt payload fields Lane C needs.
# The reader remains a thin consumer: it never parses JSON itself. This tokenizer
# follows object paths, so top-level or sibling/nested spoof keys cannot shadow the
# canonical payload path. String escapes match aib_event_field; JSON null/absence
# produce empty output, while numeric pid/code are emitted as decimal tokens.
_AIB_EVENT_PAYLOAD_FIELD_AWK='
function full_path(depth, key, base) {
  base = objpath[depth]
  return base == "" ? key : base "." key
}
function capture(path, value) {
  if (!found && path == target) {
    if (value != "null") printf "%s", value
    found = 1
  }
}
{ data = data $0 }
END {
  n = length(data); i = 1; depth = 0; found = 0
  while (i <= n) {
    c = substr(data, i, 1)
    if (c == "\"") {
      s = ""; i++
      while (i <= n) {
        d = substr(data, i, 1)
        if (d == "\\") {
          e = substr(data, i+1, 1)
          if (e == "n") s = s "\n"; else if (e == "t") s = s "\t"; else if (e == "r") s = s "\r"
          else if (e == "b") s = s "\b"; else if (e == "f") s = s "\f"
          else if (e == "\"") s = s "\""; else if (e == "\\") s = s "\\"; else if (e == "/") s = s "/"
          else if (e == "u") { s = s "\\u" substr(data, i+2, 4); i += 6; continue }
          else { s = s e }
          i += 2; continue
        }
        if (d == "\"") { i++; break }
        s = s d; i++
      }
      if (kind[depth] == "object") {
        if (expect[depth] == "key") {
          curkey[depth] = s
          expect[depth] = "colon"
        } else if (expect[depth] == "value") {
          capture(full_path(depth, curkey[depth]), s)
          curkey[depth] = ""
          expect[depth] = "comma"
        }
      }
      continue
    }
    if (c == "{") {
      if (depth == 0) {
        depth = 1
        kind[depth] = "object"
        objpath[depth] = ""
        expect[depth] = "key"
      } else {
        p = full_path(depth, curkey[depth])
        if (kind[depth] == "object" && expect[depth] == "value") {
          curkey[depth] = ""
          expect[depth] = "comma"
        }
        depth++
        kind[depth] = "object"
        objpath[depth] = p
        expect[depth] = "key"
      }
      i++; continue
    }
    if (c == "[") {
      p = full_path(depth, curkey[depth])
      if (kind[depth] == "object" && expect[depth] == "value") {
        curkey[depth] = ""
        expect[depth] = "comma"
      }
      depth++
      kind[depth] = "array"
      objpath[depth] = p
      expect[depth] = ""
      i++; continue
    }
    if (c == "}" || c == "]") {
      delete kind[depth]
      delete objpath[depth]
      delete expect[depth]
      delete curkey[depth]
      depth--
      i++; continue
    }
    if (c == ":") {
      if (kind[depth] == "object" && expect[depth] == "colon") expect[depth] = "value"
      i++; continue
    }
    if (c == ",") {
      if (kind[depth] == "object" && expect[depth] == "comma") expect[depth] = "key"
      i++; continue
    }
    if (c == " " || c == "\t" || c == "\r" || c == "\n") { i++; continue }
    s = ""
    while (i <= n) {
      d = substr(data, i, 1)
      if (d == " " || d == "\t" || d == "\r" || d == "\n" || d == "," || d == "}" || d == "]" || d == ":") break
      s = s d
      i++
    }
    if (kind[depth] == "object" && expect[depth] == "value") {
      capture(full_path(depth, curkey[depth]), s)
      curkey[depth] = ""
      expect[depth] = "comma"
    }
  }
}'

aib_event_payload_field() {
  local json="${1-}" key="${2-}" target
  case "$key" in
    decision|pid) target="payload.$key";;
    exit.class|exit.code) target="payload.$key";;
    *) aib_die 64 "unknown event payload field '$key' (decision|pid|exit.class|exit.code)";;
  esac
  printf '%s' "$json" | awk -v target="$target" "$_AIB_EVENT_PAYLOAD_FIELD_AWK"
}

# --- read-only frame scanner / validator (shared core) -----------------------
# Classifies the whole stream fail-closed and computes the next writer seq. NEVER
# mutates the file (the writer performs the truncation the classifier prescribes).
# Args: <events_path> <extract_fields 0|1> <emit_records 0|1>
# Sets: AIB_EVENT_SCAN_STATUS      ok | degraded | corrupt
#       AIB_EVENT_SCAN_HIGHEST_SEQ highest valid seq (0 if none)
#       AIB_EVENT_SCAN_NEXT_SEQ    highest+1 (or 1)
#       AIB_EVENT_SCAN_TORN_TAIL   1 if an uncommitted (unterminated final) record exists
#       AIB_EVENT_SCAN_TRUNCATE_AT byte offset of the last intact LF boundary
#       AIB_EVENT_SCAN_DECIDED_IDS newline list of persisted attempt.decided event_ids
#       AIB_EVENT_SCAN_ENDED_IDS   newline list of attempt_ids that already have an ended
#       AIB_EVENT_SCAN_CORRUPT_REASON  human-readable cause when corrupt
# With emit=1 it prints `<seq>\t<json>` per intact record (for the fold), skipping the
# uncommitted tail and printing nothing once corrupt.
_aib_event_scan_core() {
  local path="$1" extract="${2:-0}" emit="${3:-0}"
  local LC_ALL=C
  AIB_EVENT_SCAN_STATUS=ok
  AIB_EVENT_SCAN_HIGHEST_SEQ=0
  AIB_EVENT_SCAN_NEXT_SEQ=1
  AIB_EVENT_SCAN_TORN_TAIL=0
  AIB_EVENT_SCAN_TRUNCATE_AT=0
  AIB_EVENT_SCAN_DECIDED_IDS=""
  AIB_EVENT_SCAN_ENDED_IDS=""
  AIB_EVENT_SCAN_CORRUPT_REASON=""
  [ -e "$path" ] || return 0
  if [ ! -r "$path" ]; then
    AIB_EVENT_SCAN_STATUS=corrupt
    AIB_EVENT_SCAN_CORRUPT_REASON="events stream is not readable"
    return 0
  fi

  local line rc terminated offset=0 prev_seq=0
  local seq crc len json calc calclen fields rest fev_id fev_type fatt_id
  while true; do
    IFS= read -r line; rc=$?
    if [ "$rc" -ne 0 ] && [ -z "$line" ]; then break; fi
    if [ "$rc" -eq 0 ]; then terminated=1; else terminated=0; fi

    # An unterminated final segment is the uncommitted tail — the LF is the commit
    # marker, so this holds regardless of whether the bytes would otherwise parse.
    if [ "$terminated" -eq 0 ]; then
      AIB_EVENT_SCAN_TORN_TAIL=1
      AIB_EVENT_SCAN_TRUNCATE_AT="$offset"
      break
    fi

    # strict positional parse: exactly three single-SP-separated leading tokens
    if [[ "$line" =~ ^([0-9]+)' '([0-9]+)' '([0-9]+)' '(.*)$ ]]; then
      seq="${BASH_REMATCH[1]}"; crc="${BASH_REMATCH[2]}"; len="${BASH_REMATCH[3]}"; json="${BASH_REMATCH[4]}"
    else
      AIB_EVENT_SCAN_STATUS=corrupt
      AIB_EVENT_SCAN_CORRUPT_REASON="unparsable framed record near offset $offset"
      return 0
    fi
    case "$json" in
      {*) ;;
      *) AIB_EVENT_SCAN_STATUS=corrupt; AIB_EVENT_SCAN_CORRUPT_REASON="record body is not a JSON object (seq $seq)"; return 0;;
    esac
    if [ "${#json}" -ne "$len" ]; then
      AIB_EVENT_SCAN_STATUS=corrupt; AIB_EVENT_SCAN_CORRUPT_REASON="len mismatch (seq $seq)"; return 0
    fi
    set -- $(printf '%s' "$json" | cksum); calc="$1"; calclen="$2"
    if [ "$calc" != "$crc" ] || [ "$calclen" -ne "$len" ]; then
      AIB_EVENT_SCAN_STATUS=corrupt; AIB_EVENT_SCAN_CORRUPT_REASON="crc/len mismatch (seq $seq)"; return 0
    fi
    # monotonicity: a decreasing or duplicate seq on a TERMINATED record is tampering,
    # not loss — corrupt. A forward gap is loss — degraded, non-blocking.
    if [ "$prev_seq" -ne 0 ]; then
      if [ "$seq" -le "$prev_seq" ]; then
        AIB_EVENT_SCAN_STATUS=corrupt; AIB_EVENT_SCAN_CORRUPT_REASON="non-monotonic seq $seq after $prev_seq"; return 0
      fi
      [ "$seq" -eq $((prev_seq + 1)) ] || AIB_EVENT_SCAN_STATUS=degraded
    else
      [ "$seq" -eq 1 ] || AIB_EVENT_SCAN_STATUS=degraded
    fi
    prev_seq="$seq"
    AIB_EVENT_SCAN_HIGHEST_SEQ="$seq"

    if [ "$extract" -eq 1 ]; then
      fields="$(printf '%s' "$json" | awk -v k1=event_id -v k2=event_type -v k3=attempt_id "$_AIB_EVENT_FIELD_AWK")"
      fev_id="${fields%%$'\t'*}"; rest="${fields#*$'\t'}"; fev_type="${rest%%$'\t'*}"; fatt_id="${rest##*$'\t'}"
      # tie the framing prefix to the crc-protected body: the seq inside event_id must
      # equal the prefix seq. Catches a shifted prefix that still crc-matches its body.
      if [ "${fev_id##*-}" != "$seq" ]; then
        AIB_EVENT_SCAN_STATUS=corrupt; AIB_EVENT_SCAN_CORRUPT_REASON="event_id/seq mismatch (seq $seq, event_id $fev_id)"; return 0
      fi
      case "$fev_type" in
        attempt.decided) AIB_EVENT_SCAN_DECIDED_IDS="${AIB_EVENT_SCAN_DECIDED_IDS}${fev_id}"$'\n';;
        attempt.ended) AIB_EVENT_SCAN_ENDED_IDS="${AIB_EVENT_SCAN_ENDED_IDS}${fatt_id}"$'\n';;
      esac
    fi
    [ "$emit" -eq 1 ] && printf '%s\t%s\n' "$seq" "$json"
    offset=$((offset + ${#line} + 1))
  done < "$path"

  AIB_EVENT_SCAN_NEXT_SEQ=$((AIB_EVENT_SCAN_HIGHEST_SEQ + 1))
  return 0
}

# aib_event_scan <events_path> — read-only public scan for the fold (Lane C). Sets the
# AIB_EVENT_SCAN_* globals and prints `<seq>\t<json>` for each intact record. It does
# NOT truncate (writer-only): an uncommitted tail is reported and skipped, a corrupt
# stream sets status=corrupt and prints nothing so the fold can refuse a verdict.
aib_event_scan() {
  local path="${1:-}"
  [ -n "$path" ] || aib_die 2 "event scan requires a stream path"
  _aib_event_scan_core "$path" 1 1
}

# --- record composer (identity fields injected by the broker only) -----------
_aib_json_or_null() { [ -n "$1" ] && aib_json "$1" || printf 'null'; }
_aib_event_compose_record() {
  local event_id="$1" event_type="$2" occurred_at="$3" actor_type="$4" actor_id="$5" project_uid="$6"
  local team_uid="$7" agent_uid="$8" session_id="$9" run_id="${10}" task_id="${11}"
  local gate_id="${12}" grant_id="${13}" effect_id="${14}"
  local attempt_id="${15}" correlation_id="${16}" causation_id="${17}" schema_version="${18}" payload_json="${19}"
  printf '{"event_id":%s,"event_type":%s,"occurred_at":%s,"actor_type":%s,"actor_id":%s,"project_uid":%s,"team_uid":%s,"agent_uid":%s,"session_id":%s,"run_id":%s,"task_id":%s,"gate_id":%s,"grant_id":%s,"effect_id":%s,"attempt_id":%s,"correlation_id":%s,"causation_id":%s,"schema_version":%s,"payload":%s}' \
    "$(aib_json "$event_id")" "$(aib_json "$event_type")" "$(aib_json "$occurred_at")" \
    "$(aib_json "$actor_type")" "$(aib_json "$actor_id")" "$(aib_json "$project_uid")" \
    "$(_aib_json_or_null "$team_uid")" "$(_aib_json_or_null "$agent_uid")" "$(_aib_json_or_null "$session_id")" \
    "$(_aib_json_or_null "$run_id")" "$(_aib_json_or_null "$task_id")" "$(_aib_json_or_null "$gate_id")" \
    "$(_aib_json_or_null "$grant_id")" "$(_aib_json_or_null "$effect_id")" \
    "$(aib_json "$attempt_id")" "$(aib_json "$correlation_id")" "$(aib_json "$causation_id")" \
    "$schema_version" "$payload_json"
}

# --- aib_event_commit — the serialising append broker ------------------------
# aib_event_commit <events_path> <lock_path> <event_type> <envelope_kv> <payload_json> [decided_event_id]
#
# `payload_json` is trusted composer output from aib_event_compose_decided_payload or
# aib_event_compose_ended_payload. The broker enforces object/one-line shape, identity,
# framing, size, and stream invariants; it deliberately does not duplicate a JSON parser.
#
# The caller passes payload + envelope fields WITHOUT any identity field. INSIDE the
# exclusive sidecar lock the broker: validates the whole stream fail-closed, truncates
# an uncommitted tail, allocates `seq`, COMPOSES the identity from that seq (§B4 — no
# pre-composed line ever crosses the seam), frames + checked-appends, and only THEN
# publishes the result. Returns AIB_EVENT_COMMIT_SEQ / AIB_EVENT_COMMIT_EVENT_ID.
# At most one attempt.ended per attempt_id is revalidated UNDER the lock (§B3). The lock
# wait is FINITE (flock -w) so a stuck cooperating writer cannot silently freeze all
# launches (§3/§5 DoS bound); a timeout fails loudly with a stable exit code (75).
aib_event_commit() {
  local events_path="${1:-}" lock_path="${2:-}" event_type="${3:-}"
  local envelope_kv="${4-}" payload_json="${5-}" decided_id="${6-}"
  local _fd timeout k LC_ALL=C
  local project_uid actor_type actor_id agent_uid team_uid session_id run_id task_id gate_id grant_id effect_id occurred_at

  [ "$#" -ge 5 ] || aib_die 2 "event commit requires events path, lock path, event_type, envelope, payload"
  [ -n "$events_path" ] && [ -n "$lock_path" ] && [ -n "$event_type" ] ||
    aib_die 2 "event commit requires events path, lock path, and event_type"
  [ -z "${AIB_EVENT_ACTIVE_LOCK:-}" ] || aib_die 2 "nested event commits are not supported"
  command -v flock >/dev/null 2>&1 || aib_die 6 "required runtime dependency not found: flock (util-linux)"
  command -v cksum >/dev/null 2>&1 || aib_die 6 "required runtime dependency not found: cksum"

  case "$event_type" in
    attempt.decided|attempt.ended) ;;
    *) aib_die 2 "unknown event_type '$event_type' (expected attempt.decided|attempt.ended)";;
  esac
  [ -n "$payload_json" ] || aib_die 2 "event commit requires a payload"
  case "$payload_json" in
    {*) ;;
    *) aib_die 2 "event payload must be a JSON object";;
  esac
  case "$payload_json" in
    *$'\n'*|*$'\r'*) aib_die 2 "event payload must be a single physical line";;
  esac

  # No pre-composed identity field may cross the seam (§B4/N1) — the broker owns them.
  for k in event_id attempt_id correlation_id causation_id seq; do
    if _aib_record_field "$envelope_kv" "$k" >/dev/null; then
      aib_die 2 "envelope must not carry identity field '$k' (the broker composes identity under the lock)"
    fi
  done

  project_uid="$(_aib_record_field "$envelope_kv" project_uid)" || project_uid=""
  actor_type="$(_aib_record_field "$envelope_kv" actor_type)"   || actor_type=""
  actor_id="$(_aib_record_field "$envelope_kv" actor_id)"       || actor_id=""
  agent_uid="$(_aib_record_field "$envelope_kv" agent_uid)"     || agent_uid=""
  team_uid="$(_aib_record_field "$envelope_kv" team_uid)"       || team_uid=""
  session_id="$(_aib_record_field "$envelope_kv" session_id)"   || session_id=""
  run_id="$(_aib_record_field "$envelope_kv" run_id)"           || run_id=""
  task_id="$(_aib_record_field "$envelope_kv" task_id)"         || task_id=""
  gate_id="$(_aib_record_field "$envelope_kv" gate_id)"         || gate_id=""
  grant_id="$(_aib_record_field "$envelope_kv" grant_id)"       || grant_id=""
  effect_id="$(_aib_record_field "$envelope_kv" effect_id)"     || effect_id=""
  occurred_at="$(_aib_record_field "$envelope_kv" occurred_at)" || occurred_at=""

  [ -n "$project_uid" ] || aib_die 2 "event envelope requires project_uid"
  aib_validate_token "$project_uid" project_uid
  [ -n "$actor_type" ] || aib_die 2 "event envelope requires actor_type"
  case "$actor_type" in human|agent|service|provider) ;; *) aib_die 2 "invalid actor_type '$actor_type'";; esac
  [ -n "$actor_id" ] || aib_die 2 "event envelope requires actor_id (§B7)"
  if [ "$event_type" = attempt.ended ]; then
    [ -n "$decided_id" ] || aib_die 2 "attempt.ended requires the decided event_id (causation)"
  fi

  timeout="${AIBOBNET_EVENT_LOCK_TIMEOUT:-10}"
  case "$timeout" in ''|*[!0-9.]*) aib_die 2 "invalid event lock timeout '$timeout'";; esac

  mkdir -p -- "$(dirname -- "$events_path")" || aib_die 2 "cannot create events directory for: $events_path"
  AIB_EVENT_COMMIT_SEQ=""
  AIB_EVENT_COMMIT_EVENT_ID=""

  exec {_fd}>>"$lock_path" || aib_die 2 "cannot open event lock: $lock_path"
  if ! flock -w "$timeout" -x "$_fd"; then
    aib_die 75 "event stream lock not acquired within ${timeout}s (contention or a stuck writer): $lock_path"
  fi
  local AIB_EVENT_ACTIVE_LOCK="$lock_path"
  local AIB_EVENT_LOCK_FD="$_fd"

  _aib_event_scan_core "$events_path" 1 0
  if [ "$AIB_EVENT_SCAN_STATUS" = corrupt ]; then
    aib_die 2 "event stream is corrupt (${AIB_EVENT_SCAN_CORRUPT_REASON}) — refusing append: $events_path"
  fi
  if [ "$AIB_EVENT_SCAN_TORN_TAIL" -eq 1 ]; then
    command -v truncate >/dev/null 2>&1 || aib_die 6 "required runtime dependency not found: truncate (coreutils) — needed to remove an uncommitted tail"
    truncate -s "$AIB_EVENT_SCAN_TRUNCATE_AT" "$events_path" ||
      aib_die 2 "cannot truncate the uncommitted tail of: $events_path"
  fi

  local seq="$AIB_EVENT_SCAN_NEXT_SEQ"
  local event_id="${project_uid}-${AIB_EVENT_STREAM_NAME}-${seq}"
  local attempt_id correlation_id causation_id
  if [ "$event_type" = attempt.decided ]; then
    attempt_id="$event_id"; correlation_id="$event_id"; causation_id="$event_id"
  else
    case $'\n'"${AIB_EVENT_SCAN_DECIDED_IDS}" in
      *$'\n'"$decided_id"$'\n'*) ;;
      *) aib_die 2 "attempt.ended requires a persisted prior attempt.decided event_id";;
    esac
    case $'\n'"${AIB_EVENT_SCAN_ENDED_IDS}" in
      *$'\n'"$decided_id"$'\n'*)
        aib_die 2 "attempt '$decided_id' already has an attempt.ended — refusing a second terminal record";;
    esac
    attempt_id="$decided_id"; correlation_id="$decided_id"; causation_id="$decided_id"
  fi

  [ -n "$occurred_at" ] || occurred_at="$(aib_event_now)"

  local record
  record="$(_aib_event_compose_record \
    "$event_id" "$event_type" "$occurred_at" "$actor_type" "$actor_id" "$project_uid" \
    "$team_uid" "$agent_uid" "$session_id" "$run_id" "$task_id" "$gate_id" "$grant_id" "$effect_id" \
    "$attempt_id" "$correlation_id" "$causation_id" "$AIB_EVENT_SCHEMA_VERSION" "$payload_json")"
  case "$record" in
    *$'\n'*|*$'\r'*) aib_die 2 "composed event record is not a single physical line";;
  esac
  [ "${#record}" -le "$AIB_EVENT_MAX_RECORD_BYTES" ] ||
    aib_die 2 "encoded event record exceeds ${AIB_EVENT_MAX_RECORD_BYTES}-byte cap"

  local crc len
  set -- $(printf '%s' "$record" | cksum); crc="$1"; len="$2"
  if ! printf '%s %s %s %s\n' "$seq" "$crc" "$len" "$record" >> "$events_path"; then
    aib_die 2 "cannot append event record: $events_path"
  fi
  exec {_fd}>&- || aib_die 2 "cannot close event lock: $lock_path"
  AIB_EVENT_COMMIT_SEQ="$seq"
  AIB_EVENT_COMMIT_EVENT_ID="$event_id"
}

# --- RM-3 broker transport (mediated launch contract §6) ---------------------
# The wire carries token fields as record lines and free text length-prefixed. The parser
# COUNTS BYTES for the free text instead of searching for a separator — that is what makes a
# prompt containing "\nagent_uid=root" arrive as payload rather than as a forged field.
#
# These functions REFUSE by return code and set AIB_WIRE_ERROR; they never aib_die. The caller
# is one connection instance and has to answer with a terminal status line before it exits —
# a refusal the client cannot read is indistinguishable from a dead broker (spike, 2026-08-10).
AIB_WIRE_PROMPT_MAX="${AIB_WIRE_PROMPT_MAX:-65536}"
# RM-3 slice 2 (SPEC-wire-format): cwd and label join prompt as length-prefixed
# blocks, each with its own cap. 4096 mirrors PATH_MAX; 256 is generous for a
# display label (§3: label form is checked, content is not — length is form).
AIB_WIRE_CWD_MAX="${AIB_WIRE_CWD_MAX:-4096}"
AIB_WIRE_LABEL_MAX="${AIB_WIRE_LABEL_MAX:-256}"
# A wire-level sanity ceiling on `timeout`, independent of any provider's cap_timeout
# (which the PDP alone enforces). 86400s (24h) is generous enough never to be the
# real limit in practice; its job is only to keep an absurd value from parsing at all.
AIB_WIRE_TIMEOUT_MAX="${AIB_WIRE_TIMEOUT_MAX:-86400}"

# Fields whose value is composed under the commit lock and is NEVER accepted from a caller (§3).
AIB_WIRE_FORBIDDEN_FIELDS="event_id attempt_id seq"

# aib_wire_read_request  <stdin: request frame> -> AIB_REQ_<FIELD> … + AIB_REQ_{CWD,LABEL,PROMPT}
aib_wire_read_request() {
  AIB_WIRE_ERROR=""
  # LC_ALL=C belongs on the local line, not just in front of `read` — the length check below runs
  # AFTER the read and would otherwise count characters under the ambient locale. Gate finding
  # 2026-08-15 (Riker, HIGH): a byte-exact prompt containing "ö" was refused as a short read.
  # Same idiom as _aib_utf8_is_valid, aib_json and three other places in this file.
  local key val f seen="" LC_ALL=C
  local n_cwd="" n_label="" n_prompt="" cwd="" label="" prompt=""
  local frame="" header="" body="" rest="" line=""

  # RM-3 slice 2 delta (gate finding, Ikarus R1, HIGH — same class as D1, the other
  # path through this function): reading record lines one at a time with `read -r`
  # per line is not NUL-safe either. Bash's `read -r` silently drops a NUL byte from
  # the line it returns, so the bytes `agent_uid=acme-<NUL>dev` arrived as the VALUE
  # "acme-dev" — one byte short of what the caller actually sent, and already past
  # the point where the control-character check on that value could ever see the
  # missing byte. Fix: read the ENTIRE frame — record lines and free text together —
  # in ONE `read -r -d ''` call, the same NUL-delimiter idiom the body-only fix
  # already uses below. rc=0 means a NUL was found ANYWHERE in the frame (refused
  # here, before a single byte of it is interpreted as a field); rc>0 is the ordinary
  # EOF case and `frame` holds every byte sent, exactly once. The header/record-line
  # section is then split out and iterated IN-PROCESS, by string slicing — never by a
  # second read — so no byte can go missing between this point and validation.
  if LC_ALL=C IFS= read -r -d '' frame; then
    AIB_WIRE_ERROR="control byte in frame"; return 2
  fi

  # The blank line separating record lines from free text is, in bytes, either a
  # leading newline (a frame with zero record lines) or the first "\n\n" anywhere in
  # the frame — record lines are each newline-terminated, so the blank line itself is
  # the second consecutive newline. Splitting on the FIRST such marker is required
  # (SPEC-wire-format, "Frame order"): a later "\n\n" inside the free text (e.g. a
  # multi-paragraph prompt) must stay part of the body, never end the header early.
  case "$frame" in
    $'\n'*)    header=""; body="${frame#$'\n'}" ;;
    *$'\n\n'*) header="${frame%%$'\n\n'*}"; body="${frame#*$'\n\n'}" ;;
    *)
      # Without the blank line the record lines and the free text are not separated
      # at all. Saying "short read" there sent the reader hunting in the wrong place
      # (gate finding, Marvin).
      AIB_WIRE_ERROR="missing blank line between record lines and free text"; return 2
      ;;
  esac

  # Record lines, iterated from the already-read, already-NUL-checked header string.
  # Same manual newline split idiom as _aib_record_field — pure parameter expansion,
  # no further `read` of any kind for the header section.
  rest="$header"
  while [ -n "$rest" ]; do
    line="${rest%%$'\n'*}"
    case "$rest" in
      *$'\n'*) rest="${rest#*$'\n'}" ;;
      *) rest="" ;;
    esac
    case "$line" in
      *=*) : ;;
      *) AIB_WIRE_ERROR="malformed record line"; return 2 ;;
    esac
    key="${line%%=*}"; val="${line#*=}"
    case "$key" in
      [a-z]|[a-z][a-z0-9_]*) : ;;
      *) AIB_WIRE_ERROR="invalid field name '$key'"; return 2 ;;
    esac
    # Identity fields get their own message before the allowlist, so the refusal stays diagnosable.
    for f in $AIB_WIRE_FORBIDDEN_FIELDS; do
      [ "$key" = "$f" ] && { AIB_WIRE_ERROR="identity field '$key' is composed under the lock, not accepted"; return 2; }
    done
    # ALLOWLIST, not a blocklist (gate finding 2026-08-15, Riker, MEDIUM): a blocklist has to be
    # remembered every time the contract grows a field. The contract enumerates what crosses (§3),
    # so the wire accepts exactly that and nothing else — including no environment fields, without
    # needing a rule about them. Slice 2 adds sandbox/timeout (token fields) and the cwd_bytes/
    # label_bytes headers for the two new length-prefixed blocks (SPEC-wire-format); cwd and label
    # themselves are never record-line keys, only their byte-count headers are. Everything else
    # (clearance, cap_*, env) stays refused without needing a rule about it.
    case "$key" in
      op|agent_uid|prompt_bytes|sandbox|timeout|cwd_bytes|label_bytes) : ;;
      *) AIB_WIRE_ERROR="field '$key' is not accepted at this seam"; return 2 ;;
    esac
    # A repeated field must not silently win with its last value — for agent_uid that would be a
    # HIGH-severity ambiguity (gate finding 2026-08-15, Riker LOW / Marvin coverage gap).
    case " $seen " in *" $key "*) AIB_WIRE_ERROR="field '$key' given more than once"; return 2 ;; esac
    seen="$seen $key"
    case "$val" in *[[:cntrl:]]*) AIB_WIRE_ERROR="control character in field '$key'"; return 2 ;; esac
    # §6: token fields are validated against the EXISTING token rules — a FLOOR, which `sandbox`
    # and `timeout` narrow (SPEC-wire-format: "a floor, not a ceiling"). The validators aib_die, so
    # they run in a subshell and their exit code becomes a refusal (gate finding, Marvin).
    case "$key" in
      agent_uid) ( aib_validate_agent_uid "$val" ) >/dev/null 2>&1 || {
                   AIB_WIRE_ERROR="agent_uid is not a valid token"; return 2; } ;;
      op)        ( aib_validate_token "$val" op ) >/dev/null 2>&1 || {
                   AIB_WIRE_ERROR="op is not a valid token"; return 2; } ;;
      sandbox)   _aib_rank sandbox "$val"
                 [ "$_AIB_RANK" -ne 0 ] || {
                   AIB_WIRE_ERROR="sandbox '$val' is not a recognised mode"; return 2; } ;;
      timeout)   case "$val" in
                   ''|*[!0-9]*) AIB_WIRE_ERROR="timeout '$val' is not a positive integer"; return 2 ;;
                 esac
                 [ "$val" -gt 0 ] 2>/dev/null || {
                   AIB_WIRE_ERROR="timeout '$val' must be a positive integer"; return 2; }
                 [ "$val" -le "$AIB_WIRE_TIMEOUT_MAX" ] 2>/dev/null || {
                   AIB_WIRE_ERROR="timeout '$val' exceeds the wire maximum of $AIB_WIRE_TIMEOUT_MAX seconds"; return 2; } ;;
    esac
    # The three <field>_bytes headers are consumed here, never published as AIB_REQ_* — they
    # describe the length-prefixed blocks read below, they are not request fields themselves.
    case "$key" in
      cwd_bytes)    n_cwd="$val";    continue ;;
      label_bytes)  n_label="$val";  continue ;;
      prompt_bytes) n_prompt="$val"; continue ;;
    esac
    printf -v "AIB_REQ_$(printf '%s' "$key" | tr 'a-z' 'A-Z')" '%s' "$val"
  done

  # RM-3 slice 2 delta (gate finding, Riker, D6): a frame missing `op` or `agent_uid`
  # is a malformed CALLER frame, not something a downstream resolver failure should
  # ever have to explain. Refusing it HERE, at the wire, keeps a caller mistake from
  # being reported as a broker incident (registry_config/registry_unavailable) three
  # layers downstream, where nothing can tell the two apart any more.
  [ -n "${AIB_REQ_OP:-}" ] || { AIB_WIRE_ERROR="missing required field 'op'"; return 2; }
  [ -n "${AIB_REQ_AGENT_UID:-}" ] || { AIB_WIRE_ERROR="missing required field 'agent_uid'"; return 2; }

  # Each <field>_bytes header is independent; an absent header means the block is absent from
  # the stream, and an explicit `<field>_bytes=0` behaves exactly the same way (SPEC-wire-format,
  # "Two edges"). For cwd this is also the empty-cwd-means-derived-root edge, resolved by
  # aib_contain_cwd, not here.
  case "$n_cwd" in
    '') n_cwd=0 ;;
    *[!0-9]*) AIB_WIRE_ERROR="cwd_bytes missing or not a number"; return 2 ;;
  esac
  [ "$n_cwd" -le "$AIB_WIRE_CWD_MAX" ] || {
    AIB_WIRE_ERROR="cwd of $n_cwd bytes exceeds the cap of $AIB_WIRE_CWD_MAX"; return 2; }

  case "$n_label" in
    '') n_label=0 ;;
    *[!0-9]*) AIB_WIRE_ERROR="label_bytes missing or not a number"; return 2 ;;
  esac
  [ "$n_label" -le "$AIB_WIRE_LABEL_MAX" ] || {
    AIB_WIRE_ERROR="label of $n_label bytes exceeds the cap of $AIB_WIRE_LABEL_MAX"; return 2; }

  case "$n_prompt" in
    '') n_prompt=0 ;;
    *[!0-9]*) AIB_WIRE_ERROR="prompt_bytes missing or not a number"; return 2 ;;
  esac
  [ "$n_prompt" -le "$AIB_WIRE_PROMPT_MAX" ] || {
    AIB_WIRE_ERROR="prompt of $n_prompt bytes exceeds the cap of $AIB_WIRE_PROMPT_MAX"; return 2; }

  # Fixed frame order: cwd, label, prompt (SPEC-wire-format, "Frame order"). The headers say how
  # LONG each block is, not WHERE it sits — a reader that counts bytes cannot recover from an
  # unexpected order.
  #
  # `body` (the frame's free-text tail, everything after the blank line) was already sliced
  # from the single whole-frame read above (gate delta R1) — no second read here, and no
  # opportunity for a NUL to shift anything: the one read at the top of this function already
  # refused if the frame contained a NUL anywhere, headers or body alike. What remains is a
  # single length comparison against the declared total (RM-3 slice 2 delta D1's original
  # insight, still true): the three per-block short-read checks and the old trailing
  # "more bytes than declared" peek both fall out of comparing `body`'s length once; the
  # blocks are then sliced from `body` by offset, never re-read byte-by-byte.
  local total=$((n_cwd + n_label + n_prompt))
  if [ "${#body}" -ne "$total" ]; then
    AIB_WIRE_ERROR="frame declares $total bytes (cwd+label+prompt) but carries ${#body}"
    return 2
  fi
  cwd="${body:0:n_cwd}"
  label="${body:n_cwd:n_label}"
  prompt="${body:$((n_cwd + n_label)):n_prompt}"

  case "$cwd" in
    *[[:cntrl:]]*)
      # FORM check, not content: the internal PDP record is line-oriented
      # (_aib_record_field), so a newline in cwd would split the record into two
      # fields. Containment (aib_contain_cwd) decides everything else about cwd.
      AIB_WIRE_ERROR="control character in cwd"; return 2 ;;
  esac
  case "$label" in
    *[[:cntrl:]]*)
      # Same line-oriented-record reason as cwd. Label CONTENT is otherwise never
      # checked (§3: form yes, content no) — length and control characters are all
      # the wire ever decides about it.
      AIB_WIRE_ERROR="control character in label"; return 2 ;;
  esac

  AIB_REQ_CWD="$cwd"
  AIB_REQ_LABEL="$label"
  AIB_REQ_PROMPT="$prompt"
  return 0
}

# aib_wire_write_response <ok|denied|error> [field=value …] -> response frame on stdout
# The terminal line is the contract: without it the caller cannot tell a refusal from a broker
# that died mid-connection, or from a connection the socket dropped over MaxConnections.
aib_wire_write_response() {
  local status="$1"; shift
  case "$status" in ok|denied|error) : ;; *) status=error ;; esac
  local kv
  for kv in "$@"; do printf '%s\n' "$kv"; done
  printf 'end=%s\n' "$status"
}

# aib_build_pdp_request_record <agent_uid> <sandbox> <cwd> <timeout> <label>
#   -> the request record aib_authorize_launch expects, on stdout.
# Factored out so bin/aib-broker-handler (RM-3 slice 2) does not reinvent the field
# order and shape bin/launch-agent's PEP already builds inline for the same PDP call.
aib_build_pdp_request_record() {
  printf 'agent_uid=%s\nsandbox=%s\ncwd=%s\ntimeout=%s\nlabel=%s' "$1" "$2" "$3" "$4" "$5"
}

# aib_build_pdp_snapshot_record <clearance> <provider> <effort> <adapter> <cap_sandbox>
#                                <cap_tier> <cap_effort> <cap_timeout>
#   -> the snapshot record aib_authorize_launch expects, on stdout.
aib_build_pdp_snapshot_record() {
  printf 'clearance=%s\nprovider=%s\neffort=%s\nadapter=%s\ncap_sandbox=%s\ncap_tier=%s\ncap_effort=%s\ncap_timeout=%s' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8"
}
