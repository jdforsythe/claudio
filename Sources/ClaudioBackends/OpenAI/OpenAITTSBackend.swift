import ClaudioCore
import Foundation

/// `POST /v1/audio/speech` with streaming PCM (document 06 §4).
public final class OpenAITTSBackend: TTSBackend {
    public let id: BackendID = "openai"
    public let displayName = "OpenAI (API key)"
    public let supportsWordBoundaries = false
    public static let voiceNames = ["alloy", "ash", "ballad", "coral", "echo", "fable", "nova", "onyx", "sage", "shimmer", "verse"]

    private let session: URLSession
    private let endpoint: URL
    private let keychain: KeychainStore
    private let keyOverride: (@Sendable () -> String?)?
    private let model: @Sendable () -> String
    private let log = Log.openai

    public init(session: URLSession = URLSession(configuration: .ephemeral),
                endpoint: URL = URL(string: "https://api.openai.com/v1/audio/speech")!,  // swiftlint:disable:this force_unwrapping
                keychain: KeychainStore = KeychainStore(), keyOverride: (@Sendable () -> String?)? = nil,
                model: @escaping @Sendable () -> String = { "gpt-4o-mini-tts" }) {
        self.session = session
        self.endpoint = endpoint
        self.keychain = keychain
        self.keyOverride = keyOverride
        self.model = model
    }

    public func voices() async throws -> [Voice] {
        Self.voiceNames.map { Voice(backend: "openai", id: $0, displayName: $0.capitalized, locale: "en-US") }
    }

    public var isConfigured: Bool { (keyOverride?() ?? (try? keychain.get(.openAI))) != nil }

    public func synthesize(_ request: SynthesisRequest) -> AsyncThrowingStream<SynthesisEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<SynthesisEvent, any Error>.makeStream()
        guard request.voice.backend == id else {
            continuation.finish(throwing: BackendError.invalidVoice(request.voice.id))
            return stream
        }
        if request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            continuation.yield(.finished)
            continuation.finish()
            return stream
        }
        let task = Task { [self] in
            do {
                try await run(request, continuation: continuation)
            } catch is CancellationError {
                continuation.finish(throwing: CancellationError())
            } catch let e as BackendError {
                continuation.finish(throwing: e)
            } catch let e as URLError where e.code == .timedOut {
                continuation.finish(throwing: BackendError.timeout(stage: "connect"))
            } catch {
                continuation.finish(throwing: BackendError.network(error.localizedDescription))
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    public func makeRequest(_ request: SynthesisRequest, key: String) throws -> URLRequest {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model(), "voice": request.voice.id, "input": request.text, "response_format": "pcm",
            "speed": min(4.0, max(0.25, request.rate)),
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return req
    }

    private func run(_ request: SynthesisRequest, continuation: AsyncThrowingStream<SynthesisEvent, any Error>.Continuation) async throws {
        let resolvedKey = try keyOverride?() ?? keychain.get(.openAI)
        guard let key = resolvedKey, !key.isEmpty else {
            throw BackendError.auth("no API key")
        }
        let req = try makeRequest(request, key: key)
        let (bytes, response) = try await session.bytes(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var body = Data()
            for try await b in bytes { body.append(b); if body.count > 4096 { break } }
            let message = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String } ?? ""
            switch http.statusCode {
            case 401, 403: throw BackendError.auth("HTTP \(http.statusCode)")
            case 429: throw BackendError.rateLimited(retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init))
            case 400 where message.contains("voice"): throw BackendError.invalidVoice(request.voice.id)
            default: throw BackendError.network("HTTP \(http.statusCode): \(message)")
            }
        }
        var block = Data()
        var total = 0
        for try await byte in bytes {
            try Task.checkCancellation()
            block.append(byte)
            if block.count >= 9600 {
                continuation.yield(.audio(PCMBuffer(samples: PCMFormat.int16ToFloat(block))))
                total += block.count
                block.removeAll(keepingCapacity: true)
            }
        }
        if block.count >= 2 {
            if block.count % 2 == 1 { block.removeLast() }
            continuation.yield(.audio(PCMBuffer(samples: PCMFormat.int16ToFloat(block))))
            total += block.count
        }
        guard total >= 2 else { throw BackendError.decode("no audio") }
        continuation.yield(.finished)
        continuation.finish()
    }
}
