# Split admits document panes

A **Split** is an arrangement of 2–4 **panes**, where a pane is an ordinary **Tab** or a **Workspace document**. This deliberately widens ADR 0001's definition ("an arrangement of ordinary tabs, not an entity") in exactly one dimension: what a pane may display. Everything else in ADR 0001 stands unchanged — a Split is per-window view state, never a SwiftData entity, never synced.

## Context

Phase 2 (docs/phase2-design.md) needs a Markdown document displayed beside the page it cites — the read-beside-write moment the anchor system exists for. The Phase 1 handoff required this decision be made explicitly rather than drifted into: a document pane is not a Tab, so either a second pane system exists beside Split, or Split widens.

## Decision

Split widens. **[decided]** in the Phase 2 interview, over an overlay drawer, a separate window, and a parallel pane concept.

- `TabManager.splitTabIds` keeps its name and UserDefaults key but holds *pane ids*: each element resolves against the visible tab list first, then against the active workspace's `WorkspaceDocument` rows. Unresolved ids are dropped by the existing restore rule — which also means switching workspaces dissolves document panes for free, because the resolution set changes.
- Focus: `selectedTabId` remains tabs-only, preserving the meaning of its many call sites. A new `focusedDocumentId` on TabManager marks a document owning focus; selecting any tab clears it. Exactly one pane is focused, as before.
- Per-rule answers: ⌘W on a focused document closes its pane and **never writes a disposition** (documents have none); the omnibar shows the document's name; memory saver has nothing to reclaim from a document; Fast Forward, incognito, and TabGroups never involve documents.
- Documents get sidebar rows within their workspace, can display alone (selecting a document shows the editor where a page would render), and join Splits like any member.

## Consequences

- `WebViewContainer` (macOS) resolves each pane id to a view: the tab's `WKWebView`, or an AppKit document editor view supplied by a provider. It must never call `getWebView(for:)` with a document id — that would create an orphan web view as a side effect.
- iPhone has no Split; a selected document simply displays full screen where a page would. iPad keeps desktop parity.
- Split member gathering (sidebar reorder) applies to tab members only; document rows are listed in their own block within the workspace's sidebar section, so "sidebar order = pane order" holds within each kind rather than across an interleaved list.
- Anything iterating `splitTabIds` and assuming every id is a tab must now tolerate ids that resolve to no tab. The existing "drop unresolved" behavior already gave every such site that tolerance.
