# Thought Flow — Phase 1 Design

Workspace persistence + ledger schema. Approved interview decisions are recorded inline as **[decided]**; anything chosen during design rather than in the interview is marked **[design call]** so it is easy to overrule.

## Context

The spec asks for research workspaces inside Straight Up Browser: a named project that owns its tabs, its documents, and references into a global source ledger. Phase 1 builds the foundation every later phase reads from — workspace persistence, the ledger schema, capture, and seen-before surfacing. The schema has to be right now because Phases 2–7 are all renderings and extensions of it.

**One deliberate departure from the spec.** The spec's Phase 1 describes *tab demotion*: "closing a tab in a workspace demotes it to a ledger entry." That is inverted here. In this workflow closing a tab means **rejecting** a source, so capture moves to the front of the tab's life (capture at settle) and close becomes a disposition write. §3 covers this in full; ADR 0007 records why, because capture-on-close is the design a future session will naturally want to reintroduce.

The largest finding from reading the codebase: **most of this already exists under different names.** `NewspaperArticle` is already a source (canonical key, extracted reader text, digest, byline, publication, rating). `SavedWorkspace` is already a tab snapshot. The persistence stack is already SwiftData + CloudKit. Phase 1 is mostly wiring, one join table, and one canonicalization fix.

### What "SQLite schema" means here

The spec says "SQLite for the ledger." This repo has no raw SQLite — no `sqlite3_`, no GRDB. Everything durable is SwiftData, which *is* SQLite, with CloudKit sync already wired (`TabSync.swift`, `ModelContainerStartup.swift`).

**[decided]** The ledger is SwiftData models. Building a second, hand-rolled SQLite store would mean writing CloudKit sync from scratch for it. The schema below is therefore given as `@Model` definitions plus a table-shaped summary; there is no hand-written DDL because SwiftData generates it.

The cost, stated plainly: no SQL joins, no recursive CTEs for Phase 6 provenance chains, no FTS5 for Phase 5 retrieval. Those phases get fetch descriptors plus in-memory work, or a rebuildable local FTS index added then. Nothing in Phase 1 needs SQL.

### Constraints CloudKit imposes on every model below

These are not style preferences — violating them breaks the store at launch:

- Every non-relationship attribute is **optional or has a default value** (already the documented rule at `Tab.swift:125`).
- **No `@Attribute(.unique)`.** `sourceKey` uniqueness is enforced in code by fetch-then-insert, exactly as `NewspaperStore.enqueue` (`Newspaper.swift:528`) already does.
- Cross-entity links are **`UUID` columns, not SwiftData relationships**, matching the existing codebase (`Tab.groupId: UUID?`). This also lets a synced model reference a local-only one, which a real relationship cannot do.

### Scope decisions

- **Single user.** No sharing between people in Phase 1; shared research spaces are a future feature. No `person` table, no per-person ratings, no CKShare, no merge topology. Sync is the existing private CloudKit database on one Apple ID.
- **Ratings stay single-valued** — `NewspaperArticle.rating`, last writer wins. **[decided]**
- **No credibility, provenance, or peer-validation columns.** Those are Phases 5–7 and the spec's data model does not require them yet.

---

## 1. Schema

### 1.1 `NewspaperArticle` — the Source **[decided]**

A Source *is* a Saved Article. One entity, no duplication of extracted text, no second rating that can disagree. Everything it already has (`Newspaper.swift:326`) is reused: `sourceKey`, `url`, `title`, `byline`, `publication`, `originalPayloadData`, `sourceDigest`, `rating`, `addedAt`.

Three additions:

| Column | Type | Notes |
|---|---|---|
| `modalityRaw` | `String` = `"webPage"` | `webPage` \| `video` \| `pdf` \| `image` \| `importedFile`. Derived from URL at enqueue; user-correctable. |
| `contentHash` | `String?` | For file-backed sources with no meaningful URL. `sourceKey` becomes `hash:<sha256>` in that case. |
| `firstWorkspaceId` | `UUID?` | The workspace that first captured it — the one that owns its `section`. |

And one new `NewspaperCaptureState` case:

| Case | Meaning |
|---|---|
| `deferred` | Recorded in the ledger, text not captured. Written when a workspace tab settles but full extraction was not cheap at that moment. `reconcileInterruptedWork` must skip this state (it currently only touches `.capturing`). |

Unknown raw values already fall back safely, so adding the case is backward-compatible with existing rows.

**Feed visibility** **[decided]**: research captures *do* appear in the Newspaper, filed under `section = <workspace name>`. No hidden flag. The Newspaper becomes the research reader.

The one filter it does need: sources whose workspace references are **all** `dismissed` are excluded, so pages rejected inside the 20-second settle dwell (§3) — which is most rejections — do not litter the reading list. A source dismissed in one workspace and `open` in another still appears.

**Cross-workspace filing** **[decided]**: first workspace wins. A source settled later in a second workspace gains a second `WorkspaceSourceRef` but its `section` never changes. `firstWorkspaceId` records the winner so this is inspectable rather than implicit.

### 1.2 `Workspace` (new, synced)

```swift
@Model final class Workspace {
    var id: UUID = UUID()
    var name: String = ""
    var sectionName: String = ""      // frozen at create; renaming the workspace never re-files sources
    var colorHex: String?
    var orderIndex: Int = 0
    var createdAt: Date = Date()
    var lastActiveAt: Date = Date()
    var isArchived: Bool = false
}
```

`sectionName` is frozen deliberately: renaming a workspace must not silently re-file every article already in the Newspaper under the old Section.

There is no `isSuspended` column. Suspension is per-window view state (§3), not a property of the workspace — the same workspace can be open in one window and not another, exactly as `Split` is per-window (ADR 0001).

`isArchived` **[decided]** is the completion state, and it has exactly one job: setting it runs the disposition sweep (§3, "Archive is completion"), moving every remaining `open` source reference in that workspace to `kept`. Archiving is the only writer of `kept`.

### 1.3 `Tab` — one added column

```swift
var workspaceId: UUID?   // nil = normal browsing, outside any workspace
```

Optional, so existing rows and CloudKit are both satisfied with no migration.

### 1.4 `WorkspaceSourceRef` (new, synced) — the join

```swift
@Model final class WorkspaceSourceRef {
    var id: UUID = UUID()
    var workspaceId: UUID = UUID()
    var sourceId: UUID = UUID()          // NewspaperArticle.id
    var sourceKey: String = ""           // denormalized: answers "seen before?" in one fetch
    var addedAt: Date = Date()
    var methodRaw: String = "settle"     // settle | manual | shareSheet | import
    var dispositionRaw: String = "open"  // open | dismissed | kept
    var openedFromSourceId: UUID?        // provenance lineage; Phase 1 records only
    var note: String = ""                // workspace-local note
    var updatedAt: Date = Date()
}
```

`sourceKey` is denormalized on purpose: seen-before surfacing fires on every navigation and must be a single indexed fetch, not a join walk.

#### `dispositionRaw` **[decided]**

Universal semantics. **No per-workspace setting, no per-user setting, no preference.** The whole point is that the three values mean the same thing everywhere.

| Value | Meaning | Written by |
|---|---|---|
| `open` | Still in the working set — a tab exists for it, whether or not the workspace is currently active | Settle-capture (§3) |
| `dismissed` | Rejected. The user looked at it and closed the tab | User-initiated tab close, and nothing else |
| `kept` | Survived to the end of the project | The archive sweep, and nothing else |

The load-bearing consequence: **closing a tab is the rejection gesture, so it is the only thing tab close does to the ledger.** It performs no capture. See §3.

Reopening a `dismissed` source in the same workspace and letting it settle returns it to `open` — deliberately opening it again is a reversal of the rejection. `kept` is likewise not terminal: settling a tab in a reopened archived workspace returns that ref to `open`.

#### `openedFromSourceId` **[decided]**

Set when a workspace tab is spawned from another workspace tab — link click, ⌘-click, target=_blank, a popup. It records *which source led you to this one*. `nil` when the tab came from the omnibar, a bookmark, the share sheet, or an import.

`TabManager` already tracks the parent relationship it needs for this in `automaticLinkOpeners` (`TabManager.swift:459`), so the lineage is available at tab-creation time rather than needing new plumbing.

**Phase 1 records it and reads it nowhere.** It is provenance lineage for Phase 4's graph, where a fan of sources converging on a common parent is exactly the shared-upstream pattern the spec wants to render. Listed in §6 as recorded-but-unused.

### 1.5 `LedgerAnchor` (new, synced)

```swift
@Model final class LedgerAnchor {
    var id: UUID = UUID()
    var sourceId: UUID = UUID()
    var sourceKey: String = ""
    var modalityRaw: String = "webPage"
    var locator: String = ""      // format per modality, §1.10
    var quote: String = ""        // resilience copy; the source of truth when the locator breaks
    var label: String = ""        // display text for the enriched render
    var createdAt: Date = Date()
}
```

One `locator` column serves every modality. The modality tells the resolver how to turn it into a URL, and how to re-find it in extracted text or an archive when the live page has moved on.

`quote` is not optional in spirit even though it is defaulted — an anchor with no quote cannot survive its locator breaking, which is the entire resilience story.

### 1.6 `LedgerClaim` (new, synced)

```swift
@Model final class LedgerClaim {
    var id: UUID = UUID()
    var text: String = ""
    var normalizedText: String = ""   // lowercased, whitespace-collapsed — dedup key across projects
    var createdAt: Date = Date()
}
```

**Phase 1 creates zero rows here.** The table exists only because `LedgerEdge.claimId` references it and the spec names Claim as a core concept. Promotion UX is a later phase. This is the one speculative table in the design; it costs three columns.

### 1.7 `LedgerEdge` (new, synced) — the heart

```swift
@Model final class LedgerEdge {
    var id: UUID = UUID()
    var documentId: UUID = UUID()   // WorkspaceDocument.id
    var anchorId: UUID = UUID()
    var claimId: UUID?              // nil = a plain text range, the default
    var rangeQuote: String = ""     // the document text this supports — survives edits that offsets don't
    var rangeStart: Int = 0         // best-effort; always re-validated against rangeQuote
    var rangeLength: Int = 0
    var createdAt: Date = Date()
}
```

Offsets are a fast path, `rangeQuote` is the truth. A Markdown file edited in an external app will invalidate every offset in it; re-finding by quote is what makes that survivable. Phase 4's graph view, the audit view, and "unsupported claims" are all queries over this one table.

### 1.8 `WorkspaceDocument` (new, synced)

**[decided]** Reference only in Phase 1 — no editor, no file creation, no reading or writing of file contents.

```swift
@Model final class WorkspaceDocument {
    var id: UUID = UUID()
    var workspaceId: UUID = UUID()
    var displayName: String = ""
    var relativePath: String = ""   // relative to the app's iCloud Drive container
    var orderIndex: Int = 0
    var createdAt: Date = Date()
    var lastOpenedAt: Date?
}
```

**[design call]** Paths are stored *relative to the app's own ubiquity container*, not as security-scoped bookmarks. Bookmark data is device-specific and would not survive sync to the iPad; a relative path does, and the app needs no security scope to reach its own container. Documents outside that container would need a local-only bookmark table — deferred until something actually needs it.

### 1.9 `LedgerArchive` (new, **local only, never synced**)

**[decided]** Full page archive at capture, `@Attribute(.externalStorage)`, excluded from CloudKit.

```swift
@Model final class LedgerArchive {
    var id: UUID = UUID()
    var sourceId: UUID = UUID()
    var sourceKey: String = ""
    var capturedAt: Date = Date()
    var byteCount: Int = 0
    @Attribute(.externalStorage) var webArchiveData: Data?
}
```

**The mechanism matters.** In a `ModelContainer` whose configuration declares `cloudKitDatabase: .private`, *every model in that configuration syncs*. Keeping this one local requires a **second `ModelConfiguration`** in the same container:

```swift
ModelContainer(for: schema, configurations: [cloudBackedConfig, localOnlyConfig])
```

This is why the constraints section mandates UUID columns over relationships: a synced model cannot hold a SwiftData relationship to a model in a different configuration.

Archives are produced by `WKWebView.createWebArchiveData(completionHandler:)`, available on both macOS and iOS.

**Growth policy** — archives are unbounded local growth and need a ceiling in Phase 1, not later:

- Skip any archive over **25 MB** (record `byteCount = 0` and no data; the extracted text is still there).
- Surface total archive size in Settings with a clear action, added to the existing `BrowsingDataCleaner` rather than a new surface.
- No automatic eviction. `// ponytail: manual clearing only; add LRU eviction if the folder actually gets uncomfortable.`

### 1.10 Anchor locator formats

`locator` is always a URL-fragment-shaped token. The modality determines how it is composed into a link and how it is re-found.

| Modality | `locator` format | Resulting href | Fallback when it breaks |
|---|---|---|---|
| `webPage` | the text-fragment directive without the `#:~:` prefix — `text=gut%20bacteria`, or `text=prefix-,start,end,-suffix` | `<canonicalURL>#:~:text=…` | search `quote` in `originalPayloadData`, then in `LedgerArchive` |
| `video` | `t=417`, or `t=417,432` for a range (seconds, start-first) | `<canonicalURL>&t=417` | `quote` holds the transcript line; Phase 2 transcripts make this searchable |
| `pdf` | `page=12`, or `page=12&text=…` when a quote is anchored | `<canonicalURL>#page=12` | page number alone; then `quote` search |
| `image` | empty (whole image), or `xywh=percent:10,20,30,40` | `<canonicalURL>#xywh=percent:10,20,30,40` | whole image |

`xywh=` is the W3C Media Fragments syntax — a real standard that browsers ignore harmlessly rather than a private invention. Image regions are otherwise deferred per the spec.

**Why the fragment never enters `sourceKey`:** canonicalization strips fragments (§2), so a page and a text-fragment anchor into it are the same source. This is already true of the existing `sourceKey` and is the property the whole anchor model rests on.

---

## 2. Canonical source identity

`NewspaperStore.sourceKey(for:)` (`Newspaper.swift:839`) currently strips only the fragment and lowercases scheme and host. It keeps every query parameter, so `watch?v=X&t=417` and `watch?v=X` are two different sources — and `?t=` is precisely a video *anchor locator*, not a source identity. utm-tagged links duplicate the same way.

**[decided]** Extend the existing shared function. One canonical key, no second column.

**Generic rules, in order:**

1. Lowercase scheme and host; strip a leading `www.`
2. Drop the fragment
3. Drop tracking params: `utm_*`, `fbclid`, `gclid`, `msclkid`, `mc_cid`, `mc_eid`, `igshid`, `si`, `ref`, `ref_src`, `ref_url`, `feature`
4. Sort remaining params by name, so `?a=1&b=2` and `?b=2&a=1` agree
5. Drop an empty query and a trailing `?`
6. Strip a trailing slash on non-root paths

**Per-site rules** (three lines each; these are the ones that actually bite in practice):

| Site | Rule |
|---|---|
| YouTube | `youtu.be/ID`, `/shorts/ID`, `/live/ID`, `/embed/ID`, `m.youtube.com/watch?v=ID` → `https://youtube.com/watch?v=ID`; drop `t`, `start`, `list`, `index`, `pp` |
| x.com / twitter.com | on `/status/` paths, drop the query entirely |
| arXiv | `/pdf/ID(vN)(.pdf)` → `/abs/ID(vN)`. **Version suffixes are preserved** — v1 and v2 of a paper are different sources |
| DOI | `dx.doi.org` → `doi.org`; lowercase the DOI |

**[design call]** Stripping `www.` is the one generic rule with real risk — a handful of sites serve different content at the apex. It is included because near-universally it is an alias and the duplicate-source cost is constant. Easy to drop if it misbehaves.

### The re-key migration **[decided]**

Recomputing `sourceKey` touches the existing reading list, which is live user data. One pass, on next launch:

1. Recompute `sourceKey` for every `NewspaperArticle`.
2. Group by the new key. Where two or more rows collapse, pick a **winner**: has `originalPayloadData` → higher `rating` → **earliest `addedAt`** (so original filing and Section survive).
3. Fill the winner's empty fields from the losers: `byline`, `publication`, `leadImageURL`, `originalPayloadData`. Take `max` of `rating` and `readingProgress`, `OR` of `isRead`, latest of `finishedAt` / `lastReadAt`.
4. Repoint any `WorkspaceSourceRef.sourceId` from loser to winner (none exist on the first run; this matters on later re-key passes).
5. Delete the losers.

Irreversible. Worth logging the merge count via the existing `PersistenceDiagnostics`.

---

## 3. Workspace suspend / restore

**[decided]** Tabs carry a `workspaceId`; the sidebar filters. Nothing is ever discarded or restored.

This replaces the current `SavedWorkspace` mechanism, which is a Codable snapshot in `UserDefaults["saved_workspaces"]` (`ContentView.swift:294`) whose `loadWorkspace()` (`ContentView.swift:3211`) **destroys every open tab** via `TabManager.discardTabsForWorkspaceLoad`. That path, its iOS mirror in `Browser iOS/Workspace_iOS.swift`, and `SavedWorkspaceTab` / `SavedTabGroup` all go away. A one-shot importer converts any existing saved workspaces into real `Workspace` rows with their tabs.

### The integration points

**Active workspace is per-window state**, held on `TabManager` and persisted to UserDefaults alongside `splitTabIds` — the same pattern and the same rationale as ADR 0001. Two windows can be in two different workspaces.

```swift
// TabManager
var activeWorkspaceId: UUID?
```

**The filter is one line.** `ContentView.swift:785`:

```swift
// before
private var visiblePersistedTabs: [BrowserTab] { TabSync.visible(tabs) }

// after
private var visiblePersistedTabs: [BrowserTab] {
    TabSync.visible(tabs).filter { $0.workspaceId == tabManager.activeWorkspaceId }
}
```

Every existing consumer — `allTabs`, ordering, splits, tab peek, memory saver, selection — reads through this. That is the whole of "restore."

- **Suspend** = set `activeWorkspaceId = nil`. Tabs keep their `workspaceId` in the store and simply stop being visible. Their web views are released through the existing `webViewManager?.removeWebView(for:)` path the memory saver already uses.
- **Restore** = set `activeWorkspaceId`. Tabs reappear; web views rebuild on selection exactly as any evicted tab does.
- **New tabs** inherit `tabManager.activeWorkspaceId` at creation.
- **Selection safety**: switching workspaces must re-run `ensureSelectedTab(from:)` against the newly filtered set, or `selectedTabId` points at a tab the window no longer shows.

### Incognito **[decided, softened — worth a second look]**

The chosen option was "incognito tabs can't join a workspace at all," described as *opening incognito leaves the workspace*.

**[design call]** The first half is implemented literally and the second is softened: incognito tabs never carry a `workspaceId`, are never captured, and never reach the ledger or seen-before — but they stay **visible** in the sidebar alongside the workspace's tabs rather than forcing the window out of its workspace.

Reason: `allTabs` already merges `incognitoTabs` unconditionally (`ContentView.swift:786`), so visibility is free, whereas hard-exiting would tear down a filtered sidebar and a live split for a one-off private lookup. The literal behavior is one line in the ⇧⌘N path if it turns out to be wanted.

### Capture at settle **[decided]**

**Capture is triggered by a page settling, not by a tab closing.** When a workspace tab finishes loading and dwells briefly, it enters the ledger. This is the replacement for the spec's "tab demotion" — the spec assumed closing a tab was the save gesture; in this workflow it is the reject gesture, so the capture trigger has to move to the front of the tab's life.

**Trigger:** `didFinish` navigation in a tab where `workspaceId != nil`, followed by a dwell with no further navigation. Dwell exists to keep redirect chains and interstitials out of the ledger — only the page you actually landed on gets recorded.

**Dwell = 20 seconds** **[decided]**, as a named constant beside the existing capture constants:

```swift
enum WorkspaceCapturePolicy {
    static let settleDwell: Duration = .seconds(20)   // tune here, nowhere else
}
```

Twenty seconds is not "the page finished loading" — it is "you stayed with it." The ledger records sources you considered, not every page that scrolled past. Redirect chains, consent interstitials, and login bounces are excluded trivially; so is the page you opened, glanced at, and rejected, which is the far larger category.

**This makes closing-before-settle the common path, not the edge case.** Most rejections now happen inside the dwell, which is exactly why close writes its own rejection row (below) rather than relying on a capture having already happened.

Two rules the timer needs:

- **A URL change resets it**, including a same-document SPA route change. Otherwise a single-page app records whichever route happened to be showing at `didFinish` rather than the one you stopped on. The document-identity machinery in `NewspaperCaptureDocumentBinding` (`Newspaper.swift:50`) already distinguishes a new document from a same-document navigation.
- **Background tabs settle normally.** Opening ten search results in background tabs and closing the seven bad ones is the workflow this design is for; the ten are the working set and the seven closes are seven rejections. The dwell timer does not care whether the tab is displayed.

**What it writes:**

```
on settle(tab) where tab.workspaceId != nil:

    guard not already captured        // re-fire guard, below

    upsert WorkspaceSourceRef(method: .settle,
                              disposition: .open,
                              openedFromSourceId: parent tab's sourceId or nil)

    minimum:      store.enqueue(...) with captureState = .deferred
    opportunistic: if the page is idle and extraction is cheap right now —
                   NewspaperCaptureCoordinator.capture(...)  -> .ready
                   createWebArchiveData(...)                 -> LedgerArchive
```

The `.deferred` row is the floor. Full capture and archive are best-effort on top of it: the web view is alive, loaded, and idle at settle time, which is the cheapest moment in the whole tab lifecycle to extract from. If extraction is skipped or fails, the ref still exists and the source is still in the ledger — `.deferred` rows can be upgraded later, on demand or on a subsequent visit.

**"Cheap" means:** page idle, not currently loading, and the archive under the 25 MB cap from §1.9. Nothing here blocks the UI, and nothing here can fail in a way the user sees.

#### The re-fire guard **[decided]**

Settle-capture must not re-fire on every revisit of an unchanged page, or a workspace you browse in for a week accumulates redundant work and churns CloudKit.

Two tiers:

1. **Fast guard** — a `WorkspaceSourceRef` already exists for `(workspaceId, sourceKey)` **and** the source's `captureState` is `.ready`: do nothing at all. No fetch beyond the ref lookup that seen-before surfacing already performs on this navigation.
2. **Upgrade path** — the ref exists but `captureState` is `.deferred` or `.failed`: this is the retry, so run the opportunistic capture. On success, compare the fresh extraction's digest against the stored `sourceDigest`; identical content writes nothing but the state change.

Tier 1 makes the common case — revisiting a page you already captured — a single indexed fetch and zero writes. `sourceDigest` (`Newspaper.swift:343`) already exists and is what makes tier 2 able to tell "same page again" from "the page changed."

The one write that always happens on settle is flipping a `dismissed` or `kept` ref back to `open`, because that is a real state change the user just performed.

### Close is rejection **[decided]**

**Closing a tab writes `dismissed` and does nothing else to the ledger.** No capture, no archive, no extraction, no web-view retention. The capture-on-close pipeline is gone, and with it its hazard: there is no longer any reason to keep a `WKWebView` alive after its tab closes, so the previous design's ~6-second retention window does not exist.

#### Closing before the page settles **[decided]**

A page rejected inside the 20-second dwell has no ledger row yet, so there is nothing to mark `dismissed` — and with a dwell this long, that is **most** rejections. The page you bounced off in five seconds is the page you will click again in March, and it is precisely the one worth a warning.

So **close writes the rejection even when no capture ever happened**: a minimal source row (`captureState = .deferred`, no payload, no extraction) plus a `dismissed` ref. This is still a disposition write and still does no capture work — it costs one insert, and it is what makes seen-before able to say "you rejected this in March."

Conditions: the tab has a committed main-frame URL (blank tabs write nothing, which is what already exempts the housekeeping callers) and `workspaceId != nil`. Normal browsing outside a workspace writes nothing on close, ever.

**Consequence for the Newspaper feed.** These rows would otherwise put rejected junk in the reading list under the workspace's Section. The feed therefore excludes sources whose references are **all** `dismissed`. One predicate, and it is honest: a payload-less row you threw away is not a saved article. A source dismissed in one workspace and `open` in another still appears — it is genuinely still in play.

The complication is that **`closeTab` is not a user gesture.** It has roughly fifteen callers and most of them are housekeeping:

| Caller | Rejection? | Why |
|---|---|---|
| Sidebar context menu, close button (`ContentView.swift:1099,2252`), iOS equivalents (`BrowserView_iOS.swift:680,718,1287`) | **Yes** | The gesture |
| ⌘W → `.browserCloseTab` | **Yes** | The gesture |
| ⇧⌘W → `closeTabSet` (`TabManager.swift:658`) | **Yes**, once per member | Closing a 4-pane split rejects four sources |
| `deleteTabs(at:)` (`TabManager.swift:632`) | **Yes** | Swipe to delete |
| Blank-tab housekeeping (`TabManager.swift:318,333,353,366`, `BrowserView_iOS.swift:1238`) | No | Closes `url == nil` tabs — self-exempting, a blank tab has no ref |
| `closeAutomaticallyOpenedLinkOnBack` (`TabManager.swift:459`) | No | Undoing an automatic open, not rejecting a source |
| JS `window.close()` (`WebView.swift:1157`, `WebView_iOS.swift:677`) | No | The *page* closed itself |
| `deleteContainer` (`BrowserView_iOS.swift:1564` + Mac equivalent) | No | Deleting a container, not judging its sources |
| `discardTabsForWorkspaceLoad` (`TabManager.swift:642`) | n/a | Deleted along with the old workspace mechanism |

**[design call]** So the disposition write cannot hang off `closeTab` itself. `closeTab` takes a **required** close-reason parameter:

```swift
func closeTab(_ tab: Tab, tabs: [Tab], reason: TabCloseReason)   // .userRejected | .housekeeping
```

Required, not defaulted. A default would silently do the wrong thing at whichever call site someone adds next, and this is a semantically loaded operation — the compiler should force every one of the fifteen sites to state what it means. `.userRejected` writes `dismissed`; `.housekeeping` writes nothing.

### Window close routes to suspend, never per-tab close **[decided]**

**Closing a workspace's window suspends the workspace. It must never iterate `closeTab`** — that would mass-dismiss every source in the project in one gesture.

Close-window and close-tab are different code paths with different ledger consequences:

| Gesture | Tabs | Ledger |
|---|---|---|
| Close tab | Deleted | One ref → `dismissed` |
| Close window | Untouched; keep their `workspaceId` | **Nothing written** |
| Archive workspace | Untouched | All remaining `open` → `kept` |

Where the guard is needed:

- **macOS — currently safe, must stay that way.** Browser windows are a SwiftUI `WindowGroup`; closing one tears down the scene's `ContentView`/`TabManager` while the SwiftData `Tab` rows persist untouched. Nothing iterates `closeTab` today. The guard is a standing rule plus the test in §7, so no future "clean up tabs on window close" change reintroduces it.
- **macOS — the real hazard is the last-tab coupling.** `closeTab` calls `terminateApplication()` when the last tab goes (`TabManager.swift:573,599,614`). In a workspace this inverts badly: closing your way down to zero tabs both dismisses every source *and* quits the app. The rule: when `activeWorkspaceId != nil`, an empty tab set suspends the workspace back to normal browsing instead of terminating.
- **⇧⌘W closes the workspace** **[decided]**, and closing a workspace *is* suspending it. This resolves the hazard the previous draft raised rather than mitigating it: ⇧⌘W no longer closes any tabs inside a workspace, so it cannot mass-dismiss sources, and no confirmation dialog or undo grouping is needed. Nothing is written to the ledger.

  ⇧⌘W is currently bound to `closeTabSet` (`ShortcutCommand.swift:189`), which closes every member of a split. **[design call]** The binding becomes context-dependent: workspace active → close the workspace; no workspace → existing `closeTabSet` behavior, unchanged. Two notes on that: the shortcut is user-rebindable through `ShortcutCommand`, so its label and help text have to describe both meanings, and this is the one place in the design where a single key does two things. It is justified because the two meanings never coexist — inside a workspace, "close the set of things I'm working on" *is* closing the workspace.
- **iOS/iPadOS — there is no window close.** The equivalent gestures are switching workspaces, leaving for normal browsing, and app backgrounding. All three are suspend and none of them may touch dispositions. `BrowserView_iOS.swift` routes ⌘W-equivalents through `closeActiveTab` (`:1287`) and `closeTabSet` (`:542`); those stay rejection. The workspace switcher is the suspend path and must not close anything.

### Archive is completion **[decided]**

Setting `Workspace.isArchived = true` runs one ledger pass over that workspace's refs:

```
for ref in refs(workspaceId) where ref.disposition == .open:
    ref.disposition = .kept
```

`dismissed` rows are never touched — a rejection survives archiving, which is the point of keeping the distinction. The sweep is **idempotent**: a second run finds no `open` rows and writes nothing, which matters because it can run again on another device after sync (§5).

### Platform affordances **[decided]**

Suspend is the everyday action and tab close is semantically loaded, which creates a UX obligation the schema cannot fix: **if leaving a workspace is awkward, people close tabs instead, and every one of those closes is a false `dismissed`.** Leaving must be at least as easy as closing.

The three platforms get deliberately different amounts of this feature.

**macOS — full.** ⇧⌘W closes (suspends) the workspace; the workspace switcher lives in the existing menu. Closing the window already suspends and needs no new affordance.

**iPadOS — full desktop parity.** The iPad is a research machine in this workflow, not a large phone: same shortcuts with a hardware keyboard, same switcher, same sidebar. Phase 2's Markdown editor opens **in parallel with the page** here, which is the point of the platform — you read the source and write against it at once.

One architectural note that Phase 1 must not foreclose, though it builds none of it: **a document pane is not a `Tab`.** `Split` is defined as an arrangement of 2–4 Tabs (CONTEXT.md, ADR 0001), so a Markdown pane cannot be a Split member without redefining Split. Phase 2 will need either a separate document-pane concept beside the Split or a deliberate widening of Split — a decision to make then. Phase 1's only obligation is that `WorkspaceDocument` is addressable independently of the tab set, which it is.

**iPhone — switching workspaces, and nothing more** **[decided]**. No parallel editor, no research surface. The one thing it must do is get you into and out of a workspace.

`browserGestureBar` (`BrowserView_iOS.swift:997`) already carries tap → omnibar, long-press → new tab, swipe up → all tabs, swipe left/right → adjacent tab. `handleBarSwipe` (`:1073`) handles `dy < -30`, `dx < -30`, and `dx > 30` — **swipe down is unbound**, so the affordance is free and nothing has to be reshuffled.

**Swipe down opens the workspace switcher**, always, in every state. The list contains the workspaces plus the default workspace; picking one switches to it. Suspending is not a separate gesture because it does not need to be — switching away from a workspace *is* suspending it, and switching to the default workspace is how you leave.

The binding reads correctly against its neighbour: swipe **up** brings this workspace's tabs out, swipe **down** goes up a level to the projects themselves.

Three obligations ride along:

- **The accessibility hint goes stale on ship.** `browserGestureBar`'s hint enumerates the gestures ("Swipe up for tabs, or left and right to change tabs") and must name the new one.
- **VoiceOver cannot perform a swipe-down.** The bar is a single accessibility element with `.isButton`, so the switcher must also exist as an accessibility custom action on that element. Non-negotiable: this is the only path to a core action.
- The first-run `GestureGuide` teaches four gestures today and must teach five.

### Tabs stay with their workspace **[decided]**

A workspace's tabs live in that workspace permanently. They are **never carried over into the default workspace** — suspending, switching, closing the window, and ⇧⌘W all leave `workspaceId` untouched. The default workspace shows only tabs with `workspaceId == nil`, which is what the one-line filter in "The integration points" already gives.

This is what makes the workspace a real container rather than a saved arrangement, and it is why nothing in this design ever needs to "restore" anything.

### Promoting the default workspace **[decided]**

At any point the default workspace can be turned into a workspace: create the `Workspace`, stamp `workspaceId` onto every tab in the window with `workspaceId == nil`, and the window is now in that workspace.

The ledger consequence: those tabs were in the default workspace, so **no source references exist for any of them** — capture only fires inside a workspace. Promotion therefore runs a settle-capture pass over the promoted tabs immediately rather than waiting for a re-navigation that may never come. They are loaded and idle at that moment, which is the cheapest possible time to extract, and each gets the ordinary `.open` reference with `method: .manual` (the user's deliberate act, not a settle).

Promotion is the natural on-ramp: browse normally, notice it has become a project, name it. It costs one loop and reuses the capture path that already exists.

**The default workspace is not a row.** It is `workspaceId == nil` — the absence of a workspace, named for convenience. Nothing in the schema represents it and nothing should: a sentinel `Workspace` row with a fixed UUID would need special-casing in the filter, the archive sweep, promotion, and every query that means "no workspace," and it could be renamed or deleted by the ordinary UI. The term is deliberately *not* "default workspace", which would collide with `BrowserSession` (website-data isolation — containers and incognito). A tab has a session and a workspace; they are orthogonal.

### Manual capture

One keystroke from any tab in a workspace: writes the ref with `method: .manual`, `disposition: .open`, and runs the same opportunistic capture as settle. The tab stays open. With a 20-second dwell this is the deliberate "keep this one" gesture — it is how you capture a page you are about to close, and how you re-capture one that landed as `.deferred`. Promotion (above) uses the same path.

---

## 4. Anchor Markdown link syntax

**[decided]** Real URL in the href, ledger id in the Markdown title attribute.

```markdown
[the gut bacteria finding](https://ex.com/a#:~:text=gut%20bacteria "^a1b2c3d4")
```

- **href** — the genuine deep link, built from canonical URL + `locator` per §1.10. It works in any browser with no software of ours involved.
- **title** — `^` + the first 8 hex characters of `LedgerAnchor.id`. The caret marks it as ours; the app resolves the full UUID by prefix.
- **link text** — whatever the user wrote. It is their prose, not a generated citation. `LedgerAnchor.label` is only for the sidebar and graph view.

### Degradation

| Reader | Result |
|---|---|
| In-app editor (Phase 2) | Enriched: source title, capture date, rating, click through to the exact passage or timestamp |
| Obsidian / iA Writer / Typora | Ordinary working link; `^a1b2c3d4` shows as a tooltip |
| GitHub / any CommonMark renderer | Ordinary working link with a `title` attribute |
| Plain text | `[text](url "^id")` — legible, and the URL is visible |
| Ledger deleted entirely | **The link still works.** Nothing about the document depends on our database |

That last row is the point. The document is never hostage to the ledger.

### Resolution order

1. Parse `"^…"` from the title → prefix-match `LedgerAnchor.id`. Hit → enriched.
2. Miss (file written elsewhere, id stale) → match canonical URL + parsed locator against the anchor table. Hit → enriched, and repair the title on next save.
3. Miss → plain link, rendered normally. Never an error, never a broken-looking document.

### Ambiguity

Two anchors at the same locator are distinguishable because the id is in the file. This is the concrete thing the title attribute buys over a bare URL, and it is what lets Phase 4 draw an edge to *this* anchor rather than *an* anchor.

---

## 5. Migration and versioning strategy

Every later phase adds columns to these tables, so the rules matter more than any single migration.

**[design call]** Two mechanisms, each for one job.

### Model shape: lightweight migration only

**No `VersionedSchema` / `SchemaMigrationPlan` custom stages.** CloudKit-backed SwiftData stores do not run custom migration stages reliably, and the CloudKit attribute rules already force every change to be lightweight-compatible anyway. Adding the machinery would be ceremony that cannot do the thing it exists to do.

The rules that keep it safe — these are the actual versioning strategy:

1. **Add columns; never rename or retype in place.** A rename is a new column plus a data pass.
2. **Every new attribute is optional or defaulted.** Non-negotiable under CloudKit.
3. **Enums are stored as raw strings with a safe fallback** (`memoryPolicyRaw` / `sessionKindRaw` in `Tab.swift:148-158` are the pattern). New cases are backward-compatible; old builds see an unknown value and fall back rather than crashing.
4. **New synced models are registered in `TabSync.cloudBackedModels` with a user-visible `SyncedDataCategory`.** The existing comment at `TabSync.swift:81` already mandates this — adding a synced model without naming its data category is a bug.
5. **Local-only models go in the second `ModelConfiguration`**, never in `cloudBackedModels`.

Phase 1 adds one `SyncedDataCategory`: **`research`** — "Research workspaces: projects, captured sources, anchors, and links between your writing and sources." One category for all six synced ledger models; six toggles for one feature would be noise.

### Data shape: version-gated reconcilers at startup

Data migrations (the §2 re-key, the `SavedWorkspace` import, anything later) run as **idempotent, version-gated passes at container creation**, reusing the hook that already exists:

```swift
// ModelContainerStartup.makeContainer, next to line 70
NewspaperStore(modelContext: container.mainContext).reconcileInterruptedWork()
LedgerMigrator(modelContext: container.mainContext).migrateIfNeeded()   // new
```

`LedgerMigrator` reads an integer `ledgerSchemaVersion` from UserDefaults, runs each pending step in order, writes the new version. Phase 1 ships steps 1 (`SavedWorkspace` import) and 2 (source re-key + merge).

Why this and not a `SchemaMigrationPlan`: it is the pattern already proven in this codebase, it works identically under CloudKit, it is trivially testable against a fixture store, and a partially-completed run is safe because every step is idempotent.

**Two real caveats, stated rather than papered over:**

- Version is per-device, so a multi-device user runs the pass on each device. Idempotency is what makes that fine, and it is a hard requirement on every step, not an aspiration.
- A device that has not launched in a long time may sync down rows written by a newer schema before it runs its own migration. Steps must tolerate encountering already-migrated data — which falls out of idempotency.

---

## 6. What Phase 1 does not build

Named explicitly so the next session does not drift into them: claim promotion UX, the Markdown editor, anchor creation UI, YouTube transcripts, the share extension, the graph/audit view, bibliography matching, credibility scoring, provenance tracing, any AI, any external API (OpenAlex, Crossref, Semantic Scholar), and any protocol for on-device models. `LedgerClaim` exists as a table with no writer.

**Recorded but unused in Phase 1:**

- `WorkspaceSourceRef.openedFromSourceId` — written on every link-spawned workspace tab, read by nothing. Phase 4's graph view consumes it: a fan of sources sharing one `openedFromSourceId` ancestor is the shared-upstream pattern the spec wants to detect.

**Flagged for later, deliberately not Phase 1:**

- **The iPad parallel Markdown pane is Phase 2.** Phase 1 gives iPadOS full desktop parity for *workspaces*; the side-by-side editor arrives with the editor itself. The open question it inherits is recorded in §3: a document pane is not a `Tab`, so it cannot join a `Split` as currently defined.

- **Undo of an accidental tab close must un-write the disposition.** `reopenLastClosedTab` (`TabManager.swift:673`) currently restores the tab only. Under the new semantics an accidental ⌘W leaves a false `dismissed` behind, and restoring the tab without reverting the ref would leave the ledger recording a rejection the user took back. When this is built, the reopen path must flip that ref back to `open` — which means the closed-tab snapshot needs to carry the ref id. A ⇧⌘W multi-close must undo as **one** unit, restoring every member's ref together. Phase 1 ships without it; the schema already supports it because refs are addressable by `(workspaceId, sourceKey)`.
- **`dismissed` has no UI.** Phase 1 records rejections and shows them nowhere. A "rejected sources" view is a rendering of the same column whenever it is wanted.

## 7. Verification

**Unit tests** (`Straight Up BrowserTests`, no new framework):

- **Canonicalization table** — the four site rules plus the generic ones, as an input/expected pair list. Non-negotiable: the four YouTube URL shapes collapsing to one key, `?t=417` not forking a source, utm stripping, arXiv version preservation, DOI lowercasing.
- **Merge migration** — a fixture store with known duplicates; assert winner selection (payload → rating → earliest `addedAt`), field backfill, ref repointing, loser deletion, and that a second run is a no-op.
- **Anchor round trip** — for each modality, `(source, modality, locator)` → Markdown → parse → resolve, including the resolution fallbacks: id hit, id miss with URL+locator hit, total miss renders as a plain link.
- **Workspace filtering** — tabs partition correctly by `activeWorkspaceId`; incognito tabs always visible and never carry one; `ensureSelectedTab` re-runs on switch.

The five that pin the revised semantics:

- **Close tab writes `dismissed` and captures nothing.** A user-initiated close on a workspace tab sets exactly one ref to `dismissed`; assert no capture was started, no archive written, and no web view retained past the close.
- **Close tab with `reason: .housekeeping` writes nothing.** Covers the blank-tab, JS `window.close()`, container-delete, and back-closes-child callers — the ledger must be untouched by all of them.
- **Close window suspends.** Tearing down a workspace window writes **no** dispositions, every tab keeps its `workspaceId`, and reopening the workspace restores the full set. The regression this guards is a future change iterating `closeTab` on window teardown.
- **Archive sweep.** `open → kept` for every remaining ref; `dismissed` rows untouched; **a second run writes nothing** (idempotent, because it can run again on another device after sync).
- **Settle-capture fires once per page.** Settling the same unchanged page twice produces one ref and one capture — the second pass hits the tier-1 fast guard and writes nothing. Settling after a `dismissed` returns the ref to `open`.
- **`openedFromSourceId` lineage.** Populated on a tab spawned by a link click from another workspace tab; `nil` on a tab opened from the omnibar.
- **Dwell.** A redirect chain settles once, on the final URL. A tab closed at 5 seconds never captures. An SPA route change resets the timer, so the recorded URL is the one dwelt on, not the one at `didFinish`. A background tab settles like any other.
- **Close before settle.** Closing inside the dwell writes a `.deferred` source and a `dismissed` ref, runs no extraction, and writes no archive. A blank tab writes nothing. A tab outside any workspace writes nothing.
- **Feed exclusion.** A source whose refs are all `dismissed` is absent from the Newspaper; the same source `open` in a second workspace is present.
- **⇧⌘W closes the workspace.** Inside a workspace it suspends and writes **nothing** to the ledger — no dispositions, no tabs closed. Outside a workspace it still closes the split's tab set as before.
- **Tabs never leave their workspace.** After suspend, switch, window close, and ⇧⌘W, every tab retains its `workspaceId`, and none of them appear in the default workspace.
- **Promotion.** Turning the default workspace into a workspace stamps every `workspaceId == nil` tab in the window, creates one `.open` ref per tab with `method: .manual`, and captures them without waiting for a re-navigation. Tabs already belonging to another workspace are untouched.

**Manual, end to end:**

1. Create a workspace, open three tabs, let them settle → all three appear in the ledger and in the Newspaper under the workspace's Section, `disposition: open`.
2. Close one → its ref reads `dismissed`; the other two are untouched and nothing was captured by the close.
3. Close the window → nothing changes in the ledger. Reopen the workspace → the two remaining tabs return intact.
4. Archive the workspace → the two `open` refs become `kept`; the `dismissed` one stays `dismissed`.
5. Same URL settled in a second workspace → two `WorkspaceSourceRef` rows, `section` unchanged.
6. Revisit a captured URL by typing → ledger row in the omnibar suggestions. Arrive by clicking a link → banner. **[decided: both]**
7. Second device on the same Apple ID → workspaces, sources, refs, anchors sync; archives do not.
8. Open a document containing an anchor link in an external Markdown editor → ordinary working link.
9. Browse normally, then promote the default workspace to a workspace → those tabs join it and enter the ledger; the default workspace is now empty.
10. ⇧⌘W → the workspace closes, tabs keep their `workspaceId`, and the default workspace does not inherit them. Reopen the workspace → all of them return.
11. On iPhone, swipe down on the gesture bar → the workspace switcher, in every state. Confirm VoiceOver reaches it via the custom action and that the bar's accessibility hint names the gesture.

**Two known integration hazards:**

- **`ContentView` type-check budget.** Documented from prior experience: one more modifier on `body` breaks the build with a misleading line number. The seen-before banner must register through `onAppear` observers into `@State` and render inside an existing overlay container — never a new `.onReceive` or modifier on `body`.
- **Localization.** Every user-facing string goes through `String(localized:)` and the 40-locale String Catalog pipeline. New surfaces here: workspace names UI, the seen-before banner, the `research` sync category label, the archive-clearing control.

---

## Companion edits (proposed, not yet made)

- **`CONTEXT.md`** — the ubiquitous language gains **Workspace**, **Source** (and the fact that Source *is* a Saved Article), **Workspace reference**, **Anchor**, **Claim**, **Edge**, **Disposition**; and the relationships section gains the workspace/tab/incognito rules from §3. Without this the codebase has two vocabularies for one thing.

  It should also define **default workspace** (`workspaceId == nil`, not a row) and note in *Flagged ambiguities* that it is distinct from `BrowserSession` — a tab has a session and a workspace, and the two are orthogonal.
- **`docs/adr/0007-the-research-ledger.md`** — records the four decisions most likely to be "fixed" by a later session that does not know why they are the way they are. Matching the existing ADR format (Considered Options / Consequences):
  1. **The ledger is SwiftData**, not a second hand-rolled SQLite store.
  2. **A research Source is a Saved Article**, not a parallel entity.
  3. **Single user per instance is deliberate.** Two people run separate instances; a shared ledger, per-person ratings, CKShare zones, and merge topology are consciously cut, not overlooked. Re-adding them is a product decision, not a gap to fill in.
  4. **Close semantics: close is rejection, suspend is the resting state, archive is completion.** This is the one most at risk. Capture-on-close is the natural-seeming design — the spec itself proposes it as "tab demotion," and it reads as obviously right: the tab is about to disappear, so save it. It is wrong for this workflow because closing a tab is how a source gets rejected, so capture-on-close would save precisely the material the user just threw away, and would make the ledger a record of everything seen rather than everything kept. The ADR must state this plainly enough that a future session reintroducing capture-on-close recognises it is reversing a decision rather than fixing an oversight.

New Swift files land flat in `Straight Up Browser/`, which the iOS target picks up automatically through Xcode 16 synced-folder membership.
