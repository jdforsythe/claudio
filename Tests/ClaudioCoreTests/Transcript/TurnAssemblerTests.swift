import ClaudioCore
import TestSupport
import XCTest

final class TurnAssemblerTests: XCTestCase {
    let parser = TranscriptParser()
    var clock = ManualClock()
    var assembler: TurnAssembler!

    override func setUp() {
        clock = ManualClock()
        assembler = TurnAssembler(sessionID: RecordBuilder.session, clock: clock)
    }

    private func ingest(_ data: Data) async -> [TurnEvent] { await assembler.ingest(parser.record(data)) }
    private func items(_ events: [TurnEvent]) -> [SpeechItem] { events.compactMap { if case .item(let i) = $0 { i } else { nil } } }

    func test_TurnAssembler_humanPrompt_startsTurn() async {
        let events = await ingest(RecordBuilder.humanPrompt("hi", promptID: "p1"))
        XCTAssertTrue(events.contains { if case .turnStarted("p1", "hi", _) = $0 { true } else { false } })
        XCTAssertTrue(events.contains(.statusChanged(.busy)))
        let open = await assembler.openTurn
        XCTAssertEqual(open, "p1")
    }

    func test_TurnAssembler_skillAndMetaPrompts_doNotStartTurn() async {
        let a = await ingest(RecordBuilder.skillPrompt("Base directory for this skill", promptID: "p1"))
        let b = await ingest(RecordBuilder.metaPrompt("meta", promptID: "p2"))
        XCTAssertFalse((a + b).contains { if case .turnStarted = $0 { true } else { false } })
    }

    func test_TurnAssembler_toolResultUserRecord_doesNotStartTurn() async {
        let events = await ingest(RecordBuilder.toolResult(toolUseID: "t", content: "ok", promptID: "p1"))
        XCTAssertFalse(events.contains { if case .turnStarted = $0 { true } else { false } })
    }

    func test_TurnAssembler_textBlockWithEndTurnStopReason_emitsFinalAnswer() async {
        _ = await ingest(RecordBuilder.humanPrompt("hi", promptID: "p1"))
        let events = await ingest(RecordBuilder.text("The answer.", messageID: "m1", stopReason: "end_turn"))
        XCTAssertEqual(items(events).map(\.category), [.finalAnswer])
        XCTAssertEqual(items(events).first?.turnID, "p1")
    }

    func test_TurnAssembler_toolUseStopReason_isNarration() async {
        _ = await ingest(RecordBuilder.humanPrompt("hi", promptID: "p1"))
        let events = await ingest(RecordBuilder.text("Let me look.", messageID: "m1", stopReason: "tool_use"))
        XCTAssertEqual(items(events).map(\.category), [.narration])
    }

    func test_TurnAssembler_pendingTextFollowedByToolUse_isNarration() async {
        _ = await ingest(RecordBuilder.humanPrompt("hi", promptID: "p1"))
        let a = await ingest(RecordBuilder.text("Let me look.", messageID: "m1", stopReason: NSNull()))
        XCTAssertTrue(items(a).isEmpty)
        let b = await ingest(RecordBuilder.toolUse(name: "Read", input: ["file_path": "/a/b/Parser.swift"], messageID: "m1", stopReason: NSNull()))
        XCTAssertEqual(items(b).map(\.category), [.narration, .toolCall])
        XCTAssertEqual(items(b).last?.text, "Reading Parser dot swift.")
    }

    func test_TurnAssembler_pendingText_resolvedAsFinalByTurnDuration() async {
        _ = await ingest(RecordBuilder.humanPrompt("hi", promptID: "p1"))
        _ = await ingest(RecordBuilder.text("Answer.", messageID: "m1", stopReason: NSNull()))
        let events = await ingest(RecordBuilder.turnDuration())
        XCTAssertEqual(items(events).map(\.category), [.finalAnswer])
        XCTAssertTrue(events.contains { if case .turnEnded("p1", _, .completed) = $0 { true } else { false } })
        XCTAssertTrue(events.contains(.statusChanged(.idle)))
    }

    func test_TurnAssembler_pendingText_forceResolvedAfterSilence() async {
        _ = await ingest(RecordBuilder.humanPrompt("hi", promptID: "p1"))
        _ = await ingest(RecordBuilder.text("Answer.", messageID: "m1", stopReason: NSNull()))
        let stream = assembler.asyncEvents()
        let ok = await waitUntil(1) { self.clock.pendingSleepers == 1 }
        XCTAssertTrue(ok)
        clock.advance(by: 2)
        var iterator = stream.makeAsyncIterator()
        let events = await iterator.next() ?? []
        XCTAssertEqual(items(events).map(\.category), [.finalAnswer])
    }

    func test_TurnAssembler_newPromptWhileTurnOpen_closesPreviousTurn() async {
        _ = await ingest(RecordBuilder.humanPrompt("one", promptID: "p1"))
        let events = await ingest(RecordBuilder.humanPrompt("two", promptID: "p2"))
        XCTAssertTrue(events.contains { if case .turnEnded("p1", _, .interruptedByPrompt) = $0 { true } else { false } })
        XCTAssertTrue(events.contains { if case .turnStarted("p2", _, _) = $0 { true } else { false } })
    }

    func test_TurnAssembler_orphanText_opensSyntheticTurn() async {
        let events = await ingest(RecordBuilder.text("Answer.", messageID: "m9", stopReason: "end_turn"))
        XCTAssertTrue(events.contains { if case .turnStarted("orphan-m9", _, _) = $0 { true } else { false } })
        XCTAssertEqual(items(events).first?.turnID, "orphan-m9")
    }

    func test_TurnAssembler_toolResultError_emitsToolResultItem() async {
        _ = await ingest(RecordBuilder.humanPrompt("hi", promptID: "p1"))
        _ = await ingest(RecordBuilder.toolUse(name: "Bash", input: ["command": "ls"], id: "t1", messageID: "m1"))
        let a = await ingest(RecordBuilder.toolResult(toolUseID: "t1", content: "zsh: command not found: foo", isError: true, promptID: "p1"))
        XCTAssertEqual(items(a).map(\.category), [.toolResult])
        XCTAssertEqual(items(a).first?.text, "Bash failed: zsh: command not found: foo")
        let b = await ingest(RecordBuilder.toolResult(toolUseID: "t1", content: "all good", promptID: "p1"))
        XCTAssertTrue(items(b).isEmpty)
        let c = await ingest(RecordBuilder.toolResult(toolUseID: "t1", content: "", toolUseResult: ["success": false, "error": "boom"], promptID: "p1"))
        XCTAssertEqual(items(c).first?.text, "Bash failed: boom")
    }

    func test_TurnAssembler_emptyThinking_producesNothing() async {
        _ = await ingest(RecordBuilder.humanPrompt("hi", promptID: "p1"))
        let a = await ingest(RecordBuilder.thinking("", messageID: "m1"))
        XCTAssertTrue(items(a).isEmpty)
        let b = await ingest(RecordBuilder.thinking("deep thoughts", messageID: "m1"))
        XCTAssertEqual(items(b).map(\.category), [.thinking])
    }

    func test_TurnAssembler_duplicateUUID_emitsOnce() async {
        _ = await ingest(RecordBuilder.humanPrompt("hi", promptID: "p1"))
        let line = RecordBuilder.text("Answer.", messageID: "m1", uuid: "same-uuid")
        let a = await ingest(line)
        let b = await ingest(line)
        XCTAssertEqual(items(a).count, 1)
        XCTAssertEqual(items(b).count, 0)
    }

    func test_TurnAssembler_aiTitle_emitsTitleChanged() async {
        let events = await ingest(RecordBuilder.aiTitle("New title"))
        XCTAssertEqual(events, [.titleChanged("New title")])
    }

    func test_TurnAssembler_cwdAndEntrypoint_observedOnce() async {
        let a = await ingest(RecordBuilder.humanPrompt("hi", promptID: "p1"))
        XCTAssertTrue(a.contains(.cwdObserved(URL(fileURLWithPath: RecordBuilder.cwd))))
        XCTAssertTrue(a.contains(.entrypointObserved(.cli)))
        let b = await ingest(RecordBuilder.text("x", messageID: "m1"))
        XCTAssertFalse(b.contains(.entrypointObserved(.cli)))
    }

    func test_TurnAssembler_consecutiveIdenticalToolCalls_dedupedWithinFiveSeconds() async {
        _ = await ingest(RecordBuilder.humanPrompt("hi", promptID: "p1"))
        let a = await ingest(RecordBuilder.toolUse(name: "Grep", input: ["pattern": "foo"], messageID: "m1"))
        let b = await ingest(RecordBuilder.toolUse(name: "Grep", input: ["pattern": "foo"], messageID: "m1"))
        XCTAssertEqual(items(a).count, 1)
        XCTAssertEqual(items(b).count, 0)
    }

    // MARK: Subagents

    func test_TurnAssembler_subagentText_emitsNothingAndFinishEmitsToolCall() async {
        _ = await ingest(RecordBuilder.humanPrompt("hi", promptID: "p1"))
        _ = await ingest(RecordBuilder.toolUse(name: "Task", input: ["description": "analyze source"], messageID: "m1"))
        let first = parser.record(RecordBuilder.humanPrompt("agent prompt", promptID: "p1"))
        let a = await assembler.ingestSubagent(first, agentID: "a1", metaURL: nil)
        XCTAssertTrue(items(a).isEmpty)
        let text = parser.record(RecordBuilder.assistant(block: ["type": "text", "text": "agent narration"], messageID: "am1", stopReason: "end_turn", sidechain: true, agentID: "a1"))
        let b = await assembler.ingestSubagent(text, agentID: "a1", metaURL: nil)
        XCTAssertTrue(items(b).isEmpty)
        let done = parser.record(RecordBuilder.turnDuration())
        let c = await assembler.ingestSubagent(done, agentID: "a1", metaURL: nil)
        XCTAssertEqual(items(c).map(\.text), ["Agent finished: analyze source."])
        let again = await assembler.ingestSubagent(parser.record(RecordBuilder.turnDuration()), agentID: "a1", metaURL: nil)
        XCTAssertTrue(items(again).isEmpty)
    }

    // MARK: Hooks and reconciliation

    private func hook(_ name: String, _ fields: [String: Any]) -> HookEvent {
        var all = fields
        all["hook_event_name"] = name
        all["session_id"] = RecordBuilder.session
        let data = try! JSONSerialization.data(withJSONObject: all)  // swiftlint:disable:this force_try
        let envelope = ControlEnvelope(hookEvent: name, session: RecordBuilder.session, payload: RawJSON(data: data))
        return HookEvent.decode(envelope: envelope, now: clock.now)!  // swiftlint:disable:this force_unwrapping
    }

    func test_TurnAssembler_hookStartThenTranscriptStart_startsOnce() async {
        let a = await assembler.ingestHook(hook("UserPromptSubmit", ["prompt_id": "p1", "prompt_text": "hi"]), title: "T")
        XCTAssertTrue(a.contains { if case .turnStarted("p1", _, _) = $0 { true } else { false } })
        let b = await ingest(RecordBuilder.humanPrompt("hi", promptID: "p1"))
        XCTAssertFalse(b.contains { if case .turnStarted = $0 { true } else { false } })
    }

    func test_TurnAssembler_continuationPrompt_ignored() async {
        let a = await assembler.ingestHook(hook("UserPromptSubmit", ["prompt_id": "p1", "is_continuation": true]), title: "T")
        XCTAssertTrue(a.isEmpty)
    }

    func test_TurnAssembler_hookFinalAnswer_droppedWhenTranscriptAlreadyEmitted() async {
        _ = await ingest(RecordBuilder.humanPrompt("hi", promptID: "p1"))
        _ = await ingest(RecordBuilder.text("The final   answer text.", messageID: "m1"))
        let events = await assembler.ingestHook(hook("Stop", ["prompt_id": "p1", "last_assistant_message": "The final answer text."]), title: "T")
        XCTAssertTrue(items(events).isEmpty)
        XCTAssertTrue(events.contains { if case .turnEnded("p1", _, .hookStop) = $0 { true } else { false } })
        let late = await ingest(RecordBuilder.turnDuration())
        XCTAssertFalse(late.contains { if case .turnEnded = $0 { true } else { false } })
    }

    func test_TurnAssembler_hookFinalAnswer_usedWhenTranscriptLags_andLateTranscriptDropped() async {
        _ = await ingest(RecordBuilder.humanPrompt("hi", promptID: "p1"))
        let events = await assembler.ingestHook(hook("Stop", ["prompt_id": "p1", "last_assistant_message": "From the hook."]), title: "T")
        XCTAssertEqual(items(events).map(\.category), [.finalAnswer])
        XCTAssertEqual(items(events).first?.sourceUUID, "hook:p1")
        _ = await ingest(RecordBuilder.humanPrompt("again", promptID: "p1"))  // deduped start, keeps turn open? no: within window
        let late = await ingest(RecordBuilder.text("From the hook.", messageID: "m2", promptID: "p1"))
        XCTAssertTrue(items(late).filter { $0.category == .finalAnswer && $0.turnID == "p1" }.isEmpty)
    }

    func test_TurnAssembler_notificationTypes_mapped() async {
        let a = await assembler.ingestHook(hook("Notification", ["notification_type": "permission_prompt"]), title: "Yard")
        XCTAssertTrue(a.contains(.statusChanged(.waiting)))
        XCTAssertEqual(items(a).first?.text, "Yard needs permission.")
        let b = await assembler.ingestHook(hook("Notification", ["notification_type": "agent_needs_input"]), title: "Yard")
        XCTAssertEqual(items(b).first?.text, "Yard needs input.")
        let c = await assembler.ingestHook(hook("Notification", ["notification_type": "auth_success"]), title: "Yard")
        XCTAssertTrue(c.isEmpty)
    }

    func test_TurnAssembler_agentCompletedBeforeStop_endsTurnOnce_noFinishedItem() async {
        _ = await ingest(RecordBuilder.humanPrompt("hi", promptID: "p1"))
        let a = await assembler.ingestHook(hook("Notification", ["notification_type": "agent_completed"]), title: "Yard")
        XCTAssertEqual(a.filter { if case .turnEnded("p1", _, _) = $0 { true } else { false } }.count, 1)
        XCTAssertTrue(items(a).isEmpty, "the Arbiter announces; the assembler must not emit a finished item")
        let b = await assembler.ingestHook(hook("Stop", ["prompt_id": "p1"]), title: "Yard")
        XCTAssertFalse(b.contains { if case .turnEnded = $0 { true } else { false } })
        let c = await ingest(RecordBuilder.turnDuration())
        XCTAssertFalse(c.contains { if case .turnEnded = $0 { true } else { false } })
    }

    func test_TurnAssembler_stopAfterAgentCompleted_withMismatchedPromptID_endsOnce() async {
        _ = await ingest(RecordBuilder.humanPrompt("hi", promptID: "p1"))
        let a = await assembler.ingestHook(hook("Stop", ["prompt_id": "other-id"]), title: "Yard")
        XCTAssertEqual(a.filter { if case .turnEnded("p1", _, .hookStop) = $0 { true } else { false } }.count, 1)
        let b = await ingest(RecordBuilder.turnDuration())
        XCTAssertFalse(b.contains { if case .turnEnded = $0 { true } else { false } })
    }

    func test_TurnAssembler_hookAndTranscriptStartWithDifferentIDs_withinWindow_areOneTurn() async {
        let a = await assembler.ingestHook(hook("UserPromptSubmit", ["prompt_id": "hook-id", "prompt_text": "hi"]), title: "T")
        XCTAssertTrue(a.contains { if case .turnStarted("hook-id", _, _) = $0 { true } else { false } })
        let b = await ingest(RecordBuilder.humanPrompt("hi", promptID: "transcript-id"))
        XCTAssertFalse(b.contains { if case .turnStarted = $0 { true } else { false } })
        XCTAssertFalse(b.contains { if case .turnEnded = $0 { true } else { false } }, "no spurious interruption cancel")
        let c = await ingest(RecordBuilder.text("Answer.", messageID: "m1"))
        XCTAssertEqual(items(c).first?.turnID, "hook-id")
    }

    func test_TurnAssembler_transcriptFinalAfterHookStop_joinsThatTurnAndIsDeduped() async {
        _ = await ingest(RecordBuilder.humanPrompt("hi", promptID: "p1"))
        let stop = await assembler.ingestHook(hook("Stop", ["prompt_id": "p1", "last_assistant_message": "The answer."]), title: "T")
        XCTAssertEqual(items(stop).map(\.category), [.finalAnswer])
        let late = await ingest(RecordBuilder.text("The answer.", messageID: "m1"))
        XCTAssertTrue(items(late).isEmpty, "late transcript copy of the hook answer must not be spoken again")
        XCTAssertFalse(late.contains { if case .turnStarted = $0 { true } else { false } }, "no orphan turn")
    }

    func test_TurnAssembler_stopFailure_humanised() async {
        _ = await ingest(RecordBuilder.humanPrompt("hi", promptID: "p1"))
        let events = await assembler.ingestHook(hook("StopFailure", ["prompt_id": "p1", "error_type": "rate_limit"]), title: "Yard")
        XCTAssertEqual(items(events).first?.text, "Yard hit an error: rate limit.")
        XCTAssertTrue(events.contains { if case .turnEnded("p1", _, .hookStopFailure) = $0 { true } else { false } })
    }

    func test_TurnAssembler_sessionEndClear_keepsSession() async {
        let a = await assembler.ingestHook(hook("SessionEnd", ["reason": "clear"]), title: "T")
        XCTAssertFalse(a.contains(.sessionEnded))
        XCTAssertTrue(a.contains(.statusChanged(.idle)))
        let b = await assembler.ingestHook(hook("SessionEnd", ["reason": "exit"]), title: "T")
        XCTAssertTrue(b.contains(.sessionEnded))
    }

    // MARK: Fixture (behaviour probe, docs/03 §6.3)

    func test_TurnAssembler_fixture_stopReasonIsPresentOnEveryAssistantRecord() {
        var assistant = 0
        var nullStop = 0
        for line in TestFixtures.lines("transcripts/claude-speak-design/session.jsonl") {
            let r = parser.record(line)
            switch r.payload {
            case .assistantText(_, _, _, let stop, _), .assistantThinking(_, let stop, _), .assistantToolUse(_, let stop, _, _, _):
                assistant += 1
                if stop == nil { nullStop += 1 }
            default: break
            }
        }
        XCTAssertGreaterThan(assistant, 100)
        XCTAssertEqual(nullStop, 0, "Claude Code started writing assistant records without stop_reason; the secondary classifier is now the production path")
    }

    func test_TurnAssembler_fixture_classifiesFinalAnswersAndTurns() async {
        var finals = 0
        var narration = 0
        var started = 0
        var ended = 0
        var endTurnTexts = 0
        for line in TestFixtures.lines("transcripts/claude-speak-design/session.jsonl") {
            let r = parser.record(line)
            if case .assistantText(_, _, _, let stop, _) = r.payload, stop == "end_turn" { endTurnTexts += 1 }
            for e in await assembler.ingest(r) {
                switch e {
                case .item(let i) where i.category == .finalAnswer: finals += 1
                case .item(let i) where i.category == .narration: narration += 1
                case .turnStarted: started += 1
                case .turnEnded: ended += 1
                default: break
                }
            }
        }
        XCTAssertEqual(finals, endTurnTexts)
        XCTAssertGreaterThan(narration, 10)
        XCTAssertGreaterThan(started, 5)
        let stillOpen = await assembler.openTurn != nil
        XCTAssertEqual(started, ended + (stillOpen ? 1 : 0))
    }

    func test_TurnAssembler_stopReasonVariants_produceIdenticalEvents() async {
        // Strip stop_reason from every assistant record and compare the final-answer/narration sequence.
        let lines = TestFixtures.lines("transcripts/claude-speak-design/session.jsonl")
        func run(strip: Bool) async -> [String] {
            let a = TurnAssembler(sessionID: RecordBuilder.session, clock: clock)
            var out: [String] = []
            for line in lines {
                var data = line
                if strip, var obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any], var msg = obj["message"] as? [String: Any], obj["type"] as? String == "assistant" {
                    msg["stop_reason"] = NSNull()
                    obj["message"] = msg
                    data = RecordBuilder.line(obj)
                }
                for e in await a.ingest(parser.record(data)) {
                    if case .item(let i) = e, i.category == .finalAnswer || i.category == .narration { out.append("\(i.category.rawValue):\(i.text.prefix(20))") }
                }
            }
            out.append(contentsOf: (await a.flushPendingNow()).compactMap { if case .item(let i) = $0 { "\(i.category.rawValue):\(i.text.prefix(20))" } else { nil } })
            return out
        }
        let primary = await run(strip: false)
        let secondary = await run(strip: true)
        XCTAssertEqual(primary.filter { $0.hasPrefix("finalAnswer") }.count, secondary.filter { $0.hasPrefix("finalAnswer") }.count)
        XCTAssertEqual(primary.count, secondary.count)
    }
}
