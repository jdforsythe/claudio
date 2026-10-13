import Foundation

public struct SynthesisRequest: Sendable {
    public let id: UUID
    public let text: String
    public let voice: Voice
    public let rate: Double
    public let wantsWordBoundaries: Bool

    public init(id: UUID = UUID(), text: String, voice: Voice, rate: Double, wantsWordBoundaries: Bool = true) {
        self.id = id
        self.text = text
        self.voice = voice
        self.rate = rate
        self.wantsWordBoundaries = wantsWordBoundaries
    }

    public func replacingVoice(_ voice: Voice) -> SynthesisRequest {
        SynthesisRequest(id: id, text: text, voice: voice, rate: rate, wantsWordBoundaries: wantsWordBoundaries)
    }
}

public enum SynthesisEvent: Sendable {
    case audio(PCMBuffer)
    case wordBoundary(textRange: Range<String.Index>, audioOffset: TimeInterval, duration: TimeInterval)
    case finished
}

/// Contract in document 06 §1.
public protocol TTSBackend: Sendable {
    var id: BackendID { get }
    var displayName: String { get }
    var supportsWordBoundaries: Bool { get }
    func voices() async throws -> [Voice]
    func synthesize(_ request: SynthesisRequest) -> AsyncThrowingStream<SynthesisEvent, any Error>
}

/// Optional lifecycle for backends that need warm-up or a sidecar process.
public protocol BackendLifecycle: Sendable {
    func start() async
    func stop() async
    func health() async -> Bool
}

/// Reports which backend actually spoke a request (document 06 §5).
public struct FallbackUsage: Sendable, Equatable {
    public let requestID: UUID
    public let backend: BackendID
    public let fellBack: Bool
    public let reason: BackendError?

    public init(requestID: UUID, backend: BackendID, fellBack: Bool, reason: BackendError?) {
        self.requestID = requestID
        self.backend = backend
        self.fellBack = fellBack
        self.reason = reason
    }
}

public struct BackendNotice: Sendable, Equatable {
    public let text: String
    public let at: Date
    public init(text: String, at: Date) {
        self.text = text
        self.at = at
    }
}

/// Backends that can report fallback usage (implemented by `FallbackBackend`).
public protocol FallbackReporting: TTSBackend {
    func usageStream() -> AsyncStream<FallbackUsage>
    func noticeStream() -> AsyncStream<BackendNotice>
    var fallbackOnly: any TTSBackend { get }
}
