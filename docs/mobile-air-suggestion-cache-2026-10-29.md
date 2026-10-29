# Mobile Browser — suggestion-cache source correction, October 29

This bounded increment resumes the existing sole-owner mobile branch `codex/mobile-air-20261022` from clean checkpoint `2c8a1dcf21efd3ad430aeb0ad5890c6148a81169`. It does not resume A440, Elemental or Fendoku. The original mobile freezes and October 22 acceptance/recovery evidence are preserved. No new task, worktree, descendant, automation or replacement loop was created.

## Source defect and correction

Before this change, `BrowserView_iOS.suggestions` returned `cachedSuggestions` whenever the omnibar was visible and its text was nonempty. `refreshSuggestions()` deliberately waits 100 ms and then computes local results. Changing text resets the selected index but does not invalidate those displayed cached rows. Therefore, after results for query A have arrived, typing query B and pressing Down/Return during its debounce can select a row belonging to A. The result-application guard prevents a late result replacing a different query, but does not prevent an already cached row being presented or selected. This is a source-level control-flow finding, not a newly executed UI reproduction.

The cache now carries an immutable `MobileSuggestionRequest`: query, selected tab ID, editor-entry UUID, data revision and private state. Both `.task(id:)` and the displayed snapshot use the same request identity. A snapshot exposes rows only for its exact eligible current request, so stale rows disappear before replacement results are ready. The final async publication guard also checks the full request, protecting close/reopen with identical text and data refreshes. Selection indices reset on snapshot replacement rather than carrying an index into a different result set.

Ranking, existing data sources, HTTP(S)/credential filtering, private-source exclusion, sync opt-in and persistence are unchanged. The change introduces no service, network request, sync/privacy access, account or security-setting operation. The request/snapshot values are in memory. Weather-query handling and existing once-on-entry URL selection remain intact.

## Focused regression source

Five new `MobileSuggestionSnapshotTests` cover:

1. Query A rows cannot appear for query B while its lookup is pending.
2. Switching tabs, losing the selected tab, or reopening the same text in a different editor entry invalidates old rows.
3. A data revision cannot expose an older request's result set.
4. Closed/empty and whitespace-only editor requests cannot expose cached rows.
5. Private editors cannot expose either regular snapshots or an accidentally populated private snapshot.

The existing offline policy runner now accepts `--filter`. It still copies the actual production files and existing test sources into its task-owned temporary package. After explicit execution admission, the narrow command is:

```sh
nice -n 10 python3 scripts/verify-mobile-chrome-policy.py --filter MobileSuggestionSnapshotTests
```

This command did **not produce a completed test run**. The later bounded attempt below failed at SwiftPM manifest sandboxing before test selection. The runner compiles a temporary single-job Swift package and would run only the new suite; it does not require a Simulator or app launch. No old 40-test acceptance suite needs to be repeated unchanged. The initial `33fd6c9` correction left the existing runner sandbox flag alone; the bounded follow-up removes that opt-out and keeps normal SwiftPM sandboxing enabled.

## Completed checks and limits

Completed in the initial source increment: source/control-flow review, exact diff review, `git diff --check`, and Python AST parsing of the updated runner. Python parsing did not execute the runner or invoke a compiler. At that checkpoint no Swift parse/typecheck/build or test execution occurred. The later attempted harness invocation is recorded below and did not reach production/test compilation or test execution. The five new test cases remain uncompiled/unexecuted. Earlier phone/iPad passes belong to their recorded historical application revisions; they do not establish acceptance of this changed BrowserView.

The next build, after admission, is an unsigned `Browser iOS` scheme build-for-testing from `Straight Up Browser.xcodeproj` with two jobs, no package updates, isolated generated outputs and an exact new source receipt. Do not silently reuse the October 22 executable as evidence for this source. A later synthetic UI regression should populate one query, change it, and use keyboard suggestion navigation during a controlled pending lookup; also check same-text close/reopen and tab/private transitions. That requires separate Simulator/UI admission and a supported verified runtime. No production browsing data is needed.

## Preserved holds and remaining acceptance

The official iOS 27.1 runtime's last recorded signature verification failed with `-67054` (`errSecCSBadResource`). The independent codesign wrapper custom-omit observation is `-67013`; they are distinct and no shared root cause is established. The original disk-image checksum and 56 recorded resource hashes matched, and official component maintenance reported no updates. This increment did not reverify, repair, download, re-sign, bypass or boot the runtime. The runtime hold remains until verification confirms a supported resolution.

The earlier iOS 18.5 process-local WebKit loader workaround addresses a separate old-runtime defect. It is not a remedy or permission to work around the 27.1 trust failure. Prior 26.5 phone/iPad acceptance is not Duo acceptance. Multiple Browser scenes remain disabled; no simultaneous-scene claim is possible from the existing configuration.

Still pending: manual VoiceOver, physical-device/system rotation-lock combinations, and the resized/occluded/Duo hardware matrix (including asymmetric camera/fold safe areas, 30% local-window width, stationary snapping, editing and lifecycle continuity). No phone installation, launch or reboot is authorized. Do not change system accessibility/security settings to obtain a result.

Shared Studio builds, Simulator and UI resources need fresh explicit admission from coordinator `01a16f34-bab5-762e-84cf-ebcf549af015`. None was acquired or used here. Studio was not operated. A read-only hardware-metadata probe was unavailable in the local sandbox and was not retried; no current global process inventory is claimed. The lane has no active descendants and started no persistent process, native worker or UI session.

No release/publication, app upload, external contact, new credentials, security changes, other-app work or model-setting change occurred. There is no verified fast-mode claim. The temporary model-choice authorization ends **2026-10-30 05:53:05 UTC**; stop by that deadline absent an explicit extension, or earlier for a user instruction or actual capacity limit. Nathan owns reset decisions; no reset, bypass or inferred restoration is part of this lane.

## Actual bounded pure-test attempt, 12:45 UTC

The renewed request explicitly allowed a genuinely permitted source-only/pure-test path. Inspection found this dependency-free temporary Swift package, rather than an app/Simulator harness. The lane was clean at `33fd6c9`, had no descendants or active owned receipt, and acquired its existing nonblocking heavy-operation lock. A read-only `swift test --help` succeeded and confirmed the cache/config/filter options. No prior process-inventory denial was retried and no claim about unrelated global workers was made.

The runner's `--disable-sandbox` was removed before execution; cache/config locations and local manifest caching were directed into the same temporary directory. These changes retain normal security enforcement and do not modify system settings. The one attempted command selected only `MobileSuggestionSnapshotTests`, requested one job and low priority, and had a 300-second supervisor deadline. Application, production-policy and test bytes match `33fd6c9`; only the runner had this recorded local change.

**Actual result: harness exit 1 in approximately two seconds; zero tests executed, zero test passes, zero test-case failures, all five cases unexecuted.** SwiftPM failed at the manifest stage with `sandbox-exec: sandbox_apply: Operation not permitted`. It also reported that its normal user security/cache location was inaccessible; no package dependencies or credentials were involved. `nice` independently reported `setpriority: Operation not permitted`, so low-priority execution was requested but not achieved. There is no production/test compiler result or iOS application-build acceptance from this attempt.

The attempt is known failed, not pending or uncertain. Its supervisor joined the child, the new owned process group is absent, and the lane lock was released. The temporary package/cache was removed by the runner's normal temporary-directory cleanup. Full log, source hashes, exact command, timing, result and cleanup metadata are preserved in `build-air/suggestion-cache-pure-oct29/` outside the source worktree.

No retry, restored sandbox opt-out, escalation, direct-compiler substitution or alternative execution route was attempted after this denial. No Xcode/app/Simulator/UI/device work, runtime verification/repair, unrelated source compilation, upload or release occurred. The five concrete regression cases remain pending a genuinely permitted execution environment/admission. There is no independently executable test route established under the current holds; do not present more source-only reasoning as test execution.
