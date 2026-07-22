# ai-bobnet — Domain Contract

**Normative.** This is the domain freeze every pillar builds against. Where an earlier `CONTRACT-*.md`
disagrees with this document, this document wins. Vocabulary and invariants here are stable; anything
still open is listed explicitly in §12 — nothing is silently undecided.

> **Implementation status:** this document defines the target contract, not the current feature set.
> P0 identity/registry, schema-3 execution binding with per-field provenance, P1 delivery, P2 wakeup/local
> adapter, P3 scoped memory, the legacy-journal serialized commit protocol, and the Codex managed-launch
> path are built and tested. The full serialized event spine, provider-wide reference monitor,
> Gate/Grant/Effect state machines, profile provisioning, full runtime lifecycle, external adapters, and
> dashboard projection remain specified but unimplemented. Until the reference monitor exists,
> `clearance` is registry/audit data rather than an enforced authorization decision.
>
> **The managed-launch path is NO ENFORCEMENT.** It resolves a binding and dispatches an adapter; it does
> not apply §7's decision function, mediate provider syscalls or arbitrary children, constrain network/VCS
> effects, protect `PATH`, prevent raw provider execution, or make T4 decisions. It does not yet implement
> the target §7 environment allow-list. It also creates no durable Attempt record or provider-change audit;
> a heartbeat that shows the binding is operational visibility, not historical proof.
>
> The delivery and memory contracts define the implemented intermediate legacy-journal commit protocol.
> The protocol is a prelude to §6, not its implementation: it does not add sequence numbers, event
> envelopes, framing, integrity markers, a project `main` stream, cursors, projectors, gap detection, or
> torn-tail recovery.

Principle behind the freeze: *the previous generation became unreliable because reliability was added as
heuristics on top of an ambiguous core.* The cure is a small, deterministic domain that an agent can use
**without research**.

---

## 1. Vocabulary (18)

**Core objects**

| Term | Meaning |
|---|---|
| **Project** | A registered repository or logical working environment. The primary grouping. |
| **Team** | Optional group inside a project (e.g. `api`, `web`). Invisible when unused. RM-0 supports one flat direct team; no nesting or rights inheritance. |
| **Agent** | A durably addressable team member. A **registry object**, not a parsed string (§2). |
| **Profile** | Reusable task/capability/instruction set (`infra`, `rails`, `review`, …). **Mutable.** |
| **Session** | One concrete running provider process (a CLI process). Never the identity. |
| **Task** | One concrete unit of work. |
| **Attempt** | One execution attempt of a Task. A crashed process ends an *Attempt*, not the Task. |
| **Run** | A coherent mission composed of Tasks: `Project → Run → Task → Attempt → Session`. |
| **Gate** | A required check or approval. Carries a **typed, content-addressed subject-ref** (§7). |
| **Grant** | A durable authorization that outlives the Gate decision that created it (§3.7). |
| **Effect** | An external side-effect as a first-class object (§4). |
| **Tier** | Risk class of an **action** (T1–T4). Belongs to the action, not to a role. |
| **Scope** | Machine-readable area of responsibility (filesystem/git/environments). |
| **Event** | An immutable fact. Projections derive state from events; state is never guessed. |
| **Artifact** | A referenceable result (file, branch, commit, report, test result) — **by reference**. |

**Technical adapters:** **Provider** (a CLI/agent runtime binding — `claude-code`, `codex`, …; this is the object others call a "harness", and it stays free per agent, see §2.1) · **Runtime** (tmux, process, container, remote) · **Policy** (machine-readable rule for capabilities, risk, approval).

**Retired as core objects:** Archetype → *Profile* · Persona → optional `display_name` · Ring → visual filter only · Territory → *Scope* · Helper → *Session/Attempt under a parent Agent* · standing service personas → *system modules*.

The word `task` MUST NOT mean "role" anywhere, including environment variable names. `Task` is the work item.

---

## 2. Identity

```
agent_uid   = <project_uid> "-" <agent_key>     # IMMUTABLE. The routing key.
agent_key   = explicit, immutable (default: the profile name; suffixed when several share a profile)
profile     = MUTABLE
display_name= OPTIONAL, MUTABLE
provider    = MUTABLE                          # which agent runtime executes this agent (§2.1)
model       = MUTABLE
effort      = MUTABLE
```

- An **Agent is a registry object**. Lookup is the authority; parsing is validation only. An agent that is
  not in the registry is **fail-closed — even if its prefix parses**.
- `profile` and `display_name` MAY change; `agent_uid` MUST NOT. Changing an agent's role MUST NOT change
  its routing key, inbox, journal, or memory scope.
- **Clearance lives on the registry agent object**, never on the mutable `profile` (a profile swap MUST NOT
  silently change clearance). Clearance changes are audited events.
- **Registry governance:** the registry is the identity authority *and* the clearance source *and* is inside
  the executable-config threat set. Writes to it are gated at a high tier and audited. Credential material
  MUST NOT be co-located with it.
- **Ephemeral helpers:** a short-lived helper (e.g. a one-shot provider call) is a **Session/Attempt acting
  `on_behalf_of` an existing Agent** — not a new Agent. A genuinely new durable role is provisioned
  explicitly (atomic bootstrap write, inherited and capped clearance, TTL, audit). Discriminator: *can it
  receive messages, own memory, or be addressed later? → registry Agent. Otherwise → Session/Attempt.*

Registry shape: `projects` · `agents` · `teams` · `profiles`.

### 2.1 Execution binding — `provider`, `model`, `effort`

How an Agent is executed is **registry data resolved for the agent**, not a launcher flag and not a
per-tool default. Without this, the same agent runs on a different model depending on who started it, and
no projection can answer "what is this team actually running on". See the implemented interface and
migration contract in `docs/CONTRACT-execution-binding.md`.

- **`provider`** names the agent runtime binding (`claude-code`, `codex`, …) — the term the vocabulary
  already defines; there is no second word for it. **`model`** and **`effort`** are the settings inside
  that binding. All three are MUTABLE and MUST NOT affect `agent_uid`, routing, inbox, journal, or memory
  scope — swapping the runtime under an agent does not create a different agent.
- **Resolution is field-wise, fixed, and total.** Each of `provider`, `model`, and `effort` independently
  resolves from `agent` → direct `team` → `project` default. The first level where that field is present
  supplies the complete scalar value; one scalar is never assembled from several levels. Cross-level
  bindings are intentional: an agent may resolve `provider` from project, `model` from team, and `effort`
  from agent. Only absence falls through. A present empty, malformed, or unusable value fails closed at
  that level. An agent with no team falls through to project, so teams stay invisible when unused (§1).
- **One launch uses one snapshot and one resolver.** Identity, clearance, direct-team membership, all three
  values, and each value's `level:uid` provenance come from one validated registry read. The adapter and
  managed heartbeat path consume that process-local bundle and MUST NOT reopen the registry or apply a
  second precedence/default layer.
- **An execution binding never grants clearance.** A `provider`/`model`/`effort` change MUST NOT alter
  clearance, for the same reason a `profile` swap must not (above).
- **But it can cap it.** §7 bars `soft-enforcement` runtimes from high-tier and T4 work. That bar binds
  here: an agent's **effective** authority is `min(clearance, what its provider can actually enforce)`.
  Registry clearance is therefore a ceiling, never a promise. Because this is security-relevant,
  `provider` changes are **audited events**, like clearance changes.
- **An Attempt records the resolved binding it actually ran with** (§5). The registry is mutable, so the
  current object cannot answer what executed last Tuesday; only the Attempt can. Audit reads the Attempt.
  RM-0 does not implement this target: its heartbeat binding is not a durable Attempt or audit record.

---

## 3. State machines

A single fused badge is forbidden. There are **seven** independent machines; the UI composes a readable
sentence from them. **No status column exists** — status is a read-time function with a documented
precedence ladder, and every displayed state MUST be traceable to a causing event.

1. **Session** — `OFFLINE → STARTING → READY → WORKING ↔ WAITING → STOPPING → STOPPED` (+ `FAILED`, `ORPHANED`)
2. **Work** — `UNASSIGNED → QUEUED → ASSIGNED → IN_PROGRESS → BLOCKED → REVIEW → DONE | FAILED | CANCELLED`
3. **Message** — `PERSISTED → NOTIFIED → SEEN → PROCESSED` (+ `FAILED → DLQ`)
4. **Gate** — `REQUESTED → PENDING → APPROVED | DENIED | EXPIRED | CANCELLED`
5. **Run** — `QUEUED → RUNNING → PAUSED → BLOCKED → COMPLETED | FAILED | CANCELLED`
6. **Health** — `healthy | warning | idle | unhealthy`
7. **Grant** — `ISSUED → EXPIRED | REVOKED | ROTATED`

### 3.7 Grant — notes that are load-bearing
- There is **no `ACTIVE` state.** It conflated *in force* (time-derived) with *has been used* (observable
  only in the proxy case, and **repeatable** — a grant may be used many times). Usage emits a repeatable
  **`grant.used`** event; it is not a transition.
- **`EXPIRED` is derived, not emitted.** Effectiveness is computed at read time, so expiry holds across
  restarts and downtime with no process running to emit it. Projections MUST NOT cache grant status timelessly.
- **Revocation has two steps:** `REVOCATION_REQUESTED` and `REVOCATION_CONFIRMED`. Until confirmed (or until
  natural expiry) access counts as still effective — an unconfirmed revoke MUST NOT release a safety block
  while the downstream system may still honour the credential.

---

## 4. Effect — external side-effects

Anything that changes the world outside this system is an **Effect**:

`REQUESTED → AUTHORIZED → CLAIMED → EXECUTING → RECONCILED → APPLIED | FAILED | UNKNOWN`

- **Honest semantics: at-least-once dispatch plus adapter idempotency and reconciliation.** This system does
  **not** promise exactly-once, and MUST NOT be documented as if it did.
- **`UNKNOWN` escalates to a human.** An effect whose outcome cannot be established is never silently
  resolved.
- Effects make "resume must not re-fire an already-acknowledged side-effect" implementable: intent is
  recorded **before** the effect; reconciliation detects a crash that happened after the effect but before
  its receipt.

---

## 5. Event envelope

```
event_id · event_type · occurred_at · actor_type · actor_id ·
project_uid · team_uid? · agent_uid? · session_id? · run_id? · task_id? · attempt_id? ·
gate_id? · grant_id? · effect_id? · correlation_id · causation_id · schema_version · payload
```

- `actor_type ∈ { human, agent, service, provider }`. **`agent_uid` MAY be null when `actor_type ≠ agent`** —
  otherwise a human approval, a system/health event, or a broker event cannot be represented at all.
- **The envelope is unambiguously encoded.** Structured fields MUST NOT be parsed out of arbitrary
  separator-delimited segments of free text; a crafted body or note MUST NOT be able to forge a field.
- **Schema versioning: additive-only.** Every record carries `schema_version`; readers MUST tolerate unknown
  fields. A later envelope MUST be able to read earlier records.
- Attribute naming follows the OpenTelemetry GenAI conventions (`gen_ai.*`) so journals are portable from day
  one; an optional span projection mirrors the envelope.
- Concrete provider payload schemas are frozen **after** the provider-session spike (§12).

---

## 6. Event spine — files are the truth

- **Files are authoritative.** A projection (SQLite or otherwise) is a **disposable** coordinator/index for
  order and query. `rm <projection> && rebuild` MUST restore state from the journals.
- **Single append path:** the append **is** the event. There is exactly one writer path, so an event cannot
  be lost by a forgotten emit.
- **Sequence numbers are writer-assigned and live in the source records**, per stream. A projection-assigned
  sequence cannot rebuild order or detect a wholly missing event, so it is forbidden.
- Each record is **framed with a terminator and integrity marker** so a torn tail (kill during append) is
  detectable and quarantinable rather than silently corrupting the fold.
- **A stream is identified by `(project_uid, stream_name)`.** `seq` counts within one stream; a consumer
  cursor is `(stream, seq)`. The addressing is frozen; *how many* streams exist is policy, not format.
  The engine starts with exactly **one stream `main` per project** — at agent-orchestration volumes a single
  serialized append path is ample, and it buys total order for free (one broker, one cursor, a trivial
  rebuild, an ops lens that is a plain read instead of a merge). Splitting later (blast radius of a torn
  tail, a runaway writer flooding a shared journal) is **additive**: a new stream name, no format change.
  Relations across streams are carried by `causation_id`/`correlation_id` — never by timestamps (see below).
- Each stream has **one serializing append broker**. Encoding is: *encode → enforce byte cap → one checked
  append*. A record that exceeds the cap becomes an **Artifact by reference**; it is never inlined.
- Replay reports gaps explicitly (`lost`); a stale consumer cursor after a rebuild is answered with an
  explicit resync signal, never with silent divergence.
- **Cross-file ordering is never derived from timestamps.** Stream order is truth; `occurred_at` is display.
- Raw terminal or prompt data MUST NOT enter the durable journal unfiltered.

---

## 7. Trust: tiers, clearance, gates

**Decision function:** `Action Risk (Tier) × Agent Clearance × Project Policy × Environment → ALLOW | REQUIRE GATE | DENY`.
Tier belongs to the **action**; clearance belongs to the **agent**. High clearance does not imply permission
for a high-risk action.

**Gates are typed and composable**, selected per project profile (from "minimal" to "full compliance"):

| Gate type | Subject | Note |
|---|---|---|
| `code` | a change/diff | correctness review; reviewer ≠ author |
| `compliance` | **any artifact, including plain text** | runs independently of `code`; a text artifact still needs it |
| `gatekeeper` | an access request | issues **Grants**; see §8 |
| *(extensible)* | | new types are added, not special-cased |

- A Gate carries a **typed subject-ref** (`kind: change | artifact | grant-request` + ref) and the ref is
  **content-addressed** (commit hash / artifact hash / spec hash) so an approval cannot be swapped after the fact.
- **Enforcement lives below the agent loop** as an ordered veto chain that can block an action *before* it
  takes effect. A provider-side permission callback is **defense in depth, not a reference monitor**: it
  cannot intercept a provider process's own syscalls. Where a runtime can only be advised, it is labelled
  **`soft-enforcement`** honestly and barred from high-tier and T4 work.
- The current managed-launch seam is below neither raw provider execution nor provider syscalls. It only
  resolves and dispatches a binding and is therefore labelled **NO ENFORCEMENT**, not a reference monitor.
- There is no global "skip all restrictions" mode. At most `--unrestricted-within-tier`; T4, secret and
  deployment floors and the audit trail remain active.
- **T4 is human-only and immutable.** No provider flag, CLI option or policy may silently cross it.
- **Secrets:** the gatekeeper brokers access; it prefers **proxied grants** (opaque handles, short-lived
  scoped tokens, broker-executed operations) over handing raw material to an agent. T4 material is never
  disclosed to an agent. Secrets MUST NOT appear in the registry, journals, prompts, memory, terminal
  recordings, or API responses — only credential identifiers. Launchers pass an **allow-list** of environment
  variables, never an inherited environment.

---

## 8. `effective_access` and toxic combinations

```
effective_access(principal, t) = issued ∧ not_before ≤ t < expires_at ∧ ¬revoke_confirmed
```

This single computed term — not a stored state — is what every policy check consults.

**Toxic combination rule.** Holding an access grant *and* the ability to write executable configuration
(hooks, skills, launcher templates, and the registry itself) is unsafe in combination even when each is safe
alone: granted access can be planted into configuration that a later, higher-clearance run executes.

- The predicate is a **shared, bidirectional** check: the gatekeeper asks "does this principal hold
  executable-config write?", and the executable-config gate asks "does this principal hold effective access?".
- It is evaluated **at decision-commit**, not at request time. Durable gates stay open for hours, so a
  check-then-act window is not a millisecond race.
- The serialization key is **`(project_uid, principal_uid)` across gate types** — not partitioned per gate
  type. An open grant request counts pessimistically as *held*.
- It is keyed on the **beneficiary**, not the actor. Evaluate the **post-state for every affected principal**;
  otherwise one principal can simply grant the capability to another. A clearance change is itself a
  grant-shaped subject and is gated as one.
- Separation of duties: requester ≠ approver ≠ executor. Where the approver is a human out of band and the
  issuer is an isolated broker, this holds structurally rather than by convention.

---

## 9. Invariants

1. **A dashboard is a projection and a command surface — never a second truth.** It never mutates files,
   never computes trust decisions, never bypasses a gate. If it is down, messaging and the CLI still work.
2. **Store facts, derive the display.** Never persist an interpreted status.
3. **Memory never governs.** Recalled memory is advisory context; identity, routing, tier and policy come
   from the registry, never from memory.
4. **Ledger and executor are separate.** Journals record; agent sessions act.
5. **The internal cooperative trust assumption applies to this fleet only.** Any external principal is
   untrusted: its input is hard-enforced and fail-closed, never "cooperatively" accepted.
6. **Honest labelling.** Where a guarantee is best-effort (revocation propagation, advisory enforcement, an
   unverifiable external issuer), it is labelled as such rather than overstated. A component that must be
   trusted is declared trusted, not pretended to be verified.

---

## 10. Non-goals

- **Single host.** This contract targets one host. Cross-host replication is out of scope; an external peer
  is an *external system behind an adapter* (the same class as a messaging integration), not part of this
  system. **Red line: foreign sequence numbers or events are never mapped into local streams.**
- No exactly-once effect delivery (§4). No power-loss durability (§11). No visual workflow editor before a
  working workflow engine.

---

## 11. Durability acceptance

Crash model: **process-restart durability** (a killed process is the torn case). Power-loss durability is out
of scope and no synchronous flush is required.

A conforming implementation proves: (a) a gate/run survives stop and restart · (b) pending/fan-in state is
durable, not in-memory · (c) in-flight work resumes rather than being re-dispatched from scratch · (d) an
event cannot be lost through a forgotten emit · (e) a deleted projection can be rebuilt · (f) replay reports
gaps explicitly · (g) a torn final record is tolerated or quarantined and never corrupts the fold · (h) resume
does not re-fire an already-acknowledged effect · (j) a living orphaned session is **adopted, not duplicated**;
a failed probe alone never kills · (k) grant expiry holds across restart and downtime with no emitting process
· (l) a crash after an effect but before its receipt is caught by reconciliation · (m) an `UNKNOWN` effect
escalates to a human.

---

## 12. Open contract points (explicitly not frozen)

1. ~~**Stream granularity** for the event spine (§6)~~ — **resolved 2026-07-19**: stream identity is
   `(project_uid, stream_name)`, one stream `main` per project to start, splitting is additive. See §6.
2. **Provider payload schemas** (§5) — frozen after the provider-session spike.
3. **Registry vs. policy split** (§2) — clearance on the registry object (current) vs. a separate policy
   ledger keyed by `agent_uid`. Invariant either way: clearance binds to immutable identity.
4. **Gatekeeper seam details** — issuance receipt verified against the approved specification before the
   grant is recorded; unique issuance key; the trusted-computing-base declaration for an external issuer.

---

White-label: example project id `acme`; no real names, hosts, or infrastructure in this repository.
