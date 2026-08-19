# Thought Flow Phase 3 — Handoff

Phase 3 (share-sheet capture) is implemented, unit-tested, and on `main`. Built **without an interview** immediately after Phase 2 at the owner's request; every decision is a [design call] in `docs/phase3-design.md`, open to annotation. Manual verification is pending — the Phase 3 section of `docs/phase2-manual-checklist.md`.

## The one rule this phase adds

**The extension never opens the store.** Two processes on one CloudKit-backed SwiftData container is how sync state corrupts. The extension reads a mirrored workspace list from the app group's UserDefaults, writes one JSON (+ optional payload file) into `<group>/ShareInbox/`, and completes. The app drains on activation — never in the background, exactly as SPEC's suspension constraint demands.

## What shipped

| File | Holds |
|---|---|
| `Straight Up Browser/ShareQueue.swift` | queue format + inbox read/write/clear + the workspace mirror. Foundation-only; compiles into both apps, the extension, and the Mac test target |
| `Straight Up Browser/ShareIngest.swift` | the app side: drain → `LedgerStore`, imports directory, mirror refresh. Separate file so the extension never links SwiftData |
| `Browser Share/` | the `BrowserShare` iOS app-extension target: `ShareViewController` (principal class + SwiftUI one-tap picker), Info.plist (web URL / image / movie / file, max 1 each), entitlements |
| `LedgerStore.swift` | `recordShareCapture` (the `.shareSheet` method Phase 1 reserved), `recordFileImport` (SHA-256 → `hash:` sourceKey → `contentHash`, bytes in Application Support/Imports), `moveReference` |
| `NewspaperView.swift` | "Move to Workspace" context submenu — both platforms, since the view is shared |
| `BrowserView_iOS.swift` | drain on launch + `didBecomeActive`; mirror refresh on `willResignActive` (rides the existing merged publisher) |

Project surgery: `BrowserShare` target created with the xcodeproj gem — **classic group + file references, not a synced folder** (deviation from the design's sketch; smaller surface). `ShareQueue.swift` is compiled into the extension via an explicit second file reference. Versions pinned to the host app (2.0.0/23); bundle id `com.nathanfennel.Straight-Up-Browser.share`; app group `group.com.nathanfennel.Straight-Up-Browser` on the iOS app + extension. The extension's Info.plist needed explicit CFBundle keys (`GENERATE_INFOPLIST_FILE = NO` — the embed validator rejects an appex with no `CFBundleIdentifier`).

## Semantics pinned by tests (8 tests, 3 suites, in `Phase3Tests.swift`)

Queue round-trips oldest-first and `clear` removes payloads; drain writes `.shareSheet`/`.open` references against **canonicalized** keys and leaves articles `deferred`; identical bytes shared twice collapse onto one `hash:` source with two references; items for vanished workspaces are dropped, not retried forever; the mirror sorts most-recent-first and the *active* workspace outranks stored timestamps; moving re-points the join row (method and `addedAt` travel, Section and `firstWorkspaceId` do not), and moving onto an existing reference merges.

## Gotchas

- **Mac is untouched**: no app group on the Mac entitlements, no Mac share extension (deliberate — design §1). `ShareQueue.containerURL()` returns a group path on Mac anyway; nothing calls drain there.
- ~~**Extension strings are English-only** — the extension bundle has no string catalog.~~ *Closed 2026-08-20: `Browser Share/Localizable.xcstrings` now carries the extension's 6 keys in all 36 locales, added to the `BrowserShare` resources phase.*
- **First device build**: automatic signing must mint the app-group + extension provisioning; if the group id is rejected, register `group.com.nathanfennel.Straight-Up-Browser` on the team.
- The Phase 1 rule stands: a share is `.open`, capture-shaped — never a disposition change, never text extraction at drain.

## Not built, deliberately

Mac share-menu extension; workspace creation inside the extension; text/Scratch-Pad shares; background ingestion; share-time extraction or transcript fetch; any UI listing "recently shared" items (the Newspaper + seen-before already show them).
