# Thought Flow Phase 4 — Handoff

Phase 4 (the graph / audit view) is implemented, unit-tested, and on `main`. Built **without an interview** (same unattended protocol as Phase 3); every decision is a [design call] in `docs/phase4-design.md`. Manual verification pending — the Phase 4 section of `docs/phase2-manual-checklist.md`.

## What it is

SPEC's sentence, implemented literally: **a rendering of the edge table.** One document's blank-line blocks down the left, the workspace's sources down the right, one bezier per edge between them. No graph engine, no persistence, no schema change — the whole phase is read-only over Phase 1/2 tables.

| File | Holds |
|---|---|
| `AuditModel.swift` | pure model: block parsing (UTF-16 ranges), edge→block mapping (offsets fast path, `rangeQuote` truth, quote-search fallback — the Phase 1 rule verbatim), unsupported/unused/upstream computation. Plain value inputs, zero SwiftData |
| `AuditView.swift` | shared SwiftUI: lazy columns + anchor-preference connectors (offscreen rows report no geometry — "filtered to the visible passage" is free), segmented modes, `AuditLoader` (the store-backed assembly, coordinated document read) |
| `Phase4Tests.swift` | 12 tests: parsing, mapping fallbacks, the three modes, lineage chains and cycles |

Entry: **⌃⌘G** (rebindable `auditView` command, dispatched like the Phase 2 trio — no Mac menu item, the builder is still at its cap), the iPad registry, the iOS document-header graph button, and the iPhone workspace switcher. Target = focused document, else the workspace's current document. Mac presents as a large card in the existing overlay group (type-check budget); iOS as a sheet.

## Semantics pinned by tests

Blocks keep exact UTF-16 ranges; valid offsets win, stale offsets fall back to the quote, unfindable quotes map nowhere without error; **unsupported** = prose blocks with no edge (headings never claims); **unused** = cited by no edge in ANY workspace document (workspace-wide on purpose); **shared upstream** groups by `openedFromSourceId` chains — video→blog→press-release collapses to one family, lineage-less sources join none, and cycles (only possible via imported data) collapse to one canonical root rather than splitting the family.

## Gotchas

- Clicking a source card posts `browserOpenAnchor` with no `anchorId` — the Phase 2 handlers only read `url`, so the user's open-behavior setting governs. If a future change makes the handlers require `anchorId`, this breaks quietly; there's a test-free seam here.
- The view is a static snapshot (coordinated read at open). If an editor session has unsaved buffer text, the audit shows the last save — by design, not a bug.
- `AuditView` uses `Color(cgColor:)` for its background; if a theming pass lands later, this is the one hard-coded surface.

## Not built, deliberately

Cross-document graphs; content-based upstream detection (Phase 5+ credibility work — only recorded lineage renders); clickable/editable blocks; claim promotion; export.
