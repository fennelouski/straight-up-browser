# Thought Flow Phase 6 — Handoff

Phase 6 (background claim extraction) is implemented, unit-tested, and on `main`. Built unattended ([design call]s in `docs/phase6-design.md`); manual verification pending (checklist, Phase 6 section). With it, **every entity Phase 1 created finally has a writer**: `LedgerClaim` and `LedgerEdge.claimId` were reserved in Phase 1 and first written here.

## The rules this phase adds

1. **Selection, never generation.** The heuristic extractor picks claim-shaped sentences; the FoundationModels extractor (only where the OS model exists AND the user's AI Features switch is on — the `AgentPageAI` gating pattern) is instructed to copy verbatim and is then *checked*: any line the paragraph doesn't literally contain is discarded. Paraphrase is structurally impossible.
2. **Paragraph-settle, hash-gated.** `ClaimScout` re-scans 3s after the last change; paragraphs are SHA-256 hashed and only new hashes are extracted (SPEC's never-re-extract rule, a test counts extractor calls to pin it). Nothing persists — candidates, dismissals, and the cache all die with the panel.
3. **Promotion is the only write.** `LedgerStore.promoteClaim` fetch-then-inserts on `normalizedText` (dedup across projects, as Phase 1's comment promised), then `stampClaim` sets `claimId` on the document's edges inside the claim's paragraph — never overwriting an earlier claim.

## What shipped

| File | Holds |
|---|---|
| `ClaimExtraction.swift` | `ClaimExtractor` protocol (the Phase 5 seam pattern), `HeuristicClaimExtractor` (sentence segmentation + token-based claim-shape test: number, marker token, or split comparative "more … than"), `FoundationModelClaimExtractor` (verbatim-guarded, availability-gated), `ClaimCandidate`, `ClaimScout` |
| `ClaimsPanel.swift` | the ONLY surface candidates appear on: Research plan (unanchored — SPEC's to-do) with **Find Support** (hands the claim to Phase 5's bibliography panel) and **Promote**; Supported group; per-session dismiss |
| `LedgerStore` | `promoteClaim`, `claimExists(normalizedFrom:)`, `stampClaim` |
| plumbing | **⌃⌘C** — the research row is now complete: ⌃⌘N documents, ⌃⌘T transcripts, ⌃⌘G audit, ⌃⌘B bibliography, ⌃⌘C claims. Mac bottom-LEADING overlay (bibliography holds bottom-trailing, so both can be up); iOS sheet; iPhone switcher entry |

**No schema change** — two Phase 1 columns gained writers, nothing else moved.

## Deviation from the design doc

§2 says "the scout runs per open editor session"; as built, the scout is owned by the **panel** and runs while the panel is open (plus a full immediate scan at open). Because extraction is hash-gated, opening the panel yields identical results to an always-on scout at lower cost; the paragraph-settle debounce still governs live typing while the panel is up. Recorded here per the no-silent-drift rule.

## Gotchas

- The heuristic's marker test is **token-based**, not phrase-based — a phrase list broke on inflection ("reduce"/"reduces") and split comparatives ("more vitamin C than"). Extend `markerTokens`, not phrases.
- `ClaimScout` reuses `AuditModel.parseBlocks` for paragraph ranges — a deliberate coupling: claims and the audit view must agree on what a "paragraph" is, or the research plan and the unsupported-claims mode drift apart.
- `stampClaim` never overwrites an existing `claimId` (a test pins it). Re-claiming a paragraph is not a merge tool; if reassignment is ever wanted, it's a new, explicit gesture.

## Not built, deliberately

Persisted candidates/dismissals; extraction over sources; automatic anchoring; a claims browser across documents (Phase 7+ can render `claimId` groups in the audit view); paraphrase, summarization, or any generation.
