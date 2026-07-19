# shellcheck shell=bash
# ai-bobnet — shared deterministic core library. SOURCE this, do not execute it.
#
# Contract: docs/CONTRACT.md. No external deps (no jq/python) — bash + awk + date only.
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

# --- minimal JSON string encoder (for context --json) -------------------------
aib_json() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

# --- registry location --------------------------------------------------------
# AIBOBNET_REGISTRY overrides for advanced/local use; otherwise the canonical
# location is <REPO_ROOT>/registry.json. (bin/run-agent scrubs AIBOBNET_* by
# design, so under run-agent the canonical repo-root registry is always used.)
aib_registry_file() {
  printf '%s\n' "${AIBOBNET_REGISTRY:-$REPO_ROOT/registry.json}"
}

aib_check_registry() {
  local reg; reg="$(aib_registry_file)"
  [ -r "$reg" ] || aib_die 2 "registry not found or unreadable: $reg"
}

# --- registry parser (pure awk; no jq) ----------------------------------------
# Schema (schema_version 2):
#   { "schema_version": 2,
#     "projects": { "<project_uid>": { "home":…, "standup_dir":…, "mux_session":… } },
#     "agents":   { "<agent_uid>":   { "project":…, "profile":…, "clearance":… } } }
# The top-level section is a PARAMETER (-v sect=projects|agents) so one tokenizer
# serves both. Field values must be JSON strings (flat); robust to arbitrary JSON
# whitespace. Unknown extra fields are ignored (forward-compatible, never load-bearing).
_AIB_AWK='
{ data = data $0 "\n" }
END {
  n = length(data); i = 1; ntok = 0
  while (i <= n) {
    c = substr(data, i, 1)
    if (c==" "||c=="\t"||c=="\r"||c=="\n") { i++; continue }
    if (c=="{"||c=="}"||c=="["||c=="]"||c==":"||c==",") { ntok++; tok[ntok]=c; ty[ntok]="P"; i++; continue }
    if (c=="\"") {
      s=""; i++
      while (i<=n) {
        d=substr(data,i,1)
        if (d=="\\") {
          e=substr(data,i+1,1)
          if(e=="n")s=s"\n"; else if(e=="t")s=s"\t"; else if(e=="r")s=s"\r";
          else if(e=="\"")s=s"\""; else if(e=="\\")s=s"\\"; else if(e=="/")s=s"/";
          else s=s e
          i+=2; continue
        }
        if (d=="\"") { i++; break }
        s=s d; i++
      }
      ntok++; tok[ntok]=s; ty[ntok]="S"; continue
    }
    s=""
    while (i<=n) {
      d=substr(data,i,1)
      if (d==" "||d=="\t"||d=="\r"||d=="\n"||d==","||d=="}"||d=="]"||d==":") break
      s=s d; i++
    }
    ntok++; tok[ntok]=s; ty[ntok]="V"; continue
  }
  # Locate the requested TOP-LEVEL section (depth 1) — a nested key of the same
  # name must never be mistaken for it.
  pstart = 0; sdepth = 0
  for (j=1; j<=ntok; j++) {
    if (ty[j]=="P" && (tok[j]=="{" || tok[j]=="[")) { sdepth++; continue }
    if (ty[j]=="P" && (tok[j]=="}" || tok[j]=="]")) { sdepth--; continue }
    if (sdepth==1 && ty[j]=="S" && tok[j]==sect && ty[j+1]=="P" && tok[j+1]==":" && ty[j+2]=="P" && tok[j+2]=="{") { pstart=j+2; break }
  }
  if (pstart==0) { exit 3 }
  depth=0; cur=""; nuid=0
  for (j=pstart; j<=ntok; j++) {
    if (ty[j]=="P" && tok[j]=="{") { depth++; continue }
    if (ty[j]=="P" && tok[j]=="}") { depth--; if(depth==0) break; if(depth==1) cur=""; continue }
    if (ty[j]=="S" && ty[j+1]=="P" && tok[j+1]==":") {
      if (depth==1) { cur=tok[j]; nuid++; uids[nuid]=cur; hasuid[cur]=1 }
      else if (depth==2 && cur!="") { store[cur SUBSEP tok[j]] = tok[j+2] }
    }
  }
  if (op=="keys") { for (k=1;k<=nuid;k++) print uids[k]; exit 0 }
  if (op=="has")  { if (hasuid[uid]) exit 0; else exit 3 }
  if (op=="field") {
    if (!hasuid[uid]) exit 3
    key = uid SUBSEP field
    if (key in store) { print store[key]; exit 0 } else { exit 4 }
  }
  exit 9
}'

# aib_registry_query <projects|agents> <keys|has|field> [uid] [field]
aib_registry_query() {
  local sect="$1" op="$2" uid="${3:-}" field="${4:-}" reg
  reg="$(aib_registry_file)"
  [ -r "$reg" ] || aib_die 2 "registry not found or unreadable: $reg"
  awk -v sect="$sect" -v op="$op" -v uid="$uid" -v field="$field" "$_AIB_AWK" "$reg"
}

aib_require_project() {
  local p="$1"
  if ! aib_registry_query projects has "$p"; then
    aib_die 3 "unknown project_uid: '$p' (not in registry). Known: $(aib_registry_query projects keys | tr '\n' ' ')"
  fi
}

# aib_project_field <project_uid> <field> -> value (dies if missing/empty)
aib_project_field() {
  local p="$1" f="$2" v rc=0
  v="$(aib_registry_query projects field "$p" "$f")" || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$v" ]; then
    aib_die 3 "registry: project '$p' has no usable field '$f'"
  fi
  printf '%s\n' "$v"
}

# aib_agent_field <agent_uid> <field> -> value (dies if missing/empty)
aib_agent_field() {
  local a="$1" f="$2" v rc=0
  v="$(aib_registry_query agents field "$a" "$f")" || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$v" ]; then
    aib_die 3 "registry: agent '$a' has no usable field '$f'"
  fi
  printf '%s\n' "$v"
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
