# Newspaper on-device document transforms are not Agent Runs

Status: Accepted

ADR-0004 requires built-in, scheduled, MCP, and delegated agent execution to use the canonical `AgentRun`/`AgentStep`, policy, and metering runtime. Newspaper shortening is a narrow exception: the app may call Apple's on-device Foundation Models API directly when an attended reader action transforms one already captured, bounded **Article Document** into one derived **Rendition**. This exception exists because the operation is a document transform with no delegated authority, while forcing it through the macOS-only agent runtime would make a basic cross-platform reading feature depend on an execution and audit model it does not need.

The exception applies only when all of these constraints hold:

- Input is one versioned Article Document with enforced byte, block, and character ceilings; output is one typed Rendition with an enforced word or character ceiling.
- The model runs on device. It receives no tools, Pages, files, MCP connections, network provider, secrets, durable memory, authority, or ability to cause effects.
- The transform is directly caused by an attended Add/Shorten flow, is cancellable, has bounded chunk count, concurrency, and runtime, and cannot run as a schedule or unattended background agent.
- Page content is hostile observation, including text that resembles instructions. Output is validated locally, the original is always retained, and failure falls back to the original.
- Acceptance is bound to source digest, target, prompt version, and model identity. A late or stale result cannot replace a Rendition for a changed source or request.
- Local state records status, provenance, and a privacy-safe error category. Logs and diagnostics do not contain article text, prompts, or generated prose. Incognito input is denied.

This carve-out does not introduce an “agent session,” rename `BrowserSession`, or weaken ADR-0004 for any other feature. A remote model, tool use, browsing or file effects, multi-step delegated reasoning, scheduled/unattended execution, or access to memory or secrets must use the ADR-0004 Run runtime and its policy and resource accounting, or be authorized by a later ADR.

## Considered options

- **Represent every shortening operation as an AgentRun** — rejected for the first release because the no-tool on-device transform is supported on both app platforms and has no delegated authority, while the canonical execution runtime is intentionally macOS-owned.
- **Allow any direct model call labeled “reading”** — rejected because the label would become an unaudited path around policy, metering, and authority boundaries.
- **Delay shortening until the full agent runtime exists on every platform** — rejected because a bounded local transform can be made safe without granting agent capabilities.

## Consequences

- Unsupported OS versions or hardware show the original Article Document and an availability explanation; they do not silently use a remote provider.
- Prompt or model changes create new provenance and invalidate incompatible cached results rather than mutating the original.
- Newspaper needs dedicated limit, cancellation, stale-result, prompt-injection, incognito, and content-redaction tests even though the transform is not an AgentRun.
- The exception records local transform state, not synthetic provider usage or cost, and cannot be generalized to avoid ADR-0004.
