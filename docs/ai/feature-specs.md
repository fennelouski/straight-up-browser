# Browser 2.0 AI tooling feature specifications

These are durable product and implementation contracts, ordered by the roadmap.
Every slice is complete for the Browser 2.0 macOS release. Each slice preserves the
BrowserOS-compatible MCP surface unless its acceptance criteria explicitly
define a versioned change. All slices inherit
the invariants in [Architecture](architecture.md),
[Security and privacy](security-and-privacy.md), and
[Testing strategy](testing.md).

All user-facing controls live in the first-class Agent settings pane. Sections
group Model Provider, Cowork Files, Automation & Records, Safety & Run Budgets,
Delegated Runs, Scoped Memory, Observability & Page Signals, and Agent
Definition Sync. Management buttons open the existing scheduled-task, trusted
integration, and timeline/replay windows; decorative settings keys are not
permitted.

## AI-001 — Canonical tool catalogue

**Status:** Complete

**Depends on:** None

### Outcome

One Foundation-only catalogue defines browser, Cowork, and internal tool
metadata. The built-in agent and MCP server render provider/protocol schemas
from it instead of hand-maintaining overlapping arrays.

### Prior limitation

`BrowserAgent` and `browserMCPTools` independently declared names,
descriptions, required fields, and JSON types. The built-in agent intentionally
exposed a subset plus `wait_for_page` and Cowork tools, so shared tools could
drift silently.

### Implemented design

- `AgentToolDescriptor` carries typed JSON Schema, origin, risk, required
  capabilities, route, output schema, version, and visibility profiles.
- The Foundation-only catalogue compiles in Browser and `browser-cli` without
  SwiftUI, AppKit, or WebKit imports.
- OpenAI-style function definitions and MCP `tools/list` are rendered from the
  same descriptors; the BrowserOS visibility profile is fixed at 53 tools.
- Dispatch remains separate: a descriptor never executes its tool.
- Compatibility aliases and schema deprecation metadata do not expose duplicate
  model-visible names in one profile.

### Acceptance criteria

- MCP still exposes the documented 53 names and compatible required arguments.
- Every overlapping built-in/MCP tool comes from the same descriptor.
- `wait_for` (including the `wait_for_page` alias), Cowork, delegation, memory,
  and signal tools use explicit visibility profiles.
- Catalogue validation rejects duplicate names, unresolved aliases, missing
  risk/capability metadata, and unsupported schema constructs.
- Snapshot tests cover both renderers and the exact 53-tool compatibility view.

### Non-goals

Renaming tools, consolidating the 53 compatibility tools, or changing execution
behavior.

## AI-002 — Durable conversations, runs, and steps

**Status:** Complete

**Depends on:** AI-001

### Outcome

Every attended, scheduled, and externally initiated AI execution has a durable,
queryable lifecycle and can be diagnosed or recovered after relaunch.

### Prior limitation

The panel writes message arrays to a newly generated conversation file but does
not index or reopen them. Scheduled tasks retain 15 summary strings. MCP audit
uses a separate JSONL format. Success is partly inferred from message roles.

### Implemented design

- Versioned `AgentConversation`, `AgentRun`, `AgentStep`, `AgentArtifact`, and
  `AgentRunStore` types implement the architecture's storage layout.
- Explicit state transitions and monotonic Step sequence numbers distinguish
  success, failure, cancellation, limits, and interruption.
- Each Run snapshots model/provider/tool/policy configuration.
- Launch recovery marks nonterminal Runs `interrupted` and requires an explicit
  recovery decision.
- Indexes cover conversation, task definition, date, status, provider, and
  parent Run without reading Step bodies.
- Validated, idempotent import handles legacy panel conversation JSON,
  scheduler summaries, and MCP audit JSONL with owner-only migration receipts.

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

**Status:** Complete

**Depends on:** AI-001, AI-002

### Outcome

All tool entry points use one enforceable policy decision, and users approve
the concrete effect of risky actions rather than relying on a system prompt.

### Prior limitation

CLI/MCP has global capability switches and the agent prompt warns against
consequential actions, but the built-in run loop has no typed per-invocation
approval gate. Dynamic MCP effects are not classified locally.

### Implemented design

- Typed capabilities, risk classes, `AgentInvocationContext`, policy rules,
  approval requests, decisions, scopes, expiry, and invocation digests.
- Targets resolve to a Page/origin/browser Session, canonical Cowork path, or
  MCP identity before policy evaluation.
- Attended Runs use a nonmodal approval queue; schedules use notification-based
  `waitingForHuman` behavior.
- Built-in agent, scheduler, MCP, and CLI execution pass through the same policy
  service while preserving existing static Security switches.
- Decisions are recorded before effects; denial and expiry are structured results.

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

**Status:** Complete

**Depends on:** AI-002

### Outcome

Provider APIs are isolated behind one normalized streaming contract. The panel
shows incremental text/tool progress, cancellation is prompt, and usage/cost
can be budgeted.

### Prior limitation

The current loop posts one OpenAI Chat Completions-shaped request and waits for
the complete JSON response. Provider identity mostly changes endpoint/defaults,
and usage is not persisted.

### Implemented design

- Normalized request/content parts, model events, finish reasons, usage,
  provider capabilities, and retry classification.
- Parsers/builders cover OpenAI-compatible Chat Completions, OpenAI Responses,
  Anthropic Messages, and Gemini generateContent behind one adapter protocol.
- Streaming text and incremental tool calls support cancellation, bounded retry
  before side effects, and provider-reported usage.
- API keys stay in Keychain and adapter errors are redacted.
- Each task/Run snapshots its provider, model, endpoint identity,
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

**Status:** Complete

**Depends on:** AI-001

### Outcome

Web agents can act reliably on dynamic pages without arbitrary sleeps or stale
selectors, using semantics WebKit can safely expose.

### Prior limitation

Snapshot IDs are injected into the current DOM and the native agent has a load
wait. Modern pages may replace nodes, use shadow roots or frames, and complete
useful state changes after the main load event.

### Implemented design

- Element references contain PageHandle, navigation/document
  generation, local ID, role/name/state, frame context, and geometry digest.
- References resolve immediately before action and reject stale, substituted,
  or ambiguous matches.
- `wait_for` covers load state, URL, selector, text, element state,
  dialog, download start/completion, and Page close.
- Bounded `MutationObserver` bridges and WebKit navigation/download delegates
  clean up on cancellation.
- Open shadow roots are traversed. Inaccessible cross-origin frames are
  explicit boundaries rather than pretend DOM access.

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

**Status:** Complete

**Depends on:** AI-002, AI-003

### Outcome

One timeline explains attended, scheduled, MCP, and child Runs,
including what was proposed, approved, executed, changed, and retained.

### Prior limitation

Replay reads MCP-specific JSONL and post-action frames. Built-in conversations
and schedule summaries are separate and omit policy/model lifecycle events.

### Implemented design

- Model, tool, approval, handoff, state, artifact, usage, limit, and error Steps
  render from `AgentRunStore`.
- Policy-controlled frames before and/or after visual mutations carry
  PageHandle, URL origin, viewport, and Step references.
- Redaction states, missing-artifact handling, retention, deletion, and
  redacted diagnostic export share the Run store.
- Argument/result summaries do not eagerly load content artifacts.
- Step filters, autoplay, keyboard controls, and accessible descriptions are
  shared across entry points.

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

**Status:** Complete

**Depends on:** AI-002, AI-003, AI-004

### Outcome

Scheduled agent work has explicit execution configuration, downtime behavior,
budgets, concurrency, and human-handoff semantics.

### Prior limitation

The in-process 30-second timer uses the current global provider/model and needs
an available browser window. A missed run waits until a future schedule, task
definitions cannot be edited comprehensively, and only summary output is kept.

### Implemented design

- Task definitions capture provider/model, Page/browser Session
  scope, MCP connections, Cowork access, budgets, timeout, concurrency policy,
  retention, and catch-up policy (`skip`, `runLatest`, or bounded `runAll`).
- Create/edit/duplicate/delete UI validates schedules across time
  zone and daylight-saving changes.
- Launch recovery plans due work and creates full `AgentRun` records.
- Occurrences serialize, skip, or queue according to the definition and use
  stable occurrence IDs to prevent duplicates.
- Notifications cover waiting-for-human, failure, repeated failure, and
  configured success conditions.

### Acceptance criteria

- A task runs with its saved configuration even after global settings change.
- Relaunch tests cover every catch-up and overlap policy with stable occurrence
  IDs and no duplicates.
- No-window execution records a clear blocked outcome. With an available browser
  manager, scheduled work uses hidden Pages without changing focus.
- An approval need pauses/notifies without displaying an unattended modal.
- Disabling or deleting a task prevents future occurrences but preserves run
  history until separately deleted.
- Time-zone/DST, cancellation, budget, and repeated-failure tests pass.

### Non-goals

Promising execution while the Mac is shut down. OS background launch/wake
support, if added, requires a separate entitlement and energy-impact decision.

## AI-008 — MCP trust and OAuth lifecycle

**Status:** Complete

**Depends on:** AI-003, AI-006

### Outcome

Users can connect standards-compliant remote MCP servers, understand their
identity and scopes, and revoke or reauthorize them without opaque credentials.

### Prior limitation

Connections accept a Streamable HTTP endpoint and optional bearer token.
OAuth-only services require a separately operated local remote bridge, and
server/schema changes are not a first-class trust version.

### Implemented design

- Standards discovery and OAuth authorization code flow require S256 PKCE, use
  `ASWebAuthenticationSession`, and store tokens in device-only Keychain.
- A one-shot `NWListener` binds to `127.0.0.1` on an OS-assigned ephemeral port;
  it validates the exact callback path, Host/port, state, size, and timeout. The
  sandbox's network-server entitlement is limited to this native callback.
- Connections track normalized endpoint, server identity,
  protocol/capabilities, tool-schema digest, auth scopes, last test, and trust
  version.
- Reconnect, single-flight refresh, immediate revoke, and reauthorize flows have
  visible state and failure UI.
- HTTPS is required except loopback. Response size/depth limits, timeouts, and
  collision-safe names constrain dynamic tools.
- Connection/tool identity and egress details flow into policy and replay.
- Mutation retries use a logical-invocation idempotency key derived from the
  permit digest plus persisted invocation Step ID: one 401 refresh reuses it,
  while a later deliberate same-argument invocation receives another key.

### Acceptance criteria

- No OAuth token or authorization code appears in settings files, logs, runs,
  exports, or model context.
- Endpoint/server/schema/scope changes invalidate earlier grants.
- Revocation removes Keychain material and prevents calls immediately.
- Concurrent calls use the correct MCP connection/session negotiation and
  recover from an expired access token once without duplicating mutations.
- A retry of one persisted mutation carries the same header and MCP `_meta`
  idempotency key; a later invocation with identical arguments has a new key.
- The real callback listener accepts only its exact ephemeral `127.0.0.1`
  redirect and matching OAuth state, then shuts down after one outcome.
- Loopback fixtures cover OAuth success, denial, refresh, revocation, schema
  change, collision, protocol mismatch, oversized data, and timeout.

### Non-goals

Shipping vendor-specific connector proxies, dynamic client registration, or
storing a service's website cookies as an integration credential. OAuth requires
a pre-registered public native client ID.

## AI-009 — Cowork artifact transactions

**Status:** Complete

**Depends on:** AI-003, AI-006

### Outcome

Agents can create and update useful local artifacts with preview, recovery, and
a precise record of what changed.

### Prior limitation

Cowork supports scoped UTF-8 list/read/write/move/Trash operations with size and
containment checks, but writes are immediately applied and run history does not
show a diff or artifact manifest.

### Implemented design

- A per-Run artifact workspace and transaction API stages create, replace,
  append, move, and recoverable delete.
- Text diffs and metadata previews precede explicit approval and commit for
  risky changes.
- Atomic replacement retains a bounded prior version for rollback.
- Typed artifact results carry content type, byte count, digest, source Steps,
  final relative path, and commit status.
- Containment is revalidated at effect time across traversal, symlink, alias,
  volume, and hard-link policy boundaries, with byte/count bounds.
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

**Status:** Complete

**Depends on:** AI-002, AI-003, AI-005

### Outcome

One parent run can delegate bounded independent work to child runs without Page
races, focus theft, unbounded fan-out, or fragmented audit.

### Implemented design

- `AgentRunGroup` combines child-run contracts, Page read/write leases, shared
  budgets, maximum depth/fan-out, cancellation propagation, and result handoff.
- A child contract requires an objective, allowed tools, allowed
  Pages/origins/browser Sessions, and return schema.
- Child-created Pages are hidden and never steal focus. Mutating an existing
  user Tab requires an explicit lease and applicable approval.
- The parent and children share one atomic meter; a child receives only a
  subset of authority and a smaller budget.
- The tree/timeline carries per-child status, cleanup ownership, and structured
  handoff. Cancellation closes child-owned Pages but not user-owned Pages.

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

**Status:** Complete

**Depends on:** AI-002, AI-003

### Outcome

Agents can reuse durable facts and preferences without treating browsing
history or old transcripts as invisible global memory.

### Implemented design

- Memory entries carry source/provenance, scope (`global`, origin, task, or
  conversation), sensitivity, created/last-used time, expiry, and user-edited
  text, plus an explicit normal/container/all-persistent browser-Session scope.
- Writes are explicit model proposals evaluated by policy; sensitive inferred
  facts require approval.
- Deterministic retrieval applies exact scope, expiry, entry, and token bounds
  and records the Run and Step that consumed each entry.
- Review, search, edit, disable, export, exact “forget this,” and delete are
  available independently of agent execution.
- Memory storage remains separate from browsing history, bookmarks, and provider
  context caches.

### Acceptance criteria

- Memory never crosses origin/task/browser-Session scope unexpectedly.
- The user can see why an entry exists and every run that consumed it.
- Deleting history, a conversation, or memory follows explicit independent
  rules; UI explains the difference.
- Incognito runs neither read nor write durable memory by default.
- Prompt injection cannot silently create a persistent instruction.
- Retrieval tests are deterministic and enforce token/entry limits.
- Forgetting an inaccessible ID does not reveal whether another scope or
  browser Session contains it.

### Non-goals

Training a model on browser history, hidden behavioral profiling, or storing
authentication data.

## AI-012 — Budgets, observability, and diagnostics

**Status:** Complete

**Depends on:** AI-002, AI-004, AI-006

### Outcome

Users and maintainers can understand latency, failure, token use, cost when
known, and resource consumption without sending telemetry by default.

### Implemented design

- Per-Run and per-task hard limits cover turns, tool calls, elapsed time,
  provider tokens/known cost, open Pages, model-result bytes, download
  count/bytes, and artifact count/bytes.
- A shared meter admits work before effects and records an explicit limit Step
  before terminal cancellation. Child Runs atomically consume the root ledger.
- Local metrics cover provider latency, time-to-first-token, tool latency,
  retries, approvals, failure categories, and resource peaks.
- Run summaries and an aggregate local dashboard preserve unknown usage/cost.
- A previewable redacted diagnostic bundle contains versions,
  configuration shape, timeline metadata, metrics, and selected errors.
- Remote diagnostics are off and no upload transport is implemented.

### Acceptance criteria

- Hard limits stop the next operation and produce an explicit limit step.
- Child runs consume shared parent budgets atomically.
- Non-idempotent tools are never repeated to improve a latency metric or after
  an ambiguous timeout.
- Cost is shown only from provider usage plus user/provider pricing metadata;
  estimates are labeled.
- Pricing metadata is bound to the provider/model used for that usage event;
  stale global pricing is not applied retroactively, and unknown remains unknown.
- Default diagnostic fixtures contain no prompts, page/file/MCP bodies, full
  URLs, screenshots, secrets, or authorization headers.

## AI-013 — WebKit-native diagnostic signals

**Status:** Complete

**Depends on:** AI-001, AI-005

### Outcome

Agents can reason about console errors, downloads, navigation responses, and a
bounded set of request outcomes using supported WebKit hooks.

### Implemented design

- An isolated, opt-in script bridge captures page console messages with
  source, level, timestamp, and size limits.
- WebKit delegates expose navigation response/status, visible redirects, TLS
  state, failed resource signals WebKit actually surfaces, and download lifecycle.
- `observe_webkit_signals` and `wait_for_webkit_signal` have explicit capability
  and retention metadata and use bounded Page/Run buffers.
- Unavailable details are unsupported; the runtime never fabricates CDP request
  IDs, timing waterfalls, cache internals, or response bodies.

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

**Status:** Complete

**Depends on:** AI-002, AI-007

### Outcome

Safe reusable configuration can follow the user's existing private CloudKit
sync without syncing execution content or secrets.

### Implemented design

- Schedule definitions, nonsecret provider presets, and user-authored memory
  each have a separate off-by-default setting on macOS and iPadOS. Turning one
  off offers keep-local, delete-cloud, or cancel; cloud deletion publishes
  tombstones while retaining usable local-only payloads for a later re-enable.
- Stable IDs, schema versions, monotonic revisions, deterministic conflict
  handling, tombstones, and device capability checks prevent resurrection.
- Endpoint credentials, OAuth tokens, Cowork bookmarks, Run transcripts, Steps,
  frames, artifacts, Page handles, and incognito data remain local.
- Remote tombstones and disabled schedules uninstall runnable occurrences while
  preserving Run history. Revoking local authorization uninstalls immediately;
  reauthorization can reinstall the same definition revision.
- The UI shows missing provider credentials, MCP connection, Cowork scope,
  browser Session, capability/policy authorization, or platform support.
- Synced sensitive memory waits for local review. iPadOS retains unsupported
  definitions and never attempts macOS-only automation.

### Acceptance criteria

- CloudKit records and logs contain none of the prohibited local-only fields.
- Conflicting edits resolve deterministically without duplicate schedule
  occurrences.
- Disabling sync stops new writes and offers keep-local versus delete-cloud
  behavior consistent with existing sync UX.
- Delete-cloud publishes a monotonic tombstone without destroying the retained
  local payload needed for an intentional later re-enable.
- A receiving device never runs a schedule until local dependencies and policy
  are satisfied.
- Tombstones, disabled definitions, and local authorization revocation uninstall
  runnable schedules without deleting their Run history.
- iPadOS can retain an unsupported definition without attempting macOS-only
  automation.

### Non-goals

Remote execution, transcript continuity across devices, or syncing access to a
Mac's files and signed-in browser state.
