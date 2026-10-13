@preconcurrency import AVFoundation
import ClaudioCore
import Foundation
import Synchronization

/// `AVSpeechSynthesizer` in write-to-buffer mode (document 06 §3). Always available, offline.
public final class AppleSpeechBackend: NSObject, TTSBackend, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    public let id: BackendID = "apple"
    public let displayName = "Apple (offline)"
    public let supportsWordBoundaries = true
    public static let firstAudioTimeout: TimeInterval = 3

    private let queue = DispatchQueue(label: "com.jdforsythe.claudio.apple-speech")
    private var synthesizer = AVSpeechSynthesizer()
    private var converter: AVAudioConverter?
    private var current: Job?
    private var pending: [Job] = []
    private let log = Log.apple
    private let boundaryWarned = Mutex<Set<String>>([])

    private final class Job: @unchecked Sendable {
        let request: SynthesisRequest
        let continuation: AsyncThrowingStream<SynthesisEvent, any Error>.Continuation
        var framesYielded = 0
        var pendingSamples: [Float] = []
        var sawBoundary = false
        var finished = false
        var timeout: DispatchWorkItem?
        init(request: SynthesisRequest, continuation: AsyncThrowingStream<SynthesisEvent, any Error>.Continuation) {
            self.request = request
            self.continuation = continuation
        }
    }

    override public init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: Voices

    public func voices() async throws -> [Voice] {
        let all = AVSpeechSynthesisVoice.speechVoices().map(Self.voice(from:))
        return Self.ranked(all)
    }

    public static func voice(from v: AVSpeechSynthesisVoice) -> Voice {
        let quality: String? = switch v.quality {
        case .premium: "premium"
        case .enhanced: "enhanced"
        default: nil
        }
        let gender: String? = switch v.gender {
        case .male: "Male"
        case .female: "Female"
        default: nil
        }
        let suffix = quality.map { " (\($0.capitalized))" } ?? ""
        return Voice(backend: "apple", id: v.identifier, displayName: v.name + suffix, locale: v.language, gender: gender, quality: quality)
    }

    static func qualityRank(_ q: String?) -> Int {
        switch q {
        case "premium": 0
        case "enhanced": 1
        default: 2
        }
    }

    public static func ranked(_ voices: [Voice]) -> [Voice] {
        voices.sorted { a, b in
            let la = a.id.contains("com.apple.eloquence") || a.id.contains("com.apple.speech.synthesis.voice")
            let lb = b.id.contains("com.apple.eloquence") || b.id.contains("com.apple.speech.synthesis.voice")
            if la != lb { return !la }
            let qa = qualityRank(a.quality)
            let qb = qualityRank(b.quality)
            if qa != qb { return qa < qb }
            return a.displayName < b.displayName
        }
    }

    public var hasHighQualityVoice: Bool {
        AVSpeechSynthesisVoice.speechVoices().contains { $0.quality == .premium || $0.quality == .enhanced }
    }

    /// Best installed voice for the locale (premium > enhanced > default), falling back to en-US.
    public static func defaultVoice(locale: String = Locale.current.identifier.replacingOccurrences(of: "_", with: "-"),
                                    gender: String? = nil) -> Voice? {
        let all = ranked(AVSpeechSynthesisVoice.speechVoices().map(voice(from:)))
        let lang = String(locale.split(separator: "-").first ?? "en").lowercased()
        func pick(_ candidates: [Voice]) -> Voice? {
            if let gender, let g = candidates.first(where: { $0.gender == gender }) { return g }
            return candidates.first
        }
        let exact = all.filter { $0.locale.lowercased() == locale.lowercased() }
        if let v = pick(exact) { return v }
        let sameLang = all.filter { $0.languageCode == lang }
        if let v = pick(sameLang) { return v }
        return pick(all.filter { $0.locale.lowercased() == "en-us" }) ?? all.first
    }

    // MARK: Rate

    public static func appleRate(from multiplier: Double) -> Float {
        if multiplier <= 1.0 { return Float(min(0.9, max(0.1, 0.5 * multiplier))) }
        return Float(min(0.9, max(0.5, 0.5 + (multiplier - 1.0) * 0.2)))
    }

    // MARK: Synthesis

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
        let job = Job(request: request, continuation: continuation)
        continuation.onTermination = { [weak self] reason in
            guard case .cancelled = reason else { return }
            self?.queue.async { self?.cancel(job) }
        }
        queue.async { [self] in
            pending.append(job)
            startNextIfIdle()
        }
        return stream
    }

    private func startNextIfIdle() {
        guard current == nil, !pending.isEmpty else { return }
        let job = pending.removeFirst()
        current = job
        let voice: AVSpeechSynthesisVoice?
        if job.request.voice.id.isEmpty {
            voice = Self.defaultVoice().flatMap { AVSpeechSynthesisVoice(identifier: $0.id) }
        } else {
            voice = AVSpeechSynthesisVoice(identifier: job.request.voice.id)
        }
        guard let voice else {
            finish(job, error: BackendError.invalidVoice(job.request.voice.id))
            return
        }
        let utterance = AVSpeechUtterance(string: job.request.text)
        utterance.voice = voice
        utterance.rate = Self.appleRate(from: job.request.rate)
        utterance.prefersAssistiveTechnologySettings = false
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.current === job, job.framesYielded == 0 else { return }
            self.synthesizer.stopSpeaking(at: .immediate)
            self.finish(job, error: BackendError.timeout(stage: "firstAudio"))
        }
        job.timeout = timeout
        queue.asyncAfter(deadline: .now() + Self.firstAudioTimeout, execute: timeout)
        synthesizer.write(utterance) { [weak self] buffer in
            self?.queue.async { self?.received(buffer, for: job) }
        }
    }

    private func received(_ buffer: AVAudioBuffer, for job: Job) {
        guard current === job, !job.finished else { return }
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        if pcm.frameLength == 0 {
            flushPending(job)
            if job.framesYielded == 0 {
                finish(job, error: BackendError.decode("no audio"))
            } else {
                if !job.sawBoundary { warnNoBoundaries(job.request.voice.id) }
                finish(job, error: nil)
            }
            return
        }
        guard let canonical = PCMFormat.canonicalBuffer(from: pcm, converter: &converter) else {
            finish(job, error: BackendError.decode("converter"))
            return
        }
        job.timeout?.cancel()
        job.pendingSamples.append(contentsOf: canonical.samples)
        if job.pendingSamples.count >= 1200 { flushPending(job) }
    }

    private func flushPending(_ job: Job) {
        guard !job.pendingSamples.isEmpty else { return }
        let out = PCMBuffer(samples: job.pendingSamples)
        job.pendingSamples.removeAll()
        job.framesYielded += out.frameCount
        job.continuation.yield(.audio(out))
    }

    private func finish(_ job: Job, error: (any Error)?) {
        guard !job.finished else { return }
        job.finished = true
        job.timeout?.cancel()
        if let error {
            job.continuation.finish(throwing: error)
            synthesizer = AVSpeechSynthesizer()
            synthesizer.delegate = self
        } else {
            job.continuation.yield(.finished)
            job.continuation.finish()
        }
        if current === job { current = nil }
        startNextIfIdle()
    }

    private func cancel(_ job: Job) {
        if let idx = pending.firstIndex(where: { $0 === job }) {
            pending.remove(at: idx)
            job.finished = true
            return
        }
        guard current === job, !job.finished else { return }
        job.finished = true
        job.timeout?.cancel()
        synthesizer.stopSpeaking(at: .immediate)
        current = nil
        startNextIfIdle()
    }

    private func warnNoBoundaries(_ voiceID: String) {
        let first = boundaryWarned.withLock { $0.insert(voiceID).inserted }
        if first { log.notice("no word boundaries delivered for voice \(voiceID); approximating") }
    }

    // MARK: Delegate

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
                                 utterance: AVSpeechUtterance) {
        queue.async { [self] in
            guard let job = current, !job.finished else { return }
            let text = job.request.text
            guard let range = Range(characterRange, in: text) else { return }
            job.sawBoundary = true
            let offset = Double(job.framesYielded + job.pendingSamples.count) / PCMFormat.sampleRate
            job.continuation.yield(.wordBoundary(textRange: range, audioOffset: offset, duration: 0.3))
        }
    }
}
