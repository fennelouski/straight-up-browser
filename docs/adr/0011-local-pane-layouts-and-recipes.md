# ADR 0011: Local pane geometry, retained sessions, and workspace layout recipes

Status: implemented in the development checkout behind the default-off local
`paneLayoutsRolloutEnabled.v1` gate. Native media, navigation, and accessibility
release verification remain required before shipping.

## Context

The source baseline already has 2–4 split members, native web/document panes,
sidebar pane reordering, and CloudKit-backed research workspaces. A five-pane
arrangement requires geometry beyond the flat columns/grid. Saving that geometry
must preserve research ownership and must not sync meeting links or private state.

## Decision

`PaneLayoutTree` is local, per-window geometry with stable, distinct pane IDs,
typed content references, split IDs, axes, and preferred ratios. Existing
`TabManager`, `WebViewManager`, and document-provider identities remain owners of
their sessions. Structural changes update frames inside the same native host;
they do not close, recreate, reload, suspend, or navigate existing content.

This extends ADR 0001's view-state split: local recovery can retain recursive
geometry and explicit named local recipes can retain a reusable configuration.
It does not make split groups into synced research entities. ADR 0007's source
dispositions and ADR 0008's document-provider routing remain in force. Removing a
pane from the arrangement is distinct from closing its tab or rejecting a source.

The legacy local split membership record is retained. An optional versioned local
recovery snapshot restores validated typed topology/ratios only when membership
and research workspace still match. Malformed or stale recovery data is retained
and the validated legacy arrangement supplies a fallback. Rejected, corrupt, or
future recovery bytes block later automatic rewrites, including opt-in and focus
changes, rather than being silently downgraded. Private working state is excluded
from persistent membership and recovery.

The rollout gate covers recursive rendering, tree reconciliation/migration and
recovery writes, recursive divider commits, Apply, Layout Undo/Redo, temporary
maximize, and admission beyond four members. Previews and local recipe review
remain available while it is off. Legacy two-to-four-pane rendering and divider
resizing continue to work. Revocation cancels an active recursive divider drag
before fallback and retains every live member, tab, document, and engine. Expanded
arrangements use nonrecursive columns with an explanation and disabled resizing;
they are not truncated to four or compacted on revocation. The retained preferred
tree returns on re-enable only when typed member order and workspace still match.
The old editor-only `paneArrangementsEnabled` preference does not enable this gate.

`LocalLayoutRecipeStore` writes a separate atomic local JSON file with a previous
file and bounded revision history. It never adds fields to SwiftData/CloudKit.
Its tree refers to configuration slot IDs, not runtime TabIDs. Slots contain a
document-provider reference, a conservatively reviewed ordinary starting URL, a
manual meeting slot, or an empty slot. Profile affinity refers only to an existing
authorized profile; absent profiles block application. No credentials, cookies,
website state, raw titles, or private content is stored. A parsed-host meeting
classification is independent of the user-editable memory-pin list.

Runtime recipe bindings remain in memory. Open reveals a known live instance in
another native window instead of cloning sessions. Otherwise its preview reuses
retained identity bindings and explicitly lists new safe starters and manual
blank slots. It never merges by URL. Meeting slots never navigate, join, request
capture permission, or claim to resume a call. Missing documents are represented
by a blank manual slot, not recreated from stale document data. Cold manual
slots currently use ordinary blank tabs; they have no starting navigation.

An explicit Update now computes a pure before/after diff from the saved revision
and the reviewed proposal. It shows topology, preferred divider ratios, content
positions, added/removed configuration slots, exact restore references, profile
affinity, focus, name and research-workspace linkage. Reordered content retains
slot identity rather than appearing as deletion/recreation; two starters with
the same URL remain distinct. Split bookkeeping IDs and timestamps alone create
no changes. Unsafe restore references and mismatched revisions are rejected
before a diff can be rendered. The editor disables saving a no-change update.
Save binds to the frozen reviewed revision. Any successful saved-recipe mutation
invalidates the review, and the store independently rejects a draft whose own
revision differs from the expected saved revision. Revision overflow is rejected
at the store boundary, including previous-version restoration.

Cold restore registers only newly created safe starting-page IDs after successful
Apply; retained live bindings and manual/meeting/private slots are excluded. Both
focused and nonfocused automatic load paths are guarded before interaction-state
restore, fade, and load; the manager's memory-state restore and preview/link/OG
warming paths also exclude deferred starters. One per-window scheduler reserves
at most two automatic loads synchronously, counting unfinished jobs in retired
generations. Admission is focused first among actual positive-area projected panes
in a visible native window, after URL/profile/workspace/revision/gate revalidation.
Post-frame and window focus/show/occlusion/resize callbacks request admission again.

The returned `WKNavigation` is bound to the unique generation/tab/load token.
Commit/paint never frees capacity. Exact finish/failure/provisional failure,
download conversion, process termination, or actual engine disposal acknowledges
the permit; stale and duplicate terminals cannot release newer work. Workspace,
layout, Undo, rollout, replacement restore, or new user navigation cancels future
starts while preserving active engines and their permits. A successful actual
finish retires scheduler ownership so later ordinary memory restoration works.
Canceled and failed pages remain guarded against automatic retry and receive a
native Load Saved Page control. That restore control rejoins bounded admission,
including retired in-flight work; a still-pending target is only promoted.
Retries retain the original reviewed URL/profile and require a blank engine or
the exact known failed engine state, protecting newer manual work. New omnibar or
website navigation is a deliberate user action and retires only its target's
automatic ownership. Generic selection, Undo, and workspace focus never grant it.
Manual slots never navigate. Deterministic policy tests exercise these boundaries;
the native callback/visibility races still require runtime acceptance.

The Arrange Panes sheet provides both a linear keyboard route and typed native
drag destinations. Drag payloads require the presentation nonce, source UUID,
current revision, current source whitelist, and current target. A drop produces
the final preview; Apply commits once. This is a safe drop-to-preview adaptation;
hover does not yet render the final destination geometry. External text, URLs, and files do not
participate. Cancel and deactivation create no content or layout changes.
Independent Layout Undo/Redo restores geometry and retained content. Undoing a
new blank split leaves the new tab open in the sidebar instead of losing work.
The implementation conservatively retains every newly created blank tab on
Undo: a reliable pristine-page/unsent-input signal is not yet established.
Spatial keyboard targets use the rendered preview bounds, perpendicular overlap,
distance and deterministic reading-order ties, with no wrapping. Temporary
maximize retains the complete tree and preferred ratios, restores focus, and
refuses to hide another protected pane. Divider cancellation monitors only the
active drag's Browser window; marked text owns its first Escape, repeated key
events cannot count as a second physical press, and focus/display changes cancel
without committing.

Applied ratios clamp against recursive minimums without rewriting preferred
ratios. An undersized viewport projects a compact subset while retaining every
protected pane; ordinary omitted panes remain in the sidebar. Enlarging restores
the original tree. If the physical viewport cannot fit all protected minimums,
all protected panes remain visible with an explicit space constraint notice.
That case cannot promise useful website viewport sizes. Compact dividers cannot
rewrite the saved full tree. Fade residence refreshes after native frame commit.

## Limits and verification

The model accepts up to 32 leaves; the integrated UI explicitly limits visible
arrangements to eight. Cross-window/profile/private transfer is rejected. This
implementation adds no calendar/context matching or new permissions. Multiwindow
geometry restoration, context suggestions, and live media survival through view
and display transitions remain separate acceptance work.

`scripts/verify-browser-v2-panes.sh` runs the actual pane and cold starter policy
tests using a local temporary Swift package with two compiler jobs and records a
log. The script explicitly excludes the
full-app transaction tests. Full Browser tests, real two-party audio/video/share
continuity, VoiceOver, native drag cancellation, memory/display stress, and cold
restore behavior must each be reported separately; a model pass or successful
compile does not certify them.
