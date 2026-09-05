# ai-bobnet — Wire Format Specification (subordinate to the mediated launch contract §6)

**Status:** proposed, 2026-08-16. **Subordinate to** `CONTRACT-mediation.md` §6, which is frozen and
stays frozen. This document does not amend it; it spells out per field what §6 already provides for.

## Why this document exists rather than a contract amendment

Slice 1 was built on the assumption that a frame carries exactly one length-prefixed block and that
this block is the `prompt`. **The contract never said that.** §6 defines two branches — token fields
on record lines, and free text carried length-prefixed — and §3 already assigns `label` to the second
branch when it says its form is checked and its content is not.

So there was no contradiction between §2 and §6 to resolve, only a silence to fill. Breaking a freeze
over a silence would be the most expensive possible way to handle it.

## The rule that settles the recurring question

> **Where the contract states a floor, a validator may be stricter — never looser.**

§6 requires token fields to be "validated against the existing token rules". That is a **floor, not a
ceiling**. An enum check on `sandbox` and a digits-plus-range check on `timeout` *narrow* the token
rule; they do not replace it. Narrowing a floor has never been a contract violation — only loosening
would be. Whenever a new field appears, this sentence answers "do we need to change §6?" without a
debate.

**A mechanism the contract names is not a strictness dial.** Where the contract or this document
states *how* a boundary reacts — §3 has the PDP **clamp** `sandbox` against declared capabilities and
the broker **cap** `timeout` — that mechanism is part of the settlement, not a floor to be tightened.
Refusing instead of clamping looks stricter and is in fact a different promise to the caller: a clamp
returns a degraded success, a refusal returns nothing. Swapping one for the other is a behaviour
change, not a more careful enforcement of the same rule. See "Assurances that must move with
`authorize`", which is the same distinction seen from the other end.

**The qualifier is not decoration.** The contract also states **ceilings**, and there the sentence
inverts. §3 says `label` is checked for form but **not for content** — that is an upper bound, not
merely the absence of a lower one. A reader who applies "stricter is always allowed" to `label` and
adds a content check would violate §3 while believing they were being careful: exactly the mistake
this rule exists to prevent. So before invoking it, establish which kind of statement the contract is
making about the field. Floors take narrowing; ceilings do not; named mechanisms are neither.

A second rule, from the same family as the confinement work:

> **What containment can decide, no character class should have to guess.**

A path grammar (no `..`, absolute, restricted alphabet) is a guessing game against symlinks, Unicode
and normalisation. A resolved path compared against a derived root is a decision.

## Field classification

| Field | Branch | Validation | Decided by |
|---|---|---|---|
| `op` | record line | existing token rule + enum (`launch`) | wire |
| `agent_uid` | record line | `aib_validate_agent_uid` (existing) | wire |
| `sandbox` | record line | **enum**, narrower than the token rule | wire + PDP |
| `timeout` | record line | digits + range, then `min(requested, cap)` | PDP |
| `cwd` | **length-prefixed** | **containment** in the registry-derived root | broker |
| `label` | **length-prefixed** | length only (§3: content is not checked) | wire |
| `prompt` | length-prefixed | length only (existing) | wire |

Length-prefixed fields are declared with a `<field>_bytes` header on a record line and read by
counting bytes, never by searching for a separator. Their order in the frame is fixed and given
below, because a reader that counts bytes has no way to recover from an unexpected order.

**Frame order:** record lines, blank line, then the length-prefixed blocks in this order:
`cwd`, `label`, `prompt`. The order is required because the headers say how *long* each block is, not
*where* it sits in the byte stream — a reader that counts bytes cannot recover from an unexpected
sequence.

Two edges, so that no one has to infer them:

- **A block whose `<field>_bytes` header is absent is absent from the stream, and
  `<field>_bytes=0` behaves exactly as absent.** For `prompt` an empty value is a legal empty string
  either way. For `cwd` the distinction would otherwise matter: an explicitly empty path handed to
  the resolution step below is an unspecified edge case, and it resolves here instead — an empty
  `cwd` means the derived root, the same as omitting it.
- **An unrecognised `<field>_bytes` header is refused**, by the same allowlist that governs the other
  record-line fields. A length header is a field like any other; it does not get a side entrance
  because it happens to describe bytes.

## `cwd` — the field that stops carrying authority

**The Landlock positive list is derived from the registry, never from the request.**

This is the load-bearing sentence of this document. §2.1 justifies confinement by the restriction
being installed *before* the untrusted code runs and *not being revocable* by the restricted process.
Both properties are worthless if the **scope** of the restriction comes from the request: a cage
whose bars the prisoner chooses is not a cage. That is the same defect, one level lower, as an
`authorize` call whose caller owns the enactment.

Once the writable set is derived from the registry, `cwd` no longer selects *what* is writable. It
selects only *where inside the already-fixed area* the child starts. A `cwd` outside that area is
therefore not a security problem but a **rejection** — one the broker decides by comparison, without
inventing a single character rule.

**Order is part of the requirement**, so that no window opens between check and effect:

1. resolve the requested `cwd`
2. require the resolved path to lie inside the registry-derived writable root
3. install the Landlock ruleset built **from the registry root**
4. change into the directory
5. `exec`

If `cwd` is absent, the derived root applies.

**Step 4 must be followed by a re-check of `pwd -P` against the root, before step 5.**
Resolution at step 1 (`realpath -e`, existence required) closes the window where a
symlink is planted at `cwd` *before* authorisation — the resolved, existence-checked
path is compared, not a lexical guess. It does not close the window between
authorisation and `exec`: a symlink swapped in at the already-authorised path after
step 2 and before step 4 would still redirect the `cd`. The re-check at step 4 catches
exactly that swap, inside the same enactment that installs Landlock — a check
performed anywhere earlier, or skipped, leaves the window open one step later than
where slice 2 closed it.

## `timeout` — TWO checks are missing, not one

§3 states that the broker caps `timeout` and that "resource authority does not belong to the caller".
Verified by calling the PDP directly rather than by reading it, that assurance is **unimplemented** — not false as a contract statement, since the broker it describes does
not exist yet, but nothing in today's path provides it either:

- `cap_timeout` appears nowhere in the repository.
- The PDP does not check the **form** of `timeout` either: `1200`, `999999999999`, `-5` and `banana`
  all return `decision=allow`, and none of them reaches the verdict record. `sandbox`, `clearance` and
  `effort` all pass through a ranking function; `timeout` has no equivalent.

So the repair needs **two** additions to the PDP, not one:

1. a **form** check — digits plus a range — which today exists only in `bin/launch-agent`;
2. the **cap**: a declared `cap_timeout` in the provider capability record and `min(requested, cap)`
   in the PDP, the shape already used for sandbox, tier and effort. **Never `max`.**

Building only the cap would move the wrong-house defect below rather than fix it.

## Assurances that must move with `authorize`

Slice 2 moves `authorize` behind the socket. Every assurance that lives only in `bin/launch-agent`
disappears silently at that moment, because the wrapper stops being the only entry point. The
following were established by calling the PDP directly, and are **not** enforced behind the seam
today. The inputs are given so that any reader can repeat the calls rather than take this on trust:

| Assurance | Where it lives now | What the PDP does today |
|---|---|---|
| refuse `sandbox=danger-full-access` | `bin/launch-agent` only | **clamps** to the capability and allows (`decision=allow`) — the clamp branch is even unit-tested |
| `timeout` numeric and in range | `bin/launch-agent` only | nothing; `banana` is accepted |
| `cwd` exists | `bin/launch-agent` only | nothing; a missing path, an empty string and `../../../../etc` all return `decision=allow`. `cwd` is unpacked and never referenced again |

Each of the three must exist behind the boundary before slice 2 is finished, or be recorded as
deliberately given up. Clamping and refusing are **not** the same decision: a clamp turns a request
for more authority into a quieter grant, a refusal ends it. Which of the two the boundary owes the
caller is a decision for slice 2, and it must be made explicitly rather than inherited from whichever
file happens to run first. This is the same distinction the narrowing rule above marks as its third
category, seen from the other end: a named mechanism is part of the settlement, not a dial to be
turned tighter.

## `label` — free text with a length cap and nothing else

Its only purpose is making an audit record findable. §3 says its form is checked and its content is
not, so this specification requires a length cap and no content rule. Two obligations follow from
carrying unchecked text:

- the **composer escapes it** on entry into the event stream;
- **consumers of the stream render free-text fields as untrusted**.

If `label` is absent the broker composes one. That is a default, not a rule: a label no human chose
makes the audit record harder to find, and findability is the entire point of the field.

## Response frame

Slice 1 was built on the same silent assumption named at the top of this document: that a response
is one block, sent once the whole answer exists. §2's `launch` returns `stream, exit_class,
event_ids` — the enacted provider's stdout/stderr as it happens, not after it finishes. Streaming
requires framing, and a shell variable cannot hold it: it cannot hold a NUL byte, and command
substitution strips trailing newlines, so any "collect the whole output, then count it" implementation
corrupts the byte count on exactly the input that makes the count matter. Chunking is specified below
for that reason, before it is built, so this is a decision rather than a silence discovered later.

**`aib_wire_write_response` stays the terminal-line writer.** It appends `end=<status>`
unconditionally. A response with enactment has a terminal line, but not at the top — reusing that
function to emit the verdict would put a terminal line in front of the chunks, and a client reading
to the first `end=` would stop there and treat the stream as already finished. The verdict lines are
written by a **separate prologue writer that never emits a terminal line.**

### 1. Prologue

Written once, immediately, before enactment starts:

```
decision=allow
code=0
effective_sandbox=workspace-write
effective_clearance=t2
effective_effort=high
effective_timeout=900
cwd=/srv/acme/ws
reasons=
decided_event_id=acme-main-42
enacted=yes
```

`decided_event_id` is in the prologue, immediately after the verdict lines, **not** in the terminal
section — it is known before enactment, because `commit(attempt.decided)` happens before the child is
spawned (§2 step 2). A client that loses the connection mid-stream still has the attempt id to
correlate its lost attempt against the event stream, which is the authoritative record; putting it
only at the end would strand exactly the client that most needs it, on exactly the connection that
failed. `enacted=yes` on every prologue in this section distinguishes it from slice 2's `enacted=no`
verdict-only response, which this section does not change.

### 2. Chunks

Immediately after the prologue, the provider's output is relayed as a sequence of chunks:

```
chunk_bytes=<N>

<exactly N opaque bytes>
```

repeated for as long as the provider produces output, and closed by:

```
chunk_bytes=0

```

(the zero-length closing chunk carries the same header-then-blank-line shape, with no bytes after
it). Chunk bytes are **opaque**: a NUL byte inside a chunk, or a chunk whose bytes happen to spell out
the literal line `end=ok`, are both legal and must not disturb the frame — a reader that counts bytes
never searches them for a separator. Both are fixtures, because a chunk containing `end=ok` is the
test that proves the reader counts rather than scans.

**Child bytes never pass through a shell variable.** The relay copies from the provider's pipe to the
connection through files or a counted byte copy (`dd`/`head -c`-shaped), never through `$( )` or
`read`, for the same reason chunking exists at all. This also means the **response direction does
NOT inherit the request reader's NUL rule**: `aib_wire_read_request` treats a NUL anywhere in the
frame as fatal, because the request is broker-controlled framing around caller-supplied lengths and a
NUL there can only mean a smuggling attempt. Provider output legitimately contains arbitrary bytes,
including NUL — the response direction opaquely relays exactly what the provider wrote, and nothing
about its content is ever inspected or rejected.

A declared `chunk_bytes=N` followed by fewer than `N` bytes and then EOF, with **no** `end=` line
after it, is **an incident, never a truncated success**. This is the same shape the terminal-line
invariant below already governs, stated explicitly here because a short body that merely looks
plausible is precisely the failure mode spike 1.3 measured: an empty reply with `rc=0` read as
success until a terminal line existed to contradict it.

### 3. Terminal lines

After the last chunk (`chunk_bytes=0` and its blank line), exactly one terminal record closes the
connection:

```
exit_class=ok
stage=provider
ended_event_id=acme-main-43
end=ok
```

`exit_class` is one of `ok | provider-failure | timeout | io-refused | aborted`
(`docs/CONTRACT-execution-binding.md` §8.1). Exactly one of `exit_code=` (the provider's numeric
status) or `signal=` (the forwarded signal name) follows, matching the shape
`aib_event_compose_ended_payload` already requires for the durable record. `stage` names which phase
of enactment the terminal status belongs to — see the "stage" field note in
`docs/CONTRACT-execution-binding.md` §8.1. `ended_event_id` is the `attempt.ended` event's own id,
committed causally bound to `decided_event_id` from the prologue. Then, always last:

```
end=ok | end=denied | end=error
```

`end=ok` on the response means **the broker did its job**, regardless of the provider's own exit
class — a provider that failed, timed out, or was aborted still gets `end=ok` if the broker
successfully observed and reported that outcome. `end=error` is reserved for a broker-side incident
during enactment itself (a stream-commit failure after the child has already been reaped, for
example) — the provider's own failure is `exit_class`, never `end`.

**Invariant: exactly one `end=` line per connection, and it is the last line written.** No frame this
section produces ever contains a second `end=`, and nothing after the first `end=` is meaningful — a
client may stop reading there. This invariant is what makes the short-chunk-then-EOF rule above
enforceable: any frame that closes without reaching an `end=` line, chunked or not, is definitionally
incomplete.

### Deny

A denied `launch` writes exactly the decided record and no enactment ever happens (§2 step 2 runs for
every verdict, allow or deny — codex-run.md §4 item 1). Its response has no chunk section:

```
decision=deny
code=3
reasons=unknown_agent
decided_event_id=acme-main-44
end=denied
```

Wire-level errors (malformed request, registry unavailable, registry misconfigured) keep the
slice-1/2 shape unchanged — a flat set of `reason=`/`detail=` lines and `end=error`, with no prologue
and no `decided_event_id`, because no verdict was ever reached.

### Detecting a disconnected client while the provider is silent

The broker side of this is a `poll(2)`-based liveness probe (`_aib_enact_conn_alive`,
`lib/aibobnet.sh`), run once per idle relay tick, that classifies the connection "gone" iff
`POLLHUP`, `POLLERR`, or `POLLNVAL` is set — never `POLLOUT`, which a writable socket reports
regardless of whether anyone is still reading it. This closes the general case (the client process
exits, or closes the socket outright) within one idle tick, without ever writing a probe byte onto
the wire — chunk bytes are opaque and counted, never invented for a liveness check.

**Accepted latency case, stated explicitly rather than left implicit:** a client that shuts down
only its own READ half (`shutdown(fd, SHUT_RD)`) while leaving the socket itself open is not visible
to this probe — the kernel does not surface that specific half-close to the writer via `poll(2)`.
Such a client is indistinguishable from one that is merely slow to read until the broker's next real
write discovers the failure on its own (`EPIPE`/`ECONNRESET`). A client abandoning a response in the
ordinary way — closing the connection, or shutting down its own WRITE half of what was already a
read-only reply channel — is caught by the probe; only the narrower "still open, deliberately not
reading" case falls back to next-write detection.

### The client-side reading rule

A connection that closes **without** an `end=` line — at any point, prologue, mid-chunk, or between
chunks — has exactly two causes from the client's side of the socket, and the client cannot tell
which without other evidence: the broker died mid-enactment (an incident on the broker's own account,
covered by the abort path this document does not otherwise specify), or the connection was never
served at all because `MaxConnections` (`deploy/systemd/aib-broker.socket`) was already at its cap
when the socket accepted and then closed it — spike 1.4's measured behaviour, indistinguishable at
the wire from a crash. A client MUST treat "closed without `end=`" as a hard failure in both cases; it
is not entitled to assume success from an empty or partial reply, and this document does not obligate
the broker to make the two causes distinguishable at the wire in this slice.

## What this specification deliberately does not decide

- The path resolution mechanics in Bash.
- Whether the confinement helper is a compiled binary or a namespace wrapper.
- Anything about slices beyond the launch path.

## Provenance

The classification, the narrowing rule and the registry-derived positive list come from an
architecture consult; the framing question that prompted them was posed wrongly by the maintainer,
and the advisor said so first. The empirical statements above were produced by a separate reviewer
calling the code, not by the author of this document.

Working notes behind both live outside this repository and are deliberately not linked: a citation a
reader cannot resolve is not evidence. Everything asserted here is either reproducible from the
inputs given or visible in this repository's own source.
