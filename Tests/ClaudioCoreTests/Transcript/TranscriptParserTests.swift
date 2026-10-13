import ClaudioCore
import TestSupport
import XCTest

final class TranscriptParserTests: XCTestCase {
    let parser = TranscriptParser()

    func test_TranscriptParser_assistantTextBlock_decodesTextAndStopReason() {
        let r = parser.record(RecordBuilder.text("Hello", messageID: "msg_1", stopReason: "end_turn", promptID: "p1", index: 2))
        guard case .assistantText(let messageID, let requestID, let blockIndex, let stopReason, let text) = r.payload else { return XCTFail("wrong payload") }
        XCTAssertEqual(messageID, "msg_1")
        XCTAssertEqual(requestID, "req_x")
        XCTAssertEqual(blockIndex, 2)
        XCTAssertEqual(stopReason, "end_turn")
        XCTAssertEqual(text, "Hello")
        XCTAssertEqual(r.envelope.sessionID, RecordBuilder.session)
        XCTAssertEqual(r.envelope.promptID, "p1")
        XCTAssertNotNil(r.envelope.timestamp)
    }

    func test_TranscriptParser_userStringContent_decodesAsHumanPrompt() {
        let r = parser.record(RecordBuilder.humanPrompt("hi there", promptID: "p1"))
        guard case .humanPrompt(let text, let origin, let source, _) = r.payload else { return XCTFail("wrong payload") }
        XCTAssertEqual(text, "hi there")
        XCTAssertEqual(origin, "human")
        XCTAssertEqual(source, "typed")
    }

    func test_TranscriptParser_userToolResult_decodesToolResult() {
        let r = parser.record(RecordBuilder.toolResult(toolUseID: "toolu_1", content: "ok", isError: true, toolUseResult: ["success": false], promptID: "p1"))
        guard case .toolResult(let id, let isError, let summary) = r.payload else { return XCTFail("wrong payload") }
        XCTAssertEqual(id, "toolu_1")
        XCTAssertTrue(isError)
        XCTAssertEqual(summary, "ok")
    }

    func test_TranscriptParser_mixedUserContent_isToolResult() {
        let block: [String: Any] = ["type": "tool_result", "tool_use_id": "t", "content": "x"]
        let line = RecordBuilder.line(RecordBuilder.envelope(type: "user", extra: ["message": ["role": "user", "content": [["type": "text", "text": "typed"], block]]]))
        guard case .toolResult = parser.record(line).payload else { return XCTFail("expected tool result") }
    }

    func test_TranscriptParser_systemTurnDuration_decodesDuration() {
        guard case .turnDuration(let ms, let count, _) = parser.record(RecordBuilder.turnDuration(ms: 4321)).payload else { return XCTFail("wrong") }
        XCTAssertEqual(ms, 4321)
        XCTAssertEqual(count, 3)
    }

    func test_TranscriptParser_aiTitle_decodes() {
        guard case .aiTitle(let t) = parser.record(RecordBuilder.aiTitle("My title")).payload else { return XCTFail("wrong") }
        XCTAssertEqual(t, "My title")
    }

    func test_TranscriptParser_unknownType_returnsUnknownWithTypeName() {
        guard case .unknown(let t) = parser.record(RecordBuilder.unknown("future-thing")).payload else { return XCTFail("wrong") }
        XCTAssertEqual(t, "future-thing")
    }

    func test_TranscriptParser_missingType_returnsUnknown() {
        let r = parser.record(Data(#"{"foo":1}"#.utf8))
        guard case .unknown(let t) = r.payload else { return XCTFail("wrong") }
        XCTAssertEqual(t, "")
    }

    func test_TranscriptParser_malformedJSON_returnsMalformed() {
        guard case .failure(.malformed(let offset, let prefix)) = parser.parse(line: Data("{not json".utf8), offset: 42) else { return XCTFail("expected malformed") }
        XCTAssertEqual(offset, 42)
        XCTAssertEqual(prefix, "{not json")
    }

    func test_TranscriptParser_fileHistorySnapshot_shortCircuits() {
        let big = String(repeating: "x", count: 100_000)
        let r = parser.record(Data(#"{"type":"file-history-snapshot","snapshot":{"data":"\#(big)"}}"#.utf8))
        guard case .ignored = r.payload else { return XCTFail("expected ignored") }
        XCTAssertGreaterThan(r.rawLength, 100_000)
    }

    func test_TranscriptParser_extraUnknownFields_areIgnored() {
        var extra: [String: Any] = [:]
        for i in 0..<40 { extra["unknown\(i)"] = i }
        let line = RecordBuilder.line(RecordBuilder.envelope(type: "user", extra: extra.merging(["message": ["role": "user", "content": "x"], "origin": ["kind": "human"]]) { $1 }))
        guard case .humanPrompt = parser.record(line).payload else { return XCTFail("expected prompt") }
    }

    func test_TranscriptParser_hookAttachment_decodesClaudioHook() {
        let line = RecordBuilder.line(RecordBuilder.envelope(type: "attachment", extra: ["attachment": ["type": "hook_success", "hookEvent": "Stop", "command": "/Applications/Claudio.app/Contents/Helpers/claudio hook", "exitCode": 0]]))
        guard case .hookAttachment(let event, let command, let code) = parser.record(line).payload else { return XCTFail("wrong") }
        XCTAssertEqual(event, "Stop")
        XCTAssertTrue(command.contains("claudio hook"))
        XCTAssertEqual(code, 0)
    }

    func test_TranscriptParser_fixture_everyLineDecodes() {
        let lines = TestFixtures.lines("transcripts/claude-speak-design/session.jsonl")
        XCTAssertGreaterThan(lines.count, 500)
        var malformed = 0
        var unknown: [String: Int] = [:]
        for line in lines {
            switch parser.parse(line: line) {
            case .success(let r): if case .unknown(let t) = r.payload { unknown[t, default: 0] += 1 }
            case .failure: malformed += 1
            }
        }
        XCTAssertEqual(malformed, 0)
        XCTAssertEqual(unknown["file-history-delta"], nil)
        XCTAssertLessThan(unknown.values.reduce(0, +), 10)
    }
}
