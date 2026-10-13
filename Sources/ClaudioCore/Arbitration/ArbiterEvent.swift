import Foundation

public enum ArbiterMode: Sendable, Equatable {
    case idle
    case catchingUp(SessionID)
    case live(SessionID)
    case paused

    public var sessionID: SessionID? {
        switch self {
        case .catchingUp(let id), .live(let id): id
        default: nil
        }
    }

    public var label: String {
        switch self {
        case .idle: "idle"
        case .catchingUp: "catchingUp"
        case .live: "live"
        case .paused: "paused"
        }
    }
}

public struct ArbiterState: Sendable, Equatable {
    public var mode: ArbiterMode = .idle
    public var activeSessionID: SessionID?
    public var catchUpProgress: CatchUpProgress?
    public var eventsMuted = false

    public struct CatchUpProgress: Sendable, Equatable {
        public var index: Int
        public var total: Int
    }

    public init() {}
}

public enum ArbiterEvent: Sendable, Equatable {
    case prompt(sessionID: SessionID, title: String, verb: String)
    case notice(String)
    case activated(SessionID, reason: String)
}
