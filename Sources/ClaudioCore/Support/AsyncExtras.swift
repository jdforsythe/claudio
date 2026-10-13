import Foundation
import Synchronization

/// Fan-out broadcaster: each `subscribe()` returns an independent `AsyncStream`.
public final class Broadcast<Element: Sendable>: Sendable {
    private struct State {
        var continuations: [Int: AsyncStream<Element>.Continuation] = [:]
        var nextID = 0
        var latest: Element?
    }

    private let state = Mutex(State())
    private let replayLatest: Bool
    private let policy: AsyncStream<Element>.Continuation.BufferingPolicy

    public init(replayLatest: Bool = false,
                bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy = .unbounded) {
        self.replayLatest = replayLatest
        self.policy = bufferingPolicy
    }

    public func subscribe() -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream<Element>.makeStream(bufferingPolicy: policy)
        let id: Int = state.withLock { s in
            s.nextID += 1
            s.continuations[s.nextID] = continuation
            if replayLatest, let latest = s.latest { continuation.yield(latest) }
            return s.nextID
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.continuations.removeValue(forKey: id) }
        }
        return stream
    }

    public func send(_ element: Element) {
        let targets: [AsyncStream<Element>.Continuation] = state.withLock { s in
            if replayLatest { s.latest = element }
            return Array(s.continuations.values)
        }
        for c in targets { c.yield(element) }
    }

    public func finish() {
        let targets: [AsyncStream<Element>.Continuation] = state.withLock { s in
            let all = Array(s.continuations.values)
            s.continuations.removeAll()
            return all
        }
        for c in targets { c.finish() }
    }

    public var subscriberCount: Int { state.withLock { $0.continuations.count } }
}

/// A box that lets non-Sendable-but-safe values cross isolation boundaries explicitly.
public struct UncheckedSendable<T>: @unchecked Sendable {
    public let value: T
    public init(_ value: T) { self.value = value }
}

extension String {
    /// Collapses whitespace and lowercases, for text comparisons that must survive rendering differences.
    public var whitespaceNormalized: String {
        split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public func truncated(to limit: Int, suffix: String = "…") -> String {
        guard count > limit else { return self }
        return String(prefix(limit)) + suffix
    }

    public var abbreviatingHome: String {
        let home = NSHomeDirectory()
        if hasPrefix(home) { return "~" + dropFirst(home.count) }
        return self
    }
}

/// FNV-1a 64-bit hash over UTF-8 bytes (stable across launches, unlike `Hasher`).
public func fnv1a64(_ string: String) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for b in string.utf8 {
        hash ^= UInt64(b)
        hash = hash &* 0x0000_0100_0000_01b3
    }
    return hash
}

/// A plain-text error for diagnostic results that only need a message.
public struct MessageError: Error, Sendable, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}
