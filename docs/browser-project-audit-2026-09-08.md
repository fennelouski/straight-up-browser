# Browser project audit, 8 September 2026

Built and exercised the original audit checkout, `864d07f`, on macOS and iOS simulators. The audit
found and fixed launch, concurrency, search, layout, and accessibility defects.
This is a broad verification pass, not a claim that every website, device, or
account-dependent integration is flawless.

## Initial audit results

| Check | Result |
| --- | --- |
| macOS unit/integration tests | 561 passed after the polish follow-up |
| macOS app coverage, initial audit | 42.40%; required minimum 25% |
| macOS UI tests | 9 passed; Downloads permission test reported separately below |
| iOS unit tests | 6 passed |
| iPhone 17 Pro UI tests, iOS 26.5 | 4 passed |
| iPad 11-inch M5 UI tests, iOS 26.5 | 3 passed; 1 iPhone-only check skipped |
| macOS Debug development app | Built, signed locally, launched, and reopened |
| macOS Release app | Built for Apple Silicon with warnings treated as errors |
| iOS Release app | Device and simulator builds passed, with warnings treated as errors |
| CLI | Built with Swift 6 and warnings as errors; help and live commands exercised |
| Repository gates | Release policy, security policy, architecture validation, and diff checks passed |

The Mac suite covers tabs, history, windows, browser chrome, autofill, permissions,
provider adapters/transports, MCP trust/OAuth, agent scheduling and run groups,
history recovery/deletion, memory, observability, file transactions, Newspaper,
developer tools, WebKit signals, and page expansion. Mobile checks cover shared
contracts, address-bar interaction, menus, settings, and device-specific controls.

## Fixes

- **Launch/reopen crash:** replacing an already-created titled AppKit frame could
  dereference a freed `NSThemeFrame`. The browser now starts with SwiftUI's plain
  window style. The existing AppKit bridge supplies keyboard activation, resizing,
  accessibility window identity, corners, and placement without replacing the frame.
- **Development app replacing itself:** Sparkle installed the published release
  over a test bundle, invalidating code coverage. Debug and test launches no longer
  start the updater; normal release launches retain updates.
- **Agent startup race:** a second caller could start a conversation while history
  recovery was still deleting empty conversations. Callers now await the same
  recovery task. A regression test failed before the fix and passes afterward.
- **Search corruption:** literal `&`, `+`, `=`, `?`, and `#` are escaped as query
  data. Mac/iOS omnibars, CLI searches, and Shortcuts share the encoder and honor
  the selected search engine. Tests round-trip Unicode and punctuation for all
  four supported engines.
- **Narrow windows:** the address field and Find bar can shrink. Tab overview
  chooses columns from its available width; vertical keyboard movement
  follows that column count. Cards are accessible buttons, and reduced-motion
  settings suppress animated scrolling.
- **Competing overlays:** opening tab overview dismisses the address bar. External
  links, CLI navigation, and Shortcuts dismiss the address bar after accepting a URL.
- **Mobile dismissal and touch targets:** the address bar has an explicit close
  button. Its close, tabs, and bookmark icons expose actual 44-point hit regions.
- **Control names:** the default-browser prompt's close button and the Agent
  toolbar, Send, and Stop controls have action labels for assistive technology.
- **Settings sizing:** removed a conflicting second window-resizability modifier.
- **Test timing:** page-expansion tests now use the shipping WebKit settle interval;
  their previous 20 ms interval could finish before real scroll events were handled.

## Visual polish follow-up

- Preview-card thumbnails now stay within the sidebar and overview cell width,
  regardless of their aspect ratio. Selection, drag-target, and new-tab glow
  borders draw inside their shapes so clipping cannot remove half the stroke.
  A rendered-image regression test failed before the fix and now checks all four
  selection edges with landscape, very wide, and portrait thumbnails.
- Split-pane focus uses a rounded outline above the page. It follows window
  resizing and pane selection, clears when leaving split view, and lets clicks
  through to the page. Its corners remain visible at the rounded window edge.
- Compact sidebars use a native More Tab Actions menu instead of overlapping
  toolbar icons. Wide sidebars retain the current toolbar. The UI regression check
  verifies an 80-point sidebar, its menu actions, and opening/closing visual tabs.
- Preview cards omit a redundant domain caption when the title already shows
  that domain.

Inspected populated preview cards and tab overview in light and dark themes,
compact and wide toolbars, and the split outline in a 480-point window.
The release pull request includes before/after screenshots. Local screenshots
remain with the result bundles described below.

## Hands-on UI coverage

Inspected all twelve Mac settings panes: General, Agent, Shortcuts, Autofill,
Content, Newspaper, Downloads, Screenshots, Appearance, Security, Memory, and
Privacy. Their navigation and expected controls are covered by the expanded UI test.

Used a local article/form page in the running development browser to exercise
page loading, links, back/forward navigation, new/close tabs, form typing and
submission, DOM reading, page capture, bookmarks, history, Find matching, reader
mode, tab overview, two-page split view, and the Agent panel. Inspected 480-point and larger Mac
windows, plus iPhone and iPad layouts. The Find bar and tab overview fixes were
checked again at 480 points.

## Remaining verification boundary

**Saving a download to the system Downloads folder is not verified on this host.**
The added UI test reached `WKDownload` destination selection, then the app blocked
inside WebKit's sandbox-extension request. The captured stack ends in
`__WAITING_ON_APPROVAL_FROM_SANDBOXD__`; the test timed out before the file appeared.
The same test is retained as an opt-in check. After granting Downloads access to
the exact test app, set `BROWSER_TEST_DOWNLOADS=1` in the Xcode test scheme,
or prefix the shell verification command with
`TEST_RUNNER_BROWSER_TEST_DOWNLOADS=1` so `xcodebuild` forwards it to the test
runner. Run `testLocalPageDownloadCompletesAndAppearsInDownloads`. Its assertions check
the saved bytes and the Downloads UI, and its temporary files are cleaned up.
This blocked check is excluded from the passing totals above.

CloudKit synchronization across devices, live paid AI providers, account-based
extensions, camera/microphone permission flows, signed distribution/updater
installation, physical iOS devices, every rotation/text-size combination, and
long-duration resource stress still need their corresponding accounts, devices,
permissions, or release environment. Passing unit tests is not live-service sign-off.

## Reproduce and inspect

- `./script/build_and_run.sh` builds and opens a separate development bundle and
  sandbox. The project Run action invokes it. `--ui-testing` uses temporary tab data;
  `--logs` streams that development executable's logs.
- `RUN_UI_TESTS=1 RUN_IOS_UI_TESTS=0 ./scripts/verify.sh` runs the Mac gates and the
  iOS compilation gate. The Downloads UI check is opt-in as described above.
- `./scripts/verify-ios.sh` runs the mobile gates. Select available devices with
  `IPHONE_SIMULATOR_ID` and `IPAD_SIMULATOR_ID`; this machine used separate audit
  simulators instead of the older simulator defaults in the scripts.
- Result bundles are under
  `~/Library/Caches/straight-up-browser/audit-0bc2/`.
  `macos-polish-final.xcresult` contains the 561 passing Mac unit checks and
  `macos-polish-ui-final.xcresult` contains the nine passing Mac UI checks;
  `macos-ui-tests.xcresult` retains the permission-blocked download attempt.
- Screenshots and logs are retained under that directory's `evidence` folder.
  The download stack trace is `download-sandbox-spindump.txt`.

## Release integration

The release candidate incorporates these fixes into `9ca8bfa`, Browser 2.6.12,
build 94, and increments the Mac version to 2.6.13, build 95. It preserves the
newer release's document panes, contextual tab labels, live previews, sidebar
actions, saved window placement, and window snapping. The shared pane outline
also covers document panes. The newer release already included the startup
recovery race fix; the audit adds a regression check for it. Settings sidebar
cards now expose one accessible action per pane, and the compact toolbar remains
visible down to the 80-point sidebar width.

The release checks use `~/Library/Caches/straight-up-browser/release-2.6.13/`.
The Mac verification script passed all gates: 729 unit tests, 40.82% coverage
against the 25% minimum, nine UI tests, the iOS Release compilation check, and
the arm64 Mac Release build. One Downloads permission test remains explicitly
skipped for the reason above.

The first iPhone and iPad 26.5 close-button checks each found a tap that left
the address bar open. Focused instrumented runs showed no repeated presentation;
the exact intermittent cause was not established. The toolbar now keeps one
set of buttons while switching between horizontal and vertical native layouts,
with 44-point targets. Tests require dismissal after one tap and do not retry it. The original
two-test order then passed twice on each device: eight executions, zero
failures, with diagnostic instrumentation removed.

The iOS 18.5 unit-test host aborted before launch because that Apple simulator
runtime misplaced `libswiftWebKit.dylib`. The failure matches
[WebKit bug 293831](https://bugs.webkit.org/show_bug.cgi?id=293831). Verification
uses the corrected iOS 18.6 runtime without changing app linkage, reducing
supported APIs, or raising the iOS 18.0 deployment target.

The iOS app follows its own version, signing, physical-device, and App Store
acceptance gates in `IOS_DEPLOYMENT.md`. Simulator results do not replace those
gates.

On the iPhone SE, iOS 18 renders the settings section header in uppercase and
places the open Tabs menu over the screen's center. The UI tests now compare
the heading without case sensitivity and dismiss the menu at an outside point,
waiting for it to close before opening the next menu. No app behavior was
changed for these two test assumptions.

### Final mobile release checks

| Runtime and device | Unit tests | UI tests |
| --- | --- | --- |
| iOS 18.6, iPhone SE (3rd generation) | 7 passed | 5 passed |
| iPadOS 18.6, iPad mini (A17 Pro) | Shared iPhone suite above | 4 passed; 1 iPhone-only skip |
| iOS 26.5, iPhone 17 Pro | 7 passed | 5 passed |
| iPadOS 26.5, iPad Pro 13-inch (M5) | Shared iPhone suite above | 4 passed; 1 iPhone-only skip |

Both complete `verify-ios.sh` runs passed, including their device and simulator
Release builds and bundle-contract checks. Results are in `ios18.6/` and
`ios26/` under the release cache, with `verification-summary.json` recording the
final counts. Earlier failed attempts remain in separate folders.

### Distribution prerequisites

This host currently lacks the Developer ID Application certificate and private
key, the `notary` Keychain profile, and the existing Sparkle EdDSA signing key.
The documented signed/notarized DMG and appcast cannot be published until those
are restored. The Sparkle key must retain the existing public-key identity.
App Store Connect is not authenticated, and the required physical-device and
private-CloudKit acceptance checks are still outstanding. No mobile build number
has been guessed or uploaded.
