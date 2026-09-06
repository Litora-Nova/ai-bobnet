# ADR-005: Broker Event Stream Lives Under `AIB_EVENT_ROOT`, Not `standup_dir`

## Status

Accepted

## Date

2026-09-05

## Context

ADR-0004 placed the framed event stream at `<standup_dir>/events/main.events`. That convention was
correct for RM-2, where the only writer was `bin/launch-agent`, running in-process for the same
account whose home the `standup_dir` sits inside — there was no other trust domain to separate it
from.

RM-3 slice 3 confines the provider child under `docs/CONFINEMENT.md` (contract §2.1: no write access
to the event stream, the high-water anchor, the registry, the adapter map, or the installed engine).
The registry's `standup_dir` sits **inside** the project `home` (`registry.json`,
`docs/CONTRACT-execution-binding.md`), and `home` is exactly the directory the confined child needs
write access to for its own legitimate output — the workspace `cwd` is derived from it. An
architecture consult raised this directly: keeping the stream under `standup_dir` while granting
`LL_RW` over `home` hands the confined child write access to the stream, because Landlock grants by
hierarchy and "grant `home`, deny `events/` two levels down" is not expressible as a positive list.
There is no DAC backstop behind that mistake either — the child runs as the broker account, which
owns the stream, so ownership (§5's argument for why agents cannot truncate it today) does not help
once the agent-directed child runs *as* the owner.

Agents also write legitimately under `standup_dir` today — heartbeats (`aib_log_resolved`), inbox
journals, memory journals — so the fix cannot be "nothing under `standup_dir` is ever writable by a
confined child"; only the events subtree specifically must never be reachable that way.

## Decision

The **broker's own** event stream moves to broker-owned state, outside every project `home`:

- `AIB_EVENT_ROOT` — a unit-environment variable, default `/var/lib/aib/events`, never
  request-supplied and never registry-supplied (it names where the broker keeps its own state, not
  a per-project setting).
- File `<AIB_EVENT_ROOT>/<project_uid>/main.events`, sidecar lock `main.events.lock` — same framing,
  same lock discipline, same identity/causation rules ADR-0004 established; only the containing
  directory changes.
- `<standup_dir>/events` remains, as a **reader-facing symlink** into the broker-owned location,
  maintained by provisioning (already present on the VM per the spike's build order). Readers
  (`bin/attempts`, any operator tooling) keep working against the path they already know; only the
  broker's own write path changes.
- The **in-process wrapper** (`bin/launch-agent`, the single-trust-domain path §7 keeps alive) is
  unaffected: it has no confined child to protect the stream from, and keeps writing
  `<standup_dir>/events` exactly as ADR-0004 specified. This ADR amends ADR-0004's location clause
  for the **broker's** enactment path only, not the wrapper's.

Consequence for `docs/SPEC-wire-format.md`'s positive-list composition: `LL_RW` may safely contain
`home` (and therefore `standup_dir`, and therefore the agent-legitimate subtrees inside it), because
nothing the confinement minimum names — stream, anchor, registry, adapter map, installed engine —
lives under `home` any more. Stream and anchor live under `AIB_EVENT_ROOT`; registry, adapter map and
engine live under `/opt/aib`. `SPEC-wire-format.md`'s positive list is composed from the registry
snapshot alone, and this ADR is why that composition is sound.

## Alternatives Considered

### Enumerate the writable subtrees of `standup_dir`, deny `events/` specifically

Keep the stream where ADR-0004 put it, and instead grant `LL_RW` over `inbox/`, `memory/`, and the
agent's own heartbeat log individually, never over `standup_dir` as a whole. Rejected for this slice:
it requires the positive list to track every legitimate agent-writable subtree as that set grows, and
a subtree added later without a matching Landlock-list change is a silent regression — the failure
mode is invisible until someone checks. Moving the stream is a one-time, structural fix; enumerating
subtrees is an ongoing maintenance obligation with no forcing function.

### Leave the stream where it is and accept the exposure

Rejected outright: §2.1's minimum names "no write access to the event stream" as the first item, not
an aspirational one, and the spike's 9/9 TCB-closed result was measured against the stream living
outside the workspace — it does not transfer to a layout where the stream sits inside the granted
`LL_RW`.

## Consequences

- The install/provisioning step gains one more requirement: create `<AIB_EVENT_ROOT>/<project_uid>/`
  before the broker's first write, and maintain the `<standup_dir>/events` symlink per project (the
  VM already has it, per the spike's build order — step 0 there is the TCB ownership fix this ADR
  does not change).
- `bin/attempts` and any other reader continue to resolve `<standup_dir>/events/main.events` and need
  no change: the symlink makes the relocation invisible to them.
- The wrapper (`bin/launch-agent`) and the broker (`bin/aib-broker-handler`) now write to two
  different **paths** for what is conceptually the same kind of stream, in two different **trust
  domains** — the wrapper's single-trust deployment has no confined child to protect the stream from,
  so it never needed this move. A reader that follows the symlink sees one merged view either way;
  nothing about the fold in `bin/attempts` changes.
- `AIB_EVENT_ROOT` becomes broker-owned configuration surface: it must be settable only from the unit
  environment, the same restriction `docs/CONFINEMENT.md` already states for `AIB_CONFINE_BIN`, for
  the same reason — a value an agent-directed request could influence would defeat the point of
  moving it.
