# ai-bobnet — Foundation Contract (P0)

The deterministic core every agent depends on. A freshly booted agent — regardless of runtime —
must be able to (1) know who and where it is, (2) log a heartbeat, (3) read its own inbox,
(4) message another agent, and (5) appear on the dashboard — **without guesswork or research.**
If any of these needs guessing, it is a bug.

## 1. Identity — four explicit IDs (no ambiguous "uid")

| ID | Meaning | Example | Authority (single source of truth) |
|----|---------|---------|-------------------------------------|
| `project_uid` | one project / bobiverse | `acme` | the registry (`registry.json`) |
| `agent_uid` | one agent instance; the routing key | `acme-core` | derived: `<project_uid>-<task>` |
| `task` | what the agent does (role) | `core`, `review`, `infra` | the archetype layer |
| `persona` | optional display name / avatar | (theme) | the theme layer — **never** a routing key |

- `agent_uid = <project_uid>-<task>` — deterministic, unique, the **only** routing key.
- Persona is cosmetic: a folder lead may carry a name/avatar; others are task- or self-named. Never route by persona.

## 2. Resolver — one place, no guessing

`bin/context [--json]` resolves, for the **current** agent, from validated env + the registry:
`agent_uid · project_uid · task · home · standup_dir · inbox_path · mux_session`.
- Inputs: `AIBOBNET_PROJECT_UID` + `AIBOBNET_TASK` (set by the launcher) → `agent_uid`; the rest from `registry.json`.
- **Fail-closed:** ambiguous / missing / inconsistent context → non-zero exit + clear error. Never guess, never default to a foreign path.

`bin/inbox <agent_uid>` → prints the **recipient's** inbox path (deterministic; used when writing TO another agent).

## 3. Inbox canon (one sentence)

**Write to the recipient's own inbox (`bin/inbox <agent_uid>`); read only your own (`bin/context` → `inbox_path`).**
- Per-agent inbox file: `<standup_dir>/inbox/<agent_uid>.md` (append-only journal). No shared, address-filtered file.
- Each line is structured: `TIMESTAMP | from:<agent_uid> | <text>` — the sender is a real field, not a free-text signature to parse.

## 4. Launch — fail-closed `bin/run-agent`

`bin/run-agent <agent_uid> -- <cmd...>`:
1. **Scrub** inherited routing env (`STANDUP_DIR`, `INBOX*`, `MUX*`, `BOOT_*`, `PROJECT_*`, `AIBOBNET_*`).
2. Resolve + **validate** the target context (via the resolver). Abort loudly on any mismatch.
3. Export the clean, validated context, then exec the command.

A leaked ambient variable must **never** route an agent into a foreign project (the #1 field bug this core exists to kill).

## 5. Logging — fail-loud `scripts/log.sh`

`scripts/log.sh <agent_uid> <busy|idle|blocked|done> "<one line>"`:
- Requires a resolvable context (agent_uid + standup_dir). **Missing/ambiguous → error + hint; never a default dir.**
- Writes `<standup_dir>/<agent_uid>.log`. `agent_uid` is canonical; persona is display-only (the dashboard maps it via the theme).

## 6. Acceptance (P0 slice)

A fresh agent, launched via `bin/run-agent`, can: resolve `bin/context`, `log.sh` a heartbeat, read its own inbox,
and write to another agent's inbox — **all deterministic, no guessing** — even with a poisoned `BOOT_*` / `STANDUP_DIR`
in the ambient env (scrubbed by `run-agent`). Proven by `tests/`.

---
White-label: example project id `acme`; no real names, infrastructure, or hosts anywhere in this repo.
