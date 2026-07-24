# ai-bobnet

Next-generation Bobiverse engine — a shared, versioned setup for **Team-Lead-orchestrated AI dev teams**,
rebuilt on a clean, deterministic core.

> **Status: work in progress — clean-core rebuild.** The core (identity, deterministic messaging/delivery,
> memory-with-trust) is built from the ground up; proven components are ported in incrementally.
>
> **Built and tested:** P0 identity/registry, schema-3/4 execution binding with per-field provenance,
> P1 delivery, P2 wakeup/local adapter, P3 scoped memory, the serialized commit path for the current
> delivery and memory journals, the watchdogged Codex managed-launch path, and the RM-1 **managed policy
> gate** (schema-4 adapter map + declared capabilities, the pure Policy Decision Point with
> `min(clearance, provider capabilities)` capping, absolute adapter resolution, and the `env -i`
> allow-list child environment). **Specified, not yet implemented:** the full serialized event spine,
> provider-wide reference monitor (non-bypassability), Gate/Grant/Effect state machines, durable Attempt
> records and the provider-change audit event, profile provisioning, full runtime lifecycle, external
> adapters, and dashboard projection. `docs/DOMAIN.md` is the normative target contract; it is not a claim
> that every domain surface already exists in code.
>
> **The managed launch is a POLICY GATE for cooperating agents (RM-1), not containment.** It caps effective
> authority, pins the adapter to an absolute registry path, and builds the child environment from an
> allow-list — but it does not mediate provider syscalls, shell children, network/VCS effects, or T4
> actions, and a hostile local process can still run a provider directly. Non-bypassability, durable Attempt
> records, and the provider-change audit event are specified but not yet built.

The [execution-binding contract](docs/CONTRACT-execution-binding.md) defines the schema-2/3/4
compatibility boundary, the exact provenance interface, the managed-launch migration, and the RM-1
policy-gate mechanics (§7). The [managed-launch ADR](docs/decisions/0002-managed-launch-boundary.md) records
the RM-0 boundary decision; the [managed-policy-gate ADR](docs/decisions/0003-managed-policy-gate.md) records
the RM-1 PDP/PEP split, effective-authority capping, absolute adapter map, and allow-list environment.

## Runtime requirements

The core commands require Bash, `awk`, standard Unix tools, and `flock` from util-linux. `flock`
serializes commits to the current line-oriented delivery and memory journals on a single host; a journal
mutation on a host without it refuses loudly with exit 6 rather than committing unserialized. The managed
launcher additionally uses `timeout` and `env` from coreutils — it runs the adapter under a `timeout`
watchdog and constructs the child environment with `env -i`. The optional localhost HTTP adapter uses the
Python 3 standard library only; it has no pip dependency. RM-0 and RM-1 add no daemon, network call, or
development server of their own.

**Deployment precondition (RM-1): provider authentication must be file-based.** The managed launcher builds
the child environment from an allow-list — `HOME`, `PATH`, and the explicit managed `AIBOBNET_*` exports —
so an API key supplied only as an environment variable, for example `OPENAI_API_KEY`, does not survive
`env -i` and the provider will fail authentication. This is a required deployment property, not a defect;
see [`docs/CONTRACT-execution-binding.md`](docs/CONTRACT-execution-binding.md) §7.5.

## Design principles
- **Deterministic foundation.** A freshly booted agent — whatever its runtime — can heartbeat, read its inbox,
  message another agent, and appear on the dashboard **without guesswork**.
- **Role/task-based agents.** Agents are named by task (`infra`, `core`, `review`, `tests`, …). A folder lead
  carries a display name and avatar; the rest are task-named or self-named. Spawn by task.
- **Model-agnostic, additive.** Schema 3 and 4 resolve provider/model/effort independently from agent,
  direct team, then project. The managed interface is provider-neutral; only the Codex adapter is
  implemented, and later adapters extend rather than replace it.
- **White-label.** Ships publicly; example project id `acme`; no real names, infrastructure, or hosts.

Predecessor engine: `claude-bobnet` (remains canonical until this reaches parity).

Licensed under the [Apache License 2.0](LICENSE).
