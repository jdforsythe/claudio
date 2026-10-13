import ClaudioCore
import Synchronization
import TestSupport
import XCTest

final class ControlServerTests: XCTestCase {
    func test_ControlServer_roundTrip_hookNoResponse_mode0600_staleReplaced() throws {
        let path = "/tmp/claudio-test-\(UUID().uuidString.prefix(8)).sock"
        defer { unlink(path) }
        // Stale file from a "crash"
        FileManager.default.createFile(atPath: path, contents: nil)
        let received = Mutex<[ControlEnvelope]>([])
        let server = ControlServer(path: path) { envelope, writer in
            received.withLock { $0.append(envelope) }
            if envelope.kind == "request" { writer.write(.success(.text("pong"))) }
        }
        try server.start()
        defer { server.stop() }
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        let client = ControlClient(socketPath: path)
        let response = try client.send(.ping)
        XCTAssertEqual(response.result, .text("pong"))
        try client.sendHook(ControlEnvelope(hookEvent: "Stop", session: "s", payload: RawJSON(string: #"{"hook_event_name":"Stop","session_id":"s"}"#)))
        XCTAssertTrue(waitSync(1) { received.withLock { $0.count } == 2 })
        XCTAssertEqual(received.withLock { $0.last?.kind }, "hook")
        // A second server on the same live socket must refuse.
        let second = ControlServer(path: path) { _, _ in }
        XCTAssertThrowsError(try second.start()) { XCTAssertEqual($0 as? ControlServer.ServerError, .anotherInstanceRunning) }
    }

    func test_ControlServer_unsupportedVersion_respondsWithError() throws {
        let path = "/tmp/claudio-test-\(UUID().uuidString.prefix(8)).sock"
        defer { unlink(path) }
        let server = ControlServer(path: path) { _, writer in writer.write(.success(.none)) }
        try server.start()
        defer { server.stop() }
        let client = ControlClient(socketPath: path)
        let fd = try client.connect()
        let line = Data((#"{"v":99,"kind":"request","request":{"ping":{}}}"# + "\n").utf8)
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        shutdown(fd, SHUT_WR)
        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &buffer, buffer.count)
        close(fd)
        let text = String(decoding: buffer[0..<max(0, n)], as: UTF8.self)
        XCTAssertTrue(text.contains("not supported"))
    }
}

