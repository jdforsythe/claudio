import Foundation
import Synchronization

/// Deterministic backend for tests and `claudio bench`: emits one buffer per request after an optional delay.
public final class MockBackend: TTSBackend {
    public enum Behaviour: Sendable {
        case succeed
        case fail(BackendError)
        case failAfterAudio(BackendError)
        case hang
    }

    private struct State {
        var calls: [SynthesisRequest] = []
        var concurrent = 0
        var maxConcurrent = 0
        var cancelled = 0
        var behaviour: Behaviour = .succeed
        var perRequest: [Int: Behaviour] = [:]
    }

    public let id: BackendID
    public let displayName: String
    public let supportsWordBoundaries: Bool
    public let secondsPerCharacter: Double
    public let delay: TimeInterval
    public let clock: any ClaudioClock
    private let state = Mutex(State())

    public init(id: BackendID = "mock", delay: TimeInterval = 0, secondsPerCharacter: Double = 0.05,
                supportsWordBoundaries: Bool = true, clock: any ClaudioClock = SystemClock()) {
        self.id = id
        self.displayName = "Mock (\(id))"
        self.supportsWordBoundaries = supportsWordBoundaries
        self.delay = delay
        self.secondsPerCharacter = secondsPerCharacter
        self.clock = clock
    }

    public var calls: [SynthesisRequest] { state.withLock { $0.calls } }
    public var maxConcurrent: Int { state.withLock { $0.maxConcurrent } }
    public var cancelledCount: Int { state.withLock { $0.cancelled } }

    public func setBehaviour(_ b: Behaviour) { state.withLock { $0.behaviour = b } }
    public func setBehaviour(_ b: Behaviour, forCall index: Int) { state.withLock { $0.perRequest[index] = b } }

    public func voices() async throws -> [Voice] {
        [Voice(backend: id, id: "mock-voice", displayName: "Mock Voice", locale: "en-US", gender: "Male")]
    }

    public static func voice(for backend: BackendID = "mock") -> Voice {
        Voice(backend: backend, id: "mock-voice", displayName: "Mock Voice", locale: "en-US", gender: "Male")
    }

    public func synthesize(_ request: SynthesisRequest) -> AsyncThrowingStream<SynthesisEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<SynthesisEvent, any Error>.makeStream()
        let behaviour: Behaviour = state.withLock { s in
            let index = s.calls.count
            s.calls.append(request)
            s.concurrent += 1
            s.maxConcurrent = max(s.maxConcurrent, s.concurrent)
            return s.perRequest[index] ?? s.behaviour
        }
        let task = Task { [self, clock, delay, secondsPerCharacter] in
            defer { self.state.withLock { $0.concurrent -= 1 } }
            do {
                if delay > 0 { try await clock.sleep(for: delay) }
                try Task.checkCancellation()
                switch behaviour {
                case .fail(let e):
                    continuation.finish(throwing: e)
                    return
                case .hang:
                    try await clock.sleep(for: 3600)
                    continuation.finish(throwing: BackendError.timeout(stage: "firstAudio"))
                    return
                case .succeed, .failAfterAudio:
                    break
                }
                let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    continuation.yield(.finished)
                    continuation.finish()
                    return
                }
                let seconds = max(0.2, Double(text.count) * secondsPerCharacter / request.rate)
                let frames = Int(seconds * PCMBuffer.sampleRate)
                // Word boundaries proportional to character counts.
                let words = Self.wordRanges(in: text)
                let totalChars = max(1, words.reduce(0) { $0 + text.distance(from: $1.lowerBound, to: $1.upperBound) + 1 })
                var offset = 0.0
                for r in words {
                    let d = seconds * Double(text.distance(from: r.lowerBound, to: r.upperBound) + 1) / Double(totalChars)
                    continuation.yield(.wordBoundary(textRange: r, audioOffset: offset, duration: d))
                    offset += d
                }
                let chunk = 4800
                var produced = 0
                while produced < frames {
                    try Task.checkCancellation()
                    let n = min(chunk, frames - produced)
                    var samples = [Float](repeating: 0, count: n)
                    for i in 0..<n { samples[i] = sinf(Float(produced + i) * 2 * .pi * 440 / 24_000) * 0.3 }
                    continuation.yield(.audio(PCMBuffer(samples: samples)))
                    produced += n
                    if case .failAfterAudio(let e) = behaviour {
                        continuation.finish(throwing: e)
                        return
                    }
                }
                continuation.yield(.finished)
                continuation.finish()
            } catch is CancellationError {
                self.state.withLock { $0.cancelled += 1 }
                continuation.finish(throwing: CancellationError())
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    public static func wordRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        var i = text.startIndex
        while i < text.endIndex {
            if text[i].isWhitespace {
                if let s = start {
                    ranges.append(s..<i)
                    start = nil
                }
            } else if start == nil {
                start = i
            }
            i = text.index(after: i)
        }
        if let s = start { ranges.append(s..<text.endIndex) }
        return ranges
    }
}
