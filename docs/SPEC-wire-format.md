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

**The qualifier is not decoration.** The contract also states **ceilings**, and there the sentence
inverts. §3 says `label` is checked for form but **not for content** — that is an upper bound, not
merely the absence of a lower one. A reader who applies "stricter is always allowed" to `label` and
adds a content check would violate §3 while believing they were being careful: exactly the mistake
this rule exists to prevent. So before invoking it, establish which kind of statement the contract is
making about the field. Floors take narrowing; ceilings do not.

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
file happens to run first.

## `label` — free text with a length cap and nothing else

Its only purpose is making an audit record findable. §3 says its form is checked and its content is
not, so this specification requires a length cap and no content rule. Two obligations follow from
carrying unchecked text:

- the **composer escapes it** on entry into the event stream;
- **consumers of the stream render free-text fields as untrusted**.

If `label` is absent the broker composes one. That is a default, not a rule: a label no human chose
makes the audit record harder to find, and findability is the entire point of the field.

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
