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
  through the same locked `bin/message notify` commit semantics, and pings the recipient's `mux_session`
  (from registry) via a **configurable wakeup hook** (`AIBOBNET_WAKEUP_HOOK`; default: mux send;
  test-stubbable/capturable). Candidate discovery is lock-free and may be stale; the mutation revalidates
  state under the writer lock, so a stale candidate cannot create a duplicate transition. Idempotent —
  never re-notifies NOTIFIED/terminal.
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
- **Concurrent wakeup:** two wakeups may observe the same candidate, but locked revalidation commits at most
  one NOTIFIED transition.
- **Adapter parity:** each `/send /inbox /seen /done /fail /state /dlq` yields the SAME journal state as the
  equivalent `bin/message` call (adapter ≡ CLI).
- **Hardening:** daemon binds `127.0.0.1` only; missing/wrong auth token → rejected; no default token.
- **Journal authority:** with the daemon stopped, the P1 CLI still sends/reads/transitions fully.
- p0 + p1 suites stay green. Core journal commits require util-linux `flock`; `python3` stdlib only for
  the optional daemon.

---
White-label: example id `acme`; no real names, infrastructure, or hosts.
