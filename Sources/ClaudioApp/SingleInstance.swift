import AppKit
import ClaudioControlProtocol
import Foundation

/// Socket ping → activate the running instance and exit (document 07 §1.3).
enum SingleInstance {
    static func ensure(socketPath: String) {
        let client = ControlClient(socketPath: socketPath, connectTimeoutMs: 200)
        guard FileManager.default.fileExists(atPath: socketPath) else { return }
        if let response = try? client.send(.ping, readTimeoutMs: 500), response.ok {
            _ = try? client.send(.activate, readTimeoutMs: 500)
            exit(0)
        }
        // Stale socket from a crash: the server removes it before binding.
    }
}
