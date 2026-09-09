# ADR-0008: The ai-bobnet Dashboard — Schema Bump, Server-Side Rendering, and Reader Account

## Status

Accepted

## Date

2026-09-09

## Context

`plan/BobNet_3.0_ENTSCHEID_sichtbarkeit-und-vm-split.md` (PO decision, 2026-08-15) named a dashboard
as the third of three items behind visibility: (1) `docs/CONTRACT-visibility.md`'s schema, (2) a
dashboard that reads only the projection, (3) decommissioning the engine's 2.0 dashboard on the dev
VM, which the PO found to be a clone with dead links. A design note
(`standup/_design_aib-dashboard.md`, v2) proposed the shape; an architecture consult
(`standup/_advisor_aib-dashboard.md`, Tim, GO_WITH_NOTES, no NO_GO) verified it against the running
code (`lib/aibobnet.sh`'s payload composer, `bin/aib-broker-handler`, `tests/projection_spec.sh`'s
§3 non-consumption pin, `bin/project`) and produced twelve findings, all adopted into the v2 design
this ADR records the reasoning behind. `docs/CONTRACT-visibility.md` is the *what* (schema 2, §19's
rendering obligations); this document is the *why*. The PO signed off the layout draft
(`standup/_design_aib-dashboard/henry-4.html`) on 2026-09-09 ("kann so gebaut werden").

## Decision

### A. Why a schema bump, not a silent additive grow

`docs/CONTRACT-visibility.md` §18 already told readers to tolerate unknown *fields* added additively,
but it also fixed `"schema": 1` as a literal the retiring engine dashboard pins `=== 1` against
(`claude-bobnet/dashboard/server/utils/projection.mjs:39`, advisor finding 7). Growing the shape
without moving the number would make that one consumer's `=== 1` check silently continue to pass over
content it was never verified against — the exact "reader trusts a version number that no longer
means what it once meant" failure this contract's own rule exists to prevent. Bumping to `2` is the
honest reading of "at least the version I understand": nothing else in this codebase's tests asserts
`"schema": 1` (finding 7 verified this), so the only casualty of bumping is the one dashboard already
scheduled for decommission (§F below), and it fails the way §18 predicts for an unknown-but-tolerated
version — not a crash, a clearly wrong "unknown / schema" render, exactly the rollout note states.

### B. Why SSR, Python stdlib, zero JS, no dependencies

Three separate arguments converge on the same answer:

1. **Escaping cannot be black-box tested against client-rendered JSON+JS** (advisor finding 3). A
   `curl`-based test sees only the template if hostile heartbeat text is escaped inside a
   `<script>`-fed JSON blob and interpolated by client-side JS — the test would have to grep the JS
   source for `innerHTML`, which proves the code *looks* safe, not that a given response *is* safe.
   Server-side rendering with Python's `html.escape` on every string makes the test what it should
   be: fetch the page, assert the hostile string appears in its escaped form and the raw form does
   not, for a running server against a real fixture.
2. **Zero dependencies means zero supply chain and zero build step** for two read-only pages. The
   Nuxt-based engine dashboard this replaces needs a `node_modules` tree and a Node version the VM
   does not carry; a two-page read-only render does not need a framework's reactivity model, routing,
   or bundler to show four state hues and some tables. Python 3's `http.server` module
   (`ThreadingHTTPServer`, `BaseHTTPRequestHandler`) plus `html.escape`, `json`, and `os.scandir`
   covers every requirement below with no import outside the standard library — matching this
   codebase's existing precedent that the readers (`bin/attempts`, `bin/project`) already require only
   Python 3.9+ stdlib, isolated mode, no pip dependency (`README.md`'s Runtime requirements).
3. **No JavaScript closes the XSS surface at its root**, rather than mitigating it downstream. A page
   that never evaluates script cannot be made to run an attacker's script, regardless of what a future
   edit gets wrong about escaping one more field. `Content-Security-Policy: default-src 'none';
   style-src 'unsafe-inline'` (permitting only the page's own inline `<style>`, nothing else) is the
   header form of the same decision, and the test can assert it directly rather than trusting review
   discipline to keep noticing every new render path.

`/api/fleet` and `/api/project/<uid>` stay as JSON twins of `/` and `/p/<uid>` — cheap (the JSON is
already computed to render the HTML) and the natural integration point if something other than a
human ever wants this data, without reopening the "second reader of engine truth" question (§D).

### C. Why a daemon, not static regeneration by `bin/project`

Considered and rejected (advisor Q2): pushing HTML generation into `bin/project` itself, so the
timer-driven projector writes ready-to-serve pages next to each `<uid>.json`, with a bare static file
server (or none — files read directly from disk) in front. Rejected for three compounding reasons:

1. **It does not actually remove the daemon**, it only moves what serves HTML on the tailnet from a
   150-line Python process to nginx (or an equivalent) plus its own configuration — a heavier
   dependency for a smaller win.
2. **It moves HTML escaping of hostile agent-written text into the broker account's own writer**
   (`aib-broker`, which already holds `ReadWritePaths=/var/lib/aib/projection`, per
   `deploy/systemd/aib-projection.service`). `bin/project`'s output contract is pinned byte-for-byte
   by `tests/projection_spec.sh`'s rebuild-identical acceptance test (§17) and its `--stdout` shape
   (§18's implementation notes); folding a second, HTML-shaped output into that path widens what the
   broker account produces and what the rebuild test must cover, for a concern (rendering) that has
   nothing to do with why that account exists.
3. **A fleet index needs to exist somewhere**, and `bin/project <uid>` (the single-project invocation)
   cannot keep one consistent — only `--all` sees every project in one pass, and nothing requires an
   operator to run `--all` on every tick. A separate reader that lists `<root>/*.json` itself (§D) does
   not have this problem: it enumerates whatever is actually on disk, right now, every request.

**Adopted:** the daemon reads, the projector writes; the roles stay separated exactly as
ADR-0007 §Alternatives-Considered already argued for the projection's own timer vs. a
handler-triggered nudge. `bin/dashboard` is `Type=simple` under `systemd`, restarted on failure,
never triggered by or coupled to the projector's own `Type=oneshot` timer.

### D. Why the projection root, and never the registry

`docs/CONTRACT-visibility.md` §4/§5 already require every consumer, dashboard included, to never
become a second reader of engine truth. This ADR's mechanical enforcement of that rule for
`bin/dashboard` specifically:

- **Project set** comes from `os.scandir(AIB_PROJECTION_ROOT)` filtered to the `aib_validate_token`
  filename grammar (`^[a-z0-9]([a-z0-9-]*[a-z0-9])?\.json$`), never from `aib_registry_query` or any
  read of the registry file. A registered project with no projection file simply does not appear on
  the fleet page; a *deregistered* project's stale file keeps appearing, aging, until an operator
  removes it (§F of ADR-0007's own reasoning: `bin/project --all` only writes for currently registered
  projects, so a dropped project's last file is never refreshed and never deleted either).
- **`bin/dashboard` never sources `lib/aibobnet.sh`.** Every helper it needs — path validation,
  timestamp arithmetic, JSON escaping — is reimplemented in the ~15 lines it actually costs in Python,
  rather than pulled in from a 3000-line Bash library whose other 95% is registry, event-stream, and
  broker-account machinery this process has no business touching. This is the mechanical form of the
  "import-level, not repo-level" separation advisor Q1 names: placing `bin/dashboard` in this same
  repository is safe specifically because it does not import the engine's own internals.
- **`tests/projection_spec.sh`'s §3 ALLOWLIST is widened by exactly `bin/dashboard`,
  `tests/dashboard_spec.sh`, `docs/decisions/0008-dashboard.md`, and
  `deploy/systemd/aib-dashboard.service`** — no more, no fewer — and a second, counter-pin grep in the
  same test block asserts `bin/dashboard` never mentions `AIBOBNET_REGISTRY`, `AIB_EVENT_ROOT`, or
  `_projection.json` (the standup symlink name). The ALLOWLIST says where the projection root's own
  name may legitimately appear outside `bin/project`; the counter-pin says `bin/dashboard`, once it is
  one of those places, may never also reach for the engine truth the projection merely summarizes.

### E. The `aib-dash` account, the bind rule, and the CSP header

- **A new, distinct `User=aib-dash` account** — not `aib-broker`. Unlike the projector (ADR-0007
  §Alternatives-Considered, which keeps `User=aib-broker` for V-1 because that account already
  existed and the projector's own hardening was judged sufficient), `bin/dashboard` is a new process
  with no legacy account to inherit, so there is no cost to giving it the narrower account from day
  one: read-only group membership in the projection root's shared reader group (`docs/CONTRACT-
  visibility.md` §14, "the shared group (dashboard, operators) reads"), nothing else. `aib-dash` is
  never a member of `aib-broker`'s own group, never granted the credential directory, and never
  granted the event root at all (`InaccessiblePaths=/var/lib/aib/auth /var/lib/aib/events`, tighter
  than the projector's own unit, which needs `ReadOnlyPaths` on the event root to fold it — the
  dashboard never folds anything itself, so it does not need that path even read-only).
- **Bind rule:** `bin/dashboard` refuses to start bound to `0.0.0.0` unless `AIB_DASHBOARD_BIND` names
  it explicitly (never a default) — the same "explicit, not a default" posture
  `docs/CONTRACT-visibility.md` §14 already states for `AIB_PROJECTION_ROOT`. Provisioning sets
  `AIB_DASHBOARD_BIND` to the tailnet IPv4 address, so the service is reachable exactly where Tailscale
  already is this deployment's access boundary (`~/CLAUDE.md`'s "Tailscale is the boundary today,"
  restated in the design note's Scope). `AIB_DASHBOARD_PORT` (default `3030`) is unprivileged, and
  port `0` is honored for tests: the process binds an ephemeral port and prints it, so a test harness
  never has to guess or hardcode one.
- **`Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'`** on every HTML response,
  asserted directly by the test (§B above) rather than left to code review to keep noticing.
  `Cache-Control: no-store` accompanies it — a projection page is disposable, out-of-band data (§4),
  and must never be served from a shared cache as if it were a stable resource.

### F. Rollout note

Between the schema-2 deploy and the VM decommission of the engine's 2.0 dashboard, that dashboard
renders every project as "unknown / schema" (its own `projection.mjs:39` pins `=== 1`). This is
expected and is not a regression to debug — `docs/CONTRACT-visibility.md`'s rollout note (§18/ADR-A
above) states it, and advisor finding 7 verified nothing else in this codebase's own test suite
depends on the literal value `1`. The ordering PO Decision fixed — schema, then dashboard, then
decommission — makes this window unavoidable and bounded; it ends the moment the VM's engine
dashboard checkout is removed, which is item (3) of the same PO decision, tracked separately
(Remote Bob's `prox-init` revier, per `~/CLAUDE.md`'s topology table), not by this ADR.

## Alternatives Considered

### Reusing or extending the engine's 2.0 dashboard on the VM

Rejected by the PO before this design note was written: the running instance is "a clone with dead
links." Extending broken code to speak a new schema is a worse trade than a small, from-scratch
reader with none of that code's accumulated drift.

### Client-side rendering (JSON + vanilla JS)

Rejected — see §B above (advisor finding 3). Recorded separately from §B because the original design
note's first draft proposed exactly this, and the correction is a load-bearing reversal, not a minor
tweak: it changes what the escaping test can even prove.

### A third repository for the dashboard

Rejected (advisor Q1). The §3 non-consumption pin, the shared test runner, the deployment path
(`/opt/aib/engine` already checked out, no build step to add), and the white-label rule all live in
`ai-bobnet`; a third repository would need its own version pin against the projection schema and
would duplicate the visibility contract rather than consume it. The separation that actually matters
is import-level (§D above), not repository-level — revisit only if the dashboard grows a write path,
at which point it stops being "a consumer" in this contract's sense entirely and needs its own ADR
regardless of which repository it lives in.

### Carrying `launch.decided_at`

Considered, dropped (advisor finding 11; `docs/CONTRACT-visibility.md` §18/§2). It would duplicate
`agents[uid].attempt.decided_at` from the identical selected record, and a reader that finds two
timestamps on what is provably one event will reasonably ask which one is authoritative. `attempt`
already carries it; `launch` does not need to.

### Not carrying `reasons`

Considered, reversed (advisor Q3; design note v1's open question). `reasons` is broker-composed
verdict text, not raw user input — the only user-influenced tokens inside it are already-validated
ids — and on a `deny` it is the single fact an operator most needs. The page already renders more
hostile text than this (`message`, `attention[].reason` are agent-written free text); withholding the
one broker-composed field while rendering agent-written ones would be a strange, inconsistent
narrower cut. Carried, capped at 512 bytes in the fold, escaped on render (§18).

### Carrying `adapter.raw` alongside `adapter.source`

Considered, not adopted for this pin. Advisor finding 2 notes `raw` (the registry's provider-name map
value) is as safe to project as `source` and suggests carrying it. This ADR keeps the object to
`{source}` only, matching the design note's S2 exactly: `raw` adds a second, largely redundant way to
learn which provider ran (an operator reading `provider.effective` already has the provider name) for
one more field this contract has to hold stable forever. A future pin may add it additively if an
operator need is found that `provider.effective` does not already answer; this one does not build
ahead of that need.

## Consequences

- `docs/CONTRACT-visibility.md` moves to schema 2: `agents[uid].launch`, `attested_sources` gaining
  `"launch"`, `anomalies.launch_malformed`, and the new §19 rendering obligations. Schema 1 is
  superseded, not deleted from history — the frozen shape it described remains exactly what shipped.
- `lib/attempts_fold.py` gains `launch` on the non-legacy `fold_records` path, passed through as raw
  JSON with a malformed-tolerant `anomalies.launch_malformed` counter, never a `ValueError` on old
  fixtures (`docs/CONTRACT-visibility.md` §18's implementation notes).
- `bin/dashboard` is a new, standalone Python 3 stdlib executable: no change to `bin/project`'s own
  CLI contract, no new dependency on any existing binary.
- `deploy/systemd/aib-dashboard.service` is a new unit, `User=aib-dash` (a new account provisioning
  must create), read-only on the projection root, with no `ReadWritePaths` anywhere.
- `docs/CONFINEMENT.md`'s runtime-dependency notes gain `bin/dashboard`'s own python3-stdlib-only
  dependency line, and its existing "read-only consumer of `lib/aibobnet.sh`" list is corrected to
  drop the dashboard, which this ADR moves outside that list entirely (§D).
- `tests/projection_spec.sh`'s §3 ALLOWLIST and counter-pin are widened by exactly the four paths in
  §D above; `tests/dashboard_spec.sh` is new and RED until `bin/dashboard` and the schema-2 fold both
  exist.
- **Known limits, stated rather than hidden:** the dashboard cannot show anything the projection
  itself does not carry (§6 of `docs/CONTRACT-visibility.md` already states this for any consumer);
  the rollout window named in §F is a known, bounded period of a stale second dashboard rather than a
  defect; a distinct `aib-projector` account (ADR-0007's own deferred item) remains deferred and is
  unaffected by `aib-dash` existing, because the two accounts solve different halves of the same
  "narrow the reader" goal.

This ADR extends ADR-0007; it reverses neither ADR-0007 nor ADR-0006.

---
White-label: example project id `acme`; no real names, infrastructure, or hosts in this repository.
