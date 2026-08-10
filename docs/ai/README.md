# AI tooling guide

This directory records the Straight Up Browser 2.0 agent runtime: its delivery
map, component boundaries, security invariants, durable feature IDs, and release
acceptance criteria. It is for maintainers and coding agents working on the
implementation without duplicating schemas, weakening authority checks, or
inventing capabilities WebKit does not expose.

The public compatibility baseline remains the implementation described in
[BrowserOS AI parity](../browseros-parity.md): the live WebKit browser has a
built-in agent, an exact 53-tool BrowserOS-compatible MCP profile, stable Page
handles, hidden Pages, provider configuration, external Streamable HTTP MCP,
Cowork, schedules, and replay. AI-001 through AI-014 consolidate those surfaces
behind one durable, policy-gated, observable runtime. The extra native tools do
not rename or expand the 53-tool compatibility profile.

## Read in this order

1. [Roadmap](roadmap.md) — delivery order and release milestones.
2. [Architecture](architecture.md) — implemented boundaries, domain names, and
   contracts.
3. [Security and privacy](security-and-privacy.md) — threat model and policy
   invariants.
4. [Feature specifications](feature-specs.md) — durable feature contracts and
   acceptance criteria.
5. [Testing strategy](testing.md) — required verification; it is not a record of
   results until a release run is attached.

The naming decision in
[ADR-0003](../adr/0003-agent-lifecycle-language.md) is normative:
`BrowserSession` remains the website-data isolation container; an AI execution
is an `AgentRun`, never an "agent session."

[ADR-0004](../adr/0004-browser-2-agent-runtime-and-mcp-oauth.md) records the
2.0 execution-core and native MCP OAuth decisions, including the real ephemeral
loopback callback and logical-invocation idempotency boundary.

## Planning conventions

Feature IDs are durable. Do not renumber them when priorities change. A feature
may use one of these states in an issue or pull request:

- **Proposed** — the problem and outcome are documented, but dependencies or
  interface decisions remain.
- **Ready** — dependencies are available and acceptance criteria are specific
  enough to implement.
- **In progress** — an owner has a branch or pull request.
- **Complete** — acceptance criteria and the testing strategy pass.
- **Blocked** — a concrete platform, product, or dependency decision prevents
  progress.

A feature is ready only when its persistence impact, permission impact, failure
behavior, and macOS/iPadOS scope are explicit. The implementation may be marked
**In progress** while code is present but full release acceptance is pending. It
is **Complete** only when:

- public tool names and payloads remain compatible or have a versioned
  migration;
- cancellation, relaunch recovery, and permission denial have tests;
- secrets and page/file content do not appear in ordinary logs;
- the user can identify what acted, where it acted, and what changed;
- `./scripts/verify.sh` passes.

## Product rules

- Agents operate the user's real Tabs and existing browser Sessions. There is
  no second automation profile or debugging browser.
- A Page handle addresses a Tab. A hidden/background Page is still an ordinary
  Tab with different presentation and memory policy.
- A Split is view state, not an automation container. Agents may address its
  member Tabs individually but must not create a new split-specific page type.
- Page content, downloaded text, and MCP results are untrusted data. They never
  grant authority.
- Scheduled work has less implied authority than an attended prompt, not more.
- Chromium/CDP emulation is not a goal. WebKit capabilities should have native
  semantics and explicit unsupported results where no safe equivalent exists.
- Local-first is the default: definitions may sync only with an explicit
  product decision; secrets, run transcripts, replay frames, and Cowork files
  stay local by default.
- Settings has one Agent pane for provider/Keychain configuration, Cowork,
  schedules and MCP connections, timeline/replay, approvals and hard budgets,
  child-run limits, memory, local observability/WebKit signal opt-ins, and
  definition sync. A UI control must read the same setting key as its runtime.
- Definition sync is private-CloudKit, category-specific, and off by default.
  Imported definitions never carry local authority and cannot run until local
  dependencies and policy are satisfied.
