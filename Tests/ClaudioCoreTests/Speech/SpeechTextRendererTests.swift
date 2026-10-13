import ClaudioCore
import TestSupport
import XCTest

final class SpeechTextRendererTests: XCTestCase {
    let renderer = SpeechTextRenderer()

    private func segments(_ md: String) -> [Utterance.Segment] { renderer.renderSegments(md) }
    private func text(_ md: String) -> String { segments(md).map(\.text).joined(separator: " ") }

    func test_SpeechTextRenderer_fencedCodeWithLanguage_becomesLanguageCodeBlock() {
        let s = segments("Before.\n\n```swift\nlet x = 1\n```\n\nAfter.")
        XCTAssertEqual(s.map(\.kind), [.sentence, .cue, .sentence])
        XCTAssertEqual(s[1].text, "Swift code block.")
    }

    func test_SpeechTextRenderer_fencedCodeNoLanguage_andUnterminated() {
        XCTAssertEqual(segments("```\nx\n```").map(\.text), ["code block."])
        XCTAssertEqual(segments("Intro sentence that is long enough to stand alone here.\n```js\nnever closed").map(\.text).last, "JavaScript code block.")
    }

    func test_SpeechTextRenderer_indentedCode_becomesCodeBlock_butListContinuationDoesNot() {
        XCTAssertEqual(segments("Para.\n\n    indented code\n    more").map(\.kind), [.sentence, .cue])
        let list = segments("- item one\n    continued here")
        XCTAssertEqual(list.map(\.kind), [.listItem])
        XCTAssertEqual(list[0].text, "item one continued here.")
    }

    func test_SpeechTextRenderer_gfmTable_oneSegmentPerBodyRow_headerNotRead() {
        let md = "| Name | Value |\n|---|---:|\n| a | 1 |\n| b \\| c | |\n| d | 3 | extra |"
        let s = segments(md)
        XCTAssertEqual(s.map(\.kind), [.tableRow, .tableRow, .tableRow])
        XCTAssertEqual(s[0].text, "Name: a, Value: 1.")
        XCTAssertEqual(s[1].text, "Name: b | c, Value: empty.")
        XCTAssertEqual(s[2].text, "Name: d, Value: 3, column 3: extra.")
        XCTAssertTrue(segments("| H1 | H2 |\n|---|---|").isEmpty)
    }

    func test_SpeechTextRenderer_headings_andSetext() {
        XCTAssertEqual(segments("## Reading order ##").first?.text, "Reading order")
        XCTAssertEqual(segments("# Title").map { ($0.kind, $0.text) }.first?.1, "Title")
        XCTAssertEqual(segments("Title\n===").first?.kind, .heading)
    }

    func test_SpeechTextRenderer_lists_flattenedAndTaskMarkers() {
        let s = segments("1. First\n2. Second\n   - nested child\n- [x] done thing\n- [ ] todo thing")
        XCTAssertEqual(s.map(\.kind), Array(repeating: .listItem, count: 5))
        XCTAssertEqual(s.map(\.text), ["First.", "Second.", "nested child.", "done: done thing.", "todo thing."])
    }

    func test_SpeechTextRenderer_inlineRules() {
        XCTAssertEqual(text("See [the docs](https://x.y/z) now."), "See the docs now.")
        XCTAssertEqual(text("Go to https://a.b/c?d=1 please."), "Go to link please.")
        XCTAssertEqual(text("![diagram](a.png) Then **bold** and *italic* and ~~gone~~."), "Then bold and italic and gone.")
        XCTAssertEqual(text("Use `TranscriptTailer.swift` here."), "Use Transcript Tailer dot swift here.")
        XCTAssertEqual(text("Call `message.stop_reason` or `URLSession`."), "Call message stop reason or URL Session.")
        XCTAssertEqual(text("Edit /Users/j/dev/claudio/Sources/App.swift now."), "Edit App dot swift now.")
        XCTAssertEqual(text("Open ~/dev/claudio/README.md now."), "Open README dot M D now.")
        XCTAssertEqual(text("Run with --dry-run and -v flags."), "Run with dry run and dash v flags.")
        XCTAssertEqual(text("Map a -> b => c."), "Map a to b to c.")
        XCTAssertEqual(text("Salt & pepper, x == y, a <= b."), "Salt and pepper, x equals y, a at most b.")
        XCTAssertEqual(text("Done ✅ 🎉 now."), "Done now.")
        XCTAssertEqual(text("Build all *.swift now."), "Build all swift files now.")
        XCTAssertEqual(text("See the parser (Parser.swift:42) for it."), "See the parser Parser dot swift line 42 for it.")
        XCTAssertEqual(text("Really?! Wow..."), "Really? Wow.")
        XCTAssertEqual(text("Keep version 2.1.290 and 50% and $3.50 intact."), "Keep version 2.1.290 and 50% and $3.50 intact.")
        XCTAssertEqual(text("Session 562358f2 has pid 21934 in 2026."), "Session 5 6 2 3 5 8 F 2 has pid 2 1 9 3 4 in 2026.")
        XCTAssertEqual(text("Costs 1,000,000 or 12345."), "Costs 1,000,000 or 1 2 3 4 5.")
        XCTAssertEqual(text("Id `a01c0993` and `deadbeef`."), "Id A 0 1 C 0 9 9 3 and deadbeef.")
        XCTAssertEqual(text("Ref 11111111-2222-4333-8444-555555555555 here."), "Ref 1 1 1 1 1 1 1 1, 2 2 2 2, 4 3 3 3, 8 4 4 4, 5 5 5 5 5 5 5 5 5 5 5 5 here.")
    }

    func test_SpeechTextRenderer_stageOrder_codeBeforeInline() {
        // An arrow inside inline code is rewritten once by the code cleanup, not again by the arrow rule.
        XCTAssertEqual(text("Type `a -> b` here."), "Type a to b here.")
        XCTAssertEqual(text("Flag `--foo-bar` stays."), "Flag --foo-bar stays.")
    }

    func test_SpeechTextRenderer_blockCleanup() {
        XCTAssertEqual(text("> quoted line\n\n---\n\n<b>bold</b> text\n\n[ref]: https://x.y"), "quoted line bold text")
        XCTAssertEqual(text("line one\u{1B}[31m red\u{1B}[0m\r\nline two"), "line one red line two")
    }

    func test_SpeechTextRenderer_emptyAndEventItems() {
        XCTAssertTrue(segments("").isEmpty)
        XCTAssertTrue(segments("   \n\n").isEmpty)
        let event = SpeechItem(sessionID: "s", turnID: nil, category: .event, text: Cues.mark("Yard finished."), timestamp: Date())
        let u = renderer.render(event)
        XCTAssertEqual(u.segments.map { ($0.kind, $0.text) }.first?.1, "Yard finished.")
        XCTAssertEqual(u.segments.first?.kind, .cue)
    }

    func test_SpeechTextRenderer_neverThrows_onRandomInput() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            let bytes = (0..<Int.random(in: 0..<400, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }
            let s = String(decoding: bytes, as: UTF8.self)
            _ = renderer.renderSegments(s)
        }
    }

    func test_SpeechTextRenderer_goldenCorpus() throws {
        let dir = try XCTUnwrap(TestFixtures.url("markdown"))
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".md") }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let md = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
            let expected = try String(contentsOf: dir.appendingPathComponent(file.replacingOccurrences(of: ".md", with: ".expected.txt")), encoding: .utf8)
                .split(separator: "\n").map(String.init)
            let actual = segments(md).map { "\($0.kind.rawValue)|\($0.text)" }
            XCTAssertEqual(actual, expected, file)
        }
    }

    func test_inlineCodeCleanup_rules() {
        XCTAssertEqual(SpeechTextRenderer.inlineCodeCleanup("Parser.swift"), "Parser dot swift")
        XCTAssertEqual(SpeechTextRenderer.inlineCodeCleanup("index.ts"), "index dot T S")
        XCTAssertEqual(SpeechTextRenderer.inlineCodeCleanup("SCREAMING_SNAKE_case"), "SCREAMING SNAKE case")
        XCTAssertEqual(SpeechTextRenderer.inlineCodeCleanup("Array<String>"), "Array String")
        XCTAssertEqual(SpeechTextRenderer.inlineCodeCleanup("foo()"), "foo")
        XCTAssertEqual(SpeechTextRenderer.inlineCodeCleanup("kebab-case"), "kebab-case")
    }
}
