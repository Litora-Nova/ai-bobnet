# ADR-003: Managed Policy Gate — Split Launch Authority into a Pure PDP and an Enacting PEP

## Status

Accepted

## Date

2026-07-23

## Context

ADR-002 built a managed launch **seam** — one resolver, one snapshot, deterministic `provider`/`model`/
`effort` binding — but that seam decided nothing and enforced nothing. It resolved a binding and dispatched
an adapter. Three promises the domain contract already made were left unbuilt at the seam:

- `docs/DOMAIN.md` §2.1 states an agent's **effective** authority is `min(clearance, what its provider can
  actually enforce)`. RM-0 resolved clearance but never capped it against the provider.
- The adapter executable was still located with `command -v codex` from the launch **cwd**. cwd is
  attacker-influenceable input, so which binary ran depended on where the launch happened.
- The child environment was **scrubbed by denylist** (a `compgen` sweep of known-bad names). A denylist is
  never complete: the provider silently inherited `HOME`, `PATH`, locale, and any provider-auth variable —
  none of them named anywhere, none of them intended.

RM-0 also deferred three findings: raw-NUL registry rejection, load-time validation of every team key, and
exit-127 coverage for a missing adapter.

The larger design pressure is the later hard boundary (RM-3): non-bypassability through OS confinement.
If RM-1 grew authority logic tangled into the launch mechanics — reading cwd, PATH, and the environment
inline while deciding — then RM-3 would be a rewrite, because none of those ambient reads reproduce once
the decision runs behind a process boundary with a constructed environment. The decision had to be
structured so that RM-3 is an **additive infrastructure layer around the same decision function**, not a
second implementation of the same rules.

## Decision

Split the managed launch into a **Policy Decision Point (PDP)** and a **Policy Enforcement Point (PEP)**,
and make the adapter map and provider capabilities registry data under a new schema version.

RM-1 is a **policy gate for cooperating agents. It is NOT containment.** A hostile local process can still
run a provider binary directly and never touch this seam. Non-bypassability is RM-3's job and is out of
scope here. The words "enforcement boundary", "reference monitor", and "containment" remain reserved for
RM-3 and are not claimed for RM-1 anywhere in code or docs. "Policy Enforcement Point" is used only in its
XACML sense — the component that **executes the verdict** — never colloquialized into an enforcement or
containment guarantee.

### PDP — a pure decision function

`aib_authorize_launch <request-record> <snapshot-record>` (`lib/aibobnet.sh`) is the single authority for
a managed launch and a **pure function**: it reads nothing from disk, PATH, cwd, or the environment. Both
inputs arrive as newline-delimited `key=value` records:

- `request`: `agent_uid`, requested `sandbox`, `cwd`, `timeout`, `label`;
- `snapshot`: `clearance`, `provider`, `effort`, the absolute `adapter` path, and the declared
  `cap_sandbox` / `cap_tier` / `cap_effort` capabilities — all already resolved by
  `aib_resolve_managed_agent`, never re-read inside the PDP.

The verdict is published through `AIB_VERDICT_*` shell globals (house style): `DECISION` (`allow`/`deny`),
`CODE`, `REASONS`, the three effective values, `ADAPTER_PATH`, `ENV_ALLOW`, and a one-line JSON
`AIB_VERDICT_RECORD` (`event: launch_verdict`). Determinism over the two records is what lets RM-3 move
this identical function behind a process boundary — a broker daemon, its own uid, or a container entrypoint
— sourced today, `exec`'d tomorrow, same contract. The PDP MUST NOT call `aib_registry_file` or any
snapshot helper; those route through the `AIBOBNET_REGISTRY` environment and would break purity.

**Authority lives only in the PDP.** The sandbox ceiling, `min(clearance, cap_tier)`, and the effort cap
are computed there and nowhere else. The PEP's argument-parsing `aib_die` checks remain as input hygiene
(they validate *form*), but no authority decision is duplicated into `launch-agent` or `codex-run`.

### Effective authority = `min(clearance, provider capabilities)`

The PDP computes each effective value as a minimum over a total order (`_aib_rank`: `t1<t2<t3<t4`;
`read-only<workspace-write<danger-full-access`; `low<medium<high<max`). A request above a ceiling is
**clamped, not denied** — the launch proceeds at the lower, safer bound; a request never *grants* the
higher value. This delivers the DOMAIN §2.1 promise **at the seam**.

Honesty about scope: the capabilities are **declared** registry data ("what the provider can honor"), not
runtime-verified. RM-1 clamps the values it hands the provider and trusts the provider to honor them; it
does not itself confine the provider, and it does not verify the provider obeys. A bypassing process is
unaffected. That gap is exactly what RM-3 closes.

### Adapter map = absolute registry data (schema 4)

The provider adapter is resolved from `providers.<name>.adapter`, an **absolute** path validated absolute
by the PDP (a non-absolute adapter is a config deny, code 2). This replaces `command -v codex` from cwd:
adapter resolution no longer depends on attacker-influenceable input. Capabilities
(`cap_sandbox`, `cap_tier`, `cap_effort`) are likewise declared registry data, resolved by
`_aib_resolve_provider_caps`, never runtime-probed — runtime probing is another ambient dependency that
would not reproduce under RM-3 confinement.

Because the adapter map and capabilities are load-bearing fields, they require **`schema_version: 4`**.

- Schema 3 stays readable for identity and context.
- The schema-4 gate is **field-presence, not version-branching**: a managed launch requires the adapter
  field; schema 4 guarantees it; a schema-3 registry simply resolves an empty adapter, and the PDP denies
  it with the same fail-closed missing-adapter path (exit 127). "Requires the adapter" — not "requires
  version 4" — is the check.
- Old readers that know only 2/3 reject 4, preserving the compatibility-boundary property ADR-002
  established.

### PEP — enacts the verdict

`bin/launch-agent` builds the two records from the resolved bundle, calls the PDP, and on deny fails closed
with the PDP-chosen exit code **before any heartbeat or provider process starts**. On allow it enacts the
verdict: it runs at the effective (clamped) sandbox/effort and `exec`s the **absolute** `adapter_path` from
the verdict under a `timeout` watchdog. `bin/codex-run` remains a thin `exec` delegator into
`launch-agent`; it holds no second truth.

### Child environment built by allow-list (`env -i`)

The child environment is **constructed** from the verdict's allow-list via `env -i`, not scrubbed by
denylist. The provider inherits nothing but the named variables, plus the explicit managed `AIBOBNET_*`
exports. The allow set was derived empirically from an `env -i` smoke launch, not guessed: the Codex
adapter needs `HOME` (its config directory and file-based auth) and a `PATH` (its runtime and helpers); no
separate provider-auth environment variable is load-bearing, because the credential lives in the adapter's
own auth file rather than an inherited variable. An allow-list is complete by construction where a denylist
never is, and it matches RM-3's confined environment for free.

### Stable exit-code contract

`64` usage/refusal · `2` config/IO · `127` adapter-not-found · `124` watchdog timeout. The PDP orders its
deny checks by severity so the first deny fixes the code (`127 > 2 > 64`). The RM-3 broker will return the
same codes; no renumbering.

### Verdict is a record, shaped for reuse

The PDP emits `AIB_VERDICT_RECORD` as a one-line JSON object (`launch_verdict`), the same shape family as
the RM-0 `managed_launch_binding` observability event the PEP still writes to stderr. It is **not**
journalled in RM-1 — durable audit is RM-2 — but it is shaped so RM-2's Attempt audit reuses the schema.

### Deferred RM-0 findings folded in

- **Raw-NUL rejection within the one-open invariant.** The snapshot is read once with
  `IFS= read -r -d ''`; rc=0 means a NUL delimiter was found → loud refusal. Detection is by `read`'s
  return status alone (a bash variable cannot hold a NUL), so no second open is needed — the double-open
  that deadlocked the one-write FIFO seam as a hotfix does not return.
- **Load-time team-key validation.** Every team key in the registry is validated at load, not only the one
  an agent references.
- **Exit-127 coverage.** A resolvable-but-absent adapter fails closed at 127 before any heartbeat.

## Alternatives Considered

### Keep authority inline in the launcher, add the cap there

Rejected. Authority that reads cwd/PATH/env inline cannot move behind RM-3's process boundary without a
rewrite. A pure decision function that consumes a passed-in snapshot is the whole point: it relocates
unchanged.

### Runtime-probe provider capabilities

Rejected. Probing "what can this provider enforce" at launch is another ambient dependency that would not
reproduce under confinement. Capabilities are declared registry data, versioned with the schema.

### Resolve the adapter through `PATH`/`command -v`

Rejected. cwd and PATH are attacker-influenceable, so executable selection could not become a security
property. An absolute, cwd-independent adapter map is the prerequisite the enforcement phase needs, and
RM-1 introduces it now (ADR-002 had deferred it).

### Keep scrubbing the environment by denylist

Rejected. A denylist is never complete; the provider silently inherited unnamed variables. `env -i` from an
empirical allow-list inherits nothing else and equals RM-3's constructed environment semantics for free.

### Version-branch the schema-4 gate

Rejected. Branching on the version number duplicates the invariant. The real requirement is the adapter
field's presence; a schema-3 registry without it fails through the same missing-adapter path. Field-presence
is the single gate.

### Add the secret-behind-broker / confinement now

Rejected — out of scope (RM-3). RM-1 introduces no secret, daemon, namespace, or seccomp policy. It only
guarantees the single chokepoint and the PDP shape, so RM-3's non-bypassability is later a config move
(pull the credential behind the broker, make the binary executable only by the broker uid), not a call-site
hunt.

### Journal the verdict now

Rejected — out of scope (RM-2). The verdict is shaped for reuse but not written to any durable stream; the
line-oriented heartbeat is not the event spine.

## Consequences

- A managed launch now caps effective authority at `min(clearance, provider capabilities)`, resolves the
  adapter from an absolute registry path, and constructs the child environment from an allow-list — the
  three DOMAIN §2.1/§7 promises RM-0 left open, delivered **at the seam**.
- The authority decision is a pure, isolated, table-testable function. RM-3 can relocate it behind a
  process boundary without touching its logic.
- Schema 4 is a deliberate compatibility boundary. Managed launch from schema 3 fails closed (no adapter
  field); old readers reject 4. Migration adds a `providers` map with absolute adapters and declared caps.
  **Rollback** reverses this: a schema-4 registry must be down-migrated to 3 before an old (2/3-only) reader
  runs — the fail-closed rejection is the safety net. See `docs/CONTRACT-execution-binding.md` §6.
- A schema-4 provider named in a binding but absent from the `providers` map (or missing declared caps) is
  a resolution-time config error (**exit 3**), raised before the PDP — distinct from the PDP's missing-adapter
  127. Both fail closed.
- **RM-1 is still bypassable.** The cap binds only launches that go through the seam; a process that runs a
  provider directly is unaffected, and declared capabilities are trusted, not verified. Public documentation
  keeps the **policy gate, not containment** framing until RM-3 withholds raw capability and mediates
  effects.
- No durable Attempt record or provider-change audit exists yet (RM-2). The verdict record is shaped for
  that reuse but is transient observability today, not historical proof of what ran.
- No new runtime dependency, daemon, network call, or server. Existing Bash/awk/coreutils requirements
  hold; the watchdog still uses `timeout`.

This ADR extends ADR-002; it does not reverse it. The managed seam remains provider-neutral and
single-snapshot; RM-1 adds the decision function, the effective-authority cap, the absolute adapter map,
and the allow-list environment on top of it.

---
White-label: example project id `acme`; no real names, infrastructure, or hosts.
