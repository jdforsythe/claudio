import ClaudioCore
import SwiftUI

@MainActor @Observable
final class SessionsViewModel {
    private(set) var sessions: [Session] = []
    private(set) var activeSessionID: SessionID?
    private let registry: SessionRegistry
    private let arbiter: Arbiter
    private var task: Task<Void, Never>?

    init(registry: SessionRegistry, arbiter: Arbiter) {
        self.registry = registry
        self.arbiter = arbiter
    }

    func start() {
        let changes = registry.changes()
        task = Task { [weak self] in
            for await snapshot in changes {
                guard let self else { return }
                self.sessions = snapshot.sessions
                self.activeSessionID = snapshot.activeSessionID
            }
        }
    }

    /// Document 07 §3.4.
    var sortedSessions: [Session] {
        sessions.sorted { a, b in
            if (a.id == activeSessionID) != (b.id == activeSessionID) { return a.id == activeSessionID }
            let ra = Self.rank(a.status)
            let rb = Self.rank(b.status)
            if ra != rb { return ra < rb }
            if a.lastActivity != b.lastActivity { return a.lastActivity > b.lastActivity }
            return a.title < b.title
        }
    }

    private static func rank(_ s: SessionStatus) -> Int {
        switch s {
        case .waiting: 0
        case .busy: 1
        case .idle: 2
        case .ended: 3
        }
    }

    var totalUnread: Int {
        sessions.filter { $0.id != activeSessionID }.reduce(0) { $0 + $1.unreadTurns.count }
    }

    var activeSession: Session? { sessions.first { $0.id == activeSessionID } }

    func activate(_ id: SessionID) {
        Task { await arbiter.activate(id) }
    }

    /// Cycle hotkey: popover order, wrapping, skipping ended sessions unless they are the only ones.
    func activateNext() {
        let ordered = sortedSessions
        guard !ordered.isEmpty else { return }
        let live = ordered.filter(\.isLive)
        let pool = live.isEmpty ? ordered : live
        guard let active = activeSessionID, let idx = pool.firstIndex(where: { $0.id == active }) else {
            activate(pool[0].id)
            return
        }
        activate(pool[(idx + 1) % pool.count].id)
    }

    func setLevel(_ level: SpeechLevel, for id: SessionID) {
        if let idx = sessions.firstIndex(where: { $0.id == id }) { sessions[idx].level = level }
        Task { await registry.setLevel(level, for: id) }
    }

    func cycleLevelOfActive() {
        Task { _ = await arbiter.cycleLevelOfActive() }
    }

    func binding(forLevelOf id: SessionID) -> Binding<SpeechLevel> {
        Binding(get: { self.sessions.first { $0.id == id }?.level ?? .answers },
                set: { self.setLevel($0, for: id) })
    }
}
