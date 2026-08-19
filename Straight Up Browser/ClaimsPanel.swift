//
//  ClaimsPanel.swift
//  Straight Up Browser
//
//  The claims panel (Phase 6, docs/phase6-design.md §3): the ONLY place
//  candidates appear. Research plan = extracted-but-unanchored; Supported =
//  the paragraph already cites something. Promotion is the only write;
//  everything else vanishes without a trace.
//

import SwiftUI

struct ClaimsPanel: View {
    @ObservedObject var session: DocumentEditSession
    let ledgerStore: LedgerStore
    /// Opens Phase 5's bibliography panel prefilled with the claim.
    let onFindSupport: (String) -> Void
    var onClose: (() -> Void)? = nil

    @StateObject private var scout = ClaimScout()
    @State private var note: String?

    private var researchPlan: [ClaimCandidate] { scout.candidates.filter { !$0.hasSupport } }
    private var supported: [ClaimCandidate] { scout.candidates.filter(\.hasSupport) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary).padding(.vertical, 6)
            }
        }
        #if os(macOS)
        .frame(width: 440)
        .frame(maxHeight: 540)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        #endif
        .task {
            if !session.isLoaded { await session.open() }
            scout.isAlreadyPromoted = { [weak ledgerStore] text in
                ledgerStore?.claimExists(normalizedFrom: text) ?? false
            }
            rescan(immediate: true)
        }
        .onChange(of: session.text) { _, _ in rescan() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "checklist")
                .foregroundStyle(.secondary)
            Text("Claims")
                .font(.headline)
            if scout.isExtracting { ProgressView().controlSize(.small) }
            Spacer()
            Button {
                onClose?()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel(String(localized: "Close claims panel"))
        }
        .padding(10)
    }

    @ViewBuilder private var content: some View {
        if scout.candidates.isEmpty {
            Text(scout.isExtracting
                 ? String(localized: "Reading your writing…")
                 : String(localized: "No checkable claims found in this document yet. Keep writing — this list is your research plan."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(24)
                .frame(maxWidth: .infinity, minHeight: 120)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if !researchPlan.isEmpty {
                        sectionHeader(String(localized: "Research plan — claims with no anchor yet"))
                        ForEach(researchPlan) { candidate in
                            candidateCard(candidate, needsSupport: true)
                        }
                    }
                    if !supported.isEmpty {
                        sectionHeader(String(localized: "Supported paragraphs"))
                        ForEach(supported) { candidate in
                            candidateCard(candidate, needsSupport: false)
                        }
                    }
                }
                .padding(10)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    private func candidateCard(_ candidate: ClaimCandidate, needsSupport: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(candidate.text)
                .font(.system(size: 12))
                .lineLimit(4)
            HStack(spacing: 6) {
                if needsSupport {
                    Button(String(localized: "Find Support")) { onFindSupport(candidate.text) }
                        .controlSize(.small)
                }
                Button(String(localized: "Promote")) { promote(candidate) }
                    .controlSize(.small)
                    .help(String(localized: "Make this a named claim, deduplicated across projects"))
                Spacer()
                Button {
                    scout.dismiss(candidate)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(String(localized: "Dismiss claim"))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(needsSupport ? Color.yellow.opacity(0.10) : Color.primary.opacity(0.05)))
        .accessibilityElement(children: .combine)
    }

    private func rescan(immediate: Bool = false) {
        scout.noteText(
            session.text,
            resolvedLinkRanges: session.resolvedLinks.map(\.match.range),
            immediate: immediate
        )
    }

    /// The only write in this panel (design §4): claim row + edge stamps.
    private func promote(_ candidate: ClaimCandidate) {
        let claim = ledgerStore.promoteClaim(text: candidate.text)
        ledgerStore.stampClaim(
            claim.id, documentId: session.documentId, within: candidate.paragraphRange)
        scout.dismiss(candidate)
        note = String(localized: "Promoted — this claim now deduplicates across projects.")
    }
}
