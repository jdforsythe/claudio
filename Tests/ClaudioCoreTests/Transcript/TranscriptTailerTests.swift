import ClaudioCore
import TestSupport
import XCTest

final class TranscriptTailerTests: XCTestCase {
    var root = TempRoot()
    override func tearDown() { root.cleanup() }

    private func write(_ lines: [Data], to url: URL, append: Bool = true, trailingNewline: Bool = true) {
        var data = Data()
        for (i, l) in lines.enumerated() {
            data.append(l)
            if i < lines.count - 1 || trailingNewline { data.append(0x0A) }
        }
        if append, let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: url)
        }
    }

    private func collect(_ collector: RecordCollector, expect: Int, budget: TimeInterval = 2) async -> [TranscriptRecord] {
        _ = await waitUntil(budget) { collector.records.count >= expect }
        return collector.records
    }

    func test_TranscriptTailer_attach_startsAtEndOfFile() async {
        let url = root.path("s.jsonl")
        write((0..<200).map { RecordBuilder.humanPrompt("old \($0)", promptID: "p\($0)") }, to: url, append: false)
        let tailer = TranscriptTailer(url: url, sessionID: "s")
        let collector = RecordCollector(tailer.records)
        await tailer.wakeAndWait()
        let got = await collect(collector, expect: 1, budget: 0.5)
        XCTAssertEqual(got.count, 0)
    }

    func test_TranscriptTailer_append_emitsNewLinesOnly() async {
        let url = root.path("s.jsonl")
        write([RecordBuilder.humanPrompt("old", promptID: "p0")], to: url, append: false)
        let tailer = TranscriptTailer(url: url, sessionID: "s")
        let collector = RecordCollector(tailer.records)
        await tailer.wakeAndWait()
        write([RecordBuilder.humanPrompt("new1", promptID: "p1"), RecordBuilder.humanPrompt("new2", promptID: "p2")], to: url)
        await tailer.wakeAndWait()
        let got = await collect(collector, expect: 2)
        XCTAssertEqual(got.map(\.envelope.promptID), ["p1", "p2"])
    }

    func test_TranscriptTailer_partialLine_bufferedUntilNewline() async {
        let url = root.path("s.jsonl")
        write([], to: url, append: false)
        let tailer = TranscriptTailer(url: url, sessionID: "s")
        let collector = RecordCollector(tailer.records)
        await tailer.wakeAndWait()
        let line = RecordBuilder.humanPrompt("split line", promptID: "p1")
        let half = line.count / 2
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.prefix(half)); try? h.close() }
        await tailer.wakeAndWait()
        let collected13 = await collect(collector, expect: 1, budget: 0.3)
        XCTAssertEqual(collected13.count, 0)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.suffix(from: half)); h.write(Data([0x0A])); try? h.close() }
        await tailer.wakeAndWait()
        let got = await collect(collector, expect: 1)
        XCTAssertEqual(got.first?.envelope.promptID, "p1")
    }

    func test_TranscriptTailer_truncation_resetsToNewEnd() async {
        let url = root.path("s.jsonl")
        write((0..<5).map { RecordBuilder.humanPrompt("old \($0)", promptID: "p\($0)") }, to: url, append: false)
        let tailer = TranscriptTailer(url: url, sessionID: "s")
        let collector = RecordCollector(tailer.records)
        await tailer.wakeAndWait()
        // Truncate to one old line (timestamp before attach) then append a new line with a future timestamp.
        write([RecordBuilder.humanPrompt("old", promptID: "p0", timestamp: "2020-01-01T00:00:00.000Z")], to: url, append: false)
        await tailer.wakeAndWait()
        let future = TranscriptParser.formatDate(Date().addingTimeInterval(60))
        write([RecordBuilder.humanPrompt("new", promptID: "pnew", timestamp: future)], to: url)
        await tailer.wakeAndWait()
        let got = await collect(collector, expect: 1)
        XCTAssertEqual(got.map(\.envelope.promptID), ["pnew"])
    }

    func test_TranscriptTailer_largeAppend_readsInOneMiBChunks() async {
        let url = root.path("s.jsonl")
        write([], to: url, append: false)
        let tailer = TranscriptTailer(url: url, sessionID: "s")
        let collector = RecordCollector(tailer.records)
        await tailer.wakeAndWait()
        let big = String(repeating: "x", count: 1_500_000)
        write([RecordBuilder.line(["type": "unknown-big", "sessionId": "s", "payload": big]), RecordBuilder.humanPrompt("after", promptID: "p1")], to: url)
        await tailer.wakeAndWait()
        let got = await collect(collector, expect: 2)
        XCTAssertEqual(got.count, 2)
        XCTAssertEqual(got.last?.envelope.promptID, "p1")
    }

    func test_TranscriptTailer_peekTitle_findsLastTitle() {
        let url = root.path("s.jsonl")
        write([RecordBuilder.aiTitle("First"), RecordBuilder.humanPrompt("x", promptID: "p"), RecordBuilder.aiTitle("Second")], to: url, append: false)
        XCTAssertEqual(TranscriptTailer.peekTitle(url: url), "Second")
        XCTAssertEqual(TranscriptTailer.peekCwd(url: url), RecordBuilder.cwd)
    }
}
