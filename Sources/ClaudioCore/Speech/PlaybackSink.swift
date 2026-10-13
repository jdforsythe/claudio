import Foundation
import Synchronization

public enum PlaybackEvent: Sendable, Equatable {
    case segmentStarted(UUID, at: Date)
    case segmentFinished(UUID, at: Date)
    case position(UUID, TimeInterval)
    case paused
    case resumed
    case drained
    case deviceChanged
}

/// Audio output abstraction (document 05 §7.1). Production: `PlaybackEngine`; tests: `RecordingPlaybackSink`.
public protocol PlaybackSink: AnyObject, Sendable {
    func enqueue(_ buffer: PCMBuffer, segmentID: UUID) async
    func markSegmentEnd(_ segmentID: UUID) async
    func pause() async
    func resume() async
    func cancelAll(fade: TimeInterval) async
    func skipSegment(_ segmentID: UUID, fade: TimeInterval) async
    func events() -> AsyncStream<PlaybackEvent>
}

/// Test sink: records every call with the clock time and simulates instantaneous playback (document 05 §7.7).
public final class RecordingPlaybackSink: PlaybackSink {
    public enum Call: Sendable, Equatable {
        case enqueue(segmentID: UUID, frames: Int, at: Date)
        case markEnd(segmentID: UUID, at: Date)
        case pause(at: Date)
        case resume(at: Date)
        case cancelAll(fade: TimeInterval, at: Date)
        case skip(segmentID: UUID, fade: TimeInterval, at: Date)
    }

    private struct State {
        var calls: [Call] = []
        var frames: [UUID: Int] = [:]
        var order: [UUID] = []
        var ended: Set<UUID> = []
        var started: Set<UUID> = []
        var finished: [UUID] = []
        var playing: UUID?
        var paused = false
        var pendingQueue: [UUID] = []
    }

    private let state = Mutex(State())
    private let broadcast = Broadcast<PlaybackEvent>()
    public let clock: any ClaudioClock
    /// When true, segments "finish" as soon as their end is marked (instant playback).
    public let autoPlay: Bool
    /// Simulated seconds per frame of audio; 0 keeps playback instantaneous.
    public let realtimeFactor: Double

    public init(clock: any ClaudioClock = SystemClock(), autoPlay: Bool = true, realtimeFactor: Double = 0) {
        self.clock = clock
        self.autoPlay = autoPlay
        self.realtimeFactor = realtimeFactor
    }

    public var calls: [Call] { state.withLock { $0.calls } }
    public var playbackOrder: [UUID] { state.withLock { $0.order } }
    public var finishedOrder: [UUID] { state.withLock { $0.finished } }
    public func totalFrames(for segmentID: UUID) -> Int { state.withLock { $0.frames[segmentID] ?? 0 } }
    public var cancelCount: Int { calls.filter { if case .cancelAll = $0 { true } else { false } }.count }
    public var cancelTimes: [Date] { calls.compactMap { if case .cancelAll(_, let at) = $0 { at } else { nil } } }

    public func events() -> AsyncStream<PlaybackEvent> { broadcast.subscribe() }

    public func enqueue(_ buffer: PCMBuffer, segmentID: UUID) async {
        let now = clock.now
        let startEvent: PlaybackEvent? = state.withLock { s in
            s.calls.append(.enqueue(segmentID: segmentID, frames: buffer.frameCount, at: now))
            s.frames[segmentID, default: 0] += buffer.frameCount
            if !s.order.contains(segmentID) { s.order.append(segmentID) }
            if s.playing == nil, !s.paused, autoPlay {
                s.playing = segmentID
                s.started.insert(segmentID)
                return .segmentStarted(segmentID, at: now)
            }
            if s.playing != segmentID, !s.pendingQueue.contains(segmentID) { s.pendingQueue.append(segmentID) }
            return nil
        }
        if let e = startEvent { broadcast.send(e) }
    }

    public func markSegmentEnd(_ segmentID: UUID) async {
        let now = clock.now
        state.withLock { s in
            s.calls.append(.markEnd(segmentID: segmentID, at: now))
            s.ended.insert(segmentID)
        }
        if autoPlay { await drive() }
    }

    /// Finishes the playing segment if its end is marked, then starts the next; repeats while possible.
    public func drive() async {
        while true {
            let now = clock.now
            let events: [PlaybackEvent] = state.withLock { s in
                guard !s.paused, let current = s.playing, s.ended.contains(current) else { return [] }
                var out: [PlaybackEvent] = []
                s.finished.append(current)
                out.append(.segmentFinished(current, at: now))
                s.playing = nil
                if !s.pendingQueue.isEmpty {
                    let next = s.pendingQueue.removeFirst()
                    s.playing = next
                    s.started.insert(next)
                    out.append(.segmentStarted(next, at: now))
                } else {
                    out.append(.drained)
                }
                return out
            }
            guard !events.isEmpty else { return }
            for e in events { broadcast.send(e) }
            if realtimeFactor > 0, let frames = events.compactMap({ if case .segmentStarted(let id, _) = $0 { state.withLock { $0.frames[id] } } else { nil } }).first {
                try? await clock.sleep(for: Double(frames) / PCMBuffer.sampleRate * realtimeFactor)
            }
            // Loop again in case the next segment has already ended.
            let again: Bool = state.withLock { s in
                guard let p = s.playing else { return false }
                return s.ended.contains(p)
            }
            if !again { return }
        }
    }

    public func pause() async {
        let now = clock.now
        state.withLock { s in
            s.calls.append(.pause(at: now))
            s.paused = true
        }
        broadcast.send(.paused)
    }

    public func resume() async {
        let now = clock.now
        state.withLock { s in
            s.calls.append(.resume(at: now))
            s.paused = false
        }
        broadcast.send(.resumed)
        await drive()
    }

    public func cancelAll(fade: TimeInterval) async {
        let now = clock.now
        state.withLock { s in
            s.calls.append(.cancelAll(fade: fade, at: now))
            s.playing = nil
            s.pendingQueue.removeAll()
        }
        broadcast.send(.drained)
    }

    public func skipSegment(_ segmentID: UUID, fade: TimeInterval) async {
        let now = clock.now
        state.withLock { s in
            s.calls.append(.skip(segmentID: segmentID, fade: fade, at: now))
            s.playing = nil
            s.pendingQueue.removeAll()
        }
        broadcast.send(.drained)
    }
}
