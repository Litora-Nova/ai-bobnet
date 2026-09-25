# ai-bobnet — Provider Adapters

This document lists what provisioning installs for each registered `providers.<name>` entry
(`docs/CONTRACT-execution-binding.md` §7.3, schema 4) and, for `codex`, the operator's own credential
recipe. `docs/CONTRACT-codex-run.md` §4.1 is the adapter ABI every entry here must accept; this
document is the per-provider deployment and operational detail behind that ABI, not a restatement of
it.

## `codex`

### Placement

| What | Path | Owner / mode |
|---|---|---|
| Wrapped binary | `/opt/aib/codex/<version>/codex` | root:aib-runtime 0755, static build, checksum pinned by provisioning |
| Adapter | `/opt/aib/adapters/codex` | root:aib-broker 0750, from this repo's `adapters/codex`, install-time copy |
| `CODEX_HOME` | `/var/lib/aib/.codex` | aib-broker:aib-broker 0700, created empty by provisioning |
| `config.toml` inside it | `/var/lib/aib/.codex/config.toml` | root:aib-broker 0644 |

`/opt/aib/codex/<version>/codex` is an immutable versioned install. Provisioning updates the
`/opt/aib/codex/current` symlink to select a version; the adapter defaults to
`/opt/aib/codex/current/codex`, while the registry continues to name the adapter. There is no
in-place binary rewrite. The adapter resolves the binary from that default; `AIB_CODEX_BIN` overrides that default when set, a deploy/test
seam analogous to `AIBOBNET_REGISTRY`'s "advanced/test locator" (`docs/CONTRACT-execution-binding.md`
§3) — never propagated by the broker's own `env -i` allow-list, never influenced by the request, and
absent in every production invocation. `tests/adapter_codex_spec.sh` is the one caller that sets it,
to point the adapter at a fake binary instead of the real one.

`$CODEX_HOME` is unconditionally in `LL_RW` for both effective sandboxes
(`docs/CONFINEMENT.md`, "Effective-sandbox → `LL_RW`") — the adapter's wrapped binary cannot start
against an unwritable `$CODEX_HOME` (measured write set: `config.toml`, `installation_id`, six sqlite
databases, `sessions/`, `shell_snapshots/`, extracted helper binaries — see `docs/CONFINEMENT.md` for
the full list).

### Sibling binary

The static build extracts nothing at runtime, but it spawns a **sibling executable** it expects next to
itself (`codex-code-mode-host`, shipped in the same package under `vendor/<triple>/bin/`). Without it the
run still ends `ok`, yet the tool router logs "failed to spawn code-mode host" and the model executes no
command — an answer without an action. Provisioning installs both files from the same pinned archive.

### Credential recipe (the operator's step, T4)

The adapter's credential check is file-based only, matching the deployment precondition already
stated in `docs/CONTRACT-execution-binding.md` §7.5 for the seam as a whole:

1. Preferred: run the wrapped binary's own login flow **on the broker host, as the broker account**, so the
   credential is created in place and never exists as a copy elsewhere. The browser callback the login
   opens on `localhost` is reached through an SSH port forward from the operator's machine:
   `ssh -L 1455:127.0.0.1:1455 <operator>@<host>`, then
   `sudo -u aib-broker -H env HOME=/var/lib/aib CODEX_HOME=/var/lib/aib/.codex /opt/aib/codex/current/codex login`
   and open the printed URL locally. (`codex login --with-api-key` reads a key from stdin and needs no
   browser.) This is a T4 (credential) action: PO-only, per the standing tier rule this repository
   inherits — no code path in this repository performs it on the operator's behalf.
2. Alternative: log in on a trusted machine and copy `auth.json` to `/var/lib/aib/.codex/auth.json`
   over an already-authenticated channel (SSH); the credential is not bound to the machine.
3. Verify `ls -l /var/lib/aib/.codex/auth.json` shows `aib-broker aib-broker` and mode `0600`; otherwise
   `chown aib-broker:aib-broker` and `chmod 0600` it.

The adapter refuses to start (exit **78**, one line, never the prompt) unless, at launch time:

- `$HOME/.codex/auth.json` exists and is a regular file, not a symlink;
- it is owned by the adapter's own running uid;
- its mode is `0600`;
- `$HOME/.codex` itself is a directory with mode `0700`, not a symlink.

An unset/empty HOME or failed metadata lookup is also a credential refusal. The Linux wrapper
uses GNU `stat` and compares the file owner with Bash's running effective uid; it never reads the
credential contents, compares mtimes, or caches a check across launches.

The check tolerates an **OAuth refresh rewrite** of `auth.json` (owner and mode are re-checked on
every launch; mtime and content are never compared against a prior value) — the wrapped binary is
expected to rewrite this file in place when a token refreshes, and that rewrite must not turn a
working credential into a launch failure on the very next attempt. An API-key `auth.json` does not
refresh and needs no such tolerance; the check is identical for both.

### Effort mapping

| Registry `effort` | `model_reasoning_effort` |
|---|---|
| `low` | `low` |
| `medium` | `medium` |
| `high` | `high` |
| `max` | `xhigh` |

Every other token is a shape refusal, exit **65**. Only `max→xhigh` renames; the other three pass
through their own name. This table is single-sourced with the adapter's own validation — a spec
assertion that changes one side without the other is a spec bug, not a documentation drift, because
there is exactly one place this mapping is expressed as code.

### Sandbox mapping and refusal

`read-only` and `workspace-write` pass through to the wrapped binary's own `-s` flag unchanged (the
value is otherwise unused — see `docs/CONTRACT-codex-run.md` §4.1 for why the wrapped binary's own
sandbox enforcement is bypassed and Landlock is the sandbox of record). `danger-full-access` is
refused by the adapter itself, exit **65**, unconditionally — even where the registry's `cap_sandbox`
would otherwise permit it. This is a wrapper-owned refusal, independent of and in addition to the
`docs/CONTRACT-codex-run.md` §2 refusal at the `codex-run` compatibility layer: the two refusals sit
at different seams (compatibility CLI vs. adapter ABI) and neither substitutes for the other.

### Exit codes

| Code | Meaning |
|---|---|
| `65` | shape, effort, or sandbox refusal (`EX_DATAERR`) — a malformed or disallowed argv token before `--`, never the prompt itself |
| `78` | credential missing, wrong mode, or foreign-owned (`EX_CONFIG`) |
| any other | the wrapped binary's own exit code, passed through unmodified |

The adapter never itself exits `124`, `126`, or `127` — see `docs/CONTRACT-codex-run.md` §4.1. `65`
and `78` are both disjoint from the PDP's own `64` (`docs/CONTRACT-execution-binding.md` §7.6).
For provider exits `65` and `78`, the existing `_aib_enact_map_status` (`lib/aibobnet.sh`) records
`attempt.ended(provider-failure, stage=provider)`; no terminal mapping changes are needed.

### One shared `CODEX_HOME`

Every agent and every project's attempt runs as the one broker account (`docs/CONFINEMENT.md`,
"Documented divergence"), so they all share one `$CODEX_HOME`: one `sessions/` history (mitigated —
not eliminated — by `--ephemeral`, verified to suppress `sessions/` writes; the sqlite state files
still accumulate across attempts), one `thread_history` and persistent-memory database, and one
`config.toml`. `--ephemeral` is a fixed flag precisely because it is the cheap half of that mitigation
available today; the full fix (a `CODEX_HOME` per project, keyed off `AIBOBNET_PROJECT_UID`, each with
its own `auth.json`) is a later slice and its own T4 decision, not built here. Provisioning owns
`config.toml` as `root:aib-broker 0644` to prevent in-place writes to that inode. This does not
make operator defaults immutable: the broker-owned writable parent directory permits unlink or
replacement, which the current Landlock write grant also permits. Protecting the configuration
from replacement needs a separate provisioning boundary; it is a follow-up, not a guarantee of
this slice. MCP servers, hooks, `model_provider` and `shell_environment_policy` remain shared
operator defaults under the documented cooperative-with-audit boundary.

The adapter's credential checks are metadata-only and sequential (type and symlink test, then directory
mode, then owner and file mode). A writer who already has write access to `CODEX_HOME` could replace
`auth.json` between two of those checks. That writer sits inside the same trust boundary as the shared
home itself, so the gap adds no authority beyond what this section already grants; it closes with the
per-project `CODEX_HOME` and the role-uid switch recorded as follow-up slices.

### Registry entry (example, `acme`)

```json
{
  "schema_version": 4,
  "providers": {
    "codex": {
      "adapter": "/opt/aib/adapters/codex",
      "cap_sandbox": "workspace-write",
      "cap_tier": "t3",
      "cap_effort": "high",
      "cap_timeout": "3600"
    }
  },
  "projects": {
    "acme": {
      "home": "/srv/acme",
      "standup_dir": "/srv/acme/standup",
      "mux_session": "acme",
      "provider": "codex",
      "model": "example-model",
      "effort": "high"
    }
  }
}
```

`cap_timeout` above is generous (an hour) relative to `docs/CONTRACT-codex-run.md`'s own `1200`s
default at the compatibility layer — the registry cap and a request's own `--timeout` still clamp to
`min(requested, cap_timeout)` (`docs/CONTRACT-execution-binding.md` §7.2) exactly as for every other
provider; nothing about the `codex` adapter changes that arithmetic.

## `claude-code`

Sprint I-B slice 2 (`standup/_design_claude-code-adapter.md` v2, `standup/_advisor_claude-code-adapter.md`,
ADR-0010). The second real adapter under the ABI `docs/CONTRACT-codex-run.md` §4.1 names; see §4.1.1
there for what stays identical to `codex`'s translation and what differs.

### Placement

| What | Path | Owner / mode |
|---|---|---|
| Wrapped binary | `/opt/aib/claude-code/<version>/claude` | root:aib-runtime 0755, dynamically-linked ELF, checksum pinned by provisioning |
| Adapter | `/opt/aib/adapters/claude-code` | root:aib-broker 0750, from this repo's `adapters/claude-code`, install-time copy |
| `CLAUDE_CONFIG_DIR` | `/var/lib/aib/.claude` | aib-broker:aib-broker 0700, created empty by provisioning |

`/opt/aib/claude-code/<version>/claude` is an immutable versioned install, exactly like `codex`'s own
placement above: provisioning updates the `/opt/aib/claude-code/current` symlink to select a version,
the adapter defaults to `/opt/aib/claude-code/current/claude`, and `AIB_CLAUDE_BIN` overrides that
default when set — a deploy/test seam analogous to `AIB_CODEX_BIN`, never propagated by the broker's
own `env -i` allow-list, never influenced by the request, absent in every production invocation.
`tests/adapter_claude_code_spec.sh` is the one caller that sets it.

**Unlike `codex`'s static build, this binary is dynamically linked** (`libc`, `libm`, `librt`,
`libpthread`, `libdl`, plus the dynamic loader) — it needs those readable at exec. `LL_RO=/` already
covers this (unchanged by this slice); the dependency list is recorded here for the same future `LL_RO`
narrowing `docs/CONFINEMENT.md` tracks for `codex`. There is no sibling executable to provision the way
`codex`'s `codex-code-mode-host` is (`docs/CONFINEMENT.md` has no claude-code-specific equivalent
finding); the probed footprint is otherwise `$HOME` writes, not a second binary.

`$CLAUDE_CONFIG_DIR` is unconditionally in `LL_RW` for both effective sandboxes
(`docs/CONFINEMENT.md`, "Effective sandbox × provider `state_dir` → `LL_RW`") — the wrapped binary
writes there **unconditionally, even unauthenticated** (`.claude.json` and its backups,
`sessions/`, `projects/<slug>/memory/`, `session-env/` — see `docs/CONFINEMENT.md`'s probed-footprint
note), which is a stronger reason than `codex`'s own "cannot start without it": `claude` does not even
refuse cleanly first.

### Credential recipe (the operator's step, T4)

The adapter's credential check is file-based only, the same shape as `codex`'s (`standup/
_facts_claude-code-adapter.md`: the pattern ports almost verbatim):

1. Preferred: run the wrapped binary's own login flow **on the broker host, as the broker account**,
   with `CLAUDE_CONFIG_DIR` **explicitly set** — omitting it sends the account metadata to
   `$HOME/.claude.json` at the top of `$HOME` instead of inside the state dir the adapter's runs
   actually read (`standup/_advisor_claude-code-adapter.md` F8):
   `sudo -u aib-broker -H env HOME=/var/lib/aib CLAUDE_CONFIG_DIR=/var/lib/aib/.claude
   /opt/aib/claude-code/current/claude auth login`, reaching the browser callback it opens on
   `localhost` through an SSH port forward from the operator's machine (`ssh -L <port>:127.0.0.1:<port>
   <operator>@<host>`) — the exact local port is `claude auth login`'s own choice and was not pinned by
   this slice's probes (unlike `codex`'s documented `1455`); check the login flow's own printed URL at
   deploy time rather than assuming a fixed port. This is a T4 (credential) action: PO-only, per the
   standing tier rule this repository inherits — no code path in this repository performs it on the
   operator's behalf.
2. Alternative: log in on a trusted machine (with `CLAUDE_CONFIG_DIR` set the same way) and copy
   `.credentials.json` to `/var/lib/aib/.claude/.credentials.json` over an already-authenticated
   channel (SSH); the credential is not bound to the machine.
3. Verify `ls -l /var/lib/aib/.claude/.credentials.json` shows `aib-broker aib-broker` and mode `0600`;
   otherwise `chown aib-broker:aib-broker` and `chmod 0600` it. Re-verify after the first OAuth token
   refresh too (see B14-equivalent acceptance note below) — the check tolerates the refresh rewrite
   exactly as `codex`'s does, but only if the rewrite itself lands with the right owner/mode.

The adapter refuses to start (exit **78**, one line, never the prompt) unless, at launch time:

- `$HOME/.claude/.credentials.json` exists and is a regular file, not a symlink;
- it is owned by the adapter's own running uid;
- its mode is `0600`;
- `$HOME/.claude` itself is a directory with mode `0700`, not a symlink.

An unset/empty HOME or failed metadata lookup is also a credential refusal. mtime is never compared —
the OAuth refresh rewrite is tolerated exactly like `codex`'s `auth.json`.

**The wrapped binary's own "not logged in" exit is a plain, generic `1`, not a sysexits code**
(`standup/_facts_claude-code-adapter.md` §C probe) — unlike `codex`, whose own exit codes never
had to be inferred as "credential missing" in the first place. This makes the adapter's own file-based
pre-flight above load-bearing in a stronger sense than for `codex`: there is no wrapped-binary exit code
the adapter could fall back to inferring 78 from, so a credential problem the pre-flight does not catch
(a change between the check and the wrapped binary's own read) surfaces as the wrapped binary's bare `1`,
passed through unmodified under "any other" below — a known, accepted limitation of a metadata-only,
sequential check, the same class of gap `docs/PROVIDERS.md`'s own `codex` section already documents for
its shared `CODEX_HOME`.

### Effort mapping

| Registry `effort` | `--effort` |
|---|---|
| `low` | `low` |
| `medium` | `medium` |
| `high` | `high` |
| `max` | `max` |

Identity — no rename, unlike `codex`'s `max→xhigh`. Every other token is a shape refusal, exit **65**.
This check is more load-bearing here than for `codex`: **`claude` does not refuse an unknown `--effort`
value at all** — it prints a warning and silently continues at its own default
(`standup/_advisor_claude-code-adapter.md` F4). The adapter's own 65 is therefore the *only* place this
gets refused; there is no wrapped-binary-side backstop to rely on.

**`max` is not always the API's own top effort.** `claude` silently lowers it for models that do not
support it (e.g. `opus-4-5` → `high`; observed via a scripted request body against a local fake Messages
API, never a real Anthropic endpoint). The adapter still passes `max` verbatim identity, no cap — the
registry's own `cap_effort` ceiling already bounds cost — but the effort recorded by this stack is the
adapter's own requested value, not necessarily the effort the API executed the turn at.

### Sandbox: no wrapped-binary flag to translate into

`claude` has **no OS-level sandbox flag or mechanism of its own** — no `--sandbox`, no
`bubblewrap|landlock|seccomp` strings in the binary (`standup/_facts_claude-code-adapter.md` §B) — so,
unlike `codex`, there is no sandbox-shaped argument to bypass. The adapter still validates `-s <value>`
for shape only (`read-only|workspace-write`, refusing `danger-full-access` unconditionally, exit **65**,
regardless of what the registry cap declares — the same wrapper-owned refusal `codex`'s section above
documents, independent of and in addition to the `docs/CONTRACT-codex-run.md` §2 refusal at the
compatibility layer), but the value drives exactly one conditional flag on the wrapped binary's side
(below), never a sandbox argument. Landlock is the sole sandbox of record for both adapters alike
(`docs/CONTRACT-codex-run.md` §4.1.1); `claude`'s own permission gate
(`--permission-mode bypassPermissions`) is defence in depth, verified (`standup/
_advisor_claude-code-adapter.md` F6) not to reopen anything Landlock already denies — a forced tool call
outside the confined `LL_RW` set is denied by Landlock regardless of the permission mode.

### Fixed flags and environment, in the pinned order

Appended by the adapter after validation, never received from the PEP and never registry-sourced:

```
claude -p --model <model> --effort <effort> --permission-mode bypassPermissions \
  --no-session-persistence --output-format text --setting-sources "" --strict-mcp-config \
  --add-dir "$PWD" [--disallowedTools=Edit,Write,NotebookEdit]
```

`--disallowedTools=Edit,Write,NotebookEdit` (one token — the flag is variadic and would otherwise
swallow following non-flag tokens, `standup/_advisor_claude-code-adapter.md` F6) is present **if and
only if** the effective sandbox is `read-only`; absent at `workspace-write`. No `--settings` flag: a v1
premise, dropped (F3) because the flag is a code-execution input (hooks in the file execute; a missing
path is itself a failure mode) and nothing in this slice's scope needs an operator settings file — the
`codex` `config.toml` replaceability finding this would have paralleled is already recorded at
`docs/PROVIDERS.md:120-127` (this file, `codex`'s own "One shared `CODEX_HOME`" section) and is not
re-filed here. The prompt travels on stdin, byte-exact, via a process substitution (never a `<<<`
here-string, which appends a newline) — there is no bare `-` sentinel token the way `codex`'s invocation
needs one; omitting a positional prompt argument after `-p` is what tells `claude` to read stdin.

Environment, exported by the adapter itself before the final `exec`, in this order:

```
SHELL=/bin/bash TERM=dumb CLAUDE_CONFIG_DIR=$HOME/.claude DISABLE_AUTOUPDATER=1 \
CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 \
XDG_CACHE_HOME=$HOME/.claude/cache CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1
```

`CLAUDE_CODE_DISABLE_AUTO_MEMORY=1` (F1): without it, `$CLAUDE_CONFIG_DIR/projects/<slug>/memory/
MEMORY.md` enters every attempt's system prompt, and because `$HOME/.claude` is one shared directory
across every project on the one shared broker account, one attempt's memory becomes the next attempt's
(any project's) steering input — a cross-attempt/cross-project injection channel `--setting-sources ""`
does not close by itself. `XDG_CACHE_HOME=$HOME/.claude/cache` (F5) is a belt for an MCP session's own
cache writes (`$HOME/.cache/claude-cli-nodejs/...`), which would otherwise land outside the state dir;
not triggered under `--strict-mcp-config` in the probe, kept anyway as a cheap, verified-honoured
redirect. Before this export block, the adapter also `unset`s `ANTHROPIC_API_KEY` and
`CLAUDE_CODE_OAUTH_TOKEN` defensively: the broker's own `env -i` allow-list is `HOME PATH` only, so
neither should ever be inherited in production, but the adapter does not rely on that alone — an
inherited value could otherwise switch which account the wrapped binary authenticates as.

### CLAUDE.md yes, hooks/skills/agents/MCP no (a stated decision, not a side effect)

`--setting-sources ""` alone suppresses far more than "settings": CLAUDE.md at both levels, skills,
agents, hooks, and MCP servers, at user and project level alike (`standup/
_advisor_claude-code-adapter.md` F2, probed against a fixture with a marker in each channel). Left
alone, that would run every agent **without the project's own CLAUDE.md** — safe and token-cheap, but a
side effect, not a decision, if left unstated. This slice states it: agents **do** get the project's
CLAUDE.md, via `--add-dir "$PWD"` plus `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1` (verified to
admit only the workspace CLAUDE.md, nothing else from that level), for parity with `codex`, which reads
a repository's `AGENTS.md` unconditionally. Hooks, skills, agents, and MCP configuration from
user/project/local settings stay off: CLAUDE.md is instructions, at the same trust level as the prompt
itself; hooks are code execution on the *next* attempt, which is exactly the class of thing `--setting-
sources ""` exists to keep out (`docs/CONTRACT-codex-run.md` §4.1.1's own credential/config isolation
concern, one level up). `--setting-sources project` was considered and rejected (not merely
"stricter than needed"): project-level settings also carry command-executing keys outside hooks
(`apiKeyHelper`, `statusLine`, …) that a `disableAllHooks` override does not cover, and those were not
probed individually enough to trust.

### Root/sudo self-refusal — noted, not used

`--dangerously-skip-permissions` self-refuses under uid 0 / sudo (binary string: "cannot be used with
root/sudo privileges for security reasons") — `codex`'s own bypass flag has no such refusal
(`adapters/codex:37`). This adapter does not pass `--dangerously-skip-permissions` at all (it uses
`--permission-mode bypassPermissions`, which has no such self-refusal), so the finding is moot while
`aib-broker` runs as a non-root account; it is recorded here because the pending role-uid slice may
change which account this confined child runs as, and that slice's design must know this refusal exists
before choosing an account model for `claude-code` specifically.

### Exit codes

| Code | Meaning |
|---|---|
| `65` | shape, effort, or sandbox refusal (`EX_DATAERR`) — a malformed or disallowed argv token before `--`, or an unrecognized `--effort` value the wrapped binary itself would only warn about, never the prompt itself |
| `78` | credential missing, wrong mode, or foreign-owned (`EX_CONFIG`) |
| `1` | the wrapped binary's own generic failure (includes "not logged in" if a credential state changes between the adapter's pre-flight and the wrapped binary's own read — see "Credential recipe" above) |
| any other | the wrapped binary's own exit code, passed through unmodified |

The adapter never itself exits `124`, `126`, or `127` — same discipline as `codex`
(`docs/CONTRACT-codex-run.md` §4.1). `65` and `78` are both disjoint from the PDP's own `64`
(`docs/CONTRACT-execution-binding.md` §7.6). Provider exits `65` and `78` map to
`attempt.ended(provider-failure, stage=provider)` via the existing `_aib_enact_map_status`, no new
terminal mapping needed — identical to `codex`'s own table entry above.

### One shared `$CLAUDE_CONFIG_DIR`

Every agent and every project's attempt runs as the one broker account (`docs/CONFINEMENT.md`,
"Documented divergence"), exactly as for `codex`, so they all share one `$CLAUDE_CONFIG_DIR`: one
`sessions/`/`projects/` history (mitigated, not eliminated, by `--no-session-persistence`, which does
**not** stop those directories from being created — `standup/_advisor_claude-code-adapter.md` F5;
do not assert their absence anywhere), one auto-memory store per project slug (mitigated by
`CLAUDE_CODE_DISABLE_AUTO_MEMORY=1` above), and one `.credentials.json`. A `CLAUDE_CONFIG_DIR` per
project is the same class of later slice `codex`'s own per-project `CODEX_HOME` is (`docs/
PROVIDERS.md`'s `codex` section, "One shared `CODEX_HOME`"), not built here.

### Registry entry (example, `acme`)

```json
{
  "schema_version": 4,
  "providers": {
    "claude-code": {
      "adapter": "/opt/aib/adapters/claude-code",
      "state_dir": ".claude",
      "cap_sandbox": "workspace-write",
      "cap_tier": "t3",
      "cap_effort": "high",
      "cap_timeout": "3600"
    }
  },
  "projects": {
    "acme": {
      "home": "/srv/acme",
      "standup_dir": "/srv/acme/standup",
      "mux_session": "acme",
      "provider": "codex",
      "model": "example-model",
      "effort": "high"
    }
  }
}
```

Project `acme` stays on `codex` by default; an acceptance run selects `claude-code` per agent binding
(`agents.<uid>.provider`, the same override shape `tests/adapter_codex_spec.sh`'s Block D already
exercises for a second registered provider) rather than by changing the project default.

### Acceptance (live, PO watching — mirrors `codex`'s own acceptance run)

Agent bound to `claude-code`: a `workspace-write` run asserts real `date` output plus a file written in
the project root; a `read-only` run's `touch` in the project root is refused, file absent (proving the
Landlock cage, not `claude`'s own tool gate, is what actually stops it — `--disallowedTools` only makes
the model fail fast); orphan check identical in shape to `codex`'s; the projection row shows
`provider.effective=claude-code`; egress log shows ≥1 connection for `aib-broker`; nothing written in
`$HOME` outside `.claude/`. Additionally, beyond `codex`'s own acceptance shape: `stat` of
`.credentials.json` (owner `aib-broker`, mode `0600`) after at least one OAuth token refresh, since this
adapter's credential check has no wrapped-binary exit code to fall back on if that rewrite ever lands
wrong (see "Credential recipe" above).

## `stub`

The reference test-matrix provider (`tests/broker_enact_spec.sh`'s stub shape, deployed on the VM as
`stub-codex` — `standup/_vm_exercise_rm3-slice4.md`) stays registered alongside `codex`, at a
permissive-but-narrow capability set, so the confined path can be exercised end-to-end without a real
provider binary or credential. It is not documented here beyond this pointer: its behavior is the
stub CLI shape already pinned by `tests/broker_enact_spec.sh`, not a deployment contract of its own.

---
White-label: example project id `acme`; no real names, infrastructure, or hosts.
