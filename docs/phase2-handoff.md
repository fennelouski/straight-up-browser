# Thought Flow Phase 2 — Handoff

Phase 2 (the Markdown editor with anchors) is implemented, unit-tested, and on `main`. This document is written for a session with **no memory of the work**: what actually shipped, every deviation from `docs/phase2-design.md`, and where Phase 3+ plugs in.

Read alongside:
- `docs/phase2-design.md` — the approved design. Its §12 lists every implementation deviation; **where §12 disagrees with §1–11, §12 is right.**
- `docs/adr/0008-split-admits-document-panes.md` — the ADR 0001 amendment.
- `docs/phase2-manual-checklist.md` — **NOT yet run.** Phase 2 closed with the automated suite green but before any hands-on pass. That file is the outstanding verification debt.
- `docs/phase1-handoff.md` — everything there still holds.

## The three rules this phase adds

1. **What is on disk is always exactly what the storage holds.** Hybrid rendering is attribute-only; styling never mutates text. The one write the editor makes to your prose is title repair (`"^id"` markers), and only inside the save pass.
2. **A document's anchor links ARE its edge set.** Every save reconciles `LedgerEdge` declaratively from the parsed links — offsets recomputed, absent anchors' edges deleted. `rangeQuote` stays the truth; offsets are the fast path.
3. **A pane is a Tab or a document; `selectedTabId` stays tabs-only.** `focusedDocumentId` marks document focus; selecting any tab clears it. A document id must never land in `selectedTabId` (a test pins this).

---

## 1. What shipped, by file

### New shared files (both targets)

| File | Holds |
|---|---|
| `MarkdownStyling.swift` | pure span computation for hybrid rendering; heading scales; `fadedMarkOpacity`; the `anchorIdAttribute`/`anchorSourceKeyAttribute` custom keys |
| `AnchorResolver.swift` | the three-step resolution order **exactly as phase1-handoff §2 ships it**, plus the save pass (`processForSave`: title repair back-to-front, then edge occurrences) |
| `AnchorComposer.swift` | the creation funnel every surface lands in: capture-if-needed → locator → `createAnchor` → append + clipboard → `recordEdge`. Pure helpers: `textFragmentDirective` (≤150 chars whole, else start,end pair), `linkText` (120-char word-boundary trim), `formatTimestamp` |
| `DocumentStore.swift` | THE owner of document file ops (LedgerStore's sibling): container resolution (`containerOverride:` is the test seam), create/rename/delete/append, `NSMetadataQuery` reconciliation (downloads, stray adoption, missing set), conflict siblings |
| `DocumentEditSession.swift` | one open document, headless: buffer, resolution, debounced save (2s), external-change handling. The round-trip tests drive this directly |
| `WorkspaceDocumentFile.swift` | `NSDocument` (Mac, embedded — no `NSDocumentController`, no windows) / `UIDocument` (iOS) behind one `@MainActor` protocol. Buffers live in `Mutex`es because the SDK's read/write overrides are nonisolated |
| `TranscriptFetcher.swift` | caption-track discovery from the live page's `ytInitialPlayerResponse`, json3 fetch/parse, track choice (manual > ASR > language), `search()` for omnibar rows |

### New platform files

| File | Holds |
|---|---|
| `DocumentPane.swift` (Mac, `#if os(macOS)`) | `DocumentPaneManager` (per-window view registry, WebViewManager's sibling), `DocumentPaneView` (AppKit pane: editor + status line + peek popover), `MarkdownTextView` (NSTextView, TextKit) |
| `DocumentSidebarRows.swift` (Mac) | sidebar document block: select/shift-click-split/rename/delete/new |
| `TranscriptPanel.swift` (cross-platform SwiftUI) | per-video transcript: search, tap-to-seek, select-lines-and-anchor. Mac floats it bottom-trailing; iOS presents it as a sheet |
| `Browser iOS/DocumentPane_iOS.swift` | `DocumentPaneHost_iOS` (full-screen host) + `MarkdownTextView_iOS` (UITextView twin of the Mac styling) |
| `Browser iOS/DocumentSidebarRows_iOS.swift` | sidebar Documents section + rename alert |

Mac-only files carry whole-file `#if os(macOS)` guards instead of pbxproj membership exceptions — zero project-file surgery. New files in `Straight Up Browser/` auto-join both targets via the synced folder.

### Existing files touched

`ResearchLedger.swift` (+`SourceTranscript`, `TranscriptSegment`), `LedgerStore.swift` (+anchor/edge/transcript APIs), `TabManager.swift` (+`focusedDocumentId`, `isDocumentPaneId`, `selectDocument`, `toggleDocumentSplitMembership`, `closeDocumentPane`), `WebView.swift` (WebViewContainer takes a `documentPaneProvider`; context-menu anchor item), `WebViewManager.swift` (`BrowserWKWebView` subclass — iOS edit-menu "Anchor"), `ContentView.swift` / `BrowserView_iOS.swift` (wiring, observers, overlays), `TabSidebar_iOS.swift` (`documentsSection` slot), both omnibars (+`.transcript` suggestion rows), both settings surfaces (+"Anchor links open"), `ShortcutCommand.swift` + `KeyboardShortcutsManager.swift` (three commands), `NotificationNames.swift` (six names), `TabSync.swift` (+`SourceTranscript` under `.research`), `WorkspaceSettleCapture.swift` (video capture → transcript fetch), entitlements + Info.plists (CloudDocuments, `NSUbiquitousContainers`).

---

## 2. Schema

One new synced model, CloudKit rules observed (defaults everywhere, no `.unique`, UUID links):

| Entity | Notes |
|---|---|
| `SourceTranscript` (`ResearchLedger.swift`) | `sourceId`, `sourceKey` (uniqueness by fetch-then-insert; re-fetch replaces), `languageCode`, `isAutoGenerated`, `fetchedAt`, `@Attribute(.externalStorage) segmentsData` = JSON `[TranscriptSegment]` (`s`/`d`/`t` short keys). Synced deliberately — a transcript is extracted text, and extracted text syncs. In `TabSync.cloudBackedModels` under the existing `.research` category; the guard test's expected list grew in the same change |

`WorkspaceDocument` gained **no** columns. No canonicalization change → **no `LedgerMigrator` bump**.

`LedgerAnchor` and `LedgerEdge` finally have writers: `LedgerStore.createAnchor` (dedupes identical locator+quote per source), `reconcileEdges` (declarative, per save), `recordEdge` (targeted, for appends to closed documents — offsets 0 until the next open+save).

## 3. Where things live on disk

```
<ubiquity container>/Documents/<Workspace Name>/<Document Name>.md
```

Folder name freezes at first document creation (the `sectionName` rule); workspace rename never moves it. `NSUbiquitousContainerIsDocumentScopePublic = YES` — the container is user-visible in Files/Finder as "Browser". Conflict losers become ordinary sibling files (`Name (conflict from iPad, Aug 19 15.12).md`), adopted as rows by the stray-file rule. Rows and bytes ride different sync systems (CloudKit vs iCloud Drive); "row exists, file not local yet" is a normal state (`Waiting for iCloud…`), and `DocumentStore.missingDocumentIds` is only for files absent from the cloud entirely.

## 4. Phase 3+ extension points

- **Share-sheet capture (Phase 3)** should add its `SourceCaptureMethod` case and call the same `LedgerStore.upsertReference` path, per phase1-handoff. Nothing in Phase 2 changes that. If the share flow wants "anchor this share", `AnchorComposer.finishAnchor`'s pieces are all public-ish — lift `anchorTranscript`'s shape (article + locator + quote in, note out).
- **Graph/audit (Phase 4)** now has real edges to render: one per (document, anchor), `rangeQuote` + offsets maintained by every save. `LedgerStore.edges(documentId:)` and `anchors(sourceKey:)` are the queries.
- **Claim promotion** — `LedgerEdge.claimId` still nil everywhere; `reconcileEdges` preserves existing edge rows (updates in place), so a claimId set later survives saves.
- **Transcript search index** — `TranscriptFetcher.search` is a linear scan over decoded blobs (ponytail-noted). Phase 5 retrieval wants a real index; build it rebuildable, per the ADR 0007 pattern.
- **iPad document-in-split** — the seam is ready: `WebView_iOS`'s pane container needs the same `documentPaneProvider` treatment `WebViewContainer` got (see `WebView.swift` diff for the pattern), plus a UIKit host for `MarkdownTextView_iOS`.

## 5. Gotchas (beyond phase1-handoff's, which all still hold)

- **`MarkdownTextView` trapped on first display until 2026-08-20.** NSTextView's
  `init(frame:)` convenience dispatches to `init(frame:textContainer:)` on SELF;
  the subclass declared its own `init()` (losing initializer inheritance), so the
  first real render of any document pane hit "unimplemented initializer" and
  crashed the app. Found on the first hands-on run of the checklist — the unit
  suite drives `DocumentEditSession` headlessly and never instantiates the view,
  so no automated gate could see it. Fixed by overriding the designated
  initializer; if you subclass another AppKit view with a convenience-built
  stack, remember this dispatch pattern.

- **`NSDocument` refuses to overwrite an externally-modified file.** `WorkspaceDocumentFile.saveFile` (Mac) adopts the on-disk `fileModificationDate` before saving, because by then the conflict flow has already preserved the disk version as a sibling. Remove that and the dirty-buffer conflict path silently stops winning the path — a test pins it.
- **Never call `getWebView(for:)` with a pane id before checking `documentPaneProvider`.** It creates a web view as a side effect; `WebViewContainer.paneView(for:)` is the safe accessor. Same rule as capture's `existingWebView`.
- **The SDK's document classes are only partially MainActor.** `read/data/contents/load`, `autosavesInPlace`, `init(fileURL:)`, `presentedItemDidChange` are nonisolated; overrides must be too, which is why the text buffer and callbacks live in `Mutex` boxes. Follow the existing pattern when adding methods.
- **`@CommandsBuilder` is at its 10-child cap** (`Straight_Up_BrowserApp.swift`); the three research commands dispatch through the `KeyboardShortcutsManager` monitor and have no Mac menu items. Adding a menu item for them means merging into an existing group.
- **⌥⌘A, ⌥⌘N, ⌥⌘T are all taken** (autofill, Scratch Pad, translation). The shipped chords are ⌥⇧⌘D / ⌃⌘N / ⌃⌘T. Check `ShortcutCommand.swift`'s full binding list before assigning anything new.
- **The transcript panel rides `saveWorkspaceDialogOverlay`** on the Mac — the ContentView type-check budget forbids another body modifier. iOS: one merged `phase2Publisher` for the same reason (`.onReceive` chains overwhelm the checker).
- **`plistlib` destroys plist comments.** The entitlements carry load-bearing comments (Sparkle!); edit them as text, never round-trip through a plist parser.
- **`xcodebuild -exportLocalizations` rewrites `Localizable.xcstrings` wholesale** (it swept in ~676 never-synced keys when tried). The catalog is maintained by the i18n pipeline; don't let build tooling touch it casually.
- **String catalog state:** every Phase 2 string goes through `String(localized:)`/SwiftUI literals but is **not yet in the catalog** — same pending state as several Phase 1 strings ("Captured to %@"). The 40-locale pass is pipeline work, deliberately not hand-faked here.

## 6. Remaining `ponytail:` comments from this phase

| Location | Deferral |
|---|---|
| `MarkdownStyling.swift` (header) | whole-document restyle per edit/caret move; go incremental only if a trace shows it |
| `DocumentEditSession.refreshResolution` | full re-resolve per edit; cache per (url, idPrefix) if a link-heavy document stutters |
| `LedgerStore.anchor(idPrefix:)` | linear scan of the anchor table; add an indexed prefix column if counts ever matter |
| `TranscriptFetcher.search` | linear scan over decoded segment blobs; rebuildable index when Phase 5 needs retrieval |

## 7. Tests

`Straight Up BrowserTests/Phase2Tests.swift` — 26 tests in 7 suites, same serial invocation as Phase 1:

```
xcodebuild test -project "Straight Up Browser.xcodeproj" -scheme "Browser" \
  -destination 'platform=macOS' -only-testing:"Straight Up BrowserTests" \
  -parallel-testing-enabled NO
```

Full serial run at close: **640 tests, 108 suites, all passing.**

### Fixtures worth reusing

- **`makePhase2Stores()`** — in-memory ledger container + a temp-directory `DocumentStore` via `containerOverride:`. The pattern for any document/file test; the sessions and `NSDocument`s it hands out are real and hit the real filesystem.
- The round-trip tests show how to drive `DocumentEditSession` headlessly, including simulating external edits (write the file directly, call `handleExternalChange()`).

### What the suite deliberately pins

Insert→save→external-mangle→reopen resolves by fallback #2 and repairs; unknown links stay byte-identical; deleted ledger degrades to plain; dirty-buffer conflicts keep both versions; clean buffers reload silently; a document id never lands in `selectedTabId`; deleting a document deletes edges and never anchors; refetch replaces transcripts; the guard test knows `SourceTranscript`.

## 8. Not built, deliberately

Whisper/ASR; PDF-page and image-region anchor *creation* (locator formats ready); claim promotion; the share extension (Phase 3); graph/audit (Phase 4); iPad document-in-split (deviation #6 — awaiting the owner's verdict); split-with-document relaunch persistence; omnibar display of the focused document's name; document version-history UI; any AI.

**Known debt:**
- **The manual checklist has not been run** (`docs/phase2-manual-checklist.md`). Everything hands-on — the gesture feel, real iCloud conflict behavior, Files-app visibility, cross-device latency — is unverified.
- ~~`DocumentPaneManager` panes and their sessions live until workspace switch/delete; no LRU~~ — *closed 2026-08-20: `TabManager.workspaceSwitched` now discards panes and closes every edit session when the active workspace changes (both platforms).*
- ~~Closing a tab pane beside a document pane dissolves to a neighbor tab rather than the document~~ — *closed 2026-08-20: `closeTab` restores the document successor's focus after the selection reassignment (pinned in `UndoCloseTests`).*
- ~~The undo-close-tab disposition debt from Phase 1 is untouched~~ — *closed 2026-08-20: see SPEC "Still open" and `UndoCloseTests`.*
