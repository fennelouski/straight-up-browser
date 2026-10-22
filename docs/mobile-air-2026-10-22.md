# Mobile Browser — Air implementation and acceptance

Validated application code: `943b9150fe64df882aac328059c7aba532e34864` on `codex/mobile-air-20261022`. Later test/documentation commit `c2264ffa299c7d4e8ae1b6826cb5d336ee941beb` leaves application source byte-for-byte unchanged; its full build also passed. This work continues the original mobile commits `a9cacb0` and `2f0d772`; it does not replace their history. Source, implementation, builds and native testing were completed on the MacBook Air. The Studio was not operated.

The handoff archive from Nathan's Library was verified at SHA-256 `878b106cca36b6c1ac7a8218166e33fc1908288cb2f3f71f1c2d0f069a868ccf`; all 21 manifest entries, the bundle prerequisite, both commits and their trees matched. The original dirty Air checkout remained separate. No upstream is configured on the isolated mobile branch.

## Result and evidence

The final unsigned `Browser iOS` build-for-testing passed with the app and both test products. Xcode 27.1, arm64 Simulator, cached Sparkle 2.9.4, low priority and two Xcode jobs were used. Only one heavy operation ran at a time.

The consolidated iPhone 16 Pro / iOS 26.5 result is **40 passed, 0 failed, 0 skipped**: 23 native unit tests and 17 selected UI tests. The unrelated Newspaper cover/style UI method was excluded from this selected regression set. These are actual integrated app executions, not helper stand-ins. The earlier host-only policy/script suite separately passed 15 tests, including the previously unexecuted minimum-width correction.

Air workspace evidence, relative to the parent of this repository:

- `build-air/attempt-11/result.json` — successful full build, clean code commit above, owned process group ended.
- `build-air/final-acceptance/result.json` — final native invocation, successful exit and joined process group.
- `build-air/final-acceptance/summary.json` — structured 40-test result and exact Simulator identity.
- `build-air/final-acceptance/Tests.xcresult` — finalized native results, coverage and explicit synthetic screenshot attachments.
- `build-air/final-acceptance/attachments/manifest.json` — exported screenshot index.
- `policy-import.log` — the earlier 15-test host policy/script result on imported `2f0d772`.
- `MOBILE-AIR-CHECKPOINT.md`, `mobile-air-status.json` — continuation state and resource cleanup status.

## Requested behavior

| Feature | Implementation and native evidence |
|---|---|
| Stationary-edge snapping | Stable viewport coordinate space fixes the moving-view drag feedback. Real fixed-page-border acquisition from six points away settles to the border; scrolling does not move the placed bar. Existing bounded traversal and hysteresis policies remain in use. |
| X/Y position and width | Settings sliders, on-page movement and stored viewport-relative preferences remain. A real landscape test found safe-area-reduced measurement; the gesture-bar reader now spans its local window horizontally while placement stays inside safe insets. Rendered minimum width passes portrait and landscape. |
| Smaller idle circles | Source uses 28-point idle and 36-point navigation visuals. Native idle/navigation screenshots show the transition; outer rectangular targets are 48 points and pass native accessibility auditing. |
| Select URL on entry | A native address field selects once after gaining first-responder status. Actual replacement, continued typing, background/foreground continuity and reopening pass. Hardware suggestion arrows, Escape, Go, accessibility labeling and Dynamic Type font behavior are retained. |
| Suggestions | Existing local ranking and received-tab model data are used without a new sync path. Native synthetic records in another workspace appear when typed; private records and incognito-mode suggestions stay excluded, and nonmatching continued input removes stale results. |
| Safe-area colors | A bounded on-screen hierarchy capture supplies independent edge colors. The page-colored background fills the window behind the page. Premultiplied alpha is corrected. Actual screenshot pixels match authored red/blue values `(239,48,48)` / `(32,64,239)`, then green/yellow `(32,207,64)` / `(239,207,32)` after navigation and foreground return. Sampling pauses during suspension and refreshes after activation and size changes. No page images/colors are persisted by this feature. |
| Navigation animation and visual tabs | Existing Reduce Motion-aware page transition remains. An optional trailing-edge pan now opens Visual Tabs; native open/dismiss recovery and the permanent menu route pass. When enabled, the trailing edge belongs to Visual Tabs; Forward remains in Page Menu and leading-edge Back remains available. |
| Hide/show gesture | Native testing found the original target overlapped the sensor housing. The optional target now sits below the top circles or inside the sensor-side strip in landscape. Physical double-tap hide/show and permanent Page Menu recovery pass. |
| Domain rotation | Exact-host allow/lock/default rules remain local. Actual portrait locking, allowing landscape and resetting to the app setting pass. Domain changes do not request forced rotation or override system rotation restrictions. |

Additional native regressions cover discoverable top menus, phone split-command restrictions, full omnibar hit targets, safe disabled sync Settings and weather while typing above the phone keyboard. Weather uses an explicit local fixture city and makes no live service request.

## Isolation and lifecycle

The iOS scene now waits for the existing isolated WebKit startup wrapper before constructing browser views. Private test defaults flow through the scene and mobile code; isolated navigation preserves the existing page-script and network restrictions. Border sampling uses the permitted native isolated content world rather than disabling the actual sampler. Tests use unique isolated profiles, in-memory models/backends and fresh task-owned Simulator guests with tab/agent sync disabled. Synthetic received records do not invoke a sync client.

All application source changes are mobile-specific. No new account, credential transfer, key generation, provisioning change, physical-device install, upload, deployment or release publication was performed. The published Mac 2.9.34 release was left intact.

One intermediate test run completed its cases but stalled collecting verbose Xcode diagnostics. Only its verified owned collector was terminated after inactivity was established and then joined. Its incomplete bundle is not claimed as finalized evidence. Later runs use Xcode's documented `-collect-test-diagnostics never` option and retain normal logs and explicit attachments.

## Scope limits and continuation

Physical-device acceptance, manual VoiceOver use, system rotation-lock combinations and simultaneous iPad multi-scene behavior are not established by the phone run. The UIKit masks respect OS/device/windowing constraints; there is no forced domain-driven rotation. The optional gesture has menu and Settings alternatives.

A fresh iPad Pro 11-inch (M4) / iOS 26.5 guest also passed four focused smoke checks: native accessibility, address editing/background/reopen, minimum width across rotation, and edge-pan Visual Tabs. The initial edge test started at 99% of width, which was too far from UIKit’s edge-recognition band on the tablet. Test-only commit `9eceb610409585cd5c78ce11fb14dbbdaa1fc878` uses a fixed two-point inset and passed the tablet retest. Application source is unchanged from the consolidated 40-test code revision. The three initial passes and corrected edge pass are preserved separately in `build-air/tablet-smoke/` and `build-air/tablet-edge/`; this is not represented as one original four-case green run.

Continue only from this isolated branch or a verified source bundle. Keep one mobile owner, preserve the existing dirty checkout and released Mac history, and inspect the final checkpoint before starting a compiler or Simulator. No release action is part of this task.

## Reproducing the local page fixtures

Start `python3 scripts/serve-mobile-chrome-fixtures.py --state-file /tmp/browser-mobile-fixture.json` and keep that owned process running. It binds only `127.0.0.1`, prints its ephemeral URL and serves synthetic HTML with no external resources. Set the UI test runner's `MOBILE_FIXTURE_URL` environment variable to the printed `/fixture` URL. `/alternate` supplies the second color pair. Stop the server with Ctrl-C after the test run.

The domain-rotation and page-color lifecycle tests explicitly skip when this integration fixture is not configured. The 40-test Air run supplied it, executed both tests and had zero skips. Standard test launches therefore do not depend on an unrecorded service or attempt a real website as a fallback. The source-only handoff includes this helper.

## Completion checkpoint

The portable fixture guards and fixed two-point edge test were compiled in `build-air/attempt-13/` and then executed on the phone: `build-air/final-fixture-and-edge/summary.json` records **3 passed, 0 failed, 0 skipped** for domain rotation, exact-edge Visual Tabs, and strict page-color/navigation/foreground checks. The 40-test phone suite and four tablet smoke methods remain bound to the identical application source.

Both task-owned Simulator guests are shut down, the owned loopback fixture server has ended, and all build/test process groups have been joined. No coding or build blocker remains. Device/manual VoiceOver, system rotation-lock combinations and simultaneous multi-scene acceptance remain outside the verified matrix. The source-only delivery bundle preserves the original unpublished commits plus the Air fixes and this report; no app, cache, runtime profile, screenshot, credential or signing asset is included.
