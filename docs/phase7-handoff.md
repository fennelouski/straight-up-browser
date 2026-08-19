# Thought Flow Phase 7 — Handoff

Phase 7 (deep-research import) is implemented, unit-tested, and on `main`. **This completes the Thought Flow specification** — all seven phases shipped. Built unattended ([design call]s in `docs/phase7-design.md`); manual verification pending (checklist, Phase 7 section).

## The load-bearing decision

**The imported report becomes a workspace document**, and from that everything follows by composition rather than construction:

- The importer writes only what Phase 1 defined: sources (the report content-hashed via the Phase 3 identity rule; each citation with the `.importBundle` method Phase 1 reserved), references with `openedFromSourceId` = the report, and one anchor per Markdown citation (locator inferred from the URL — `?t=`, `#:~:text=`, else whole-source, in exactly the stored forms fallback #2 matches).
- Then **one ordinary Phase 2 save** does the rest: title repair stamps `^id` markers into the file, edge reconciliation writes the pre-populated claim-citation edges with real quotes and offsets.
- And **provenance tracing is Phase 4 unchanged**: the lineage renders the bundle as one Shared Upstream fan — "what this report is standing on," and the warning that citations inside one report are never independent corroboration. Unsupported Claims reads the report's uncited assertions off the page.

Phase 7 added a parser, an orchestrator, a paste sheet — and zero new writers, zero schema.

## What shipped

| File | Holds |
|---|---|
| `ResearchReportImport.swift` | `ResearchReportParser` (title from heading/first line/override; Markdown links via `AnchorLink.parseAllMatches` + bare-URL regex with punctuation trimming; canonical-key dedupe where a link beats its bare footnote twin; locator inference) and `ResearchReportImporter` (the pipeline above) |
| `ImportReportSheet.swift` | shared SwiftUI: paste-first, optional title, file picker for saved `.md`/`.txt`. Mac center card in the overlay group; iOS sheet |
| `LedgerStore` | `recordBundleSource` (capture + lineage), `recordFileImport` gained a defaulted `method:` (Phase 3 callers untouched) |
| plumbing | **⌃⌘I** — the research row ends at N/T/G/B/C/I. iPhone switcher entry. Import finishes by selecting the document; the note points at ⌃⌘G |

## Semantics pinned by tests (7 tests, 2 suites)

Title precedence and the 80-char cap; Markdown + bare citations with `ftp:` dropped and trailing punctuation trimmed; canonical dedupe (utm twin collapses, the link wins); locator inference matches resolver-stored forms; the end-to-end bundle — repaired markers on disk, `.importBundle` refs with lineage, two edges with the right quotes, the video's `t=417` a locator not a source, and the upstream fan over the resulting refs; re-import = same report source + politely-colliding document; empty paste writes nothing.

## Gotchas

- The importer never rewrites report text — bare URLs stay bare (no edge; membership only). The only file mutation ever is Phase 2's own title repair. Resist "linkifying" on import; it would put words in the report's mouth.
- Cited pages arrive `deferred` (no fetch at import — the Phase 3 rule). Bibliography matching over a fresh bundle finds nothing until sources are opened once; that is the designed behavior.
- `inferredLocator` must keep producing exactly the stored forms `AnchorResolver.locatorMatches` compares against; a drift there silently downgrades imports from enriched to plain (a test pins the two-sided contract via the end-to-end repair assertion).

## The spec is done

Every SPEC phase is complete. What remains, deliberately, is the SPEC's own "Later / optional" list (citation-graph APIs, Scite, Google Docs publish, image-region and visual-video anchors), the recorded deviations awaiting the owner's verdict (chiefly iPad document-in-split), the untranslated string-catalog pass, and the entire manual checklist — which is now the project's outstanding debt, phase by phase, in one file.
