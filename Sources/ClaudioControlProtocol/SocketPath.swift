import Foundation

/// Resolution of the control socket path, shared byte-for-byte by app and CLI (document 02 §8).
public enum SocketPath {
    public static let maxBytes = 104

    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment,
                               home: String = NSHomeDirectory()) -> String {
        if let override = environment["CLAUDIO_SOCKET"], !override.isEmpty {
            return override
        }
        let preferred = home + "/Library/Application Support/Claudio/claudio.sock"
        if preferred.utf8.count < maxBytes - 3 {
            return preferred
        }
        let marker = home + "/Library/Application Support/Claudio/socket-path"
        if let chosen = try? String(contentsOfFile: marker, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !chosen.isEmpty {
            return chosen
        }
        return "/tmp/claudio-\(getuid()).sock"
    }
}
