import Foundation

/// The digest to play when switching to a session with unread turns (document 01 §8).
public struct CatchUpPlan: Sendable, Equatable {
    public static let maxTurns = 5

    public let sessionID: SessionID
    public let turns: [UnreadTurn]
    public let droppedCount: Int

    public init(session: Session) {
        sessionID = session.id
        let all = session.unreadTurns.sorted { $0.endedAt < $1.endedAt }
        let kept = Array(all.suffix(Self.maxTurns))
        turns = kept
        droppedCount = all.count - kept.count
    }

    public var isEmpty: Bool { turns.isEmpty }

    public func items(at now: Date) -> [SpeechItem] {
        turns.map { t in
            SpeechItem(sessionID: sessionID, turnID: t.turnID, category: .finalAnswer, text: t.finalAnswerText,
                       sourceUUID: "catchup:\(t.turnID)", timestamp: now, isCatchUp: true)
        }
    }
}
