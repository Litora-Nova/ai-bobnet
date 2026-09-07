# ADR-0007: Visibility Projection — Location, Ownership, and Channel Choices

## Status

Accepted

## Date

2026-09-07

## Context

`plan/BobNet_3.0_ENTSCHEID_sichtbarkeit-und-vm-split.md` (PO decision, 2026-08-15) made a thin,
read-only visibility projection a pillar acceptance criterion and a precondition for production
go-live. A maintainer design note (`standup/_design_visibility-v1.md`, v1) proposed writing that
projection as `<standup_dir>/_projection.json`, broker-owned, mode `0664`, inside the same sticky
`root:aib-shared 3775` directory every agent already shares. An architecture consult
(`standup/_advisor_visibility-v1.md`, Tim) reviewed it against the running code
(`lib/aibobnet.sh:1888`'s `LL_RW` composition, `bin/aib-broker-handler`'s admission block,
`docs/decisions/0005-broker-event-stream-location.md`, `dashboard/server/utils/beats.mjs`) and found a
**NO_GO on Q1** (placement/mode/account) with four independent defects, each sufficient alone, plus
eleven further load-bearing findings (Q4) on the contract's content, capacity reading, timezone
handling, and failure semantics. `standup/_design_visibility-v1.md` v2 revised the design against that
consult (decisions P-A through P-L); this ADR records the placement/mechanism reasoning behind that
revision and the choices `docs/CONTRACT-visibility.md` builds on. `docs/CONTRACT-visibility.md` is the
what; this document is the why.

## Decision

### A. Placement: a broker-owned root outside every project `home`, exposed by symlink

**Rejected: `<standup_dir>/_projection.json`.** The consult's four defects, verified at the code:

1. `standup_dir` sits inside the project `home`, and `lib/aibobnet.sh:1888` composes `LL_RW` from
   `home` for the confined provider child (RM-3 slice 3). A broker-produced artifact placed there is
   writable by the very agent-directed computation it is meant to attest about — verbatim the argument
   `docs/decisions/0005-broker-event-stream-location.md` already made and fixed for the event stream.
   Placing the projection back under `home` reopens that exact hazard for a second broker-attested
   artifact, and it invalidates ADR-0005's own soundness clause ("`LL_RW` may safely contain `home`…
   because nothing the confinement minimum names lives under `home` any more") for the next reader who
   trusts that clause at face value.
2. A `0664` group-writable file in a directory every agent's account can write is rewritable **by any
   agent**, sticky bit or not — the sticky bit restricts unlink/rename, never write. An agent could set
   its own claimed state to `idle` or delete an attention item naming itself, inside a file meant to be
   the broker's attestation.
3. The standup directory's sticky bit turns **pre-creation into a permanent denial**: `rename()` over
   an existing destination in a sticky directory requires owning the destination, the directory, or
   `CAP_FOWNER`. The broker owns none of the three there. Any agent that creates the file name first
   permanently blocks every later atomic publish with `EPERM` — visible only as a `generated_at` that
   quietly stops advancing.
4. Untrusted parsing (heartbeat message bodies, directory filenames every agent can write) under the
   most privileged account reachable — `aib-broker` also owns the credential directory, the event
   stream, and the adapter map.

**Adopted: reuse the accepted ADR-0005 pattern rather than invent a new one.** The projection root is
broker-owned state, `AIB_PROJECTION_ROOT` (unit-environment-only, default `/var/lib/aib/projection`),
outside every project `home`, mode `0750`/`0640` (§B). `<standup_dir>/_projection.json` is a
**read-only symlink** into it, maintained by provisioning, exactly as `<standup_dir>/events` already
is for the stream — Landlock resolves symlinks to their target's own grant, so the confined child gets
whatever the target path allows, which is nothing writable once the target sits outside `LL_RW`
entirely. `docs/CONFINEMENT.md`'s §2.1 minimum list is amended by this ADR (and `CONTRACT-visibility.md`
§15) to name the projection root explicitly, the same amendment ADR-0005 made for the event stream and
the anchor — a deliverable of this slice, not a follow-up, for the same reason ADR-0005 gave: leaving
the amendment for later hands the same mistake to the next artifact.

### B. Mode, ownership, and atomic publish

`0664`/`root:aib-shared` group-write (the v1 proposal's stated reason: group *readability*, which
`0644`/`0750` already gives via the group without ever granting write) is dropped for the same reason
listed above. This ADR fixes, tighter than the consult's own `0644` suggestion:

- Directory `aib-broker:aib-shared 0750` — broker writes, shared group reads, no one else, and no
  group-write anywhere in the chain.
- File `<root>/<project_uid>.json`, mode `0640`.
- Publish via `mktemp` (in `AIB_PROJECTION_ROOT` itself, `O_EXCL`, random suffix) then `rename(2)`,
  never a fixed temp name — the consult's fixed-temp-name concern (a pre-planted symlink at a known
  temp path turns a broker write into an attacker-chosen write, `landlock-exec`'s own "TCB directories
  owned root, not the writer" reasoning applies identically here) is closed structurally: nothing fixed
  is ever opened for writing.

### C. Capacity: read the handler's own attested count, never probe

The consult's sharpest Q4 finding: `bin/aib-broker-handler`'s admission block *is* the live-lease
count — it takes `flock -n` on each lease file under `attempts.lock` and deletes the ones it wins. A
separate reader has only bad options: counting files over-reports (a holderless lease can linger by
design); probing with `flock` opens admission state for write and can make the handler's own `flock -n`
probe fail, causing a false `over_capacity` answer to a launch that should have been admitted. An
observability job that can cause launch denials is not read-only in any sense that matters.

**Adopted:** the handler already computes the live count under the lock it already holds; this ADR
requires it to also write that integer, atomically, to `$AIB_EVENT_ROOT/attempts/.live` on every
admission decision. The projector reads that one file and its mtime, and — this is the load-bearing
half — **never opens, locks, or lists any other file under `attempts/`.** `capacity.limit` comes from
the projector's own unit environment (`AIB_BROKER_CAPACITY`, mirrored from the broker unit), the same
mirrored-value pattern `docs/decisions/0006-anchor-and-capacity.md` already accepted for
`AIB_BROKER_MAX_CONNECTIONS`, with the identical, stated drift risk: nothing enforces agreement between
the two units' copies, and the deploy comment must say so.

### D. Heartbeat as the agent-state channel, with provenance added to the schema

Adopted with the consult's three notes folded in, verbatim in effect: an explicit `attested` field on
every `agents[uid]` entry and every `attention[]` item (`CONTRACT-visibility.md` §2); claim/attestation
disagreement folded into a `disagreement` attention item rather than one side silently overwriting the
other (§8 there); and the mechanical "does the pillar emit the contract's events" check written down as
not satisfied by free text alone once a pillar's state becomes genuinely broker-observable (§1.1
there). Amending the frozen `docs/CONTRACT-mediation.md` §2 ("`launch(request)` is the entire
agent-visible surface. One call.") to add a state-reporting operation is explicitly deferred — the
heartbeat is honest labelling of a real limitation, not a workaround, and the dashboard already parses
it.

### E. `needs:` plus derived attention, with the scope limit written down

Adopted with three notes folded in: the gate/approval/T4 kinds are declared, in the contract itself, as
things V-1 can only see an agent *declare* — no gate/grant state machine backs them yet
(`CONTRACT-visibility.md` §6); the inbox is explicitly out of scope, named rather than silently
uncovered (§6 there); an unrecognized `needs:` token becomes `kind: "other"` with the full original
message preserved, never dropped (§7 there). Where the consult flagged `human`/`input` as overlapping
and recommended picking one, this ADR keeps both, with a stated distinction (§7 there: `human` is
discretion, `input` is a missing fact) — the maintainer's read is that collapsing them loses a
real distinction agents will want, and the fallback (`other`) already protects against ceremony
mistakes either way. A future pillar that finds this unworkable in practice can revisit it by its own
ADR.

### F. Shared reader implementation and failure policy

The shell API `aib_attempts_fold` invokes one Python 3 process for the complete stream. The CRC
uses bit-order translation around zlib's C implementation, differentially checked against coreutils
`cksum`; per-record shell forks would miss the 10,000-record budget. A block-buffered `mapfile` handoff avoids quadratic Bash string replacement when returning large folds. `bin/attempts` formats the same
ordered fold as before, while `bin/project` applies the frozen visibility schema's corruption policy.
No writer or admission path calls this reader.

The shipped pins needed two fixture corrections: a dateless line labelled "non-last" was actually
last (and `beats.mjs` borrows its old mtime without marking it stale), and the fold-global assertion
ran its fold inside a command substitution where assignments cannot reach the caller. The corrected
pins test the actual parser rule and invoke the fold directly before inspecting its globals.

The handler samples `.live` before allocating its new lease. Sample publication is best-effort:
a write failure leaves the previous value and diagnostic, preserving every existing admission answer.
The projection's schema-1 decisions for degraded streams, malformed anchors, multiple attempts,
undatable attention and `--stdout` are stated in CONTRACT-visibility's implementation notes.

## Alternatives Considered

### Handler-triggered projection instead of a timer

Rejected. Most of what this projection reports — staleness, presumed-dead, "blocked since" — is
time-derived, not event-derived. A commit-triggered refresh is freshest during launches and staleest
exactly when the fleet is idle or blocked, which is the operator's main case for looking. It would also
put observability in the request path (a slow or failing projection becomes a slow or failing launch),
and denied/over-capacity requests never reach the point in the handler where a commit-triggered refresh
could even fire (`bin/aib-broker-handler` answers and exits before that point), so exactly the cases an
operator most wants to see would not trigger a refresh. A post-commit *nudge* as a pure accelerator
(a stamp file, a `systemd.path` unit) remains available as a future addition; it must never become the
only trigger and must never block the handler.

### A distinct `aib-projector` account from day one

Considered, deferred. The consult's Q1 finding #4 recommends a distinct low-privilege account with read
on the event root and standup dirs and write only on the projection root, so a process parsing hostile
agent text is not simultaneously the account that owns the credential directory. V-1 keeps
`User=aib-broker` (the same account the event stream and anchor already trust) and hardens the unit
instead: `InaccessiblePaths=/var/lib/aib/auth`, `ReadOnlyPaths=$AIB_EVENT_ROOT`,
`ReadWritePaths=/var/lib/aib/projection` only, plus the standard `NoNewPrivileges`/`ProtectSystem=strict`/
`PrivateTmp` set every broker-family unit already carries. A separate account is recorded here as the
end state, not built in this slice — provisioning churn for a second system account is a real cost, and
the hardened unit already closes the specific hazard (credential-directory reachability) the consult
named as non-optional.

### Enumerating standup dirs in the projection unit

Rejected, for the identical reason ADR-0005 rejected enumerating writable subtrees under `home`: a
project added to the registry would get no projection until someone edited the unit, silently. The
unit points at one root; the project list comes from the registry at every tick.

### Spine event types for agent state, built now

Rejected for V-1, deferred by this ADR (§D above) rather than left implicit. Amending the frozen
mediation contract for a channel the fleet already has, that the dashboard already renders, is the
wrong trade at this size — see §D.

## Consequences

- `docs/CONFINEMENT.md`'s §2.1 minimum list gains the projection root, alongside the event stream, the
  anchor, the registry, and the adapter map.
- `deploy/systemd/aib-projection.service` and `aib-projection.timer` are new units, following the
  hardening shape `aib-broker@.service` already established, with `User=aib-broker` (§ "Alternatives
  Considered" above) and the mirrored-value drift risk on `AIB_BROKER_CAPACITY` documented in the unit
  comment, the same way `AIB_BROKER_MAX_CONNECTIONS`'s drift risk already is in `aib-broker@.service`.
- `bin/aib-broker-handler` gains one additional, atomic write per admission decision
  (`$AIB_EVENT_ROOT/attempts/.live`) — a small, fixed cost inside a critical section that already does
  more expensive work (§C above); it does not change any existing wire answer or exit code.
- `lib/aibobnet.sh` gains `aib_attempts_fold`, extracted from `bin/attempts`'s existing fold logic, with
  the die-or-report decision moved to each caller (`CONTRACT-visibility.md` §12). `bin/attempts`'s
  output must remain byte-identical after this extraction.
- **Known limits, stated rather than hidden:** the projection cannot see anything an agent does not
  declare through `needs:` and the broker does not itself detect (`CONTRACT-visibility.md` §6); the
  inbox, gate/grant state, and incremental folding are explicitly out of scope for V-1 and are follow-up
  ADRs, not silent gaps; `User=aib-broker` remains a broader trust boundary than the end-state
  `aib-projector` account this ADR names but does not build.

This ADR extends ADR-0005 and ADR-0006; it reverses neither.

---
White-label: example project id `acme`; no real names, infrastructure, or hosts in this repository.
