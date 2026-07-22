# ai-bobnet

Next-generation Bobiverse engine — a shared, versioned setup for **Team-Lead-orchestrated AI dev teams**,
rebuilt on a clean, deterministic core.

> **Status: work in progress — clean-core rebuild.** The core (identity, deterministic messaging/delivery,
> memory-with-trust) is built from the ground up; proven components are ported in incrementally.
>
> **Built and tested:** P0 identity/registry, schema-3 execution binding with per-field provenance,
> P1 delivery, P2 wakeup/local adapter, P3 scoped memory, the serialized commit path for the current
> delivery and memory journals, and the watchdogged Codex managed-launch path. **Specified, not yet
> implemented:** the full serialized event spine,
> provider-wide reference monitor, Gate/Grant/Effect state machines, profile provisioning, full
> runtime lifecycle, external adapters, and dashboard projection. `docs/DOMAIN.md` is the normative
> target contract; it is not a claim that every domain surface already exists in code.
>
> **Managed launch is NO ENFORCEMENT.** It deterministically resolves `provider`, `model`, and `effort`,
> but does not mediate provider syscalls, shell children, network/VCS effects, or T4 actions. Raw provider
> execution and `PATH`-selected executables remain possible. Durable Attempt records and provider-change
> audit are specified but not yet built.

The [execution-binding contract](docs/CONTRACT-execution-binding.md) defines the schema-2/schema-3
compatibility boundary, exact provenance interface, and managed-launch migration. The corresponding
[managed-launch ADR](docs/decisions/0002-managed-launch-boundary.md) records the boundary decision.

## Runtime requirements

The core commands require Bash, `awk`, standard Unix tools, and `flock` from util-linux. `flock`
serializes commits to the current line-oriented delivery and memory journals on a single host.
The Codex managed-launch adapter additionally uses `timeout` from coreutils. The optional localhost HTTP
adapter uses the Python 3 standard library only; it has no pip dependency. RM-0 adds no dependency,
daemon, network call, or development server of its own.

## Design principles
- **Deterministic foundation.** A freshly booted agent — whatever its runtime — can heartbeat, read its inbox,
  message another agent, and appear on the dashboard **without guesswork**.
- **Role/task-based agents.** Agents are named by task (`infra`, `core`, `review`, `tests`, …). A folder lead
  carries a display name and avatar; the rest are task-named or self-named. Spawn by task.
- **Model-agnostic, additive.** Schema 3 resolves provider/model/effort independently from agent, direct
  team, then project. The managed interface is provider-neutral; RM-0 implements only the Codex adapter,
  and later adapters extend rather than replace it.
- **White-label.** Ships publicly; example project id `acme`; no real names, infrastructure, or hosts.

Predecessor engine: `claude-bobnet` (remains canonical until this reaches parity).

Licensed under the [Apache License 2.0](LICENSE).
