# ai-bobnet — Execution Binding and Managed Launch Contract (RM-0)

This contract defines the first provider-neutral launch seam. It makes the registry the source of
`provider`, `model`, and `effort`, and makes the resolved values observable. It does **not** authorize
actions or contain them.

> **Security status: NO ENFORCEMENT.** Managed launch is not a reference monitor. It does not evaluate
> `ALLOW | REQUIRE GATE | DENY`, mediate provider syscalls or child processes, constrain network or VCS
> effects, or make T4 decisions. A caller can still bypass it and execute a provider directly. The
> installed `codex` executable is selected through `PATH`, and RM-0 does not yet implement the target
> environment allow-list from `docs/DOMAIN.md` §7. These are explicit limitations, not security guarantees.

## 1. Registry compatibility boundary

The registry has two supported reader modes:

- **Schema 2 is legacy-only.** Existing identity, context, delivery, wakeup, memory, and arbitrary
  `bin/run-agent` commands continue to work. A managed provider launch from schema 2 fails loudly before
  an adapter process starts.
- **Schema 3 enables managed launch.** It adds flat `teams`, optional direct `agent.team_uid` membership,
  and optional `provider`, `model`, and `effort` fields at project, team, and agent level. A complete valid
  binding must resolve before an adapter process starts.

Old schema-2 readers reject schema 3. Unknown extra fields remain forward-compatible only when they are
not consumed. Schema-3 execution fields are load-bearing known fields and are therefore validated rather
than ignored.

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
| `registry_schema_version` | `AIBOBNET_REGISTRY_SCHEMA_VERSION` | `3` |

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
The Codex adapter invokes the installed executable named exactly `codex` through `PATH`; deterministic
tests prepend a controlled directory containing an executable with that exact name.
Because `PATH`, the wider inherited process environment, and raw provider execution are not brokered, the
managed path is not an enforcement boundary.

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

---
White-label: example project id `acme`; no real names, infrastructure, or hosts.
