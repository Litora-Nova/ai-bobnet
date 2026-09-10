# ADR-0009: The `codex` Provider Adapter — Exec-Wrapper, Bypassed Sandbox, Stdin Prompt

## Status

Accepted

## Date

2026-09-10

## Context

RM-3 slice 3 built the confinement path (`docs/CONFINEMENT.md`) and RM-3 slice 5 the anchor, but every
launch since RM-0 has run against a stub CLI shape (`tests/broker_enact_spec.sh`), never a real
provider binary. Sprint I-B slice 1's design (`standup/_design_codex-adapter.md` v1) proposed the
first real adapter; an architecture consult (`standup/_advisor_codex-adapter.md`, GO_WITH_NOTES, one
NO_GO) probed the real static binary (`codex-cli 0.153.4`, musl static-pie) directly on the dev host
and found three of v1's premises wrong before anything was built. This ADR records the corrected
decisions (v2, all adopted) and the alternatives they replaced.

## Decision

### A. An exec wrapper, not a driver

`adapters/codex` is a thin, `≤ 80`-line bash script: it validates its own received argv against the
frozen ABI (`docs/CONTRACT-codex-run.md` §4.1), re-shapes it for the wrapped binary, and `exec`s. Its
only longer-lived fork is the process-substitution stdin feeder; that feeder remains in the same
process group. This keeps the broker's process-group, watchdog, and exit model (`lib/aibobnet.sh`'s
`set -m` group-leader mechanics) exactly as already pinned: the adapter is one more link in a single
exec chain (helper → adapter → wrapped binary), never a second process the manager has to track.

### B. Codex's own sandbox is bypassed; Landlock is the sole sandbox of record

**Rejected as written (NO_GO, advisor finding F1): passing `-s <value>` straight through and trusting
codex's own sandbox alongside Landlock.** The pinned binary's Linux sandbox is bubblewrap-only
(`features list` shows `use_linux_sandbox_bwrap` always on, `use_legacy_landlock` deprecated and
panicking if forced), and bubblewrap needs `mount`/`pivot_root` in a fresh mount namespace — syscalls
the kernel's Landlock filesystem hooks deny (`EPERM`) to an already-restricted task, independent of
any other namespace setting. Under that premise every model-run shell command would fail inside
`run_confined`, and the acceptance prompt would "succeed" as a model answer with no command actually
executed — a false green, not a working sandbox.

**Adopted:** the adapter validates `-s <value>` for shape only (refusing `danger-full-access`
unconditionally) and always passes `--dangerously-bypass-approvals-and-sandbox`, the wrapped binary's
own documented mode for an externally-sandboxed caller. `run_confined` then derives `LL_RW` from the
**effective** sandbox (`docs/CONFINEMENT.md`, "Effective-sandbox → `LL_RW`") — Landlock is the only
enforcement point left, and because the effective sandbox is the PDP's own clamp, a request can only
narrow that cage, never widen it by asking the wrapped binary to open a second, conflicting one of its
own (D-B2 holds unchanged).

### C. The credential lives at the broker account's own `$CODEX_HOME`, not a new store

**Rejected: a broker-owned, read-only credential handoff, or a new `providers.codex`-scoped
environment variable.** The confined child runs as `aib-broker` (`deploy/systemd/aib-broker@.service`,
`User=`), and the wrapped binary **writes** to `$CODEX_HOME` on first start (config, sqlite state,
extracted helpers) and rewrites `auth.json` on OAuth refresh — a read-only handoff breaks it at the
first real run, and `CODEX_HOME` is not in `AIB_ENV_ALLOW_DEFAULT` (`HOME PATH` only,
`lib/aibobnet.sh`), so no new variable reaches the child without widening that allow-list, which this
slice does not do. `/var/lib/aib/auth`, the broker's own trust store, is a different thing entirely
and stays out of `LL_RW` — the confined child must not be able to traverse it.

**Adopted:** the credential is the broker account's own `$HOME/.codex/auth.json`
(`CODEX_HOME=/var/lib/aib/.codex`, since `aib-broker`'s passwd entry sets `HOME=/var/lib/aib`),
provisioned there by the operator (T4, `docs/PROVIDERS.md`'s recipe), with `$HOME/.codex` added to
`LL_RW` as a unit-derived, never request-derived, addition (`docs/CONFINEMENT.md`). This keeps the
`env -i` allow-list at exactly `HOME PATH` — the credential reaches the child because `HOME` already
does, not because of a new variable.

### D. The prompt travels on stdin, never argv

**Rejected: the frozen PEP argv's trailing `<prompt>` token passed straight through to the wrapped
binary's own trailing argv token.** `/proc/<pid>/cmdline` is world-readable for the whole run; nothing
in this repository's docs accepted that exposure (no mention of `cmdline`/`hidepid`/`ProtectProc`
before this slice), and the wrapped binary independently reads fd 0 to EOF whenever it is not a
terminal — meaning an unrelated inherited stdin (e.g. the broker's own socket, in some future call
shape) could deadlock a launch until the watchdog fires.

**Adopted:** the adapter delivers the prompt on the wrapped binary's stdin, byte-exact (a process
substitution, not a `<<<` here-string, which appends a newline), with a bare `-` positional token
telling the wrapped binary to read it. The adapter itself pins stdin closed to that exact byte range
(no trailing bytes, no inherited fd), so a prompt can begin with `--dangerously`
and still never be interpreted as a flag — the validation happens on argv before `--`, and the prompt
after `--` is never inspected as anything but bytes. The transient adapter/feeder argv can
still expose those bytes before completion; only the wrapped binary's argv is prompt-free.
Process visibility restrictions do not isolate attempts sharing the same broker uid.

### E. Broker-account divergence, recorded rather than fixed here

Every agent's provider process runs as `aib-broker` today, regardless of the request's own
`agent_uid` — role accounts (the RM-3 target) are not switched to before `exec`. This slice does not
build that switch; `docs/CONFINEMENT.md` records it as a dated divergence, the same posture already
used for `LL_RO=/`, rather than silently shipping it undocumented.

## Alternatives Considered

### `--ignore-user-config`

Rejected (v1, unchanged in v2). The per-role `config.toml` is the operator's own knob for defaults the
broker does not pass (MCP servers, hooks, `shell_environment_policy`); suppressing it would remove
that knob for no offsetting safety gain, operator defaults must remain available. Root ownership prevents in-place writes to
`config.toml`, but its writable parent still permits replacement (`docs/PROVIDERS.md`); stronger
configuration isolation is a provisioning follow-up, not a property of this wrapper.

### A denylist of `--dangerously-*` tokens in the prompt

Considered, rejected (advisor Q2). The adapter validates argv **positively** against the exact
contract shape before `--`; the prompt after `--` is never inspected at all, so a prompt beginning
with `--dangerously` is safe by construction and a denylist would be redundant, incomplete-by-nature
defense.

### Per-project `CODEX_HOME`

Considered, deferred (advisor F3). Correct long-term fix for the shared-state concern (§C above), but
it needs one `auth.json` per project — a T4 decision this slice does not make on the operator's
behalf. `--ephemeral` plus a root-owned `config.toml` is the cheap mitigation adopted now;
`docs/PROVIDERS.md` names the deferred fix explicitly rather than leaving it implicit.

## Consequences

- `docs/CONTRACT-codex-run.md` gains §4.1, the adapter ABI amendment: stdin prompt, fixed flags,
  wrapper-exported `SHELL`/`TERM`, and the 65/78 exit codes.
- `docs/CONFINEMENT.md` gains the effective-sandbox → `LL_RW` table, the `$HOME/.codex` rationale, the
  `/var/lib/aib/auth` exclusion, the `hidepid=invisible` expectation, and the broker-account
  divergence note.
- `docs/PROVIDERS.md` is new: placement, the operator's credential recipe, the effort table, the
  sandbox mapping and refusal, the exit-code table, and the registry entry example.
- `tests/adapter_codex_spec.sh` is new and RED until `adapters/codex` exists and `run_confined`'s
  `LL_RW` derivation is amended to match.
- `bin/launch-agent`'s hard-coded `case "$AIB_PROVIDER" in codex) ;; *) …` case is specified to be
  removed (A9/F8): "provider names a registered adapter" is safe once the frozen argv is documented as
  the adapter ABI every adapter must accept, and the resolver (exit 3) and PDP (exit 127) already
  cover an unregistered or unimplemented one.
- LL_RO narrowing itself is **not** built by this slice — A11's strace measurement method is pinned as
  the next slice's input, not its output.

---
White-label: example project id `acme`; no real names, infrastructure, or hosts.
