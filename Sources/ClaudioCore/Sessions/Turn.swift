import Foundation

/// In-memory record of one turn, kept for catch-up (document 03 §8.8).
public struct Turn: Sendable, Equatable, Identifiable {
    public var id: TurnID
    public var startedAt: Date
    public var endedAt: Date?
    public var promptText: String
    public var finalAnswerTexts: [String]
    public var reason: TurnEndReason?

    public init(id: TurnID, startedAt: Date, promptText: String = "") {
        self.id = id
        self.startedAt = startedAt
        self.promptText = promptText
        self.finalAnswerTexts = []
    }

    public var finalAnswerText: String { finalAnswerTexts.joined(separator: "\n\n") }
}

public enum TurnEndReason: String, Sendable, Codable {
    case completed
    case interruptedByPrompt
    case hookStop
    case hookStopFailure
    case sessionEnded
}
