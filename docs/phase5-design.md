# Thought Flow — Phase 5 Design

Bibliography matching. **No interview was held** (unattended, same protocol as Phases 3–4); every decision is a **[design call]**. SPEC scope: "'Does anything in my bibliography support this sentence?' Retrieval over the user's own saved sources only — no open-web search, no hallucination surface. First AI feature because it runs on trusted data." SPEC's technical constraint governs the shape: **all model access behind a protocol from day one, so matching is built against mocks before any real inference** — and design principle 4: AI is advisory, surfaces in a panel, becomes real only when the user accepts or anchors; silence is the default.

## Decisions

1. **The gesture.** [design call] With a document focused, select a sentence (or just leave the caret in a paragraph) and press **⌃⌘B** ("b": ⌥⌘B and ⇧⌘B are taken; ⌃⌘B is free — the ⌃⌘ row is becoming the research row: N documents, T transcripts, G audit, B bibliography). A panel opens with the query prefilled and the best-matching passages from the workspace's own sources. Also reachable from the iPhone workspace switcher and the iOS document header is left alone (two buttons is enough).

2. **The corpus is exactly the bibliography.** [design call] Passages come from two places only, both already on device: the reader-extracted text of the workspace's captured sources (`NewspaperArticle.originalDocument.blocks` — block-level plain text, stable ids) and stored transcript segments (`SourceTranscript`, whose hits carry timestamps). Dismissed sources are excluded. Nothing is fetched; a source with no extracted text simply contributes nothing (it is `deferred` — open it once to fill it).

3. **Matching is behind a protocol, lexical first.** [design call]
   ```swift
   protocol PassageMatcher { func rank(query: String, passages: [BibliographyPassage]) -> [PassageMatch] }
   ```
   - `LexicalPassageMatcher` ships as the default: normalized token overlap with IDF weighting (BM25-shaped, pure Swift, deterministic, fully unit-tested). No model, no download, works identically on every platform.
   - `EmbeddingPassageMatcher` layers on where the OS provides it: `NLEmbedding.sentenceEmbedding` (NaturalLanguage framework, entirely on-device) re-ranks the lexical top-K by cosine similarity. If the embedding is unavailable for the language, the lexical ranking stands. No third implementation, no remote anything.
   - The protocol is the Phase 6 seam: claim extraction will want the same corpus and the same mock-first testing.

4. **The index is rebuilt, never persisted.** [design call] ADR 0007's rule ("a rebuildable local index in the phase that first needs it"): the corpus is assembled per panel-open from live rows, cached in memory keyed by `sourceDigest`/`fetchedAt` for the panel's lifetime. Realistic bibliographies are dozens of sources; if profiling ever disagrees, the cache grows a disk layer — behind the same assembler.

5. **A match becomes real only by anchoring.** [design call] Each result shows the passage, its source, and the score band (strong/possible — never a raw float in UI); its **Anchor** button runs the existing composer tail: a `LedgerAnchor` with a text-fragment locator (or timestamp locator for transcript hits) and the passage as quote, link appended to the current document and copied — precisely what the manual gesture would have produced. Dismissing the panel writes nothing, stores nothing, logs nothing. There is no "AI suggested this" state anywhere in the schema.

## Schema

**Nothing.** No new entities, no columns, no sync changes. The panel reads; only the user's explicit Anchor writes, through Phase 2's existing paths.

## New files

| File | Holds |
|---|---|
| `Straight Up Browser/BibliographyMatcher.swift` | `BibliographyPassage`/`PassageMatch`, the `PassageMatcher` protocol, `LexicalPassageMatcher` (tokenizer + IDF scoring), `EmbeddingPassageMatcher` (NLEmbedding re-rank), corpus assembly from the stores |
| `Straight Up Browser/BibliographyPanel.swift` | shared SwiftUI panel: query field, result cards, Anchor/Open actions. Mac: the existing overlay group; iOS: a sheet |
| `Straight Up BrowserTests/Phase5Tests.swift` | tokenizer, IDF ranking, mock-matcher protocol conformance, corpus exclusion rules, transcript passages carrying timestamps, anchor-tail integration |

Existing files touched: the usual command plumbing (⌃⌘B `bibliographySearch`), ContentView/BrowserView wiring, workspace-switcher entry.

## Not built, deliberately

Claim extraction (Phase 6 — this panel is pull, not push); open-web retrieval; cross-workspace search (the bibliography is the workspace's); credibility scoring, provenance tracing, citation-graph APIs (OpenAlex/Crossref — later phases); any hosted model, any API key, any telemetry.
