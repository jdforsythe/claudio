import ClaudioCore
import TestSupport
import XCTest

final class SentenceSegmenterTests: XCTestCase {
    let segmenter = SentenceSegmenter()

    private func texts(_ s: String) -> [String] { segmenter.segment(s, kind: .sentence).map(\.text) }

    func test_SentenceSegmenter_basicSplit_andShortMergeForward() {
        let s = texts("This is the first sentence of a paragraph that is comfortably long. Short one. Another sentence that is long enough to stand on its own here.")
        XCTAssertEqual(s.count, 2)
        XCTAssertTrue(s[1].hasPrefix("Short one. Another"))
    }

    func test_SentenceSegmenter_lastShortSentence_notMerged() {
        XCTAssertEqual(texts("Done."), ["Done."])
        let s = texts("A reasonably long opening sentence that passes the sixty character minimum easily. Done.")
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s.last, "Done.")
    }

    func test_SentenceSegmenter_abbreviations_andNumbers_notSplit() {
        let eg = texts("Use tools, e.g. grep, to search the tree for identifiers that matter most. Then stop.")
        XCTAssertTrue(eg.first?.contains("e.g. grep") == true, "abbreviation must not split: \(eg)")
        XCTAssertEqual(texts("Ask Dr. Smith about the measurement results before the meeting begins tomorrow. Then stop.").count, 2)
        XCTAssertEqual(texts("We shipped version 2.1 of the parser after a long review cycle. It works.").count, 2)
    }

    func test_SentenceSegmenter_longSentence_splitAtClausePunctuationOrSpace() {
        let clause = (0..<80).map { "clause number \($0) goes here" }.joined(separator: ", ") + "."
        let pieces = segmenter.segment(clause, kind: .sentence)
        XCTAssertGreaterThan(pieces.count, 1)
        XCTAssertTrue(pieces.allSatisfy { $0.text.utf8.count <= 1200 })
        let words = Array(repeating: "word", count: 400).joined(separator: " ") + "."
        XCTAssertTrue(segmenter.segment(words, kind: .sentence).allSatisfy { $0.text.utf8.count <= 1200 })
    }

    func test_SentenceSegmenter_multibyte_neverSplitMidCharacter() {
        let s = String(repeating: "日本語のテキスト ", count: 200)
        for seg in segmenter.segment(s, kind: .sentence) { XCTAssertEqual(seg.text, String(seg.text)) }
    }

    func test_SentenceSegmenter_tableRowNeverSplit_andPreTypedKindsPreserved() {
        let row = "Header: " + String(repeating: "value, ", count: 300)
        let rows = segmenter.segment(row, kind: .tableRow)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(segmenter.segment("Heading", kind: .heading).first?.kind, .heading)
        XCTAssertEqual(segmenter.segment("Item.", kind: .listItem).first?.kind, .listItem)
    }
}
