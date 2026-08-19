# Thought Flow — Phase 2 Design

The Markdown editor with anchors. Interview decisions are recorded inline as **[decided]**; anything chosen during design rather than in the interview is marked **[design call]** so it is easy to overrule.

Scope per SPEC.md Phase 2: editing Markdown files in the app's own iCloud Drive container; multiple documents per workspace over the `WorkspaceDocument` table Phase 1 created reference-only; the anchor link syntax from `docs/phase1-handoff.md` §2 rendered enriched in-app, resolved against the ledger in the shipped resolution order, degrading to plain links everywhere else; YouTube transcript ingestion so video anchors are text-searchable with timestamps. Nothing from Phases 3–7. **Whisper is out of scope [decided]** — captions only (§8.1).

## Context

Phase 1 left three loaded guns pointed at this phase:

1. **`WorkspaceDocument` exists with no writers.** `relativePath` is relative to the app's own iCloud Drive container, deliberately not a security-scoped bookmark. Nothing creates a document yet.
2. **A document pane is not a `Tab`,** and Split is defined as an arrangement of 2–4 Tabs (ADR 0001). The handoff demands the side-by-side question be decided explicitly. It is — see §2.
3. **`LedgerAnchor` and `LedgerEdge` have zero writers.** Anchor creation UI is Phase 2's to build, and if Phase 2 does not write edges at insert time, Phase 4's graph reads an empty table.

Findings from reading the codebase that shape this design:

- **The app has no iCloud Documents capability today.** Both entitlements declare CloudKit only. Phase 2 adds `CloudDocuments` to `com.apple.developer.icloud-services` in both entitlement files, plus `NSUbiquitousContainers` in both Info.plists (§4.1).
- **Two sync systems, two latencies.** `WorkspaceDocument` rows ride CloudKit; file bytes ride iCloud Drive. A row can arrive on the iPad before its file has downloaded, or the reverse. "Row exists, file not local yet" is a normal transient state the UI must render calmly, never an error (§4.4).
- **Resolution fallback #2 ("repair the title on next save") means the editor rewrites the user's Markdown.** That write is exactly the one that can collide with an external edit, so the repair pass and file coordination are one design problem (§6.3, §5).
- **The `ContentView`/`BrowserView_iOS` type-check budget** means all new UI lives in new files; observers register inside existing `onAppear` blocks; transient feedback reuses `showTransientNote(_:)`.

### Interview decisions, in one table

| Question | **[decided]** |
|---|---|
| Editor engine | Native TextKit 2, hybrid live rendering (Bear-style) |
| Presentation | Widen Split to admit document panes — deliberate ADR 0001 amendment |
| Document standing | Full peer: sidebar rows, solo display, Split membership |
| iPhone | Document displays full screen where a page would, like a tab view |
| Anchor destination | Append to the workspace's current document **and** copy to clipboard |
| Anchor gestures | Mac keystroke (⌥⌘A) + Mac context menu + iOS edit-menu action |
| File stack | `UIDocument` (iOS) / `NSDocument` (Mac), embedded |
| Conflicts | Auto-resolve: newest wins the path, losers kept as visible sibling files |
| Transcripts | YouTube captions only, no Whisper |
| Transcript storage | New synced entity |
| Transcript search | Both: per-video panel and omnibar cross-transcript rows |
| Pill click | User setting; default = peek popover, click-through opens source beside the doc in a Split |

---

## 1. Amending ADR 0001: Split admits document panes **[decided]**

A **Split** becomes an arrangement of 2–4 **panes**, where a pane is a Tab **or** a Workspace document. This is a deliberate widening, recorded as ADR 0008, superseding ADR 0001's "an arrangement of ordinary tabs" sentence and nothing else. Everything else in ADR 0001 stands: per-window view state, never an entity, never synced.

### 1.1 The pane model

`TabManager.splitTabIds: [UUID]` already stores bare UUIDs and already drops unresolved IDs on restore. **[design call]** It keeps its name and its UserDefaults key (`splitTabIds`) for persistence compatibility, but is documented as *pane IDs*: each element resolves against the tab list first, then against `WorkspaceDocument` rows of the active workspace. UUID collision between the two tables is not a real event. A document UUID that resolves to nothing (document deleted, workspace switched away) is dropped by the existing unresolved-ID rule — switching workspaces dissolves document panes for free, because the resolution set changes.

### 1.2 Focus

`selectedTabId` remains tabs-only; every one of its many call sites keeps meaning what it meant. **[design call]** One new per-window published property:

```swift
@Published var focusedDocumentId: UUID?   // non-nil ⇒ a document owns focus
```

Invariant: when `focusedDocumentId != nil`, the focused pane is that document; selecting any tab (click, ⌘T, tab cycling) sets it back to nil. Chrome that must behave differently for documents checks `focusedDocumentId` first; everything that never learned about documents keeps reading `selectedTabId` and stays correct for tabs.

Per-Split-rule answers, as the interview required:

| Rule | Document answer **[decided unless noted]** |
|---|---|
| Omnibar / ⌘L | Omnibar shows the document's display name, not editable as a URL. ⌘L focuses the editor's find bar **[design call]** — the nearest analogue of "go somewhere". |
| ⌘W | Closes the pane (solo view: returns to the selected tab). **Never writes a disposition** — documents have none. The sidebar row remains; closing is not deleting. |
| Sidebar | Documents get sidebar rows inside the workspace's tab list, styled distinctly (document glyph, no favicon). Sidebar order = pane order holds: doc rows participate in the same `orderIndex` space. **[design call]**: `WorkspaceDocument.orderIndex` maps into the sidebar ordering the same way tab `orderIndex` does. |
| Gathering / dissolve | Identical to tabs: members gather adjacent, selecting a non-member dissolves, shift-click on a doc row adds it as a pane. |
| Memory saver | Documents are exempt trivially — there is no web view to reclaim. |
| Fast Forward | Never involves documents (it only opens from a single-view *search*). No change. |
| Incognito | Documents are workspace-owned; incognito tabs have no workspace. No interaction. |

### 1.3 Solo display

Selecting a document row displays the editor alone in the content area, exactly where a web page would render. The previously selected tab stays selected underneath (`selectedTabId` untouched); its web view stays alive; re-selecting any tab row returns to it.

### 1.4 iPhone **[decided]**

No Split on iPhone (existing `supportsSplitPanes` gate). Selecting a document in the sidebar shows the editor full screen in the content area; the gesture bar and tab switcher return to tabs. The document behaves like "another thing the window can display," which is the same mental model as the Mac minus Split. iPad keeps desktop parity: sidebar rows, solo display, Split membership.

---

## 2. The editor **[decided: native TextKit 2, hybrid live render]**

### 2.1 Architecture

Three layers, platform-split only at the outermost view:

| Layer | File | Role |
|---|---|---|
| Styling core | `MarkdownStyling.swift` (shared target membership, like the Phase 1 core files) | Line-based Markdown parser producing attribute runs + the hybrid-render rules. Pure functions over `(line, caretInLine)` → attributes. No UIKit/AppKit imports beyond `NSAttributedString` types. |
| Text view | `MarkdownTextView.swift` (Mac, `NSTextView` subclass) / `Browser iOS/MarkdownTextView_iOS.swift` (`UITextView` subclass) | TextKit 2 (`NSTextLayoutManager`). Applies styling on edit + caret move, hosts anchor pills, find bar (`usesFindBar` / `findInteraction`), native undo. |
| Pane view | `DocumentPane.swift` / `Browser iOS/DocumentPane_iOS.swift` | SwiftUI wrapper: title area, save state, conflict note, wires the document file object to the text view. |

### 2.2 Hybrid live rendering rules **[design call]**

Bear-style: rendered form everywhere, syntax marks revealed only on the caret's line.

- **Rendered:** headings (sized per level), bold/italic, inline code + fenced code blocks (monospaced, tinted background), lists (marker tinted), blockquotes (bar + indent), plain links (styled text, ⌘-click / tap opens as a normal tab), anchor links (pills, §6).
- **On the caret line:** syntax characters (`#`, `**`, `` ` ``, `[…](… "^…")`) reappear at reduced opacity so editing is character-accurate. Leaving the line re-hides them.
- **Not rendered:** images (syntax shown as-is), tables (monospaced block), HTML. Phase 2 is a writing surface, not a previewer.
- Fonts/colors from system styles; dark mode for free.

Hiding syntax marks uses TextKit 2 rendering attributes (fold/zero-advance presentation), never document mutation — **what is on disk is always exactly what the storage holds.** The round-trip test in Stage 4 pins this: load → edit → save produces byte-identical untouched regions.

### 2.3 Save cadence **[design call]**

Autosave via the document classes (§5): content changes mark the document dirty; `UIDocument` autosaves on its own cadence, the Mac side autosaves on a 2-second debounce after the last keystroke, plus save-on: pane blur, pane close, app background/terminate. The anchor-repair and edge-reconcile passes (§6.3) run inside save, so they ride every one of those triggers.

---

## 3. Documents in the workspace

### 3.1 Creation, naming, lifecycle **[design call]**

- **Create:** "New Document" in the workspace's sidebar context menu and in the File menu (⌥⌘N) when a workspace is active. Creates `WorkspaceDocument` row (fetch-then-insert, per CloudKit rules) + an empty file, names it "Untitled" with collision suffixes, opens it focused with the title selected for rename.
- **Rename:** inline in the sidebar row (Mac double-click / iOS context menu). Renames the file via coordinated move, updates `displayName` + `relativePath`.
- **Delete:** context menu, with confirmation. Coordinated delete of the file, deletes the row, deletes the document's `LedgerEdge` rows. Anchors are *not* deleted — they belong to sources, and other documents may reference them.
- **Current document** (anchor-append target): the workspace's document with the newest `lastOpenedAt`, else its only document, else auto-create "Notes" on first anchor capture. Opening a document stamps `lastOpenedAt`.

### 3.2 On-disk layout **[design call]**

```
<ubiquity container>/Documents/<Workspace Name>/<Document Name>.md
```

Human-readable, because "Nothing is trapped" means legible in the Files app, not just technically portable. Workspace folder name is sanitized (path separators, leading dots) and frozen at first document creation; renaming a workspace later does **not** move the folder (relativePath stays valid; the folder keeps its historical name — same freeze rule as `Workspace.sectionName`). Name collisions get a short numeric suffix.

`NSUbiquitousContainerIsDocumentScopePublic = YES` so the container appears in Files/Finder under iCloud Drive.

---

## 4. iCloud plumbing

### 4.1 Entitlements and Info.plists

- Both `.entitlements`: add `CloudDocuments` to `com.apple.developer.icloud-services` (container identifier already declared).
- Both Info.plists: `NSUbiquitousContainers` → `iCloud.com.nathanfennel.Straight-Up-Browser` → `{ NSUbiquitousContainerIsDocumentScopePublic: YES, NSUbiquitousContainerName: "Browser" }`.

### 4.2 `DocumentStore` (`DocumentStore.swift`, `@MainActor`) **[design call]**

The single owner of document file operations, mirroring `LedgerStore`'s "every write goes through me" role:

- Resolves the container URL once (`FileManager.url(forUbiquityContainerIdentifier:)` off-main, cached). iCloud signed out → documents UI shows a localized "iCloud Drive is unavailable" state; rows still render.
- Create/rename/delete/append, each through `NSFileCoordinator`.
- **Append without opening** (the anchor path): coordinated read-modify-write of the raw file — never through an open editor buffer. If the document *is* open, the append goes through the open document object instead so the buffer and disk agree.
- Runs the `NSMetadataQuery` (§4.4).

### 4.3 The document objects **[decided: UIDocument / NSDocument]**

`WorkspaceDocumentFile.swift`: on iOS a `UIDocument` subclass (string contents, conflict notifications via `UIDocumentStateChanged`). On Mac an `NSDocument` subclass used **embedded**: instantiated directly, never registered with `NSDocumentController`, no window controllers, no Save panels — we use it for coordinated reads/writes, autosave-in-place, change tracking, and `NSFileVersion` conflict detection, and present it inside the pane ourselves. A thin shared protocol (`text`, `isDirty`, `save`, `conflictVersions`, change callbacks) keeps `DocumentPane` platform-agnostic.

### 4.4 External changes and the metadata query **[design call]**

One `NSMetadataQuery` over `*.md` in the container, owned by `DocumentStore`:

- **File changed under a clean open editor** → reload buffer, re-run resolution + pill rendering, repair edge offsets via `rangeQuote`. Silent.
- **File changed under a dirty open editor** → the conflict machinery (§5) decides; never silently drop the user's buffer.
- **File not yet local** (row synced before bytes) → row shows a localized "Waiting for iCloud…" state; `startDownloadingUbiquitousItem` is requested; editor opens read-only-empty until content arrives.
- **Stray `.md` files** dropped into a workspace folder from Files/Finder → adopted: a `WorkspaceDocument` row is created (fetch-then-insert on `relativePath`). Nothing in the folder is invisible to the app.
- **File missing** (moved/deleted externally) → row shows a localized "File missing" state with a Remove action; edges are kept until the row is removed. An external move within the container reads as missing + stray-adopt; the new row does not inherit the old `documentId`'s edges. Accepted Phase 2 limitation, noted here deliberately.

## 5. Conflicts **[decided: newest wins, losers become siblings]**

When `NSFileVersion.unresolvedConflictVersionsOfItem` is non-empty (or `UIDocument` reports `.inConflict`):

1. The current (newest) version keeps the filename.
2. Every losing version is written out as a sibling: `Name (conflict from <device>, <date>).md`, coordinated write, then the `NSFileVersion` is marked resolved and removed.
3. The sibling is adopted as an ordinary `WorkspaceDocument` row (stray-file rule) — openable, comparable by eye, deletable.
4. `showTransientNote` announces it, localized: "Kept both versions of '<name>' — the other copy is beside it."

No modal, never blocks typing, nothing discarded. The dirty-buffer external-change case funnels into the same shape: save the buffer (newest), external version becomes the sibling.

---

## 6. Anchors

### 6.1 Creation flow **[decided]**

Surfaces, all funneling into one `AnchorComposer.swift`:

- **Mac:** ⌥⌘A (registered alongside existing shortcuts; availability against `KeyboardShortcutsManager` verified at implementation) and a context-menu item "Anchor Selection to '<current document>'" / "Anchor Page…".
- **iOS/iPadOS:** an "Anchor" edit-menu action on the web view's text-selection menu (`buildMenu(with:)` on the existing WKWebView subclass). No-selection anchors ride the existing page-actions surface (`MobilePageActions_iOS`) **[design call]**.

Behavior, given the focused tab and its **existing** web view (`WebViewManager.existingWebView(for:)` — capture must never create one):

1. **Ensure the source exists.** Not in the ledger yet (dwell not reached)? Run the deliberate-capture path first (`recordManualCapture`), same as ⇧⌘D. Requires an active workspace; outside one, the gesture shows the existing "Open a workspace…" note. Private tabs: never (existing rule).
2. **Build the locator** by modality:
   - `webPage`: selection text (via JS) → text-fragment directive (`text=` with start/end disambiguation when the selection is long). No selection → whole-source.
   - `video`: current playback time (JS `document.querySelector('video').currentTime`) → `t=<s>`. A selection *in the transcript panel* → `t=start,end` of the covered caption segments, quote = caption text (§8.3).
   - `pdf`: **whole-source only in Phase 2 [design call]** — WKWebView does not expose the visible PDF page. The locator format is ready; the gesture upgrade is deferred and noted in the handoff.
   - `image`: whole-source.
3. **Write `LedgerAnchor`** via a new `LedgerStore.createAnchor(...)` (LedgerStore stays the single write path): `sourceId`, `sourceKey`, `modalityRaw`, `locator`, `quote` = full selection text, `label` empty.
4. **Compose the Markdown** with `AnchorLink.markdown(text:url:anchorId:)`. Link text **[design call]**: the selection trimmed to 120 characters at a word boundary (+…); no selection → the page/video title, with `at m:ss` appended for timestamps.
5. **Append** to the current document (§3.1) as a list item `- <link>\n` via `DocumentStore.append` — and **copy** the bare link Markdown to the clipboard for precise placement later.
6. **Write the `LedgerEdge`** for the appended occurrence: `documentId`, `anchorId`, `rangeQuote` = link text, offsets from the append position.
7. `showTransientNote`: "Anchored to '<document>' — link copied."

A pasted copy of the link becomes an edge at the next save of whatever document it lands in, via reconciliation (§6.3). The same anchor in two documents is two edges, one anchor.

### 6.2 Resolution and rendering

`AnchorResolver.swift` implements the handoff's order *exactly*: id-prefix match → URL+locator match (title repaired on next save) → plain link, never an error. Resolution runs on load, on external reload, and incrementally on edited ranges.

**The pill:** a resolved anchor link renders as an inline chip — modality glyph (¶ / ▶ m:ss / PDF / image), the link text, tinted by the source's disposition in this workspace (open / kept / dismissed-muted). Unresolved-but-parseable anchor links (foreign ledger, deleted ledger) render as ordinary styled links — indistinguishable from links the user typed, exactly as the degradation principle demands. Caret entering the pill's line reveals the raw syntax (§2.2), so the text is always editable.

### 6.3 The save pass **[design call]**

Every save runs, in order, inside the same coordinated write:

1. **Title repair** — links resolved via fallback #2 get their `"^id"` title rewritten in the buffer (resolution order step 2's mandated repair).
2. **Edge reconciliation** — parse all anchor links; for each resolved one, upsert the edge (`rangeQuote` = current link text, fresh `rangeStart`/`rangeLength`); delete edges of this document whose anchor no longer appears. Declarative: the document's links *are* the edge set, `rangeQuote` stays the truth, offsets are the fast path recomputed on every save.

### 6.4 Pill interaction **[decided: user setting]**

New setting (Mac Settings pane + iOS Settings), localized: **"Anchor links open"** → *Peek first* (default) / *Beside the document* / *As a tab*.

- **Peek first:** click/tap shows a popover — anchor quote, source title, disposition, timestamp — with an Open button that performs the *Beside the document* behavior.
- **Beside the document:** reuse an existing tab for the source if the workspace has one, else open one, as a pane in a Split next to the document (the Fast Forward companion-pane pattern), navigated to the anchor's deep-link URL — the text fragment / `t=` / `#page` does the scrolling and seeking with zero of our code. At the 4-pane cap: focus. iPhone: full-screen navigation; back returns to the document.
- **As a tab:** ordinary link behavior, single-view dissolve rules apply.

Hover (Mac) shows the peek content as a tooltip-style popover regardless of setting **[design call]**.

---

## 7. Schema additions

One new synced model, in `ResearchLedger.swift` with the others; CloudKit rules observed (every attribute defaulted/optional, no `.unique`, UUID links only):

```swift
@Model
final class SourceTranscript {          // "Transcript" alone collides with agent vocabulary
    var id: UUID = UUID()
    var sourceId: UUID = UUID()
    var sourceKey: String = ""
    var languageCode: String = ""       // BCP-47 of the caption track
    var isAutoGenerated: Bool = true    // YouTube ASR vs author captions
    var fetchedAt: Date = Date()
    @Attribute(.externalStorage) var segmentsData: Data?   // JSON [ {s, d, t} ] — start, duration, text
}
```

- Joins `TabSync.cloudBackedModels` under the existing `.research` `SyncedDataCategory` (the guard test's expected list is updated in the same change).
- Uniqueness by `sourceKey` via fetch-then-insert; re-fetch replaces `segmentsData`.
- ~100–300KB per hour of video, external storage → CKAsset; comfortably inside limits.
- `WorkspaceDocument` gains **no** columns — `lastOpenedAt` and `orderIndex` already carry §3's needs. No canonicalization change → **no `LedgerMigrator` bump**.

---

## 8. Transcripts **[decided: captions only, synced, panel + omnibar]**

### 8.1 Acquisition — `TranscriptFetcher.swift` **[design call]**

Captions are read the way the player itself gets them, from inside the video's own tab:

1. JS in the tab's existing web view reads `ytInitialPlayerResponse.captions.…captionTracks` (fallback: the same structure off the live player object) → track list with `baseUrl`s.
2. Track choice: manual over auto-generated; the user's language, else the video's default track.
3. `URLSession` fetch of `baseUrl + "&fmt=json3"`, parsed to segments, stored via a new `LedgerStore.storeTranscript(...)`.

Triggers: video source settles or is manually captured (async, off the capture path's critical path); transcript panel opened; timestamp anchor created — first of these to run wins; failures leave no row and the panel offers Retry. Captions disabled → localized "No transcript available." No audio download, no ASR, no third-party endpoint beyond YouTube's own caption URL.

### 8.2 The panel — `TranscriptPanel.swift` / `Browser iOS/TranscriptPanel_iOS.swift`

On a video tab: toggled by ⌥⌘T **[design call]** and a page-actions entry (keyboard-first rule: every surface a key command). Shows the caption segments with timestamps; a search field filters to matching lines; clicking a line seeks the video (JS `currentTime`). Selecting transcript text and invoking the anchor gesture creates a **video anchor**: `t=start,end` covering the selected segments, quote = the caption text — the panel is an anchor-creation surface, which is the point of ingestion.

### 8.3 Omnibar rows — cross-transcript recall

A new suggestion *source* (distinct from Phase 1's single ledgerNote decoration point, which is unchanged): queries ≥ 3 characters match against stored `SourceTranscript` segments (in-memory substring search over fetched blobs, cached; a rebuildable index only if profiling demands — **[design call]**, ponytail ceiling noted in code). At most 2 rows **[design call]**: "…matched caption text… — 6:57 · <Video Title>", opening the watch URL with `t=` set, so the video arrives seeked. Both `OmnibarView` and `Omnibar_iOS`.

---

## 9. Settings, strings, tests

- **Settings:** the pill-click picker (§6.4), in the existing panes both platforms. Transcript fetching gets no toggle — it only runs on captured sources **[design call]**.
- **Localization:** every user-facing string in this design (`Waiting for iCloud…`, `File missing`, `No transcript available`, conflict note, anchor notes, menu items, setting labels) goes through `String(localized:)` into the String Catalog, 40-locale pipeline.
- **Testing (Stage 4 preview):** anchor round-trip through the real editor core (insert → save → external modification → reopen → all three resolution fallbacks); conflict handling producing siblings and losing nothing; save-pass title repair + edge reconciliation (including offsets after external edits, `rangeQuote` recovery); transcript parse + timestamp search; multi-document behavior (current-document selection, append-while-open vs closed, stray-file adoption); split-pane resolution dropping deleted documents. Fixtures reuse `LedgerStoreTests.makeStore()`; sync-routing proof reuses the `LedgerArchiveRoutingTests` two-configuration pattern for `SourceTranscript`.

## 10. Not built, deliberately

Whisper and any ASR; PDF page-level anchor *creation* (format ready, gesture deferred); image-region anchor creation; claim promotion; the share sheet (Phase 3); graph/audit views (Phase 4); anchor edit/relabel UI beyond delete-the-link; document version history UI (iCloud keeps versions; surfacing them is later); Markdown preview/export (the file *is* the export); reassigning documents between workspaces.

## 11. New files

| File | Holds |
|---|---|
| `docs/adr/0008-split-admits-document-panes.md` | the ADR 0001 amendment (§1) |
| `MarkdownStyling.swift` | shared hybrid-render styling core |
| `MarkdownTextView.swift` / `Browser iOS/MarkdownTextView_iOS.swift` | TextKit 2 text views, pills, find |
| `DocumentPane.swift` / `Browser iOS/DocumentPane_iOS.swift` | pane chrome, conflict note |
| `DocumentStore.swift` | container URL, file ops, metadata query, adoption |
| `WorkspaceDocumentFile.swift` | UIDocument/NSDocument subclasses + shared protocol |
| `AnchorComposer.swift` | gesture funnel: capture-if-needed → locator → anchor → append → edge → clipboard |
| `AnchorResolver.swift` | the three-step resolution, pill models, save pass |
| `TranscriptFetcher.swift` | caption track discovery + fetch + parse |
| `TranscriptPanel.swift` / `Browser iOS/TranscriptPanel_iOS.swift` | per-video transcript UI |
| `Straight Up BrowserTests/Phase2Tests.swift` | the §9 suite |

Existing files touched: `ResearchLedger.swift` (+`SourceTranscript`), `LedgerStore.swift` (+`createAnchor`, `storeTranscript`, edge upserts), `TabManager.swift` (pane resolution, `focusedDocumentId`), `TabSync.swift` (+model), sidebar views, omnibar views (+transcript rows), settings panes, entitlements + Info.plists, `ShortcutCommand`/menus.

---

## 12. Implementation deviations (recorded during Stage 3)

Per the build rules: where implementation forced a change, it is recorded here rather than silently drifted.

1. **Keystrokes.** ⌥⌘A, ⌥⌘N and ⌥⌘T were all already bound (autofill, Scratch Pad, translation). Shipped: **⌥⇧⌘D** Anchor Selection (capture ⇧⌘D's precise sibling — a better mnemonic anyway), **⌃⌘N** New Workspace Document, **⌃⌘T** Toggle Video Transcript. All three are rebindable `ShortcutCommand`s and appear in the ⇧⌘H overlay.
2. **No Mac menu items for the three commands.** The `@CommandsBuilder` is at its 10-child cap (documented in `Straight_Up_BrowserApp.swift`); dispatch runs through the `KeyboardShortcutsManager` monitor like other chord-only commands. Discoverability: the shortcut overlay, the page context menu ("Anchor Selection to Document"), and the sidebar's New Document row.
3. **The Mac pane is AppKit end-to-end** (`DocumentPaneView: NSView`), not a SwiftUI wrapper as §2.1 sketched — `WebViewContainer` lays out NSViews, and an `NSHostingView` indirection would only add first-responder seams.
4. **Syntax marks fade to near-invisible (0.28 opacity) instead of hiding.** True hiding reflows layout on every caret move (Typora-style folding); fading is layout-stable and keeps disk bytes == screen bytes. §2.2's "re-hides" reads as "re-fades".
5. **Sidebar: documents are a block above the tab list**, ordered among themselves, rather than interleaved into the tabs' orderIndex space. "Sidebar order = pane order" holds within each kind. Full interleaving would have meant rewriting `BrowserTabOrder` + drag machinery for a cross-entity order space.
6. **iOS displays documents solo (full screen) only; document-in-Split is Mac-only in Phase 2.** The iPad split container (`WebView_iOS`) was not widened. iPad thereby matches iPhone for documents, not the Mac. This is the largest deviation from "full peer" [decided §1.2] — flagged for review. *(Closed 2026-08-20, owner's verdict "build it": `WebViewContainer_iOS` gained the same `documentPaneProvider` resolution `WebViewContainer` has, backed by `DocumentPaneManager_iOS` + `DocumentPaneView_iOS` (the UIKit twin of the Mac pane); document rows gained an Open in Split context action; anchor links honor "Beside the document" on iPad. iPhone stays solo-display. Hands-on iPad verification still pending — checklist.)*
7. **A Split containing a document pane does not survive relaunch** — `restoreSplit` resolves against tabs only, so document ids drop and fewer than 2 survivors collapse to a single view. The document itself is one sidebar click away. *(Closed 2026-08-20: `restoreSplit` now also resolves ids against the active workspace's documents via `isDocumentPaneId`; an all-document split focuses its first pane through `focusedDocumentId`.)*
8. **Pill tap on iOS always navigates full screen** (§6.4 already said iPhone navigates; the peek popover is Mac-only). The iOS Settings picker exists for parity but peek behaves as navigate. "Back returns to the document" is via the sidebar/tab switcher, not hardware back. *(Closed 2026-08-20, owner's verdict: "Peek first" removed from the iOS picker — it promised what iOS never did; a stored legacy "peek" migrates to "split". With #6 built, "Beside the document" is now real on iPad; iPhone still navigates full screen.)*
9. **The omnibar does not yet display the focused document's name**; ⌘L → editor find bar IS implemented. The pane itself and the sidebar selection carry the identity. *(Closed 2026-08-20: the Mac omnibar shows a small document-name header row when `focusedDocumentId` is set.)*
10. **Image-region anchor creation** is out with PDF-page creation (§10 already deferred PDF; images ride along — locator formats ready).
11. **The dirty-buffer conflict sibling** is stamped "(conflict, <time>)" without a device name (NSFileVersion isn't in play on that path; the version-conflict path keeps the device name).
12. **Context-menu item title is generic** ("Anchor Selection to Document"), not named for the current document — the coordinator has no DocumentStore reach, and the transient note names the destination immediately after.
13. **Localization**: every new user-facing string goes through `String(localized:)` / SwiftUI literals and is extraction-ready; the String Catalog sync + 40-locale translation pass runs through the existing i18n pipeline as a follow-up (several Phase 1 strings, e.g. "Captured to %@", are in the same pending state at HEAD). *(Closed 2026-08-20: 129 Phase 1–7 research keys translated into all 36 locales and spliced into the catalog; the BrowserShare extension gained its own catalog.)*
14. **Transcript fetch has no LedgerMigrator involvement** and `SourceTranscript` joined `.research`'s existing sync category — both as designed; noted here because the guard test's expected list changed in the same commit, per the Phase 1 rule.
