# The research ledger: SwiftData, Saved Articles, and close-as-rejection

Research workspaces (Thought Flow Phase 1, `docs/phase1-design.md`) are built on the existing SwiftData + CloudKit store rather than a second database; a research **Source** is a **Saved Article**; the ledger is single-user; and closing a tab means *rejecting* a source rather than saving it.

## Considered Options

- **A separate SQLite ledger** (raw `sqlite3`, or GRDB), as the specification proposed — rejected. SwiftData already *is* SQLite, and it already carries CloudKit sync, migration behaviour, and `@Query`. A second store would mean hand-writing sync, conflict resolution, and record mapping for it. The price is real and stated: no SQL joins, no recursive CTEs for provenance chains, no FTS5 for retrieval. Those arrive as fetch descriptors plus in-memory work, or a rebuildable local index, in the phase that first needs them. Nothing in Phase 1 needs SQL.

- **A parallel `Source` entity beside `NewspaperArticle`** — rejected. `NewspaperArticle` already holds a canonical key, extracted reader text, a content digest, byline, publication, and a rating: it is a Source under a different name. Two entities would mean two copies of every article's text and two ratings free to disagree. The cost of merging them is that a research capture appears in the Newspaper, filed under its workspace's **Section**; that is accepted, and the reading list gains one filter (sources rejected in every workspace are hidden).

- **A shared ledger across two people** (CloudKit shared zone, or per-user stores with merge, plus per-person rating rows) — **consciously cut, not overlooked.** Each person runs a separate instance with their own private CloudKit database. There is deliberately no `person` table and no per-person rating join; `NewspaperArticle.rating` is single-valued. Shared research spaces are a future feature and a product decision. A later session should not "fix" this by adding a person dimension.

- **Capture on close ("tab demotion")**, which the specification itself proposes and which reads as obviously correct — **rejected, and this is the decision most at risk of being reversed.** See below.

## Close is rejection

The three states a source can hold inside a workspace are universal — no per-workspace or per-user setting:

- **`open`** — still in the working set. Written when a page *settles*: it loaded and the user stayed with it for `WorkspaceCapturePolicy.settleDwell` (20 seconds).
- **`dismissed`** — rejected. Written by a user-initiated tab close, and by nothing else.
- **`kept`** — survived to the end of the project. Written by the archive sweep, and by nothing else.

Capture therefore happens at the *front* of a tab's life, not the end. Closing a tab writes a disposition and performs no capture, no extraction, and no archiving.

**Why capture-on-close is wrong here, despite being the natural design.** It is intuitive: the tab is about to disappear, so save it first. But in this workflow closing a tab is how a source gets thrown away. Capturing on close would preserve precisely the material the user just rejected, and would turn the ledger into a record of everything *seen* rather than everything *kept* — which destroys the value of asking it "have I looked at this before, and what did I decide?"

A future session that reintroduces capture-on-close is reversing a decision, not filling a gap.

## Consequences

- **`closeTab` takes a required `TabCloseReason`.** It has roughly fifteen callers and most are housekeeping — blank-tab cleanup, JavaScript `window.close()`, container deletion, undoing an automatic link open. A defaulted parameter would silently misfile whichever call site is added next, so the compiler forces every one to declare intent.
- **⇧⌘W closes the workspace, not the tab set,** whenever a workspace is active. One keystroke can therefore never mass-reject sources. Outside a workspace the shortcut keeps its original meaning; the two meanings never coexist.
- **Closing the last tab in a workspace suspends it** instead of terminating the app, which is what `closeTab` does outside a workspace.
- **Because the dwell is 20 seconds, most rejections happen before any capture.** Close writes a minimal deferred source row so the rejection is still recorded — that is what lets seen-before say "you dismissed this in March".
- **Suspension is per-window view state on `TabManager`, not a column.** A workspace can be open in one window and not another, exactly as a **Split** is (ADR 0001). Tabs keep their `workspaceId` forever and never migrate into the default workspace; the entire suspend/restore mechanism is one filter on the tab list.
- **The default workspace is `workspaceId == nil`, not a row.** A sentinel `Workspace` would need special-casing in the filter, the archive sweep, and promotion, and could be renamed or deleted by ordinary UI.
- **Page archives are local-only,** in the container's second `ModelConfiguration`. A synced model cannot hold a SwiftData relationship into another configuration, which is why every cross-entity link in the ledger is a `UUID` rather than a relationship — matching `Tab.groupId`.
- **Data migrations are idempotent version-gated passes at container creation** (`LedgerMigrator`), not `SchemaMigrationPlan` stages, which CloudKit-backed stores do not run reliably. Model *shape* changes stay lightweight-compatible by rule: add columns, never rename or retype, every attribute optional or defaulted, enums as raw strings with a safe fallback.
- **Canonicalization is shared.** `NewspaperStore.sourceKey(for:)` delegates to `SourceCanonicalizer`, so the reading list and the ledger can never disagree about what page they are looking at. A video's `?t=` is an anchor locator and must not fork the video into two sources.
