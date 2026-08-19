# ai-bobnet — Confining the provider child (contract §2.1)

**Status:** decided 2026-08-19, measured on a live VM. Nothing here is built into the launch path
yet — that is slice 4. This document exists so the decision is not re-litigated when it is.

## What §2.1 requires

The provider child runs under the broker account, but the prompt that drives it comes from the
request. So it is agent-directed computation running inside the account that owns the event stream,
the anchor, the credentials and the adapter map. §2.1 therefore requires the child to be **confined
before `exec`**, with two properties: the restriction is installed before the foreign code runs, and
the restricted process cannot revoke it.

**Minimum:** no write access to the event stream, the high-water anchor, the registry, the adapter
map or the installed engine. Read access to the credential directory only as far as the adapter needs.

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

## Why the helper is built at install time and not shipped as a binary

A committed binary is architecture- and libc-specific, and it asks every reader to trust a build they
cannot reproduce — in a repository whose purpose is that they do not have to. The source is therefore
in `src/`, and the install step compiles it. The result is owned by the deploy account and is not
writable by an agent.

A compiler is consequently needed **at install time only**. On a development host that is not a
meaningful exposure: the agent account already has a shell, node and python, so arbitrary code
execution is long since available and a compiler adds little. On a production host the compiler is
removed after the install, through the mediated package wrapper.
