# Thought Flow Phase 1 — Handoff

Phase 1 (research workspaces + the source ledger) is implemented, tested, and on `main`. This document is written for a session with **no memory of the work**. It records what actually shipped, where every deviation from `docs/phase1-design.md` lies, and where Phase 2 plugs in.

Read alongside:
- `docs/phase1-design.md` — the approved design. **Where this document disagrees with it, this document is right.**
- `docs/adr/0007-the-research-ledger.md` — the four decisions a later session is most likely to reverse by accident.
- `CONTEXT.md` — ubiquitous language (Workspace, Source, Disposition, Anchor, Edge…).

## The two rules

Everything else follows from these, and both are counterintuitive:

1. **Capture happens when a page *settles*** — loaded, then dwelt on for 20 seconds — **never when a tab closes.**
2. **Closing a tab *rejects* a source.** It writes a disposition and captures nothing.

Capture-on-close is the design that keeps suggesting itself (the original spec called it "tab demotion"). It is wrong here: closing a tab is how the user throws a source away, so capturing then would preserve exactly the material they rejected. ADR 0007 states this at length.

---

## 1. Schema as actually implemented

All models live in `Straight Up Browser/ResearchLedger.swift` unless noted.

### Synced entities (CloudKit private database)

| Entity | File:line | Notes |
|---|---|---|
| `Workspace` | `ResearchLedger.swift:94` | `id`, `name`, `sectionName` (frozen at create), `colorHex?`, `orderIndex`, `createdAt`, `lastActiveAt`, `isArchived` |
| `WorkspaceSourceRef` | `ResearchLedger.swift:124` | the join; see deviations below |
| `LedgerAnchor` | `ResearchLedger.swift:175` | `sourceId`, `sourceKey`, `modalityRaw`, `locator`, `quote`, `label`, `createdAt` |
| `LedgerClaim` | `ResearchLedger.swift:215` | `text`, `normalizedText`, `createdAt`. **Zero writers in Phase 1** |
| `LedgerEdge` | `ResearchLedger.swift:241` | `documentId`, `anchorId`, `claimId?`, `rangeQuote`, `rangeStart`, `rangeLength` |
| `WorkspaceDocument` | `ResearchLedger.swift:281` | reference only — no file is ever created or read in Phase 1 |
| `NewspaperArticle` | `Newspaper.swift:326` | **is** the Source. Gained `modalityRaw`, `contentHash?`, `firstWorkspaceId?` |
| `Tab` | `Tab.swift` | gained `workspaceId: UUID?` |

### Local-only entity (never synced)

| Entity | File:line | Notes |
|---|---|---|
| `LedgerArchive` | `ResearchLedger.swift:309` | `@Attribute(.externalStorage) webArchiveData`. Lives in a second `ModelConfiguration` named `LocalArchives`, so it gets its own store file |

### Enums

`SourceModality` (`:22`), `SourceCaptureMethod` (`:46`), `SourceDisposition` (`:56`), `TabCloseReason` (`:65`), `WorkspaceCapturePolicy` (`:73`).

### Deviations from `docs/phase1-design.md`

Every one, including trivia:

1. **`SourceCaptureMethod.importBundle`, not `import`.** `import` is a Swift keyword.
2. **`SourceCaptureMethod.rejectedOnClose` exists** and is not in the design. A page rejected inside the 20-second dwell has no ledger row yet, so the close creates one; recording that as `.settle` would claim the page settled when it never did. New refs from `recordRejection` use `.rejectedOnClose`; an existing ref keeps whatever method first created it.
3. **`WorkspaceSourceRef.methodRaw` defaults to `settle`**, not `manual` as the design wrote.
4. **`WorkspaceSourceRef` has an `updatedAt`** the design did not list. The archive sweep and disposition changes stamp it.
5. **Seen-before decorates existing omnibar rows rather than adding ledger rows.** The design said "ledger hits appear alongside history"; the implementation adds `Suggestion.ledgerNote` (`OmnibarView.swift`, `Browser iOS/Omnibar_iOS.swift`) and annotates whichever row you were already going to see. One decoration point means no suggestion source can forget it, and the ledger needs no search path of its own.
6. **The seen-before banner doubles as the capture-feedback surface.** `ContentView.showTransientNote(_:)` reuses `seenBeforeNote`/`seenBeforeToken`. A second transient surface would have cost another modifier on `ContentView.body` — see Gotchas.
7. **`NewspaperStore.enqueue` gained a `section:` parameter** (`Newspaper.swift`) so a research capture is filed under its workspace. First workspace wins; an existing article's section is never rewritten.
8. **`TabManager.discardTabsForWorkspaceLoad` was deleted**, along with its test. Nothing replaces tabs on workspace load any more, so it had no callers.
9. **`TabSync.syncedDataCategories` now de-duplicates.** Six research models share one `.research` category.
10. **`TabSync.localOnlyModelTypes` is new**, and is what keeps `LedgerArchive` out of CloudKit.
11. **`activeWorkspaceId` is stored under one global UserDefaults key**, not per window — matching how `splitTabIds` already behaves, despite both being described as per-window state.
12. **iPhone swipe-down opens the workspace switcher in every state.** An intermediate design had it suspend directly; the shipped behaviour is switch-only, because switching away *is* suspending.
13. **`BrowserGestureBarActions_iOS` is a separate `ViewModifier`** (`Browser iOS/BrowserView_iOS.swift`) purely to keep the gesture bar's expression inside the type-checker's budget.
14. **`LedgerClaim` and `WorkspaceDocument` have no writers.** Deliberate; both exist because Phase 2+ references them.

---

## 2. Anchor link syntax as shipped

`Straight Up Browser/AnchorLink.swift`.

```markdown
[the gut bacteria finding](https://ex.com/a#:~:text=gut%20bacteria "^a1b2c3d4")
```

- **href** — a genuine deep link, composed from the canonical URL plus the locator. Works in any browser with none of our code involved.
- **title** — `^` plus the first **8** hex characters of `LedgerAnchor.id` (`AnchorLink.idPrefixLength`).
- **link text** — the user's own prose. `LedgerAnchor.label` is for the sidebar and graph view, never for the document.

**If the ledger is deleted, the link still works.** A document is never hostage to the database.

### Locator formats (`AnchorLocator`, `AnchorLink.swift:20`)

| Modality | `locator` stored | href built |
|---|---|---|
| `webPage` | `text=…` (a text-fragment directive, no `#:~:`) | `<url>#:~:text=…` |
| `video` | `t=417` or `t=417,432` | `t` as a **query** param, not a fragment |
| `pdf` | `page=12`, optionally `&text=…` | `<url>#page=12` |
| `image` | empty, or `xywh=percent:…` (W3C Media Fragments) | `<url>#xywh=…` |

### Resolution order (implement in Phase 2 exactly this way)

1. Parse `"^…"` from the title, prefix-match `LedgerAnchor.id` → enriched.
2. Miss → match canonical URL + parsed locator against the anchor table → enriched, and repair the title on next save.
3. Miss → render as a plain link. **Never an error, never a broken-looking document.**

`AnchorLink.parseAll(in:)` handles both `[a](url)` and `[a](url "title")`, and returns `idPrefix == nil` for foreign titles.

---

## 3. File map and Phase 2 extension points

### New files

| File | Holds |
|---|---|
| `ResearchLedger.swift` | all seven models plus the vocabulary enums |
| `LedgerStore.swift` | **every ledger write.** `@MainActor` |
| `SourceCanonicalizer.swift` | canonical source identity |
| `AnchorLink.swift` | Markdown anchor syntax, `AnchorLocator` |
| `LedgerMigrator.swift` | idempotent version-gated data migrations |
| `WorkspaceSettleCapture.swift` | the 20-second dwell timer |
| `Straight Up BrowserTests/ResearchLedgerTests.swift` | 32 tests |

### Extension points

- **`WorkspaceDocument`** — Phase 2's editor. `relativePath` is relative to the app's **own iCloud Drive container**, deliberately not a security-scoped bookmark (bookmarks are device-specific and would not survive sync to iPad). Nothing creates a document yet; the picker/creation flow is yours to add.
  **Constraint you inherit:** a document pane is **not** a `Tab`, and `Split` is defined as an arrangement of 2–4 Tabs (ADR 0001). Side-by-side Markdown on iPad needs either a separate pane concept or a deliberate widening of Split. Decide it explicitly.
- **Anchor resolution** — build on `AnchorLink.parseAll` + `LedgerStore.source(sourceKey:)`. Anchor creation UI does not exist; `LedgerAnchor` rows are written by nothing today.
- **Capture pipeline** — `WorkspaceSettleCapture.captureNow(tab:webView:)` is the deliberate path (⇧⌘D) and `pageDidSettleEventually(...)` the automatic one. Both funnel into `LedgerStore.recordSettle` / `recordManualCapture`. Share-sheet import (Phase 3) and bundle import (Phase 7) should add a `SourceCaptureMethod` case and call the same `upsertReference`.
- **`LedgerEdge`** — Phase 4's graph, audit view, and "unsupported claims" are all queries over this one table. `rangeQuote` is the truth; `rangeStart`/`rangeLength` are a fast path that any external edit invalidates.
- **`WorkspaceSourceRef.openedFromSourceId`** — written on link-spawned tabs, read by nothing. A fan of sources sharing an ancestor is the shared-upstream pattern Phase 4 wants.

---

## 4. Canonicalization: where, and how to add a site

`Straight Up Browser/SourceCanonicalizer.swift`. `NewspaperStore.sourceKey(for:)` delegates here, so the reading list and the ledger can never disagree about what page they are looking at.

**To add a per-site rule:** extend `siteSpecific(components:host:)` (`:57`). It runs *before* the generic rules and returns a finished key string, so a site rule bypasses param sorting entirely. Existing rules: YouTube (all six URL shapes → `https://youtube.com/watch?v=ID`), x.com/twitter `/status/`, arXiv `/pdf/` → `/abs/` (**versions preserved** — v1 and v2 are different sources), DOI.

**Generic rules** (`canonicalKey`, `:44`): lowercase scheme+host, strip leading `www.`, drop fragment, drop tracking params (`utm_*`, `fbclid`, `gclid`, `msclkid`, `mc_cid`, `mc_eid`, `igshid`, `si`, `ref`, `ref_src`, `ref_url`, `feature`), sort remaining params, drop empty query, strip trailing slash.

**The rule that matters most:** a video's `?t=` is an **anchor locator**, not a source identity. Dropping it is why `SourceCanonicalizer` exists. `youTubeTimestampSeconds(in:)` recovers it for the anchor path, including `1h2m3s` form.

**If you change canonicalization you must bump the migration.** Add a step to `LedgerMigrator` and raise `currentVersion`; the re-key pass merges rows that newly collapse onto one key. Merge order: has text → higher rating → **earliest `addedAt`** (so the original filing and Section survive). It is irreversible.

---

## 5. Gotchas

- **`ContentView` type-check budget.** `Straight Up Browser/ContentView.swift` — one more modifier on `body` fails the build with *"unable to type-check this expression in reasonable time"* at a **misleading line number**. Register observers in the existing `onAppear` block and render new transient UI inside an existing overlay. This cost a retry: the first build reported the failure at `ContentView.swift:1057`, which was a knock-on from missing-argument errors elsewhere in the same expression — fix the real errors first, then re-read.
- **The same ceiling exists on iOS now.** Adding one accessibility action to the gesture bar blew `BrowserView_iOS.swift:1047`. Fix was extracting `BrowserGestureBarActions_iOS`.
- **CloudKit attribute rules are hard constraints**, not style. Every non-relationship attribute optional or defaulted; **no `@Attribute(.unique)`** (uniqueness is enforced by fetch-then-insert, as `NewspaperStore.enqueue` already did); cross-entity links are `UUID` columns, never SwiftData relationships — matching `Tab.groupId`. A synced model also *cannot* hold a relationship into another `ModelConfiguration`, which is the second reason for UUIDs.
- **Both store files contain every table.** Core Data creates the full managed object model in each store, so you cannot read "the archive is local" off the schema. Routing is decided by which configuration declares the entity. `LedgerArchiveRoutingTests` pins this by building the real two-configuration container and checking where a write lands.
- **`TabSync.cloudBackedModels` has a test that guards it.** Adding a synced model without naming its user-visible `SyncedDataCategory` fails `everyCloudBackedModelHasAVisibleDataCategory` in `Straight_Up_BrowserTests.swift`. That is deliberate; update the expected list in the same change.
- **`closeTab` takes a required `TabCloseReason`.** It has ~15 callers and most are housekeeping. The compiler caught JS `window.close()` (`WebView.swift`, `WebView_iOS.swift`), blank-tab cleanup (`TabManager.swift`), container deletion, and back-closes-auto-opened-child. **Never add a default value** — every one of those would silently become a false `dismissed`.
- **Use `WebViewManager.existingWebView(for:)`, not `getWebView(for:)`**, when capturing. `getWebView` creates a web view on demand; capturing must never bring one into being as a side effect.
- **Closing the last tab inside a workspace suspends** instead of terminating the app. `TabManager.closeTab` calls `terminateApplication()` on an empty tab set outside a workspace; inside one that would both reject every source and quit.
- **The app must be quit gracefully** (`osascript -e 'tell application "Browser" to quit'`). `pkill` corrupts saved state.

---

## 6. Remaining `ponytail:` comments

Two in the new code, plus the pre-existing ones elsewhere in the repo.

| Location | Deferral | Why |
|---|---|---|
| `ResearchLedger.swift:75` — `WorkspaceCapturePolicy.settleDwell` | "tune here, nowhere else" | 20 seconds is a judgement call about when a page stops being glanced at and starts being considered. It wants tuning against real browsing, so it is one constant in one place rather than a setting. |
| `ResearchLedger.swift` — `maximumArchiveBytes` | per-archive cap plus manual clearing in Settings; **no automatic eviction** | Archives are unbounded local growth. A 25 MB per-item cap plus a visible size and a clear action in the Clear Browsing Data dialog is enough while the corpus is small. Add LRU eviction if the local archive store gets uncomfortable. |
| `SourceCanonicalizer.swift:39` — stripping `www.` | drop the rule if a site serves different content at the apex | Near-universally an alias, and the duplicate-source cost of keeping it is constant. This is the one generic rule that can genuinely merge two different pages. |

---

## 7. Tests

`Straight Up BrowserTests/ResearchLedgerTests.swift` — 32 tests in 6 suites.

```
xcodebuild test -project "Straight Up Browser.xcodeproj" -scheme "Browser" \
  -destination 'platform=macOS' -only-testing:"Straight Up BrowserTests" \
  -parallel-testing-enabled NO
```

**Run serially.** Three unrelated agent tests fail on parallel full-suite runs on any commit; `release.sh` runs serial so the release gate never sees it.

### Fixtures worth reusing

- **`LedgerStoreTests.makeStore()`** — in-memory container with all ledger models plus `Tab`, returning `(container, context, LedgerStore)`. The pattern for any ledger test.
- **`LedgerArchiveRoutingTests`** — builds the **real two-configuration container on disk**. Reuse whenever you need to prove something about sync vs local routing; an in-memory store cannot show it.
- **`LedgerMigratorTests.makeDefaults()`** — a throwaway `UserDefaults` suite per test, so version-gated migrations can be run repeatedly. Essential for asserting idempotency.
- **`SourceCanonicalizerTests`** — table-driven input/expected pairs. Add a row here whenever you add a site rule.
- **`WorkspaceMembershipTests.visible(_:workspaceId:)`** — mirrors the production filter in `ContentView.visiblePersistedTabs` and `BrowserView_iOS.visibleTabs`. If you change the filter, change this too or the mirror lies.

### What the suite deliberately pins

Close writes `dismissed` and captures nothing; housekeeping closes write nothing; settle fires once per page and not on revisit; the archive sweep is idempotent and never touches rejections; a page that never settled records `rejectedOnClose`; archives land in the local store; the reconciler leaves `.deferred` alone.

---

## 8. Not built, deliberately

Claim promotion UX, the Markdown editor, anchor creation UI, YouTube transcripts, the share extension, the graph/audit view, bibliography matching, credibility scoring, provenance tracing, any AI, and any external API (OpenAlex, Crossref, Semantic Scholar).

**Known debt beyond the ponytail list:**
- ~~**Undo of an accidental tab close does not un-write the disposition.**~~ *Closed 2026-08-20: the snapshot carries workspace, prior disposition, and an undo-group id; `reopenLastClosedTab` un-writes the `dismissed` (restore-or-delete, never clobbering a newer verdict) and a multi-pane ⌘W undoes as one unit. Pinned by `UndoCloseTests`.*
- ~~**`dismissed` has no UI.**~~ *Closed 2026-08-20 (owner picked the Newspaper-filter proposal): fully-dismissed sources are now actually hidden from the Newspaper (the ADR 0007 feed rule finally has its caller), a Dismissed toggle in the masthead reveals them, and the card context menu restores a rejection per workspace (`LedgerStore.restoreDismissed`).*
- **The workspace UI flow is not covered by a UI test.** Verified by unit tests and by inspecting the real store at runtime, not by driving the menus.
