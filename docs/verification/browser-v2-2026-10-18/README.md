# Browser v2 implementation verification

Development implementation on Nathan's authorized Mac Studio, 18 October 2026.
This record separates implemented source, executed tests, and native acceptance.
It is not installation or release approval.

## Source reconciliation

The local `fennelouski/straight-up-browser` checkout was exactly the reviewed
baseline `666bb5729a3a1e3797cceac6ad5e101f0d03f731`, version 2.9.32. The main
checkout's only untracked file, `APP_DESIGN_PRINCIPLES.md`, was read and preserved.
Implementation uses branch `codex/browser-v2-20261018` in an isolated worktree.
The former owner was idle and was notified of the replacement. MDX,
StandupStash, and video-build tasks were coordinated; Xcode builds use two jobs
and separate `/tmp` derived data.

The Library ZIP was retrieved using the supported transfer helper. Its 873,029
bytes hash to `fca35484f0902aeadec2a04f358507fcf3556402818d4a5a708f1d3473ccfda5`,
matching the authoritative handoff. See `planning-provenance.json`.

The baseline Command+N behavior, existing split-membership and tab-reordering paths,
ShortcutStore, onboarding, research workspaces, document providers, and per-window
WebViewManager were retained. A reconciliation discrepancy remains: the historical
2.9.28 handoff describes configurable Command+N, but this 2.9.32 baseline binds
Command+N directly to New Window and contains no newCommandDestination or
newCommandPresentation preferences. This task did not duplicate or silently
restore that historical implementation. Reconcile that separate revision before
any release claiming its configurable behavior. The historical 893-test result for 2.9.28 is not a test result for
this branch.

## Implemented scope

| Area | Source behavior |
| --- | --- |
| Page fades | Per-TabID/URL sliding inclusive two-second breaker; continued suppressed attempts; continuous visible-hour recovery; bounded session state; provisional/redirect reconciliation; generation/episode paint and timer guards; Reduce Motion and preference-off immediate reveal. |
| Window placement | Existing edge states followed by full-height centered half/third/quarter widths; actual source rational thirds retained; constraints skip infeasible states; pixel geometry, display fallback, normal-browser-window scope and native frame readback. |
| Shortcuts | Existing authoritative store extended with normalized comparisons, fixed-alias diagnostics, accessible issue popovers, exact default-restoration preview and per-command revision guarded Undo. Carbon replacement registers first, retains previous working registration on failure, and tracks failed cleanup. No system-wide scan is claimed. |
| Panes | Recursive layouts, stable typed tab/document references, five/eight-pane structures, minimum-size projection, compact preservation, center swap and edge placement, keyboard/list alternative, in-panel typed drag previews, Apply, layout Undo/Redo, local recovery. The complete new engine defaults off; disabling it retains all existing identities in nonrecursive geometry and cancels pending recursive mutations. |
| Saved layouts | Separate local versioned recipes; field-level saved/proposed Update diffs, prior revisions, stale-write checks, fresh cold starter tabs and manual meeting slots; runtime bindings stay in memory. Newly created safe starters use visible-only, two-at-a-time admission and exact navigation completion tokens. No URL-only live session merging or new CloudKit schema. |
| Settings | Original categories/order/selection/search and numbered navigation retained; measured complete labels and compact category fallback; window-scoped Escape/edit/IME/recorder/transient/dirty-close handling; tracked pilot-setting drafts. |
| Power Up | Searchable live-binding catalog, known/snoozed/suppressed state, safe sample practice, explicit opt-in bounded local aggregates and tested day/week/lifetime/privacy gates. Confirmed global omnibar presentation outside Browser, and validated nonprivate pane Apply/Save outcomes, donate success. |
| Conversational Settings | Optional local-rule guidance with a four-setting typed catalog, strict structured suggestion validation, question-only mode, app-owned diffs, stale/draft/ABA/revocation checks and a testable Apply/Undo transaction engine. Native production cards link to manual controls while the durable writer is unverified. |

## Deliberate unavailable paths

- **Production assistant Apply/Undo: pending.** The existing UserDefaults adapter
  cannot attest durable operation outcome reconciliation or reliable tracking
  of every external writer. `supportsRecoverableCommit` is false. The reviewed
  plan (`assistant/review.md`, finding 3) explicitly requires: “Adapters without
  a proven path must withhold Apply.” Previews do not write. Completing a durable
  native writer and its crash/outcome tests is a technical dependency, not an
  unanswered user authorization request.
- **Remote model and external Settings agent: pending.** No new provider request,
  credential, authenticated pairing, private-value transport, or Apply endpoint
  was introduced. Narrow Settings descriptors are denied before broad legacy
  grants; unknown CLI tools/actions fail closed. The legacy 53-tool BrowserOS
  and 56-tool local profiles stay intact.
- **Unsolicited contextual teaching: pending.** Eligibility is modeled/tested,
  but display waits for a complete real safety snapshot. Static search and
  sample practice remain usable with donation off. Other features do not infer
  successful learning from mere keypresses.
- **Pane behavior adaptations:** dragging stages a final preview followed by
  separate Apply. Layout Undo keeps all newly created tabs, including blank
  ones; reliable pristine-state detection is not implemented, so no user work
  is guessed disposable. Spatial target navigation and temporary maximize
  preserve the structural layout. Native hover-preview/interaction parity
  still needs acceptance testing.
- **Cold-loader verification:** focused and nonfocused startup, interaction-state
  restoration and preview warming obey the new starter boundary. Undo, workspace
  and rollout changes cancel pending starts while retaining actual in-flight
  loads. Saved-page retries use the same budget; explicit new browser navigation
  is a separate user action. Model tests and source review cover these rules;
  actual WebKit timing, download, disposal and visibility races remain a native
  acceptance dependency.
- **Optional calendar/context suggestions and cross-window session transfer:**
  not enabled. No calendar, screen, microphone, or other-app access was added.

## Executed source tests

The standalone source checks, including reruns after policy changes, passed
**124 Swift tests**: motion/placement 30, Settings/actual policy/CLI 28, Power Up
14, pane/restore model 42 (22 pane and 20 scheduler), shortcut/registration 10.
Parameterized Settings inputs execute additional cases within that test count.
These harnesses compile production source and the corresponding repository tests;
the scripts state any omitted app-dependent integration or declared settings
fixture. They do not launch Browser or register a real global hotkey.

Reproduce from this worktree with the five bounded commands:

```sh
./scripts/verify-browser-v2-motion.sh
./scripts/verify-browser-v2-settings.sh
./scripts/verify-browser-v2-powerup.sh
./scripts/verify-browser-v2-panes.sh
./scripts/verify-browser-v2-shortcuts.sh
```

Static model-review verification, its six Python tests, release policy, security
policy, and whitespace checks passed. No release or live-provider review is
claimed. See `test-results.json`, the five test logs and `static-checks.log`.

## Compile checks and cleanup

All four final compile-only commands exited zero with warnings treated as errors:
macOS unit-test bundle, macOS UI-test bundle, Apple Silicon macOS Release and iOS
Simulator Release. Every check compared the same 339-file source manifest before
and after compilation; no source changed. The app and CLI helper also passed the
Apple Silicon architecture gate. The repository helper phase uses an ad-hoc
signature; inspected metadata has no certificate/team identity. No distribution
signing or app launch occurred.

See `build-results.json` for exact commands, exit codes and log paths,
`source-manifest.json` for SHA-256 values and `macos-binary-receipt.json` for the
compiled executable hashes. The first final test-bundle attempt exposed a missing
SwiftUI import in a new test fixture; that import was corrected and all four
checks then passed. It changed no production behavior.

Repository `verify.sh` requires removing temporary app products to avoid shipping
bundle-ID LaunchServices conflicts. Cleanup unregistered and removed only the
three task-owned `/tmp` product trees' apps/aliases; production was untouched.
Compiled objects and diagnostics remain. `build-app-cleanup.json` records exact
paths and the guarded in-tree Sparkle-symlink cleanup continuation. Raw logs stay
in the task output directory; repository log copies trim trailing whitespace.

## Native evidence boundary

The baseline XCTest invocation compiled but Xcode's LaunchServices test-host
launcher aborted with `Assertion failed: childPID > 0` (exit 134). No full hosted
suite pass is claimed. The task also identified native screen control as failing.
The original visual defects were therefore not reproduced on the running app.
The repository's complete `verify.sh`, hosted coverage gate, UI execution and
Thread Sanitizer were not completed. The implementation is not release-qualified.

Actual running-app screenshots, keyboard/IME/VoiceOver traversal, two mixed-scale
displays, full-screen/Stage Manager, real Carbon registration, live capture,
30-minute/100-action two-party calls, screen sharing and unsaved-document
continuity remain **unobserved**. Native latency, frame-rate and retention-memory
budgets are also unmeasured. Object identity, unit tests and compilation
are not evidence of uninterrupted media. The default-off engine gate covers
rendering, migration/recovery writes, expanded membership, resize, Apply,
Undo/Redo and maximize. Legacy two-to-four-pane geometry and resizing remain
available without it. Native validation of enablement, revocation during a drag,
retained layouts and restore scheduling is still required before release.

## Review

An independent source reviewer checked the implementation against the package,
including transaction/policy boundaries, meeting URL persistence, native view
ownership, compact projection, fade eligibility, memory eviction, shortcut
rollback, input-layout assumptions and Settings lifecycle. Findings were sent
to owners and corrected in batches. The final review is in `review.md`, with its source fingerprint in
`reviewed-source.json`; exact executed tests and compiles are recorded alongside it.

No production Browser installation, app restart, distribution signing, external deployment,
paid external services, credentials, system permission changes, or persistent access
grants were performed.
