# iPad conditional rotation-lock fix — Air, 2026-10-22

Application implementation: `e5638ae9cbdb49bca8413013f153286054541d1e`. Latest built test harness: `013c8cb42fedaad65211ff113305b62fbb8021f3`. Application files are identical between those commits. Work remains on the isolated `codex/mobile-air-20261022` branch. All work and tests ran on the MacBook Air; Studio was not operated.

## Problem and change

The earlier strict iPad probe showed that supplying orientation masks did not stop the window rotating. That failed result remains finalized in `build-air/ipad-additional/Tests.xcresult`, with its source in commit `81d03a9` and summary in the earlier Library acceptance handoff. It has not been overwritten or reclassified as a passing test.

On iPadOS 26 and later, a small UIKit root container now retains SwiftUI's existing hosting controller as its only child and implements `prefersInterfaceOrientationLocked`. It forwards status-bar, home-indicator and gesture-edge preferences to the original content. The scene configuration, model container, SwiftUI commands, storage, release metadata and phone host remain unchanged. Root installation happens once per window, without private hosting classes or method replacement. Its observer is scoped to the owning scene and removed when the container is deallocated.

Domain rules resolve through the existing controller. A locked rule requests the conditional scene lock; allow releases it; removal returns to the app setting. Updates invalidate UIKit's preference. Domain navigation never forces a geometry change. On activation, the owning UIKit scene reasserts the preference without depending on WebKit already being attached.

Explicit app orientation choices retain their existing geometry request. The conditional lock is temporarily released if that request needs a different orientation. When UIKit denies it, the active scene re-locks the orientation UIKit actually granted. The phone and older iPad path continue to use their existing orientation masks, without installing the new container or calling the new preference API.

## Platform distinctions

Apple's conditional lock is eligible only for an appropriately positioned, screen-sized, unobscured scene. It can be released while the app is suspended or system UI makes the scene ineligible. Re-entry must lock the newly granted orientation; it does not guarantee the old screenshot's geometry. The API also does not promise a forced orientation target. See [Apple TN3192](https://developer.apple.com/documentation/technotes/tn3192-migrating-your-app-from-the-deprecated-uirequiresfullscreen-key) and [orientation-lock preference](https://developer.apple.com/documentation/uikit/uiviewcontroller/prefersinterfaceorientationlocked).

The owned iPad Pro 11-inch M4 / iOS 26.5 Simulator returned UIKit geometry-request-denied code **101**, including for an explicit portrait request while landscape. The app then remained landscape and successfully blocked a subsequent rotation attempt. The report records the requested target as **not honored**, separately from the passing active lock. It does not claim the system can be overridden, that geometry stayed fixed while suspended, or that this is physical-device acceptance. No `UIRequiresFullScreen`, windowing, system rotation-lock or privacy setting was changed to obtain a pass.

The current build still declares multiple scenes disabled, and native runtime inspection confirms one connected scene and `supportsMultipleScenes=false`. No simultaneous scene was enabled or forced. Manual VoiceOver remains pending; earlier native audits are not spoken-navigation tests. Physical-device and system rotation-lock combinations remain unverified. Resized/occluded-scene behavior is subject to UIKit's documented eligibility; an exhaustive hardware/windowing matrix was not performed.

## Strict iPad acceptance

The final `build-air/ipad-rotation-verified/` run is **5 passed, 0 failed, 0 skipped** on the owned iPad / iOS 26.5 guest. It includes the live native host/mask/precedence test plus four UI methods: strict conditional locking, URL editing/background continuity, safe-area color/navigation/foreground checks and trailing-edge Visual Tabs. `build-air/attempt-22/` is the successful unsigned build, using cached dependencies, two jobs and low priority. The passed 40-test phone suite was not repeated unchanged.

The strict test observes actual app geometry and holds inverted expectations against forbidden active rotations. These are the recorded outcomes:

| Case | Actual result |
|---|---|
| App portrait lock, device turned landscape | Remained portrait, 834 × 1210 |
| Domain Allow over app lock | Rotated landscape, 1210 × 834 |
| Domain Lock captured in landscape, device turned portrait | Remained landscape, 1210 × 834 |
| Foreground return after suspension | UIKit granted portrait; subsequent rotation was blocked, 834 × 1210 |
| Reset domain to app lock after system menu | UIKit granted landscape; subsequent rotation was blocked, 1210 × 834 |
| App Unlocked | Rotated landscape |
| Explicit app portrait request from landscape | Target refused; remained landscape, recorded as not honored |
| Rotation attempt after that refused request | Remained locked in granted landscape |

The JSON attachment is `build-air/ipad-rotation-verified/attachments/3BB68B29-C1F5-413D-9798-7D0E816DC377.json`. Native screenshot attachments remain local to the workspace and are excluded from the Library source handoff. Coarse isolated-test diagnostics in `build-air/orientation-trace.log` record only orientation/policy/activation/lock fields, without page data. They require explicit isolated UI-test flags and do not run for normal browsing.

Earlier focused containment tests also passed native accessibility and portrait/landscape minimum width in `build-air/ipad-lock-strict/`; that intermediate run still failed the background assumption and is preserved as **5 passed / 1 failed**, not a successful final suite. Subsequent lifecycle probes and corrected system-geometry expectations are retained alongside it. No failed result has been erased.

## Compatibility and recovery

The current iPhone 16 Pro / iOS 26.5 run `build-air/phone-rotation-compatibility/` is **2 passed, 0 failed, 0 skipped**. The native test confirms the existing phone host remains in use, and the actual portrait lock → domain allow → app-default reset UI sequence passes. This is focused phone regression evidence for the current application, not a repeat of the earlier 40-test suite.

The installed iPadOS 18.5 runtime was checked in a fresh isolated iPad guest `ADC6982B-CA66-4C6C-A01A-6B2834904EC8`. `build-air/legacy-ipad-availability/` finalized with **0 passed, 2 failed, 1 skipped**. The iPadOS 26-only strict test explicitly skipped for API availability. The application itself could not start: dyld could not load `/usr/lib/swift/libswiftWebKit.dylib`, and the address test subsequently timed out. `linked-libraries.txt` and `webkit-undefined-symbols.txt` preserve the dependency evidence. The native fallback policy did not execute, so no older-runtime behavioral pass is claimed. The new API is availability-gated and the build targets iOS 18, but source/build gating alone does not prove runtime acceptance. Only Xcode 27 is installed on this Air. The minimal next step for iPadOS 18.5 acceptance is a compatible SDK/back-deployment setup; no library-copy, weak-link workaround, toolchain installation or Studio access was attempted.

The minimal remaining acceptance is manual VoiceOver and separately authorized physical-device/system-lock testing. The conditional API remains subject to system eligibility. No source, Air-access or signing blocker remains for this fix. No physical-device app install, credential access/transfer, app upload, deployment or release publication occurred; published Mac 2.9.34 is intact.

All three task-owned Simulator guests are shut down. The synthetic loopback server and coarse orientation trace are stopped; owned build/test process groups have ended. `build-air/owned-guests-final-state.json` records the final booted-device inventory. Source-only recovery handoffs contain no application binaries, caches, profiles, screenshots or credentials. Earlier source handoffs remain intact; the new handoff preserves the fix commits, failed probes and finalized textual evidence.
