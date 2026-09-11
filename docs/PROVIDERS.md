# ai-bobnet — Provider Adapters

This document lists what provisioning installs for each registered `providers.<name>` entry
(`docs/CONTRACT-execution-binding.md` §7.3, schema 4) and, for `codex`, the operator's own credential
recipe. `docs/CONTRACT-codex-run.md` §4.1 is the adapter ABI every entry here must accept; this
document is the per-provider deployment and operational detail behind that ABI, not a restatement of
it.

## `codex`

### Placement

| What | Path | Owner / mode |
|---|---|---|
| Wrapped binary | `/opt/aib/codex/<version>/codex` | root:aib-runtime 0755, static build, checksum pinned by provisioning |
| Adapter | `/opt/aib/adapters/codex` | root:aib-broker 0750, from this repo's `adapters/codex`, install-time copy |
| `CODEX_HOME` | `/var/lib/aib/.codex` | aib-broker:aib-broker 0700, created empty by provisioning |
| `config.toml` inside it | `/var/lib/aib/.codex/config.toml` | root:aib-broker 0644 |

`/opt/aib/codex/<version>/codex` is an immutable versioned install. Provisioning updates the
`/opt/aib/codex/current` symlink to select a version; the adapter defaults to
`/opt/aib/codex/current/codex`, while the registry continues to name the adapter. There is no
in-place binary rewrite. The adapter resolves the binary from that default; `AIB_CODEX_BIN` overrides that default when set, a deploy/test
seam analogous to `AIBOBNET_REGISTRY`'s "advanced/test locator" (`docs/CONTRACT-execution-binding.md`
§3) — never propagated by the broker's own `env -i` allow-list, never influenced by the request, and
absent in every production invocation. `tests/adapter_codex_spec.sh` is the one caller that sets it,
to point the adapter at a fake binary instead of the real one.

`$CODEX_HOME` is unconditionally in `LL_RW` for both effective sandboxes
(`docs/CONFINEMENT.md`, "Effective-sandbox → `LL_RW`") — the adapter's wrapped binary cannot start
against an unwritable `$CODEX_HOME` (measured write set: `config.toml`, `installation_id`, six sqlite
databases, `sessions/`, `shell_snapshots/`, extracted helper binaries — see `docs/CONFINEMENT.md` for
the full list).

### Sibling binary

The static build extracts nothing at runtime, but it spawns a **sibling executable** it expects next to
itself (`codex-code-mode-host`, shipped in the same package under `vendor/<triple>/bin/`). Without it the
run still ends `ok`, yet the tool router logs "failed to spawn code-mode host" and the model executes no
command — an answer without an action. Provisioning installs both files from the same pinned archive.

### Credential recipe (the operator's step, T4)

The adapter's credential check is file-based only, matching the deployment precondition already
stated in `docs/CONTRACT-execution-binding.md` §7.5 for the seam as a whole:

1. Preferred: run the wrapped binary's own login flow **on the broker host, as the broker account**, so the
   credential is created in place and never exists as a copy elsewhere. The browser callback the login
   opens on `localhost` is reached through an SSH port forward from the operator's machine:
   `ssh -L 1455:127.0.0.1:1455 <operator>@<host>`, then
   `sudo -u aib-broker -H env HOME=/var/lib/aib CODEX_HOME=/var/lib/aib/.codex /opt/aib/codex/current/codex login`
   and open the printed URL locally. (`codex login --with-api-key` reads a key from stdin and needs no
   browser.) This is a T4 (credential) action: PO-only, per the standing tier rule this repository
   inherits — no code path in this repository performs it on the operator's behalf.
2. Alternative: log in on a trusted machine and copy `auth.json` to `/var/lib/aib/.codex/auth.json`
   over an already-authenticated channel (SSH); the credential is not bound to the machine.
3. Verify `ls -l /var/lib/aib/.codex/auth.json` shows `aib-broker aib-broker` and mode `0600`; otherwise
   `chown aib-broker:aib-broker` and `chmod 0600` it.

The adapter refuses to start (exit **78**, one line, never the prompt) unless, at launch time:

- `$HOME/.codex/auth.json` exists and is a regular file, not a symlink;
- it is owned by the adapter's own running uid;
- its mode is `0600`;
- `$HOME/.codex` itself is a directory with mode `0700`, not a symlink.

An unset/empty HOME or failed metadata lookup is also a credential refusal. The Linux wrapper
uses GNU `stat` and compares the file owner with Bash's running effective uid; it never reads the
credential contents, compares mtimes, or caches a check across launches.

The check tolerates an **OAuth refresh rewrite** of `auth.json` (owner and mode are re-checked on
every launch; mtime and content are never compared against a prior value) — the wrapped binary is
expected to rewrite this file in place when a token refreshes, and that rewrite must not turn a
working credential into a launch failure on the very next attempt. An API-key `auth.json` does not
refresh and needs no such tolerance; the check is identical for both.

### Effort mapping

| Registry `effort` | `model_reasoning_effort` |
|---|---|
| `low` | `low` |
| `medium` | `medium` |
| `high` | `high` |
| `max` | `xhigh` |

Every other token is a shape refusal, exit **65**. Only `max→xhigh` renames; the other three pass
through their own name. This table is single-sourced with the adapter's own validation — a spec
assertion that changes one side without the other is a spec bug, not a documentation drift, because
there is exactly one place this mapping is expressed as code.

### Sandbox mapping and refusal

`read-only` and `workspace-write` pass through to the wrapped binary's own `-s` flag unchanged (the
value is otherwise unused — see `docs/CONTRACT-codex-run.md` §4.1 for why the wrapped binary's own
sandbox enforcement is bypassed and Landlock is the sandbox of record). `danger-full-access` is
refused by the adapter itself, exit **65**, unconditionally — even where the registry's `cap_sandbox`
would otherwise permit it. This is a wrapper-owned refusal, independent of and in addition to the
`docs/CONTRACT-codex-run.md` §2 refusal at the `codex-run` compatibility layer: the two refusals sit
at different seams (compatibility CLI vs. adapter ABI) and neither substitutes for the other.

### Exit codes

| Code | Meaning |
|---|---|
| `65` | shape, effort, or sandbox refusal (`EX_DATAERR`) — a malformed or disallowed argv token before `--`, never the prompt itself |
| `78` | credential missing, wrong mode, or foreign-owned (`EX_CONFIG`) |
| any other | the wrapped binary's own exit code, passed through unmodified |

The adapter never itself exits `124`, `126`, or `127` — see `docs/CONTRACT-codex-run.md` §4.1. `65`
and `78` are both disjoint from the PDP's own `64` (`docs/CONTRACT-execution-binding.md` §7.6).
For provider exits `65` and `78`, the existing `_aib_enact_map_status` (`lib/aibobnet.sh`) records
`attempt.ended(provider-failure, stage=provider)`; no terminal mapping changes are needed.

### One shared `CODEX_HOME`

Every agent and every project's attempt runs as the one broker account (`docs/CONFINEMENT.md`,
"Documented divergence"), so they all share one `$CODEX_HOME`: one `sessions/` history (mitigated —
not eliminated — by `--ephemeral`, verified to suppress `sessions/` writes; the sqlite state files
still accumulate across attempts), one `thread_history` and persistent-memory database, and one
`config.toml`. `--ephemeral` is a fixed flag precisely because it is the cheap half of that mitigation
available today; the full fix (a `CODEX_HOME` per project, keyed off `AIBOBNET_PROJECT_UID`, each with
its own `auth.json`) is a later slice and its own T4 decision, not built here. Provisioning owns
`config.toml` as `root:aib-broker 0644` to prevent in-place writes to that inode. This does not
make operator defaults immutable: the broker-owned writable parent directory permits unlink or
replacement, which the current Landlock write grant also permits. Protecting the configuration
from replacement needs a separate provisioning boundary; it is a follow-up, not a guarantee of
this slice. MCP servers, hooks, `model_provider` and `shell_environment_policy` remain shared
operator defaults under the documented cooperative-with-audit boundary.

The adapter's credential checks are metadata-only and sequential (type and symlink test, then directory
mode, then owner and file mode). A writer who already has write access to `CODEX_HOME` could replace
`auth.json` between two of those checks. That writer sits inside the same trust boundary as the shared
home itself, so the gap adds no authority beyond what this section already grants; it closes with the
per-project `CODEX_HOME` and the role-uid switch recorded as follow-up slices.

### Registry entry (example, `acme`)

```json
{
  "schema_version": 4,
  "providers": {
    "codex": {
      "adapter": "/opt/aib/adapters/codex",
      "cap_sandbox": "workspace-write",
      "cap_tier": "t3",
      "cap_effort": "high",
      "cap_timeout": "3600"
    }
  },
  "projects": {
    "acme": {
      "home": "/srv/acme",
      "standup_dir": "/srv/acme/standup",
      "mux_session": "acme",
      "provider": "codex",
      "model": "example-model",
      "effort": "high"
    }
  }
}
```

`cap_timeout` above is generous (an hour) relative to `docs/CONTRACT-codex-run.md`'s own `1200`s
default at the compatibility layer — the registry cap and a request's own `--timeout` still clamp to
`min(requested, cap_timeout)` (`docs/CONTRACT-execution-binding.md` §7.2) exactly as for every other
provider; nothing about the `codex` adapter changes that arithmetic.

## `stub`

The reference test-matrix provider (`tests/broker_enact_spec.sh`'s stub shape, deployed on the VM as
`stub-codex` — `standup/_vm_exercise_rm3-slice4.md`) stays registered alongside `codex`, at a
permissive-but-narrow capability set, so the confined path can be exercised end-to-end without a real
provider binary or credential. It is not documented here beyond this pointer: its behavior is the
stub CLI shape already pinned by `tests/broker_enact_spec.sh`, not a deployment contract of its own.

---
White-label: example project id `acme`; no real names, infrastructure, or hosts.
