# Thought Flow — Phase 6 Design

Background claim extraction. **No interview was held** (unattended, same protocol as Phases 3–5); every decision is a **[design call]**. SPEC scope: "Trigger on paragraph-settle debounce, never per keystroke. Content-hash each paragraph; never re-extract unchanged text. Output is advisory; accepted claims become ledger objects, the rest vanish. The 'research plan' is the list of extracted-but-unanchored claims — a to-do generated from the user's own writing."

## Context

Everything this phase needs already exists: `LedgerClaim` has sat writerless since Phase 1 ("both exist because Phase 2+ references them"), `LedgerEdge.claimId` has waited for a promoter, Phase 5 built the mock-first extraction seam pattern AND the "find support" surface a research-plan item wants to jump into, and the app already has an on-device LLM precedent (`AgentPageAI`: `FoundationModels`' `LanguageModelSession`, availability-gated, behind `aiFeaturesEnabled`).

## Decisions

1. **Extraction is behind a protocol; the default needs no model.** [design call]
   ```swift
   protocol ClaimExtractor { func claims(in paragraph: String) -> [String] }
   ```
   - `HeuristicClaimExtractor` ships as the default: sentence segmentation plus a deterministic claim-shape test (declarative, bounded length, carries a number/comparative/causal marker). No model, identical everywhere, fully unit-tested. It will miss subtle claims and that is fine — advisory output has no completeness contract.
   - `FoundationModelClaimExtractor` layers on **only** where the OS model is available *and* the user's existing AI Features switch is on — exactly the `AgentPageAI` pattern (`#if canImport(FoundationModels)`, `SystemLanguageModel.default.availability`, graceful nil on any error). It extracts verbatim sentences, never paraphrases: the prompt demands substrings, and anything the paragraph doesn't literally contain is discarded by a containment check — the model can select, never write.

2. **The scout runs per open editor session, on paragraph settle.** [design call] `ClaimScout` observes a `DocumentEditSession`'s text; a 3-second debounce after the last change re-hashes paragraphs (SHA-256 per paragraph) and extracts **only paragraphs whose hash is new** — SPEC's never-re-extract rule, implemented as a hash-keyed cache for the session's lifetime. Never per keystroke, nothing persisted, no background task beyond the debounce timer, and suspension-safe by construction (everything dies with the session).

3. **Silence is the default.** [design call] Candidates live only in the scout's memory. No badge, no toast, no dot. They are visible in exactly one place: the claims panel (**⌃⌘C** — the research row grows to N/T/G/B/C), which shows two groups:
   - **Research plan** — candidates in paragraphs with **no edge**: extracted-but-unanchored, SPEC's to-do. Each offers **Find Support** (opens Phase 5's bibliography panel prefilled with the claim — the two features complete each other) and **Promote**.
   - **Supported** — candidates whose paragraph already has edges; each offers **Promote**.
   Dismissing a candidate removes it for this session and writes nothing. Closing the panel writes nothing.

4. **Promotion is the only write.** [design call] Accept → `LedgerStore.promoteClaim(text:)`: fetch-then-insert on `normalizedText` (the Phase 1 dedup key, no `.unique` under CloudKit), then stamp `claimId` onto this document's edges whose range falls inside the claim's paragraph — `LedgerEdge.claimId`'s first writer. Same claim accepted in another workspace's document later: the normalized fetch finds it — dedup across projects, as the Phase 1 comment promised.

## Schema

**No new entities, no new columns.** `LedgerClaim` gains its first writer; `LedgerEdge.claimId` gains its first stamps. No migration, no sync changes (both models have been in `.research` since Phase 1).

## New files

| File | Holds |
|---|---|
| `Straight Up Browser/ClaimExtraction.swift` | the protocol, `HeuristicClaimExtractor`, `FoundationModelClaimExtractor` (verbatim-only, availability + AI-switch gated), `ClaimScout` (paragraph hashing, debounce, cache, candidates) |
| `Straight Up Browser/ClaimsPanel.swift` | shared SwiftUI: Research plan / Supported groups, Promote / Find Support / dismiss. Mac overlay group; iOS sheet |
| `Straight Up BrowserTests/Phase6Tests.swift` | heuristic shape tests, hash-cache never-re-extract, scout debounce/candidate lifecycle, promotion dedup + edge stamping, verbatim containment guard |

Existing files touched: `LedgerStore.swift` (`promoteClaim`, `stampClaim`), `DocumentEditSession` (scout attach point), the usual ⌃⌘C command plumbing, ContentView/BrowserView wiring, the workspace-switcher entry, bibliography-panel prefill hand-off.

## Not built, deliberately

Persisted candidates or rejections (silence means no memory of what was declined); any paraphrase or summary generation; claim extraction over *sources* (this phase reads the user's own writing only); automatic anchoring; cross-document claim views (the audit view's `claimId` rendering can come with Phase 7's provenance work); any hosted model.
