# ai-bobnet — Adapter Contract (P2: wakeup + message-bus adapter)

Builds on P1 (`docs/CONTRACT-delivery.md`). P1 made delivery durable + provable (file journal = truth).
**P2 makes it (a) PROMPT** via a wakeup-only notifier, **and (b) programmatically accessible** via a localhost
message-bus adapter — without the adapter becoming authoritative (journal stays truth) and without coupling to
any external runtime (CAO = inspiration, not a dependency).

## Non-negotiables
- **Journal = source of truth** (P1 append-only files). The adapter is a thin accelerator: everything it does
  goes through the same serialized journal commit path and `bin/message` semantics. **Adapter down ⇒ the
  P1 CLI still fully works.**
- **Wakeup ≠ delivery-proof.** The wakeup only pings ("check your inbox"). Proof of SEEN/PROCESSED stays the
  recipient's P1 receipt. **No heartbeat-line-count / re-nudge heuristics — ever.**
- **Core dependencies stay small and explicit.** Journal commits use `flock` from util-linux. The OPTIONAL
  HTTP daemon may use `python3` **stdlib only** (no pip deps).

## 1. Wakeup notifier — `bin/wakeup [<agent_uid>]`
- Scans the target agent's inbox journal for messages in `PERSISTED` (not yet `NOTIFIED`), appends `NOTIFIED`
  through the same locked delivery commit semantics, and pings the recipient's `mux_session`
  (from registry) via a **configurable wakeup hook** (`AIBOBNET_WAKEUP_HOOK`; default: mux send;
  test-stubbable/capturable). Candidate discovery is lock-free and may be stale. For each candidate,
  wakeup takes the recipient inbox lock and holds it across eligibility revalidation, the hook/mux ping,
  and the checked result append. Only one cooperating hook attempt for that recipient can run at a time.
  After a successful or terminal result, a waiting wakeup revalidates to a no-op; after a non-terminal
  failed attempt, it may perform the next serialized retry. A hook MUST NOT call `bin/wakeup` or any
  supported command that acquires the inbox lock of the recipient it fires for — same-recipient re-entry
  is an unbounded self-deadlock (blocking `flock -x`, no timeout; see ADR-0001).
- **Availability trade-off:** a slow or hung hook delays every cooperating mutation for that recipient
  while the wakeup parent remains alive and holds the inbox lock. It does not block a different recipient's
  independently locked journal. The external hook child closes its inherited lock descriptor before
  `exec`; sending `TERM` to the wakeup parent PID therefore releases `flock` even if that child remains
  alive.
- **Crash boundary:** a surviving child may still produce the external effect after the parent releases the
  lock, and a crash after the hook takes effect but before its journal result is appended leaves the message
  eligible for retry. A later wakeup may invoke the hook again. Wakeup does not provide exactly-once
  external effects.
- **Bounded:** after N failed wake attempts a message is dead-lettered (visible via `bin/message dlq`), never
  infinitely re-pinged.
- Fail-closed/fail-loud per P0; targets resolved via the registry, never env-guessed.

## 2. Localhost message-bus adapter — `bin/bus` (CAO-inspired accelerator)
- Localhost-bound HTTP daemon (`python3` stdlib) over the P1 operations:
  `POST /send` · `GET /inbox` · `POST /seen|done|fail` · `GET /state/<id>` · `GET /dlq`.
- **Semantics identical to `bin/message`** — the adapter invokes/mirrors it; no divergent logic.
- **Hardened:** bind `127.0.0.1` only; require an auth token (env, **NO default**); reject otherwise. No network egress.
- An MCP surface may wrap the same ops later; not required for P2.

## 3. Inbox projection (read-only)
- `GET /inbox`, `GET /state/<id>`, `GET /dlq` expose the current folded state for tools/dashboard — read-only, from the journal.

## 4. Cutover note (NOT built here)
- "Dual-run + soak + dismantle the old heuristic" applies at **cutover** (when ai-bobnet supersedes claude-bobnet):
  run both, prove parity, THEN retire claude-bobnet's heuristic watcher. Greenfield ai-bobnet has no heuristic to
  dismantle — a P4/cutover concern, noted for completeness.

## 5. Acceptance (P2 slice) — black-box, synthetic projects, example id `acme`
- **Wakeup:** PERSISTED message → `bin/wakeup` → NOTIFIED appended + recipient pinged (stub hook captured in test);
  idempotent (2nd wakeup = no re-notify); bounded (exhausted → dlq).
- **Concurrent wakeup:** two wakeups may observe the same candidate, but the recipient lock admits one
  eligible hook attempt and result append at a time. A waiter becomes a no-op after NOTIFIED or terminal
  FAILED; after a non-terminal failed hook, it may perform the next serialized retry.
- **Adapter parity:** each `/send /inbox /seen /done /fail /state /dlq` yields the SAME journal state as the
  equivalent `bin/message` call (adapter ≡ CLI).
- **Hardening:** daemon binds `127.0.0.1` only; missing/wrong auth token → rejected; no default token.
- **Journal authority:** with the daemon stopped, the P1 CLI still sends/reads/transitions fully.
- p0 + p1 suites stay green. Core journal commits require util-linux `flock`; `python3` stdlib only for
  the optional daemon.

---
White-label: example id `acme`; no real names, infrastructure, or hosts.
