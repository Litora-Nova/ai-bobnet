# ai-bobnet — Mediated Launch Contract (RM-3 stage 1)

This contract defines the seam between an agent and the broker: a single offered operation, `launch`,
executed under an identity the agent cannot assume. RM-1 turned the launch seam into a policy gate.
RM-2 made attempts durably auditable through that seam. RM-3 stage 1 is the first step that makes the
gate hard to walk around — not because the agent politely asks permission, but because it cannot
reach the provider on its own.

> **Status: SPECIFICATION — no implementation exists.** This document is written before the broker,
> deliberately, so that the thing being built has something to be measured against. Every path,
> operation, and unit named here is a requirement, not a description of running code.

> **Security status: MEDIATED LAUNCH — a boundary between the agent tree and the broker, NOT between
> one agent and another.** Under a single agent uid the broker cannot establish which agent is asking;
> the clearance selector is an assertion the broker accepts, not a fact it verifies, and the audit
> stream attributes to that same assertion. This contract does not make the monitor tamper-proof
> against a host account with root, and it does not isolate agents from each other. Per-agent uids and
> an off-host witness are separate steps. The words "tamper-proof" and "agent isolation" are reserved
> for those.

## 1. Two seams, and which one this is

The system has two boundaries that are easy to confuse. Only the second is the subject of this
contract.

| Seam | Between | Where | Threat model |
|---|---|---|---|
| PEP → PDP | enforcement and decision | in-process | none — one trust domain. Purity here buys testability, not security. |
| **Agent → broker** | the agent tree and the broker | over a unix socket | **this contract.** The caller is potentially hostile. |

ADR-0003 made `aib_authorize_launch` a pure function called by the PEP. That seam is real and useful,
but it is in-process: caller and decider share a trust domain, so nothing crossing it is an attack
surface. Promoting it to a process boundary and calling the result mediation would specify the wrong
seam.

**Where the binding actually comes from.** Non-bypassability does not follow from an agent choosing to
call `authorize`. A hostile caller does not ask; it acts. It follows from the agent being unable to
start a provider at all: the provider credential is readable only by the broker account, only the
broker account may reach the provider API, and the event stream is broker-owned. The agent has to ask
because it has no other route.

## 2. The offered operation

```
launch(request) -> { stream, exit_class, event_ids }
```

This is the entire agent-visible surface. One call.

The request carries: `agent_uid`, `cwd`, `sandbox`, `timeout`, `label`, `prompt`.

The broker then performs, internally and in this order:

1. `authorize(request, snapshot)` — the snapshot comes from the broker's own registry, never from the
   caller.
2. `commit(attempt.decided)` — the verdict is recorded **before** anything runs.
3. **Enactment** — `env -i`, absolute adapter path, `HOME` from the broker's own context, watchdog,
   capped timeout, **and the provider child is confined before `exec`** (§2.1).
4. `commit(attempt.ended)` — terminal exit class, causally bound to the `decided` event.

`authorize`, `commit`, and `high_water` are **broker internals**. They are specified here because the
broker must implement them correctly, not because an agent may call them.

### 2.1 The provider child must be confined

Moving enactment behind the boundary has a price that must be paid explicitly.

The provider child runs as the broker account — the account that owns the event stream, the high-water
anchor, the credential directory, and the adapter map, and the only account permitted to reach the
provider API. But the provider is **agent-directed computation**: the prompt comes from the request.
The provider's own sandbox flag is cooperative enforcement by the provider; from the broker's side it
is not a boundary.

Stated plainly: *the agent does not run as the broker account, but its prompts would.* A provider
defect or a prompt-driven escape would write the very components the boundary exists to protect.

**Therefore the enactment MUST confine the child before `exec`:**

- **Landlock**, applied by the broker immediately before executing foreign code. This is explicitly
  not self-sandboxing by the party being constrained — the restriction is installed before the
  untrusted code runs, and Landlock rulesets cannot be revoked by the restricted process.
- **A filesystem-namespace wrapper** remains the alternative where Landlock is unavailable or
  insufficient, as an effect limiter.

**Minimum the contract requires:** the child has **no write access** to the event stream, the
high-water anchor, the registry, the adapter map, or the installed engine. Read access to the
credential directory only to the extent the adapter requires it.

Without this, the contract would freeze a boundary that reopens itself from the inside.

## 3. What crosses the boundary and carries authority

Because `launch` is the only operation, only the request crosses. This is the complete list.

| Request field | Selects | Severity | Verifiable by the broker? |
|---|---|---|---|
| `agent_uid` | **which registry snapshot** is loaded | **HIGH** | **No** — see §4 |
| `prompt` | the computation that runs inside the broker's trust domain | **HIGH** | No — hence §2.1 |
| `timeout` | how long the child holds resources | MID | **Yes** — the broker caps it; resource authority does not belong to the caller |
| `cwd` | the writable root under a workspace-write sandbox | LOW/MID | Partly — filesystem ownership and §2.1 cover the rest |
| `sandbox` | the requested sandbox level | LOW | Yes — the PDP clamps against declared capabilities |
| `label` | display name in the audit record | LOW | Form yes (§6), content no |

The broker continues to reject pre-composed identity fields (`event_id`, `attempt_id`, `seq`) crossing
the seam; identity is composed under the lock and never accepted from a caller.

**The protocol never carries environment fields.** The child environment is built from the broker's own
context. This is what removes the credential-directory selector from the attack surface, and it holds
only as long as this rule holds.

### 3.1 What stops crossing entirely

With `launch` as the only operation, three former authority carriers disappear rather than needing to
be defended:

- **`project_uid`** — derived by the broker from the registry.
- **`actor_id`** — the broker *is* the observer of the decision; it attests to itself.
- **`decided_event_id`** — held internally between step 2 and step 4.

That reduction is the substantive gain of putting the boundary in the right place.

## 4. The single-uid limit

All agents run under one unix account. Peer credentials therefore tell the broker that *an* agent is
asking, never *which* one. `agent_uid` is an assertion the broker cannot refute: an agent presenting
the identifier of a higher-clearance agent receives that clearance.

This is a limitation of the account model, not of the interface, and it cannot be designed away at
this layer. It is stated in the security-status box above and repeated here because it also governs
how the audit stream may be read: **the recorded `agent_uid` is that same unverified assertion, and the
stream must not be treated as proof of identity between agents.**

Per-agent uids are the change that turns the assertion into a fact. They are a separate step with
their own cost, and they are not part of this contract.

## 5. `high_water` — a self-check, not a boundary

The anchor is a monotonic counter in broker-owned state, outside the stream file, read and advanced
under the same lock as the append.

**What it does not do.** With the event stream owned by the broker account and unreadable, unwritable
and unrenameable by the agent, truncation by the agent is already prevented by ownership. What remains
is a host account with root — and against that the anchor is useless, because root writes stream and
anchor alike. The set of actors that can truncate the stream but cannot write the anchor is empty.

**What it does do**, and what justifies keeping it: it catches accidental truncation or replacement,
and it catches broker-internal defects — a sequence rewind, or a refactor that loosens stream
ownership. That is defence in depth and a self-check. Detecting rewrites by a host account requires a
witness outside the machine, which is a separate step.

### 5.1 Ordering and crash behaviour

Holding one lock gives mutual exclusion, not crash atomicity across two files. The order is therefore a
real decision:

> **Append → fsync → anchor → fsync.** Both inside the same lock.

The two failure cases point in **opposite directions**, which is what makes them distinguishable:

| Observation | Cause | Behaviour |
|---|---|---|
| `high_water > max(seq)` | stream truncated or replaced | **fail closed**, no append |
| `high_water < max(seq)` | crash after append, before anchor write | advance the anchor to `max`, log the lag |
| equal | normal | proceed |

The reverse order would turn every crash during a commit into a false positive that fails the stream
closed — an unacceptable trade for a mechanism that is explicitly not a security boundary.

**The anchor is written atomically** (temporary file plus rename in the same directory). Otherwise a
crash *during* the anchor write would leave a torn file, for which the table above defines no
behaviour, and failing closed there would reintroduce the per-crash brick that this ordering avoids.

**The lag record goes to the broker log, not into the event stream.** A repair that mutates the object
under examination would be recursive.

**Remaining gap, stated rather than hidden:** an actor who removes exactly the records appended after
the last anchor write is not detected, because the truncation is indistinguishable from lag. Since the
anchor is written immediately after the append inside the same lock, that window is **at most one
record**, and it requires an unclean broker stop. This is consistent with torn-tail handling: an
unterminated record never advanced the anchor, so tail truncation cannot produce a false `> max`.

Keeping the anchor in a separate directory from the stream is housekeeping, not a security gain — both
belong to the same trust domain.

## 6. Transport

- **Socket** in the broker's runtime directory, owned by the broker account, group-readable by the
  shared group. The directory is not writable by the agent, so the socket can be neither removed nor
  replaced nor repointed.
- **No JSON on the wire.** The runtime has no JSON parser.
- **Plain key-value framing is not sufficient on its own, and using it alone would be an injection
  defect.** The existing record reader takes newline-separated records with single-line values. A
  prompt is multi-line free text and does not fit; worse, any free-text value containing a newline
  forges fields — a label carrying an embedded newline followed by an identity assignment would be
  indistinguishable on the wire from two honest fields. This is the same class as the inbound
  injection gate, on a new channel.
  **Requirement:** key-value framing carries **token fields only**, validated against the existing
  token rules. **Free text is length-prefixed**: a header field giving the byte count, followed by
  exactly that many raw bytes, never read as record lines. The parser counts bytes instead of
  searching for separators — the same principle the framed event stream already applies.
- **Implementation language is fixed to the language of the existing runtime.** A broker written in
  anything else would need a second implementation of the frozen composers, the checksum framing and
  the identity composition, held byte-identical. Two authorities for one frozen wire format is the
  fork this contract exists to prevent.
- **No daemon loop:** socket activation with one instance per connection. This removes the
  long-running-shell-service problem, isolates crashes per connection, and makes reading the registry
  per connection the natural default, which keeps clearance changes fresh. The existing lock-based
  serialisation is unaffected, because the lock covers only the commit windows, not the enactment.
  **Connection limits are part of this requirement**: without them a caller in a connect loop produces
  a fork storm and lock contention.
- **The lock wait stays finite**, with the existing stable exit code on timeout.

## 7. Migration

- **A genuine move:** `authorize` and `commit` exist, are tested, and relocate behind the socket
  without changing their logic.
- **New code, not configuration:** the transport failure domain. In-process, authorization cannot fail
  because a broker is down. Across a socket, every call can fail with a permission error, a timeout, or
  an absent broker, and every call site needs that handling.
- **No predecessor:** `high_water` does not exist today. There is no current behaviour to preserve.
- **Single-trust-domain deployments** stay on the in-process path. They do not get a broker and do not
  need one; there, everything is one trust domain, and that is documented rather than papered over.

## 8. Deliberately not decided here

- **Per-agent uids** — the single change that turns §4 from a limitation into a boundary.
- **An off-host witness** — the only escalation that holds against a host account with root.
- **Reconnect and backpressure semantics** beyond the existing lock timeout.
- **Whether the registry is re-read per connection or cached** — with socket activation, per
  connection is the natural default.
