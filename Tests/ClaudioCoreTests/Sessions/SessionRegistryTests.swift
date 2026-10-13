import ClaudioCore
import TestSupport
import XCTest

/// Registry + Arbiter + Pipeline wired with a mock backend and a recording sink; records are injected directly.
@MainActor
final class SessionRegistryTests: XCTestCase {
    var root = TempRoot()
    var settings: AppSettings!
    var registry: SessionRegistry!
    var pipeline: SpeechPipeline!
    var arbiter: Arbiter!
    var sink: RecordingPlaybackSink!
    var backend: MockBackend!
    let parser = TranscriptParser()

    override func setUp() async throws {
        root = TempRoot()
        settings = makeTestSettings()
        backend = MockBackend()
        sink = RecordingPlaybackSink()
        let paths = Paths(environment: ["CLAUDE_CONFIG_DIR": root.path("cfg").path], home: root.url, bundleURL: nil)
        try FileManager.default.createDirectory(at: root.path("cfg/projects"), withIntermediateDirectories: true)
        let discovery = SessionDiscovery(roots: [root.path("cfg/projects")])
        registry = SessionRegistry(discovery: discovery, probe: nil, store: nil, settings: settings,
                                   projectPrefs: ProjectPreferences(fileURL: root.path("projects.json")), paths: paths)
        pipeline = SpeechPipeline(backend: backend, sink: sink, voiceProvider: { MockBackend.voice(for: $0) })
        arbiter = Arbiter(registry: registry, pipeline: pipeline, settings: settings)
        await pipeline.start()
        await registry.start()
        await arbiter.start()
    }

    override func tearDown() async throws {
        await arbiter.stop()
        await registry.stop()
        await pipeline.stop()
        root.cleanup()
    }

    private func inject(_ data: Data, session: String = RecordBuilder.session) async {
        var record = parser.record(data)
        if session != RecordBuilder.session {
            record = TranscriptRecord(envelope: .init(type: record.envelope.type, uuid: record.envelope.uuid, sessionID: session, promptID: record.envelope.promptID,
                                                     timestamp: record.envelope.timestamp, cwd: "/Users/fixture/project-2", entrypoint: "cli", version: nil),
                                      payload: record.payload)
        }
        await registry.inject(record: record, into: session, transcriptURL: root.path("cfg/projects/-proj/\(session).jsonl"))
    }

    private func spoken(_ n: Int, budget: TimeInterval = 3) async -> [String] {
        _ = await waitUntil(budget) { self.backend.calls.count >= n }
        return backend.calls.map(\.text)
    }

    func test_SessionRegistry_firstRecord_createsSession_titleAndLevelDefaults_singleAutoActivates() async {
        await inject(RecordBuilder.humanPrompt("hello there", promptID: "p1"))
        let session = await registry.session(RecordBuilder.session)
        XCTAssertEqual(session?.title, "project-1")
        XCTAssertEqual(session?.status, .busy)
        XCTAssertEqual(session?.lastPrompt, "hello there")
        let ok21 = await waitUntil(2) { await self.arbiter.activeSessionID == RecordBuilder.session }
        XCTAssertTrue(ok21)
        let activated = await registry.session(RecordBuilder.session)
        XCTAssertEqual(activated?.level, .narrate, "first activation applies defaultLevelActive")
        await inject(RecordBuilder.aiTitle("Real title"))
        let titled = await registry.session(RecordBuilder.session)
        XCTAssertEqual(titled?.title, "Real title")
    }

    func test_Story01_narratedSingleSession_speaksAllThreeInOrder() async {
        await inject(RecordBuilder.humanPrompt("hi", promptID: "p1"))
        _ = await waitUntil(2) { await self.arbiter.activeSessionID != nil }
        await inject(RecordBuilder.text("I will read the parser first to understand the structure.", messageID: "m1", stopReason: "tool_use"))
        await inject(RecordBuilder.toolUse(name: "Read", input: ["file_path": "/x/Parser.swift"], messageID: "m1"))
        await inject(RecordBuilder.text("The parser attaches at end of file and never replays history.", messageID: "m2", stopReason: "end_turn"))
        let texts = await spoken(3)
        XCTAssertEqual(texts, ["I will read the parser first to understand the structure.", "Reading Parser dot swift.", "The parser attaches at end of file and never replays history."])
    }

    func test_Story02b_promptDuringSpeech_cancelsQueue() async {
        backend = MockBackend(delay: 0.3)
        await pipeline.setBackend(backend)
        await inject(RecordBuilder.humanPrompt("hi", promptID: "p1"))
        _ = await waitUntil(2) { await self.arbiter.activeSessionID != nil }
        await inject(RecordBuilder.text("A long final answer sentence that will still be synthesizing when the next prompt lands here.", messageID: "m1"))
        _ = await waitUntil(1) { self.backend.calls.count == 1 }
        await inject(RecordBuilder.humanPrompt("next question", promptID: "p2"))
        let ok22 = await waitUntil(1) { self.backend.cancelledCount >= 1 }
        XCTAssertTrue(ok22)
        let state = await pipeline.currentState
        XCTAssertEqual(state.queuedSegments, 0)
    }

    func test_Story03_backgroundTurnCompletes_announcesAndIncrementsUnread() async {
        await inject(RecordBuilder.humanPrompt("hi", promptID: "p1"))
        _ = await waitUntil(2) { await self.arbiter.activeSessionID == RecordBuilder.session }
        let b = "bbbbbbbb-0000-4000-8000-000000000002"
        await inject(RecordBuilder.humanPrompt("background", promptID: "q1"), session: b)
        await inject(RecordBuilder.text("Background answer text that nobody is listening to right now.", messageID: "bm1"), session: b)
        await inject(RecordBuilder.turnDuration(), session: b)
        let texts = await spoken(1)
        XCTAssertEqual(texts, ["project-2 finished."])
        let session = await registry.session(b)
        XCTAssertEqual(session?.unreadTurns.count, 1)
        XCTAssertEqual(session?.status, .idle)
    }

    func test_Story04_switchWithUnread_speaksCueThenFinalsThenCaughtUp() async {
        let a = RecordBuilder.session
        let b = "bbbbbbbb-0000-4000-8000-000000000002"
        await inject(RecordBuilder.humanPrompt("hi", promptID: "p1"), session: a)
        _ = await waitUntil(2) { await self.arbiter.activeSessionID == a }
        for i in 1...3 {
            await inject(RecordBuilder.humanPrompt("q\(i)", promptID: "q\(i)"), session: b)
            await inject(RecordBuilder.text("Let me check something quickly here.", messageID: "n\(i)", stopReason: "tool_use"), session: b)
            await inject(RecordBuilder.text("Background final answer number \(i) that is long enough for a segment.", messageID: "bm\(i)"), session: b)
            await inject(RecordBuilder.turnDuration(), session: b)
        }
        _ = await spoken(3)
        let unreadBefore = await registry.session(b)?.unreadTurns.count
        XCTAssertEqual(unreadBefore, 3)
        let before = backend.calls.count
        await arbiter.activate(b)
        let texts = await spoken(before + 5)
        let tail = Array(texts.suffix(from: before))
        XCTAssertEqual(tail.first, "project-2. Catching up on 3 turns.")
        XCTAssertEqual(tail.dropFirst().prefix(3).map { $0 }, (1...3).map { "Background final answer number \($0) that is long enough for a segment." })
        XCTAssertEqual(tail.last, "You're caught up.")
        XCTAssertFalse(tail.contains { $0.hasPrefix("Let me check") })
        let unreadAfter = await registry.session(b)?.unreadTurns.count
        XCTAssertEqual(unreadAfter, 0)
        let mode = await arbiter.mode
        XCTAssertEqual(mode, .live(b))
    }

    func test_Story06_levelDowngrade_dropsQueuedNarrationKeepsFinal() async {
        backend = MockBackend(delay: 0.3)
        await pipeline.setBackend(backend)
        sink = RecordingPlaybackSink(autoPlay: false)
        await inject(RecordBuilder.humanPrompt("hi", promptID: "p1"))
        _ = await waitUntil(2) { await self.arbiter.activeSessionID != nil }
        await inject(RecordBuilder.text("Narration one that is long enough to be a segment by itself.", messageID: "m1", stopReason: "tool_use"))
        await inject(RecordBuilder.text("Narration two that is long enough to be a segment by itself.", messageID: "m2", stopReason: "tool_use"))
        await inject(RecordBuilder.text("Final answer that is long enough to be a segment by itself.", messageID: "m3"))
        _ = await waitUntil(1) { await self.pipeline.queueSnapshot().count == 3 }
        await registry.setLevel(.answers, for: RecordBuilder.session)
        let dropped = await waitUntil(1) { await self.pipeline.queueSnapshot().filter { $0.item.category == .narration && $0.state != .playing }.isEmpty }
        XCTAssertTrue(dropped)
        let remaining = await pipeline.queueSnapshot()
        XCTAssertTrue(remaining.contains { $0.item.category == .finalAnswer })
    }

    func test_SessionRegistry_resolve_queries() async {
        await inject(RecordBuilder.humanPrompt("hi", promptID: "p1"))
        await inject(RecordBuilder.aiTitle("Claude speak redesign"))
        let full = await registry.resolve(RecordBuilder.session)
        XCTAssertEqual(try? full.get().id, RecordBuilder.session)
        for query in ["5623", "claude speak redesign", "speak", "/Users/fixture/project-1/sub/dir", "id:\(RecordBuilder.session)"] {
            let resolved = await registry.resolve(query)
            XCTAssertEqual(try? resolved.get().id, RecordBuilder.session, query)
        }
        let none = await registry.resolve("nothing-matches")
        if case .success = none { XCTFail("expected failure") }
    }

    func test_SessionNaming_duplicateTitles_suffixed() {
        let a = Session(id: "a", title: "T", cwd: URL(fileURLWithPath: "/dev/yard"), transcriptURL: URL(fileURLWithPath: "/a"), root: URL(fileURLWithPath: "/"), colorIndex: 0, lastActivity: Date())
        let b = Session(id: "b", title: "T", cwd: URL(fileURLWithPath: "/dev/vea"), transcriptURL: URL(fileURLWithPath: "/b"), root: URL(fileURLWithPath: "/"), colorIndex: 0, lastActivity: Date())
        let names = SessionNaming.disambiguate([a, b])
        XCTAssertEqual(names["a"], "T (yard)")
        XCTAssertEqual(names["b"], "T (vea)")
        let c = Session(id: "cccccccc-1", title: "T", cwd: URL(fileURLWithPath: "/dev/yard"), transcriptURL: URL(fileURLWithPath: "/c"), root: URL(fileURLWithPath: "/"), colorIndex: 0, lastActivity: Date())
        XCTAssertEqual(SessionNaming.disambiguate([a, c])["a"], "T (a)")
        XCTAssertEqual(Session.colorIndex(for: "abc"), Session.colorIndex(for: "abc"))
        XCTAssertTrue((0..<8).contains(Session.colorIndex(for: "abc")))
    }

    func test_LiveAgentsProbe_parsesAndBacksOff() async {
        let json = Data(#"[{"pid":1,"cwd":"/a","kind":"interactive","startedAt":1,"sessionId":"s","name":"yard-53","status":"busy"}]"#.utf8)
        let agents = LiveAgentsProbe.parse(json)
        XCTAssertEqual(agents?.first?.name, "yard-53")
        XCTAssertEqual(agents?.first?.pid, 1)
        XCTAssertNil(LiveAgentsProbe.parse(Data("nope".utf8)))
        let probe = LiveAgentsProbe(runner: { .failure(MessageError("not found")) })
        for _ in 0..<3 { await probe.probeOnce() }
        let outcome = await probe.lastOutcome
        XCTAssertEqual(outcome, .failed("not found"))
    }

    func test_SessionDiscovery_classifyPaths() {
        let root = URL(fileURLWithPath: "/h/.claude/projects")
        let main = root.appendingPathComponent("-Users-x-dev/562358f2-0209-4cc5-b2be-9157fd4b6a9d.jsonl")
        XCTAssertEqual(ProjectPathEncoding.classify(main, root: root), .main(sessionID: "562358f2-0209-4cc5-b2be-9157fd4b6a9d", projectDir: root.appendingPathComponent("-Users-x-dev")))
        let sub = root.appendingPathComponent("-Users-x-dev/562358f2-0209-4cc5-b2be-9157fd4b6a9d/subagents/agent-a01c0993.jsonl")
        if case .subagent(let s, let a, _)? = ProjectPathEncoding.classify(sub, root: root) {
            XCTAssertEqual(s, "562358f2-0209-4cc5-b2be-9157fd4b6a9d")
            XCTAssertEqual(a, "a01c0993")
        } else { XCTFail("subagent not recognised") }
        XCTAssertNil(ProjectPathEncoding.classify(root.appendingPathComponent("-p/x/subagents/agent-1.meta.json"), root: root))
        XCTAssertNil(ProjectPathEncoding.classify(root.appendingPathComponent("-p/memory/notes.md"), root: root))
        XCTAssertNil(ProjectPathEncoding.classify(root.appendingPathComponent("-p/562358f2-0209-4cc5-b2be-9157fd4b6a9d/tool-results/x.jsonl"), root: root))
        XCTAssertEqual(ProjectPathEncoding.encode("/Users/j/dev/claudio"), "-Users-j-dev-claudio")
    }
}
