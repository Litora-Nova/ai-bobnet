# ai-bobnet — Memory Contract (P3: memory with trust)

Builds on P0 (`docs/CONTRACT.md`) + P1 (`docs/CONTRACT-delivery.md`). P0 made identity + "where"
deterministic; P1 made delivery provable. **P3 makes MEMORY trustworthy** — a scoped, promotable,
append-only store where nothing is trusted by default and shared knowledge is *earned* through review,
not assumed.

## 0. Non-negotiable invariant — memory never governs
Recalled memory is **advisory context only**. There is **no** engine path where a stored memory value
feeds identity resolution, routing, tier/governance, or delivery. Those come **only** from the registry
(SSoT) + the P0 resolver. `bin/memory` MUST NOT be wired into `bin/context`, `bin/inbox`, or
`bin/message` routing. A recalled memory is *data an agent may read*, never an *instruction the engine
obeys*. This mirrors the harness memory doctrine: recalled memory is background, not a directive.

## 1. Trust model — scope × lifecycle
A memory is a structured, ID'd record. Two orthogonal axes:

**Scope** (who it *could* serve): `agent` · `project` · `shared`.
**Lifecycle state** (how far it has *earned* trust): `PROPOSED → REVIEWED(accept|reject) → PROMOTED`
(+ `REJECTED` terminal), folded from append-only events exactly like P1's delivery state.

The plan's four buckets are `scope × state`:
| Plan bucket | = scope | at state |
|---|---|---|
| agent | `agent` | born trusted-for-self (author-private) |
| project | `project` | `PROMOTED` |
| shared-candidate | `shared` | `PROPOSED` |
| shared-published | `shared` | `PROMOTED` |

- **`agent`** scope = an agent's own private notes. Author-private, no review, trusted for the author only.
- **`project`** + **`shared`** = collective knowledge → must be **reviewed + promoted** before anyone
  other than author/reviewer may recall it. **Default-deny:** un-promoted collective memory is invisible
  to third parties (fail-closed).

## 2. Source of truth = serialized append-only journals
Paths are **registry-authoritative** (never env-trusted), same discipline as P0/P1:
- `agent`   → `<standup_dir>/memory/agent/<agent_uid>.md`
- `project` → `<standup_dir>/memory/project.md`   (`standup_dir` = the caller's project, via `bin/context`)
- `shared`  → `<shared_memory_dir>/shared.md`, where `shared_memory_dir` is resolved from a registry
  top-level key. **Fail-closed:** a `--scope shared` op with no `shared_memory_dir` configured dies loud
  (no silent fallback, no guessed path).

All memory mutations in one reachable namespace share one advisory lock. When `shared_memory_dir` is
configured, the lock is `<shared_memory_dir>/.aibobnet-memory.lock`; otherwise it is
`<standup_dir>/memory/.aibobnet-memory.lock`. The writer takes an exclusive `flock`, folds every journal
needed for the decision, revalidates the operation, and performs one checked append before releasing the
lock. This common lock makes the supported scope-aware collision scan and append atomic. Lock or append
failure is loud and never reported as committed.

With `shared_memory_dir` configured, the common lock is registry-wide on the host: every supported memory
mutation in every registered project takes it, including private agent-scope writes. A shared proposal's
ID collision scan reaches every registered project's private and project journals. If a narrower writer
used a separate lock, it could append between that cross-journal scan and the shared append, violating
scope-aware ID uniqueness. Serializing unrelated project and private writes reduces write concurrency and
widens the availability blast radius of a slow memory mutation. This is an accepted trade-off for atomic
cross-journal ID uniqueness in the file-journal design.

The collision set expands with the proposed scope:

- `agent` checks the caller's private journal plus the project and configured shared collective journals
  reachable by that caller.
- `project` checks every private journal in the caller's project plus that project's collective journal
  and the configured shared journal.
- `shared` checks every registered project's private and project journals plus the shared journal.

Two private journals owned by different agents are not jointly reachable for an `agent` proposal and may
reuse an ID. A later `project` or `shared` proposal fails loud if that ID occurs anywhere in its broader
collision set. IDs are therefore scope-aware, not globally unique across unrelated private journals.

Record line (on `propose`):
`TS | id:<id> | scope:<agent|project|shared> | author:<uid> | key:<key> | state:PROPOSED | <body>`
Event line (transitions):
`TS | id:<id> | event:<REVIEWED_ACCEPT|REVIEWED_REJECT|PROMOTED> | by:<uid> [| note:<note>]`

A memory's current state = the fold (last event) over its `id`. Read-only folds retain their existing
lock-free behavior and are not linearizable with concurrent commits. In particular, a multi-journal read
is not a coherent namespace snapshot and may observe journals at different commit points. The legacy line
grammar has no sequence, frame, or checksum. A SQLite index is an OPTIONAL future accelerator — the file
journal is authoritative.

## 3. Commands — `bin/memory <sub>`
- `propose --scope <agent|project|shared> [--key <k>] "<body>" [--id <id>]`
  → validate scope + resolve journal, atomically deduplicate and commit `PROPOSED`, then print the `id`.
  (`agent` scope is trusted-for-self immediately; `project`/`shared` await review.)
- `review <id> <accept|reject> ["<note>"]` → revalidate and append `REVIEWED_ACCEPT|REVIEWED_REJECT`
  in one locked commit (`by` = own agent_uid).
  Reviewer MUST NOT be the author (builder ≠ reviewer, same doctrine as gates). `agent`-scope items are
  not reviewable (author-private).
- `promote <id>` → revalidate and append `PROMOTED` in one locked commit. **Only** from an
  accepted-reviewed state; promoting an unreviewed or rejected id dies loud. Idempotent
  (double-promote = no-op).
- `recall [--scope <s>] [--key <k>]` → print the memories **trusted for the caller** (§4), newest-first,
  each clearly marked advisory. Never emits un-promoted collective memory to a non-author/non-reviewer.
- `state <id>` → current folded state (always observable).
- `list [--state <s>] [--scope <s>]` → list own + reviewable items (for authors/reviewers to see the queue).

## 4. Recall visibility (fail-closed, default-deny)
| caller | recalls |
|---|---|
| any agent | own `agent`-scope · own project's `PROMOTED` `project`-scope · `PROMOTED` `shared`-scope |
| the author | additionally their own `PROPOSED` (candidate) items |
| a reviewer | additionally `PROPOSED` items pending review in that scope |
Anything else (a third party's un-promoted proposal) is **never** returned. Default is deny, not allow.

## 5. Idempotency & determinism
- `id` is unique within the target scope's collision set for writers that use the supported command path;
  re-`propose` in the same journal with an existing PROPOSED id = no-op (dedup). `promote`/`review` on an
  already-terminal or already-applied id = no-op. The scope-aware collision check, lifecycle precondition,
  and append share the namespace lock, so concurrent compliant retries cannot both commit.
- Explicit IDs; no `date +%N`-random guessing for identity. Bash/awk plus util-linux `flock`;
  fail-closed (exit 3 unresolved / exit 5 ambiguous) + fail-loud on every refusal, per P0.

## 6. Promotion = the trust gate (why "with trust")
Promotion is the moment memory becomes *collectively trusted*. It is deliberately a two-step, two-actor
path (`propose` by author → `review accept` by a **different** agent → `promote`) so a single agent cannot
unilaterally inject "fact" into project/shared recall. This is the memory analogue of the merge gate:
**author proposes, an independent reviewer accepts, then it is promoted.** Poisoned/rejected proposals stay
`REJECTED` in the journal (auditable, never recalled), never silently deleted.

This guarantee remains **CLI discipline inside the cooperative-with-audit trust boundary**, not
hostile-writer integrity. The serialized commit path closes races between compliant concurrent callers,
but `flock` is advisory: an actor that bypasses `bin/memory` can ignore the lock and forge a journal event.
Cryptographic integrity and an OS-enforced writer boundary remain future work.

## 7. Acceptance (P3 slice) — black-box, synthetic projects, example id `acme`
- **Scope isolation:** `agent`-scope proposed by `acme-core` is recalled by `acme-core`, and is **never**
  returned to `acme-tests`.
- **Promotion path:** `project` propose → third party cannot recall → independent `review accept` +
  `promote` → now every project agent recalls it. Author ≠ reviewer enforced (self-review dies loud).
- **Shared trust:** `shared` propose = candidate (invisible cross-project) → review+promote = published
  (recallable cross-project). Missing `shared_memory_dir` ⇒ fail-closed, loud.
- **Poisoning contained:** a rejected proposal never surfaces in `recall`; remains auditable in the journal.
- **Idempotency:** double-propose (same id) = one record; double-promote = no error/effect.
- **Scope-aware IDs:** private journals for different agents may reuse an id; a project proposal rejects an
  id found in any private journal in its project, and a shared proposal rejects an id found in any private
  or project journal of any registered project.
- **Concurrency:** simultaneous proposals with one id commit at most one record within the applicable
  scope-aware collision set; simultaneous reviews/promotions are revalidated under the namespace lock.
- **Failure:** lock acquisition and append failures are loud and never reported as committed memory.
- **Governance untouched:** memory is never consulted for routing/identity/tier — verified by construction
  (no `bin/memory` call in `bin/context`/`bin/inbox`/`bin/message`).
- Bash/awk plus `flock` from util-linux; fail-closed/fail-loud per P0.

This prelude targets cooperative single-host processes and process-restart durability. It does not provide
framing, checksums, torn-tail detection, `fsync`/power-loss guarantees, cross-host coordination, or
exactly-once external effects.

---
White-label: example id `acme`; no real names, infrastructure, or hosts.
