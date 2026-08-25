import Foundation
import Testing
@testable import Browser

struct PaperNoteTests {
    @Test("arXiv PDF URLs are papers even without a .pdf extension")
    func arxivPDFIsPDF() {
        #expect(PaperNote.isPDF(URL(string: "https://arxiv.org/pdf/2401.12345v2")))
        #expect(PaperNote.isPDF(URL(string: "https://example.org/paper.pdf")))
        #expect(!PaperNote.isPDF(URL(string: "https://arxiv.org/abs/2401.12345")))
    }

    @Test("PDF pages become paragraph blocks; giant runs are packed by sentence")
    func pagesBecomeParagraphs() throws {
        let long = String(repeating: "This is a sentence about results. ", count: 60) // ~2k chars
        let article = try #require(PaperNote.readerArticle(
            pages: ["Line one\nline two\n\nSecond paragraph.", long], title: "T"))
        #expect(article.blocks[0].plainText == "Line one line two")
        #expect(article.blocks[1].plainText == "Second paragraph.")
        #expect(article.blocks.count > 3)
        #expect(article.blocks.dropFirst(2).allSatisfy { $0.plainText.count <= 1_200 })
    }

    @Test("Tagged lines are parsed tolerantly, merged deterministically, and gaps are named")
    func factsMergeIntoEvidenceNote() {
        let response = """
            Here are the notes:
            - RESULT: BLEU 34.2 on WMT14 En-De, +1.1 over baseline
            * method: 6-layer encoder, d_model = 512
            RESULT: bleu 34.2 on wmt14 en-de, +1.1 over baseline
            ignored line without a tag
            LIMITATION:
            """
        let facts = PaperNote.facts(in: response)
        #expect(facts.count == 3)
        let markdown = PaperNote.markdown(facts: facts)
        #expect(markdown.contains("## Results\n- BLEU 34.2 on WMT14 En-De, +1.1 over baseline"))
        #expect(markdown.contains("## Method\n- 6-layer encoder, d_model = 512"))
        #expect(!markdown.contains("wmt14 en-de")) // case-insensitive dedupe
        #expect(markdown.contains("## Not established in this source"))
        #expect(markdown.contains("research question, limitations"))
    }
}
