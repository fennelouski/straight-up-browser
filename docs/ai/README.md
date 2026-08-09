# AI tooling development guide

This directory turns Straight Up Browser's existing BrowserOS-parity layer into
an implementation roadmap for the next generation of agent tooling. It is for
maintainers and coding agents: each planned capability has a stable ID,
dependencies, boundaries, and testable acceptance criteria.

The baseline is the implementation described in
[BrowserOS AI parity](../browseros-parity.md): the live WebKit browser already
has a built-in agent, 53-tool MCP server, stable page IDs, background pages,
model-provider configuration, Streamable HTTP MCP connections, a scoped Cowork
folder, scheduled tasks, and local audit/replay. The items here improve the
cohesion, reliability, safety, and extensibility of those features; they should
not be presented as missing BrowserOS parity.

## Read in this order

1. [Roadmap](roadmap.md) — priority and dependency order.
2. [Architecture](architecture.md) — target boundaries, domain names, and
   contracts.
3. [Security and privacy](security-and-privacy.md) — threat model and policy
   invariants.
4. [Feature specifications](feature-specs.md) — independently buildable work.
5. [Testing strategy](testing.md) — required verification and fixtures.

The proposed naming decision in
[ADR-0003](../adr/0003-agent-lifecycle-language.md) is normative for new code:
`BrowserSession` remains the website-data isolation container; an AI execution
is an `AgentRun`, never an "agent session."

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
behavior, and macOS/iPadOS scope are explicit. It is complete only when:

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
