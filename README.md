# ai-bobnet

Next-generation Bobiverse engine — a shared, versioned setup for **Team-Lead-orchestrated AI dev teams**,
rebuilt on a clean, deterministic core.

> **Status: work in progress — clean-core rebuild.** The core (identity, deterministic messaging/delivery,
> memory-with-trust) is built from the ground up; proven components are ported in incrementally.
>
> **Built and tested:** P0 identity/registry, P1 delivery, P2 wakeup/local adapter, P3 scoped memory,
> and the watchdogged `codex-run` wrapper. **Contracted, implementation pending:** the serialized
> commit path for the current delivery and memory journals. **Specified, not yet
> implemented:** the full serialized event spine,
> provider-wide reference monitor, Gate/Grant/Effect state machines, profile provisioning, full
> runtime lifecycle, external adapters, and dashboard projection. `docs/DOMAIN.md` is the normative
> target contract; it is not a claim that every domain surface already exists in code.

## Runtime requirements

The core commands require Bash, `awk`, standard Unix tools, and `flock` from util-linux. `flock`
serializes commits to the current line-oriented delivery and memory journals on a single host.
`bin/codex-run` additionally uses `timeout` from coreutils. The optional localhost HTTP adapter uses
the Python 3 standard library only; it has no pip dependency.

## Design principles
- **Deterministic foundation.** A freshly booted agent — whatever its runtime — can heartbeat, read its inbox,
  message another agent, and appear on the dashboard **without guesswork**.
- **Role/task-based agents.** Agents are named by task (`infra`, `core`, `review`, `tests`, …). A folder lead
  carries a display name and avatar; the rest are task-named or self-named. Spawn by task.
- **Model-agnostic, additive.** Native harness plus additive model layers (a router for extra paid models, and an
  MCP tool bridge to other provider CLIs) — added **beside, never replacing**, the native runtime.
- **White-label.** Ships publicly; example project id `acme`; no real names, infrastructure, or hosts.

Predecessor engine: `claude-bobnet` (remains canonical until this reaches parity).
