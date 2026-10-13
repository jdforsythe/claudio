import Foundation

public struct UnreadTurn: Sendable, Equatable, Codable {
    public let turnID: TurnID
    public let endedAt: Date
    public let finalAnswerText: String

    public init(turnID: TurnID, endedAt: Date, finalAnswerText: String) {
        self.turnID = turnID
        self.endedAt = endedAt
        self.finalAnswerText = finalAnswerText
    }
}

/// One Claude Code conversation (document 02 §4).
public struct Session: Identifiable, Sendable, Equatable {
    public let id: SessionID
    public var title: String
    public var cwd: URL
    public var transcriptURL: URL
    public var root: URL
    public var entrypoint: SessionEntrypoint
    public var status: SessionStatus
    public var level: SpeechLevel
    public var colorIndex: Int
    public var lastActivity: Date
    public var unreadTurns: [UnreadTurn]
    public var currentTurn: TurnID?
    public var pid: Int32?
    public var permissionMode: String?
    public var lastPrompt: String?
    public var muted: Bool
    public var hasSeenAITitle: Bool
    public var probeName: String?
    public var subagentActivity: Int
    /// Title as given by the transcript/hooks/probe before dedup suffixing.
    public var baseTitle: String

    public init(id: SessionID, title: String, cwd: URL, transcriptURL: URL, root: URL,
                entrypoint: SessionEntrypoint = .unknown, status: SessionStatus = .idle, level: SpeechLevel = .answers,
                colorIndex: Int, lastActivity: Date, unreadTurns: [UnreadTurn] = [], currentTurn: TurnID? = nil,
                pid: Int32? = nil, permissionMode: String? = nil, lastPrompt: String? = nil, muted: Bool = false,
                hasSeenAITitle: Bool = false, probeName: String? = nil, subagentActivity: Int = 0) {
        self.id = id
        self.title = title
        self.baseTitle = title
        self.cwd = cwd
        self.transcriptURL = transcriptURL
        self.root = root
        self.entrypoint = entrypoint
        self.status = status
        self.level = level
        self.colorIndex = colorIndex
        self.lastActivity = lastActivity
        self.unreadTurns = unreadTurns
        self.currentTurn = currentTurn
        self.pid = pid
        self.permissionMode = permissionMode
        self.lastPrompt = lastPrompt
        self.muted = muted
        self.hasSeenAITitle = hasSeenAITitle
        self.probeName = probeName
        self.subagentActivity = subagentActivity
    }

    public var isLive: Bool { status != .ended }

    public static func colorIndex(for id: SessionID) -> Int {
        Int(fnv1a64(id) % 8)
    }

    public func summary(active: Bool) -> SessionSummary {
        SessionSummary(id: id, title: title, cwd: cwd.path, entrypoint: entrypoint, status: status, level: level,
                       unread: unreadTurns.count, active: active, lastActivity: lastActivity, pid: pid)
    }
}
