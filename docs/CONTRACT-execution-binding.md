# ai-bobnet — Execution Binding and Managed Launch Contract (RM-0 / RM-1)

This contract defines the provider-neutral launch seam. RM-0 made the registry the source of `provider`,
`model`, and `effort` and made the resolved values observable. RM-1 turns that seam into a **policy gate**:
it caps effective authority, resolves the adapter from an absolute registry path, and builds the child
environment from an allow-list. It still does **not** contain a provider.

> **Security status: POLICY GATE for cooperating agents (RM-1) — NOT containment.** RM-1 evaluates a
> managed launch through a pure Policy Decision Point and enacts the verdict, but it is **not** a reference
> monitor. It does not mediate provider syscalls or child processes, constrain network or VCS effects, make
> T4 decisions, or prevent a hostile local process from running a provider binary directly. The
> capabilities it caps against are **declared** registry data, trusted rather than runtime-verified.
> Non-bypassability is RM-3's job. The RM-1 details below (schema 4, PDP/PEP split, `min(clearance,
> provider capabilities)`, absolute adapter map, `env -i` allow-list) are in **§7**. The words
> "enforcement boundary", "reference monitor", and "containment" are reserved for RM-3.

## 1. Registry compatibility boundary

The registry has two supported reader modes:

- **Schema 2 is legacy-only.** Existing identity, context, delivery, wakeup, memory, and arbitrary
  `bin/run-agent` commands continue to work. A managed provider launch from schema 2 fails loudly before
  an adapter process starts.
- **Schema 3 enables managed launch.** It adds flat `teams`, optional direct `agent.team_uid` membership,
  and optional `provider`, `model`, and `effort` fields at project, team, and agent level. A complete valid
  binding must resolve before an adapter process starts.
- **Schema 4 adds the RM-1 policy-gate data** (see §7): a top-level `providers.<name>` map carrying the
  absolute `adapter` path and declared `cap_sandbox` / `cap_tier` / `cap_effort` capabilities. Managed
  launch requires the adapter field; a schema-3 registry lacks it and fails closed with the same
  missing-adapter path (exit 127), so the gate is field-presence, not a version branch.

Old schema-2 readers reject schema 3 and 4; readers that know only 2/3 reject 4. Unknown extra fields remain
forward-compatible only when they are not consumed. Schema-3 execution fields and schema-4 policy-gate
fields are load-bearing known fields and are therefore validated rather than ignored.

```json
{
  "schema_version": 3,
  "projects": {
    "acme": {
      "home": "/srv/acme",
      "standup_dir": "/srv/acme/standup",
      "mux_session": "acme",
      "provider": "codex",
      "model": "example-model",
      "effort": "high"
    }
  },
  "teams": {
    "acme-engine": {
      "project": "acme",
      "model": "example-review-model"
    }
  },
  "agents": {
    "acme-core": {
      "project": "acme",
      "team_uid": "acme-engine",
      "profile": "engine-dev",
      "clearance": "t2",
      "effort": "medium"
    }
  }
}
```

### Teams in schema 3

`team_uid = <project_uid>-<team_key>`, using the same lowercase token rules as other routing IDs. An
agent may name one direct team through `team_uid`. The team must exist as an object, its required
`project` must equal the agent's project, and its object key must carry that project's prefix. Unknown,
malformed, or cross-project membership fails closed.

Teams are flat in RM-0. There is no parent team, nesting, rights inheritance, or parent-binding lookup.
A truly absent `team_uid` means no team and falls through to project defaults. A present but empty,
non-string, undecodable, or malformed `team_uid` is an error; it is not treated as absence.

## 2. Field-wise binding resolution

Each field resolves independently in this fixed order:

```text
agent -> direct team -> project
```

For each of `provider`, `model`, and `effort`, the first level where that field is present supplies the
entire scalar value. Cross-level bindings are intentional; one scalar is never combined from multiple
levels. Only absence falls through. A present empty, non-string, undecodable, or syntactically invalid
value fails closed at that level rather than revealing a lower default.

The example above resolves exactly:

```text
provider=codex                       provider_source=project:acme
model=example-review-model           model_source=team:acme-engine
effort=medium                        effort_source=agent:acme-core
```

Every managed launch requires all three resolved fields. Their validation is:

- `provider`: a lowercase token, at most 64 bytes; it must name an implemented adapter.
- `model`: 1–256 bytes from `[A-Za-z0-9._:/-]`.
- `effort`: an adapter-owned closed enum. The Codex adapter accepts `low | medium | high | max`.

The selected adapter validates the complete resolved binding before it starts the provider. An unknown
provider, an unimplemented adapter, a missing field, or an adapter-invalid binding is a loud pre-launch
failure.

Binding resolution never changes registry clearance. In particular, changing `provider`, `model`,
`effort`, or direct-team membership must not change the agent UID, routing, inbox, journals, memory scope,
profile, or clearance.

## 3. One snapshot, one resolver

One managed-resolution API owns schema-3 validation and returns one process-local bundle containing:

- schema version;
- agent and project identity, profile, clearance, and the resolved standup directory;
- optional direct-team membership;
- resolved `provider`, `model`, and `effort`;
- the exact source level and UID for each binding field.

The complete bundle comes from one validated read of one registry file generation. Identity and binding
for one launch must not be assembled from separate reads. A provider adapter and the managed heartbeat
path consume this bundle; neither may reopen the registry, repeat precedence logic, or replace a resolved
field with its own default.

Managed heartbeats use a shared pre-resolved primitive with the bundle's `agent_uid` and `standup_dir`.
That primitive preserves the standalone logger's closed status enum and LF/CR/pipe sanitization, but does
not authenticate the identity with a second registry read. It is an internal, process-local interface;
there is no public flag or ambient environment input for supplying a pre-resolved heartbeat identity or
path. Standalone `scripts/log.sh` remains registry-authenticated for callers that do not already hold a
managed-resolution bundle.

For schema 3, `bin/context` text and JSON output and the environment produced by `bin/run-agent` add these
exact fields:

| Text/JSON field | Environment variable | Value |
|---|---|---|
| `provider` | `AIBOBNET_PROVIDER` | resolved provider |
| `provider_source` | `AIBOBNET_PROVIDER_SOURCE` | `agent:<uid>`, `team:<uid>`, or `project:<uid>` |
| `model` | `AIBOBNET_MODEL` | resolved model |
| `model_source` | `AIBOBNET_MODEL_SOURCE` | `agent:<uid>`, `team:<uid>`, or `project:<uid>` |
| `effort` | `AIBOBNET_EFFORT` | resolved effort |
| `effort_source` | `AIBOBNET_EFFORT_SOURCE` | `agent:<uid>`, `team:<uid>`, or `project:<uid>` |
| `registry_schema_version` | `AIBOBNET_REGISTRY_SCHEMA_VERSION` | `3` or `4` |

Inherited values in those environment variables are scrubbed and cannot override the resolved bundle.
Schema-2 `bin/context` and `bin/run-agent` keep their legacy identity/context behavior but expose no
execution binding that can authorize a managed provider launch.

Before provider execution, managed launch exports the resolved schema-3 identity and binding namespace to
the child. It removes inherited values first, including `CODEX_RUN_BIN`, so the child sees the validated
bundle rather than ambient lookalikes. This export is context and observability, not authorization.
The managed child receives the legacy resolved identity/path variables, `STANDUP_DIR`, every binding and
source variable in the table above, and `AIBOBNET_TEAM_UID` (empty when the agent has no direct team).

The pre-existing `AIBOBNET_REGISTRY` advanced/test locator can select the registry file that is read before
the snapshot is created. It is not a per-field provider/model/effort override and is not forwarded to the
provider child. RM-0 does not turn that caller-controlled registry locator into a security boundary.

RM-0 exposes no registry generation or digest. It also creates no durable Attempt record or
provider-change audit. Both remain specified target behavior. The effective binding may appear in a
heartbeat for operator visibility, but a mutable heartbeat is neither a durable audit event nor historical
proof of what ran.

## 4. Managed launch interfaces

The provider-neutral entry point is:

```text
bin/launch-agent --as <agent_uid> [runtime options] (--prompt <text> | --prompt-file <file> | -)
```

`--as` identifies the registered agent to launch; it is not `bin/run-agent --as <actor-label>`. RM-0
implements only the `codex` adapter. Provider, model, and effort have no CLI or environment override.
The only runtime options are `--sandbox`, `--cwd`, `--timeout`, and `--label`; they do not select the
execution binding. Exactly one prompt source is required: `--prompt`, `--prompt-file`, or standard input
selected by `-`.

`bin/codex-run` remains a compatibility command, but it delegates to `bin/launch-agent` and does not
open the registry or resolve a field itself. Both entry points refuse `--model` and `--effort` with a
migration error and exit 64; there is no model or effort default in either command.

The former `CODEX_RUN_BIN` variable has no managed-launch role and is removed before provider execution.
Under RM-1 the adapter is no longer located through `PATH`: it is the **absolute** `providers.<name>.adapter`
path from the registry, executed by absolute path (see §7). Raw provider execution outside the seam is still
not brokered, so the managed path remains a policy gate for cooperating agents, not an enforcement boundary.

Every validation or dispatch error is loud and non-zero. Binding, membership, schema, provider, and
argument failures occur before the provider process starts. Watchdog timeout and provider exit behavior
remain adapter-specific and are defined in `docs/CONTRACT-codex-run.md`.

## 5. Acceptance

A conforming RM-0 implementation proves:

- schema 2 still serves legacy identity/context operations but cannot launch a provider;
- schema 3 resolves project fallback, direct-team fallback, agent overrides, no-team fallback, and the
  exact mixed-level provenance example above;
- invalid values at a higher-precedence level fail rather than falling through;
- malformed, missing, unknown, or foreign direct-team membership fails closed;
- inherited binding variables and `CODEX_RUN_BIN` cannot become managed binding or executable authority;
- one launch cannot mix identity or binding from two registry generations;
- managed start and terminal heartbeats use the same resolved identity/path bundle without reopening the
  registry, while retaining status validation and LF/CR/pipe sanitization;
- a label containing LF, CR, or `|` still produces exactly one physical busy line and one physical terminal
  line, with the payload sanitized rather than interpreted as structure;
- provider changes do not alter clearance;
- Codex argv and heartbeat use the resolved model and effort exactly;
- model/effort overrides, schema-2 managed launch, provider mismatch, and unknown or unimplemented
  providers fail before the provider stub starts;
- an adapter that reopens the registry, restores a local default, or removes precedence/provenance makes
  the adversarial suite fail.

## 6. Migration and rollback

To migrate without changing the intended runtime, copy each existing Codex model and effort choice into
schema-3 project, direct-team, or agent fields, add `provider: codex`, validate the mixed-level result for
every managed agent, and only then move callers from raw `codex-run` defaults/overrides to managed launch.
Existing schema-2 commands remain available during this preparation, but schema-2 managed launch does not.

This is an intentional compatibility boundary: old readers reject schema 3, and upgraded `codex-run`
rejects its former model/effort flags. Rollback therefore requires stopping managed launches, converting
the registry back to schema 2, restoring any caller-owned model/effort arguments expected by the old
wrapper, and only then running an old reader. A schema-3 registry must never be handed to an old reader.
A schema-4 registry likewise must never be handed to a reader that knows only 2/3.

## 7. RM-1 policy gate — PDP/PEP split (ADR-0003)

RM-1 makes the seam a **policy gate for cooperating agents** — not containment (see the security-status box).
The design and rationale are in [ADR-0003](decisions/0003-managed-policy-gate.md); this section is the
implemented interface.

### 7.1 Policy Decision Point — a pure function

`aib_authorize_launch <request-record> <snapshot-record>` (`lib/aibobnet.sh`) is the single authority for a
managed launch. It is **pure**: it reads nothing from disk, PATH, cwd, or the environment — both inputs
arrive as newline-delimited `key=value` records, and the verdict is deterministic over them. It MUST NOT
reopen the registry (that would route through the `AIBOBNET_REGISTRY` locator and break purity).

- `request` keys: `agent_uid`, requested `sandbox`, `cwd`, `timeout`, `label`.
- `snapshot` keys: `clearance`, `provider`, `effort`, the absolute `adapter`, and `cap_sandbox` /
  `cap_tier` / `cap_effort` — all resolved by `aib_resolve_managed_agent` before the call, never probed.

The verdict is published through `AIB_VERDICT_*` globals: `DECISION` (`allow`/`deny`), `CODE`, `REASONS`,
`EFFECTIVE_CLEARANCE` / `EFFECTIVE_SANDBOX` / `EFFECTIVE_EFFORT`, `ADAPTER_PATH`, `ENV_ALLOW`, and a
one-line JSON `AIB_VERDICT_RECORD` (`event: launch_verdict`). Purity is what lets RM-3 relocate this
identical function behind a process boundary without a rewrite.

**Authority lives only in the PDP.** The sandbox ceiling, `min(clearance, cap_tier)`, and the effort cap
are computed there and nowhere else. The launcher's argument-parsing checks remain input hygiene (form),
not a second authority.

### 7.2 Effective authority = `min(clearance, provider capabilities)`

Each effective value is a minimum over a total order (`t1<t2<t3<t4`;
`read-only<workspace-write<danger-full-access`; `low<medium<high<max`). A request above a ceiling is
**clamped, not denied**: the launch proceeds at the lower, safer bound and a deny reason records the clamp.
This delivers the `docs/DOMAIN.md` §2.1 promise **at the seam**. The capabilities are declared registry
data, trusted rather than runtime-verified — RM-1 hands the provider the clamped values and trusts it to
honor them; it does not itself confine the provider.

### 7.3 Absolute adapter map + declared capabilities (schema 4)

The provider adapter is `providers.<name>.adapter`, an absolute path validated absolute by the PDP (a
non-absolute adapter is a config deny, code 2). This replaces the RM-0 `command -v codex` from cwd — cwd is
attacker-influenceable, so adapter resolution no longer depends on it. `cap_sandbox` / `cap_tier` /
`cap_effort` are declared capability data, resolved by the managed resolver, never runtime-probed. An
empty adapter entry resolves no adapter and is a fail-closed PDP deny (code 127). On schema 3 this also
subsumes the unknown-provider case (there is no adapter map). On schema 4, a provider named but absent from
the `providers` map, or missing its declared capabilities, is a resolution-time config error (**exit 3**)
caught by the resolver before the PDP — not the PDP's 127.

```json
{
  "schema_version": 4,
  "providers": {
    "codex": {
      "adapter": "/opt/acme/adapters/codex",
      "cap_sandbox": "workspace-write",
      "cap_tier": "t3",
      "cap_effort": "high"
    }
  }
}
```

### 7.4 Policy Enforcement Point — enacts the verdict

`bin/launch-agent` builds the two records from the resolved bundle, calls the PDP, and on deny fails closed
with the PDP-chosen exit code **before any heartbeat or provider process starts**. On allow it runs at the
effective (clamped) sandbox/effort and `exec`s the **absolute** `adapter_path` from the verdict under the
`timeout` watchdog. It re-decides no authority — "PEP" means it *executes the verdict*, nothing more.
`bin/codex-run` is a thin `exec` delegator into `launch-agent`.

### 7.5 Child environment built by allow-list (`env -i`)

The child environment is **constructed** from the verdict's allow-list via `env -i`, not scrubbed by
denylist. The provider inherits nothing but the named allow-list variables (values from the current
environment) plus the explicit managed `AIBOBNET_*` exports. The allow set was derived empirically from an
`env -i` smoke launch, not guessed: the Codex adapter needs `HOME` (its config directory and file-based
auth) and a `PATH` (its runtime and helpers); no separate provider-auth environment variable is
load-bearing, because the credential lives in the adapter's own auth file. A denylist is never complete; an
allow-list is complete by construction and matches RM-3's confined environment for free.

**Deployment precondition:** provider auth must be **file-based**. An API key supplied only as an
environment variable (e.g. `OPENAI_API_KEY`) is not in the allow-list, does not survive `env -i`, and the
provider would fail authentication — a required deployment property, not a defect. The parent `PATH` is
passed through verbatim (not filtered), acceptable here because the adapter is resolved to an absolute path
and RM-1's threat model is cooperating agents.

### 7.6 Exit codes and verdict record

Exit codes: `64` usage/refusal · `2` config/IO · `127` adapter-not-found · `124` watchdog timeout. The PDP
orders deny checks by severity so the first deny fixes the code (`127 > 2 > 64`); the RM-3 broker returns
the same codes. Separately, `3` is a registry resolution config error (e.g. a schema-4 provider absent from
the `providers` map) raised by the resolver *before* the PDP, so it is not one of the PDP verdict codes. The `launch_verdict` record shares the shape family of the RM-0 `managed_launch_binding`
observability event so RM-2's durable Attempt audit can reuse it — but RM-1 journals nothing; the record is
transient observability, not durable audit.

### 7.7 Deferred RM-0 findings folded in

Raw-NUL registry rejection within a single open (`IFS= read -r -d ''`; rc=0 means a NUL was found → loud
refusal, no second open); load-time validation of **every** team key, not only referenced ones; and
exit-127 coverage for a resolvable-but-absent adapter.

---
White-label: example project id `acme`; no real names, infrastructure, or hosts.
