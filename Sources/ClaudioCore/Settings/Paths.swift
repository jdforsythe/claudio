import Foundation

/// Every filesystem location Claudio uses (document 02 §8, document 08 §9).
public struct Paths: Sendable {
    public let home: URL
    public let environment: [String: String]
    public let bundleURL: URL?

    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                home: URL = FileManager.default.homeDirectoryForCurrentUser,
                bundleURL: URL? = Bundle.main.bundleURL) {
        self.environment = environment
        self.home = home
        self.bundleURL = bundleURL
    }

    // MARK: Claude Code

    public var claudeConfigDir: URL {
        if let dir = environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        }
        return home.appendingPathComponent(".claude")
    }

    public var claudeSettingsFile: URL { claudeConfigDir.appendingPathComponent("settings.json") }
    public var defaultTranscriptRoot: URL { claudeConfigDir.appendingPathComponent("projects") }
    public var claudeSkillsDir: URL { claudeConfigDir.appendingPathComponent("skills") }
    public var speakSkillDir: URL { claudeSkillsDir.appendingPathComponent("speak") }

    /// Default root plus extras (and `CLAUDIO_ROOTS`), deduplicated, existing directories only.
    public func transcriptRoots(extra: [URL]) -> [URL] {
        var candidates: [URL] = [defaultTranscriptRoot]
        candidates.append(contentsOf: extra)
        if let env = environment["CLAUDIO_ROOTS"] {
            for p in env.split(separator: ":") where !p.isEmpty {
                candidates.append(URL(fileURLWithPath: (String(p) as NSString).expandingTildeInPath))
            }
        }
        var seen = Set<String>()
        var out: [URL] = []
        for c in candidates {
            let resolved = c.resolvingSymlinksInPath().standardizedFileURL
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if seen.insert(resolved.path).inserted { out.append(resolved) }
        }
        return out
    }

    /// Every candidate root regardless of existence (used by discovery to watch parents that appear later).
    public func allTranscriptRootCandidates(extra: [URL]) -> [URL] {
        var candidates: [URL] = [defaultTranscriptRoot]
        candidates.append(contentsOf: extra)
        if let env = environment["CLAUDIO_ROOTS"] {
            for p in env.split(separator: ":") where !p.isEmpty {
                candidates.append(URL(fileURLWithPath: (String(p) as NSString).expandingTildeInPath))
            }
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    // MARK: Claudio

    public var applicationSupport: URL {
        home.appendingPathComponent("Library/Application Support/Claudio")
    }

    public var controlSocket: URL {
        URL(fileURLWithPath: SocketPath.resolve(environment: environment, home: home.path))
    }

    public var socketPathMarker: URL { applicationSupport.appendingPathComponent("socket-path") }
    public var projectsFile: URL { applicationSupport.appendingPathComponent("projects.json") }
    public var sessionsFile: URL { applicationSupport.appendingPathComponent("sessions.json") }
    public func voiceCacheFile(_ backend: BackendID) -> URL {
        applicationSupport.appendingPathComponent("voices-\(backend).json")
    }
    public var backupsDirectory: URL { applicationSupport.appendingPathComponent("backups") }
    public var logsDirectory: URL { home.appendingPathComponent("Library/Logs/Claudio") }
    public var logFile: URL { logsDirectory.appendingPathComponent("claudio.log") }

    // MARK: Bundle

    public var isBundled: Bool {
        guard let bundleURL else { return false }
        return bundleURL.pathExtension == "app" && environment["CLAUDIO_UNBUNDLED"] != "1"
    }

    public var cliExecutable: URL? {
        guard let bundleURL else { return nil }
        if isBundled {
            return bundleURL.appendingPathComponent("Contents/Helpers/claudio")
        }
        // Unbundled: the CLI product is `claudio-cli` next to the app binary in .build/<config>/ (D-30).
        for dir in [bundleURL, bundleURL.deletingLastPathComponent()] {
            let sibling = dir.appendingPathComponent("claudio-cli")
            if FileManager.default.isExecutableFile(atPath: sibling.path) { return sibling }
        }
        return nil
    }

    public var hookCommand: String? {
        guard isBundled, let cli = cliExecutable else { return nil }
        return "\(cli.path) hook"
    }

    public var cliSymlink: URL { URL(fileURLWithPath: "/usr/local/bin/claudio") }

    public func ensureDirectories() throws {
        let fm = FileManager.default
        for dir in [applicationSupport, backupsDirectory, logsDirectory] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }
        let socket = controlSocket.path
        if socket.hasPrefix("/tmp/") {
            try? socket.write(to: socketPathMarker, atomically: true, encoding: .utf8)
        } else {
            try? fm.removeItem(at: socketPathMarker)
        }
    }
}
