import ClaudioControlProtocol
import ClaudioCore
import Synchronization
import TestSupport
import XCTest

/// End-to-end through real FSEvents discovery and the tailer, with a mock backend and recording sink.
final class IntegrationTests: XCTestCase {
    var root: URL!
    var settings: AppSettings!
    var registry: SessionRegistry!
    var pipeline: SpeechPipeline!
    var arbiter: Arbiter!
    var backend: MockBackend!
    var sink: RecordingPlaybackSink!
    let session = "11111111-2222-4333-8444-555555555555"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("claudio-int-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("cfg/projects/-Users-fixture-project-1"), withIntermediateDirectories: true)
        let suite = "com.jdforsythe.claudio.int.\(UUID().uuidString)"
        settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)  // swiftlint:disable:this force_unwrapping
        backend = MockBackend()
        sink = RecordingPlaybackSink()
        let paths = Paths(environment: ["CLAUDE_CONFIG_DIR": root.appendingPathComponent("cfg").path], home: root, bundleURL: nil)
        let discovery = SessionDiscovery(roots: [paths.defaultTranscriptRoot])
        registry = SessionRegistry(discovery: discovery, probe: nil, store: SessionStateCache(fileURL: root.appendingPathComponent("sessions.json"), clock: SystemClock()),
                                   settings: settings, projectPrefs: ProjectPreferences(fileURL: root.appendingPathComponent("projects.json")), paths: paths)
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
        try? FileManager.default.removeItem(at: root)
    }

    private var transcript: URL { root.appendingPathComponent("cfg/projects/-Users-fixture-project-1/\(session).jsonl") }

    private func append(_ lines: [Data], to url: URL? = nil) {
        let target = url ?? transcript
        var data = Data()
        for l in lines { data.append(l); data.append(0x0A) }
        if let h = try? FileHandle(forWritingTo: target) { h.seekToEndOfFile(); h.write(data); try? h.close() } else { try? data.write(to: target) }
    }

    private func wait(_ seconds: TimeInterval, _ cond: @escaping () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await cond() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return await cond()
    }

    private func record(_ data: Data) -> Data {
        // Rewrite the session id so the file name and records agree.
        var obj = try! JSONSerialization.jsonObject(with: data) as! [String: Any]  // swiftlint:disable:this force_try force_cast
        obj["sessionId"] = session
        return try! JSONSerialization.data(withJSONObject: obj)  // swiftlint:disable:this force_try
    }

    func test_Story01_11_liveTranscript_isDiscoveredSpokenInOrder_andHistoryNeverReplayed() async throws {
        // Pre-existing history that must never be spoken.
        append([record(RecordBuilder.humanPrompt("old", promptID: "old")), record(RecordBuilder.text("Old answer never spoken.", messageID: "old1"))])
        let ok1 = await wait(3) { await self.registry.session(self.session) != nil }
        XCTAssertTrue(ok1)
        let ok2 = await wait(2) { await self.arbiter.activeSessionID == self.session }
        XCTAssertTrue(ok2)
        append([record(RecordBuilder.humanPrompt("hi", promptID: "p1"))])
        append([record(RecordBuilder.text("Looking at the file first to orient myself.", messageID: "m1", stopReason: "tool_use")),
                record(RecordBuilder.toolUse(name: "Read", input: ["file_path": "/a/Parser.swift"], messageID: "m1")),
                record(RecordBuilder.text("The answer is forty two and that is final.", messageID: "m2")),
                record(RecordBuilder.turnDuration())])
        let ok3 = await wait(5) { self.backend.calls.count >= 3 }
        XCTAssertTrue(ok3)
        XCTAssertEqual(backend.calls.map(\.text), ["Looking at the file first to orient myself.", "Reading Parser dot swift.", "The answer is forty two and that is final."])
        XCTAssertFalse(backend.calls.contains { $0.text.contains("Old answer") })
        let ok4 = await wait(2) { self.sink.finishedOrder.count == 3 }
        XCTAssertTrue(ok4)
    }

    func test_Story02b_transcriptPromptCancelsWithin600ms() async throws {
        backend = MockBackend(delay: 0.4)
        await pipeline.setBackend(backend)
        append([record(RecordBuilder.humanPrompt("hi", promptID: "p1"))])
        let ok5 = await wait(3) { await self.arbiter.activeSessionID == self.session }
        XCTAssertTrue(ok5)
        append([record(RecordBuilder.text("A long answer that is still being synthesized when the prompt lands.", messageID: "m1"))])
        let ok6 = await wait(3) { self.backend.calls.count == 1 }
        XCTAssertTrue(ok6)
        let sent = Date()
        append([record(RecordBuilder.humanPrompt("next", promptID: "p2"))])
        let ok7 = await wait(2) { self.backend.cancelledCount >= 1 }
        XCTAssertTrue(ok7)
        XCTAssertLessThan(Date().timeIntervalSince(sent), 0.6)
    }

    func test_Story09_hooksDisabled_claudeDirUnchanged() async throws {
        let before = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("cfg").path).sorted()
        append([record(RecordBuilder.humanPrompt("hi", promptID: "p0"))])
        let discovered = await wait(3) { await self.arbiter.activeSessionID == self.session }
        XCTAssertTrue(discovered)
        append([record(RecordBuilder.humanPrompt("hi", promptID: "p1")), record(RecordBuilder.text("Answer.", messageID: "m1")), record(RecordBuilder.turnDuration())])
        let spoken = await wait(3) { self.backend.calls.count >= 1 }
        XCTAssertTrue(spoken)
        let after = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("cfg").path).sorted()
        XCTAssertEqual(before, after)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cfg/settings.json").path))
    }

    func test_Story10_hookCoexistence_installThenUninstall_foreignEntriesIdentical() throws {
        let settingsURL = root.appendingPathComponent("cfg/settings.json")
        let fixture = try XCTUnwrap(TestFixtures.url("settings/with-orca-and-plugins.json"))
        try FileManager.default.copyItem(at: fixture, to: settingsURL)
        let before = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? NSDictionary
        let installer = HookInstaller(settingsURL: settingsURL, backupsDirectory: root.appendingPathComponent("backups"), bundleURL: root.appendingPathComponent("Claudio.app"))
        try installer.install()
        try installer.uninstall()
        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? NSDictionary
        XCTAssertEqual(before, after)
    }

    func test_HookReceiver_builtCLI_forwardsRawPayload_andExitsZeroWithoutApp() throws {
        guard let products = ProcessInfo.processInfo.environment["CLAUDIO_BUILT_PRODUCTS"] else { throw XCTSkip("CLAUDIO_BUILT_PRODUCTS unset") }
        let cli = URL(fileURLWithPath: products).appendingPathComponent("claudio-cli")
        guard FileManager.default.isExecutableFile(atPath: cli.path) else { throw XCTSkip("claudio-cli not built") }
        let socket = "/tmp/claudio-hook-test-\(UUID().uuidString.prefix(8)).sock"
        defer { unlink(socket) }
        let received = Mutex<[ControlEnvelope]>([])
        let server = ControlServer(path: socket) { envelope, _ in received.withLock { $0.append(envelope) } }
        try server.start()
        defer { server.stop() }
        let payload = #"{"hook_event_name":"UserPromptSubmit","session_id":"abc","prompt_text":"hi / there"}"#
        func run(env: [String: String]) -> (Int32, TimeInterval) {
            let p = Process()
            p.executableURL = cli
            p.arguments = ["hook"]
            p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
            let input = Pipe()
            p.standardInput = input
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            let start = Date()
            try? p.run()
            input.fileHandleForWriting.write(Data(payload.utf8))
            try? input.fileHandleForWriting.close()
            p.waitUntilExit()
            return (p.terminationStatus, Date().timeIntervalSince(start))
        }
        let (status, elapsed) = run(env: ["CLAUDIO_SOCKET": socket])
        XCTAssertEqual(status, 0)
        XCTAssertLessThan(elapsed, 0.5)
        let deadline = Date().addingTimeInterval(2)
        while received.withLock({ $0.isEmpty }), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        let envelope = try XCTUnwrap(received.withLock { $0.first })
        XCTAssertEqual(envelope.event, "UserPromptSubmit")
        XCTAssertEqual(envelope.session, "abc")
        XCTAssertEqual(envelope.payload?.jsonValue?["prompt_text"]?.stringValue, "hi / there")
        let (status2, _) = run(env: ["CLAUDIO_SOCKET": "/tmp/claudio-nonexistent-\(UUID().uuidString).sock"])
        XCTAssertEqual(status2, 0)
    }
}

