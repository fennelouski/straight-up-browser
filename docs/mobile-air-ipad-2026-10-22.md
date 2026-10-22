> Historical checkpoint: the later [conditional iPad rotation fix and final focused results](mobile-air-ipad-rotation-fix-2026-10-22.md) supersede the pending iPad enforcement status below. Its original test counts and failures are preserved.

# Additional iPad acceptance — 2026-10-22

This follow-up ran entirely on the existing task-owned MacBook Air iPad Pro 11-inch (M4) / iOS 26.5 Simulator (23F77). No production application source changed from validated commit `943b9150fe64df882aac328059c7aba532e34864`. New tests were built at `81d03a9fc7156477ce41bab263418f99837877d5` and `141d750e1fcb470dc3ba835bfa451d8d9e9389d7`. The passed 40-test phone suite was not repeated.

## Findings

**The native orientation policy passes, but iPad windowing does not enforce its app/domain masks in this configuration.** This is a remaining acceptance limitation; control usability is not evidence that the lock worked.

The live hosted native test passed all five app masks (unlocked=30, portrait=2, upside-down=4, landscape-left=16, landscape-right=8), domain allow overriding an app lock, capture-current lock overriding app selection, exact-host context changes and removal returning to the app setting. This tests the integrated controller against a real connected scene, not rendered geometry or the system rotation-lock switch.

An initial strict UI probe expected portrait lock to block landscape and failed. Its finalized result remains in `build-air/ipad-additional/Tests.xcresult`: **1 native pass, 1 UI failure, 0 skips**. The follow-up characterization explicitly records lock enforcement separately from layout usability. It passed **1 UI test, 0 failures, 0 skips** in `build-air/ipad-windowing/Tests.xcresult` and produced these observations:

| App/domain setting | Requested outcome | Rendered outcome | Interpretation |
|---|---|---|---|
| App Portrait; device landscape | Portrait | 1210 × 834 landscape | Lock not enforced |
| Domain Allow over app Portrait | Landscape | 1210 × 834 landscape | Rotation permitted |
| Domain Lock captured in landscape; device portrait | Landscape | 834 × 1210 portrait | Domain lock not enforced |
| Domain reset to app Portrait; device portrait | Portrait | 834 × 1210 portrait | Reset route usable; same device orientation |
| App Unlocked; device landscape-right | Landscape | 1210 × 834 landscape | Rotation permitted |

In every case Page Menu remained hittable and the gesture-bar accessibility frame stayed inside the app window. Local fixture screenshots were inspected and retained only as workspace test evidence. They are excluded from the Library handoff.

The built app declares `UIApplicationSupportsMultipleScenes = false`; the running app reports `supportsMultipleScenes=false` and exactly one connected scene. Simultaneous Browser scenes therefore cannot be exercised with this app configuration. No second scene was forced, no manifest changed and no multi-window support was claimed. This is an app capability limit, not an Air access denial.

The running app reports `UIAccessibility.isVoiceOverRunning=false`. No manual VoiceOver session was possible without enabling a setting. No settings or permissions were changed. The earlier automated native accessibility audits remain valid; they are not manual spoken-navigation acceptance. The available `simctl` command/UI-option inventories expose no system rotation-lock operation. The system lock was neither read nor changed, and physical-device lock combinations remain pending.

## Platform interpretation and minimal next steps

Apple documents that multitasking affects orientation constraints. Its iPadOS 26 orientation-lock preference is conditional on a centered, screen-sized and unobscured scene, and is not guaranteed. The current controller supplies orientation masks and does not implement that newer view-controller preference. The observed iPad failure therefore remains explicit rather than being generalized into a Simulator-only defect or a real-device result. See [supported orientations](https://developer.apple.com/documentation/uikit/uiviewcontroller/supportedinterfaceorientations) and [Apple TN3192](https://developer.apple.com/documentation/technotes/tn3192-migrating-your-app-from-the-deprecated-uirequiresfullscreen-key).

The next code step, if iPad lock enforcement is required, is a narrowly scoped UIKit hosting integration for `prefersInterfaceOrientationLocked` on iPadOS 26+, followed by the strict full-screen probe and a resizable-window check. It must preserve older-system behavior and system authority; changing `UIRequiresFullScreen` is not a workaround performed here. This follow-up was scoped to acceptance, so that new application lifecycle integration was not introduced. Enabling multiple Browser scenes would likewise be a separate product capability change before simultaneous-scene acceptance. Manual VoiceOver and hardware/system-lock acceptance need a user-enabled session or authorized physical-device test, neither of which was requested here.

## Evidence and cleanup

Paths are relative to the parent of this repository:

- `build-air/attempt-14/result.json`, `build-air/attempt-15/result.json`: successful two-job, low-priority unsigned builds; ended/joined groups.
- `build-air/ipad-additional/summary.json`, `tests.log`, `built-app-capabilities.json`: original strict result, runtime masks, scene count and inactive VoiceOver.
- `build-air/ipad-windowing/summary.json`, `tests.log`, `attachments/manifest.json`: follow-up result and exact screenshots/JSON observations.
- `build-air/ipad-additional/simctl-supported-commands.txt`, `simctl-ui-options.txt`: supported automation inventory, no system rotation-lock control.

The iPad guest is shut down, the loopback-only fixture server is stopped and both test groups ended. The phone guest stayed shut down. No Studio operation, physical-device install, account, credential transfer, system/privacy setting change, app upload or publication occurred. There was no approval-review denial or uncertain operation. A sandbox loopback bind initially failed before starting; the authorized elevated fixture launch subsequently succeeded and was stopped cleanly.
