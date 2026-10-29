# Page-fade notification boundary correction

Source candidate: `ca6c7033b5da96750377483a4ce37d4225bc5b04`, incorporating
the preserved Air candidate `63702ebb7f658867d419464e86acf4c5ed6d532f` and the
previously reviewed Browser v2 source `f7e29c918ad28e70d9fd5cff547a3409029decfb`.

## Failure and resulting behavior

The Air native suite reproduced a real crash when the runtime sync actor saved
settings: NotificationCenter invoked the page-fade Objective-C selector on the
posting background thread, triggering Swift's MainActor executor assertion.

The three selector entry points are now nonisolated. They extract immutable
visibility/suspend/resume values into a Mutex-protected inbox. Main-thread
notifications drain synchronously under a checked MainActor boundary; background
notifications schedule a weak-manager block on the serial main dispatch queue.
The inbox drains earlier background events before a later synchronous main event,
so a delayed suspend cannot overwrite a newer resume. A reentrant notification
stays behind the current batch. No Notification payload or WebKit object crosses
the boundary. Only the MainActor drain touches fade state or native views.

## Regression coverage

Five native tests cover an actual visibility update after a background Defaults
notification, synchronous sleep/wake completion, repeated background pairs, mixed
background/main ordering with independent suspension reasons, and manager release
while delivery is pending. The visibility test observes the existing offscreen
WebView being revealed and retaining its identity. Completion uses a main-queue
barrier rather than an arbitrary yield. Synthetic sleep/wake notifications invoke
only the manager's Objective-C selectors, avoiding unrelated application observers.
The WebView fixture uses a nonpersistent store and performs no navigation.

Three standalone inbox tests cover ordered once-only batches, events arriving
during batch processing, and loss/duplication under concurrent producers.

Studio executed 147 source tests: motion/inbox 33, Settings 48, Power Up 14,
panes/scheduler 42, shortcuts 10. Six Python model-review tests, release/security
policy checks, live public-provider review and whitespace validation passed.
See `source-checks.json` and the checked-in logs. On the exact source candidate,
the Air owner reports the native Browser suite passed: **1,061 passed, zero
failed, two skipped, 1,063 total**, with **40.59% app coverage** against the 25%
gate. This includes all five functional lifecycle and three inbox tests. Xcode
27.1 compiled and executed the Objective-C invocation and manager-lifetime
regressions successfully. The final nonforeground `verify.sh` pipeline physically
joined with exit zero: iOS Release, arm64 macOS Release, the Apple Silicon
architecture gate and macOS UI test-bundle compilation all passed on the same
candidate. See `native-and-build-checks.json` for the Air owner receipt and
390-file build-input fingerprint. Actual UI execution remains a separate local
deployment gate and is not claimed here. These native results are not inferred
from the standalone tests.

## Source reconciliation and review

The Air's preserved configurable New command, pane movement, frame-scoped
credential runtime and isolated fixtures remain included. The owner reviewed
their final changes against remote `main`, including actual WebKit frame/origin
and document-token checks, private-tab saving guards, customized shortcut
separation, session inheritance and preserved pane focus. Xcode project updates
do not expand entitlements or grant new access. Review provenance and the 24
changed Swift app/test file fingerprint are in `reviewed-source.json`.

The recursive pane engine remains default off. Native conversational mutation
remains theme-only, with external Settings pairing denied and question/status
reads remaining pure. No credentials, browser profiles, session rollback data,
production app bundles or external publication assets are part of this source
integration. Actual live-call, accessibility and performance acceptance remains
separate from source tests and compilation.
