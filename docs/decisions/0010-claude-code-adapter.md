# ADR-0010: The `claude-code` Provider Adapter — Second Adapter, Generalised `LL_RW`, No Wrapped Sandbox

## Status

Accepted

## Date

2026-09-25

## Context

RM-3 slice I-B-1 built the first real provider adapter, `codex` (ADR-0009), and `docs/CONTRACT-codex-
run.md` §4.1 designed the adapter ABI to be provider-neutral from the start, naming a future
`claude-code` adapter explicitly. Sprint I-B slice 2's design
(`standup/_design_claude-code-adapter.md` v1) proposed the second adapter; a fact-finding probe
(`standup/_facts_claude-code-adapter.md`, no real credentials, no strace on this host) and an
architecture consult (`standup/_advisor_claude-code-adapter.md`, GO_WITH_NOTES, probes against a local
fake Anthropic Messages API, never a real endpoint) found four of v1's premises needing amendment
before the RED spec was pinned. This ADR records the corrected decisions (v2, all adopted) and the
alternatives they replaced, in the same shape ADR-0009 used for `codex`.

## Decision

### A. A second thin exec wrapper, same ABI, own file — no shared sourced helper

`adapters/claude-code` is a second, independent, `≤ 80`-line bash script: it validates the identical
eleven-token argv positively (the same checks and messages `adapters/codex:6-20` already uses, prefixed
`claude-code adapter:`), translates, and `exec`s. It does not source anything from `adapters/codex`, so
each adapter stays one self-contained file the broker execs directly — the anti-drift device is a spec
parity matrix (both adapters refuse the same malformed argv set with 65), not shared code, matching
ADR-0009's own "an exec wrapper, not a driver" reasoning.

### B. No wrapped-binary sandbox to bypass — Landlock is still the sole sandbox of record

Unlike `codex`, `claude` ships **no OS-level sandbox flag or mechanism at all** — `--help` has no
`--sandbox`, and the binary's strings have zero hits for `bubblewrap|landlock|seccomp|unshare(`
(`standup/_facts_claude-code-adapter.md` §B). There is therefore no collision to design around the way
ADR-0009 §B had to for `codex`'s bubblewrap-only sandbox. The adapter still validates `-s <value>` for
shape only, refusing `danger-full-access` unconditionally (parity with `codex`'s own refusal), but the
value drives exactly one conditional flag on the wrapped binary's side
(`--disallowedTools=Edit,Write,NotebookEdit` under read-only) rather than a sandbox argument. Landlock
remains the sole enforcement point for both adapters alike.

### C. The credential lives at the broker account's own `$CLAUDE_CONFIG_DIR`, explicitly set

**Rejected: relying on bare `$HOME` the way `codex` relies on `$HOME/.codex` falling out of
`CODEX_HOME`'s own default.** Probed (`standup/_advisor_claude-code-adapter.md` F5): without
`CLAUDE_CONFIG_DIR` set, `claude` writes `$HOME/.claude.json` at the top of `$HOME`, outside any state
directory a `state_dir`-scoped `LL_RW` grant would cover, and outside what the adapter's own credential
pre-flight checks. With `CLAUDE_CONFIG_DIR=$HOME/.claude` set, everything — including `.claude.json` —
moves inside it (confirmed by probe).

**Adopted:** the wrapper exports `CLAUDE_CONFIG_DIR=$HOME/.claude` itself, and the operator's login
recipe (`docs/PROVIDERS.md`) sets the same variable explicitly when provisioning the credential — not
relying on any default the wrapped binary might otherwise choose. `$HOME/.claude` joins `LL_RW` the same
way `$HOME/.codex` already does (`docs/CONFINEMENT.md`), generalised via the new `state_dir` registry
field (§E below) rather than a second hard-coded branch.

### D. The prompt travels on stdin, never argv — no sentinel token needed

Same conclusion as ADR-0009 §D (`/proc/<pid>/cmdline` exposure, an inherited stdin that could deadlock a
launch), reached independently for this binary: the adapter delivers the prompt on the wrapped binary's
stdin, byte-exact, via a process substitution. Unlike `codex`, which needs a bare `-` positional token
telling it to read stdin after its own `--`, `claude -p` with **no** positional prompt argument already
reads stdin on its own (`standup/_facts_claude-code-adapter.md` §B, confirmed by probe) — one fewer
token in the fixed flag set, not a different delivery mechanism.

### E. `LL_RW` generalises to a registry-declared `state_dir`, not a second hard-coded branch

**Rejected (v1 premise): add a second `.claude`-literal branch beside `lib/aibobnet.sh:1888`'s existing
`.codex`-literal one.** That would make every future adapter its own `run_confined` edit, growing an
if/else ladder indefinitely for a fact (which directory a provider needs writable) that is already
declared, operator-owned data for every other provider capability.

**Adopted:** `providers.<name>.state_dir` — a new, optional, additive registry field (schema 4 unchanged),
one relative path component (`^\.[A-Za-z0-9_-]+$`). `run_confined` derives `$HOME/<state_dir>` for the
**resolved** provider from this field instead of a literal; absent means nothing is appended (e.g.
`stub`); a value that fails the format regex is a registry data error, refused at resolve time with the
same exit **3** `_aib_resolve_provider_caps` already uses for "provider declares no valid capability" —
before any launch, not inside `run_confined`. `codex` gets `state_dir: ".codex"`, made explicit rather
than left as an unstated literal; its own `LL_RW` composition must stay byte-identical (a regression
guard the RED spec pins directly). This is registry-owned, operator-trusted data exactly like the other
four provider capabilities (`cap_sandbox`/`cap_tier`/`cap_effort`/`cap_timeout`) already are — it stays
inside D-B2 (`docs/SPEC-wire-format.md`).

**Not yet built:** the enact record `run_confined` reads (`bin/launch-agent:316`) has no provider name
or `state_dir` field today — only `adapter, root, cwd, sandbox, effort, model, timeout`. This decision
requires threading a new field onto that record at the same point `adapter` is already resolved, which
this slice documents as the target (`docs/CONFINEMENT.md`) and pins as RED (`tests/
adapter_claude_code_spec.sh`), but does not implement — consistent with this slice's docs-and-spec-only
scope.

### F. A missing or symlinked state dir must refuse, for both providers

**Finding (advisor F7):** `src/landlock-exec.c:84` opens every `LL_RW` path with `O_PATH`, following
symlinks; a missing path fails the helper's own add-rule step (`:188`) *before* the adapter's own
credential pre-flight ever runs. A symlinked state dir therefore grants Landlock rights on whatever it
points at, and an unprovisioned one reports as a bare confinement failure, never the adapter's own 78.

**Adopted:** before composing `LL_RW`, `run_confined` requires `$HOME/<state_dir>` to be a directory and
not a symlink (`-d && ! -L`); on failure it refuses the same way the existing D-A pre-flight already
does for "confinement is not available right now" (`exit_class=io-refused`, `stage=confine`,
`reason=confinement_unavailable`). This mapping is this ADR's own choice, reusing existing vocabulary —
the v2 design says only "refuse," not a specific wire shape — and applies equally to `.codex` today,
fixed once, generically, in the same amendment that adds the field, since `codex` never had this guard
either.

### G. Settings file dropped entirely; `--setting-sources ""` kept, with a stated CLAUDE.md carve-out

**Rejected (v1 premise, advisor F3): an optional operator `--settings <file>` flag, parallel to
`codex`'s root-owned `config.toml`.** Probed: a `--settings` file whose JSON carries hooks executes
them, and a missing path is itself a failure mode (`Error: Settings file not found`, exit 1) — a
code-execution input this slice's scope does not need, since every knob actually used is a flag or an
environment variable. The `codex` `config.toml` in-place-replaceability finding this would have
paralleled is already recorded (`docs/PROVIDERS.md:120-127`) and is not re-filed here.

**Rejected (advisor F2, considered explicitly): `--setting-sources project` instead of `""`.** Project
settings also carry command-executing keys outside hooks (`apiKeyHelper`, `statusLine`, …) that a
`disableAllHooks` override does not cover, and those were not probed individually — too large a surface
to accept on an unverified assumption.

**Adopted:** `--setting-sources ""` (suppresses CLAUDE.md, skills, agents, hooks, and MCP servers at
both user and project level — probed exhaustively per channel) plus `--strict-mcp-config`. Because that
also removes the project's own CLAUDE.md as a side effect rather than a decision, this ADR states the
carve-out explicitly: `--add-dir "$PWD"` plus `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1` restores
**only** the workspace CLAUDE.md (probed to admit nothing else from that level), for parity with
`codex`'s own unconditional `AGENTS.md` read. CLAUDE.md is instructions, at the prompt's own trust
level; hooks are code, which is exactly the class of thing dropping `--settings` and keeping
`--setting-sources ""` both exist to keep out.

### H. Auto-memory disabled; `bypassPermissions` kept over `dontAsk`

**Finding (advisor F1):** auto-memory survives `--setting-sources ""` — `$CLAUDE_CONFIG_DIR/projects/
<slug>/memory/MEMORY.md` enters the system prompt regardless, and because `$HOME/.claude` is one
directory shared by every project on the one shared broker account, any attempt's memory becomes the
next attempt's (any project's) steering input. **Adopted:** `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1`.

**Rejected (advisor Q3/F6): `--permission-mode dontAsk` plus a maintained tool allow-list, instead of
`bypassPermissions`.** Probed with a scripted `tool_use` against the local fake API: `dontAsk` denies a
forced tool call outside the working directory exactly like the default mode does — it adds nothing
Landlock does not already enforce, at the cost of an allow-list that drifts per release. **Adopted:**
`bypassPermissions`, with the single-token `--disallowedTools=Edit,Write,NotebookEdit` under read-only
(the flag is variadic and would otherwise swallow following non-flag tokens) — verified that deny wins
over bypass (a forced `Write` call fails `No such tool available` once the tool is removed).

## Alternatives Considered

### Capping `max` at `xhigh`-equivalent

Considered, rejected (advisor F4/Q5). `claude` silently lowers `max` itself for models that lack it; the
registry's own `cap_effort` ceiling already bounds cost, and there is no cost/latency reason found to
cap below what the operator already caps.

### A denylist of dangerous tokens in the prompt

Not reconsidered separately from ADR-0009's own rejection of this for `codex` — the same positive-
validation-before-`--`, prompt-never-inspected reasoning applies unchanged to a second adapter under the
identical ABI.

## Consequences

- `docs/CONTRACT-codex-run.md` gains §4.1.1: claude-code as the ABI's second adapter, unchanged contract.
- `docs/CONFINEMENT.md` gains the `state_dir` registry field, the generalised `LL_RW` table, the F7
  missing/symlinked-state-dir guard (applying to `codex` too), and a probed (not strace-measured)
  footprint note for `claude-code`.
- `docs/PROVIDERS.md` gains a full `claude-code` section: placement, credential recipe, effort table,
  the "no wrapped sandbox flag" note, fixed flags/env in pinned order, the CLAUDE.md-yes/hooks-no
  decision, the root self-refusal note (unused but recorded), the exit-code table, and a registry entry
  example.
- `registry.json` gains the `state_dir` field on `codex` (`.codex`, byte-identical) and a new
  `claude-code` entry (`.claude`); `stub` declares none. Additive, schema 4, `SCHEMA_VERSION` unchanged.
- `tests/adapter_claude_code_spec.sh` is new and RED until `adapters/claude-code` exists, `run_confined`'s
  `LL_RW` derivation reads the new field, and the resolver's format check is added.
  `tests/adapter_codex_spec.sh` is untouched and must stay green on this same unbuilt tree.
- `adapters/claude-code` does not exist yet — this slice is docs and a RED spec only, per its scope.
- LL_RO narrowing, per-project `$CLAUDE_CONFIG_DIR`, and the role-uid switch remain out of scope, exactly
  as they do for `codex`.

---
White-label: example project id `acme`; no real names, infrastructure, or hosts.
