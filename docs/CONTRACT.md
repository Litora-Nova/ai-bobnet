# ai-bobnet — Foundation Contract (P0)

The deterministic core every agent depends on. A freshly booted agent — regardless of runtime —
must be able to (1) know who and where it is, (2) log a heartbeat, (3) read its own inbox,
(4) message another agent, and (5) appear on the dashboard — **without guesswork or research.**
If any of these needs guessing, it is a bug.

## 1. Identity — the Agent is a registry object

Authority: `docs/DOMAIN.md` §2 (normative). Lookup is the authority; **parsing is validation only.**

| ID | Meaning | Example | Authority (single source of truth) |
|----|---------|---------|-------------------------------------|
| `project_uid` | one project / bobiverse | `acme` | `registry.json` → `projects` |
| `agent_uid` | one agent instance; the routing key | `acme-core` | `registry.json` → `agents` (the object key) |
| `agent_key` | the uid's per-project part | `core`, `review`, `infra` | derived: `agent_uid` minus the `<project_uid>-` prefix |
| `profile` | reusable task/capability set — **mutable** | `engine-dev` | the agent object's `profile` field |
| `clearance` | the agent's trust level, `t1`–`t4` | `t2` | the agent object's `clearance` field — **never the profile** |
| `display_name` | optional cosmetic name / avatar | (theme) | the theme layer — **never** a routing key |

- `agent_uid = <project_uid>-<agent_key>` — immutable, unique, the **only** routing key.
- An agent that is **not in the registry is fail-closed — even if its prefix parses.** There is no
  prefix-scan fallback: with projects `acme` and `acme-core` both registered, only the agent object's
  own `project` field decides, so `acme-core-review` is never a guessing problem.
- A profile swap MUST NOT change clearance, the inbox, the journal, or the memory scope.
- The word `task` is reserved for the *Project → Run → Task → Attempt* work unit. It is **never** an
  identity token — not in an env var, not in output.

### Registry shape (`schema_version: 2`)

```json
{
  "schema_version": 2,
  "projects": { "acme": { "home": "…", "standup_dir": "…", "mux_session": "…" } },
  "agents":   { "acme-core": { "project": "acme", "profile": "engine-dev", "clearance": "t2" } }
}
```

- The **object key IS the `agent_uid`**. `project`, `profile` and `clearance` are mandatory;
  `project` is authoritative and is never guessed from the prefix.
- `display_name` is optional and free text (may contain spaces/unicode); it never routes.
- Unknown extra fields are ignored (forward-compatible) and never load-bearing.
- Registry writes are the identity *and* clearance authority — gated at a high tier and audited
  (DOMAIN §2). Credential material is never co-located with it.

**A malformed registry never resolves.** Because this file is the identity *and* clearance source,
a half-written or hand-edited file must fail closed rather than hand out a wrong value:
the whole document must parse as JSON (balance checking alone is not enough — a single missing
quote can re-synchronise on the next one and silently change a value), exactly one top-level value
with no trailing data, no duplicate key in one object (key order must never decide routing or
clearance), and every *consumed* field must be a JSON string. Unknown nested or array fields stay
ignored, so forward compatibility is unaffected. `\u` escapes are refused rather than mis-decoded —
raw UTF-8 needs no escape.

## 2. Resolver — one place, no guessing

`bin/context [--json]` resolves, for the **current** agent, from validated env + the registry:
`agent_uid · project_uid · agent_key · home · standup_dir · inbox_path · mux_session`.
- Inputs: `AIBOBNET_PROJECT_UID` + `AIBOBNET_AGENT_KEY` (set by the launcher) → `agent_uid`; the rest
  from `registry.json`. The derived `agent_uid` is then looked up in `agents`, and the project it
  declares must match — a stale env pair cannot outvote the registry.
- **Fail-closed:** unknown agent / missing / inconsistent context → non-zero exit + clear error.
  Never guess, never default to a foreign path.

`bin/inbox <agent_uid>` → prints the **recipient's** inbox path (deterministic; used when writing TO another agent).

## 3. Inbox canon (one sentence)

**Write to the recipient's own inbox (`bin/inbox <agent_uid>`); read only your own (`bin/context` → `inbox_path`).**
- Per-agent inbox file: `<standup_dir>/inbox/<agent_uid>.md` (append-only journal). No shared, address-filtered file.
- Each line is structured: `TIMESTAMP | from:<agent_uid> | <text>` — the sender is a real field, not a free-text signature to parse.
- `from:`/`to:`/`by:` always carry an **`agent_uid`** — the routing key, never an actor label (see §4.1).
- **Line grammar:** structured fields first, then at most **one** free-text tail, introduced by a
  known marker (`state:PERSISTED | <body>`, or `reason:<reason>`) and running to end of line.
  Readers MUST stop scanning for fields at that marker. Free text is attacker-controlled and may
  contain `|`, so a reader that keeps scanning lets a crafted body or reason forge `id:`/`event:`
  and flip the state of a **foreign** message. Unknown structured fields are ignored (forward-compatible).

## 4. Launch — fail-closed `bin/run-agent`

`bin/run-agent [--as <actor-label>] <agent_uid> -- <cmd...>`:
1. **Scrub** inherited routing env (`STANDUP_DIR`, `INBOX*`, `MUX*`, `BOOT_*`, `PROJECT_*`, `AIBOBNET_*`).
2. Resolve + **validate** the target context (via the resolver). Abort loudly on any mismatch.
3. Export the clean, validated context, then exec the command.

Exported: `AIBOBNET_PROJECT_UID · AIBOBNET_AGENT_KEY · AIBOBNET_AGENT_UID · AIBOBNET_PROFILE ·
AIBOBNET_CLEARANCE · AIBOBNET_HOME · AIBOBNET_STANDUP_DIR · AIBOBNET_MUX_SESSION ·
AIBOBNET_INBOX_PATH · STANDUP_DIR` (+ `AIBOBNET_ACTOR` when `--as` is given).

A leaked ambient variable must **never** route an agent into a foreign project (the #1 field bug this core exists to kill).

### 4.1 `--as <actor-label>` — `on_behalf_of`, not a new identity

A short-lived helper (a one-shot provider call, a bootstrap step) is a **Session/Attempt acting on
behalf of an existing Agent — never a new Agent** (DOMAIN §2).

- The routing identity stays the **parent `agent_uid`**: inbox, journal, memory scope, standup file
  and `AIBOBNET_AGENT_UID` are unchanged. An actor label MUST NOT create an identity.
- The label is a **validated token** (same charset as an id: lowercase, digits, hyphen), exported as
  `AIBOBNET_ACTOR`. Because the charset admits no `|` and no newline, a label can never inject a
  journal field.
- **Clearance is inherited and capped:** `AIBOBNET_CLEARANCE` is the parent's. There is no flag that
  raises it.
- Journal lines that record who acted (`NOTIFIED`/`SEEN`/`PROCESSED`/`FAILED`) carry an encoded
  `actor:<label>` field after `by:` (and before the free-text `reason:`), so the acting session is
  auditable without disturbing routing. Unknown fields are ignored by the fold, so older parsers are
  unaffected.
- A genuinely new **durable** role is provisioned by a gated registry write — never by a helper
  inventing an identity. (The atomic bootstrap writer with TTL + audit is a later sprint.)

## 5. Logging — fail-loud `scripts/log.sh`

`scripts/log.sh <agent_uid> <busy|idle|blocked|done> "<one line>"`:
- Requires a resolvable context (agent_uid must be a registry agent → standup_dir). **Unknown/inconsistent → error + hint; never a default dir.**
- Writes `<standup_dir>/<agent_uid>.log`. `agent_uid` is canonical; persona is display-only (the dashboard maps it via the theme).

## 6. Acceptance (P0 slice)

A fresh agent, launched via `bin/run-agent`, can: resolve `bin/context`, `log.sh` a heartbeat, read its own inbox,
and write to another agent's inbox — **all deterministic, no guessing** — even with a poisoned `BOOT_*` / `STANDUP_DIR`
in the ambient env (scrubbed by `run-agent`). Proven by `tests/`.

Because the registry is the identity authority, **every agent that heartbeats, is woken, owns memory
or is launched must exist in `agents`** — `bin/run-agent`, `scripts/log.sh`, `bin/wakeup` and
`bin/memory` all fail closed on an unregistered uid. That is intended, not a regression.

---
White-label: example project id `acme`; no real names, infrastructure, or hosts anywhere in this repo.
