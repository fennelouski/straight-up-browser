# Thought Flow — Specification

Research workspaces inside Straight Up Browser. A workspace owns its tabs, its documents, and its source ledger. The tool makes it trivially easy to capture sources, link them to writing at precise locations, validate their credibility, and recall anything previously researched — without changing how the user reads and reviews material.

Built for one person's research: food science for video scripts, plus AI, software engineering, and the occasional academic paper. Most sources are general web pages and YouTube videos; some are academic papers. General-audience polish is explicitly not a goal.

**Status:** ALL SEVEN PHASES are complete and shipped. The 40-locale translation pass ran 2026-08-20 (129 research keys + a new BrowserShare extension catalog, 36 locales each). What remains is the "Later / optional" list below, the recorded scope deviations awaiting the owner's verdict (chiefly iPad document-in-split), and the manual verification checklist (`docs/phase2-manual-checklist.md`) — not yet run. See `docs/phase1-handoff.md` and `docs/phase2-handoff.md` for what exists, `docs/adr/0007-the-research-ledger.md` and `docs/adr/0008-split-admits-document-panes.md` for the decisions that shaped them.

---

## Design principles (settled — do not re-decide)

1. **The browser is the capture surface.** It already knows what page is open and which workspace is active. Capture must never require tagging, filing, or choosing a project — context comes from the workspace.
2. **Nothing is trapped.** Documents are plain Markdown files on disk (iCloud Drive). Export is a no-op because the storage format is already portable. There is no proprietary document format.
3. **Anchors degrade gracefully.** Enriched links render specially inside the app but are stored as plain Markdown link syntax, so any external Markdown reader sees an ordinary working link.
4. **AI is advisory, never authoritative.** Background AI never edits the user's text and never silently creates authoritative objects. Its output surfaces in a sidebar and becomes real only when the user accepts or anchors it. Silence is the default state.
5. **The ledger is global; workspaces are views.** Sources live once, referenced by many workspaces. This enables cross-project recall.
6. **Single user per instance.** No shared ledger, no per-person ratings, no CloudKit shared zones. This is a deliberate cut recorded in ADR 0007, not an oversight — shared research spaces are a possible future feature and a product decision, not a gap to be filled in.
7. **No two-way sync with external editors.** Google Docs (or similar) is a one-way publish/export step only. Sync-back is out of scope permanently unless revisited deliberately.
8. **Each phase ships as an independently useful tool.** Phase 1 with zero AI must already be satisfying to use daily.

---

## Core concepts

**Workspace** — A named research project. Owns: a set of tabs, one or more documents, and references into the global ledger. Its tabs stay with it permanently and never migrate into the default workspace. Ordinary browsing happens in the **default workspace**, which is the absence of a workspace rather than a record of its own.

**Source** — A globally unique captured item: web page, YouTube video, PDF, image, or imported file. Identified by a canonical URL or a content hash. Carries metadata, extracted text (via the browser's existing reader extraction), transcript (for video), capture timestamp, and credibility signals. A source exists once even if referenced by five workspaces. A Source **is** a Saved Article — the same entity seen from research rather than reading.

**Workspace reference** — The join between a workspace and a source: when it was added, how, its **disposition**, any workspace-local note, and which source led to it.

**Disposition** — The verdict on a source within one workspace. Universal semantics; no per-workspace or per-user setting:

- **`open`** — still in the working set. Written when a page **settles**.
- **`dismissed`** — rejected. Written by a user-initiated tab close, and by nothing else.
- **`kept`** — survived to the end of the project. Written by the archive sweep, and by nothing else.

**Anchor** — A precise location inside a source: `(source, modality, locator)`, plus a stored quote so the anchor survives its locator breaking. Locators: text fragment for web pages, timestamp for video, page number for PDFs, optional region for images.

**Claim** — An assertion in a document, represented as a text range. Claims are implicit ranges by default; a range can be *promoted* to a named claim when the user wants deduplication across projects.

**Edge** — A link between a claim (or plain text range) and an anchor. The edge table is the heart of the system: the graph view, the audit view, and the "unsupported claims" list are all renderings of it.

**Document** — A Markdown file in iCloud Drive belonging to a workspace. A workspace can hold several. The scratchpad is just a document, not a special top-level object.

**Rating** — A single per-source score. Deliberately **optional and standout-only**: most sources are never rated, because disposition already carries the everyday verdict. Rating marks the few that are exceptional, not a score everything must receive.

---

## Capture and rejection

The two rules the whole system rests on. Both are counterintuitive enough to be worth stating plainly:

### Capture happens at settle

When a page in a workspace finishes loading and the user **stays with it for twenty seconds**, it enters the ledger with disposition `open`. That threshold is not "the page loaded" — it is "you stayed with it," so the ledger records sources that were *considered* rather than every page that scrolled past. Redirect chains, consent interstitials and login bounces never appear.

Background tabs settle exactly like displayed ones: opening ten search results and closing the seven bad ones is the workflow this is built for.

A deliberate one-keystroke capture (⇧⌘D) writes the same thing without waiting out the dwell.

### Close is rejection

**Closing a tab rejects its source.** It writes `dismissed` and performs no capture, no extraction, and no archiving. Because the dwell is twenty seconds, most rejections happen before any capture; the close writes a minimal source row so the rejection is still recorded, which is what lets the browser later say "you dismissed this in March."

**Capture-on-close is wrong here**, despite being the obvious design and despite earlier drafts of this document proposing it as "tab demotion." Closing a tab is how a source gets thrown away, so capturing then would preserve exactly the material the user rejected, and turn the ledger into a record of everything *seen* rather than everything *kept*.

### Suspend is the resting state; archive is completion

- **Suspending** a workspace (closing its window, switching away, ⇧⌘W) writes nothing to the ledger. Its tabs keep their membership. Restoring is the same filter change in reverse — nothing is discarded, so nothing is recreated.
- **Archiving** a workspace sweeps every remaining `open` reference to `kept`. Rejections are never touched. The sweep is idempotent.

---

## Credibility model

Every source can carry independent signals, displayed side by side and never merged into one opaque number:

1. **Personal rating** — optional, for standout sources only.
2. **AI evaluation** — an LLM assessment of the source and, more importantly, of the claim it is being used to support.
3. **Peer validation** — for academic sources, citation-graph evidence that a finding has been independently corroborated rather than merely cited. For general web sources, independent-corroboration heuristics.

### Provenance tracing (the food-science killer feature)

Much web content is derivative: video cites blog cites press release cites paper. For a claim: extract it, follow the citation chain until it bottoms out at a primary source or dead-ends, then score at the *root* rather than the surface.

### Independent corroboration

"Do multiple sources report this claim without sharing a common upstream source?" The failure pattern to catch is twelve articles all tracing to one press release. In the graph view this renders as a fan converging on a single root — which is what `openedFromSourceId` on each workspace reference is quietly recording from Phase 1 onward.

### Academic backbone

For sources with DOIs, use free open APIs — OpenAlex, Semantic Scholar, Crossref — to walk the citation graph. Shared-author detection between citing and cited papers is a cheap proxy for non-independence.

---

## Feature phases

### Phase 1 — Workspace persistence + ledger schema ✅ **Complete**

- Workspace create / suspend / restore, with tabs staying with their workspace permanently.
- The ledger: sources, workspace references, anchors, claims, edges, documents, and local-only page archives.
- Settle-capture, close-as-rejection, the archive sweep, and promotion of the default workspace into a named one.
- One-keystroke manual capture (⇧⌘D).
- Seen-before surfacing: opening a URL in any context checks the ledger and shows prior encounters, in the omnibar and as an arrival banner.
- Canonical source identity, so a video's `?t=` is an anchor locator rather than a second copy of the video.

Delivered on macOS, iPadOS and iPhone. iPhone gets workspace switching only; iPad has desktop parity.

### Phase 2 — Editor with anchors ✅ **Complete**

- Markdown editor (hybrid live rendering, native text views) over files in the app's own iCloud Drive container; multiple documents per workspace; external edits reload, conflicts keep both versions as visible sibling files.
- Anchor links stored as plain Markdown, rendered enriched in-app as pills, resolved against the ledger in the shipped three-step order, resilient via the stored quote; every save reconciles the edge table from the document's links.
- One-gesture anchor creation from any source tab (⌥⇧⌘D / context menu on Mac, the selection callout bar on iOS): anchor written, link appended to the workspace's current document and copied to the clipboard.
- YouTube transcript ingestion (captions only — **Whisper cut in the Phase 2 interview**), synced as a ledger entity; per-video transcript panel with anchor-from-caption, plus cross-transcript omnibar recall rows.
- Split widened to admit document panes — ADR 0008 resolves the inherited constraint. Read-beside-write ships on the Mac.

**Scope changes at close:** iPad displays documents full screen only (document-in-Split is Mac-only for now — flagged, not silently dropped); PDF-page and image-region anchor *creation* deferred (locator formats ready); the manual verification pass (`docs/phase2-manual-checklist.md`) is still to be run.

### Phase 3 — Share-sheet capture ✅ **Complete** (iOS)

Share any page, video, or file from any app into a chosen workspace; default to the most recently active one; items movable afterward.

Shipped as an iOS share extension (one-tap picker, most-recent workspace first) handing off through an app-group inbox the app drains on activation — the extension never opens the store. Files import by content hash; "movable afterward" is the Newspaper's Move to Workspace menu on both platforms. **Scope notes:** Mac share-menu extension deferred (in-app capture already covers the Mac); no interview was held — decisions are [design call]s in `docs/phase3-design.md`; manual verification pending (`docs/phase2-manual-checklist.md`, Phase 3 section).

### Phase 4 — Graph / audit view ✅ **Complete**

Document-anchored, not free-floating: text down one side, sources down the other, edges between, filtered to the visible passage. No force-directed hairball. Modes: unsupported claims, unused sources, shared upstream. This is a rendering of the edge table.

Shipped exactly as specified: `AuditModel` + `AuditView` over the edge table, ⌃⌘G / document-header entry, modes as filters over one layout. Unused is workspace-wide; shared upstream renders only the lineage `openedFromSourceId` recorded since Phase 1. **Scope notes:** no interview held ([design call]s in `docs/phase4-design.md`); read-only snapshot view; manual verification pending (checklist, Phase 4 section).

### Phase 5 — Bibliography matching ✅ **Complete**

"Does anything in my bibliography support this sentence?" Retrieval over the user's own saved sources only — no open-web search, no hallucination surface. First AI feature because it runs on trusted data.

Shipped with zero required inference: a deterministic lexical matcher behind the SPEC-mandated `PassageMatcher` protocol, optionally re-ranked by the OS's on-device `NLEmbedding`. Corpus = reader-extracted blocks + windowed transcripts of the workspace's sources; results are verbatim passages, banded Strong/Possible; a match becomes real only via its Anchor button (Phase 2's composer tail). ⌃⌘B. **Scope notes:** no interview held ([design call]s in `docs/phase5-design.md`); no persisted index (rebuilt per open, per ADR 0007); manual verification pending (checklist, Phase 5 section).

### Phase 6 — Background claim extraction ✅ **Complete**

Trigger on paragraph-settle debounce, never per keystroke. Content-hash each paragraph; never re-extract unchanged text. Output is advisory; accepted claims become ledger objects, the rest vanish. The "research plan" is the list of extracted-but-unanchored claims — a to-do generated from the user's own writing.

Shipped with a deterministic heuristic extractor as the default and the on-device FoundationModels model (availability- and AI-switch-gated, verbatim-guarded — selection, never generation) layered behind the same protocol. ⌃⌘C opens the claims panel: Research plan → Find Support hands off to Phase 5; Promote writes `LedgerClaim` + stamps `LedgerEdge.claimId` — the last writerless Phase 1 entities now have writers. **Scope notes:** no interview held ([design call]s in `docs/phase6-design.md`); candidates and dismissals deliberately unpersisted; extraction runs while the claims panel is open (hash-gated, identical results to always-on — recorded deviation); manual verification pending (checklist, Phase 6 section).

### Phase 7 — Deep-research import ✅ **Complete**

Import Gemini/Claude/ChatGPT reports as source bundles: every cited link becomes a source, the report becomes a source, its claim-citation pairs become pre-populated edges. Then run provenance tracing over the bundle — turning "confident report" into "what this report is standing on."

Shipped by composition: the report becomes a workspace document, the importer writes sources/references/anchors (`.importBundle`, lineage to the report), and one ordinary Phase 2 save produces the repaired links and pre-populated edges. Provenance tracing is Phase 4's Shared Upstream fan over the recorded lineage. ⌃⌘I, paste-first. **Scope notes:** no interview held ([design call]s in `docs/phase7-design.md`); Markdown/plain-text reports only; no fetch of cited pages at import (they arrive deferred); manual verification pending (checklist, Phase 7 section).

### Later / optional

One-way publish to Google Docs; Scite API for supporting/contrasting classification; image-region anchors; visual video search.

---

## Technical constraints

- Platform: Swift, WebKit; Mac + iPad + iPhone. Reuse the existing reader extraction, workspace, and scratchpad code — extend, don't parallel-build.
- Storage: **SwiftData** for the ledger (it is SQLite underneath, and it already carries CloudKit sync, migrations and `@Query`); plain Markdown in iCloud Drive for documents. A second hand-rolled SQLite store was considered and rejected — see ADR 0007. The cost is no SQL joins, recursive CTEs, or FTS5 until a phase needs them.
- Sync: the existing private CloudKit database, single user. Page archives are local-only and never sync.
- On-device AI: all model access behind a protocol from day one, so extraction and matching are built against mocks before any real inference.
- External APIs: OpenAlex, Crossref, Semantic Scholar. Free tiers; no hard dependency on any commercial service.
- Background work must respect iOS suspension; no design may assume long-running background sync.

---

## Open questions

Resolved in Phase 1 (see ADR 0007): ledger storage engine, sync topology, dead-source handling, capture trigger, close semantics, canonical identity, and the anchor link syntax.

Resolved in Phase 2: transcript storage (a synced ledger entity; Whisper cut entirely — captions only) and document conflicts (newest wins the path, losers become visible sibling files; never a merge, never a modal).

Still open:

- **Claim promotion UX** — what gesture turns a text range into a named claim. (The claims panel's Promote button covers extracted claims; a selection-based gesture remains open.)
- ~~**Undo of an accidental tab close** must un-write the `dismissed` disposition~~ — **resolved 2026-08-20**: the closed-tab snapshot carries the ref's prior disposition; ⇧⌘T restores it (or deletes a ref the close created), restores workspace membership, and undoes a multi-pane ⌘W as one unit. Pinned by `UndoCloseTests`.
- **iPad document-in-split** — deferred from Phase 2 (deviation #6); needs an explicit keep-or-build decision.
