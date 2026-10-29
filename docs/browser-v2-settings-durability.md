# Native Settings theme pilot

The first durable assistant writer owns **theme only**. Page fading, fade length,
and automatic link splitting remain explain/preview/manual-control features.
External Settings agents remain denied by the existing policy and CLI gates.

## Source ownership

`BrowserThemeStore` is the observable runtime owner. `BrowserThemeStorage` connects
it to all native theme surfaces: the macOS app scene, ContentView, FilesWindow,
HelpWindow, SettingsWindow, Appearance Settings, and the iOS Settings and browser
views. `SettingsManager.theme` forwards to the same owner; ToneSchedule already
reads that property. SettingsManager no longer seeds a theme default.

Each app's own Application Support directory contains `Straight Up Browser/Theme
Authority`. The first initialization imports the existing legacy theme, including
absence, while holding the authority lock. A malformed legacy value blocks
migration rather than being silently normalized. The legacy `theme` defaults key
becomes a one-way compatibility projection after migration; raw defaults changes
are no longer authoritative and are never reimported. This is intentional: a raw
defaults notification cannot prove an intervening same-value or ABA write.

The global shared factory checks `XCTestConfigurationFilePath`,
`XCInjectBundleInto`, and `-uiTesting` before selecting any production location or
defaults. Those processes receive a unique temporary authority and a private
defaults suite. Standalone tests inject their own directories/suites and never
evaluate the shared owner.

## Disk transaction and recovery

`SettingsDurableStore` supports only the four typed registry IDs, and verifies the
exact registered descriptor. Production constructs it with the singleton set
`theme`. A versioned checksummed state document contains stored value/absence,
per-target revisions, a global generation, and at most 100 operation outcomes.
The immutable authority marker prevents a missing state file from being mistaken
for a new migration. A pre-existing lock without initial state also fails closed.

Every operation holds `flock(LOCK_EX | LOCK_NB)` on the dedicated stable lock
inode. The lock is never renamed or unlinked; process death releases it. The
writer rereads a coherent value/revision pair and compares both with the preview.
Same-value manual writes advance the persisted revision. Cooperative second
owners therefore cannot hide an away-and-back edit.

For one setting, the writer:

1. Records and syncs an intent containing the exact operation identity, request
   fingerprint, before/after state hashes, and before generation.
2. Writes a replacement authority file, runs `fsync` and `F_FULLFSYNC`, atomically
   renames it, and syncs its directory.
3. Records and syncs the completed outcome using the same replacement protocol.

These OS persistence barriers establish the disk outcome; a cached UserDefaults
readback is never used as evidence. Runtime theme is published only after a
successful commit and coherent read. A nontransient publication/read failure is
reported as recovery-required, even if disk evidence can later show a commit.

Startup, filesystem observation, an explicit native Retry, and commit admission
may reconcile an orphan intent. Reconciliation **never replays its requested
preference write**. Matching authority/outcome evidence resolves a commit. An
unchanged before-state records `notApplied` and advances only the target revision,
making that original expected revision permanently stale even after outcome
compaction. Impossible hashes, identities, types, revisions, generations, unknown
schemas, and malformed records are preserved and block the writer.

A crash after intent-file sync but before its rename leaves only a temp file.
That operation has unknown/not-admitted status, rather than a durable notApplied
receipt. Native proposals and approvals are memory-only: reopening cannot
resurrect or automatically retry that identity. Temp files remain as evidence.

Snapshots, operation-status reads, questions, and previews perform no recovery
writes and schedule no deferred recovery. A pending intent returns a recovery
status; native owner lifecycle or deliberate Retry handles it separately. Initial
theme migration is normal owner startup work, not proposal application.

## Apply and Undo boundary

`SettingsNativeStore` grants recoverable capability per target, only for theme.
The native coordinator retains question mode, request/session identity, expiry,
draft conflicts, immutable preview matching, and revocation checks. Immediately
before a native assistant commit, both the coordinator and NativeStore recheck
current app-owned eligibility. NativeStore reads the AI master/help opt-in from
its injected current defaults; a stale SwiftUI availability flag cannot approve
a revoked operation. Known pre-write denial does not become an uncertain write.
Manual theme controls remain usable with AI/help off.

Undo is a fresh compare-and-set operation against the receipt's persisted
post-revision and value. It restores absence when the old key was absent. Any
later edit, including same-value edits, prevents Undo. Session ending discards
Undo controls and approvals; durable operation evidence is not approval material.

## Verification and limits

Run `scripts/verify-browser-v2-settings.sh`. It compiles actual implementation and
tests with two jobs, the app's MainActor default isolation, and warnings as errors.
Fixtures exercise real temporary files, OS sync calls, all nine injected crash
boundaries, two owner instances, an actual second process with abrupt exit,
compaction, absence Undo, persisted ABA, pure delayed questions, eligibility
revocation, and preserved malformed/future authority. No production app is
launched and no shared production theme owner is instantiated by these tests.

Fault injection models interruption after real operations; it does not certify
physical power-loss behavior on every filesystem or device. Advisory locks do not
protect against an uncooperative process rewriting arbitrary files. Checksums and
revision/marker checks detect inconsistent state, not an adversary replaying a
complete internally consistent old directory. This is an app-owned preference
authority, not a tamper-proof store. Native IME, accessibility, multiwindow visual
behavior, and signed release checks remain separate integration gates.
