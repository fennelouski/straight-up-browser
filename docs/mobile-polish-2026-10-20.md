# Mobile browser polish — source handoff

This is the existing universal `Browser iOS` target in `fennelouski/straight-up-browser`.
Its top menus and gesture capsule match the UI Nathan described. Work starts at
remote main `a90f9f7c7e1cfd2d9c5380a304f40dfbf34f1f0f` on isolated branch
`codex/mobile-polish-20261020`. The canonical checkout, its untracked design
principles, the other Browser worktrees and the installed Mac app were not edited.
No version, project, signing, entitlements, release or provider changes are included.

All nine items below have source changes. **None is certified as native runtime
acceptance.** Full iOS compilation and actual iPhone/iPad interactions remain pending.

| # | Acceptance checkpoint | Implementation and checked evidence | Remaining native acceptance |
|---|---|---|---|
| 1 | Snap near stationary borders without following page scrolling | Explicit bar placement acquires at 8pt and holds until 16pt away. Viewport edges plus stable, visible fixed horizontal page borders qualify. Two samples reject moving edges; sticky elements and transformed containing blocks are excluded. Tree traversal stops at 400 nodes / 12 ancestors / 24 edges. Policy and actual sampler-script tests pass. | Move near a synthetic fixed footer, scroll, animate a border, zoom and rotate. Snapping intentionally applies while moving, not as automatic page-driven repositioning. Page vertical borders are not sampled. |
| 2 | Move in both axes, persist width with a 30% floor | Settings → Mobile Controls provides normalized X/Y/width sliders and Move Bar on Page. Drag mode has a Done action and accessibility adjustment. Position is viewport-relative; width uses the local containing view before safe-area insets, then clamps to available safe-area and keyboard geometry. Legacy per-site edge placements remain when custom position is off. The initial clamp tests passed on a9cacb0; the corrected containing-width tests are added but not yet executed. | Measure the rendered bar at the minimum against its containing view width in portrait and landscape, then drag, relaunch, rotate, use a keyboard, test iPad window sizes and VoiceOver. |
| 3 | Idle circles are 8pt smaller in diameter | Visible circles are 28pt idle / 36pt in navigation; 44pt targets remain. Same control instances animate their diameter, with Reduce Motion respected. Actual helper API/typecheck passes. | Measure native idle/navigation appearance and hit frames at large text sizes. |
| 4 | Select the current URL once upon entry | Existing selection behavior is retained; repeated focus commands while already editing now preserve text and caret. Deferred initial selection is canceled if the overlay has closed. A functional UI regression is added. | Execute replacement-then-append UI test on the iOS target. |
| 5 | Local autocomplete, existing same-user sync, no private sources | Refines the existing cancellation-aware suggestion pipeline: open-tab titles/URLs, durable history titles, recency/frequency and bookmarks; canonical URL deduplication; credential-bearing URLs excluded. Incognito does not query this pipeline. No networking is introduced. Ranking, deduplication, private-source and cancellation tests pass. | Type quickly, switch sessions mid-request and choose results. Cross-device results are limited to records already received through opted-in same-account iCloud sync; history itself is local and sync can be delayed. This does not query all live instances or infer intent through a provider. |
| 6 | Independent top/bottom adjacent colors with fallbacks | Two separate 2pt WebKit strips, each rendered at width 32 into an in-memory average; no snapshots or colors persisted. Sampling debounces 250ms after load/scroll, uses a single sampler, rejects stale views and falls back to WebKit/system backgrounds. Helper API/typecheck passes. | Verify solid, gradient, dark, video/protected content, split panes and failed snapshots. A single safe-area fill cannot perfectly reproduce arbitrary gradients, video or inaccessible content; no perfect-every-page claim. |
| 7 | Navigation motion and a visual tab browser | A 0.98 page transform keeps existing WKWebViews alive, disabled by Reduce Motion. Visual Tabs has menu routes and optional bar-up gesture; existing web back/OS edges are unchanged. Current page preview is ephemeral; other cards use title/host fallback. Existing selection/close actions preserve identities. UI regression added. | Verify motion, scroll/back behavior, split panes, private/regular separation and VoiceOver. This is a card grid, not fresh screenshots of every background tab. |
| 8 | Optional hide/show gesture, always recoverable | Opt-in double tap in the gap between top controls. Page Menu always has Show/Hide Gesture Bar and Settings; Settings also has a Show toggle. Old bar long press still creates a tab. Recovery UI regression added. | Enable, hide, relaunch, recover by menu and accessibility, including landscape sensor-side layout. |
| 9 | Per-domain rotation with exact matching/reset | Exact HTTP(S) host rules: allow or lock while on the domain; lock captures the current interface orientation at entry, with an immediate Page Menu action. Per-scene URL context avoids applying one domain rule to every window. Individual/all resets are available. New domain rules only update supported masks and never request a rotation; the existing explicit app rotation menu retains its geometry requests. No private API or device-orientation forcing. Exact-host/reset policy tests and helper API/typecheck pass. | Verify supported phone/tablet orientations, navigation to subdomains, multiple scenes, system rotation lock and iPad windowing limits. OS policy remains authoritative. |

## Width review correction (21 October)

The coordinator found that a9cacb0 applied 30% after safe-area insets. The corrected
policy accepts the local containing view width explicitly, without global screen
state: a 390pt container now requests at least 117pt, including when its available
viewport is only 374pt. Landscape has a corresponding case. Available safe-area
containment wins only if there is physically insufficient usable width. Relevant
source, tests and this document changed. No compiler, tests or native execution
were run for this correction; the results below remain bound to a9cacb0.

## Actual validation (prior a9cacb0 only)

- `python3 scripts/verify-mobile-chrome-policy.py`: **13 tests passed, 0 failed**.
  This is an offline, single-job Swift package using the actual pure production
  policy/ranking sources, verbatim `HistoryVisit`, actual iOS test files and the
  actual sampler JavaScript in JavaScriptCore with synthetic DOM fixtures.
  It runs on the Mac host, not in the iOS app. First pass exposed a missing
  CoreGraphics import; that was fixed before the passing run.
- Swift 6 syntax parse: all mobile production/test files pass. Parsing is not
  typechecking or target compilation.
- Seven helper production files typecheck against the installed iPhone Simulator
  SDK with iOS 18 deployment and MainActor default isolation, in one compiler
  process. Explicit stand-ins cover Tab/favicon/profile/logger/history/download
  dependencies. This caught and fixed the WebKit async overload and accessibility
  action syntax. **BrowserView integration and the full Settings target are not
  covered by these stand-ins.**
- Three app UI regressions added: hidden-bar recovery, Visual Tabs menu access,
  URL selection once then appending. **Executed iOS app UI tests: 0.**
- No native runtime screenshots, simulator launches, phone installations,
  archives, uploads, publishing or main-branch integration were performed.

External evidence lives beside the checkout in `../mobile-polish-evidence/`:
`policy-tests-final.log`, `swift-parse.log`, `helper-typecheck-r2.log`, explicit
`helper-typecheck-stubs.swift` and `helper-typecheck-result.json` with input hashes.
The helper check required ordinary sandbox escalation for the compiler's SwiftUI
macro server; that completed successfully without changing system permissions.

## Pending build admission

The shared Studio coordinator record
`task-11/receipts/current-native-coordination-20261020.json` has no active native
owner/hold, but also no Browser admission. Its state is
`OVERNIGHT_APP_QUEUE_RECONCILED_NEW_EXECUTION_BLOCKED_BY_DESTINATION_MESSAGING_AUTHORIZATION`.
No denied coordinator message was retried and no alternate owner was activated.
The small source/policy checks above are complete. Full `Browser iOS` Xcode
builds, simulator unit/UI execution and visual evidence are **pending admission,
not failed app tests**; no such project build or runtime action was attempted.

The next admitted phase should first compile the actual iOS target without
signing, using task-owned DerivedData and the coordinator's resource bounds.
Then use a fresh task-owned simulator for the existing suite plus the three new
UI regressions and the nine checkpoints above. Do not merge this as a verified
mobile release until actual target compilation and acceptance are complete.

Supported platform references: Apple's
[WebKit snapshot configuration](https://developer.apple.com/documentation/webkit/wksnapshotconfiguration)
and [scene orientation preferences](https://developer.apple.com/documentation/uikit/uiwindowscenegeometrypreferencesios/interfaceorientations).
