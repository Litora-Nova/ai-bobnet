# ADR-001: Serialize Legacy Journal Commits with `flock`

## Status

Accepted

## Date

2026-07-21

## Context

Delivery and memory state are folds over append-only, line-oriented files. Their original command paths
checked the current fold and appended in separate steps. Two concurrent processes could therefore observe
the same pre-state and both append a commit that should have been idempotent or mutually exclusive.

The full event spine in `docs/DOMAIN.md` will eventually replace these legacy journals with a versioned
event envelope, explicit stream ordering, framing, integrity markers, and projection contracts. That is a
larger migration. The current system needs one deterministic commit point now without pretending that the
event spine already exists.

## Decision

Use util-linux `flock` as the single-host serialization primitive for all supported delivery, wakeup, and
memory journal mutations.

- A delivery journal uses `<inbox-journal>.lock`.
- All memory journals in one reachable namespace share a lock. When `shared_memory_dir` is configured,
  the lock is `<shared_memory_dir>/.aibobnet-memory.lock`; otherwise it is
  `<standup_dir>/memory/.aibobnet-memory.lock`.
- A mutation acquires the applicable exclusive lock, folds every journal required for its decision,
  revalidates the precondition, and performs one checked append before releasing the lock.
- Wakeup deliberately includes external work in its critical section: it holds the recipient inbox lock
  across eligibility revalidation, the configurable hook/mux ping, and the checked result append. This
  prevents a parallel cooperating wakeup from invoking the hook for the same eligible state.
- A lock or append failure is loud. The caller does not report a state that was not committed.
- Read-only folds do not acquire the writer lock. They retain the existing snapshot/fold behavior and are
  explicitly not linearizable with concurrent commits.
- The existing record grammar remains unchanged. Physical append order remains the only ordering in these
  journals.

This is a cooperative writer contract. The supported commands use the lock; an unsupported direct writer
can ignore an advisory lock and is outside the guarantee.

## Alternatives Considered

### Keep independent check and append steps

Rejected. It leaves duplicate-ID and lifecycle-transition races open even when every caller uses the
supported CLI.

### Add separate locks in each command

Rejected. Command-specific locks can protect different files or lock in different orders, recreating the
cross-command and cross-journal race at a less visible boundary.

### Release the inbox lock around the wakeup hook

Rejected. Two cooperating wakeups could both revalidate the same PERSISTED message and invoke the external
hook before either appends NOTIFIED. Holding the recipient lock across the hook removes that duplicate in
the non-crashing path, while leaving unrelated recipient journals independent.

### Use sentinel directories or PID lock files

Rejected. They require stale-owner recovery after crashes. Kernel-managed `flock` releases ownership when
the process or descriptor exits; the persistent sidecar file does not represent a live owner.

### Make SQLite or a resident daemon authoritative now

Rejected for this prelude. Files remain the source of truth, and adding a second authority would expand the
migration without delivering the narrow concurrency fix. A future projection may still use SQLite as a
disposable index.

### Implement the full event spine in this change

Deferred. Its envelope, migration, replay, integrity, and projection semantics require a separate contract
and cutover plan.

## Consequences

- Concurrent supported writers have one decision-and-commit point, so deduplication and transition
  preconditions can be enforced atomically.
- `flock` from util-linux becomes an explicit runtime dependency.
- The mechanism is single-host and advisory. It does not protect against hostile or accidental writers
  that bypass the supported commands.
- Process exit releases lock ownership without a stale-lock recovery protocol. The sidecar file may remain
  on disk and is harmless.
- A slow or hung wakeup hook delays cooperating mutations for that recipient for as long as it holds the
  inbox lock. This is an explicit availability cost of preventing parallel duplicate hook invocations.
- A crash after a wakeup hook takes effect but before its result append can cause a retry to invoke the hook
  again. Kernel lock release prevents a stale lock, not duplicate external effects across that crash
  window; exactly-once wakeup is not guaranteed.
- The ordering point applies to mutations only. It does not provide a coherent namespace snapshot or
  linearizable reads.
- Durability means surviving process restart after a successful append. No `fsync` or power-loss guarantee
  is added.

The following remain explicitly deferred: sequence numbers, event envelopes, framing, checksums, byte caps,
the per-project `main` stream, cursors, projectors, gap detection, torn-tail detection or quarantine,
hostile-writer integrity, cross-host coordination, and exactly-once effects.
