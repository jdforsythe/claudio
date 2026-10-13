import AppKit
import ClaudioControlProtocol
import Foundation

/// Socket ping → activate the running instance and exit (document 07 §1.3).
enum SingleInstance {
    static func ensure(socketPath: String) {
        let client = ControlClient(socketPath: socketPath, connectTimeoutMs: 500)
        guard FileManager.default.fileExists(atPath: socketPath) else { return }
        // A stale socket file refuses connections; a live instance accepts even if it is slow to answer.
        guard let fd = try? client.connect() else { return }
        close(fd)
        _ = try? client.send(.activate, readTimeoutMs: 2000)
        exit(0)
    }
}
