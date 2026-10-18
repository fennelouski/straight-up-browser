# Independent durable Settings source review

Reviewed 18 October 2026 against
`3bbe18e91a811e5ba5376173696452259e4b9ad4` in the isolated Browser v2 worktree.
No unresolved P0/P1 or additional actionable P2 source defect was found after the
corrections below. This finding supports source integration within the reviewed
scope; it is not native acceptance, signing, installation, or release approval.

The frozen new-phase snapshot contains 16 changed/untracked Swift app/test files
under `Straight Up Browser`, `Straight Up BrowserTests`, and `Browser iOS`.
Probe/documentation Swift files are excluded. SHA-256 of sorted UTF-8 path, NUL,
file bytes, NUL:
`9e84caf3c980eadce7c0b975cacdb297eb61fccf4828155c0af4a557994df648`.
The reviewer read implementation, regression source, the planning package and
[ownership/protocol documentation](../../browser-v2-settings-durability.md).
`git diff --check` passed. No reviewer tests, builds, native UI, implementation
edits, process termination, installation, signing, network mutation or permission
changes were performed. This review document is the reviewer-written deliverable.

## Actual scope and authority

Theme alone gains a native assistant Apply/Undo path. All eight macOS/iOS theme
property-storage surfaces and `SettingsManager.theme` use one observable typed
owner. The eager default seed is removed. Initial migration preserves the legacy
stored value or absence once; subsequent raw `theme` defaults edits are
non-authoritative compatibility data and cannot silently reimport an ABA edit.
The other three catalog preferences remain manual-only for production mutation.
The generic four-ID durable fixture does not grant them production capability.
External Settings tools/pairing remain denied.

The authority uses a stable advisory lock, coherent stored-value/revision reads,
exact revision/value CAS, a versioned checksummed state, an initialization marker,
and bounded operation outcomes. Intent, replacement state and outcome use file
sync/full-sync, atomic rename and directory sync. UserDefaults cached readback is
not durability evidence. Undo is a new CAS operation preserving absence; approvals
and Undo controls remain session-only.

## Corrected findings verified in final source

| Finding | Resolution |
| --- | --- |
| A global adapter capability could enable unmigrated IDs. | Capability and Apply/Undo checks are per setting; the native adapter admits only the exact theme descriptor. |
| A stale view flag could admit a change after local help/master revocation. | Coordinator and native adapter recheck app-owned eligibility synchronously before writing; known pre-write denial does not become an uncertain result. Manual theme remains usable with help off. |
| Undo could continue after its snapshot entered recovery. | Post-read recovery, snapshot-error and capability checks precede commit. A read-fails-once regression prevents mutation from cached receipt state. |
| Ordinary lock contention could permanently freeze observation or startup. | Busy/stale states remain retryable; bounded lifecycle refresh and explicit native Retry cover exhausted initialization/read retries. Watcher cancellation releases its descriptor. |
| A post-commit verification failure could still report Applied without publishing runtime state. | Nontransient failure propagates recovery-required; the previous published selection is retained and durable evidence is preserved. |
| Missing initial state could reimport stale Defaults before the first setting mutation. | Authority marker and prior-lock admission distinguish initialized/missing state from first migration and refuse reseeding. |
| Checksums alone did not reject impossible historical/journal semantics. | Typed before/after values, authority/fingerprint, revision arithmetic, target/global generation relationships and overflow-checked revision sum are validated before recovery writes. |
| Questions could reconcile an orphan directly, or schedule that write later. | Snapshot/status reads are pure and schedule no recovery. The delayed 450 ms regression checks unchanged state with observation disabled; explicit Retry may reconcile metadata afterward. |
| Eager test-host startup could initialize production theme storage before XCTest connected. | Shared-factory XCTest/UI-testing detection selects a UUID temporary authority and private suite before any normal Application Support/defaults selection. |

## Recovery and evidence limits

Reconciliation never replays the requested preference change. Durable evidence
resolves committed versus notApplied outcomes; notApplied burns the old expected
revision so compaction cannot make it fresh. Before canonical intent rename, an
orphan temp file has unknown/not-admitted status, not a blanket idempotency result.
Restarted native coordinators have no staged approval and cannot reuse that old
proposal. A fresh deliberate preview/action is required. Corrupt or future state
is preserved and blocks mutation rather than being automatically repaired.

The owner-run `/tmp/browser-v2-durable-settings-review-tests.log` records 48 passing
tests in three suites. The harness compiles actual durable/native owner,
coordinator, policy and SwiftUI-wrapper sources with MainActor default isolation,
warnings as errors and two compiler jobs. It uses private files/suites. The
reviewer inspected that log and the corresponding regression source, and did not
execute the harness. Final aggregate results and compile checks belong to the
owning task's verification record.

Fault-injected throws occur after real filesystem operations; they are not actual
Browser process crashes or physical power-loss tests. The separate-process
fixture exercises contention and lock release when a lock-holding child exits
without cleanup; it does not crash Browser during a preference commit. Advisory
locking requires cooperating writers and does not resist arbitrary file tampering
or replay of an entire internally consistent old authority directory.

Actual multiwindow visual updates, native Apply/Undo traversal, IME/VoiceOver,
iOS runtime behavior, abrupt Browser-death recovery, device/filesystem power-loss
behavior and media continuity remain unobserved. The owning task reproduced the
Xcode hosted-launch assertion in an independent minimal project; hosted-suite
execution is blocked. Its signing/release preflight also remains a separate
installation gate. Neither this source review nor standalone tests attest a
production release, and no deployment authorization is implied.
