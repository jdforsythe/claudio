import Foundation
import Synchronization

/// Injectable time source. Named `ClaudioClock` to avoid clashing with `Swift.Clock`.
public protocol ClaudioClock: Sendable {
    var now: Date { get }
    /// Suspends for the given interval; `ManualClock` resolves these when advanced.
    func sleep(for seconds: TimeInterval) async throws
}

public struct SystemClock: ClaudioClock {
    public init() {}
    public var now: Date { Date() }
    public func sleep(for seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

/// Deterministic clock for tests. Sleeps complete when `advance(by:)` passes their deadline.
public final class ManualClock: ClaudioClock {
    private struct Waiter {
        let id: Int
        let deadline: Date
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now: Date
        var waiters: [Waiter] = []
        var nextID = 0
        var cancelled = Set<Int>()
    }

    private let state: Mutex<State>

    public init(now: Date = Date(timeIntervalSince1970: 1_790_000_000)) {
        state = Mutex(State(now: now))
    }

    public var now: Date { state.withLock { $0.now } }

    public func sleep(for seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        let deadline = now.addingTimeInterval(seconds)
        let id: Int = state.withLock { s in
            s.nextID += 1
            return s.nextID
        }
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let cancelled: Bool = state.withLock { s in
                    if s.cancelled.remove(id) != nil { return true }
                    s.waiters.append(Waiter(id: id, deadline: deadline, continuation: continuation))
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let waiter: Waiter? = state.withLock { s in
                if let idx = s.waiters.firstIndex(where: { $0.id == id }) { return s.waiters.remove(at: idx) }
                s.cancelled.insert(id)
                return nil
            }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Advances time and resumes every sleeper whose deadline has passed, in deadline order.
    public func advance(by seconds: TimeInterval) {
        let target = now.addingTimeInterval(seconds)
        set(target)
    }

    public func set(_ date: Date) {
        while true {
            let due: [Waiter] = state.withLock { s in
                let dueNow = s.waiters.filter { $0.deadline <= date }.sorted { $0.deadline < $1.deadline }
                if let first = dueNow.first {
                    s.now = max(s.now, first.deadline)
                    s.waiters.removeAll { $0.id == first.id }
                    return [first]
                }
                s.now = date
                return []
            }
            guard let w = due.first else { return }
            w.continuation.resume()
            // Give the resumed task a chance to run before resuming the next waiter.
            Thread.sleep(forTimeInterval: 0.0005)
        }
    }

    /// Number of pending sleepers; useful in tests to wait for a component to park.
    public var pendingSleepers: Int { state.withLock { $0.waiters.count } }
}
