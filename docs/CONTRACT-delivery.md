# ai-bobnet — Delivery Contract (P1: durable, provable message delivery)

Builds on P0 (`docs/CONTRACT.md`). P0 made identity + "where" deterministic; **P1 makes DELIVERY
deterministic and provable** — replacing heuristic guessing (heartbeat-line-count + re-nudge) with real
message IDs, an observable state machine, receipts, idempotency, replay, and a dead-letter queue.

## 1. Message = a structured, ID'd record
Every message has: `id` (unique), `from` (agent_uid), `to` (agent_uid), `ts`, `state`, `body`.
Sender/recipient are real fields — **never a free-text signature to parse.**

## 2. Source of truth = serialized append-only journal
- The recipient's per-agent inbox journal `<standup_dir>/inbox/<agent_uid>.md` (from P0) is the
  **append-only audit journal**. Messages and state transitions are appended as event lines; a message's
  current state = the fold (last event) over its `id`.
- Every mutation takes an exclusive `flock` on `<inbox-journal>.lock`. The writer folds and revalidates
  under that lock, then performs one checked append before releasing it. A lock or append failure is a
  loud non-zero result; the command MUST NOT report a state that was not committed.
- Reads fold a stable snapshot captured while holding the same lock. They do not keep the lock while
  formatting output, but they never fold a moving journal.
- Message line: `TS | id:<id> | from:<uid> | to:<uid> | state:PERSISTED | <body>`
- Event line:   `TS | id:<id> | event:<NOTIFIED|SEEN|PROCESSED|FAILED> | by:<uid>`
- Physical journal order is the only ordering supplied by this contract. This prelude does not add a
  `seq`, frame, checksum, or other event-spine field to the legacy line grammar.
- A SQLite/WAL index is an OPTIONAL future accelerator — **not required for P1**; the file journal is authoritative.

## 3. Delivery state machine (observable, never inferred)
`PERSISTED → NOTIFIED → SEEN → PROCESSED | FAILED` (+ dead-letter).
- **PERSISTED** committed to the recipient's journal · **NOTIFIED** recipient pinged (wakeup) ·
  **SEEN/CLAIMED** explicitly picked up · **PROCESSED|FAILED** terminal.
- `bin/message state <id>` → current folded state. Always observable.

## 4. Commands — `bin/message <sub>`
- `send <to_uid> "<body>" [--id <id>]` → resolve recipient via `bin/inbox` (P0), atomically deduplicate
  and commit PERSISTED, then print the `id`.
- `inbox` → list own OPEN messages (state ∉ {PROCESSED,FAILED}) from own `inbox_path` (via `bin/context`).
- `seen <id>` · `done <id>` · `fail <id> ["<reason>"]` → revalidate and append the transition in one
  locked commit (`by` = own agent_uid).
- `state <id>` → print current folded state · `dlq` → list dead-lettered messages.
- `replay` → list own unprocessed messages, in order (for a fresh/restarted agent to catch up).

## 5. Idempotency
- Within one recipient journal, `id` is unique for writers that use the supported command path. Re-`send`
  with an existing id is a **no-op** (dedup); `seen/done` on an already-terminal id is a no-op. The
  existence/state check and append share one lock, so concurrent compliant retries cannot both commit.
  This is idempotent journal mutation, not exactly-once external effect delivery.

## 6. Replay (restart-safe)
- A fresh/restarted agent runs `replay` → gets exactly the messages not yet PROCESSED/FAILED, in physical
  journal order from one stable snapshot. Timestamps never establish replay order. **Nothing committed is
  silently lost on a process recycle.** Power-loss durability is outside this contract.

## 7. Dead-letter
- A message that FAILs (or exceeds a retry bound) is retained in `bin/message dlq` — visible, never silently dropped, never infinitely re-notified.

## 8. Watcher = wakeup only
- The notify/wakeup mechanism only pings ("check your inbox"). It does **not** prove delivery via heartbeat-line-count or re-nudges — proof lives in the state events (§3). (The heuristic watcher is dismantled in P2 after parity; P1 provides the receipts that replace it.)

## 9. Acceptance (P1 slice) — black-box, synthetic projects, example id `acme`
- `send → PERSISTED → NOTIFIED → SEEN → PROCESSED`, state observable at each step.
- **Idempotency:** double-send (same id) = one message; double-`done` = no error/effect.
- **Concurrency:** simultaneous sends with one id commit one PERSISTED record; simultaneous transitions
  are revalidated under the journal lock and cannot commit an illegal post-state.
- **Failure:** lock acquisition and append failures are loud and never reported as committed delivery.
- **Replay:** a "restarted" recipient recovers exactly the unprocessed messages, in order.
- **Dead-letter:** a FAILED message surfaces in `dlq`, not in `inbox`, not re-notified endlessly.
- **Cross-target:** deliver to another project's agent (recipient busy/down/restart) — nothing lost.
- Bash/awk plus `flock` from util-linux; fail-closed/fail-loud per P0.

`flock` is cooperative, advisory serialization for the supported single-host writers. A process that
bypasses the command path can ignore the lock and forge journal lines. The full event spine's framing,
integrity, torn-tail handling, and stronger writer boundary remain future work.

---
White-label: example id `acme`; no real names, infrastructure, or hosts.
