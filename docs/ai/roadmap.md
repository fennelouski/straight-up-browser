# Browser 2.0 AI tooling roadmap

## Objective

Deliver one dependable runtime for long-running, recoverable agent work without
duplicating tool schemas, permission decisions, budgets, or run history. The
sequence below is the dependency order used for Browser 2.0; durable feature IDs
remain useful after release for compatibility and regression tracking.

## Current baseline

Before the 2.0 runtime work, Straight Up Browser provided:

- a native, bounded agent loop over OpenAI-compatible chat-completion APIs;
- direct OpenAI, OpenRouter, Ollama, LM Studio, and custom endpoint settings;
- a 53-tool BrowserOS-compatible stdio MCP catalogue;
- stable `windowUUID:tabUUID` Page IDs and background/hidden Pages;
- dynamic Streamable HTTP MCP tools with Keychain bearer tokens;
- immediate text-file tools scoped to a security-bookmarked Cowork folder;
- basic daily and interval schedules while the browser was running;
- MCP-specific JSONL audit logs and post-action page frames.

The feature map and engine boundaries live in
[BrowserOS AI parity](../browseros-parity.md).

## Delivery sequence

Every slice is complete for the Browser 2.0 macOS release. The companion iPadOS
target compiles with the shared safe-definition code, but its UI, accessibility,
CloudKit round-trip, App Store, and device acceptance are a separately tracked
follow-up and do not gate the signed macOS 2.0.0 distribution.

| Horizon | ID | Outcome | Depends on | Status |
|---|---|---|---|---|
| Foundation | AI-001 | One canonical, versioned tool catalogue | — | Complete |
| Foundation | AI-002 | Durable conversations, Runs, and Steps | AI-001 | Complete |
| Foundation | AI-003 | Contextual policy and human approvals | AI-001, AI-002 | Complete |
| Foundation | AI-004 | Streaming provider adapters and usage accounting | AI-002 | Complete |
| Foundation | AI-005 | Resilient semantic element references and waits | AI-001 | Complete |
| Dependability | AI-006 | Unified timeline, redaction, and replay | AI-002, AI-003 | Complete |
| Dependability | AI-007 | Reliable, configurable scheduled tasks | AI-002, AI-003, AI-004 | Complete |
| Dependability | AI-008 | MCP trust, native OAuth, and connection lifecycle | AI-003, AI-006 | Complete |
| Dependability | AI-009 | Reviewable Cowork artifact transactions | AI-003, AI-006 | Complete |
| Scale | AI-010 | Multi-agent Run Groups with Page ownership | AI-002, AI-003, AI-005 | Complete |
| Scale | AI-011 | User-controlled, scoped agent memory | AI-002, AI-003 | Complete |
| Scale | AI-012 | Budgets, diagnostics, and local observability | AI-002, AI-004, AI-006 | Complete |
| Native signals | AI-013 | WebKit-native console, download, and navigation signals | AI-001, AI-005 | Complete |
| Definition sync | AI-014 | Opt-in sync for safe agent definitions | AI-002, AI-007 | Complete |

Detailed acceptance criteria are in
[Feature specifications](feature-specs.md).

## Milestones

### M1 — One execution core

AI-001 through AI-004 establish the shared core. The built-in panel, schedules,
and MCP bridge describe tools through one catalogue, record the same Run model,
and pass invocations through typed policy. Provider-specific payloads stop at
their adapter boundary.

Exit criteria:

- no hand-authored duplicate input schema for the same built-in tool;
- every built-in and scheduled prompt creates a durable `AgentRun`;
- cancellation and app termination leave a recoverable terminal state;
- a risky action cannot execute before its policy decision is recorded;
- model text streams to the UI and reports token usage when the provider does.

### M2 — Trustworthy unattended work

AI-005 through AI-009 make execution reviewable. Runs wait for observable
WebKit conditions, share timeline/replay regardless of entry point, recover
after relaunch, and pause for approval. MCP connections and Cowork commits are
inspectable trust boundaries rather than opaque tools.

Exit criteria:

- schedules survive browser downtime according to an explicit catch-up policy;
- unattended runs never block forever on an approval dialog;
- replay shows model, tool, approval, handoff, and artifact events;
- file writes have a previewable before/after record;
- MCP tools show their server identity and effective permissions at approval
  time.

### M3 — Controlled parallelism

AI-010 through AI-012 add bounded delegation, scoped memory, and local
observability. One request may coordinate workers without racing the same Tab
or spending outside a shared budget; memory is inspectable and independently
erasable.

Exit criteria:

- Page ownership prevents conflicting writes and focus theft;
- a run group has shared step, time, and cost limits;
- the user can export a redacted diagnostic bundle;
- saved memory can be reviewed, disabled per scope, and deleted independently
  of browsing history.

### M4 — Native signals and safe definitions

AI-013 and AI-014 add WebKit-supported runtime observations and category-level
private CloudKit sync. Both preserve local-first execution: signal capture is
bounded and content opt-ins are explicit; a synced definition is inert until
the receiving device satisfies its local dependencies and policy.

Exit criteria:

- unsupported CDP details are reported as unsupported, never fabricated;
- console and diagnostic text collection remain separately opt in;
- incognito signal content is cleared under the default policy;
- sync records contain only allowlisted, nonsecret definition payloads;
- disabling a sync category offers keep-local or delete-cloud behavior;
- iPadOS retains unsupported definitions without attempting macOS-only work.

## Prioritization rules

When choosing work inside a milestone, prefer the change that removes the most
duplicate policy or persistence logic. Do not add a new autonomous surface that
bypasses `AgentRun`, the policy engine, or the canonical tool catalogue. A new
provider or tool category is lower priority than making current runs
recoverable and reviewable.

Platform differences are intentional. macOS owns the full automation surface.
iPadOS exposes the safe definition-sync choices and can retain unsupported
definitions, but it cannot execute macOS-only scheduled/Cowork/MCP automation.
Neither platform treats a synced record as authority: local credentials,
connections, scopes, browser Sessions, capabilities, and policy must all pass.

## iPadOS follow-up

The macOS 2.0.0 release does not ship or certify a new iPad build. Before the
companion target is released, complete all of the following on the exact iPad
source revision selected for that release:

1. Run the full `Browser iOS` unit and UI plans on the supported iPad simulator
   matrix and at least one physical iPad, with warnings treated as errors.
2. Exercise all three definition-sync category toggles, including cancel,
   keep-local, delete-cloud, re-enable, tombstone convergence, and conflict
   resolution across a real private CloudKit account shared with a Mac.
3. Confirm imported schedules remain inert and visibly unavailable until every
   local provider, MCP, Cowork, browser-Session, capability, and policy
   dependency is satisfied; iPadOS must never attempt macOS-only execution.
4. Verify VoiceOver, Dynamic Type, keyboard navigation, touch targets, rotation,
   multitasking, offline/relaunch recovery, and incognito non-retention for the
   Agent Definition Sync settings and unavailable-definition review UI.
5. Recheck production CloudKit container entitlements/schema, device-only
   Keychain behavior, privacy manifests, App Store signing/provisioning,
   screenshots, metadata, TestFlight installation, and upgrade migration from
   the last public iPad build.
6. Give iPadOS its own version/build decision and release approval. A passing
   macOS DMG/notarization run is not evidence that the iPad app is ready to ship.
