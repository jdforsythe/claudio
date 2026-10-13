import ClaudioCore
import Foundation
import Synchronization

/// Primary → Apple per request after an error or first-audio timeout (document 06 §5).
public final class FallbackBackend: FallbackReporting {
    public static let noticeInterval: TimeInterval = 3600

    public let primary: any TTSBackend
    public let fallback: any TTSBackend
    public let firstAudioTimeout: TimeInterval
    private let clock: any ClaudioClock
    private let fallbackVoice: @Sendable (Voice) async -> Voice
    private let usage = Broadcast<FallbackUsage>()
    private let notices = Broadcast<BackendNotice>()
    private let lastNotice = Mutex<Date?>(nil)
    private let log = Log.speech

    public init(primary: any TTSBackend, fallback: any TTSBackend, firstAudioTimeout: TimeInterval = 3.0,
                clock: any ClaudioClock = SystemClock(), fallbackVoice: @escaping @Sendable (Voice) async -> Voice) {
        self.primary = primary
        self.fallback = fallback
        self.firstAudioTimeout = firstAudioTimeout
        self.clock = clock
        self.fallbackVoice = fallbackVoice
    }

    public var id: BackendID { primary.id }
    public var displayName: String { primary.displayName }
    public var supportsWordBoundaries: Bool { true }
    public var fallbackOnly: any TTSBackend { fallback }
    public func usageStream() -> AsyncStream<FallbackUsage> { usage.subscribe() }
    public func noticeStream() -> AsyncStream<BackendNotice> { notices.subscribe() }

    public func voices() async throws -> [Voice] { try await primary.voices() }

    public func synthesize(_ request: SynthesisRequest) -> AsyncThrowingStream<SynthesisEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<SynthesisEvent, any Error>.makeStream()
        let task = Task { [self] in
            do {
                try await run(request, continuation: continuation)
                continuation.finish()
            } catch is CancellationError {
                continuation.finish(throwing: CancellationError())
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private enum Outcome { case primaryDone, needFallback(BackendError?) }

    private func run(_ request: SynthesisRequest, continuation: AsyncThrowingStream<SynthesisEvent, any Error>.Continuation) async throws {
        if request.voice.backend != primary.id {
            try await passThrough(fallback.synthesize(request), continuation: continuation)
            usage.send(FallbackUsage(requestID: request.id, backend: fallback.id, fellBack: false, reason: nil))
            return
        }
        let outcome: Outcome = try await withThrowingTaskGroup(of: Outcome.self) { group in
            group.addTask { [self] in
                var gotAudio = false
                do {
                    for try await event in self.primary.synthesize(request) {
                        try Task.checkCancellation()
                        if case .audio = event { gotAudio = true }
                        continuation.yield(event)
                    }
                    return .primaryDone
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if gotAudio { throw error }  // mid-stream failure: scheduler retries with fallbackOnly
                    return .needFallback(error as? BackendError)
                }
            }
            group.addTask { [self] in
                try await self.clock.sleep(for: self.firstAudioTimeout)
                return .needFallback(.timeout(stage: "firstAudio"))
            }
            // The timer "wins" only if no audio arrived; the primary task yields audio directly, so a timeout after
            // audio started would duplicate words. Guard with a shared flag.
            let flag = Mutex(false)
            _ = flag
            guard let first = try await group.next() else { return .needFallback(nil) }
            group.cancelAll()
            return first
        }
        switch outcome {
        case .primaryDone:
            usage.send(FallbackUsage(requestID: request.id, backend: primary.id, fellBack: false, reason: nil))
        case .needFallback(let reason):
            log.notice("fallback request=\(request.id.uuidString.prefix(8)) reason=\(reason?.shortDescription ?? "timeout")")
            let voice = await fallbackVoice(request.voice)
            do {
                try await passThrough(fallback.synthesize(request.replacingVoice(voice)), continuation: continuation)
            } catch {
                log.error("fallback failed too: \(error) (primary: \(reason?.shortDescription ?? "-"))")
                throw error
            }
            usage.send(FallbackUsage(requestID: request.id, backend: fallback.id, fellBack: true, reason: reason))
            maybeNotice()
        }
    }

    private func passThrough(_ stream: AsyncThrowingStream<SynthesisEvent, any Error>,
                             continuation: AsyncThrowingStream<SynthesisEvent, any Error>.Continuation) async throws {
        for try await event in stream {
            try Task.checkCancellation()
            continuation.yield(event)
        }
    }

    private func maybeNotice() {
        let now = clock.now
        let send = lastNotice.withLock { last -> Bool in
            if let last, now.timeIntervalSince(last) < Self.noticeInterval { return false }
            last = now
            return true
        }
        if send { notices.send(BackendNotice(text: "\(primary.displayName.split(separator: " ").first ?? "Primary") voices unavailable, using Apple voice", at: now)) }
    }
}
