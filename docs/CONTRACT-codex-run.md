# ai-bobnet — Codex Managed-Launch Adapter Contract

`bin/codex-run` remains the compatibility name for a watchdogged, heartbeat-owning Codex call. It is a
thin `exec` delegator to the provider-neutral `bin/launch-agent`, which resolves one schema-3
execution-binding snapshot. `codex-run` does not reopen the registry, choose a model or effort, or apply a
second default.

> **Security status: NO ENFORCEMENT.** This adapter is not a reference monitor. It does not evaluate
> `ALLOW | REQUIRE GATE | DENY`, mediate Codex syscalls or children, constrain network/VCS effects, make T4
> decisions, protect executable selection through `PATH`, or prevent a caller from invoking `codex`
> directly. It does not yet implement the target environment allow-list in `docs/DOMAIN.md` §7.

## 1. Invocation

```text
bin/codex-run --as <agent_uid> [options] (--prompt <text> | --prompt-file <file> | -)
```

- `--as <agent_uid>` is required. It selects the registered agent whose schema-3 binding is launched and
  whose heartbeat is written. It is not the actor-label meaning of `bin/run-agent --as`.
- Exactly one prompt source is required: `--prompt`, `--prompt-file`, or standard input selected by `-`.

`bin/launch-agent` accepts the same identity, runtime-option, and prompt-source surface and dispatches by
the resolved provider. RM-0 implements only `provider=codex`; unknown or unimplemented providers fail
before a process starts.

## 2. Runtime options and binding authority

| Option | Default | Contract |
|---|---|---|
| `--sandbox <mode>` | `read-only` | `read-only \| workspace-write`; `danger-full-access` is refused |
| `--cwd <dir>` | `$PWD` | existing directory from which Codex runs |
| `--timeout <seconds>` | `1200` | positive-integer watchdog deadline |
| `--label <text>` | `codex-run` | operational heartbeat label |

These controls describe one invocation; they do not select the execution binding. `provider`, `model`,
and `effort` come only from the schema-3 registry resolution defined by
`docs/CONTRACT-execution-binding.md`.

The former `--model` and `--effort` flags are accepted only far enough to return an explicit migration
error with exit 64. They never override the registry and never start a provider process. There is no
tool-local model or effort default. Provider has no CLI or environment option.

These refusals — the rejected `--model`/`--effort` flags and the `danger-full-access` sandbox — are
input hygiene at this one managed entry point, not a containment guarantee: a caller can still bypass
`codex-run` and execute a provider directly (see NO ENFORCEMENT).

## 3. Resolution and delegation

For one call:

1. `codex-run` delegates its arguments to `launch-agent`; it does not read the registry.
2. The managed resolver requires schema 3 and obtains identity, clearance, optional direct team, resolved
   provider/model/effort, and per-field `level:uid` provenance from one validated registry snapshot.
3. `launch-agent` rejects a missing binding, invalid membership, unknown/unimplemented provider, provider
   mismatch, or invalid Codex effort before dispatch.
4. The Codex adapter consumes that process-local bundle. It must not reopen the registry or replace any
   resolved field with a local default.

Schema 2 remains valid for legacy context and arbitrary `run-agent` commands but cannot reach this managed
adapter. Inherited `AIBOBNET_PROVIDER`, `AIBOBNET_MODEL`, `AIBOBNET_EFFORT`, provenance, and schema-version
variables cannot override the resolved bundle. Managed launch replaces the child `AIBOBNET_*` context with
the resolved schema-3 values, including direct-team membership, and removes `CODEX_RUN_BIN` and the
registry locator before execution. The pre-existing `AIBOBNET_REGISTRY` advanced/test locator may select
the file used for the one initial snapshot; it is not a binding-field override or an enforcement boundary.

## 4. Observable and bounded behavior

After all pre-launch validation succeeds:

1. Emit a `busy` heartbeat for the selected agent containing the resolved model, selected sandbox,
   resolved effort, and label. The managed heartbeat primitive uses the already-resolved `agent_uid` and
   `standup_dir`; it does not reopen the registry.
2. Run from `--cwd` under the watchdog:

   ```text
   timeout <seconds> codex exec -m <resolved-model> -s <sandbox> \
     -c model_reasoning_effort="<resolved-effort>" \
     -c approval_policy="never" <prompt>
   ```

3. Report one terminal outcome:
   - watchdog timeout (exit 124): heartbeat `blocked`, relay captured output to stderr, exit 124;
   - Codex error: heartbeat `blocked`, relay captured output to stderr, propagate the provider exit code;
   - success: heartbeat `done`, relay Codex output to stdout.

The heartbeat proves that the wrapper observed a start and terminal result. Binding text in that mutable
file is operational visibility only. RM-0 emits no durable Attempt record, provider-change audit, or Event
Spine event, so it cannot prove later what ran.

Managed heartbeat writes retain the standalone logger's fixed status validation and its LF/CR/pipe
sanitization. Standalone `scripts/log.sh` remains registry-authenticated; only the managed path uses the
pre-resolved primitive to preserve the one-snapshot launch invariant. That primitive consumes only the
internal process-local bundle; no public option or ambient environment variable may inject its identity or
path.

## 5. Executable and test seam

`CODEX_RUN_BIN` has no production or test-seam role and is removed before provider execution. The adapter
executes the installed executable named exactly `codex` through `PATH`. Deterministic specs prepend a
controlled directory containing a stub with that exact executable name to prove argument fidelity,
timeout, error, success, heartbeat, cwd, and pre-launch refusal without network access.

`PATH` selection is deliberately not a security claim. An operator-owned absolute adapter map belongs to
the future enforcement phase. The wider inherited process environment is likewise not yet the target §7
allow-list. These limits are reasons to label RM-0 **NO ENFORCEMENT**.

## 6. Migration from the legacy wrapper

Before upgrading a caller:

1. migrate its registry to schema 3;
2. place `provider=codex` and the intended model and effort at project, direct-team, or agent level;
3. inspect the resolved value and source for each field;
4. remove caller-supplied `--model` and `--effort` arguments;
5. invoke `codex-run` or `launch-agent` with only runtime options and one prompt source.

An upgraded wrapper fails loudly on schema 2 or former model/effort flags; it does not preserve behavior by
guessing the old defaults. Rollback requires restoring a schema-2 registry and the caller-owned flags or
defaults expected by the old wrapper before running the old code.

## 7. Acceptance — example id `acme`

- Missing/unknown `--as`, schema 2, incomplete binding, provider mismatch, invalid membership, unknown
  provider, or invalid arguments produce loud non-zero failure before the stub runs.
- `--model` and `--effort` produce an explicit migration failure before the stub runs.
- The captured argv contains the registry-resolved `-m` value and `model_reasoning_effort`, plus the
  requested sandbox and fixed `approval_policy=never`; no local model/effort default is used.
- Mixed-level binding provenance matches `provider_source=project:acme`,
  `model_source=team:acme-engine`, and `effort_source=agent:acme-core` for the canonical example.
- A registry replacement during launch cannot mix identity or binding generations, and the adapter cannot
  cause a second registry read.
- Busy and terminal heartbeats use the same resolved identity/path bundle without a registry reread and
  retain the standalone logger's status and line-sanitization guarantees.
- A label containing LF, CR, and `|` yields exactly two physical heartbeat records (`busy` plus terminal),
  with the hostile bytes collapsed or encoded rather than parsed as extra records or fields.
- `CODEX_RUN_BIN` and inherited binding variables cannot select the managed executable or binding.
- Success, timeout, provider error, cwd, prompt-source exclusivity, stdout/stderr relay, and heartbeat
  outcomes retain their previous observable behavior.

## 8. Relationship to the fleet

`codex-run` is the compatibility surface for the Codex **Runner** pattern. `launch-agent` is the common
provider dispatch seam. A Dispatcher may compose multiple calls and independently verify their results;
that composition does not turn either command into a policy gate. Codex output remains subject to the same
external review and merge ownership as any other builder output.

---
White-label: example project id `acme`; no real names, infrastructure, or hosts.
