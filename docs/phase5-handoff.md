# Thought Flow Phase 5 — Handoff

Phase 5 (bibliography matching) is implemented, unit-tested, and on `main` — the first AI-adjacent feature, shipped with **zero inference required**: the default matcher is lexical and deterministic, and the only "model" involved is the OS's on-device `NLEmbedding` as an optional re-rank. Built unattended ([design call]s in `docs/phase5-design.md`); manual verification pending (checklist, Phase 5 section).

## The two rules this phase adds

1. **Retrieval, never generation.** Every result is a verbatim passage already in the ledger (reader-extracted blocks, windowed transcript segments). There is no hallucination surface because there is no text synthesis anywhere.
2. **Advisory until anchored.** The panel's only writes run through the user's explicit Anchor button, into Phase 2's existing composer tail. Dismissal writes nothing; there is no "suggested" state in the schema — SPEC principle 4, implemented by omission.

## What shipped

| File | Holds |
|---|---|
| `BibliographyMatcher.swift` | `BibliographyPassage`/`PassageMatch`, the `PassageMatcher` protocol (SPEC's mock-first seam — Phase 6 reuses it), `LexicalPassageMatcher` (IDF-weighted overlap, length-damped, deterministic tie-break), `EmbeddingPassageMatcher` (NLEmbedding re-rank of the lexical top-K, silent fallback when the language has no embedding; `distanceOverride` is the test seam), `BibliographyCorpus` (blocks + ~280-char transcript windows; dismissed sources excluded) |
| `BibliographyPanel.swift` | shared SwiftUI: debounced query, Strong/Possible bands, Anchor/Open per result. Mac floats bottom-trailing in the existing overlay group; iOS is a sheet |
| `AnchorComposer.anchorPassage` | the acceptance tail for text passages (text-fragment locator from the passage) |
| command plumbing | **⌃⌘B** `bibliographySearch` (the ⌃⌘ row is now the research row: N/T/G/B), Mac monitor dispatch, iPad registry, iPhone workspace-switcher entry. Mac prefills from the focused pane's selection (`DocumentPaneView.selectedText()`); iOS opens empty |

**No schema change, no sync change, no persisted index** — the corpus is assembled per panel-open (ADR 0007's rebuildable-index rule; add a disk layer behind `BibliographyCorpus` if a real bibliography ever makes this slow).

## Semantics pinned by tests (12 tests, 3 suites)

Tokenizer drops stopwords/punctuation; overlap outranks noise and zero-overlap passages never appear; band = query-term coverage (≥½ and ≥2 terms → strong); empty/stopword-only queries are silent; ties break on passage id, not input order (deterministic across runs); the embedding re-rank falls back to lexical order when no distance is available and reorders by distance when one is; any `PassageMatcher` conformer slots in; transcript windowing merges short captions into ≥40-char windows spanning correct start/end times and drops nothing.

## Gotchas

- `EmbeddingPassageMatcher` constructs `NLEmbedding` per query — cheap enough at panel cadence; hoist it if it ever shows in a trace.
- The panel's empty-corpus copy leans on Phase 3's semantics: shared/deferred sources have no text until first opened. That's the designed behavior, not a bug to "fix" with background extraction.
- Prefill comes from the *document pane's* selection only; a web page selection is deliberately not a bibliography query (that's what anchoring is for).

## Not built, deliberately

Claim extraction (Phase 6 — same corpus, same protocol, push instead of pull); open-web or cross-workspace retrieval; credibility scoring/provenance/citation APIs; hosted models, API keys, telemetry; a persisted index.
