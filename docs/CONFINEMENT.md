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

The broker owns the launch, but the prompt that drives the provider child comes from the request.
S1c switches that child to an allow-listed role account before the adapter exec; earlier deployments
ran it as the broker itself. In either case it is agent-directed computation crossing a boundary
whose privileged side owns the event stream, anchor, credentials and adapter map. §2.1 therefore
requires the child to be **confined before `exec`**, with two properties: the restriction is installed
before the foreign code runs, and the restricted process cannot revoke it.

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
resolved adapter and its credential directory is a slice-4/VM item, tracked there, not here. This
paragraph is about `LL_RO` only — `LL_RW`'s own formula is amended below, and stays a positive list
composed from the unit environment and the verdict's effective sandbox, never from the request.

### Effective-sandbox → `LL_RW` (RM-3/slice I-B-1 amendment, ADR-0009)

The flat `LL_RW = <home>:/tmp:/var/tmp:/dev` above composed the same rights regardless of the
effective (clamped) sandbox — which meant `read-only` was, in practice, not enforced by anything at
the filesystem layer: the project home was writable under `read-only` exactly as it was under
`workspace-write`. Building the `codex` adapter is the trigger to close that (`standup/
_advisor_codex-adapter.md` F1): `run_confined` now derives `LL_RW` from the verdict's **effective
sandbox**, not from the registry snapshot alone:

| Effective sandbox | `LL_RW` |
|---|---|
| `read-only` | `/tmp:/var/tmp:/dev:$HOME/.codex` |
| `workspace-write` | `/tmp:/var/tmp:/dev:$HOME/.codex:${resolved_root}` |

`${resolved_root}` (the project `home`) is present only at `workspace-write` and above. This is the
actual filesystem-level enforcement of the refusal `docs/CONTRACT-codex-run.md` §2 already documented
at the policy-gate level (`danger-full-access` rejected) but that, before this amendment,
`run_confined` never wired through to the cage itself. This stays inside D-B2
(`docs/SPEC-wire-format.md`): the effective sandbox is the PDP's own clamp, so a request can only
narrow what `LL_RW` grants, never widen it — the request itself still contributes nothing to either
list.

### Effective sandbox × provider `state_dir` → `LL_RW` (RM-3/slice I-B-2 amendment, ADR-0010, target)

Building the second real adapter (`claude-code`, `$HOME/.claude` instead of `$HOME/.codex`) is what
turns the table above from "the codex row" into a real per-provider axis: `run_confined`'s `LL_RW`
formula is `.codex`-literal today (`lib/aibobnet.sh:1888`), the **only** place outside `adapters/codex`
and registry example data that names a provider by a hard-coded path. The design this slice pins:

- New registry field `providers.<name>.state_dir` (schema 4, additive — `SCHEMA_VERSION` unchanged),
  a single relative path component matching `^\.[A-Za-z0-9_-]+$` (no `/`, no `..`, non-empty). `codex`
  gets `"state_dir": ".codex"` (behaviour byte-identical to today — a regression guard, not a change),
  `claude-code` gets `".claude"`, `stub` declares none.
- The table generalises to `LL_RW = /tmp:/var/tmp:/dev:$HOME/<state_dir>[:${resolved_root}]` (the
  bracketed segment present only at `workspace-write` and above, unchanged from the row above), where
  `<state_dir>` is the **resolved provider's own** value — absent for a provider that declares none,
  never another provider's, never request-derived (D-B2 holds unchanged).
- A `state_dir` that fails the format regex above is a **registry data** error, refused the same way
  `_aib_resolve_provider_caps` already refuses an absent `cap_sandbox`/`cap_tier`/`cap_effort`/
  `cap_timeout` (`lib/aibobnet.sh:842-870`): `aib_die 3 "registry: provider '<name>' ..."`, at
  registry-resolve time, before any launch — the same exit **3** already used for "provider is not
  declared in the schema-4 adapter map." This is a format check on the registry string, not a
  filesystem check, and it runs before `run_confined` is ever reached.

**Real-code seam this generalisation needs (not yet built — pinned here, not assumed away).** The enact
record `run_confined` actually receives (`bin/launch-agent:316`, consumed via `_aib_record_field` in
`aib_enact_launch`) carries exactly `adapter, root, cwd, sandbox, effort, model, timeout` — no provider
*name* and no `state_dir` field. `run_confined` has never read the registry directly (it only ever sees
the manager's own process environment and the enact record's already-resolved values, by the same
purity discipline as the PDP itself, `lib/aibobnet.sh:880-885`), and this slice does not change that.
Generalising the hard-coded `.codex` therefore means threading a new `state_dir` field onto the enact
record itself — resolved from `providers.<provider>.state_dir` at the same call site that already
resolves `adapter`/`cap_*` (`_aib_resolve_provider_caps`) and carried through the verdict record the
same way `adapter` already is — not a provider-name lookup added inside `run_confined`. Until that
field exists, `run_confined` cannot honour it, which is exactly why the two rows above stay
`.codex`-only in the *shipped* code today; this section documents the target, not a claim that it is
already wired.

**A missing or symlinked `$HOME/<state_dir>` must refuse, not silently widen or silently fail past
the adapter (F7, `standup/_advisor_claude-code-adapter.md`).** `src/landlock-exec.c:84` opens every
`LL_RW` path with `O_PATH`, which **follows symlinks** — a symlinked state dir would grant Landlock
rights on whatever it points at, not the intended directory. A missing path fails the helper's own
add-rule step (`:188`) before the adapter's own credential pre-flight ever runs, so the failure would
surface as a bare confinement failure, never as the adapter's own **78**. The fix belongs in
`run_confined`, applies to **both** providers alike (not a `claude-code`-only guard), and is cheap:
before composing `LL_RW`, require `[ -d "$HOME/$state_dir" ] && [ ! -L "$HOME/$state_dir" ]`; on
failure, refuse the launch the same way the pre-flight above already does for "confinement is not
available right now" — `exit_class=io-refused`, `stage=confine`, `reason=confinement_unavailable`
(`aib_enact_launch__write_terminal`'s existing vocabulary, `lib/aibobnet.sh:2298-2326`). **This exact
mapping is this pin's own inference, not a literal sentence in the v2 design** (which says only
"refuse," `standup/_design_claude-code-adapter.md` B15) — it is the closest existing vocabulary this
code already has for "the cage cannot be composed as asked," and the RED spec pins it as the target;
the builder should keep it unless a documented reason says otherwise, and if it changes, this
paragraph moves with it. `$HOME/.codex` today has no such guard either — F7 applies to it too, fixed
once, generically, in the same amendment that adds the field.

**`$HOME/.codex` is unconditional, in both rows, because the adapter cannot start without it.**
Measured against the pinned static binary with an empty `$CODEX_HOME` (`standup/
_advisor_codex-adapter.md` F2): on first start it creates `config.toml`, `installation_id`, six
sqlite databases with WAL/SHM files (`state_5`, `logs_2`, `queue_1`, `memories_1`, `goals_1`,
`thread_history_1`), `sessions/`, `shell_snapshots/`, `skills/`, `tmp/`, `thread-writer-locks/`, and
`mcp-oauth-locks/`, and it extracts its own helper binaries under `$CODEX_HOME` — a step it refuses
outright when `$CODEX_HOME` resolves under `/tmp` (already in `LL_RW`, but not an acceptable
substitute: the adapter's own carve-out is unconditional and independent of where `/tmp` happens to
be mounted). It also rewrites `auth.json` in place on an OAuth token refresh, so the credential file
itself must sit inside a writable, not merely readable, directory. `LL_RW` grants execute as well as
read/write, which the extracted helper binaries need to run at all.

**`/var/lib/aib/auth` is never in `LL_RW`.** That path is the broker's own trust store — distinct from
the provider's file-based credential precondition (`docs/CONTRACT-execution-binding.md` §7.5) — and
the confined child must not traverse it: granting it, even read-only, would hand a provider process a
path it has no legitimate reason to open. It stays absent from both rows above, and A11's measurement
(below) lists it explicitly as a path the real launch must **not** need to touch, not merely one that
happens to be unlisted.

**`hidepid=invisible`.** The adapter delivers the prompt on stdin, keeping it out of the wrapped
binary's argv; the transient adapter or a blocked stdin feeder can still retain it in
`/proc/<pid>/cmdline` (`docs/CONTRACT-codex-run.md` §4.1). Provisioning is expected to mount `/proc`
with `hidepid=invisible` to prevent unprivileged accounts such as `aib-agent` or `aib-dash` from
enumerating another uid's process entries. This does not isolate attempts sharing the broker uid,
and privileged observers remain outside that protection. Nothing in this repository's own read
paths (the projection is file-based, never a `/proc` scan) depends on seeing another account's
processes.

**Role-account execution (2026-10-20).** The broker still accepts and audits requests as
`aib-broker`, but the confined exec path now passes the provisioned `AIB_ROLE_UID` and
`AIB_ROLE_GID` to `landlock-exec`, plus `--groups` from `AIB_ROLE_GROUPS` when that is configured.
The helper applies Landlock first, sets exactly the allow-listed supplementary groups (or clears them
when no `--groups` is given), switches gid and uid, clears all remaining capability sets and the
ambient set, and then executes the adapter. Every `--groups` gid must be strict decimal, not 0, and
listed in `AIB_ROLE_GROUPS`; there is no numeric floor, because provisioning creates the shared and
login groups as system groups. The role, gid and group list come from
`/etc/aib/role.env`, which provisioning must keep root-owned and not writable by others (the engine does
not check its owner or mode) (template `deploy/role.env.example`) read by the broker drop-in, never from a
request. Groups the role account has outside this list, such as the control group, do not reach the
confined turn. `bin/aib-agent-dirs` prepares the role-owned private home beneath `/var/lib/aib-sup` before
the unit starts; a one-shot agent without a supervisor unit needs one root run of it as well. The home is
mode `0710` and carries one extra ACL entry, search-only (`--x`) for the broker group, so the broker can
run its pre-flight and set the Landlock path rules inside it without listing the directory. A default
broker ACL grants read-only (`r--`) access to newly created state files, including `journal.jsonl` and
atomic replacements of `live.json`; an existing `live.json` receives the same named read ACL during
provisioning. The broker receives no write permission. The broker unit therefore needs only
`CAP_SETUID` and `CAP_SETGID`, bounded as shown
in the shipped S1c drop-in example. The helper deliberately rejects uid 0 and role uids below 1000;
the configured gid is broker-controlled and is not an independent user input.

The helper is the sole owner of this directory contract. It creates `/var/lib/aib-sup` as root-owned
`0755`, then prepares the per-agent home, provider directories, and named ACLs. The agent unit therefore
does not use systemd `StateDirectory=` or `StateDirectoryMode=`: the template has no `User=`, so systemd
would recursively restore root ownership and its configured mode after the privileged pre-start helper,
destroying the role ownership and ACLs. `ProtectSystem=strict` remains enabled; the unit grants write
access to `/var/lib/aib-sup` explicitly.

`/srv/aib/standup` is setgid, sticky, and group-writable. With `fs.protected_regular=2`, a writer cannot
open an existing `O_CREAT` heartbeat owned by neither the writer nor the directory owner, even when the
writer is root. Before the supervisor starts, `aib-agent-dirs` therefore creates
`<standup>/<agent>.log` as a regular `0664` file owned by the standup directory owner and group, or
re-owns an existing foreign-owned regular file to the directory owner while preserving its group and
only its read/write permission bits (special and execute bits are removed). The directory-relative
`O_NOFOLLOW` open rejects symlinks; descriptor checks reject non-regular and multiply-linked files. The
supervisor's `inbox/<agent>.md` and `transcripts/<agent>.log` append paths live in non-sticky subdirectories,
so the protected-regular condition does not apply there and their existing ownership contracts are unchanged.

### Documented divergence: shared subscription login (2026-10-20)

Subscription credentials are shared server-wide under `/var/lib/aib/login/<provider>/`. Credential
files are regular `aib-broker:aib-login` files with mode `0640`, inside the setgid login directory.
Every agent role account on that server is intentionally able to read the shared login through the
`aib-login` group. Landlock keeps the store out of writable paths, but this subscription mode is not a
"credential never reaches the agent" design.

For `claude-code`, the broker extracts the access token into an unlinked buffer, opens it,
and hands the already-open descriptor to the role process; the adapter exposes only the descriptor
number. The buffer is created as `aib-broker:aib-login 0640` inside a fresh broker-private `0700`
directory so the role uid can re-open `/proc/self/fd/N`; the file is unlinked after opening and the
empty directory is removed by the confined-run cleanup. For `codex`, the role-owned
`$HOME/.codex/auth.json` is a pinned symlink to the shared
`/var/lib/aib/login/codex/auth.json`, because that CLI consumes its complete authentication object.
The broker-owned `login.meta.json` may retain the full provider account id for internal expiry
tracking, but human-facing status exposes only its last four characters. Device authorization URLs
and user codes are sent only to the human-ops server outbox.

The login unit runs as `aib-broker` with supplementary groups `aib-login` and `aib-gateway`. The
first grants access to the shared credential store; the second grants only the group membership
needed to publish the mode-`0660` code socket in `/run/aib/login` for gateway clients.

Control-plane caller identities come from the kernel uid, then resolve into four disjoint classes.
`role:<name>` is selected first when the numeric uid appears in `AIB_ROLE_UIDS` in the root-owned
`/etc/aib/role.env`; the file is parsed as data and never sourced. `gateway:<name>` is reserved for
accounts named exactly `aib-gw` or `aib-gateway` — membership in the `aib-gateway` group does not
confer gateway identity. Any other account whose name starts with `aib-` is `role:<name>` as well, so
system and role accounts should keep that prefix. A remaining account in `aib-shared` or `aib-ops` is
`human:<name>`; every other uid is `unknown:<uid>`. An unreadable or malformed `AIB_ROLE_UIDS` (for
example a quoted value) makes every caller `unknown:` until root fixes the file: control is locked
out, never widened. This ordering prevents a role account's shared-group membership from
turning it into a human operator.

Two further residuals follow from the group grants and are accepted for the shared subscription
mode. First, the role account is not a member of `aib-login` itself; it holds the group only inside
the confined turn, and the role switch exists only in `landlock-exec`, which fails closed without
Landlock. There the store stays outside `LL_RW`. Should a future path grant the group without
Landlock, DAC alone would let the role create, rename or remove entries in the setgid store directory
(mode `2770`); only the owner and mode checks the refresher and broker apply to every store file would
then stand in the way, turning a tampered file into a refusal and an alarm rather than a silent use.

Second, `_control.jsonl` and the team outbox are group-writable for `aib-shared` as provisioned;
the engine itself does not fix their mode. A confined turn cannot write them while the standup and
outbox trees lie outside the agent's project root (as in the shipped `/srv/aib/standup` and
`/srv/aib/outbox` layout), because only the project root, the provider state directory and the
temporary trees are in its `LL_RW`. Every other process in `aib-shared` can append arbitrary lines.
The project-root guard enforces this separation only for configured and resolvable directories;
unset or not-yet-existing standup, outbox, or control-log directories are skipped.
Both files are report streams. `bin/aib-login` is no longer an exception: it never reads
`_control.jsonl`. `agentctl login start`
keeps its `login.requested` audit record, but also creates a mode-`0644` request in the broker-owned,
sticky mode-`1733` `/run/aib/login-requests` spool. Randomized request names prevent planted entries
from blocking a start. The login unit removes unusable entries, opens only regular request files
without following symlinks, derives the caller from the file's kernel-attested owner uid, and rejects
role uids independently of the mapped identity; a `caller` field in the content has no authority.
The bounded scan leaves an availability residual: local accounts can delay a login by filling the
spool, but their entries can never start or authorize one. A gateway-owned request still passes
through the due and rate-limit gate.

The accepted residual is reporting-only: `agentctl` learns a request's outcome by polling
`_control.jsonl` for a terminal record. An `aib-shared` member can therefore fake the outcome reported
to that waiting caller, but cannot start a login or skip its authorization, due, or rate checks.

API-key mode is the path that restores the stronger "the agent never sees the shared credential"
property. The deployment schema reserves `credential_mode=proxy` for that later mediation path; it
fails closed until built. Operators must not describe the current shared subscription mode as API-key
isolation.

The role gid is selected only by the broker's protected unit configuration. `landlock-exec --gid`
does not carry a second allow-list: the uid must be present in `AIB_ROLE_UIDS`, uid/gid must be passed
together, role uids below 1000 and gid 0 are refused, and provisioning receives the uid/gid pair only
from the protected broker unit configuration. Treat write access to the broker drop-in as equivalent
to control of the role identity.

**A11 — the measurement that feeds `LL_RO` narrowing, not the narrowing itself.** `LL_RO=/` above
stays exactly as dated and unbuilt as before this amendment; this slice's real `codex` launch is the
first opportunity to measure the wrapped binary's actual read set, per the standing precondition
("Narrowing `LL_RO`... is a slice-4/VM item"). The method: `strace -f -o <file> -e trace=%file` (not a
fixed syscall trio — `%file` catches `newfstatat`/`statx`/`readlink`/`execve`/`mkdir`/`rename`/
`unlink`/`connect` alongside the obvious `openat`/`stat`/`access`), run as `aib-broker` under the same
unit constraints the real launch runs under (`systemd-run --uid=aib-broker -p PrivateTmp=yes -p
ProtectHome=yes -p ProtectSystem=strict …`, matching `deploy/systemd/aib-broker@.service`) — not as an
arbitrary shell, because the accessible paths differ by unit. Three prompts, not one: no command, one
shell command, one file edit — the read set for "answer without touching the sandbox" is not the read
set for "run `ls`," and neither is the read set for "write a file." ABI 6 (this host's Landlock
version) has no audit mode; a second launch under the narrowed lists derived from this measurement,
diffed for new `stage=provider` failures, is the audit substitute until ABI 7 (Linux 6.15+) is
available. The output is a list in this document, not a code change — narrowing `LL_RO` from `/` to
that list is its own next slice, with numbers behind it instead of a guess.

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
  `bin/attempts`, the specs) on a host whose `sync` predates file-argument support. (The dashboard is
  no longer on this list, and never was after `docs/decisions/0008-dashboard.md`: `bin/dashboard`
  does not source `lib/aibobnet.sh` at all — see the runtime-dependency note below.)
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

**`python3` is the one optional runtime dependency in the enactment path**; the readers
`bin/attempts` and `bin/project` require Python 3.9+ (see the reader runtime requirements below).
In enactment it runs in the unconfined broker/manager
process, never inside the sandboxed child or the Landlock helper. It sharpens disconnect detection
(the `poll(2)`-based liveness probe — see SPEC-wire-format.md, "Detecting a disconnected client
while the provider is silent") from "next real write" latency down to one idle tick. When it is
absent, `_aib_enact_conn_alive` returns "alive" unconditionally and enactment degrades gracefully to
next-write-only detection — never a crash, never a hang, and the probe never writes a byte to the
wire either way. An operator auditing this path's runtime dependencies should install `python3` if
they want the sharper detection; its absence is a documented degradation, not a defect.

**`bin/dashboard`'s own runtime dependency is `python3` (3.9+) standard library only** — `http.server`
(`ThreadingHTTPServer`, `BaseHTTPRequestHandler`), `html`, `json`, `os`, `pathlib` — no third-party
package, no build step, no `pip install` (`docs/decisions/0008-dashboard.md` §B). Unlike the fold and
`bin/attempts`/`bin/project` above, it is not a "read-only consumer of `lib/aibobnet.sh`": it never
sources that library and never runs inside the broker account at all. It runs under its own account,
`aib-dash`, with read access to `AIB_PROJECTION_ROOT` only — never the credential directory, never the
event stream, never the registry (`docs/decisions/0008-dashboard.md` §D/§E,
`deploy/systemd/aib-dashboard.service`). Its absence is a hard failure, not a degradation: there is no
fallback render.

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

After every registry change that adds or removes a project, provisioning must (re)create the
reader-facing symlinks `<standup_dir>/_projection.json -> <AIB_PROJECTION_ROOT>/<project_uid>.json`
for all registered projects (a root-owned helper, callable by the deploy account) — the projector
never creates them.


```
cc -O2 -Wall -o /opt/aib/engine/libexec/landlock-exec src/landlock-exec.c
chown root:aib-broker /opt/aib/engine/libexec/landlock-exec
chmod 0750 /opt/aib/engine/libexec/landlock-exec
install -d -o root -g root -m 0755 /opt/aib/adapters
install -o root -g aib-shared -m 0750 adapters/codex /opt/aib/adapters/codex
install -o root -g aib-shared -m 0750 adapters/claude-code /opt/aib/adapters/claude-code
```

Owned `root:aib-broker 0750` (never `aib-broker:aib-broker`, the same reasoning as the TCB
directories' metadata-gap fix above): the broker account can exec it but not overwrite it, so a
confined child that somehow reached the broker account still cannot replace the helper it was
launched through. `deploy/systemd/aib-broker@.service` points `AIB_CONFINE_BIN` at this exact path
via `Environment=`, unconditionally — there is no code path in `bin/aib-broker-handler` or
`aib_enact_launch` that falls back to a different location or skips the helper when it is missing;
a missing or non-executable helper is D-A's pre-flight failure (`io-refused`, `stage=confine`), not
a silent bypass.

The adapters differ from the helper deliberately: the broker executes `landlock-exec`, but after the
uid switch the role account executes the adapter. Adapter ownership is therefore
`root:aib-shared 0750`: provisioned role accounts can execute it through their allow-listed shared
group, while neither they nor the broker can replace it. This assumes `aib-shared` is in
`AIB_ROLE_GROUPS`, which provisioning sets and the engine does not verify. Human members of
`aib-shared` can read and execute the adapters too; they hold no secrets. Installed adapters are copies,
so they must be reinstalled whenever the engine is updated.

### Registry and writable project paths

The shipped `deploy/systemd/aib-broker@.service` sets
`AIBOBNET_REGISTRY=/opt/aib/registry.json`. Install the registry at that path with
broker read access; installed Python control tools and shell tools that use the shared
registry resolver also select this path unconditionally when the engine root contains
`.aib-installed`. Without this binding the handler reports `registry_unavailable`.

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
host timezone database), plus the existing Bash/awk registry reader. Python runs in isolated mode
(`-I`), ignoring ambient Python import paths and the current working directory. Projection strings, including
messages, pass through `aib_json` in one batched shell encoder invocation. The projector uses
GNU coreutils `realpath`, `mktemp`, `mkdir`, `cat`, `chmod`, `mv` (with `-T`), and `rm` for path checking and atomic
publication; it never invokes `flock` or opens an admission lease. Python remains optional for the
broker's connection-liveness probe; neither admission nor event commits acquire a Python dependency.
Output ownership (root-owned, group `aib-broker`, readers via ACL — ADR-0007 §B) belongs to provisioning, not the reader.

### Measured read set of the codex adapter (input to the `LL_RO` narrowing)

Measured on the dev host (Landlock ABI 6, `strace -f -e trace=%file` as the broker account, outside Landlock,
three prompts: no command, one command, one file create+delete). Successful **writes** occurred only under
`$HOME/.codex` (plugins, cache, shell snapshots, tmp, six sqlite databases with WAL/SHM), `/dev/null` and
`/dev/tty`; the project home was written only by the model's own command; the broker trust store under
`/var/lib/aib/auth` was never opened. Successful **reads**: `/usr` (locale, ssl, shared objects, the shell
and coreutils the model invokes), `/lib`, `/etc` (CA bundle and certificates, `hosts`, `passwd`,
`resolv.conf`, `localtime`, `os-release`, `profile.d`, `codex/hooks.json`), `/proc/self` and `/proc/version`,
`/sys/fs/cgroup` (cpu.max), `/dev`, the binary tree, the project home plus `.git` probes up the tree.
Proposed narrowed list for the next slice, to be confirmed by a launch under it:
`/usr:/lib:/lib64:/etc:/proc:/sys:/dev:<binary tree>:<adapter dir>:$HOME/.codex:${resolved_root}` — never
`/var/lib/aib` as a whole, never `/home`, never the parent of the project home.

### `claude-code`'s footprint — probed, not yet strace-measured

`strace` is unavailable on this dev host for `codex` too (the gap the section above already documents);
for `claude-code` the same live-VM `LL_RO` narrowing is deferred identically, tracked as the same
slice-4/VM item, not built here. What is known without it (`standup/_facts_claude-code-adapter.md`,
`standup/_advisor_claude-code-adapter.md` F5, unauthenticated `env -i HOME=<empty>` runs and a local
fake Messages API — never a real Anthropic endpoint): the wrapped binary is a dynamically-linked ELF
(needs the dynamic loader plus `libc`/`libm`/`librt`/`libpthread`/`libdl` readable at exec, unlike
`codex`'s static build — `LL_RO=/` already covers this), and it writes to `$HOME` **unconditionally,
even unauthenticated** (`.claude.json` and its backups, `.claude/{sessions,projects/<slug>/memory,
session-env}`) — a second, independent reason `$HOME/.claude` must be unconditionally in `LL_RW`, in
both rows, parallel to `$HOME/.codex`. With `CLAUDE_CONFIG_DIR=$HOME/.claude` set, all of that (plus
`.claude.json` itself) moves inside `.claude`, confirmed by probe (F5). Two footnotes carried into
`docs/PROVIDERS.md` rather than repeated here: an MCP server session additionally writes cache files
under `$HOME/.cache/claude-cli-nodejs/...` unless `XDG_CACHE_HOME` is redirected inside `.claude`, and
`$TMPDIR/claude-<uid>/` is covered by the existing `/tmp` grant, shared across attempts like every
other `/tmp` write in this cage.
