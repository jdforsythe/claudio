import ClaudioCore
import TestSupport
import XCTest

final class SettingsTests: XCTestCase {
    func test_AppSettings_defaults_roundTrip_validation() async {
        let s = makeTestSettings()
        XCTAssertEqual(s.backendID, "edge")
        XCTAssertEqual(s.voiceID, "en-US-GuyNeural")
        XCTAssertEqual(s.rate, 1.0)
        XCTAssertEqual(s.defaultLevelNewSession, .answers)
        XCTAssertEqual(s.defaultLevelActive, .narrate)
        XCTAssertTrue(s.eventsEnabled)
        XCTAssertEqual(s.lookahead, 2)
        s.rate = 9
        XCTAssertEqual(s.rate, 2.0)
        s.hudFrame = CGRect(x: 1, y: 2, width: 3, height: 4)
        XCTAssertEqual(s.hudFrame, CGRect(x: 1, y: 2, width: 3, height: 4))
        s.extraTranscriptRoots = [URL(fileURLWithPath: "/tmp/a")]
        XCTAssertEqual(s.extraTranscriptRoots.map(\.path), ["/tmp/a"])
        s.resetAll()
        XCTAssertEqual(s.rate, 1.0)
    }

    func test_AppSettings_backendChange_resetsForeignVoiceID_andPublishesSnapshot() async {
        let s = makeTestSettings()
        let stream = s.changes()
        s.voiceID = "en-US-AriaNeural"
        s.backendID = "openai"
        XCTAssertEqual(s.voiceID, "alloy")
        var iterator = stream.makeAsyncIterator()
        let snap = await iterator.next()
        XCTAssertNotNil(snap)
    }

    func test_ProjectPreferences_matching_andAtomicWrite() async throws {
        let root = TempRoot()
        defer { root.cleanup() }
        let home = root.path("home")
        let prefs = ProjectPreferences(fileURL: root.path("projects.json"), home: home)
        let yard = home.appendingPathComponent("dev/yard")
        try await prefs.set(.init(defaultLevel: .narrate, displayName: "Yard"), for: yard)
        try await prefs.set(.init(defaultLevel: .quiet), for: home)
        let exact = await prefs.entry(matching: yard)
        XCTAssertEqual(exact?.1.defaultLevel, .narrate)
        let worktree = await prefs.entry(matching: yard.appendingPathComponent(".orca/worktrees/feature-x"))
        XCTAssertEqual(worktree?.0.path, ProjectPreferences.canonical(yard))
        let unrelated = await prefs.entry(matching: home.appendingPathComponent("dev/other"))
        XCTAssertNil(unrelated, "home-level entries match exactly only")
        let homeExact = await prefs.entry(matching: home)
        XCTAssertEqual(homeExact?.1.defaultLevel, .quiet)
        let reloaded = ProjectPreferences(fileURL: root.path("projects.json"), home: home)
        let counted9 = await reloaded.entries()
        XCTAssertEqual(counted9.count, 2)
    }

    func test_SessionStateCache_capsAndCorruptHandling() async throws {
        let root = TempRoot()
        defer { root.cleanup() }
        let clock = ManualClock()
        let cache = SessionStateCache(fileURL: root.path("sessions.json"), clock: clock)
        let turns = (0..<8).map { PersistedUnreadTurn(turnID: "t\($0)", endedAt: clock.now, finalAnswerText: String(repeating: "x", count: 30_000)) }
        let session = PersistedSession(id: "s", title: "T", cwd: "/a", transcriptPath: "/a/s.jsonl", root: "/a", entrypoint: .cli,
                                       level: .answers, colorIndex: 1, lastActivity: clock.now, status: .busy, unreadTurns: turns)
        try await cache.saveNow(.init(savedAt: clock.now, activeSessionID: "s", sessions: [session]))
        let loaded = try await cache.load()
        XCTAssertEqual(loaded?.sessions.first?.unreadTurns.count, 5)
        XCTAssertEqual(loaded?.sessions.first?.unreadTurns.first?.turnID, "t3")
        XCTAssertEqual(loaded?.sessions.first?.unreadTurns.first?.finalAnswerText.count, 20_001)
        try "not json".write(to: root.path("sessions.json"), atomically: true, encoding: .utf8)
        let value10 = try await cache.load()
        XCTAssertNil(value10)
        let files = try FileManager.default.contentsOfDirectory(atPath: root.url.path)
        XCTAssertTrue(files.contains { $0.hasPrefix("sessions.json.corrupt-") })
        try #"{"version":9,"savedAt":"2026-01-01T00:00:00Z","sessions":[]}"#.write(to: root.path("sessions.json"), atomically: true, encoding: .utf8)
        let value11 = try await cache.load()
        XCTAssertNil(value11)
    }

    func test_SessionStateCache_debouncedSave_writesOnceForBurst() async throws {
        let root = TempRoot()
        defer { root.cleanup() }
        let clock = ManualClock()
        let cache = SessionStateCache(fileURL: root.path("sessions.json"), clock: clock)
        for i in 0..<5 { await cache.scheduleSave(.init(savedAt: clock.now, activeSessionID: "\(i)", sessions: [])) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path("sessions.json").path))
        _ = await waitUntil(1) { clock.pendingSleepers == 1 }
        clock.advance(by: 3)
        let ok12 = await waitUntil(1) { FileManager.default.fileExists(atPath: root.path("sessions.json").path) }
        XCTAssertTrue(ok12)
        let loaded = try await cache.load()
        XCTAssertEqual(loaded?.activeSessionID, "4")
    }

    func test_Paths_configDirOverride_rootsFilter_andHookCommand() {
        let root = TempRoot()
        defer { root.cleanup() }
        let p = Paths(environment: ["CLAUDE_CONFIG_DIR": root.path("cfg").path, "CLAUDIO_ROOTS": root.path("extra").path], home: root.url, bundleURL: root.path("Claudio.app"))
        XCTAssertEqual(p.claudeSettingsFile.path, root.path("cfg/settings.json").path)
        XCTAssertEqual(p.defaultTranscriptRoot.path, root.path("cfg/projects").path)
        XCTAssertEqual(p.transcriptRoots(extra: [root.path("missing")]), [])
        try? FileManager.default.createDirectory(at: root.path("extra"), withIntermediateDirectories: true)
        XCTAssertEqual(p.transcriptRoots(extra: [root.path("extra")]).count, 1)
        XCTAssertEqual(p.hookCommand, root.path("Claudio.app").path + "/Contents/Helpers/claudio hook")
        let unbundled = Paths(environment: [:], home: root.url, bundleURL: root.path(".build/debug"))
        XCTAssertNil(unbundled.hookCommand)
        XCTAssertLessThan(p.controlSocket.path.utf8.count, 104)
    }

    func test_SchemaMigration_sequentialStepsApplied() throws {
        var json: JSONObject = ["version": 1, "a": 1]
        try SchemaMigration.migrate(&json, to: 3, steps: [1: { $0["b"] = 2 }, 2: { $0["c"] = 3 }])
        XCTAssertEqual(json["version"] as? Int, 3)
        XCTAssertEqual(json["b"] as? Int, 2)
        XCTAssertEqual(json["c"] as? Int, 3)
        var newer: JSONObject = ["version": 5]
        XCTAssertThrowsError(try SchemaMigration.migrate(&newer, to: 3, steps: [:]))
    }
}
