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

> **A validator may be stricter than the contract, never looser.**

§6 requires token fields to be "validated against the existing token rules". That is a **floor, not a
ceiling**. An enum check on `sandbox` and a digits-plus-range check on `timeout` *narrow* the token
rule; they do not replace it. Narrowing has never been a contract violation — only loosening would
be. Whenever a new field appears, this sentence answers "do we need to change §6?" without a debate.

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
`cwd`, `label`, `prompt`. A block whose `<field>_bytes` header is absent is absent from the stream.

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

## `timeout` — the cap the contract promises must exist

§3 states that the broker caps `timeout` and that "resource authority does not belong to the caller".
For that sentence to be true, a declared `cap_timeout` belongs in the provider capability record, and
the PDP applies `min(requested, cap)` — the same shape already used for sandbox, tier and effort.
**Never `max`.**

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

Advisor consult, 2026-08-15 (`standup/_arch_wire_fields_tim_verdikt.md`). The classification, the
narrowing rule and the registry-derived positive list are the advisor's; the framing question that
prompted them was posed wrongly by the maintainer, and the advisor said so first.
