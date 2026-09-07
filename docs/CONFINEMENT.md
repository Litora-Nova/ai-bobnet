# ai-bobnet — Confining the provider child (contract §2.1)

**Status:** decided 2026-08-19, measured on a live VM. Slice 3 wires this into the broker's enactment
path (`bin/aib-broker-handler`) against the contract this document specifies. The helper is exec'd
through, never invoked ad hoc, and its CLI contract gains one addition for slice 3: the exec-status
channel below. This document is the contract the slice-3 build must satisfy; it is not itself the
build. On the dev host the ruleset install fails closed (Landlock ABI unavailable — see "Exercising
this on a Landlock-less host"), so slice 3 is gated against a stub honouring the same contract, and
the real helper's failure path is compiled and exercised where a C compiler is present. The VM
exercise, where "confined" becomes true rather than contractual, has a precondition — see below.

## What §2.1 requires

The provider child runs under the broker account, but the prompt that drives it comes from the
request. So it is agent-directed computation running inside the account that owns the event stream,
the anchor, the credentials and the adapter map. §2.1 therefore requires the child to be **confined
before `exec`**, with two properties: the restriction is installed before the foreign code runs, and
the restricted process cannot revoke it.

**Minimum:** no write access to the event stream, the high-water anchor, the registry, the adapter
map, the installed engine, or **the visibility projection root** (`AIB_PROJECTION_ROOT`,
`docs/CONTRACT-visibility.md` §14, `docs/decisions/0007-visibility-projection.md`) — a broker-produced,
broker-attested artifact, added to this minimum for the same reason the event stream and the anchor are
here: a confined child's `LL_RW` over a project `home` must never also reach a broker-owned attestation
sitting outside that `home`. Read access to the credential directory only as far as the adapter needs.

## Primary path — Landlock

`src/landlock-exec.c` (~70 lines) creates a ruleset, adds the paths given in `LL_RO` and `LL_RW`,
sets `PR_SET_NO_NEW_PRIVS`, calls `landlock_restrict_self` and then `execvp`s.

Measured on 2026-08-10, Landlock ABI 6: provider work runs (including outbound TLS), the TCB is
closed against writes, and escape attempts via `unshare` and `setpriv` are both denied.

Two findings from that measurement are part of the requirement, not footnotes:

- **`/dev` must be writable.** With a literal reading of "only the workspace", every command dies at
  `/dev/null`. The positive list is: workspace, `/tmp`, `/var/tmp`, `/dev`.
- **Landlock does not mediate inode metadata** up to ABI 6. A fully confined child still executed
  `chmod 777` on a TCB directory. That hole is closed by **ownership**, not by Landlock: the TCB
  directories belong to root and the broker reaches them through its group.

**The paths come from the registry, never from the request** — see `SPEC-wire-format.md`.

## The helper contract, extended for slice 3

The provider child is exec'd **only** through the helper, at an absolute, broker-owned path:
`AIB_CONFINE_BIN`, default `/opt/aib/engine/libexec/landlock-exec`, settable only from the unit
environment — never from the request, never from the registry. There is no code path that runs the
provider unconfined; if the helper cannot be run, the provider does not start.

### Pre-flight, before every launch

Before spawning the provider, the enactment runs a pre-flight call through the same helper:

```
LL_RO=/ LL_RW=<tmp-dir> $AIB_CONFINE_BIN /bin/true
```

A non-zero exit from the pre-flight means confinement is not available on this host right now.
Enactment responds `attempt.ended(io-refused, code=126, stage=confine)` on the durable stream and
`reason=confinement_unavailable` on the wire — and the provider **never starts**. The pre-flight is
cheap (`/bin/true`) and existence is not the question it answers; installability of the ruleset is.
It answers that question fresh on every launch rather than once at broker start, because a host can
lose Landlock (a kernel downgrade, a container runtime change) between launches without the broker
restarting.

### Exec-status channel (`LL_STATUS_FD`)

`execvp` never returns on success, so no exit code from the helper process is available to
distinguish "confinement was never attempted" from "the confined provider itself exited 3, 127, or
any other number" — the child, once exec'd, owns the full 256-value exit-code space, and no number in
it is reserved. The helper contract therefore gains a second channel, independent of the exit code:

- The caller opens an fd and passes its number in `LL_STATUS_FD=<n>`. The helper — not the caller —
  marks it `CLOEXEC` (`fcntl(F_SETFD, FD_CLOEXEC)`, `src/landlock-exec.c`'s `status_init()`), before
  any Landlock work and well before its own `execvp`: that is what makes a later successful `execvp`
  close it automatically, while it stays open, in the helper's own process, for every failure path
  that returns before that point.
- If the helper fails **before** `execvp` — journal-fd preparation, ruleset create, add-rule, `no_new_privs`, or
  `restrict_self` — it writes **one line** naming the reason to that fd, then exits non-zero (the
  existing exit-3 convention is unchanged; `LL_STATUS_FD` is additive, not a replacement for it).
- If `execvp` succeeds, the fd is `CLOEXEC` and therefore **closes silently, with nothing written to
  it** — the kernel closes it across the exec, so the now-running provider never sees it and never
  inherits it.
- The caller reads the fd **after the child ends**: non-empty means the helper never reached `exec`
  (`stage=confine`, `io-refused`, exit code 126, regardless of the child's own wait status); empty
  means `execvp` succeeded and the wait status belongs to the provider, classified by the existing
  exit-class mapping (`provider-failure` / `io-refused` / `timeout` / `aborted`, never `confine`).

This is the only reliable discriminator. A provider that happens to exit 3 (the helper's own
"Landlock unavailable" code) or 127 (the helper's own "exec failed" code) is not thereby mistaken for
a confinement failure — the status fd is empty in both cases, because the provider is what ran.

When `LL_STDERR_FD` is supplied, the helper saves the original journal fd with `dup(2)` and
`FD_CLOEXEC` **before** Landlock setup. Either operation failing writes a `confine:` reason to
`LL_STATUS_FD` and exits 3 before redirect or exec; failed `fcntl` also closes the duplicate.
The provider-stderr redirect still occurs **after** confinement. This ordering makes descriptor
failures independently testable on a host without Landlock: the real-helper fixture exhausts its
fd table under `RLIMIT_NOFILE` after the dynamic loader runs, and separately injects a failed
`fcntl` into the compiled helper. It does not substitute Landlock results or helper output.

### Diagnostics go to the broker's journal, never the caller's stream

The helper's own stderr diagnostics (`landlock-exec: …` lines) are the broker's operational log, not
part of the response the caller reads. They reach the unit's `StandardError=journal`
(`deploy/systemd/aib-broker@.service`) like every other broker-side diagnostic. They are never merged
into the provider's output stream and never appear in the wire response — a confinement failure is
reported to the caller as the structured `reason=confinement_unavailable` above, not as leaked
stderr text from a helper the caller has no reason to know exists.

### Descriptor inheritance

Before execing the confinement helper, the confined child enumerates its own
`/proc/self/fd` and closes every inherited descriptor except 0, 1, 2, and 9. This requires
Linux procfs to be mounted for the broker. Descriptor 9 is the private `LL_STATUS_FD`;
the helper marks it `CLOEXEC`, as it does its saved journal duplicate. Consequently
the exec'd provider receives only stdin, stdout, and stderr (0, 1, 2). The broker's
copies remain open. The descriptor fixture injects read-only and writable inherited
fds, then has the stub adapter enumerate `/proc/self/fd` after exec; it excludes the
transient enumeration descriptor after confirming it is no longer open.

### `LL_RO=/` — a stated divergence, not an oversight

§2.1's credential clause reads "read access to the credential directory only as far as the adapter
needs." Slice 3 does not build that narrowing: `LL_RO=/` for this slice, composed alongside
`LL_RW = <home>:/tmp:/var/tmp:/dev` from the registry snapshot alone (the request contributes
nothing to either list). This is looser than the minimum stated above, and it is recorded here as a
deliberate, dated divergence rather than left implicit: guessing the adapter's true read set without
a VM to observe it against breaks at the first real run, and a wrong guess that under-grants is a
launch-stopper while a wrong guess that over-grants is silently unsafe. Narrowing `LL_RO` to the
resolved adapter and its credential directory is a slice-4/VM item, tracked there, not here.

### The VM exercise's precondition — the metadata gap

Landlock does not mediate inode metadata up to ABI 6 (see the finding above): a fully confined child
can still `chmod` or rename a TCB directory it owns, which is a permanent DAC change reachable from
inside the cage. The measured fix is ownership, not Landlock: TCB directories owned `root:aib-broker
0770` rather than `aib-broker:aib-broker 0700` — a change to host provisioning, not a change in this
repository. Until that ownership change lands, the word "confined" is not true on the VM even once
slice 3's code is deployed there — the contract above is necessary but not sufficient. This is listed
here as a **gating precondition of the VM exercise**: the host provisioning must own the trusted
directories as root with the broker group (mode 0770/2770) before confinement is exercised on a real
host, gated on operator sign-off before that provisioning change ships. No exercise result should be
read as "confined" until it is confirmed done.

### Exercising this on a Landlock-less host

The development host this slice is built and gated on has no Landlock ABI (`ll_create` returns
`ENOSYS`/`EOPNOTSUPP` — confirmed by compiling and running `src/landlock-exec.c` directly: exit 3,
"unavailable"). Slice 3's tests therefore exercise the contract two ways: a stub helper with the real
CLI shape (`LL_RO`/`LL_RW`/`LL_STATUS_FD`, logs what it was asked to confine, execs its argument) for
every enactment path, and the real `src/landlock-exec.c` compiled with `cc` (skipped, not faked, where
no compiler is present) to exercise its actual failure path — exit 3, non-empty status fd — which is
the one path this host can genuinely exhibit without Landlock.

## Fallback — mount namespace, no compiler needed

Measured on 2026-08-19 with `unshare` and `setpriv` only (both from util-linux; `capsh`, `bwrap` and
`newuidmap` are all absent on the target):

| | without capability drop | with `setpriv --bounding-set=-all` |
|---|---|---|
| engine writable | no | no |
| **protection removable by remount** | **YES** | no |
| **umount possible** | **YES** | no |
| child still works (`/tmp`, `exec node`) | yes | yes |

`CapEff` drops to zero. **The capability drop is the load-bearing step**: without it the child is
root inside its own user namespace and simply unmounts its cage. There is also a window between
`unshare` and `setpriv` in which the process holds `CAP_SYS_ADMIN` — nothing agent-directed may run
there.

**Why this stays the fallback:** Landlock is an **allowlist** — everything unnamed is denied. The
mount approach is a **blocklist**: only what is explicitly bind-mounted read-only is protected, and
every forgotten path stays open. For a trusted base that grows, a blocklist is the weaker design.
Per-path *read* restrictions are trivial in Landlock and contortions with mounts.

## Runtime dependencies of the broker's confined path

`dd`, `timeout`, `mkfifo`, `realpath`, `env`, `sleep`, `mktemp`, `cat`, `wc` — all
coreutils, all hard requirements resolved via `command -v` with a fail-closed
`aib_die 6 "required runtime dependency not found: ..."` on absence, the same style the rest of this
codebase already uses. `cc` is install-time only (it compiles this helper; nothing at runtime needs
a compiler).

### Runtime dependencies of the commit path this confinement sits behind (ADR-0006)

Every confined launch is preceded by a `commit(attempt.decided)` (`docs/CONTRACT-mediation.md` §2 step
2) and followed by a `commit(attempt.ended)` (step 4) — neither is optional, and both now carry the
`high_water` anchor's own dependencies on the broker's always-anchored path (§8.8,
`docs/CONTRACT-execution-binding.md`). These are distinct from the confined *child's* own dependency
list above — they run in the unconfined broker/manager process, before and after the confined child
exists, never inside it:

- **`flock`** (util-linux) — already a hard dependency of `aib_event_commit` for the stream's own
  sidecar lock; the anchor's repair tool, `bin/anchor reanchor`, takes the same lock and shares the
  dependency.
- **`truncate`** (coreutils) — already a hard dependency of the torn-tail path; unrelated to the
  anchor itself, listed here only because it lives in the same commit-path dependency set the anchor
  now joins.
- **`sync` with file arguments** (GNU coreutils ≥ 8.24) — new in this slice. Checked with `command -v`
  plus a capability probe **at `aib_event_commit`'s own entry**, alongside `flock`/`cksum`, and
  **never at library load** — a load-time check would turn a commit-path dependency into a load-path
  one and brick every read-only consumer that merely sources `lib/aibobnet.sh` (the fold,
  `bin/attempts`, the dashboard, the specs) on a host whose `sync` predates file-argument support.
  Absence fails closed with `aib_die 6`. The probe **never falls back to argument-less `sync`**: bare
  `sync` returns 0 and flushes the whole system, which would make a broken capability check read as
  "satisfied" while the anchor's durability claim (ADR-0006, part A) is silently false. `sync -d
  <events_path>` (fdatasync) covers the stream append; a full `sync` on the anchor's temp file covers
  the anchor's own fresh-inode write, before its rename.

Anchor maintenance additionally uses `mktemp`, `mv`, `rm`, and `dirname` (coreutils);
`mkdir` creates stream/admission directories and `cksum` validates the framed stream. The sync
probe uses a temporary file under `TMPDIR` (default `/tmp`), checks rejection of a missing file,
then checks both data-only and full file sync. These checks run only for anchored commits.
Admission also requires `flock` and `rm` before any registry read; storage or lock failures are
reported on the wire as `event_store_unavailable`. The repair tool uses the same coreutils and
stream-lock dependencies, with no provider or C helper involved.

A broker unit missing any of these fails every anchored commit closed with exit 6 — the same posture
`docs/CONTRACT-execution-binding.md` §8.4 already documents for the launcher's other runtime
dependencies, extended to anchored writes in this slice.

**`python3` is the one optional runtime dependency**, and it runs in the unconfined broker/manager
process, never inside the sandboxed child or the Landlock helper. It sharpens disconnect detection
(the `poll(2)`-based liveness probe — see SPEC-wire-format.md, "Detecting a disconnected client
while the provider is silent") from "next real write" latency down to one idle tick. When it is
absent, `_aib_enact_conn_alive` returns "alive" unconditionally and enactment degrades gracefully to
next-write-only detection — never a crash, never a hang, and the probe never writes a byte to the
wire either way. An operator auditing this path's runtime dependencies should install `python3` if
they want the sharper detection; its absence is a documented degradation, not a defect.

### Exhausted process-group cleanup

The bash manager enables job control only while spawning the provider, making `$!` its process-group
leader; no external `setsid` is required. After reaping the leader and completing any scheduled
TERM/KILL escalation, the manager waits up to two seconds for the group to disappear. If needed it
sends another group KILL and waits up to three more seconds. A group that remains non-empty does
not block the connection forever: the manager logs the exhausted cleanup and proceeds with the
reaped leader's status, recording **`exit.group_empty: false`** in `attempt.ended`. The wire adds
`group_empty=false` and `reason=escalation_exhausted`. Consumers must not interpret that outcome as
confirmation that every group member has disappeared. Ordinary paths, including refusals before a
provider starts, record `group_empty: true`; the ordinary wire shape is unchanged.

The internal `_aib_enact_wait_group_empty` library function can be replaced after sourcing in a
test subshell to exercise exhaustion without creating an unkillable process. The broker exposes
no request field, environment variable, or command-line flag for replacing this probe.

## Why the helper is built at install time and not shipped as a binary

A committed binary is architecture- and libc-specific, and it asks every reader to trust a build they
cannot reproduce — in a repository whose purpose is that they do not have to. The source is therefore
in `src/`, and the install step compiles it. The result is owned by the deploy account and is not
writable by an agent.

A compiler is consequently needed **at install time only**. On a development host that is not a
meaningful exposure: the agent account already has a shell, node and python, so arbitrary code
execution is long since available and a compiler adds little. On a production host the compiler is
removed after the install, through the mediated package wrapper.

### The install step, concretely

```
cc -O2 -Wall -o /opt/aib/engine/libexec/landlock-exec src/landlock-exec.c
chown root:aib-broker /opt/aib/engine/libexec/landlock-exec
chmod 0750 /opt/aib/engine/libexec/landlock-exec
```

Owned `root:aib-broker 0750` (never `aib-broker:aib-broker`, the same reasoning as the TCB
directories' metadata-gap fix above): the broker account can exec it but not overwrite it, so a
confined child that somehow reached the broker account still cannot replace the helper it was
launched through. `deploy/systemd/aib-broker@.service` points `AIB_CONFINE_BIN` at this exact path
via `Environment=`, unconditionally — there is no code path in `bin/aib-broker-handler` or
`aib_enact_launch` that falls back to a different location or skips the helper when it is missing;
a missing or non-executable helper is D-A's pre-flight failure (`io-refused`, `stage=confine`), not
a silent bypass.

### Registry and writable project paths

The shipped `deploy/systemd/aib-broker@.service` sets
`AIBOBNET_REGISTRY=/opt/aib/registry.json`. Install the registry at that path with
broker read access; without this binding the handler reports `registry_unavailable`.

**ReadWritePaths MUST include every registry project home and standup_dir.**
`ProtectSystem=strict` makes other persistent paths read-only even when their normal
ownership would permit writes. The default `/var/lib/aib /run/aib` paths cover broker
state, not project workspaces or heartbeat logs. The filesystem allowlist installed
by Landlock cannot make a read-only systemd mount writable.

Copy `deploy/systemd/aib-broker@.service.d/site.conf.example` to the installed template's
drop-in directory as `site.conf`, replacing `<site>` with the trusted deployment tree:

```ini
[Service]
ReadWritePaths=/srv/<site>
```

Include further paths if any registry `home` or `standup_dir` is outside that tree.
Keep the base unit's existing write paths (do not reset the directive with an empty
assignment). The directories must also have ownership and permissions allowing the
broker's required writes; `ReadWritePaths` does not grant filesystem permissions.
The `.example` suffix prevents the sample from being applied before site configuration.

## Read-only visibility commands

`bin/project` and `bin/attempts` require Python 3.9+ (standard library only; `zoneinfo` uses the
host timezone database), plus the existing Bash/awk registry reader. Projection strings, including
messages, pass through `aib_json` in one batched shell encoder invocation. The projector uses
GNU coreutils `realpath`, `mktemp`, `mkdir`, `cat`, `chmod`, `mv` (with `-T`), and `rm` for path checking and atomic
publication; it never invokes `flock` or opens an admission lease. Python remains optional for the
broker's connection-liveness probe; neither admission nor event commits acquire a Python dependency.
Output ownership (`aib-broker:aib-shared`) belongs to provisioning, not the reader.
