# ai-bobnet — codex-run Contract (the codex() driver, as an engine primitive)

Builds on P0 (identity/registry). **`bin/codex-run` makes "drive Codex as a teammate" a first-class,
deterministic engine primitive** — a watchdogged, heartbeat-owning wrapper around the `codex exec` CLI.
It exists to fix the two structural friction points found in field use (the bob-code-router practice day):

1. **A raw `codex` call blocks with no self-timeout** — a hung inference is locally indistinguishable
   from a thinking one (`ps` shows 0 % CPU either way; inference runs server-side). Nobody notices a hang.
2. **A read-only Codex helper cannot write a heartbeat** — it is invisible to the fleet while it works.

`codex-run` owns the timeout (watchdog) and owns the heartbeat for its ephemeral Codex helper, so any
caller — a script, a routine, or a Claude runner subagent — gets a bounded, observable Codex call.

## 1. Invocation
```
bin/codex-run --as <agent_uid> [options] (--prompt <text> | --prompt-file <f> | -)
```
- `--as <agent_uid>` **REQUIRED** — the identity the heartbeat is written under (registry-resolvable, P0
  rules). Validated fail-closed; unresolvable ⇒ loud refusal, never a default.
- `--prompt <t>` / `--prompt-file <f>` / `-` (stdin) — the instructions for Codex (exactly one source).

## 2. Options & fail-closed defaults
| Option | Default | Notes |
|---|---|---|
| `--model <m>` | `gpt-5.6-luna` | builder/cheap default; heavy review = a `sol`-class model |
| `--sandbox <s>` | `read-only` | **safe default**; `workspace-write` opt-in; `danger-full-access` **refused** (exit 64) |
| `--cwd <dir>` | `$PWD` | Codex runs here — must exist (else exit 2); pass the worktree root, never the wrong tree |
| `--timeout <secs>` | `1200` | watchdog deadline; must be a positive integer |
| `--effort <e>` | `high` | `low\|medium\|high\|max` → `model_reasoning_effort` |
| `--label <t>` | `codex-run` | shown in the heartbeat line |

Codex is always invoked non-interactively with `approval_policy=never` (it is `codex exec`). The safest
sandbox is the default; the two dangerous modes are opt-in / refused. This encodes the field lesson
"scope every Codex task tightly — read-only where possible."

## 3. Behavior (observable, bounded, fail-loud)
1. Validate all args fail-closed (missing `--as`, bad sandbox/effort/timeout, missing cwd/prompt ⇒ loud exit).
2. Heartbeat `busy` as `--as`: `codex-run: <model>/<sandbox> effort=<e> — <label>`.
3. Run, from `--cwd`, under a **watchdog**: `timeout <secs> codex exec -m <model> -s <sandbox>
   -c model_reasoning_effort="<e>" -c approval_policy="never" <prompt>`.
4. Terminal outcomes — each **observable via heartbeat**, never a silent hang:
   - **timeout** (rc 124) → heartbeat `blocked` "TIMEOUT after <secs>s" → exit 124 loud.
   - **codex error** (rc ≠ 0) → heartbeat `blocked` "FAILED rc=<n>" → codex output to stderr → exit <n> loud.
   - **success** → heartbeat `done` → Codex's output relayed 1:1 to stdout.
5. The heartbeat is the fleet-visible proof the call started and how it ended. The caller (or Colonel)
   watches the heartbeat, not a local `ps`.

## 4. Test seam (deterministic, no network)
`CODEX_RUN_BIN` overrides the `codex` binary (default `codex`). Specs point it at a stub to prove
arg-passing, timeout, error, success, heartbeat emission, and cwd — with **no** real inference / egress.
Same discipline as the P2 bus test seam.

## 5. Acceptance (codex-run slice) — example id `acme`
- Missing `--as` / `danger-full-access` / invalid sandbox|effort|timeout / missing prompt ⇒ loud non-zero, no call.
- **Success:** stub emits output → codex-run relays it, heartbeat log shows `busy` then `done`.
- **Timeout:** stub over-sleeps, `--timeout 1` → exit 124, heartbeat `blocked` TIMEOUT.
- **Error:** stub exits non-zero → codex-run exits with the same code, heartbeat `blocked`.
- **Arg fidelity:** stub captures argv → `-m`, `-s`, `model_reasoning_effort`, `approval_policy=never` all present.
- **cwd:** stub records its PWD → equals `--cwd`.
- Pure bash; the wrapper adds no deps (uses `timeout` from coreutils). Fail-closed/loud per P0.

## 6. Relationship to the fleet
`codex-run` is the **Runner** pattern (a bounded, heartbeat-owning Codex teammate) as a CLI primitive.
The **Dispatcher** pattern (one Claude orchestrator driving N `codex-run` calls, consolidating) composes
on top — no extra primitive needed. Cross-model review = a `--sandbox read-only` `codex-run` call; no
second standing instance. Codex never merges; its output is gated like any builder's.

---
White-label: example id `acme`; no real names, infrastructure, or hosts.
