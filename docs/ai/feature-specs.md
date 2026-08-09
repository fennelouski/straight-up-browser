# Future AI tooling feature specifications

These are implementation-ready product slices, ordered by the roadmap. Each
slice must preserve the current BrowserOS-compatible MCP surface unless its
acceptance criteria explicitly define a versioned change. All slices inherit
the invariants in [Architecture](architecture.md),
[Security and privacy](security-and-privacy.md), and
[Testing strategy](testing.md).

## AI-001 — Canonical tool catalogue

**Status:** Ready

**Depends on:** None

### Outcome

One Foundation-only catalogue defines browser, Cowork, and internal tool
metadata. The built-in agent and MCP server render provider/protocol schemas
from it instead of hand-maintaining overlapping arrays.

### Current limitation

`BrowserAgent` and `browserMCPTools` independently declare names,
descriptions, required fields, and JSON types. The built-in agent intentionally
exposes a subset plus `wait_for_page` and Cowork tools, but shared tools can
drift silently.

### Build

- Add `AgentToolDescriptor`, typed JSON Schema values, tool origin, risk,
  required capabilities, output schema, version, and visibility profiles.
- Put descriptors in a file/module compiled by both Browser and `browser-cli`
  without SwiftUI, AppKit, or WebKit imports.
- Render OpenAI-style function definitions and MCP `tools/list` entries.
- Keep dispatch separate: a descriptor never executes its tool.
- Support compatibility aliases and schema deprecation metadata without
  exposing duplicate model-visible names in one profile.

### Acceptance criteria

- MCP still exposes the documented 53 names and compatible required arguments.
- Every overlapping built-in/MCP tool comes from the same descriptor.
- `wait_for_page`, Cowork, and future tools use explicit visibility profiles.
- Catalogue validation rejects duplicate names, unresolved aliases, missing
  risk/capability metadata, and unsupported schema constructs.
- Snapshot tests cover both renderers and the exact 53-tool compatibility view.

### Non-goals

Renaming tools, consolidating the 53 compatibility tools, or changing execution
behavior.

## AI-002 — Durable conversations, runs, and steps

**Status:** Proposed

**Depends on:** AI-001

### Outcome

Every attended, scheduled, and externally initiated AI execution has a durable,
queryable lifecycle and can be diagnosed or recovered after relaunch.

### Current limitation

The panel writes message arrays to a newly generated conversation file but does
not index or reopen them. Scheduled tasks retain 15 summary strings. MCP audit
uses a separate JSONL format. Success is partly inferred from message roles.

### Build

- Introduce `AgentConversation`, `AgentRun`, `AgentStep`, `AgentArtifact`, and
  a versioned `AgentRunStore` using the architecture's storage layout.
- Record explicit state transitions and monotonic step sequence numbers.
- Snapshot model/provider/tool/policy configuration into each run.
- On launch, mark nonterminal runs `interrupted`; require an explicit recovery
  decision.
- Index by conversation, task definition, date, status, provider, and parent
  run without reading step bodies.
- Import legacy panel conversation JSON and MCP audit JSONL; do not call either
  an AgentSession.

### Acceptance criteria

- Panel history lists and reopens conversations across relaunch.
- Built-in and scheduled execution write the same run/step types.
- Cancellation, failure, denial, limit exhaustion, and interruption are
  distinguishable terminal/recoverable outcomes.
- A truncated final JSONL line does not corrupt earlier steps.
- Deleting a conversation removes its runs and artifacts; deleting one run
  preserves other conversation runs.
- Store and migration scenario tests pass with owner-only file permissions.

### Non-goals

Automatic cross-device transcript sync or automatic resume after app launch.

## AI-003 — Contextual policy and approvals

**Status:** Proposed

**Depends on:** AI-001, AI-002

### Outcome

All tool entry points use one enforceable policy decision, and users approve
the concrete effect of risky actions rather than relying on a system prompt.

### Current limitation

CLI/MCP has global capability switches and the agent prompt warns against
consequential actions, but the built-in run loop has no typed per-invocation
approval gate. Dynamic MCP effects are not classified locally.

### Build

- Add typed capabilities, risk classes, `AgentInvocationContext`, policy rules,
  approval requests, decisions, scopes, expiry, and invocation digests.
- Resolve Page/origin/browser Session, file canonical path, or MCP identity
  before evaluating policy.
- Add nonmodal approval UI to attended runs and notification-based
  `waitingForHuman` behavior for schedules.
- Pass built-in agent, scheduler, MCP, and CLI execution through the same policy
  service while preserving existing static Security switches.
- Record decisions before effects and return structured denial/expiry results.

### Acceptance criteria

- No executor route is callable without a recorded allow decision.
- Approval invalidates after target, arguments, origin, schema, or identity
  changes.
- Allow-once and exact-target-for-run scopes work; persistent grants are only
  created/revoked in Settings.
- Scheduled destructive, financial, auth, or ambiguous external effects cannot
  continue unattended.
- Prompt injection fixtures cannot alter capabilities, scopes, or budgets.
- Incognito and cross-browser-Session policy tests fail closed.

### Non-goals

Autonomously judging whether a purchase or message is ethically desirable. The
engine enforces authority and requires the user for consequential ambiguity.

## AI-004 — Streaming provider adapters

**Status:** Proposed

**Depends on:** AI-002

### Outcome

Provider APIs are isolated behind one normalized streaming contract. The panel
shows incremental text/tool progress, cancellation is prompt, and usage/cost
can be budgeted.

### Current limitation

The current loop posts one OpenAI Chat Completions-shaped request and waits for
the complete JSON response. Provider identity mostly changes endpoint/defaults,
and usage is not persisted.

### Build

- Define normalized request/content parts, model events, finish reasons, usage,
  provider capabilities, and retry classification.
- Implement adapters for the current OpenAI-compatible chat path first, then
  native OpenAI Responses, Anthropic Messages, and Gemini generateContent as
  separate additions.
- Support streaming text and incremental tool calls, cancellation, bounded
  retry before side effects, and provider-reported usage.
- Keep API keys in Keychain and adapter errors redacted.
- Allow a task/run to snapshot its provider, model, endpoint identity,
  temperature/reasoning controls where supported, and hard budgets.

### Acceptance criteria

- The run engine contains no vendor response-key parsing.
- Scripted fixtures for all adapters produce the same normalized event story.
- Text appears incrementally, a cancelled stream cannot execute a later tool,
  and malformed tool arguments produce a recorded validation result.
- Unsupported capabilities are declared before the run rather than failing
  halfway through.
- Usage and finish reason are persisted when available; missing usage remains
  explicitly unknown.

### Non-goals

Guaranteeing feature equivalence between models or estimating cost when a
provider supplies neither usage nor configured pricing.

## AI-005 — Semantic references and observable waits

**Status:** Proposed

**Depends on:** AI-001

### Outcome

Web agents can act reliably on dynamic pages without arbitrary sleeps or stale
selectors, using semantics WebKit can safely expose.

### Current limitation

Snapshot IDs are injected into the current DOM and the native agent has a load
wait. Modern pages may replace nodes, use shadow roots or frames, and complete
useful state changes after the main load event.

### Build

- Return element references containing PageHandle, navigation/document
  generation, local ID, role/name/state, frame context, and geometry digest.
- Resolve references just before action and reject stale/ambiguous matches.
- Add `wait_for` conditions for load state, URL, selector, text, element state,
  dialog, download start/completion, and Page close.
- Observe DOM changes with bounded `MutationObserver` bridges and WebKit
  navigation/download delegates; clean up observers on cancellation.
- Traverse open shadow roots. Represent inaccessible cross-origin frames as
  explicit boundaries rather than pretending their DOM is available.

### Acceptance criteria

- A reference never acts on a new document or substituted node silently.
- Waits are event-driven where possible, have a required maximum timeout, and
  return the observed condition or a typed timeout/cancellation error.
- Hidden/background Pages work without focus changes.
- Dynamic-page fixtures cover DOM replacement, delayed enablement, shadow DOM,
  same-origin frames, inaccessible cross-origin frames, navigation, dialogs,
  and downloads.
- Existing `sub-N` compatibility identifiers continue to work within their
  documented lifetime.

### Non-goals

CDP network-idle semantics, closed-shadow-root access, cross-origin DOM bypass,
or anti-bot/captcha evasion.

## AI-006 — Unified timeline and replay

**Status:** Proposed

**Depends on:** AI-002, AI-003

### Outcome

One timeline explains attended, scheduled, MCP, and future child-agent runs,
including what was proposed, approved, executed, changed, and retained.

### Current limitation

Replay reads MCP-specific JSONL and post-action frames. Built-in conversations
and schedule summaries are separate and omit policy/model lifecycle events.

### Build

- Render model, tool, approval, handoff, state, artifact, usage, and error steps
  from `AgentRunStore`.
- Capture frames according to policy before and/or after visual mutations, with
  PageHandle, URL origin, viewport, and step references.
- Add redaction states, missing-artifact handling, retention, delete, and
  redacted diagnostic export.
- Show argument/result summaries without eagerly loading content artifacts.
- Add step filters, autoplay, keyboard controls, and accessible descriptions.

### Acceptance criteria

- All run entry points appear in the same history and timeline UI.
- Every frame/artifact links to exactly one step and every mutation links to its
  policy decision.
- Incognito captures are off by default and are removed at run completion.
- Missing, expired, or redacted artifacts do not make a run unreadable.
- Deletion and retention remove frames, artifacts, indexes, and orphaned temp
  files.
- Export contains no configured fixture secrets, query strings, or content
  bodies by default.

## AI-007 — Reliable scheduled tasks

**Status:** Proposed

**Depends on:** AI-002, AI-003, AI-004

### Outcome

Scheduled agent work has explicit execution configuration, downtime behavior,
budgets, concurrency, and human-handoff semantics.

### Current limitation

The in-process 30-second timer uses the current global provider/model and needs
an available browser window. A missed run waits until a future schedule, task
definitions cannot be edited comprehensively, and only summary output is kept.

### Build

- Extend task definitions with provider/model snapshot, Page/browser Session
  scope, MCP connections, Cowork access, budgets, timeout, concurrency policy,
  retention, and catch-up policy (`skip`, `runLatest`, or bounded `runAll`).
- Add full create/edit/duplicate/delete UI and validate schedules across time
  zone and daylight-saving changes.
- Recover due tasks on launch and create full `AgentRun` records.
- Serialize, skip, or queue overlap according to definition; never accidentally
  run the same occurrence twice.
- Notify on waiting-for-human, failure, repeated failure, and configured
  success conditions.

### Acceptance criteria

- A task runs with its saved configuration even after global settings change.
- Relaunch tests cover every catch-up and overlap policy with stable occurrence
  IDs and no duplicates.
- No-window execution either creates a sanctioned hidden browser window or
  records a clear blocked outcome according to the chosen platform design.
- An approval need pauses/notifies without displaying an unattended modal.
- Disabling or deleting a task prevents future occurrences but preserves run
  history until separately deleted.
- Time-zone/DST, cancellation, budget, and repeated-failure tests pass.

### Non-goals

Promising execution while the Mac is shut down. OS background launch/wake
support, if added, requires a separate entitlement and energy-impact decision.

## AI-008 — MCP trust and OAuth lifecycle

**Status:** Proposed

**Depends on:** AI-003, AI-006

### Outcome

Users can connect standards-compliant remote MCP servers, understand their
identity and scopes, and revoke or reauthorize them without opaque credentials.

### Current limitation

Connections accept a Streamable HTTP endpoint and optional bearer token.
OAuth-only services require a separately operated local remote bridge, and
server/schema changes are not a first-class trust version.

### Build

- Implement MCP authorization discovery and OAuth 2.1 with PKCE where advertised,
  using the system authentication session and Keychain token storage.
- Track normalized endpoint, server identity, protocol/capabilities, tool schema
  digest, auth scopes, last test, and trust version.
- Add reconnect, refresh, revoke, and reauthorize flows plus clear failure UI.
- Enforce HTTPS except loopback, response size/depth limits, timeouts, and
  namespaced collision-safe model tool names.
- Feed connection/tool identity and egress details into policy and replay.

### Acceptance criteria

- No OAuth token or authorization code appears in settings files, logs, runs,
  exports, or model context.
- Endpoint/server/schema/scope changes invalidate earlier grants.
- Revocation removes Keychain material and prevents calls immediately.
- Concurrent calls use the correct MCP connection/session negotiation and
  recover from an expired access token once without duplicating mutations.
- Loopback fixtures cover OAuth success, denial, refresh, revocation, schema
  change, collision, protocol mismatch, oversized data, and timeout.

### Non-goals

Shipping vendor-specific connector proxies or storing a service's website
cookies as an integration credential.

## AI-009 — Cowork artifact transactions

**Status:** Proposed

**Depends on:** AI-003, AI-006

### Outcome

Agents can create and update useful local artifacts with preview, recovery, and
a precise record of what changed.

### Current limitation

Cowork supports scoped UTF-8 list/read/write/move/Trash operations with size and
containment checks, but writes are immediately applied and run history does not
show a diff or artifact manifest.

### Build

- Introduce a per-run artifact workspace and transaction API for create,
  replace, append, move, and recoverable delete.
- Generate text diffs and metadata previews before committing risky changes.
- Use atomic replacement and retain a bounded prior version for rollback.
- Add typed artifact results with content type, byte count, digest, source
  steps, final relative path, and commit status.
- Later format handlers may add structured document operations, but each is a
  separate capability and must preserve format fidelity.

### Acceptance criteria

- The user can inspect and approve a pending overwrite/delete and identify the
  producing run afterward.
- Cancellation before commit leaves the destination unchanged; interruption
  during commit leaves either the prior or complete new file.
- Rollback restores the prior version within retention limits.
- Symlink, alias, traversal, hard-link-policy, large-file, recursion, disk-full,
  and filename-collision fixtures fail safely.
- Model context receives only the bounded result needed for the next step, not
  every artifact body.

### Non-goals

An unrestricted shell, arbitrary absolute-path access, or silent binary-file
rewrites.

## AI-010 — Multi-agent run groups

**Status:** Proposed

**Depends on:** AI-002, AI-003, AI-005

### Outcome

One parent run can delegate bounded independent work to child runs without Page
races, focus theft, unbounded fan-out, or fragmented audit.

### Build

- Add `AgentRunGroup`, child-run contracts, Page read/write leases, shared
  budgets, maximum depth/fan-out, cancellation propagation, and result handoff.
- Require a child objective, allowed tools, allowed Pages/origins/browser
  Sessions, and return schema.
- Prefer child-created hidden Pages. Mutating an existing user Tab requires an
  explicit lease and applicable approval.
- Present a tree/timeline with per-child status and parent synthesis.
- Detect deadlock, orphaned Pages, duplicate work, and child failure policy.

### Acceptance criteria

- Two child runs cannot mutate the same Page concurrently.
- Readers do not block each other; navigation or document replacement
  invalidates relevant observations.
- Parent cancellation stops children, provider streams, waits, and Pages it
  created according to cleanup policy.
- Children cannot exceed parent tools, data scope, cost, time, or step budgets.
- Approval is never inherited beyond its exact digest/scope.
- Parallel deterministic scenarios produce a complete unified run tree.

### Non-goals

Unbounded autonomous swarms, cross-device workers, or making a Split into an
agent ownership primitive.

## AI-011 — Scoped, user-controlled memory

**Status:** Proposed

**Depends on:** AI-002, AI-003

### Outcome

Agents can reuse durable facts and preferences without treating browsing
history or old transcripts as invisible global memory.

### Build

- Add memory entries with source/provenance, scope (`global`, origin, task, or
  conversation), sensitivity, created/last-used time, expiry, and user-edited
  text.
- Make writes explicit model proposals evaluated by policy; sensitive inferred
  facts require approval.
- Retrieve a small ranked set only when scope matches and record which entries
  entered a run.
- Provide review, search, edit, disable, export, delete, and “forget this” UI.
- Keep memory storage separate from browsing history, bookmarks, and provider
  context caches.

### Acceptance criteria

- Memory never crosses origin/task/browser-Session scope unexpectedly.
- The user can see why an entry exists and every run that consumed it.
- Deleting history, a conversation, or memory follows explicit independent
  rules; UI explains the difference.
- Incognito runs neither read nor write durable memory by default.
- Prompt injection cannot silently create a persistent instruction.
- Retrieval tests are deterministic and enforce token/entry limits.

### Non-goals

Training a model on browser history, hidden behavioral profiling, or storing
authentication data.

## AI-012 — Budgets, observability, and diagnostics

**Status:** Proposed

**Depends on:** AI-002, AI-004, AI-006

### Outcome

Users and maintainers can understand latency, failure, token use, cost when
known, and resource consumption without sending telemetry by default.

### Build

- Add per-run and per-task limits for turns, tool calls, elapsed time, provider
  tokens/cost, Pages, model-result bytes, downloads, and artifacts.
- Record local metrics for provider latency, time-to-first-token, tool latency,
  retries, approvals, failure categories, and resource peaks.
- Add a run summary and aggregate local dashboard with clear unknown values.
- Add a previewable redacted diagnostic bundle containing versions,
  configuration shape, timeline metadata, metrics, and selected errors.
- Make any future remote diagnostics separate, opt-in, documented, and
  independently disableable.

### Acceptance criteria

- Hard limits stop the next operation and produce an explicit limit step.
- Child runs consume shared parent budgets atomically.
- Non-idempotent tools are never repeated to improve a latency metric or after
  an ambiguous timeout.
- Cost is shown only from provider usage plus user/provider pricing metadata;
  estimates are labeled.
- Default diagnostic fixtures contain no prompts, page/file/MCP bodies, full
  URLs, screenshots, secrets, or authorization headers.

## AI-013 — WebKit-native diagnostic signals

**Status:** Proposed

**Depends on:** AI-001, AI-005

### Outcome

Agents can reason about console errors, downloads, navigation responses, and a
bounded set of request outcomes using supported WebKit hooks.

### Build

- Capture opt-in page console messages through an isolated script bridge with
  source, level, timestamp, and size limits.
- Expose navigation response/status, redirects visible to delegates, TLS state,
  failed resource signals WebKit actually surfaces, and download lifecycle.
- Add observation/wait tools with explicit capability metadata and retention.
- Mark unavailable details as unsupported; never fabricate CDP request IDs,
  timing waterfalls, cache internals, or response bodies.

### Acceptance criteria

- Tool docs accurately distinguish main-navigation signals from subresource
  coverage.
- Console content is treated as hostile page data and cannot grant authority.
- Buffers are bounded per Page/run and cleared for incognito by default.
- Local fixtures cover redirects, navigation errors, console levels, download
  completion/failure, cancellation, and unsupported fields.

### Non-goals

Chromium DevTools Protocol compatibility, TLS interception, or a general packet
capture proxy.

## AI-014 — Opt-in sync for agent definitions

**Status:** Proposed

**Depends on:** AI-002, AI-007

### Outcome

Safe reusable configuration can follow the user's existing private CloudKit
sync without syncing execution content or secrets.

### Build

- Define separately toggleable sync for schedule definitions, nonsecret
  provider presets, and optionally user-authored memory entries.
- Use stable IDs, schema versions, conflict handling, tombstones, and capability
  checks per device.
- Keep endpoint credentials, OAuth tokens, Cowork bookmarks, run transcripts,
  steps, frames, artifacts, Page handles, and incognito data local.
- Show when a synced definition is unavailable on a device due to missing
  provider credentials, MCP connection, Cowork scope, or platform support.

### Acceptance criteria

- CloudKit records and logs contain none of the prohibited local-only fields.
- Conflicting edits resolve deterministically without duplicate schedule
  occurrences.
- Disabling sync stops new writes and offers keep-local versus delete-cloud
  behavior consistent with existing sync UX.
- A receiving device never runs a schedule until local dependencies and policy
  are satisfied.
- iPadOS can retain an unsupported definition without attempting macOS-only
  automation.

### Non-goals

Remote execution, transcript continuity across devices, or syncing access to a
Mac's files and signed-in browser state.
