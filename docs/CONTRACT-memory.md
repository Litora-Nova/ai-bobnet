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

## 2. Source of truth = append-only journals (pure bash/awk, no external deps)
Paths are **registry-authoritative** (never env-trusted), same discipline as P0/P1:
- `agent`   → `<standup_dir>/memory/agent/<agent_uid>.md`
- `project` → `<standup_dir>/memory/project.md`   (`standup_dir` = the caller's project, via `bin/context`)
- `shared`  → `<shared_memory_dir>/shared.md`, where `shared_memory_dir` is resolved from a registry
  top-level key. **Fail-closed:** a `--scope shared` op with no `shared_memory_dir` configured dies loud
  (no silent fallback, no guessed path).

Record line (on `propose`):
`TS | id:<id> | scope:<agent|project|shared> | author:<uid> | key:<key> | state:PROPOSED | <body>`
Event line (transitions):
`TS | id:<id> | event:<REVIEWED_ACCEPT|REVIEWED_REJECT|PROMOTED> | by:<uid> [| note:<note>]`

A memory's current state = the fold (last event) over its `id`. A SQLite index is an OPTIONAL future
accelerator — the file journal is authoritative.

## 3. Commands — `bin/memory <sub>`
- `propose --scope <agent|project|shared> [--key <k>] "<body>" [--id <id>]`
  → validate scope + resolve journal, append `PROPOSED`, print the `id`. (`agent` scope is trusted-for-self
  immediately; `project`/`shared` await review.)
- `review <id> <accept|reject> ["<note>"]` → append `REVIEWED_ACCEPT|REVIEWED_REJECT` (`by` = own agent_uid).
  Reviewer MUST NOT be the author (builder ≠ reviewer, same doctrine as gates). `agent`-scope items are
  not reviewable (author-private).
- `promote <id>` → append `PROMOTED`. **Only** from an accepted-reviewed state; promoting an unreviewed or
  rejected id dies loud. Idempotent (double-promote = no-op).
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
- `id` is unique; re-`propose` with an existing id = no-op (dedup). `promote`/`review` on an already-terminal
  or already-applied id = no-op. Retries never double-fire.
- Explicit IDs; no `date +%N`-random guessing for identity. Pure bash/awk; fail-closed (exit 3 unresolved /
  exit 5 ambiguous) + fail-loud on every refusal, per P0.

## 6. Promotion = the trust gate (why "with trust")
Promotion is the moment memory becomes *collectively trusted*. It is deliberately a two-step, two-actor
path (`propose` by author → `review accept` by a **different** agent → `promote`) so a single agent cannot
unilaterally inject "fact" into project/shared recall. This is the memory analogue of the merge gate:
**author proposes, an independent reviewer accepts, then it is promoted.** Poisoned/rejected proposals stay
`REJECTED` in the journal (auditable, never recalled), never silently deleted.

This guarantee is currently **CLI discipline inside the cooperative-with-audit trust boundary**, not
hostile-writer integrity. The journals are ordinary project files; an actor that bypasses `bin/memory`
and writes a forged event directly can bypass the two-actor workflow. The CLI enforces independent review
for callers that use it, while cryptographic/OS append integrity requires the future serialized writer.

## 7. Acceptance (P3 slice) — black-box, synthetic projects, example id `acme`
- **Scope isolation:** `agent`-scope proposed by `acme-core` is recalled by `acme-core`, and is **never**
  returned to `acme-tests`.
- **Promotion path:** `project` propose → third party cannot recall → independent `review accept` +
  `promote` → now every project agent recalls it. Author ≠ reviewer enforced (self-review dies loud).
- **Shared trust:** `shared` propose = candidate (invisible cross-project) → review+promote = published
  (recallable cross-project). Missing `shared_memory_dir` ⇒ fail-closed, loud.
- **Poisoning contained:** a rejected proposal never surfaces in `recall`; remains auditable in the journal.
- **Idempotency:** double-propose (same id) = one record; double-promote = no error/effect.
- **Governance untouched:** memory is never consulted for routing/identity/tier — verified by construction
  (no `bin/memory` call in `bin/context`/`bin/inbox`/`bin/message`).
- Pure bash/awk, no external deps; fail-closed/fail-loud per P0.

---
White-label: example id `acme`; no real names, infrastructure, or hosts.
