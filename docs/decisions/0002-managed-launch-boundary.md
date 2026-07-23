# ADR-002: Resolve Execution Binding Before Managed Provider Launch

## Status

Accepted

## Date

2026-07-22

## Context

The agent registry is already authoritative for durable identity and clearance, but provider launch is
not. The original `codex-run` accepts `--model` and `--effort` and supplies tool-local defaults. The same
agent can therefore run with a different binding depending on the caller, while the registry cannot
answer which provider, model, or effort should be used.

The target domain contract requires field-wise `agent -> team -> project` resolution, per-Attempt capture,
and an enforcement layer below the agent loop. The event spine, durable Attempts, policy decision function,
effect broker, and provider-wide reference monitor do not exist yet. Conflating deterministic launch with
those future security boundaries would turn an observability improvement into a false enforcement claim.

Execution-binding fields are load-bearing. Adding them as ignored extras to schema 2 would let an old
reader accept a registry while silently discarding the values that a managed launch treats as authority.
A versioned compatibility boundary is required.

## Decision

Introduce registry schema 3 and a provider-neutral managed launch seam.

- Schema 3 permits `provider`, `model`, and `effort` on project, flat direct-team, and agent objects.
  Each scalar resolves independently from the first level where it is present: agent, direct team, then
  project. Mixed-level bindings are valid and carry per-field source provenance.
- An optional `agent.team_uid` names one flat direct team in the same project. RM-0 has no nesting,
  parent-team lookup, or rights inheritance.
- Only absence falls through. A present malformed or unusable value fails at its level. A complete binding
  must resolve and validate against an implemented adapter before a provider starts.
- A single managed resolver reads and validates one registry snapshot and returns identity, clearance,
  membership, binding, and provenance as one process-local bundle. Adapters consume that bundle and never
  reopen the registry or apply their own precedence/defaults.
- Managed heartbeats use the bundle's pre-resolved agent identity and standup directory through a shared
  writer primitive; they do not call the registry-authenticated `scripts/log.sh` entry point and cause a
  second read. The primitive retains closed status validation and LF/CR/pipe sanitization. Standalone
  `scripts/log.sh` remains registry-authenticated. The pre-resolved primitive is internal and process-local;
  it has no public flag or ambient-environment input.
- `bin/launch-agent` is the supported provider-neutral entry. RM-0 implements one real adapter, `codex`.
  Standalone `bin/codex-run` is a thin `exec` delegator into the same entry and performs no second
  resolution.
- Provider is never a CLI or environment choice. Former `--model` and `--effort` options are refused with
  a migration error. Neither the launcher nor the adapter owns model/effort defaults.
- `CODEX_RUN_BIN` has no managed production or test-seam role and is removed before the provider child.
  Tests prepend a controlled `PATH` directory containing an executable named exactly `codex`.
  Production still locates the installed `codex` executable through `PATH`.
- Schema-3 context output and launcher environment expose the resolved values and `level:uid` provenance.
  Inherited binding variables are scrubbed before resolution.
- New readers continue to support schema 2 for legacy identity/context and command execution, but managed
  provider launch requires schema 3. Old readers continue to reject schema 3.

This managed-launch seam is explicitly **NO ENFORCEMENT**. It does not apply the domain policy decision function,
mediate syscalls or children, constrain network/VCS effects, protect `PATH`, implement the target §7
environment allow-list, prevent direct raw provider execution, or make a T4 decision. It creates no Gate,
Grant, Effect, or durable Attempt record. Heartbeat binding text is operational visibility only, not
durable audit.

## Alternatives Considered

### Keep model and effort as launcher flags with tool-local defaults

Rejected. Callers remain competing sources of truth, and the same registered agent can silently run with
different bindings.

### Add binding fields to schema 2 as forward-compatible extras

Rejected. Existing schema-2 readers deliberately ignore unknown fields. A load-bearing field cannot be
both authoritative to one reader and invisible to another reader that accepts the same schema.

### Resolve the whole binding from one level

Rejected. The domain contract defines per-field precedence. Requiring every level to repeat all three
values makes a narrow agent effort override duplicate provider and model, and lets those copies drift.

### Let every provider adapter read the registry

Rejected. Separate reads can mix registry generations and duplicate precedence and validation logic.
Adapters receive one complete process-local bundle from the managed resolver instead.

### Preserve public model/effort overrides temporarily

Rejected for RM-0. An ungated override would remain a second authority. Content-addressed approval and
durable Attempt audit do not exist yet, so safe overrides are deferred rather than simulated.

### Treat the managed launcher as a reference monitor

Rejected. Raw provider commands, `PATH` selection, provider syscalls, arbitrary shell children, network,
and VCS effects remain outside the seam. Naming it a reference monitor would contradict the hard/soft
boundary in `docs/DOMAIN.md` §7.

### Pin provider executables through an operator-owned absolute adapter map

Deferred to the enforcement phase. It is required before executable selection can become a security
property, but RM-0 intentionally adds no broker, daemon, or operator policy store.

### Add nested teams or parent binding inheritance

Deferred. RM-0 needs one deterministic direct-team level. Nesting would require a separate precedence,
cycle, governance, and migration decision and must not imply rights inheritance.

### Emit a durable Attempt record now

Deferred. The current line-oriented heartbeat and legacy journals are not the event spine and cannot
provide the immutable Attempt history required by the target contract.

## Consequences

- A managed launch has one deterministic registry source for provider, model, and effort, with observable
  provenance for each field.
- Managed start and terminal heartbeats cannot drift to another registry generation, while preserving the
  existing single-line sanitization contract.
- Schema 3 is a deliberate compatibility boundary. Consumers must migrate registry data and former
  model/effort arguments together; rollback must restore schema 2 before an old reader runs.
- Legacy schema-2 identity/context and arbitrary `run-agent` commands remain available, but upgraded
  managed launch refuses schema 2 rather than guessing defaults.
- `codex-run` remains recognizable to existing callers but its model/effort flags become explicit errors.
- Provider changes still do not change registry clearance. Provider-change audit, effective-authority
  capping, and durable binding history remain unimplemented with the event spine/reference monitor.
- `launch-agent` resolves the binding before scrubbing the environment, so it honors an ambient
  `AIBOBNET_REGISTRY` locating the registry to read; `run-agent` scrubs first. This is intentional — the
  managed launch is the trusted entry point and the child it `exec`s is fully scrubbed and re-exported
  from the resolved bundle — and consistent with NO ENFORCEMENT, but the divergence is a known limitation
  a future reference monitor must close.
- The launcher adds no runtime dependency, network call, daemon, or server. Existing Bash/Unix/coreutils
  requirements remain.
- The managed path is easier to wrap with a future reference monitor, but it is bypassable today. Public
  documentation must retain **NO ENFORCEMENT** until raw capabilities are withheld and effects are mediated.

---
White-label: example project id `acme`; no real names, infrastructure, or hosts.
