# Thought Flow — Phase 7 Design

Deep-research import — the final SPEC phase. **No interview was held** (unattended, same protocol as Phases 3–6); every decision is a **[design call]**. SPEC scope: "Import Gemini/Claude/ChatGPT reports as source bundles: every cited link becomes a source, the report becomes a source, its claim-citation pairs become pre-populated edges. Then run provenance tracing over the bundle — turning 'confident report' into 'what this report is standing on.'"

## The load-bearing decision

**The imported report becomes a workspace document.** [design call] A deep-research report is Markdown with links — exactly what Phase 2's editor eats. Once it is a document:

- its citation links are ordinary anchor links, so **Phase 2's save pass builds the bundle**: resolution fallback #2 matches each link's URL + locator against the anchors the importer writes, title repair stamps the `^id` markers into the file, and edge reconciliation writes the claim-citation edges with real quotes and offsets. The importer writes sources and anchors; the machinery the editor already exercises daily does everything else.
- **provenance tracing is Phase 4, already shipped**: every cited source's reference records `openedFromSourceId = the report`, so the audit view's Shared Upstream mode renders the entire bundle as one colored fan — the literal picture of "what this report is standing on," and the standing warning that corroboration *inside* a bundle is never independent (twelve citations, one report). Unsupported-claims mode reads the report's uncited assertions off the page for free.

No new rendering, no new resolution, no second edge writer. Phase 7 is a parser, an orchestrator, and a paste sheet.

## Decisions

1. **Input is pasted text first, a file second.** [design call] Reports live in chat UIs; copy-paste is the real gesture. The import sheet (**⌃⌘I**; iPhone workspace switcher entry) has a paste area, an optional title field, and a file picker (`.md`/`.txt`) for saved exports. Requires an active workspace.

2. **Parsing** (`ResearchReportParser`, pure, table-tested) [design call]:
   - Title: first `#` heading, else the first non-empty line, cleaned and capped; the sheet's title field overrides.
   - Citations: every Markdown link (`AnchorLink.parseAllMatches` — the same parser everything else uses) **plus bare `http(s)://` URLs** (chat exports love footnote lists). Deduplicated by canonical key (`SourceCanonicalizer` — so `?utm_…` variants collapse and a video's `?t=` stays an anchor locator, not a second source).
   - The report text is **never rewritten by the importer** — bare URLs stay bare. Only genuine Markdown links get edges (an edge needs a text range that *says something*); bare URLs still join the bundle as sources + references. The one mutation the file ever sees is Phase 2's own title repair on save.

3. **Writes, in order** (`ResearchReportImporter`) [design call]:
   1. The report → an imported **source** (content-hashed via the Phase 3 file-import path, so re-importing the same report is the same source) with method `.importBundle` — the case Phase 1 reserved.
   2. Each cited URL → source + workspace reference: method `.importBundle`, disposition `.open`, `openedFromSourceId` = the report's source id (the fan).
   3. Each cited URL → one `LedgerAnchor`, locator inferred from the URL (`?t=` → timestamp, `#:~:text=` → text fragment, else whole-source).
   4. The report text → a new workspace document; one `saveNow()` runs Phase 2's repair + reconciliation, producing the pre-populated edges.
   5. Finish: select the document, transient note with the counts, and a pointer to ⌃⌘G — the fan is one keystroke away. No modal summary. [design call: not auto-opening the audit view — the import lands you *in the report*, reading; the audit is the next gesture, not an interruption.]

4. **Dispositions are untouched semantics.** An imported citation arrives `.open` like any capture — the user's read-and-close loop then judges it exactly like a settled tab. Close-is-rejection applies unchanged when they open one and dismiss it.

## Schema

**Nothing new.** `.importBundle` was reserved in Phase 1; `recordFileImport` gains a `method:` parameter (defaulted to `.shareSheet`, so Phase 3 callers are untouched); one new `LedgerStore.recordBundleSource` mirrors `recordShareCapture` plus lineage. With Phase 6 having given the last entities writers, Phase 7 adds no writers — it only composes existing ones.

## New files

| File | Holds |
|---|---|
| `Straight Up Browser/ResearchReportImport.swift` | `ResearchReportParser` (title, links, bare URLs, canonical dedupe), `ResearchReportImporter` (the §3 pipeline), locator inference |
| `Straight Up Browser/ImportReportSheet.swift` | shared SwiftUI: paste area, title, file picker, Import. Mac overlay group; iOS sheet |
| `Straight Up BrowserTests/Phase7Tests.swift` | parser tables; end-to-end import against real stores: document text on disk with repaired `^id` markers, hash-keyed report source, `.importBundle` refs with lineage, pre-populated edges with quotes, bare-URLs-join-but-carry-no-edge, re-import idempotence, and the upstream fan over the resulting refs |

Existing files touched: `LedgerStore.swift` (`recordBundleSource`, `method:` param), the usual ⌃⌘I plumbing, ContentView/BrowserView wiring, switcher entry.

## Not built, deliberately

The SPEC "Later / optional" list stays out: OpenAlex/Crossref/Semantic Scholar citation walking, Scite, credibility scoring, Google Docs publish. Also out: HTML/PDF report parsing (Markdown/plain text only — every major assistant exports it), automatic claim extraction over the report (open the claims panel; Phase 6 already reads any document), and any network fetch of the cited pages at import (they arrive `deferred`, filling in when first opened — the Phase 3 rule).
