import ClaudioCore
import TestSupport
import XCTest

final class ToolCallSummarizerTests: XCTestCase {
    let s = ToolCallSummarizer()

    func test_ToolCallSummarizer_rules() {
        XCTAssertEqual(s.summarize(toolName: "Bash", input: ["command": .string("git status --short"), "description": .string("Show working tree status")]), "Show working tree status.")
        XCTAssertEqual(s.summarize(toolName: "Bash", input: ["command": .string("git status --short -v origin")]), "Running: git status origin.")
        XCTAssertEqual(s.summarize(toolName: "Read", input: ["file_path": .string("/a/b/Parser.swift")]), "Reading Parser dot swift.")
        XCTAssertEqual(s.summarize(toolName: "Edit", input: ["file_path": .string("/a/b/README.md")]), "Editing README dot M D.")
        XCTAssertEqual(s.summarize(toolName: "Write", input: ["file_path": .string("x.json")]), "Writing x dot json.")
        XCTAssertEqual(s.summarize(toolName: "Grep", input: ["pattern": .string("func\\s+tail")]), "Searching for func s tail.")
        XCTAssertEqual(s.summarize(toolName: "Glob", input: ["pattern": .string("**/*.swift")]), "Finding swift files.")
        XCTAssertEqual(s.summarize(toolName: "Agent", input: ["description": .string("analyze source")]), "Agent started: analyze source.")
        XCTAssertEqual(s.summarize(toolName: "Skill", input: ["skill": .string("grill-me")]), "Using skill grill me.")
        XCTAssertEqual(s.summarize(toolName: "WebFetch", input: ["url": .string("https://www.code.claude.com/docs")]), "Fetching code.claude.com.")
        XCTAssertEqual(s.summarize(toolName: "WebSearch", input: ["query": .string("one two three four five six seven")]), "Searching the web for one two three four five six.")
        XCTAssertEqual(s.summarize(toolName: "mcp__claude_ai_Asana__get_task", input: [:]), "Calling Asana get task.")
        XCTAssertEqual(s.summarize(toolName: "SomeNewTool", input: [:]), "Using Some New Tool.")
        XCTAssertEqual(s.summarize(toolName: "TodoWrite", input: [:]), "Updating tasks.")
        XCTAssertNil(s.summarize(toolName: "ToolSearch", input: [:]))
        XCTAssertNil(s.summarize(toolName: "Monitor", input: [:]))
    }

    func test_ToolCallSummarizer_twelveWordCap() {
        let long = (1...30).map { "w\($0)" }.joined(separator: " ")
        let out = s.summarize(toolName: "WebSearch", input: ["query": .string(long)]) ?? ""
        XCTAssertLessThanOrEqual(out.split(separator: " ").count, 12)
        let desc = s.summarize(toolName: "Bash", input: ["description": .string(long), "command": .string("ls")]) ?? ""
        XCTAssertTrue(desc.hasPrefix("Running: ls"))
    }

    func test_ToolCallDeduper_withinFiveSeconds() {
        var d = ToolCallDeduper()
        let t0 = Date()
        XCTAssertTrue(d.accept("Reading a.", at: t0))
        XCTAssertFalse(d.accept("Reading a.", at: t0.addingTimeInterval(2)))
        XCTAssertTrue(d.accept("Reading b.", at: t0.addingTimeInterval(2)))
        XCTAssertTrue(d.accept("Reading b.", at: t0.addingTimeInterval(8)))
    }
}
