import Foundation

public struct PersistedUnreadTurn: Codable, Sendable, Equatable {
    public let turnID: TurnID
    public let endedAt: Date
    public let finalAnswerText: String

    public init(turnID: TurnID, endedAt: Date, finalAnswerText: String) {
        self.turnID = turnID
        self.endedAt = endedAt
        self.finalAnswerText = finalAnswerText
    }
}

public struct PersistedSession: Codable, Sendable, Equatable {
    public let id: SessionID
    public let title: String
    public let cwd: String
    public let transcriptPath: String
    public let root: String
    public let entrypoint: SessionEntrypoint
    public let level: SpeechLevel
    public let colorIndex: Int
    public let lastActivity: Date
    public let status: SessionStatus
    public let unreadTurns: [PersistedUnreadTurn]

    public init(id: SessionID, title: String, cwd: String, transcriptPath: String, root: String,
                entrypoint: SessionEntrypoint, level: SpeechLevel, colorIndex: Int, lastActivity: Date,
                status: SessionStatus, unreadTurns: [PersistedUnreadTurn]) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.root = root
        self.entrypoint = entrypoint
        self.level = level
        self.colorIndex = colorIndex
        self.lastActivity = lastActivity
        self.status = status
        self.unreadTurns = unreadTurns
    }
}

/// `sessions.json` reader/writer with debounced saves (document 08 §5).
public actor SessionStateCache {
    public struct Snapshot: Codable, Sendable, Equatable {
        public var version: Int
        public var savedAt: Date
        public var activeSessionID: SessionID?
        public var sessions: [PersistedSession]

        public init(version: Int = SchemaMigration.currentSessionsVersion, savedAt: Date, activeSessionID: SessionID?,
                    sessions: [PersistedSession]) {
            self.version = version
            self.savedAt = savedAt
            self.activeSessionID = activeSessionID
            self.sessions = sessions
        }
    }

    public static let maxUnreadPerSession = 5
    public static let maxSessions = 200
    public static let maxFinalAnswerCharacters = 20_000
    public static let debounceSeconds: TimeInterval = 2

    private let fileURL: URL
    private let clock: any ClaudioClock
    private var pending: Snapshot?
    private var saveTask: Task<Void, Never>?

    public init(fileURL: URL, clock: any ClaudioClock) {
        self.fileURL = fileURL
        self.clock = clock
    }

    public func load() throws -> Snapshot? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        do {
            var json = try (JSONSerialization.jsonObject(with: data) as? JSONObject) ?? [:]
            do {
                try SchemaMigration.migrateSessions(&json)
            } catch SchemaMigration.MigrationError.newerVersion(let v) {
                let renamed = fileURL.appendingPathExtension("newer-\(v)")
                try? fm.moveItem(at: fileURL, to: renamed)
                Log.settings.error("sessions.json was written by a newer Claudio; starting fresh")
                return nil
            }
            let migrated = try JSONSerialization.data(withJSONObject: json)
            return try ControlCoding.decoder().decode(Snapshot.self, from: migrated)
        } catch {
            let stamp = Self.stamp(clock.now)
            let renamed = fileURL.deletingLastPathComponent()
                .appendingPathComponent("sessions.json.corrupt-\(stamp)")
            try? fm.moveItem(at: fileURL, to: renamed)
            Log.settings.error("sessions.json corrupt (\(error)); renamed to \(renamed.lastPathComponent)")
            return nil
        }
    }

    public func scheduleSave(_ snapshot: Snapshot) {
        pending = Self.capped(snapshot)
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            guard let self else { return }
            try? await self.clock.sleep(for: Self.debounceSeconds)
            await self.flush()
        }
    }

    public func saveNow(_ snapshot: Snapshot) throws {
        saveTask?.cancel()
        saveTask = nil
        pending = nil
        try write(Self.capped(snapshot))
    }

    public func flushPending() throws {
        if let p = pending {
            pending = nil
            try write(p)
        }
    }

    private func flush() {
        saveTask = nil
        guard let p = pending else { return }
        pending = nil
        do {
            try write(p)
        } catch {
            Log.settings.error("sessions.json write failed: \(error)")
        }
    }

    private func write(_ snapshot: Snapshot) throws {
        let encoder = ControlCoding.encoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(snapshot)
        try AtomicFile.write(data, to: fileURL)
    }

    public static func capped(_ snapshot: Snapshot) -> Snapshot {
        var s = snapshot
        s.sessions = s.sessions.sorted { $0.lastActivity > $1.lastActivity }.prefix(maxSessions).map { ps in
            let turns = ps.unreadTurns.suffix(maxUnreadPerSession).map { t in
                PersistedUnreadTurn(turnID: t.turnID, endedAt: t.endedAt,
                                    finalAnswerText: truncate(t.finalAnswerText))
            }
            return PersistedSession(id: ps.id, title: ps.title, cwd: ps.cwd, transcriptPath: ps.transcriptPath,
                                    root: ps.root, entrypoint: ps.entrypoint, level: ps.level,
                                    colorIndex: ps.colorIndex, lastActivity: ps.lastActivity, status: ps.status,
                                    unreadTurns: Array(turns))
        }
        return s
    }

    public static func truncate(_ text: String) -> String {
        guard text.count > maxFinalAnswerCharacters else { return text }
        return String(text.prefix(maxFinalAnswerCharacters)) + "…"
    }

    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }
}
