# Thought Flow — Phase 3 Design

Share-sheet capture. **No interview was held for this phase** — the owner asked for it to proceed unattended after Phase 2 closed, so every decision below is a **[design call]**, deliberately conservative, and annotatable after the fact. SPEC scope: "Share any page, video, or file from any app into a chosen workspace; default to the most recently active one; items movable afterward."

## Context

Phase 1 left the seam ready: `SourceCaptureMethod.shareSheet` already exists, and phase1-handoff §3 says share-sheet import "should add a `SourceCaptureMethod` case and call the same `upsertReference`". The case exists; Phase 3 wires a real share extension to it.

The hard constraint is process isolation: an app extension must not open the app's CloudKit-backed SwiftData store (two processes on one `NSPersistentCloudKitContainer` is how you corrupt sync state). The extension therefore **never touches the ledger** — it writes a queue the main app drains.

## Decisions

1. **iOS-only in Phase 3.** [design call] The share sheet is an iPhone/iPad workflow (the hundred-tabs-on-a-phone user shares from Safari, YouTube, Mail). The Mac already has in-app capture (⇧⌘D, ⌥⇧⌘D) for everything in the browser; a Mac share-menu extension is deferred, recorded in Not Built.

2. **Queue handoff over an App Group.** [design call] New app group `group.com.nathanfennel.Straight-Up-Browser` on the iOS app + extension. The extension writes one JSON file per shared item into `<group>/ShareInbox/`; the main app drains the inbox when it becomes active. No Darwin notifications, no background wakes — SPEC forbids designs that assume background time, and "next time you open Browser" is the honest contract.

3. **The picker is one tap.** [design call] The extension UI is a compact sheet: the **most recently active workspace is the primary button** ("Add to *Fermentation*"), other workspaces listed beneath, most-recent-first. No default-workspace option — capture requires a workspace (Phase 1 rule: the default workspace captures nothing). No workspace yet → the sheet says so and offers only Cancel.
   The app maintains a lightweight mirror (id, name, lastActiveAt) in the group's `UserDefaults`, refreshed when the app becomes active or resigns — the extension reads only this mirror.

4. **What a shared item is.** [design call]
   - **URL shares** (pages, videos): URL + best-available title. The main app runs it through the normal path — canonicalization, `enqueue`, `upsertReference(.shareSheet, .open)`. Text is not extracted at drain (no web view); the article stays `deferred`, exactly like a pre-settle capture, and fills in when the source is next opened in the workspace. Transcripts likewise fetch on first open, not at drain.
   - **File/image shares**: bytes are copied into the inbox beside the metadata; at drain they move to the app's own `Application Support/Imports/<sha256>.<ext>`, and the source is recorded with `sourceKey = "hash:<sha256>"` (`NewspaperArticle.contentHash` — the Phase 1 column built for this), modality inferred from the extension, `url` = the permanent imports-file URL.
   - **Plain-text shares** that parse as a URL are URL shares; other text is refused politely by the activation rule (out of scope — that's Scratch Pad's job).

5. **Movable afterward.** [design call] A "Move to Workspace" submenu on the Newspaper article context menu (shared `NewspaperView`, so Mac and iOS both get it). Moving re-points the existing `WorkspaceSourceRef.workspaceId` — the join row moves, disposition and method travel with it, `addedAt` stays, `updatedAt` stamps. The Newspaper `section` does **not** re-file (the Phase 1 freeze rule); `firstWorkspaceId` is history, not location, and does not change.

6. **Feedback at drain.** [design call] After a drain that ingested anything: the transient note ("Added 3 shared items to Fermentation"), through the same surfaces every other Phase 1/2 note uses.

## Schema

**No new entities, no new columns, no migration.** The queue is files in the group container; everything durable lands in Phase 1's tables via `LedgerStore`.

New `LedgerStore` API:
- `recordShareCapture(url:title:workspaceId:)` — enqueue + upsert with `.shareSheet`.
- `recordFileImport(data:suggestedName:workspaceId:)` — hash, persist to Imports, enqueue with `hash:` key, upsert with `.shareSheet`.
- `moveReference(_:to:)` — the §5 move.

## New files

| File | Holds |
|---|---|
| `Straight Up Browser/ShareQueue.swift` | the queue format (`SharedItem`), inbox read/write/drain, the workspace mirror. Foundation-only, compiled into both apps + the extension + the Mac test target |
| `Browser Share/ShareViewController.swift` | the extension: principal `UIViewController` hosting a SwiftUI picker; extracts URL/file from `NSExtensionItem`, writes the queue, completes |
| `Browser Share/Info.plist`, `Browser Share/BrowserShare.entitlements` | activation rules (web URL / file / image / movie, max 1 each), app group |
| `Straight Up BrowserTests/Phase3Tests.swift` | queue round-trip, drain → ledger writes, file import hashing, move semantics, mirror ordering |

Project surgery (brew Ruby + xcodeproj, per the established pattern): new `BrowserShare` app-extension target embedded in "Browser iOS"; the `Browser Share/` synced folder on the extension; one explicit file reference compiles `ShareQueue.swift` into the extension; app group added to `Browser iOS.entitlements` + the extension entitlements.

## Not built, deliberately

Mac share-menu extension; a workspace-creation flow inside the extension; text/Scratch-Pad shares; background ingestion; share-time text extraction or transcript fetch; any change to dispositions (a shared item is `.open`, full stop).
