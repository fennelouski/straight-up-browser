# AI tooling roadmap

## Objective

Make the existing agent feature set dependable enough for long-running,
recoverable work and simple enough to extend without duplicating tool schemas,
permission decisions, or run history. The sequence below deliberately builds
shared foundations before adding more autonomy.

## Current baseline

As of 2026-08-09, Straight Up Browser already provides:

- a native, bounded agent loop over OpenAI-compatible chat-completion APIs;
- direct OpenAI, OpenRouter, Ollama, LM Studio, and custom endpoint settings;
- a 53-tool BrowserOS-compatible stdio MCP catalogue;
- stable `windowUUID:tabUUID` Page IDs and background/hidden Pages;
- dynamic Streamable HTTP MCP tools with Keychain bearer tokens;
- six text-file tools scoped to a security-bookmarked Cowork folder;
- daily and interval schedules while the browser is running;
- MCP JSONL audit logs and post-action page frames.

The feature map and engine boundaries live in
[BrowserOS AI parity](../browseros-parity.md).

## Delivery sequence

| Horizon | ID | Outcome | Depends on |
|---|---|---|---|
| Foundation | AI-001 | One canonical, versioned tool catalogue | — |
| Foundation | AI-002 | Durable conversations, runs, and steps | AI-001 |
| Foundation | AI-003 | Contextual policy and human approvals | AI-001, AI-002 |
| Foundation | AI-004 | Streaming provider adapters and usage accounting | AI-002 |
| Foundation | AI-005 | Resilient semantic element references and waits | AI-001 |
| Dependability | AI-006 | Unified timeline, redaction, and replay | AI-002, AI-003 |
| Dependability | AI-007 | Reliable, configurable scheduled tasks | AI-002, AI-003, AI-004 |
| Dependability | AI-008 | MCP trust, OAuth, and connection lifecycle | AI-003, AI-006 |
| Dependability | AI-009 | Reviewable Cowork artifact transactions | AI-003, AI-006 |
| Scale | AI-010 | Multi-agent run groups with Page ownership | AI-002, AI-003, AI-005 |
| Scale | AI-011 | User-controlled, scoped agent memory | AI-002, AI-003 |
| Scale | AI-012 | Budgets, diagnostics, and local observability | AI-002, AI-004, AI-006 |
| Later | AI-013 | WebKit-native console, download, and request signals | AI-001, AI-005 |
| Later | AI-014 | Opt-in sync for safe agent definitions | AI-002, AI-007 |

Detailed acceptance criteria are in
[Feature specifications](feature-specs.md).

## Milestones

### M1 — One execution core

Complete AI-001 through AI-004. The built-in panel, schedules, and MCP bridge
must describe tools through one catalogue, record the same run model, and pass
every invocation through the same policy decision. Provider-specific response
shapes stop leaking into the run engine.

Exit criteria:

- no hand-authored duplicate input schema for the same built-in tool;
- every built-in and scheduled prompt creates a durable `AgentRun`;
- cancellation and app termination leave a recoverable terminal state;
- a risky action cannot execute before its policy decision is recorded;
- model text streams to the UI and reports token usage when the provider does.

### M2 — Trustworthy unattended work

Complete AI-005 through AI-009. Runs can wait for observable WebKit conditions,
replay the same way regardless of entry point, recover after relaunch, and pause
for approval. MCP connections and file mutations become inspectable trust
boundaries rather than opaque tools.

Exit criteria:

- schedules survive browser downtime according to an explicit catch-up policy;
- unattended runs never block forever on an approval dialog;
- replay shows model, tool, approval, handoff, and artifact events;
- file writes have a previewable before/after record;
- MCP tools show their server identity and effective permissions at approval
  time.

### M3 — Controlled parallelism

Complete AI-010 through AI-012. One user request may coordinate bounded workers
without two agents racing the same Tab or spending without a shared budget.
Memory is inspectable, scoped, and erasable.

Exit criteria:

- Page ownership prevents conflicting writes and focus theft;
- a run group has shared step, time, and cost limits;
- the user can export a redacted diagnostic bundle;
- saved memory can be reviewed, disabled per scope, and deleted independently
  of browsing history.

## Prioritization rules

When choosing work inside a milestone, prefer the change that removes the most
duplicate policy or persistence logic. Do not add a new autonomous surface that
bypasses `AgentRun`, the policy engine, or the canonical tool catalogue. A new
provider or tool category is lower priority than making current runs
recoverable and reviewable.

Platform differences are allowed. macOS owns the full automation surface;
iPadOS may provide conversation viewing, synced task definitions, or attended
agent execution only when WebKit and background-execution rules support them.
Do not weaken macOS security rules to manufacture cross-platform symmetry.
