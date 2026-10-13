import ClaudioControlProtocol
import TestSupport
import XCTest

final class ControlProtocolTests: XCTestCase {
    func test_ControlEnvelope_everyRequestCase_roundTripsJSON() throws {
        let cases: [ControlRequest] = [
            .status, .sessions, .switch(query: "yard"), .switch(query: nil), .level(.narrate, session: "id:abc"), .pause, .resume,
            .toggle, .skip, .live, .mute(true), .say(text: "hello"), .hooksStatus, .hooksInstall, .hooksUninstall, .link(false),
            .skill(install: true), .version, .ping, .activate, .quit, .render(markdown: "# hi"), .subscribe(.items, session: nil),
            .bench(backend: "edge", fixture: nil, runs: 3), .doctor, .dumpState, .voices(backend: "apple"),
            .speakSession(session: "x", level: .answers),
        ]
        for request in cases {
            let data = try ControlCoding.encodeLine(ControlEnvelope(request: request))
            let decoded = try ControlCoding.decoder().decode(ControlEnvelope.self, from: data)
            XCTAssertEqual(decoded.request, request)
            XCTAssertEqual(decoded.v, ControlProtocolVersion.current)
            XCTAssertEqual(decoded.kind, "request")
        }
    }

    func test_ControlEnvelope_everyResultCase_roundTripsJSON() throws {
        let summary = SessionSummary(id: "s", title: "t", cwd: "/x", entrypoint: .cli, status: .busy, level: .narrate, unread: 2,
                                     active: true, lastActivity: Date(timeIntervalSince1970: 1_700_000_000))
        let status = StatusReport(version: "0.1.0", playback: "idle", activeSession: summary, backend: "edge", voice: "v", rate: 1,
                                  eventsMuted: false, hooks: .installed(count: 7, bundlePath: "/Applications/Claudio.app"),
                                  sessionsLive: 1, metrics: ["a": 1], socketPath: "/tmp/x.sock", pid: 1, uptimeSeconds: 2)
        let cases: [ControlResult] = [
            .status(status), .sessions([summary]), .session(summary), .hooks(.notInstalled), .hooks(.settingsUnreadable("bad")),
            .text("x"), .segments([SegmentSummary(kind: "sentence", text: "Hi.")]),
            .item(SpeechItemSummary(session: "s", turn: nil, category: .finalAnswer, text: "t", filtered: false, timestamp: Date(timeIntervalSince1970: 1))),
            .record(type: "user", uuid: nil, summary: "x"), .doctor([DoctorCheck(name: "n", state: "pass", detail: "d")]),
            .voices([VoiceSummary(backend: "apple", id: "i", displayName: "d", locale: "en-US", gender: nil, quality: nil)]), .none,
        ]
        for result in cases {
            let data = try ControlCoding.encodeLine(ControlResponse.success(result))
            let decoded = try ControlCoding.decoder().decode(ControlResponse.self, from: data)
            XCTAssertEqual(decoded.result, result)
            XCTAssertTrue(decoded.ok)
        }
    }

    func test_ControlEnvelope_hookKind_preservesRawPayload() throws {
        let payload = #"{"hook_event_name":"Stop","session_id":"abc","last_assistant_message":"a \"quoted\" / value"}"#
        let line = Data(#"{"v":1,"kind":"hook","event":"Stop","session":"abc","payload":\#(payload)}"#.utf8)
        let envelope = try ControlCoding.decoder().decode(ControlEnvelope.self, from: line)
        XCTAssertEqual(envelope.kind, "hook")
        let event = try XCTUnwrap(HookEvent.decode(envelope: envelope, now: Date()))
        XCTAssertEqual(event.name, "Stop")
        XCTAssertEqual(event.sessionID, "abc")
        XCTAssertEqual(event.string("last_assistant_message"), "a \"quoted\" / value")
    }

    func test_HookEvent_eachInstalledEvent_decodes() throws {
        let names = ["UserPromptSubmit", "Stop", "StopFailure", "SubagentStop", "Notification", "SessionStart", "SessionEnd"]
        for name in names {
            let url = try XCTUnwrap(TestFixtures.url("hooks/\(name).json"))
            let raw = try Data(contentsOf: url)
            let envelope = ControlEnvelope(hookEvent: name, session: "562358f2-0209-4cc5-b2be-9157fd4b6a9d", payload: RawJSON(data: raw))
            let event = try XCTUnwrap(HookEvent.decode(envelope: envelope, now: Date()))
            XCTAssertEqual(event.name, name)
            XCTAssertEqual(event.sessionID, "562358f2-0209-4cc5-b2be-9157fd4b6a9d")
        }
    }

    func test_ControlResponse_newerVersion_isReportedAsMismatch() {
        let line = Data(#"{"v":2,"ok":true}"#.utf8)
        XCTAssertThrowsError(try ControlClient.decodeResponse(line)) { error in
            XCTAssertEqual(error as? ControlClient.ClientError, .protocolMismatch(2))
        }
    }

    func test_SocketPath_overrideAndLengthFallback() {
        XCTAssertEqual(SocketPath.resolve(environment: ["CLAUDIO_SOCKET": "/tmp/x.sock"], home: "/Users/a"), "/tmp/x.sock")
        XCTAssertEqual(SocketPath.resolve(environment: [:], home: "/Users/a"), "/Users/a/Library/Application Support/Claudio/claudio.sock")
        let longHome = "/Volumes/" + String(repeating: "x", count: 90)
        XCTAssertTrue(SocketPath.resolve(environment: [:], home: longHome).hasPrefix("/tmp/claudio-"))
    }

    func test_ControlClient_noServer_failsFast() {
        let client = ControlClient(socketPath: "/tmp/claudio-test-no-server-\(UUID().uuidString).sock", connectTimeoutMs: 20)
        let start = Date()
        XCTAssertThrowsError(try client.send(.ping))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }
}
