import Foundation

/// Per-project defaults stored in `projects.json` (document 08 §4).
public actor ProjectPreferences {
    public struct Entry: Codable, Sendable, Equatable {
        public var defaultLevel: SpeechLevel
        public var displayName: String?
        public var muted: Bool?

        public init(defaultLevel: SpeechLevel, displayName: String? = nil, muted: Bool? = nil) {
            self.defaultLevel = defaultLevel
            self.displayName = displayName
            self.muted = muted
        }
    }

    private struct File: Codable {
        var version: Int
        var projects: [String: Entry]
    }

    private let fileURL: URL
    private let home: String
    private var table: [String: Entry] = [:]
    private let broadcast = Broadcast<[URL: Entry]>()

    public init(fileURL: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.fileURL = fileURL
        self.home = Self.canonical(home)
        if let data = try? Data(contentsOf: fileURL) {
            do {
                var json = try (JSONSerialization.jsonObject(with: data) as? JSONObject) ?? [:]
                try SchemaMigration.migrateProjects(&json)
                let migrated = try JSONSerialization.data(withJSONObject: json)
                let file = try JSONDecoder().decode(File.self, from: migrated)
                table = file.projects
            } catch {
                Log.settings.error("projects.json unreadable: \(error); starting empty")
            }
        }
    }

    public static func canonical(_ url: URL) -> String {
        var path = url.resolvingSymlinksInPath().standardizedFileURL.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    public func entries() -> [URL: Entry] {
        Dictionary(uniqueKeysWithValues: table.map { (URL(fileURLWithPath: $0.key), $0.value) })
    }

    /// Exact match, then nearest ancestor. Entries at `/` or the home directory match exactly only.
    public func entry(matching cwd: URL) -> (URL, Entry)? {
        let path = Self.canonical(cwd)
        if let e = table[path] { return (URL(fileURLWithPath: path), e) }
        var current = path
        while current != "/" {
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { break }
            current = parent
            if current == home || current == "/" { break }
            if let e = table[current] { return (URL(fileURLWithPath: current), e) }
        }
        return nil
    }

    public func defaultLevel(forCwd cwd: URL) -> SpeechLevel? {
        entry(matching: cwd)?.1.defaultLevel
    }

    public func set(_ entry: Entry, for cwd: URL) throws {
        var updated = table
        updated[Self.canonical(cwd)] = entry
        try write(updated)
        table = updated
        broadcast.send(entries())
    }

    public func remove(for cwd: URL) throws {
        var updated = table
        updated.removeValue(forKey: Self.canonical(cwd))
        try write(updated)
        table = updated
        broadcast.send(entries())
    }

    public nonisolated func changes() -> AsyncStream<[URL: Entry]> { broadcast.subscribe() }

    private func write(_ projects: [String: Entry]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(File(version: SchemaMigration.currentProjectsVersion, projects: projects))
        try AtomicFile.write(data, to: fileURL)
    }
}
