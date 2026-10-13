import Foundation

public typealias SessionID = String  // Claude's sessionId
public typealias TurnID = String  // Claude's promptId

/// One unit of speakable content (document 02 §4).
public struct SpeechItem: Identifiable, Sendable, Equatable, Codable {
    public let id: UUID
    public let sessionID: SessionID
    public let turnID: TurnID?
    public let category: ContentCategory
    public let text: String
    public let sourceUUID: String?
    public let timestamp: Date
    public let isCatchUp: Bool

    public init(id: UUID = UUID(), sessionID: SessionID, turnID: TurnID?, category: ContentCategory, text: String,
                sourceUUID: String? = nil, timestamp: Date, isCatchUp: Bool = false) {
        self.id = id
        self.sessionID = sessionID
        self.turnID = turnID
        self.category = category
        self.text = text
        self.sourceUUID = sourceUUID
        self.timestamp = timestamp
        self.isCatchUp = isCatchUp
    }

    public func withCatchUp(_ flag: Bool) -> SpeechItem {
        SpeechItem(id: id, sessionID: sessionID, turnID: turnID, category: category, text: text,
                   sourceUUID: sourceUUID, timestamp: timestamp, isCatchUp: flag)
    }
}
