# Thought Flow — Phase 4 Design

The graph / audit view. **No interview was held** (built unattended, same as Phase 3); every decision is a **[design call]**, annotatable after the fact. SPEC scope: "Document-anchored, not free-floating: text down one side, sources down the other, edges between, filtered to the visible passage. No force-directed hairball. Modes: unsupported claims, unused sources, shared upstream. This is a rendering of the edge table."

## Context

Phase 2 delivered what this phase reads: `LedgerEdge` rows maintained declaratively on every document save (`rangeQuote` truth, offsets fast path), and `WorkspaceSourceRef.openedFromSourceId` has been quietly recording link-spawned lineage since Phase 1 — the fan-to-common-ancestor pattern SPEC's shared-upstream mode renders.

## Decisions

1. **It is a view over one document**, summoned from wherever you are. [design call] The audit target is the focused document, else the workspace's current document (the anchor-append target — same rule). Mac: a large overlay card riding the existing overlay group (the ContentView type-check budget forbids a new body modifier). iOS/iPadOS: a sheet. Toggled by **⌃⌘G** ("g" chords ⌘G/⇧⌘G are taken; ⌃⌘G is free), a rebindable `ShortcutCommand` dispatched like the Phase 2 trio, plus a chart button in the iOS document header and an entry in the iPhone workspace switcher.

2. **Anatomy** [design call]: document text blocks (blank-line paragraphs) down the left, source cards down the right, and bezier connectors drawn between them — one per edge, from the block containing the edge's range to the card for the anchor's source. Both columns are lazy stacks; connectors are drawn from SwiftUI anchor preferences, so **only rows actually on screen report geometry — "filtered to the visible passage" falls out for free**, and there is no graph layout engine anywhere (no hairball by construction).

3. **A static snapshot, not a live editor.** [design call] The view reads the document with a coordinated read at open; it renders read-only. Re-opening refreshes. Live sync with an open editor buffer is not worth its plumbing for an audit surface.

4. **Edge→block mapping trusts offsets, falls back to the quote.** The Phase 1 rule verbatim: if the stored offsets land inside the text and the spanned text still contains `rangeQuote`, use them; otherwise find the quote in the text; otherwise the edge maps to no block — its source card still shows, just without a line. Nothing errors.

5. **The three modes** [design call], as filters/highlights over one layout — never a different layout:
   - **Unsupported claims**: prose blocks (headings excluded) with no edge get the warning tint; sources dim. This is Phase 6's "research plan" read off the page, no AI involved.
   - **Unused sources**: sources whose id appears in **no edge across any of the workspace's documents** get the accent; supported everything else dims. Unused is workspace-wide, not per-document — "captured but never cited" is only meaningful globally.
   - **Shared upstream**: sources are grouped by walking `openedFromSourceId` chains to their root (cycle-guarded); groups of ≥2 get per-group color badges — twelve articles converging on one press release become one colored family. Only lineage recorded at capture time is used; no content analysis.
   - Default mode is **All**: everything shown, nothing dimmed.

6. **Interactions** [design call]: clicking a source card posts the existing `browserOpenAnchor` notification with the source URL — so the user's "Anchor links open" setting governs it (peek's split-open on Mac, full screen on iPhone). Blocks are not clickable in Phase 4.

## Schema

**Nothing.** This phase is deliberately read-only over Phase 1/2 tables — the SPEC sentence "this is a rendering of the edge table" is implemented literally. No new entities, no columns, no migration, no new sync category.

## New files

| File | Holds |
|---|---|
| `Straight Up Browser/AuditModel.swift` | the pure model builder: block parsing with UTF-16 ranges, edge→block mapping with quote fallback, unsupported/unused/upstream computation. Takes plain value inputs — fully testable without SwiftData |
| `Straight Up Browser/AuditView.swift` | shared SwiftUI: columns, connectors (Canvas over anchor preferences), mode picker, the store-backed loader |
| `Straight Up BrowserTests/Phase4Tests.swift` | block parsing, offset-vs-quote mapping, all three mode computations, upstream cycle guard |

Existing files touched: `ShortcutCommand.swift` + `KeyboardShortcutsManager.swift` (⌃⌘G), `NotificationNames.swift` (+1), `ContentView.swift` (state + observer + overlay entry), `BrowserView_iOS.swift` (state + sheet + switcher entry + command case), `Browser iOS/DocumentPane_iOS.swift` (header button).

## Not built, deliberately

Force-directed anything; cross-document graph views (the audit is document-anchored, per SPEC); claim promotion (its own open question); content-based upstream detection (that's Phase 5+ credibility work — this phase renders only recorded lineage); editing from the audit view; PDF/graph export.
