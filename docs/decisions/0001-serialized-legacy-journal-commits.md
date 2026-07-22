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
- With `shared_memory_dir` configured, this lock is registry-wide on the host: every supported memory
  mutation in every registered project takes it, including private agent-scope writes. This deliberately
  broad ordering point lets a shared proposal scan every registered private and project journal and
  reserve an ID without racing a narrower writer. A private append protected by a separate lock could
  otherwise occur between that cross-journal collision scan and the shared append.
- Memory collision scans are scope-aware: private proposals check their own private and reachable
  collective journals; project proposals also check every private journal in that project; shared
  proposals check every registered project's private and project journals. Separate private journals are
  not globally unique; a broader collective proposal rejects an ID found anywhere in its collision set.
- A mutation acquires the applicable exclusive lock, folds every journal required for its decision,
  revalidates the precondition, and performs one checked append before releasing the lock.
- Wakeup deliberately includes external work in its critical section: it holds the recipient inbox lock
  across eligibility revalidation, the configurable hook/mux ping, and the checked result append. This
  serializes cooperating hook attempts for the same eligible state. The wakeup parent owns the lock; the
  external child closes its inherited lock descriptor before `exec`.
- The `AIBOBNET_WAKEUP_HOOK` interface is non-reentrant for the recipient it is firing for. A hook must
  not call `bin/wakeup` or another supported command that tries to acquire that same recipient inbox
  lock. The parent still owns the lock while it waits for the hook, and the re-entering command uses
  blocking `flock -x` with no timeout. The parent and re-entering command can therefore wait for each
  other forever.
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
hook before either appends NOTIFIED. Holding the recipient lock across the hook prevents overlapping hook
attempts while leaving unrelated recipient journals independent; a non-terminal failure still permits the
next serialized retry.

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
- A configured `shared_memory_dir` serializes all supported memory writes registry-wide, so an unrelated
  project or private agent-scope write must wait behind the current memory mutation. The reduced write
  concurrency and wider availability blast radius are accepted trade-offs for atomic scope-aware,
  cross-journal ID uniqueness.
- Process exit releases lock ownership without a stale-lock recovery protocol. In particular, `TERM` to
  the wakeup parent PID releases its inbox lock even if the external hook child remains alive, because that
  child closed the inherited lock descriptor before `exec`. The sidecar file may remain on disk and is
  harmless.
- A slow wakeup hook delays cooperating mutations for that recipient for as long as the wakeup parent
  waits and holds the inbox lock. A hung hook blocks them indefinitely. In particular, same-recipient
  hook re-entry is an unbounded self-deadlock: the inner command waits forever on blocking `flock -x`
  while the lock-owning parent waits for the hook, because lock acquisition has no timeout. Hooks must
  not re-enter the lock of the recipient they fire for. This is an explicit availability cost of
  preventing overlapping hook attempts.
- A non-terminal failed wakeup attempt appends its attempt marker and permits the next serialized retry;
  only a successful or terminal result makes a waiting wakeup a no-op.
- A crash after a wakeup hook takes effect but before its result append can cause a retry to invoke the hook
  again. A surviving child may also complete its external effect after the parent releases the lock. Kernel
  lock release prevents a stale lock, not duplicate external effects across that crash window; exactly-once
  wakeup is not guaranteed.
- The ordering point applies to mutations only. It does not provide a coherent namespace snapshot or
  linearizable reads.
- Durability means surviving process restart after a successful append. No `fsync` or power-loss guarantee
  is added.

The following remain explicitly deferred: sequence numbers, event envelopes, framing, checksums, byte caps,
the per-project `main` stream, cursors, projectors, gap detection, torn-tail detection or quarantine,
hostile-writer integrity, cross-host coordination, and exactly-once effects.
