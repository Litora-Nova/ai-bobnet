# shellcheck shell=bash
# ai-bobnet — shared deterministic core library. SOURCE this, do not execute it.
#
# Contract: docs/CONTRACT.md. No external deps (no jq/python) — bash + awk + date only.
# Callers MUST set REPO_ROOT (the engine root that holds registry.json + lib/) before
# sourcing, e.g. via the symlink-safe resolver snippet each bin/ + scripts/ entrypoint uses.
#
# Registry authority: the project registry is the single source of truth for
# home / standup_dir / mux_session. Env is never trusted for those paths.

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
# Schema: { "projects": { "<uid>": { "home":..., "standup_dir":..., "mux_session":... }, ... } }
# Field values must be JSON strings (flat). Robust to arbitrary JSON whitespace.
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
  pstart = 0
  for (j=1; j<=ntok; j++) {
    if (ty[j]=="S" && tok[j]=="projects" && ty[j+1]=="P" && tok[j+1]==":" && ty[j+2]=="P" && tok[j+2]=="{") { pstart=j+2; break }
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
  if (op=="projects") { for (k=1;k<=nuid;k++) print uids[k]; exit 0 }
  if (op=="has")      { if (hasuid[uid]) exit 0; else exit 3 }
  if (op=="field") {
    if (!hasuid[uid]) exit 3
    key = uid SUBSEP field
    if (key in store) { print store[key]; exit 0 } else { exit 4 }
  }
  exit 9
}'

# aib_registry_query <projects|has|field> [uid] [field]
aib_registry_query() {
  local op="$1" uid="${2:-}" field="${3:-}" reg
  reg="$(aib_registry_file)"
  [ -r "$reg" ] || aib_die 2 "registry not found or unreadable: $reg"
  awk -v op="$op" -v uid="$uid" -v field="$field" "$_AIB_AWK" "$reg"
}

aib_require_project() {
  local p="$1"
  if ! aib_registry_query has "$p"; then
    aib_die 3 "unknown project_uid: '$p' (not in registry). Known: $(aib_registry_query projects | tr '\n' ' ')"
  fi
}

# aib_project_field <project_uid> <field> -> value (dies if missing/empty)
aib_project_field() {
  local p="$1" f="$2" v rc=0
  v="$(aib_registry_query field "$p" "$f")" || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$v" ]; then
    aib_die 3 "registry: project '$p' has no usable field '$f'"
  fi
  printf '%s\n' "$v"
}

# --- identity validation ------------------------------------------------------
aib_validate_token() {
  # single id token (project_uid or task): lowercase/digit/hyphen, no edge/double hyphen
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
    *-*) : ;;  # must be <project>-<task>
    *)   aib_die 4 "invalid agent_uid '$a' (expected <project_uid>-<task>)";;
  esac
}

# --- resolve project + task from an agent_uid (deterministic, fail-closed) -----
# Sets globals AIB_PROJECT_UID and AIB_TASK. A registered project uid is a prefix
# of the agent_uid up to the first "-"; ambiguous matches refuse to guess.
aib_split_agent() {
  local agent="$1"
  aib_validate_agent_uid "$agent"
  local plist; plist="$(aib_registry_query projects)" || true
  local match="" mtask="" count=0 p rest
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$agent" in
      "$p"-*)
        rest="${agent#"$p"-}"
        [ -n "$rest" ] || continue
        match="$p"; mtask="$rest"; count=$((count+1))
        ;;
    esac
  done <<EOF
$plist
EOF
  if [ "$count" -eq 0 ]; then
    aib_die 3 "cannot resolve project for agent_uid '$agent' (no registered project is a prefix). Known: $(printf '%s ' $plist)"
  elif [ "$count" -gt 1 ]; then
    aib_die 5 "ambiguous agent_uid '$agent' — matches multiple registered projects; refusing to guess"
  fi
  AIB_PROJECT_UID="$match"
  AIB_TASK="$mtask"
}

# aib_inbox_path <agent_uid> -> recipient's own inbox file (deterministic)
aib_inbox_path() {
  local agent="$1" sd
  aib_split_agent "$agent"
  sd="$(aib_project_field "$AIB_PROJECT_UID" standup_dir)"
  printf '%s/inbox/%s.md\n' "$sd" "$agent"
}
