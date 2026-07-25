# ADR-004: Durable Attempt Audit over the First Framed Spine Stream

## Status

Accepted

## Date

2026-07-25

## Context

Through RM-1 the managed launch produced a complete authorization verdict
(`AIB_VERDICT_RECORD`, `lib/aibobnet.sh`) but never persisted it. Three gaps followed:

- A **PDP deny left no trace at all.** `bin/launch-agent` composed the verdict, then `aib_die`d with its
  exit code; nothing recorded that the decision had been made or why.
- A **crash after the decision was indistinguishable from a running attempt.** No write-ahead record
  existed, so an operator could not tell an in-flight launch from one whose process had vanished.
- The `launch_verdict` record was shaped for reuse but was **transient observability** — a JSON object on
  stderr, gone with the process.

ADR-0001 established a `flock`-serialized commit for the legacy line journals but deliberately did **not**
build the event spine (sequence numbers, framing, integrity markers, projection). ADR-0003 (RM-1) named a
durable Attempt record and a provider-change audit event as specified-but-unbuilt. RM-2 builds the first of
those: a durable Attempt audit, and it does so as the **first real customer of the framed event envelope**
rather than as a third ad-hoc line format.

## Decision

Write **two durable records per managed attempt** over a new framed stream, committed by the PEP parent
before and after enactment. The PDP stays pure; persistence is enactment mechanics.

### The honesty boundary — audit through the seam, not completeness or containment

RM-2 audits attempts **through the launcher seam, from identity resolution onward**. This is the
"policy gate, not containment" discipline of ADR-0003 applied to audit:

- It is **not completeness.** A process that bypasses `bin/launch-agent` and runs a provider directly
  leaves nothing in the stream. The audit proves what went through the seam, never that nothing else ran.
- It is **not containment.** Non-bypassability is RM-3. RM-2 adds a record, not a boundary.
- The recorded binding proves what the launcher *decided and observed*, not an OS-attested fact about the
  provider process.

These limits are stated in the docs and here so the stream is never read as more than it is.

### Two records per attempt

| Record | When | Terminal |
|---|---|---|
| `attempt.decided` | Immediately after the PDP returns, **before any enactment**. Carries the full verdict and complete binding provenance (already resolved at decision time). | **deny:** yes — exactly one record per deny, closing the deny-has-no-trace hole. **allow:** no — a write-ahead statement of intent. |
| `attempt.ended` | Allow-path terminal only: `ok` · `provider-failure(rc)` · `timeout` · `io-refused` · `aborted(signal)`. | yes |

An attempt with a `decided(allow)` and no `attempt.ended` whose recorded PID has vanished is folded by a
reader as **`presumed-dead`**. That classification is **reader-side only**: there is no recovery writer, and
`presumed-dead` is rejected fail-closed as an event payload value — it can only ever be derived, never
stored.

### Framed stream — decision B: framed non-`.jsonl`, prefix is pure transport

The stream is `<standup_dir>/events/main.events` with a sidecar lock `main.events.lock`. Each record is:

```
<seq> SP <crc> SP <len> SP <json> LF
```

- `seq` — writer-assigned, monotonic +1 within the stream, allocated **under the stream lock**.
- `crc` / `len` — POSIX `cksum` CRC and byte count over **exactly** the `<json>` bytes (one `cksum` call
  yields both). Both must match: `len` catches a chance CRC collision or a shifted separator in the prefix.
- `json` — the event object, starting at `{`, containing no LF or CR.
- The trailing `LF` is the **commit marker**: an unterminated final record is uncommitted (never ACKed),
  not committed-but-corrupt.

The `.jsonl` name was **rejected because it would have lied** — a record is not bare JSON, it is framed.
Decision B keeps the layers separate: the frame is pure transport, parsed strictly positionally from
line-start. A crafted JSON body cannot push bytes *before* the line start, so there is no forgery vector,
and **envelope fields are parsed exclusively from the JSON part** — the reader reconstructs no envelope
field from the prefix, and the prefix carries none. The alternative (a marker embedded inside the JSON,
true-JSONL) would force the runtime — which has no JSON parser beyond the registry awk — to extract the
marker by byte-surgery and to canonically re-serialize, exactly the "structured fields parsed out of
separator-delimited free text" the domain forbids, merely moved inside the object.

### Identity from writer-assigned `seq`, never from the clock

`event_id` is `<project_uid>-main-<seq>`, deterministic from `(stream, seq)` and therefore host- and
restart-unique **without a clock**. It is composed **inside the lock** after `seq` allocation; the caller
never pre-composes a line. For `attempt.decided`, `attempt_id = correlation_id = its own event_id`; for
`attempt.ended`, `causation_id = attempt_id = the persisted decided event_id returned by the broker`, never
re-guessed. `occurred_at` is ISO-8601 UTC **display only**; a stepped clock or a reused PID cannot affect
identity. `date +%N` is guarded: a non-GNU `date` that emits the literal `N` fails closed rather than
poisoning even the display timestamp.

### At-most-one `attempt.ended` is a broker invariant, not a process flag

Under `set -euo pipefail` with `aib_die` (both exit), a process flag cannot guarantee single
terminalization. `aib_event_commit` revalidates **under the lock** whether an `attempt.ended` already exists
for the attempt and rejects a second one fail-closed — the same in-lock precondition-and-append discipline
the legacy broker uses. The signal traps disarm against re-entry (`trap - EXIT INT TERM HUP` as the
handler's first act) and preserve the original exit status. A top-level field extractor reads only
depth-1 fields, so a nested `"attempt_id"` inside `payload` can never spoof the check.

### Signal truth — the provider runs as a managed child, not in a command substitution

RM-1 ran the provider in `$( … )`, where a TERM during a running child is handled only after the
substitution returns — which could write `aborted` after a genuinely successful provider, or lose the
signal. RM-2 starts the provider as a **managed background child with a known PID**: a small manager
forwards HUP/INT/TERM to the child, runs the finite watchdog, reaps the child, and establishes the reaped
exit status **before** any terminal record is written. `attempt.ended(aborted, signal)` is written **only**
when the child's abort is actually established. A signal at the parent with the child still running or
unconfirmed is **not** `aborted` — the attempt stays an open `decided(allow)`, foldable as `presumed-dead`.
This is the reason the watchdog is now a `sleep`-based timer around a managed PID rather than the coreutils
`timeout` wrapper: `timeout` cannot forward the parent's signals to, or report the true reaped status of, a
child it owns opaquely.

### Fail-closed everywhere

Every failure of lock, tail-validation, encoding, cap, checksum, or append stops the launch **before
enactment**. Best-effort audit would be an invariant break: the provider never starts without a committed
`decided` record. The stream lock is acquired with a **finite** `flock -w` timeout; a timeout fails loudly
with a stable exit code (75) rather than freezing every launch behind a stuck writer.

### Quarantine classification (fail-closed)

- **uncommitted tail** — the last record only, and only unterminated (no trailing LF). The benign case: the
  writer truncates `main.events` in place at the last intact LF boundary (the file stays the single
  authoritative path — no rename, no second file), the never-ACKed bytes are never replayed, and the writer
  resumes at last-intact `seq+1`. A crash between truncate and append re-enters the same benign path.
- **corrupt (fail-closed)** — any *terminated* record with a crc/len mismatch, a non-object body, or an
  unparsable line marks the stream corrupt: the fold refuses a verdict **and** the writer refuses the
  append. Audit corruption is a launch-stopper by doctrine; the DoS facet is bounded by the finite lock
  timeout.
- **lost (inner seq gaps)** — reported as `degraded`; a gap is loss, not corruption, so the writer resumes
  above the highest valid seq and does not block.
- **whole-suffix / file replacement — NOT detectable in RM-2.** A persistent high-water anchor would sit in
  the same directory, same file perms, same trust domain; whoever can truncate the stream can rewrite the
  anchor. It becomes meaningful only in a **different** trust domain — a broker-owned high-water mark, the
  same move as secret-behind-broker. **That broker-held anchor is the intended RM-3 close.** The honest RM-2
  claim is: *detects torn tail, marker faults, and inner seq gaps; whole-suffix or file replacement is not
  detectable without an external cursor.*

### Frozen schema before the parallel lanes

The envelope and payload shape were frozen as Lane A's first deliverable so the parallel writer (Lane B)
and reader (Lane C) could not disagree. The envelope carries every DOMAIN §5 field including the required
`actor_id`; absent optionals are emitted as JSON `null` for a stable reader shape. The payload carries the
verdict reasons, the `{requested, resolved, source, effective}` triples for provider/model/effort, the
`{raw, effective_path, source}` adapter object, the parent PID, and `{len, sha256}` for the prompt — the
prompt text itself never enters a record. `requested` is frozen as `null` for provider/model/effort because
no direct CLI request for them exists today; the slot is reserved additively. A DENY blanks `effective` to
`null` while `resolved` stays populated, so a denied value is distinguishable from a genuinely unresolved
one. Only `attempt.ended` carries an `exit` field, and only a genuinely observed terminal value. The JSON
encoder encodes every control byte (U+0000–U+001F, backslash, quote) or rejects fail-closed — the previous
`aib_json`, which escaped only backslash and quote, was insufficient for audit payloads carrying arbitrary
label and reason text.

## Alternatives Considered

### True-JSONL with the integrity marker inside the object

Rejected. The runtime has no JSON parser beyond the registry awk. Extracting a marker out of the JSON by
byte-surgery and canonically re-serializing to verify it is fragile in bash/awk and re-creates the very
free-text-field-parsing the domain forbids. Framing outside the object keeps the integrity check the
dumbest, most verifiable code in the system.

### Wall-clock + PID as the attempt identity

Rejected. `a-<ns>-p<pid>` is not host-collision-free: PID reuse plus a stepped or replayed wall-clock can
collide, and it never allocated a real `event_id`. Uniqueness comes from the under-lock `seq`; any
wall-clock/PID label that remains is a non-authoritative display value only.

### A process flag to guarantee a single terminal record

Rejected. Under `set -e` + `aib_die`, both of which exit, a flag cannot hold across an unexpected exit or a
signal. The single-terminalization guarantee has to live in the broker's in-lock revalidation. The flag is
kept only as an optimization.

### Running the provider in a command substitution (RM-1 shape)

Rejected. It swallows signals until the substitution returns, so the terminal classification cannot be
trusted. A managed child with a known PID is the prerequisite for signal truth.

### A high-water anchor to detect whole-file replacement now

Rejected for RM-2 — same trust domain as the stream it would protect. It only helps against accidents while
doubling the write-path failure modes. It is deferred to RM-3, where a broker owns it in a different trust
domain.

### Retrofit the legacy journals or add a recovery writer

Rejected. The Delivery/Memory/Heartbeat journals keep their unframed protocol (ADR-0001); this stream is
the envelope's first customer, not a migration. A recovery writer that closed `presumed-dead` attempts
would violate the single-append-path invariant — `presumed-dead` stays a reader-side fold.

## Consequences

- A managed launch now leaves a durable trail: exactly one `decided` record per deny (the core fix), a
  write-ahead `decided(allow)` plus one `attempt.ended` on the allow path.
- **New runtime dependencies.** Beyond RM-1's `flock`, the stream path adds POSIX `cksum` and coreutils
  `truncate` (the latter only on the uncommitted-tail path); the launcher adds coreutils `sha256sum`,
  `sleep`, and `mktemp`, and now pre-checks `env`. A missing dependency fails closed with **exit 6**. The
  coreutils `timeout` wrapper is **no longer used** — the watchdog is a `sleep`-based timer around a
  managed child.
- **Exit codes:** `2` config/IO and generic fail-closed reject · `6` missing runtime dependency · `64`
  usage/refusal (including an unsupported provider, which records `decided(allow)` then
  `ended(io-refused)` before exiting 64) · `75` event-stream lock timeout (`EX_TEMPFAIL`) · `124` watchdog
  timeout · `126`/`127` adapter not runnable/not found (io-refused) · `128+signal` aborted · provider exit
  code passed through on provider failure.
- **The verdict still does not journal from the PDP.** Persistence is the PEP parent's job; the PDP stays a
  pure function so RM-3 can relocate it behind a process boundary unchanged.
- **Known limits, documented not hidden.** SIGKILL or OOM of the parent fires no trap, leaving an open
  `decided(allow)` that folds to `presumed-dead` (no recovery writer). The 0600 `mktemp` lifecycle buffers
  can leak on SIGKILL. There is no `fsync`, so power-loss durability is out of scope. PID reuse can make a
  dead attempt look alive (`/proc/<pid>` starttime hardening is Linux-specific and deliberately not
  sneaked in). A provider exiting exactly at the watchdog boundary can be classified as `timeout`/124
  rather than its true rc. The full-stream scan per append is O(n²) — safe at RM-2's low volume and the
  reason the persistent cursor is an RM-3 anchor — and the signal-truth lifecycle costs roughly 2.4× the
  RM-1 per-launch runtime, an accepted price for a trustworthy terminal classification.
- **Still specified, not built:** the provider-change audit event, cursors/projections/rebuild tooling
  beyond this stream, and non-bypassability. RM-2 is the first stream, not the whole spine.
- **Operational:** the persisted records and the launcher's stderr carry host-local absolute paths
  (`adapter_path`) and deployment uids (`*_source`) by design; redact before publishing launcher output or
  a stream excerpt to a public artifact (see `docs/CONTRACT-codex-run.md` §4).

This ADR extends ADR-0003 and ADR-0001; it reverses neither. The PDP purity, the `env -i` allow-list, and
the policy-gate-not-containment framing all hold unchanged; RM-2 adds the durable Attempt record on top.

---
White-label: example project id `acme`; no real names, infrastructure, or hosts.
