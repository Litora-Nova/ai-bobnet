# ai-bobnet — Visibility Contract (V-1)

> **Status: SPECIFICATION — `bin/project` does not exist yet.** This document is written before the
> projector, deliberately, in the same spirit `docs/CONTRACT-mediation.md` was written before the
> broker: the thing being built has something to be measured against. Every path, environment
> variable, and JSON field named here is a requirement, not a description of running code.

## 0. Why this exists

`plan/BobNet_3.0_ENTSCHEID_sichtbarkeit-und-vm-split.md` (PO decision, 2026-08-15) made visibility a
**pillar acceptance criterion**: *"Kein Pfeiler gilt als fertig, solange sein Zustand nicht sichtbar
ist"* — no pillar is done until its state is visible, checked mechanically per sprint: does the
pillar emit the events this contract names. It also made a **thin, read-only projection** the
precondition for any agent going live on the production VM (Decision 4); on the current dev VM,
admin-SSH oversight substitutes for it.

This contract has two halves, and they are graded differently:

- **The emit contract (§§1–3)** — which facets exist, which channel carries each, and what
  provenance means. This is the durable half every future pillar is measured against.
- **The projection's consumer contract (§§4–19)** — the shape of `bin/project`'s output and the
  obligations on anything that reads it. `docs/decisions/0007-visibility-projection.md` records the
  placement/mode/account reasoning behind §§13–16; read it for *why*, this document for *what*.

Both halves implement `docs/DOMAIN.md` Invariant 2 ("store facts, derive the display") for a file that
is explicitly allowed to persist an interpreted status (`stale`, `presumed-dead`, `attention` items) —
legitimate **only** under the two conditions §4 and §17 state: nothing in the engine ever reads it
back, and a deleted copy rebuilds byte-identical except for its own timestamp.

---

## 1. Three facets, three channels

Every pillar's state is one of exactly three facets. Each facet has exactly one emit channel; a
pillar is visible when it emits on the channel its facet requires, not when it invents a new one.

| Facet | Question it answers | Channel | Attested? |
|---|---|---|---|
| **Work unit** | What did the broker decide, and how did it end? | `attempt.decided` / `attempt.ended` (the existing RM-2 stream, `docs/decisions/0004-durable-attempt-audit.md`) | Yes — broker-committed |
| **Agent state** | Is the agent working, waiting, blocked, or done? | The heartbeat line (`scripts/log.sh`, `busy\|idle\|blocked\|done`) | **No** — agent-asserted |
| **Attention** | What is waiting on a human? | A `blocked` heartbeat whose message starts with `needs:<kind> ` (§8), plus broker-derived items (§9) | Mixed — see §3 |

`attempt.decided`/`attempt.ended` are unchanged by this contract; they are named here only to
complete the three-facet picture. This contract's new normative content is the agent-state and
attention channels and the projection that renders all three together.

### 1.1 Agent state stays the heartbeat, deliberately

Forcing a new `agent.state` event now would need a second broker-visible operation, and
`docs/CONTRACT-mediation.md` §2 fixes `launch(request)` as "the entire agent-visible surface. One
call." Amending a frozen contract to gain a channel the fleet already emits and the dashboard already
parses is the wrong trade at V-1's size. This is a **deferral, recorded by ADR** (§0007), not an
oversight: a later pillar whose state is genuinely broker-observable (not merely agent-declared) MUST
emit a real event through the seam, decided by its own ADR before it is built — the mechanical §2
check ("does the pillar emit the events this contract names") is not satisfied by having agents write
free text about a fact the broker could itself attest to.

---

## 2. The `attested` field

Every entry this projection emits under `agents[uid]` and every item under `attention[]` carries
`"attested": true|false`. This is not decoration: it is the difference between a **claim** (an agent
said so) and an **attestation** (the broker observed it), inside one artifact that a human reads as if
it were uniformly true.

- `agents[uid].state`, `agents[uid].message`, and every `needs:`-derived `attention[]` item carry
  `"attested": false` — they are exactly what the named agent's own heartbeat log says, unverified.
- Every broker-derived `attention[]` item (§9) carries `"attested": true` — it is computed by the
  projector from the durable stream and the broker's own `.live` file, never from agent-written text.
- `stream` and `capacity` are always broker-derived; they are not individually tagged because the
  whole object is attested — see `attested_sources` (§18).

**Consumers MUST render this distinction** — e.g., a claimed `idle` next to an open, un-ended
`attempt.decided(allow)` is not resolved by picking a side; it is folded into a `disagreement`
attention item (§9) and both facts stay visible. The projection never overwrites one side with the
other.

---

## 3. Non-consumption clause

`docs/DOMAIN.md` Invariant 2 ("never persist an interpreted status") is satisfied by this projection
under exactly two conditions, both mandatory:

1. **The file is rebuildable** — §17's `rm` + rebuild acceptance test.
2. **Nothing in the engine ever reads it back.** No script, adapter, gate, or broker path may open
   `<AIB_PROJECTION_ROOT>/<project_uid>.json` or the `<standup_dir>/_projection.json` symlink for
   anything other than a human or a dashboard render. The convenience pressure is real — the next
   slice that needs "is agent X alive" will be tempted to read this file instead of the stream it
   summarizes — and this clause exists to name that temptation before it is acted on.

This is **enforced mechanically**, not left to review discipline: `tests/projection_spec.sh` greps the
whole engine tree for a reference to the projection root or the `_projection.json` name outside
`bin/project` itself, its own tests, and documentation, and fails if one is found.

---

## 4. Consumer obligations

A projection is disposable, out-of-band data. Every reader — the dashboard included — MUST:

- **Render "as of `generated_at`."** The file's own timestamp is the only freshness signal; nothing
  else in the file self-reports its own staleness beyond the per-agent `stale` flag (§18.6).
- **Treat a missing file as UNKNOWN, never as empty.** A project with no projection file is not a
  project with no agents — the projector may simply not have run yet, or the broker-owned root may be
  unreachable. Rendering an empty roster where the truth is "we don't know" is a second-truth defect
  in the consumer, not in this contract.
- **Never write to the file, the root, or the symlink.** The projection is broker-owned output; a
  consumer that patches it to "fix" a display glitch has created a second truth by definition.

---

## 5. The prod rule is an operator check, never a runtime gate

The PO decision's Decision 4 makes this projection's existence a **precondition for provisioning
agents onto the production VM** — an operator sign-off item, checked once per go-live. It **MUST
NEVER become a runtime gate**: `bin/aib-broker-handler` must never refuse, delay, or degrade a launch
because the projection is stale, absent, or its projector process is down. Making a display artifact
load-bearing for execution would invert `docs/DOMAIN.md` §9 Invariant 1 ("a dashboard is a projection
and a command surface — never a second truth… if it is down, messaging and the CLI still work") for
the broker's own launch path, which is a strictly worse place for that inversion to happen than the
dashboard itself. `tests/projection_spec.sh` pins this directly: the handler's source is grepped for
any reference to the projection root or file, and none may exist.

---

## 6. What this does not tell you (written limits)

Stated here rather than discovered later, because an empty box in the mechanical "is it visible"
check is worse than an honest gap:

- **Gates, grants, and approvals are a later pillar.** `t4`, `approval`, and `conflict` are `needs:`
  kinds an agent MAY declare (§8), but V-1 has no gate/grant state machine behind them — it can only
  see what an agent chooses to say. Do not read an empty `attention[]` array as "nothing needs a
  human"; read it as "no agent declared a need, and the broker detected no stream fault or presumed-dead
  attempt."
- **The inbox is out of scope for V-1.** `_inbox.md` is today's actual "waiting on a human to read a
  message" channel, and the dashboard already renders it separately
  (`claude-bobnet/dashboard/server/api/inbox.get.ts`). This projector does not parse it — one more
  hostile-text-in-a-privileged-process surface for a channel that already has a reader is not a trade
  V-1 makes. A future pillar that wants inbox visibility in this same artifact needs its own ADR.
- **Silence is not evidence of no need.** The presumed-dead derivation (§9) covers a crashed or
  vanished process. Nothing in V-1 covers an agent that is alive, has not crashed, and is simply stuck
  without declaring `needs:` anything. That gap is accepted for V-1 and is exactly why the pillar
  acceptance check names *emitting*, not *inferring*, as the bar.

---

## 7. `needs:` — the attention-declaration ceremony

A `blocked` heartbeat whose message starts with `needs:<kind> ` (one of the recognized kinds below,
followed by exactly one space, followed by free text) is folded into one `attention[]` item with
`"attested": false`.

**Recognized kinds:** `human`, `t4`, `approval`, `conflict`, `input`, `other`.

- `t4`, `approval`, `conflict` name the gate concepts §6 already scopes out — they are declarations an
  agent can make today about a decision a later pillar will actually adjudicate.
- `human` and `input` are kept **distinct, not merged**, despite the two reading as близкие in casual
  use: `human` is a judgment call — something needs a person's discretion, not a specific fact
  (`"needs:human is this refactor worth the risk"`). `input` is a missing fact or credential a person
  must supply before work can continue (`"needs:input the staging DB password"`). This distinction is
  this contract's own resolution of an open note in the design consult; a pillar that finds the two
  indistinguishable in practice may propose collapsing them by ADR, but V-1 ships with both.
- **`other` is the fail-visible catch-all**, never a silent drop: any `blocked` message that starts
  with `needs:` followed by a token *not* in this list still produces an `attention[]` item with
  `"kind": "other"`. A malformed `needs:` line (no trailing space, no token, or an empty token) is
  handled the same way — `kind: "other"`.
- **The full original message is the `reason`**, verbatim, for every `needs:` item regardless of
  whether the kind was recognized — never just the text after the prefix. An agent that gets the
  ceremony wrong still gets its words preserved; only the machine-readable `kind` degrades to `other`.
- `reason` is agent-written, untrusted free text: it goes through `aib_json` like every other
  string value in this schema. It is data, never re-interpreted as structure.
- `since` is the heartbeat line's own timestamp (§10 — offset-bearing).
- `agent` is the owning agent's `uid`.
- A `blocked` heartbeat with **no** `needs:` prefix produces no `attention[]` item from this channel —
  it is still visible as `agents[uid].state = "blocked"`, just not promoted into the attention list.
  This is the concrete shape of §6's "silence is not evidence of no need" limit.

---

## 8. Broker-derived attention (P-J)

Computed by the projector itself from the durable stream, the anchor, and the `.live` file — never
from agent text — and therefore always `"attested": true`. Three kinds, with this contract's own
resolution of the literal `kind` strings (not fixed by the design note; recorded here so a builder and
this spec agree):

| `kind` | Condition | `agent` | `reason` (fixed shape) | `since` |
|---|---|---|---|---|
| `stream_unhealthy` | `stream.status` is anything but `ok`, OR `stream.anchor.relationship` is `ahead`, OR `stream.torn_tail` is `true` | `null` (project-level, not agent-level) | One of: `"stream corrupt: <corrupt reason>"`, `"stream unreadable"`, `"stream absent"`, `"anchor ahead of stream (a > m)"`, `"uncommitted tail present"` | `generated_at` of the run that detected it |
| `presumed_dead` | An open `attempt.decided(allow)` with no `attempt.ended`, and no heartbeat from that `agent_uid` newer than the `decided` record's timestamp, for more than `AIB_PROJECTION_DEAD_MINUTES` minutes (default 15) | the attempt's `agent_uid` | `"attempt <attempt_id> decided <decided_at>, no ended record and no heartbeat since"` | the `decided` record's `decided_at` |
| `disagreement` | A heartbeat claims `state` ∈ `{done, idle}` while that same agent has an `attempt.decided(allow)` still open (no `ended`) | the agent's `uid` | `"heartbeat claims <state> while attempt <attempt_id> is still open"` | the heartbeat's own timestamp (the more recent of the two signals) |

`AIB_PROJECTION_DEAD_MINUTES` is a unit-environment setting (default `15`, matching the design note's
default), never request- or registry-supplied. A stream that is corrupt or absent yields no
`presumed_dead`/`disagreement` derivation for that project's attempts on that tick — a broken stream
cannot honestly ground a derived claim about what it contains — but a `stream_unhealthy` item is still
emitted, and `agents[uid]` still projects from the still-readable heartbeat logs.

---

## 9. Timezone coupling

`scripts/log.sh` writes local wall time in `DEV_TEAM_TZ` (default `Europe/Berlin`) with **no UTC
offset in the line itself** (`YYYY-MM-DD HH:MM | status | msg`). A systemd unit runs with `TZ` unset
(UTC) unless told otherwise. The projector's unit **MUST** set `Environment=TZ=<the same value
operators set for DEV_TEAM_TZ>` — the identical coupling `claude-bobnet/dashboard/server/utils/beats.mjs`
already has via its own `DEV_TEAM_TZ` read. Getting this wrong reads every heartbeat as one-to-two
hours older than it is (flagging live agents stale) and is ambiguous, not merely shifted, across a DST
transition.

**Every timestamp this projection emits is offset-bearing ISO 8601** (`generated_at`, `since`,
`capacity.as_of`, `agents[uid].since`) — a consumer never has to know or guess the projector's zone to
render correctly. This is the concrete fix for the same-file second-parser risk named in §11: a
downstream reader that trusts this file's timestamps at face value is safe regardless of what zone
produced them.

---

## 10. Capacity — the attested `.live` file

`bin/aib-broker-handler` already computes the live-lease count under `attempts.lock` before admitting
or refusing a connection (`docs/decisions/0006-anchor-and-capacity.md`, part B). This contract adds
one requirement on top of that existing computation: **the handler writes that integer, atomically
(`mktemp` in the same directory, then `rename(2)`), to `$AIB_EVENT_ROOT/attempts/.live`, once per
admission decision** — allowed or refused, so the file reflects real traffic even during a run of
refusals. The written value is the live-lease count exactly as the handler's own lock-held arithmetic
produced it for that decision; this contract does not require a specific pre- or post-lease-creation
instant, only that it come from the one count already computed under the lock, never a second,
separately-timed pass.

**The projector reads `.live` and its mtime and does nothing else in `attempts/`:**

- `capacity.live` = the file's integer content, or `null` if the file is absent, unreadable, or its
  content is not a canonical non-negative integer (never treated as an incident — informational only,
  per §6, no attention item is derived from capacity in V-1).
- `capacity.as_of` = the file's mtime as offset-bearing ISO 8601, or `null` when `capacity.live` is
  `null`.
- `capacity.limit` = `AIB_BROKER_CAPACITY` read from **the projector's own unit environment**,
  mirrored from the broker unit's value (default `12`, the same default `bin/aib-broker-handler`
  uses) — **not** read from the broker's process or a shared file. This is the same mirrored-value,
  accepted-drift-risk pattern `docs/decisions/0006-anchor-and-capacity.md` already established for
  `AIB_BROKER_MAX_CONNECTIONS`: nothing enforces agreement between the two units' copies of
  `AIB_BROKER_CAPACITY`, and `deploy/systemd/aib-projection.service`'s comment must say so.
- **The projector never opens, locks, or enumerates any file under `attempts/` other than `.live`.**
  No lease file is ever read. A directory full of unreadable or malformed lease files must not affect
  the projector's success — this is the concrete fix for the Q4 finding that a "pure reader" probing
  leases can itself cause false `over_capacity` answers by contending on `flock -n`.

---

## 11. Agent set — registry only

The `agents` object's keys are **exactly the project's registered agent uids**
(`aib_registry_query projects keys` → `aib_registry_query agents field <uid> project`, filtered to
this `project_uid`), each validated through `aib_validate_agent_uid`. A `<something>.log` file present
in `standup_dir` with no matching registry entry is **never** projected as an agent — it increments
`anomalies.unregistered_logs` instead. A log filename containing quotes, newlines, or control bytes
can therefore never become a JSON object key: it never reaches key position in the first place,
because the key set comes from the registry, not from a directory listing.

**Heartbeat parsing reproduces `claude-bobnet/dashboard/server/utils/beats.mjs` exactly** — this is
the concrete fix for the two-parsers-of-one-file risk named in `docs/DOMAIN.md`'s framing of this
projection:

- An ISO line (`YYYY-MM-DD HH:MM | status | msg`) resolves to an offset-bearing epoch via the zone in
  §9, matching `zonedEpoch()`'s double-pass DST handling.
- A dateless legacy line (`HH:MM | status | msg`) is **stale** unless it is the file's own last line,
  in which case its instant is the file's own mtime (never the wall-clock `HH:MM`, which cannot be
  dated).
- An unparsable line is conservatively stale.
- `agents[uid].stale` is set accordingly; `agents[uid].state` still reports the line's own claimed
  status even when stale — staleness qualifies the claim, it does not erase it.

`tests/projection_spec.sh` pins this with a **differential test against `beats.mjs`**, run through
`node` when present on the host and skip-marked (not faked) otherwise, over a shared fixture set
including dateless lines, an unparsable line, and a dateless line as both a non-last and a last line.

---

## 12. Fold extraction — `aib_attempts_fold`

`bin/attempts` and `bin/project` both fold the same `attempt.decided`/`attempt.ended` stream, but they
disagree on purpose about what a corrupt stream means: `bin/attempts` dies (`docs/CONTRACT-execution-binding.md`
§8.3 — audit corruption is a launch-stopper by doctrine); `bin/project` must **report**
`stream.status = "corrupt"` and keep projecting the heartbeat facets, because a broken audit stream is
exactly the kind of fact an operator needs to see on a dashboard, not a reason to go dark.

This contract requires the fold logic to live in one library function, `aib_attempts_fold`, that
**returns both the fold and the scan status**, leaving the die-or-report decision to each caller:

```text
aib_attempts_fold <events_path>
  sets:  AIB_ATTEMPTS_FOLD_STATUS        (mirrors AIB_EVENT_SCAN_STATUS: ok|degraded|corrupt)
         AIB_ATTEMPTS_FOLD_IDS           (newline list of attempt_ids, in stream order)
         per-attempt state exactly as bin/attempts today: decision/pid/state/exit_code
  never dies on a corrupt or absent stream — the caller decides
```

`bin/attempts` is refactored to call this function and **MUST produce byte-identical output** to the
pre-refactor version on every existing fixture (`tests/attempts_spec.sh` already pins that output
shape; this contract adds a differential test that runs both callers — `bin/attempts` and a thin
projector-side caller — against one fixture stream and asserts they agree on every attempt's folded
state). This is what keeps the projector from becoming a third, independently-drifting reader of the
same stream.

---

## 13. `--all` — per-project isolation and failure semantics

`bin/project --all` iterates every `project_uid` the registry currently knows
(`aib_registry_query projects keys`, read fresh each invocation — never a cached list, so a project
added to the registry gets a projection on the very next tick with no unit edit, per §15).

- **One project's failure MUST NOT abort the others.** A single bad registry entry, an unreadable
  `standup_dir`, or a fold that reports `corrupt` for one project's stream does not stop `--all` from
  writing the remaining projects' files.
- **A partial fold is never published.** If any step of computing one project's projection fails after
  the fold has begun (not to be confused with a *reported* `corrupt`/`absent` stream status, which is
  a normal, publishable outcome), the **previous** file for that project is left untouched — its
  `generated_at` ages honestly rather than a fresh-looking file appearing with holes. This is what
  makes §4's "render as of `generated_at`" obligation meaningful: a consumer can trust that an old
  timestamp means "the projector could not complete a fresh pass," never "here is a incomplete pass
  dressed up as current."
- The projector's own health beyond what the file itself shows is invisible to a project's dashboard —
  its journal is broker-only (`StandardError=journal`, matching every other broker-owned unit in this
  repository). This is exactly why §4's obligations are placed on the consumer, not solved by the
  projector shouting louder.

---

## 14. Placement, mode, and account

Reusing the pattern `docs/decisions/0005-broker-event-stream-location.md` already established for the
event stream, not inventing a new one:

- **`AIB_PROJECTION_ROOT`** — unit-environment-only, never request- or registry-supplied (the same
  restriction already stated for `AIB_EVENT_ROOT` and `AIB_CONFINE_BIN`). Default
  `/var/lib/aib/projection`.
- **Directory** `<AIB_PROJECTION_ROOT>` owned `aib-broker:aib-shared`, mode **`0750`** — the broker
  writes, the shared group (dashboard, operators) reads, no one else.
- **File** `<AIB_PROJECTION_ROOT>/<project_uid>.json`, mode **`0640`** — group-read only, never
  group-write. `docs/CONFINEMENT.md`'s §2.1 minimum list gains this root explicitly (§16 below):
  granting a confined child `LL_RW` over a project `home` must never also grant it a route to this
  broker-owned artifact, exactly the argument ADR-0005 already made for the event stream.
- **Publish is `mktemp`-then-`rename`, never a fixed temp name.** The temp file is created with
  `mktemp` in `AIB_PROJECTION_ROOT` itself (`O_EXCL`, a random suffix on the pattern
  `.<project_uid>.json.XXXXXX`), written, then `rename(2)`d over the final name. A symlink or regular
  file pre-planted at any *fixed* name is irrelevant by construction, because no fixed name is ever
  opened for writing.
- **`<standup_dir>/_projection.json`** is a **read-only symlink into the projection root**, maintained
  by provisioning (`prox-init`, Remote Bob's revier per `[[prox-init-revier-split]]`-style ownership,
  not this repository) — exactly the pattern `<standup_dir>/events` already is for the stream. **The
  projector never creates, targets, or writes through this symlink.** It writes only inside
  `AIB_PROJECTION_ROOT`.
- **`aib-projection.service`** (text specified here; the builder wires the code): `User=aib-broker`,
  `Type=oneshot`, `ReadWritePaths=/var/lib/aib/projection`, `ReadOnlyPaths=$AIB_EVENT_ROOT`,
  `InaccessiblePaths=/var/lib/aib/auth` — the projector parses hostile agent-written heartbeat text and
  MUST NOT be able to reach the credential directory the confined provider child's adapter reads
  from — plus the same `NoNewPrivileges=yes`, `ProtectSystem=strict`, `PrivateTmp=yes`,
  `ProtectHome=yes` hardening `aib-broker@.service` already carries. `AIB_PROJECTION_ROOT`,
  `AIB_BROKER_CAPACITY` (mirrored, §11), and `TZ` (§9) come from `Environment=` lines, never a
  fallback computed in the script.
- **`aib-projection.timer`** triggers the service on a fixed interval — see §16.
- The unit points at **one projection root**, never an enumerated list of standup dirs — §13 already
  makes the project list a registry read, so nothing about adding a project to the registry requires
  touching this unit.

---

## 15. Confinement — the projection root joins the minimum

`docs/CONFINEMENT.md` §2.1's minimum list ("no write access to the event stream, the high-water
anchor, the registry, the adapter map, or the installed engine") **gains the projection root**:
`AIB_PROJECTION_ROOT` is a broker-produced, broker-attested artifact exactly like the event stream and
the anchor, and it must never sit inside a confined child's `LL_RW`. See `docs/CONFINEMENT.md`'s own
updated minimum list and `docs/decisions/0007-visibility-projection.md` for the placement reasoning in
full — this section is the pointer, not a duplicate of it.

---

## 16. Cadence and cost

- **`AIB_PROJECTION_INTERVAL`** — the timer's own interval, unit-environment, default **10 seconds**
  (`aib-projection.timer`'s `OnUnitActiveSec=`). A timer, not a handler-triggered nudge: most of what
  this projection reports is time-derived (staleness, presumed-dead, "blocked since"), and a
  commit-triggered refresh would be freshest exactly when the fleet is busiest and stalest exactly when
  an operator most wants to look — during a lull or a block. It also keeps observability entirely out
  of the launch request path: a slow or failing projection pass must never slow or fail a launch.
- **A measured fold-time budget is part of the acceptance test**: folding a stream fixture of
  **10,000 records completes in under 2 seconds** on the build host — cheap enough that a 10-second
  cadence, forever, does not become the next resource-exhaustion incident on a host that has already
  had one (see `standup/_facts_visibility.md`'s reference to the WebGL/swap freeze). This is a floor,
  not a promise of production performance; the builder measures the real number against the deployment
  host before this ships to a loaded fleet, the same discipline `docs/decisions/0006-anchor-and-capacity.md`
  already asked of the anchor's fsync-inflated commit-lock latency.
- **Incremental folding is out of scope for V-1, named as a follow-up ADR.** A full re-fold of an
  append-only stream every tick, forever, is the same unbounded-growth shape RM-2 left open for cursors
  and resync; V-1 accepts it at V-1's volumes and states the gap rather than silently deferring it.

---

## 17. Acceptance — the rebuild test

`docs/DOMAIN.md` §11(e): *a deleted projection can be rebuilt.* Concretely: `rm
<AIB_PROJECTION_ROOT>/<project_uid>.json`, wait for the next tick (or invoke `bin/project
<project_uid>` directly), and the file that reappears is **byte-identical to what would have been
written without the deletion, except for `generated_at`**. This is the cheapest possible proof that
the file is an index over the stream and the heartbeat logs, never a ledger with state of its own —
and it is why §3's non-consumption clause is safe to make at all: an index that nothing reads back and
that always rebuilds identically cannot silently drift into being the truth.

---

## 18. Output shape — schema 1 (frozen)

```json
{
  "schema": 1,
  "generated_at": "2026-09-07T14:32:10+02:00",
  "project_uid": "acme",
  "attested_sources": ["stream", "capacity"],
  "stream": {
    "status": "ok",
    "last_seq": 42,
    "anchor": { "value": 42, "relationship": "ok" },
    "torn_tail": false
  },
  "capacity": { "limit": 12, "live": 3, "as_of": "2026-09-07T14:32:09+02:00" },
  "attention": [
    { "kind": "input", "agent": "acme-core", "reason": "needs:input the staging DB password",
      "since": "2026-09-07T14:20:00+02:00", "attested": false }
  ],
  "agents": {
    "acme-core": {
      "state": "busy", "since": "2026-09-07T14:30:00+02:00",
      "message": "refactoring the fold", "stale": false, "attested": false,
      "attempt": {
        "id": "acme-main-41", "decided_at": "2026-09-07T14:29:55+02:00",
        "decision": "allow", "open": true,
        "last": { "class": null, "stage": null, "ended_at": null }
      }
    }
  },
  "anomalies": { "unregistered_logs": 0, "unparsable_lines": 0 }
}
```

Every field, documented:

| Field | Type | Meaning |
|---|---|---|
| `schema` | integer, always `1` | This document's own version. Readers MUST tolerate unknown fields added by a later, additive-only bump — the same rule `docs/DOMAIN.md` §5 states for the event envelope — and MUST NOT branch on it beyond "is this at least the version I understand." |
| `generated_at` | ISO 8601, offset-bearing | When this specific file was written. The only freshness signal (§4). |
| `project_uid` | string | The project this file describes. Matches the filename. |
| `attested_sources` | array of string | Which of `"stream"` / `"capacity"` the projector could actually read this tick — `"stream"` absent means `stream.status` reflects an unreadable/absent stream rather than a real fold; `"capacity"` absent means `.live` was unreadable (§10). Lets a consumer distinguish "reported ok" from "could not check." |
| `stream.status` | `ok\|corrupt\|absent\|unreadable` | Mirrors `AIB_ATTEMPTS_FOLD_STATUS`/`AIB_EVENT_SCAN_STATUS` (§12), plus `absent` (no stream file yet — a new project) and `unreadable` (a permissions/IO failure distinct from a corrupt parse). |
| `stream.last_seq` | integer | The highest valid `seq` the fold observed (0 if none). |
| `stream.anchor.value` | integer or `null` | The `high_water` anchor's own value, or `null` if the anchor file is absent. |
| `stream.anchor.relationship` | `ok\|lag\|ahead\|absent` | Exactly `bin/anchor status`'s own vocabulary (`docs/decisions/0006-anchor-and-capacity.md`) — the projector re-derives this read-only, it does not shell out to `bin/anchor`. |
| `stream.torn_tail` | boolean | Mirrors `AIB_EVENT_SCAN_TORN_TAIL`. |
| `capacity.limit` | integer | `AIB_BROKER_CAPACITY` from the projector's own unit environment (§10). |
| `capacity.live` | integer or `null` | The `.live` file's content, or `null` per §10. |
| `capacity.as_of` | ISO 8601 or `null` | The `.live` file's mtime, or `null` when `live` is `null`. |
| `attention[].kind` | string | One of §7's six `needs:` kinds or §8's three broker-derived kinds. |
| `attention[].agent` | string or `null` | The owning agent's `uid`, or `null` for a project-level item (`stream_unhealthy`). |
| `attention[].reason` | string | Free text, `aib_json`-escaped. Agent-written for `needs:` items (§7); a fixed, projector-composed sentence for broker-derived items (§8). |
| `attention[].since` | ISO 8601, offset-bearing | See §7/§8 for which instant, per kind. |
| `attention[].attested` | boolean | `false` for `needs:` items, `true` for broker-derived items (§2). |
| `agents` | object, keys = registered agent uids only | See §11. An agent with no heartbeat log yet still appears as a key, with `state: "unknown"`, `since: null`, `stale: true`, `attempt: null` — absence in the registry-derived key set is never confused with absence of activity. |
| `agents[uid].state` | `busy\|idle\|blocked\|done\|unknown` | The heartbeat's own claimed status, or `unknown` when no readable heartbeat line exists at all. |
| `agents[uid].since` | ISO 8601 or `null` | The claimed line's own timestamp (§9/§11), or `null` for `unknown`. |
| `agents[uid].message` | string | The heartbeat message, `aib_json`-escaped, untrusted agent text. |
| `agents[uid].stale` | boolean | Per §11's `beats.mjs`-identical staleness rule. |
| `agents[uid].attested` | boolean, always `false` | Every `agents[uid]` entry is a claim (§2) — present in the schema for symmetry with `attention[]`, not because it can ever be `true` in V-1. |
| `agents[uid].attempt` | object or `null` | `null` when the agent has no `attempt.decided` in the current fold. |
| `agents[uid].attempt.id` | string | The `decided` event's own `event_id` (= `attempt_id`, `docs/CONTRACT-execution-binding.md` §8.2). |
| `agents[uid].attempt.decided_at` | ISO 8601 | The `decided` record's own timestamp. |
| `agents[uid].attempt.decision` | `allow\|deny` | Mirrors `bin/attempts`' own fold. |
| `agents[uid].attempt.open` | boolean | `true` when `decision = allow` and no matching `ended` record exists yet. |
| `agents[uid].attempt.last.class` | exit class or `null` | Mirrors `bin/attempts`' terminal `exit_class`, `null` while `open`. |
| `agents[uid].attempt.last.stage` | stage or `null` | `docs/CONTRACT-execution-binding.md` §8.1's `exit.stage`, `null` when absent (schema-1 stream records) or `open`. |
| `agents[uid].attempt.last.ended_at` | ISO 8601 or `null` | The `ended` record's own timestamp, `null` while `open`. |
| `anomalies.unregistered_logs` | integer | Count of `<name>.log` files in `standup_dir` with no matching registry agent (§11). |
| `anomalies.unparsable_lines` | integer | Count of heartbeat lines that matched neither the ISO nor the dateless `HH:MM` shape, across every agent's log this tick. |

---

## 19. Not in V-1

Recorded so a later reader does not assume these were forgotten rather than deliberately deferred; each
gets its own ADR before it is built:

- The dashboard's own rendering of this file (a separate engine slice, `claude-bobnet`, tracked
  there — this contract fixes the shape it will consume).
- Spine event types for agent state (§1.1).
- A consumer cursor or resync signal over this file (it has none — a consumer re-reads the whole file
  every poll, exactly as the dashboard already does for heartbeat logs today).
- Incremental folding (§16).
- A separate `aib-projector` reader account, distinct from `aib-broker` (§14 keeps `User=aib-broker`
  for V-1, hardened by the unit's `InaccessiblePaths`/`ReadOnlyPaths`; a distinct low-privilege account
  is the end state named as a follow-up, not built here — see `docs/decisions/0007-visibility-projection.md`).

---

## Interfaces (summary)

```text
bin/project <project_uid> | --all [--stdout]

Env (unit-environment-only, never request/registry-supplied):
  AIB_PROJECTION_ROOT          default /var/lib/aib/projection
  AIB_PROJECTION_INTERVAL      timer cadence, default 10s (consumed by aib-projection.timer, not the binary)
  AIB_PROJECTION_DEAD_MINUTES  presumed-dead threshold, default 15
  AIB_BROKER_CAPACITY          mirrored from the broker unit, default 12 (capacity.limit only)
  AIB_EVENT_ROOT                already unit-environment (ADR-0005); read for stream + attempts/.live
  TZ                            must equal the fleet's DEV_TEAM_TZ (§9)

Library:
  aib_attempts_fold <events_path>   (§12 — new, shared by bin/attempts and bin/project)
```

---
White-label: example project id `acme`; no real names, hosts, or infrastructure in this repository.
