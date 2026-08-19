//
//  Phase4Tests.swift
//  Straight Up BrowserTests
//
//  The graph/audit view's model (docs/phase4-design.md): block parsing,
//  offset-vs-quote edge mapping, and the three modes' computations — all pure,
//  no SwiftData.
//

import Foundation
import Testing
@testable import Browser

struct AuditBlockParsingTests {

    @Test func blankLineSeparatedBlocksKeepTheirRanges() {
        let text = "# Title\n\nFirst paragraph here.\n\nSecond paragraph."
        let blocks = AuditModel.parseBlocks(text)
        #expect(blocks.count == 3)
        #expect(blocks[0].isHeading)
        #expect(!blocks[1].isHeading)
        let nsText = text as NSString
        #expect(nsText.substring(with: blocks[1].range) == "First paragraph here.")
        #expect(nsText.substring(with: blocks[2].range) == "Second paragraph.")
    }

    @Test func emptyRunsProduceNoBlocks() {
        let blocks = AuditModel.parseBlocks("One.\n\n\n\nTwo.\n\n")
        #expect(blocks.map(\.text) == ["One.", "Two."])
    }
}

struct AuditEdgeMappingTests {

    private let markdown = "Intro paragraph.\n\nA claim about [gut bacteria](https://x.example) here.\n\nOutro."

    private func edge(start: Int, length: Int, quote: String = "gut bacteria") -> AuditModel.EdgeInput {
        AuditModel.EdgeInput(id: UUID(), anchorId: UUID(), quote: quote, start: start, length: length)
    }

    @Test func validOffsetsWin() {
        let blocks = AuditModel.parseBlocks(markdown)
        let range = (markdown as NSString).range(of: "[gut bacteria](https://x.example)")
        let index = AuditModel.blockIndex(for: edge(start: range.location, length: range.length),
                                          in: markdown, blocks: blocks)
        #expect(index == 1)
    }

    @Test func staleOffsetsFallBackToTheQuote() {
        let blocks = AuditModel.parseBlocks(markdown)
        // Offsets point at the wrong text entirely (external edit shifted them).
        let index = AuditModel.blockIndex(for: edge(start: 0, length: 5),
                                          in: markdown, blocks: blocks)
        #expect(index == 1, "the quote is the truth; offsets are only the fast path")
    }

    @Test func unfindableQuotesMapNowhereWithoutError() {
        let blocks = AuditModel.parseBlocks(markdown)
        let index = AuditModel.blockIndex(for: edge(start: 9999, length: 4, quote: "vanished text"),
                                          in: markdown, blocks: blocks)
        #expect(index == nil)
    }
}

struct AuditModeTests {

    private func makeModel() -> AuditModel {
        let markdown = "# Notes\n\nSupported claim [a](https://a.example).\n\nUnsupported claim with no anchor.\n\n- just a list line"
        let sourceA = UUID(), sourceB = UUID(), sourceC = UUID(), press = UUID()
        let anchor = AuditModel.AnchorInput(id: UUID(), sourceId: sourceA, sourceKey: "https://a.example")
        let range = (markdown as NSString).range(of: "[a](https://a.example)")
        let edge = AuditModel.EdgeInput(id: UUID(), anchorId: anchor.id, quote: "a",
                                        start: range.location, length: range.length)
        let sources = [
            AuditModel.SourceInput(sourceId: sourceA, sourceKey: "https://a.example", title: "A",
                                   url: URL(string: "https://a.example"), disposition: .open, openedFromSourceId: nil),
            // B and C both spawned from the same press release: one fan.
            AuditModel.SourceInput(sourceId: sourceB, sourceKey: "https://b.example", title: "B",
                                   url: URL(string: "https://b.example"), disposition: .open, openedFromSourceId: press),
            AuditModel.SourceInput(sourceId: sourceC, sourceKey: "https://c.example", title: "C",
                                   url: URL(string: "https://c.example"), disposition: .open, openedFromSourceId: press),
        ]
        return AuditModel.build(
            markdown: markdown, edges: [edge], anchors: [anchor], sources: sources,
            citedSourceIdsInWorkspace: [sourceA]
        )
    }

    @Test func unsupportedClaimsAreProseBlocksWithoutEdges() {
        let model = makeModel()
        let unsupportedTexts = model.blocks.filter { model.unsupportedBlockIds.contains($0.id) }.map(\.text)
        #expect(unsupportedTexts.contains { $0.hasPrefix("Unsupported claim") })
        #expect(!unsupportedTexts.contains { $0.hasPrefix("#") }, "headings are never claims")
        #expect(!unsupportedTexts.contains { $0.hasPrefix("Supported") })
    }

    @Test func unusedIsWorkspaceWideAbsenceFromEdges() {
        let model = makeModel()
        let unused = model.sources.filter(\.isUnusedInWorkspace).map(\.title).sorted()
        #expect(unused == ["B", "C"])
        #expect(model.sources.first { $0.title == "A" }?.isUnusedInWorkspace == false)
    }

    @Test func sharedUpstreamGroupsTheFanAndOnlyTheFan() {
        let model = makeModel()
        let groupB = model.sources.first { $0.title == "B" }?.upstreamGroup
        let groupC = model.sources.first { $0.title == "C" }?.upstreamGroup
        #expect(groupB != nil && groupB == groupC, "one press release, one fan")
        #expect(model.sources.first { $0.title == "A" }?.upstreamGroup == nil, "no lineage, no group")
    }

    @Test func connectionsLinkBlocksToSources() {
        let model = makeModel()
        #expect(model.connections.count == 1)
        let connection = model.connections[0]
        #expect(model.blocks.first { $0.id == connection.blockId }?.text.hasPrefix("Supported") == true)
        #expect(model.sources.first { $0.sourceId == connection.sourceId }?.title == "A")
    }

    @Test func citedRailOrdersCitedBeforeUnused() {
        let model = makeModel()
        #expect(model.sources.first?.title == "A", "cited first, then the unused pile")
    }
}

struct AuditUpstreamCycleTests {

    @Test func lineageCyclesNeverHang() {
        let a = UUID(), b = UUID()
        let sources = [
            AuditModel.SourceInput(sourceId: a, sourceKey: "a", title: "A", url: nil,
                                   disposition: .open, openedFromSourceId: b),
            AuditModel.SourceInput(sourceId: b, sourceKey: "b", title: "B", url: nil,
                                   disposition: .open, openedFromSourceId: a),
        ]
        let groups = AuditModel.upstreamGroups(for: sources)
        #expect(groups[a] != nil && groups[a] == groups[b], "a cycle is still one family")
    }

    @Test func chainsCollapseToTheirRoot() {
        let root = UUID(), mid = UUID(), leaf = UUID(), lone = UUID()
        let sources = [
            AuditModel.SourceInput(sourceId: root, sourceKey: "r", title: "R", url: nil,
                                   disposition: .open, openedFromSourceId: nil),
            AuditModel.SourceInput(sourceId: mid, sourceKey: "m", title: "M", url: nil,
                                   disposition: .open, openedFromSourceId: root),
            AuditModel.SourceInput(sourceId: leaf, sourceKey: "l", title: "L", url: nil,
                                   disposition: .open, openedFromSourceId: mid),
            AuditModel.SourceInput(sourceId: lone, sourceKey: "x", title: "X", url: nil,
                                   disposition: .open, openedFromSourceId: nil),
        ]
        let groups = AuditModel.upstreamGroups(for: sources)
        #expect(groups[root] != nil && groups[root] == groups[mid] && groups[mid] == groups[leaf],
                "video cites blog cites press release: one chain, one family")
        #expect(groups[lone] == nil)
    }
}
