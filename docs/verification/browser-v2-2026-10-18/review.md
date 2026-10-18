# Independent Browser v2 source review

Reviewed 18 October 2026 in the isolated `codex/browser-v2-20261018` worktree,
against baseline `666bb5729a3a1e3797cceac6ad5e101f0d03f731` and the extracted
Browser planning package. No unresolved P0/P1 or additional actionable P2 source
defect was found after the corrections below. This is a bounded source review,
not release approval or proof of uninterrupted media.

The final source snapshot contained 39 changed/untracked Swift production and
test files. SHA-256 of their sorted UTF-8 path, NUL, file bytes, NUL sequence:
`1252185101582427363a5bf2ae2e4489e7ff2b693f7f03f535096f0e0b7ee3ba`.
The owning task subsequently added only `import SwiftUI` to
`PaneLayoutTests.swift` for its app-dependent binding fixture. Removing that
single import reproduces the original reviewed fingerprint
`6c7198a22b89867d5a0664a9de157c3c6095558a6c6fcc12774af2526c5c18b3`,
confirming no other Swift source/test delta. This was a compile-only correction.
Review covered the integrated diff, relevant repository instructions, ADR 0011,
and regression source. The reviewer performed no edits to implementation, tests,
builds, native UI, installation, signing, deployment, or permissions. The only
reviewer-written deliverable is this file. `git diff --check` passed.

## Findings corrected and source-verified

| Area | Finding and verified resolution |
| --- | --- |
| Shortcuts | US punctuation inference could break other input layouts; matching now uses AppKit characters. Repair Undo now uses per-command revisions, rejects ABA and current peer/fixed/system collisions, and rejects expanded Back/Forward aliases enabled after Apply. The added actual-store regression preserves the repaired chord when Undo is unsafe. |
| Global registration | Failed replacement/cleanup could lose track of an existing Carbon registration. Registration is replaced before releasing the old handle; failed cleanup remains tracked and exposes recovery status. Real Carbon behavior remains unobserved. |
| Fade and capture | Preference-off, compact zero-area panes, and frame timing could leave pages hidden or count hidden residence. Immediate reveal, native visibility checks and post-frame residence refresh are present. Memory eviction now excludes protected capture/call panes. These source guards do not establish call survival. |
| Pane geometry | Recursive minimums, membership changes and cancellation could discard preferred geometry or commit a canceled resize. Applied ratios clamp without rewriting preferences; reconciliation prunes only removed leaves; drag-scoped Escape ignores repeats and cancels on focus/display changes. Spatial targets use measured geometry. Maximize cannot hide another protected pane. |
| Rollout and recovery | The former editor-only gate was insufficient. The new gate defaults off and guards recursive rendering, expanded admission, mutation, Undo/Redo, maximize, migration and recovery writes. Revocation retains all live identities and cancels recursive dragging. Default observers hop to the main actor. Rejected/future recovery bytes block later writes; re-enable checks current bytes even when retaining the live tree. |
| Saved Update | Reviewing vN, then restoring a previous saved version, could silently save an old draft against a freshly fetched revision. Save now binds to the frozen reviewed revision, mutations invalidate the draft, and the store independently validates draft/current revisions and overflow. Diff source preserves distinct slot identity for equal URLs and validates restore references before displaying them. |
| Cold restore | Saved-page controls could bypass the two-load limit; retries now rejoin bounded admission, including retired generations, and retain the reviewed URL/profile. Exact navigation tokens govern terminal release and actual engine disposal. Success retires scheduler ownership for normal later restoration. Failure remains guarded. Memory-state restoration and preview warming exclude owned starters. |
| Download and nil-load recovery | Staged download claims could outlive their only consumption point and strand capacity. Claims now bind to the exact returned navigation and revalidate its token; subframe/unknown-frame actions cannot acknowledge a main-frame starter. Obsolete claims are pruned. A nil native result clears deduplication state and failed fade so a later same-URL manual navigation can proceed. |
| Settings and teaching | Manual drafts and reactive revocation now invalidate stale guidance. Unknown Settings capabilities fail closed before broad legacy grants. Global learning donation occurs only after confirmed presentation invoked outside Browser, avoiding a nonprivate guess for an unknown Browser tab. |

## Remaining delivery and acceptance limits

- Production conversational Settings Apply/Undo remains unavailable:
  `supportsRecoverableCommit` is false. Native guidance uses manual controls;
  no durable writer, authenticated external Settings pairing or remote provider
  integration is claimed. Question-only mode and narrow proposal validation were
  reviewed in source.
- Unsolicited teaching waits for a complete real safety snapshot. Calendar/context
  suggestions and cross-window session transfer are unavailable.
- Pane dragging stages a final preview followed by Apply; final-shape hover
  preview is not implemented. Layout Undo retains every new blank tab because
  pristine-page and unsent-input detection is unproven.
- The 2.9.32 baseline has fixed Command+N New Window. The historical configurable
  2.9.28 implementation is absent and requires separate reconciliation.
- Running-app screenshots, VoiceOver/IME, real hotkey registration, native drag
  and callback races, mixed displays, full-screen/Stage Manager, memory budgets,
  unsaved documents, and actual two-party audio/video/share continuity remain
  unobserved. Native 30-minute/100-action call acceptance is still required.

Executed tests and builds belong to the owning task and are recorded in
[README.md](README.md), [test-results.json](test-results.json) and their logs.
Regression source inspection and pure policy passes must not be described as a
hosted full-suite pass or native media evidence. No production installation or
expanded persistent access was part of this review.
