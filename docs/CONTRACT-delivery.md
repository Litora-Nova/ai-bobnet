# ai-bobnet — Delivery Contract (P1: durable, provable message delivery)

Builds on P0 (`docs/CONTRACT.md`). P0 made identity + "where" deterministic; **P1 makes DELIVERY
deterministic and provable** — replacing heuristic guessing (heartbeat-line-count + re-nudge) with real
message IDs, an observable state machine, receipts, idempotency, replay, and a dead-letter queue.

## 1. Message = a structured, ID'd record
Every message has: `id` (unique), `from` (agent_uid), `to` (agent_uid), `ts`, `state`, `body`.
Sender/recipient are real fields — **never a free-text signature to parse.**

## 2. Source of truth = append-only journal (pure bash/awk, no external deps)
- The recipient's per-agent inbox journal `<standup_dir>/inbox/<agent_uid>.md` (from P0) is the
  **append-only audit journal**. Messages and state transitions are appended as event lines; a message's
  current state = the fold (last event) over its `id`.
- Message line: `TS | id:<id> | from:<uid> | to:<uid> | state:PERSISTED | <body>`
- Event line:   `TS | id:<id> | event:<NOTIFIED|SEEN|PROCESSED|FAILED> | by:<uid>`
- A SQLite/WAL index is an OPTIONAL future accelerator — **not required for P1**; the file journal is authoritative.

## 3. Delivery state machine (observable, never inferred)
`PERSISTED → NOTIFIED → SEEN → PROCESSED | FAILED` (+ dead-letter).
- **PERSISTED** written to recipient's journal (durable) · **NOTIFIED** recipient pinged (wakeup) ·
  **SEEN/CLAIMED** explicitly picked up · **PROCESSED|FAILED** terminal.
- `bin/message state <id>` → current folded state. Always observable.

## 4. Commands — `bin/message <sub>`
- `send <to_uid> "<body>" [--id <id>]` → resolve recipient via `bin/inbox` (P0), append PERSISTED, print the `id`.
- `inbox` → list own OPEN messages (state ∉ {PROCESSED,FAILED}) from own `inbox_path` (via `bin/context`).
- `seen <id>` · `done <id>` · `fail <id> ["<reason>"]` → append the transition event (`by` = own agent_uid).
- `state <id>` → print current folded state · `dlq` → list dead-lettered messages.
- `replay` → list own unprocessed messages, in order (for a fresh/restarted agent to catch up).

## 5. Idempotency
- `id` is unique; re-`send` with an existing id is a **no-op** (dedup); `seen/done` on an already-terminal id is a no-op. Retries never double-fire.

## 6. Replay (restart-safe)
- A fresh/restarted agent runs `replay` → gets exactly the messages not yet PROCESSED/FAILED, in order. **Nothing silently lost on a recycle.**

## 7. Dead-letter
- A message that FAILs (or exceeds a retry bound) is retained in `bin/message dlq` — visible, never silently dropped, never infinitely re-notified.

## 8. Watcher = wakeup only
- The notify/wakeup mechanism only pings ("check your inbox"). It does **not** prove delivery via heartbeat-line-count or re-nudges — proof lives in the state events (§3). (The heuristic watcher is dismantled in P2 after parity; P1 provides the receipts that replace it.)

## 9. Acceptance (P1 slice) — black-box, synthetic projects, example id `acme`
- `send → PERSISTED → NOTIFIED → SEEN → PROCESSED`, state observable at each step.
- **Idempotency:** double-send (same id) = one message; double-`done` = no error/effect.
- **Replay:** a "restarted" recipient recovers exactly the unprocessed messages, in order.
- **Dead-letter:** a FAILED message surfaces in `dlq`, not in `inbox`, not re-notified endlessly.
- **Cross-target:** deliver to another project's agent (recipient busy/down/restart) — nothing lost.
- Pure bash/awk, no external deps; fail-closed/fail-loud per P0.

---
White-label: example id `acme`; no real names, infrastructure, or hosts.
