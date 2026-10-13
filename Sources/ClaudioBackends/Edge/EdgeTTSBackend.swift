import ClaudioCore
import Foundation
import Synchronization

/// Native port of edge-tts (document 06 §2).
public final class EdgeTTSBackend: TTSBackend, BackendLifecycle {
    public let id: BackendID = "edge"
    public let displayName = "Edge (Microsoft, online)"
    public let supportsWordBoundaries = true

    public static let connectTimeout: TimeInterval = 5
    public static let firstAudioTimeout: TimeInterval = 3
    public static let idleTimeout: TimeInterval = 10

    private let session: URLSession
    private let baseURL: URL?
    private let voiceListURL: URL?
    private let clock: any ClaudioClock
    private let log = Log.edge
    private let cachedVoices = Mutex<[Voice]?>(nil)
    private let lastActivity = Mutex<Date>(.distantPast)

    /// `baseURL` overrides the production WebSocket URL (tests use a local mock server).
    public init(session: URLSession = EdgeTTSBackend.makeSession(), baseURL: URL? = nil, voiceListURL: URL? = nil,
                clock: any ClaudioClock = SystemClock()) {
        self.session = session
        self.baseURL = baseURL
        self.voiceListURL = voiceListURL
        self.clock = clock
    }

    public static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }

    // MARK: Voices

    public func voices() async throws -> [Voice] {
        if let cached = cachedVoices.withLock({ $0 }) { return cached }
        let url = voiceListURL ?? URL(string: EdgeConstants.voiceListURL)!  // swiftlint:disable:this force_unwrapping
        var request = URLRequest(url: url)
        for (k, v) in EdgeConstants.voiceListHeaders { request.setValue(v, forHTTPHeaderField: k) }
        request.setValue(EdgeDRM.secMSGEC(), forHTTPHeaderField: "Sec-MS-GEC")
        request.setValue(EdgeConstants.secMSGECVersion, forHTTPHeaderField: "Sec-MS-GEC-Version")
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw BackendError.network(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            if http.statusCode == 401 || http.statusCode == 403 { throw BackendError.auth("HTTP \(http.statusCode)") }
            throw BackendError.network("HTTP \(http.statusCode)")
        }
        let list = try EdgeVoiceList.parse(data)
        cachedVoices.withLock { $0 = list }
        return list
    }

    // MARK: Lifecycle

    public func start() async { await warmUp() }
    public func stop() async {}
    public func health() async -> Bool { (try? await voices()) != nil }

    /// Opens a connection, sends `speech.config`, and closes, priming DNS and TLS (document 06 §2.5).
    public func warmUp() async {
        let task = makeTask(now: clock.now)
        task.resume()
        do {
            try await task.send(.string(EdgeProtocol.speechConfigFrame(wordBoundaries: true, now: clock.now)))
        } catch {
            log.notice("warmup failed: \(error.localizedDescription)")
        }
        task.cancel(with: .goingAway, reason: nil)
    }

    private func makeTask(now: Date) -> URLSessionWebSocketTask {
        let url = baseURL.map { base in
            // swiftlint:disable:next force_unwrapping
            URL(string: base.absoluteString + (base.query == nil ? "?" : "&") + "TrustedClientToken=\(EdgeConstants.trustedClientToken)&ConnectionId=\(EdgeDRM.connectionID())&Sec-MS-GEC=\(EdgeDRM.secMSGEC(now: now))&Sec-MS-GEC-Version=\(EdgeConstants.secMSGECVersion)")!
        } ?? EdgeDRM.webSocketURL(now: now)
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.connectTimeout
        for (k, v) in EdgeConstants.webSocketHeaders(muid: EdgeDRM.muid()) { request.setValue(v, forHTTPHeaderField: k) }
        return session.webSocketTask(with: request)
    }

    // MARK: Synthesis

    public func synthesize(_ request: SynthesisRequest) -> AsyncThrowingStream<SynthesisEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<SynthesisEvent, any Error>.makeStream()
        guard request.voice.backend == id else {
            continuation.finish(throwing: BackendError.invalidVoice(request.voice.id))
            return stream
        }
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            continuation.yield(.finished)
            continuation.finish()
            return stream
        }
        let task = Task { [self] in
            do {
                try await self.run(request: request, text: text, continuation: continuation, retry: true)
            } catch is CancellationError {
                continuation.finish(throwing: CancellationError())
            } catch let e as BackendError {
                continuation.finish(throwing: e)
            } catch {
                continuation.finish(throwing: BackendError.network(error.localizedDescription))
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func run(request: SynthesisRequest, text: String, continuation: AsyncThrowingStream<SynthesisEvent, any Error>.Continuation,
                     retry: Bool) async throws {
        let ssml = EdgeProtocol.ssml(text: text, voice: request.voice.id, rate: request.rate, lang: request.voice.locale)
        let ssmlFrame = try EdgeProtocol.ssmlFrame(requestID: EdgeProtocol.requestID(), ssml: ssml, now: clock.now)
        let ws = makeTask(now: clock.now)
        ws.resume()
        let decoder = MP3StreamDecoder()
        decoder.onPCM = { continuation.yield(.audio($0)) }
        var locator = EdgeProtocol.WordLocator(text: text)
        let watchdog = Watchdog(clock: clock)
        defer {
            ws.cancel(with: .goingAway, reason: nil)
            watchdog.cancel()
        }
        do {
            try await ws.send(.string(EdgeProtocol.speechConfigFrame(wordBoundaries: request.wantsWordBoundaries, now: clock.now)))
            try await ws.send(.string(ssmlFrame))
        } catch {
            let status = (ws.response as? HTTPURLResponse)?.statusCode
            if status == 403, retry, let dateHeader = (ws.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Date"),
               let serverDate = EdgeDRM.parseHTTPDate(dateHeader) {
                EdgeDRM.clockSkewSeconds = serverDate.timeIntervalSince(clock.now)
                log.notice("403; skew adjusted by \(Int(EdgeDRM.clockSkewSeconds)) s, retrying once")
                try await run(request: request, text: text, continuation: continuation, retry: false)
                return
            }
            throw mapHandshake(error: error, status: status, response: ws.response as? HTTPURLResponse)
        }
        lastActivity.withLock { $0 = clock.now }
        var gotAudio = false
        watchdog.arm(seconds: Self.firstAudioTimeout, stage: "firstAudio") { ws.cancel(with: .goingAway, reason: nil) }
        while true {
            try Task.checkCancellation()
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await ws.receive()
            } catch {
                if let timeout = watchdog.firedStage { throw BackendError.timeout(stage: timeout) }
                if Task.isCancelled { throw CancellationError() }
                let status = (ws.response as? HTTPURLResponse)?.statusCode
                if let status, status != 101 { throw mapHandshake(error: error, status: status, response: ws.response as? HTTPURLResponse) }
                if ws.closeCode != .invalid, ws.closeCode != .normalClosure { throw BackendError.network("ws close \(ws.closeCode.rawValue)") }
                throw BackendError.network(error.localizedDescription)
            }
            switch message {
            case .string(let s):
                let frame = EdgeProtocol.parseTextFrame(s)
                switch frame.path {
                case "turn.start", "response":
                    break
                case "audio.metadata":
                    for b in EdgeProtocol.parseMetadata(frame.body) where b.type == "WordBoundary" || b.type == "SentenceBoundary" {
                        let range = locator.locate(b.text)
                        continuation.yield(.wordBoundary(textRange: range, audioOffset: b.offsetSeconds, duration: b.durationSeconds))
                    }
                case "turn.end":
                    try decoder.flush()
                    guard decoder.framesProduced > 0 else { throw BackendError.decode("no audio received") }
                    continuation.yield(.finished)
                    continuation.finish()
                    return
                default:
                    throw BackendError.decode("unknown path \(frame.path ?? "nil")")
                }
            case .data(let data):
                let frame = try EdgeProtocol.parseBinaryFrame(data)
                guard frame.path == "audio" else { throw BackendError.decode("binary frame with path \(frame.path ?? "nil")") }
                if frame.contentType == "audio/mpeg", !frame.payload.isEmpty {
                    if !gotAudio {
                        gotAudio = true
                        watchdog.cancel()
                    }
                    try decoder.feed(frame.payload)
                } else if frame.contentType == nil, !frame.payload.isEmpty {
                    throw BackendError.decode("audio without content type")
                }
            @unknown default:
                break
            }
            watchdog.arm(seconds: Self.idleTimeout, stage: "idle") { ws.cancel(with: .goingAway, reason: nil) }
        }
    }

    private func mapHandshake(error: any Error, status: Int?, response: HTTPURLResponse?) -> BackendError {
        switch status {
        case 403, 401: return .auth("Sec-MS-GEC rejected")
        case 429:
            let retry = response?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            return .rateLimited(retryAfter: retry)
        case .some(let code) where code != 101: return .network("HTTP \(code)")
        default:
            if let urlError = error as? URLError, urlError.code == .timedOut { return .timeout(stage: "connect") }
            return .network(error.localizedDescription)
        }
    }

    /// Single-shot timer used for first-audio and idle deadlines.
    private final class Watchdog: Sendable {
        private let clock: any ClaudioClock
        private let state = Mutex<(task: Task<Void, Never>?, fired: String?)>((nil, nil))

        init(clock: any ClaudioClock) { self.clock = clock }

        func arm(seconds: TimeInterval, stage: String, action: @escaping @Sendable () -> Void) {
            cancel()
            let task = Task { [self] in
                try? await self.clock.sleep(for: seconds)
                guard !Task.isCancelled else { return }
                self.state.withLock { $0.fired = stage }
                action()
            }
            state.withLock { $0.task = task }
        }

        func cancel() {
            state.withLock { $0.task?.cancel(); $0.task = nil }
        }

        var firedStage: String? { state.withLock { $0.fired } }
    }
}
