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

This command is a **future check, not a completed run**. It compiles a temporary single-job Swift package and runs only the new suite; it does not require a Simulator or app launch. No old 40-test acceptance suite needs to be repeated unchanged. The runner's existing sandbox flag and build settings were not altered by this correction.

## Completed checks and limits

Completed in this increment: source/control-flow review, exact diff review, `git diff --check`, and Python AST parsing of the updated runner. Python parsing did not execute the runner or invoke a compiler. No Swift parse/typecheck/build or test execution occurred. The five new test cases and filter option remain uncompiled/unexecuted. Earlier phone/iPad passes belong to their recorded historical application revisions; they do not establish acceptance of this changed BrowserView.

The next build, after admission, is an unsigned `Browser iOS` scheme build-for-testing from `Straight Up Browser.xcodeproj` with two jobs, no package updates, isolated generated outputs and an exact new source receipt. Do not silently reuse the October 22 executable as evidence for this source. A later synthetic UI regression should populate one query, change it, and use keyboard suggestion navigation during a controlled pending lookup; also check same-text close/reopen and tab/private transitions. That requires separate Simulator/UI admission and a supported verified runtime. No production browsing data is needed.

## Preserved holds and remaining acceptance

The official iOS 27.1 runtime's last recorded signature verification failed with `-67054` (`errSecCSBadResource`). The independent codesign wrapper custom-omit observation is `-67013`; they are distinct and no shared root cause is established. The original disk-image checksum and 56 recorded resource hashes matched, and official component maintenance reported no updates. This increment did not reverify, repair, download, re-sign, bypass or boot the runtime. The runtime hold remains until verification confirms a supported resolution.

The earlier iOS 18.5 process-local WebKit loader workaround addresses a separate old-runtime defect. It is not a remedy or permission to work around the 27.1 trust failure. Prior 26.5 phone/iPad acceptance is not Duo acceptance. Multiple Browser scenes remain disabled; no simultaneous-scene claim is possible from the existing configuration.

Still pending: manual VoiceOver, physical-device/system rotation-lock combinations, and the resized/occluded/Duo hardware matrix (including asymmetric camera/fold safe areas, 30% local-window width, stationary snapping, editing and lifecycle continuity). No phone installation, launch or reboot is authorized. Do not change system accessibility/security settings to obtain a result.

Shared Studio builds, Simulator and UI resources need fresh explicit admission from coordinator `01a16f34-bab5-762e-84cf-ebcf549af015`. None was acquired or used here. Studio was not operated. A read-only hardware-metadata probe was unavailable in the local sandbox and was not retried; no current global process inventory is claimed. The lane has no active descendants and started no persistent process, native worker or UI session.

No release/publication, app upload, external contact, new credentials, security changes, other-app work or model-setting change occurred. There is no verified fast-mode claim. The temporary model-choice authorization ends **2026-10-30 05:53:05 UTC**; stop by that deadline absent an explicit extension, or earlier for a user instruction or actual capacity limit. Nathan owns reset decisions; no reset, bypass or inferred restoration is part of this lane.
