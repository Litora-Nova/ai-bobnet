# ADR-006: `high_water` Anchor Location and Absence Semantics; Global-Per-Project Capacity by Leases

## Status

Accepted

## Date

2026-09-07

## Context

`docs/CONTRACT-mediation.md` §5/§5.1 specified `high_water` as a self-check, not a boundary — it
catches accidental truncation or replacement and broker-internal defects, never a host account with
root — and fixed the append→fsync→anchor→fsync ordering and its two distinguishable failure cases
(`a > m` fails closed, `a < m` advances with a lag line). §5/§5.1 deliberately left the anchor's
storage location, its absence behaviour, and any capacity control unspecified: "no predecessor" (§7)
— `high_water` did not exist before this slice. ADR-0004 built the framed stream without an anchor,
noting a same-trust-domain anchor "only helps against accidents while doubling the write-path failure
modes" and deferring it to RM-3, where a broker owns it in a different trust domain (ADR-0005 built
that different trust domain). This slice is that deferred close, plus the admission-control question
`docs/CONTRACT-mediation.md` §6 raised in passing ("connection limits are part of this requirement":
`MaxConnections` on the socket) and never resolved below the socket level.

A maintainer design note (`standup/_design_rm3-slice5.md`, v1) proposed a fixed-name anchor, a
per-agent cap defaulting to 1, and unconditional anchoring on every `aib_event_commit` caller. An
architecture consult (`standup/_advisor_rm3-slice5.md`) reviewed it against the running code
(`aib_event_commit`, `_aib_event_scan_core`, `aib_event_stream_paths`, `_aib_resolve_binding_field`,
`_aib_verdict_deny`, `bin/aib-broker-handler`) and found five corrections to the anchor (F1–F5), one
finding that changed the slice's scope (F6: a fixed-name anchor unconditionally active on the
in-process wrapper is a permanent fail-closed brick, because `standup/` is git-tracked in this fleet
and `events/` appears in no `.gitignore` — a `git clean`, stash, or restore shortens `main.events` and
every subsequent launch in that project fails closed forever, with no repair defined), and a rejection
of the per-agent cap as specified (F9/F10: not implementable against `_aib_resolve_binding_field` as
written, and — worse than merely evadable — a denial-of-service primitive against a named agent, plus
a log- and lock-amplification primitive, at default 1). This ADR records the design revised against
that consult (`standup/_design_rm3-slice5.md`, v2, decisions H1–H8).

## Decision

### A. The `high_water` anchor

**Location.** The anchor path is derived from the stream path handed to `aib_event_commit`, never a
fixed name: `<events_path>.high_water`, sibling to the stream and its `<events_path>.lock` — the same
sidecar convention the lock already uses. A name hardcoded to the stream's *directory* would make two
streams that ever share a directory share one anchor, producing a guaranteed false `a > m` and a
permanent fail-closed the moment a second caller (a test fixture, a future stream) shares that
directory. Deriving it from the argument the function already receives closes that off structurally.

**Where it is active.** `aib_event_commit` gains an anchor mode, off by default, so the same function
serves both the broker's commit path and the wrapper's without a caller-specific fork:

- **The broker handler (`bin/aib-broker-handler`) always requests the anchor.** Its event root
  (`AIB_EVENT_ROOT`, ADR-0005) is broker-owned state, outside every project `home`, never git-tracked,
  and §5 already concedes the anchor's only threat model — an actor who can truncate the stream but
  not the anchor — is empty against a host account with root, so nothing about *this* deployment
  weakens by anchoring unconditionally.
- **The in-process wrapper (`bin/launch-agent`) does not anchor by default.** Its stream lives under
  `<standup_dir>/events` (ADR-0004's original location, unaffected by ADR-0005), and in this fleet
  `standup_dir` is a git-tracked directory (283 files under `~/Sites/Claude-tools/standup` at the time
  of the advisor's audit, `events/` absent from every `.gitignore`). An ordinary `git clean -fdx`, a
  stash, a branch switch, or a restore from backup shortens or replaces `main.events`; a defaulted-on
  anchor then reports `a > m` and fails every subsequent launch in that project closed, permanently,
  with §5.1's ordering giving no path back. Defaulting the anchor on in that deployment converts an
  accident-detector into an outage generator. Opt-in via `AIBOBNET_EVENT_ANCHOR=1` lets a
  single-trust deployment that keeps its stream out of version control choose the self-check;
  documented honestly, per §7, as *available*, not default, in single-trust deployments.

The **mechanism** is a 7th, optional positional argument to `aib_event_commit`:

```text
aib_event_commit <events_path> <lock_path> <event_type> <envelope_kv> <payload_json> [decided_event_id] [anchor_mode]
```

`anchor_mode` literally `anchor` enables anchor maintenance for that one commit call; any other value,
including absent/empty, means "commit exactly as today, no anchor file touched." The broker handler
passes the literal string `anchor` on every call, unconditionally. The wrapper passes `anchor` only
when `AIBOBNET_EVENT_ANCHOR=1` is set in its own process environment, otherwise it passes nothing —
the existing 6-argument call sites in `bin/launch-agent` keep working with no anchor semantics unless
an operator opts in. This is a proposal fixing the call shape the RED spec pins; the builder implements
it to this signature, not a different one, because the spec below asserts against it positionally.

**Durability.** Both writes happen inside the existing commit-path `flock`, in this order, extending
§5.1's `append → fsync → anchor → fsync`:

1. scan (existing) → torn-tail truncate (existing) — **then**
2. **anchor check** (below) — this position is what makes §5.1's "tail truncation cannot produce a
   false `a > max`" hold in this implementation: an uncommitted tail was never counted toward `max` in
   the first place, so truncating it before the check can only ever lower `max`, never raise it past
   the anchor
3. compose → append (existing)
4. `sync -d <events_path>` — `fdatasync` semantics: for an append to an *existing* file this is the
   right and sufficient call, cheaper than a full sync because the file's own data is already durable
   metadata
5. write the anchor value to a **temp file in the same directory**, **full `sync` (fsync, not
   `-d`) on that temp file**, `rename(2)` over `<events_path>.high_water`
6. `sync <dir>` — directory fsync, so the rename itself survives a crash

Step 5 uses a full fsync, not `fdatasync`, because the anchor file is freshly created on first write
(and on every reanchor): for a brand-new inode the conventional and safe shape is
fsync(temp) → rename → fsync(dir), not `fdatasync`, which only guarantees the data of an *existing*
file. This is load-bearing, not a nicety — it is the reason H3's "an empty or non-integer anchor is an
incident, refuse" is safe to state at all: without the temp file being fully durable before the
rename, the classic zero-length-file-after-crash outcome reintroduces exactly the per-crash brick
§5.1's ordering decision exists to avoid. The two decisions cannot be adopted separately.

**Capability check.** `sync` accepting file arguments (GNU coreutils ≥ 8.24) is probed with
`command -v sync` plus a capability check **at `aib_event_commit`'s own entry**, alongside the
existing `flock`/`cksum` checks — never at library load. Failing at load would turn a commit-path
dependency into a load-path dependency and brick every read-only consumer that merely sources
`lib/aibobnet.sh` (the fold, `bin/attempts`, the dashboard, the specs) on a host without a suitable
`sync`. The check fails closed with `aib_die 6`, the existing missing-runtime-dependency code, and
**never falls back to argument-less `sync`**: bare `sync` returns 0 and flushes the whole system,
which would make a broken capability probe read as "satisfied" while the durability claim above is
silently false.

**Anchor check** (`a` = anchor value, `m` = `AIB_EVENT_SCAN_HIGHEST_SEQ` after the torn-tail
truncate), only when `anchor_mode` is active:

| Anchor state | Behaviour |
|---|---|
| `a > m` | refuse the append; journal the discrepancy; the wire answer is `end=error reason=event_store_unavailable` — the same reason the handler already uses for every other event-store incident, so the caller does not need a new reason to recognise this as "the broker cannot record this attempt" |
| `a < m` | advance the anchor to `m`; one journal lag line; proceed |
| `a == m` | proceed |
| absent (file does not exist) | **create** the anchor at `m`; log once as a migration (§7's "no predecessor" case, restated per-stream: the first anchored commit against an existing stream accepts that stream as authentic) |
| corrupt (non-integer content, or empty) | **incident, refuse** — never silently reset. Safe only because of the temp-file fsync above: a torn write can never produce an empty durable anchor file, so an empty file observed here is evidence of tampering or a bug outside this code path, not a benign race |

**A documented, human-initiated repair is required before this ships**, not deferred: `bin/anchor
<events_path> {status|reanchor [--accept-truncation]}`.

- `status` reads the stream (read-only scan, no lock held across both reads — see the RED spec's
  atomicity notes) and the anchor file, and reports both values and the relationship between them
  (`ok` / `lag` / `ahead` / `absent` / `corrupt`), without mutating either.
- `reanchor` rewrites the anchor to the stream's current highest committed `seq`, **only** given an
  explicit `--accept-truncation` flag on the command line — never automatic, because an automatic
  repair is definitionally the same as having no anchor at all. It takes the stream's own lock (so it
  cannot race a concurrent commit), writes one journal line naming the operator (`$USER`) and the old
  and new anchor values, and — this is the point of the tool's name — **never touches the stream
  itself**, only the anchor file, using the same temp+fsync+rename discipline as the commit path.
  Human-initiated only; `aib_event_commit` never calls it, and no other code path may.

**What §5 already conceded, restated where it matters.** F5 (the consult): "absent → create at m" is
correct and does not widen §5.1's crash window — that window is about a crash *between* one commit's
append and its own anchor write, per-commit, and first-run adoption is a single, one-time acceptance of
the existing stream as authentic. But it is also true that *deleting* the anchor file is a free
re-anchor at any `m`, since absence always re-creates rather than refusing. In the broker deployment
the anchor's directory is broker-owned (root-equivalent access only), already conceded by §5's own
threat model. In a single-trust deployment that opts into `AIBOBNET_EVENT_ANCHOR=1`, the directory is
agent-owned, so the agent the anchor would be watching can reset it. Documented here so a reader of §5
("catches accidental truncation or replacement") does not believe that holds in the one deployment
where the anchor is owned by the thing it would be watching.

**What the anchor does not do.** When a refusal happens at the `attempt.ended` commit — after the
provider already ran — the anchor stops the *next* launch, never unwinds the one in progress. The wire
still gets a terminal line: `aib_enact_launch` writes its own `end=error` and the handler exits 2, so
this is not a new "closed without `end=`" cause (`docs/SPEC-wire-format.md`'s two-cause rule is
unchanged, see part C below). But the audit consequence — a decided record whose attempt can never be
closed by that same commit call — is a real outcome of a fail-closed anchor at that specific commit,
stated here rather than left to be discovered.

### B. Global-per-project capacity, replacing the per-agent cap

**The per-agent cap is dropped, not merely re-tuned.** The consult's F9 finding: under
`docs/CONTRACT-mediation.md` §4, an agent asserting another agent's `agent_uid` does not just receive
that agent's clearance (§4's existing, accepted limitation) — with a *per-agent* admission cap it
additionally *consumes that agent's slots*, denying the victim's own legitimate launches with a
concurrency error recorded in the audit stream under the victim's own `agent_uid`. At the per-agent
default the design note's v1 proposed (1), a single held connection is sufficient — a targeted
denial-of-service primitive against a named agent that does not exist in this system before this
slice. A second amplification compounds it (F9): an over-cap attempt under the v1 design was not a
cheap refusal — it still forked a handler, read the registry, ran the PDP, took the stream lock, and
wrote a durable record, so a capped caller in a connect loop converted a request rate it already had
into unbounded audit growth and lock contention on the one lock every launch in the project needs.

F10 additionally found the per-agent cap **not implementable as specified**: reusing
`_aib_resolve_binding_field` for a `max_attempts` field does not have the fallback the design assumed
— that resolver `aib_die`s when a field is absent at agent, team, and project levels, so every agent
that had not declared the new field would turn every launch attempt into a broker incident fleet-wide.

**What replaces it: a capacity ceiling shared by every agent within one project**, checked by a lease
count, before the registry is ever read for that connection:

- **Scope: per project, shared across all its agents — not global across the whole broker, and not
  per-agent.** Leases for one project's attempts live at
  `<AIB_EVENT_ROOT>/<project_uid>/attempts/` — the same per-project events directory
  `bin/aib-broker-handler` already computes as `_event_dir` (ADR-0005) — so the count and the ceiling
  are project-scoped. "Global" in this slice's design note means *global across agents*, replacing a
  cap that (as F14 observed) would otherwise read as fleet-wide while actually being per
  `(project_uid, agent_uid)`; it does not mean one number shared across every project on the broker.
  `AIB_BROKER_CAPACITY` names one ceiling applied identically to each project's own lease directory.
- **Known: `project_uid` is available before any registry read.** The wire reader already validates
  `agent_uid` through `aib_validate_agent_uid` before publishing it (lowercase/digit/hyphen, no
  leading/trailing/doubled hyphen, `<project_uid>-<agent_key>` shape) — rejecting a malformed token
  before anything downstream sees it (consult F15). The capacity check derives `project_uid` from that
  already-validated prefix, syntactically, the same way `_aib_split_agent_with` later derives it
  authoritatively from the registry — it does not open the registry to learn where to look. This is the
  invariant that makes "no registry read" possible for an over-capacity answer, and the RED spec pins
  it explicitly so a later refactor that moves admission ahead of validation, or accepts a project scope
  from another source, cannot silently open a path into broker-owned state.
- **Mechanism: a `flock`-held lease file per live attempt**, `<project_uid>/attempts/<agent_uid>.<n>`,
  `<n>` the smallest free index below the cap (not a monotonic counter — an ever-growing counter would
  make the directory and the stale scan grow unbounded over the broker's lifetime). Every step —
  opening the lease file, taking its exclusive `flock`, counting how many of the directory's lease
  files cannot be locked with `flock -n` (a file whose lock *can* be taken is stale — no live holder —
  and is removed as part of the same pass), and creating the new lease file if under capacity — happens
  while a small `<project_uid>/attempts/attempts.lock` is held. This closes the unlink/recreate race
  where one connection removes a stale name while another is mid-open on the old inode and both end up
  believing they hold a slot (consult F7a). There is no TOCTOU between the count and the decided commit
  either way: the lease is already created and flocked, under `attempts.lock`, before that lock is
  released — nothing another connection does afterward can invalidate an admission already granted
  (F8).
- **Lock order is total and one-directional: `attempts.lock` → the stream's own lock, never the
  reverse.** This is a standing invariant for any future change to this path, not just this slice's
  code — the symmetric-looking move of folding admission into the stream commit (the way H4 folds
  anchor maintenance into `aib_event_commit`) would invert this order and deadlock. Recorded here so
  that refactor has something concrete to run into before it ships.
- **The lease file descriptor must not reach the provider child.** Verified against this host's bash:
  `exec {fd}>>file`'s descriptor is **not** close-on-exec by default — a leaked fd 10 survived into an
  exec'd child in the consult's own reproduction. The confined enactment path is saved only by the
  pre-exec fd-hygiene loop already present in `_aib_enact_exec_child_confined`
  (`lib/aibobnet.sh`), which enumerates `/proc/self/fd` in the child before `exec` and closes every
  descriptor except 0/1/2/9 — the lease fd, whatever number it lands on, is closed by that existing
  loop with no change to it required. Any enactment path that lacks that loop would hand the provider a
  writable descriptor into broker-owned state, the exact capability crossing slices 3–4 exist to close,
  and a leaked fd would also pin the lease for the lifetime of any descendant that inherited it — this
  is stated as a hard requirement on any future enactment path, not merely a nicety of the existing one.
  A lease held by a handler that is `SIGKILL`ed (which fires no cleanup trap) is released by the kernel
  the instant the process's last fd closes — no different from the general lock/lease-release behaviour
  already relied on elsewhere in this codebase.
- **Answer, and its cost.** Over capacity: `end=error reason=over_capacity`, handler exit 2 — **no
  registry read, no PDP call, no stream lock taken, no `attempt.decided` record written.** A broker that
  cannot admit a connection is an incident being reported cheaply, not a policy decision being recorded
  expensively; this is what removes F9's second amplification (a capped caller converting a connect loop
  into unbounded audit growth and lock contention) rather than merely lowering its odds.
- **Default and validation.** `AIB_BROKER_CAPACITY` comes from the unit environment (never
  request/registry-supplied, the same restriction already stated for `AIB_EVENT_ROOT` and
  `AIB_CONFINE_BIN`). Unset defaults to **12**. A configured value at or above the socket's
  `MaxConnections` (`deploy/systemd/aib-broker.socket`, currently 16) is refused at handler start with a
  journal line, never silently clamped — because the whole point of this ceiling is to answer honestly
  *below* the point where the socket itself would silently close the connection, and a capacity at or
  above that point can never be reached. **Ambiguity flagged for the maintainer:** the handler process
  has no direct way to read the socket unit's `MaxConnections`; this ADR and the RED spec model that
  self-check against a second, mirrored unit-environment variable, `AIB_BROKER_MAX_CONNECTIONS`
  (deploy sets it to the same value as the socket's `MaxConnections`, 16), rather than inventing a
  mechanism that reads the socket unit file at runtime. This is Homer's resolution, not a decision
  H1–H8 named explicitly — the maintainer should confirm it or specify a different mechanism before the
  builder implements it.

### C. Docs

- `docs/SPEC-wire-format.md` — **not** a sibling of the "closed without `end=`" rule (that rule
  describes a connection that produces *no* terminal line at all; an over-capacity answer produces an
  ordinary `end=error` terminal, which is not that case — consult F13). The correct edit is additive:
  `over_capacity` joins the set of `reason=` values a caller may see on `end=error`, documented next to
  `event_store_unavailable`, with the same "no verdict was ever reached" framing wire-level errors
  already carry. The two-cause "closed without `end=`" rule itself is untouched; `MaxConnections`
  remains the only path that produces no terminal line at all.
- `docs/CONTRACT-execution-binding.md` — anchor semantics for the in-process path: §8 gains a
  subsection stating the wrapper's opt-in-only default, the reason (the git-tracked `standup/`
  hazard, F6), and a pointer to `bin/anchor` as the only sanctioned repair.
- `docs/CONFINEMENT.md` — the "Runtime dependencies" section gains `sync` (with file arguments,
  GNU coreutils ≥ 8.24, probed at `aib_event_commit` entry, never a bare-`sync` fallback), alongside
  the already-listed `flock` and `truncate` — grouped as commit-path dependencies the broker's
  confined-launch systemd unit must have installed, distinct from the confined *child's* own runtime
  dependency list this section otherwise documents.
- `deploy/systemd/aib-broker@.service` gains `Environment=AIB_BROKER_CAPACITY=12` and (per the
  flagged ambiguity above) `Environment=AIB_BROKER_MAX_CONNECTIONS=16`, both commented with the
  `< MaxConnections` rule and a pointer to `deploy/systemd/aib-broker.socket`'s own `MaxConnections=`
  line as the value that must be kept in sync by hand.
- `docs/CONTRACT-mediation.md` — **zero diff.** Nothing above requires changing the frozen contract;
  §5/§5.1 already specified the ordering and the two-case table this slice implements, and §6 already
  named connection limits as part of the transport requirement without specifying the mechanism below
  the socket.

## Alternatives Considered

### A fixed anchor filename per directory

Rejected (F1). A name that does not derive from the stream path makes any two streams sharing a
directory share one anchor, producing a guaranteed, permanent false `a > m` the moment that happens —
not a hypothetical, since the specs already pass fixture directories that could collide this way.

### `fdatasync` for the anchor's temp file

Rejected (F3). `fdatasync` guarantees a file's data and only the metadata needed to read it back; for a
brand-new inode that is not sufficient — the classic failure mode is a zero-length file surviving a
crash, which is indistinguishable from the "corrupt, refuse" case this ADR treats as an incident. A
full fsync before the rename is what makes treating an empty anchor as an incident (rather than a
benign race) a safe thing to assert.

### Capability-checking `sync` at library load

Rejected (F2). `lib/aibobnet.sh` is sourced by every consumer, including read-only ones (`bin/attempts`,
the dashboard, every spec file). A load-time hard failure would brick all of them on a host missing a
suitable `sync`, even though only the commit path needs it — the established pattern in this file
(`flock`, `cksum`) is a commit-entry check, and this follows it.

### Per-agent capacity cap, default 1

Rejected (F9, F10). Not implementable against the existing binding resolver without inventing a
tolerant variant nobody asked for, and — independent of that — it converts an uncontested assertion
weakness (§4) into an active denial-of-service and audit-amplification primitive against a specific,
named victim agent, at the smallest possible cost to the attacker. A global-per-project pool removes
the "aimed at a victim" property entirely: consuming a slot burns from the same shared pool the
attacker's own launches draw from.

### Folding admission into `aib_event_commit`, symmetric with the anchor's H4 treatment

Considered and rejected for this slice. It is a tempting symmetry — "the commit already holds a lock,
put admission there too" — but it inverts the lock order this ADR fixes (`attempts.lock` →
stream lock, never the reverse) and would deadlock against any caller that already holds the stream
lock while attempting to also take a lease. Kept as two separate mechanisms with a stated, one-directional
ordering instead.

## Consequences

- The anchor closes the gap ADR-0004 explicitly deferred: whole-suffix or whole-file replacement of the
  broker's own stream is now detected (broker deployment; opt-in elsewhere), where RM-2 could only
  detect torn tails, marker faults, and inner seq gaps.
- **New commit-path runtime dependency**: `sync` with file arguments (GNU coreutils ≥ 8.24), checked at
  `aib_event_commit` entry, `aib_die 6` on absence — joining `flock` and `cksum` there, and `truncate`
  on the torn-tail path.
- **Latency inside the commit lock increases.** Three synchronous fsyncs (`sync -d` on the stream,
  `sync` on the anchor's temp file, `sync` on the directory) now run inside the same critical section
  the existing `flock -w` timeout (currently 10s, stable exit 75 on expiry) was tuned against a
  critical section with no disk sync at all. This ADR does not carry a measured number for the new
  worst case; the builder should measure it against the deployment's actual storage before this ships
  to a loaded fleet, and revisit the timeout constant if it is not comfortably clear of the new
  fsync-inflated worst case.
- **A new human-operated tool, `bin/anchor`.** Its `reanchor --accept-truncation` path is the only
  sanctioned way to recover a wrapper deployment whose stream was legitimately shortened outside the
  broker's own commit path (a `git clean`, a restore, a deliberate truncation) — without it, F6's
  finding stands: an opted-in wrapper anchor with no repair is an outage generator, not a self-check.
- **Capacity answers a class of request more cheaply than before**: an over-capacity `launch` now costs
  one lease-directory lock, one `flock -n` scan, and a wire write — no registry read, no PDP call, no
  stream lock, no durable record — where the rejected per-agent design would have cost all of those on
  every rejected attempt.
- **Known limits, stated rather than hidden**: the anchor remains, exactly as §5 already says, useless
  against a host account with root — the set of actors who can truncate the stream but not the anchor
  is still empty. `AIB_BROKER_CAPACITY` is a fairness/incident-cost control, not a security boundary;
  §4's underlying assertion weakness (an agent naming another agent's `agent_uid` receives that agent's
  clearance) is unchanged by this slice, only the specific DoS/amplification primitive the v1 per-agent
  cap would have added on top of it is what this ADR removes. The `AIB_BROKER_MAX_CONNECTIONS`
  self-check variable this ADR proposes (part B) is Homer's resolution of an underspecified mechanism,
  flagged for the maintainer's confirmation before the builder implements it.
- **Still specified, not built** (this slice remains docs + RED spec only): `aib_event_commit`'s 7th
  argument, `bin/anchor`, the lease mechanism in `bin/aib-broker-handler`, and every library change the
  RED spec's failing assertions name.

This ADR extends ADR-0004 and ADR-0005; it reverses neither. `docs/CONTRACT-mediation.md` §5/§5.1's
ordering and failure-case table are implemented here exactly as specified, not renegotiated.

---
White-label: example project id `acme`; no real names, infrastructure, or hosts.
