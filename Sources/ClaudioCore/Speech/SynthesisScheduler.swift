import Foundation

public struct WordBoundary: Sendable, Equatable {
    public let textRange: Range<String.Index>
    public let audioOffset: TimeInterval
    public let duration: TimeInterval
    public let approximate: Bool

    public init(textRange: Range<String.Index>, audioOffset: TimeInterval, duration: TimeInterval, approximate: Bool = false) {
        self.textRange = textRange
        self.audioOffset = audioOffset
        self.duration = duration
        self.approximate = approximate
    }
}

public struct SegmentMetrics: Sendable, Equatable {
    public var enqueuedAt: Date
    public var synthStartedAt: Date?
    public var firstAudioAt: Date?
    public var readyAt: Date?
    public var playStartedAt: Date?
    public var finishedAt: Date?
    public var skipped = false
    public var backend: BackendID?

    public init(enqueuedAt: Date) { self.enqueuedAt = enqueuedAt }

    public var ttfa: TimeInterval? {
        guard let s = synthStartedAt, let f = firstAudioAt else { return nil }
        return f.timeIntervalSince(s)
    }

    public var wait: TimeInterval? {
        playStartedAt.map { $0.timeIntervalSince(enqueuedAt) }
    }
}

public struct ScheduledSegment: Sendable, Identifiable {
    public let id: UUID
    public let segment: Utterance.Segment
    public let item: SpeechItem
    public var state: State
    public var rate: Double
    public var buffers: [PCMBuffer]
    public var wordBoundaries: [WordBoundary]
    public var metrics: SegmentMetrics
    public var forwardedBuffers = 0
    public var endMarked = false
    public var synthesisComplete = false
    public var attempt = 0

    public enum State: String, Sendable { case pending, synthesizing, ready, playing, finished, cancelled }

    public var totalFrames: Int { buffers.reduce(0) { $0 + $1.frameCount } }
    public var duration: TimeInterval { Double(totalFrames) / PCMBuffer.sampleRate }
}

public enum SchedulerEvent: Sendable {
    case segmentStarted(ScheduledSegment)
    case segmentFinished(ScheduledSegment, gap: TimeInterval?)
    case segmentDropped(UUID, String)
    case boundaries(UUID, [WordBoundary])
    case position(UUID, TimeInterval)
    case queueChanged(count: Int, seconds: Double)
    case paused
    case resumed
    case drained
}

/// Keeps audio flowing: lookahead synthesis, in-order forwarding, cancel tokens (document 05 §6).
public actor SynthesisScheduler {
    public static let preRollSeconds: TimeInterval = 0.5
    public static let fade: TimeInterval = 0.015

    private var backend: any TTSBackend
    private let sink: any PlaybackSink
    private let clock: any ClaudioClock
    private let log = Log.scheduler
    private var queue: [ScheduledSegment] = []
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var rate: Double
    private var lookahead: Int
    private var voiceProvider: @Sendable (BackendID) -> Voice
    private var forwardingID: UUID?
    private var lastFinishedAt: Date?
    private var paused = false
    private var sinkTask: Task<Void, Never>?
    private let broadcast = Broadcast<SchedulerEvent>()
    private var recentTTFA: [TimeInterval] = []
    private var recentGaps: [TimeInterval] = []
    private var lastKnownBackend: [UUID: BackendID] = [:]

    public init(backend: any TTSBackend, sink: any PlaybackSink, clock: any ClaudioClock = SystemClock(),
                rate: Double = 1.0, lookahead: Int = 2, voiceProvider: @escaping @Sendable (BackendID) -> Voice) {
        self.backend = backend
        self.sink = sink
        self.clock = clock
        self.rate = rate
        self.lookahead = max(1, min(4, lookahead))
        self.voiceProvider = voiceProvider
    }

    public nonisolated func events() -> AsyncStream<SchedulerEvent> { broadcast.subscribe() }

    public func start() {
        guard sinkTask == nil else { return }
        let stream = sink.events()
        sinkTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handleSink(event)
            }
        }
    }

    public func stop() {
        sinkTask?.cancel()
        sinkTask = nil
        for t in tasks.values { t.cancel() }
        tasks.removeAll()
    }

    // MARK: - Configuration

    public func setRate(_ multiplier: Double) { rate = min(2.0, max(0.5, multiplier)) }
    public func setBackend(_ backend: any TTSBackend) { self.backend = backend }
    public func setLookahead(_ n: Int) {
        lookahead = max(1, min(4, n))
        evaluate()
    }
    public func setVoiceProvider(_ provider: @escaping @Sendable (BackendID) -> Voice) { voiceProvider = provider }
    public var currentBackendID: BackendID { backend.id }

    // MARK: - Input

    public func append(_ utterance: Utterance) {
        let now = clock.now
        for segment in utterance.segments {
            queue.append(ScheduledSegment(id: segment.id, segment: segment, item: utterance.item, state: .pending,
                                          rate: rate, buffers: [], wordBoundaries: [], metrics: SegmentMetrics(enqueuedAt: now)))
        }
        log.info("enqueued session=\(utterance.item.sessionID.prefix(8)) category=\(utterance.item.category.rawValue) segments=\(utterance.segments.count) chars=\(utterance.characterCount)")
        evaluate()
        publishQueue()
    }

    /// Pre-rendered audio (chimes) that joins the ordered queue as a ready segment.
    public func appendReady(buffer: PCMBuffer, item: SpeechItem, text: String) {
        let segment = Utterance.Segment(text: text, kind: .cue)
        var scheduled = ScheduledSegment(id: segment.id, segment: segment, item: item, state: .ready, rate: rate,
                                         buffers: [buffer], wordBoundaries: [], metrics: SegmentMetrics(enqueuedAt: clock.now))
        scheduled.synthesisComplete = true
        scheduled.metrics.readyAt = clock.now
        scheduled.metrics.synthStartedAt = clock.now
        scheduled.metrics.firstAudioAt = clock.now
        scheduled.metrics.backend = "chime"
        queue.append(scheduled)
        evaluate()
        publishQueue()
    }

    // MARK: - Control

    public func removeAll(where predicate: @Sendable (ScheduledSegment) -> Bool, fade: TimeInterval = SynthesisScheduler.fade) async {
        let removed = queue.filter(predicate)
        guard !removed.isEmpty else { return }
        let removedIDs = Set(removed.map(\.id))
        var needSinkCancel = false
        for seg in removed {
            tasks[seg.id]?.cancel()
            tasks.removeValue(forKey: seg.id)
            if seg.state == .playing || seg.forwardedBuffers > 0 { needSinkCancel = true }
        }
        let playing = queue.first { $0.state == .playing }
        queue.removeAll { removedIDs.contains($0.id) }
        if needSinkCancel {
            await sink.cancelAll(fade: fade)
            forwardingID = nil
            // A kept playing segment whose pre-rolled successor was removed is cut short (document 05 §2 rationale).
            if let p = playing, !removedIDs.contains(p.id), let idx = queue.firstIndex(where: { $0.id == p.id }) {
                queue[idx].state = .finished
                queue[idx].metrics.finishedAt = clock.now
                queue[idx].metrics.skipped = true
                let seg = queue.remove(at: idx)
                broadcast.send(.segmentFinished(seg, gap: nil))
            }
            // Re-forward retained buffers of what remains.
            for idx in queue.indices { queue[idx].forwardedBuffers = 0; queue[idx].endMarked = false; if queue[idx].state == .playing { queue[idx].state = .ready } }
            await forwardHead()
        }
        log.info("cancel dropped=\(removed.count) remaining=\(queue.count)")
        evaluate()
        publishQueue()
        if queue.isEmpty { broadcast.send(.drained) }
    }

    public func cancelAll(fade: TimeInterval = SynthesisScheduler.fade) async {
        await removeAll(where: { _ in true }, fade: fade)
    }

    public func skipCurrent() async {
        guard let idx = queue.firstIndex(where: { $0.state == .playing }) ?? queue.indices.first else { return }
        var seg = queue.remove(at: idx)
        tasks[seg.id]?.cancel()
        tasks.removeValue(forKey: seg.id)
        seg.state = .finished
        seg.metrics.skipped = true
        seg.metrics.finishedAt = clock.now
        await sink.skipSegment(seg.id, fade: Self.fade)
        forwardingID = nil
        for i in queue.indices { queue[i].forwardedBuffers = 0; queue[i].endMarked = false; if queue[i].state == .playing { queue[i].state = .ready } }
        broadcast.send(.segmentFinished(seg, gap: nil))
        await forwardHead()
        evaluate()
        publishQueue()
        if queue.isEmpty { broadcast.send(.drained) }
    }

    public func pause() async {
        paused = true
        await sink.pause()
        broadcast.send(.paused)
    }

    public func resume() async {
        paused = false
        await sink.resume()
        broadcast.send(.resumed)
        await forwardHead()
    }

    public var isPaused: Bool { paused }
    public var queuedCount: Int { queue.filter { $0.state != .finished }.count }
    public var snapshot: [ScheduledSegment] { queue }
    public var queuedSeconds: Double {
        queue.filter { $0.state == .ready }.reduce(0) { $0 + $1.duration }
    }
    public var currentSegment: ScheduledSegment? { queue.first { $0.state == .playing } }

    public func metricsSummary() -> [String: Double] {
        func pct(_ values: [TimeInterval], _ p: Double) -> Double {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted()
            let idx = min(sorted.count - 1, Int(Double(sorted.count - 1) * p))
            return sorted[idx] * 1000
        }
        return [
            "synth.ttfa.p50": pct(recentTTFA, 0.5), "synth.ttfa.p95": pct(recentTTFA, 0.95),
            "playback.gap.p50": pct(recentGaps, 0.5), "playback.gap.p95": pct(recentGaps, 0.95),
            "queue.segments": Double(queuedCount),
        ]
    }

    // MARK: - Lookahead

    private func evaluate() {
        let k = queue.firstIndex { $0.state == .playing } ?? 0
        guard !queue.isEmpty else { return }
        let upper = min(queue.count - 1, k + lookahead)
        for i in 0...upper where queue[i].state == .pending {
            startSynthesis(at: i)
        }
        Task { await forwardHead() }
    }

    private func startSynthesis(at index: Int) {
        var seg = queue[index]
        seg.state = .synthesizing
        seg.rate = rate
        seg.metrics.synthStartedAt = clock.now
        queue[index] = seg
        let request = SynthesisRequest(id: UUID(), text: seg.segment.text, voice: voiceProvider(backend.id), rate: seg.rate,
                                       wantsWordBoundaries: true)
        let useBackend: any TTSBackend = seg.attempt == 0 ? backend : ((backend as? any FallbackReporting)?.fallbackOnly ?? backend)
        let id = seg.id
        log.debug("segment \(id.uuidString.prefix(8)) synthesizing backend=\(useBackend.id) attempt=\(seg.attempt)")
        tasks[id] = Task(priority: .userInitiated) { [weak self] in
            do {
                for try await event in useBackend.synthesize(request) {
                    try Task.checkCancellation()
                    guard let self else { return }
                    switch event {
                    case .audio(let buffer): await self.received(buffer, for: id)
                    case .wordBoundary(let range, let offset, let duration): await self.recordBoundary(id, range, offset, duration)
                    case .finished: await self.synthesisFinished(id, backend: useBackend.id)
                    }
                }
            } catch is CancellationError {
                // already cancelled
            } catch {
                await self?.synthesisFailed(id, error)
            }
        }
    }

    private func received(_ buffer: PCMBuffer, for id: UUID) async {
        guard let idx = queue.firstIndex(where: { $0.id == id }), queue[idx].state == .synthesizing || queue[idx].state == .playing else { return }
        if queue[idx].metrics.firstAudioAt == nil { queue[idx].metrics.firstAudioAt = clock.now }
        queue[idx].buffers.append(buffer)
        if forwardingID == id {
            queue[idx].forwardedBuffers += 1
            await sink.enqueue(buffer, segmentID: id)
        }
        await forwardHead()
    }

    private func recordBoundary(_ id: UUID, _ range: Range<String.Index>, _ offset: TimeInterval, _ duration: TimeInterval) {
        guard let idx = queue.firstIndex(where: { $0.id == id }) else { return }
        queue[idx].wordBoundaries.append(WordBoundary(textRange: range, audioOffset: offset, duration: duration))
    }

    private func synthesisFinished(_ id: UUID, backend: BackendID) async {
        guard let idx = queue.firstIndex(where: { $0.id == id }) else { return }
        tasks.removeValue(forKey: id)
        if queue[idx].buffers.isEmpty {
            await synthesisFailed(id, BackendError.decode("no audio"))
            return
        }
        if queue[idx].state == .synthesizing { queue[idx].state = .ready }
        queue[idx].synthesisComplete = true
        queue[idx].metrics.readyAt = clock.now
        queue[idx].metrics.backend = backend
        if let t = queue[idx].metrics.ttfa { recentTTFA.append(t); if recentTTFA.count > 100 { recentTTFA.removeFirst() } }
        if queue[idx].wordBoundaries.isEmpty {
            queue[idx].wordBoundaries = Self.approximateBoundaries(text: queue[idx].segment.text, duration: queue[idx].duration)
            log.notice("approximated boundaries for segment \(id.uuidString.prefix(8))")
        }
        broadcast.send(.boundaries(id, queue[idx].wordBoundaries))
        await forwardHead()
        evaluate()
        publishQueue()
    }

    private func synthesisFailed(_ id: UUID, _ error: any Error) async {
        guard let idx = queue.firstIndex(where: { $0.id == id }) else { return }
        tasks.removeValue(forKey: id)
        log.error("synth.failed segment=\(id.uuidString.prefix(8)) backend=\(backend.id) error=\(error)")
        if queue[idx].attempt == 0, backend is any FallbackReporting {
            queue[idx].attempt = 1
            queue[idx].state = .pending
            queue[idx].synthesisComplete = false
            queue[idx].buffers.removeAll()
            queue[idx].wordBoundaries.removeAll()
            evaluate()
            return
        }
        let seg = queue.remove(at: idx)
        if forwardingID == id { forwardingID = nil }
        broadcast.send(.segmentDropped(seg.id, String(describing: error)))
        await forwardHead()
        evaluate()
        publishQueue()
        if queue.isEmpty { broadcast.send(.drained) }
    }

    // MARK: - Forwarding (ordering guarantee + pre-roll)

    /// Forwards retained buffers of the segment that is allowed to reach the sink next.
    private func forwardHead() async {
        guard !paused else { return }
        if let fid = forwardingID, let idx = queue.firstIndex(where: { $0.id == fid }) {
            // Still streaming this one; flush anything retained but not yet forwarded.
            await flush(idx)
            return
        }
        // Choose the next segment to forward: the first that is not finished and not already fully forwarded.
        guard let idx = queue.firstIndex(where: { $0.state != .finished && !$0.endMarked }) else { return }
        let playingIdx = queue.firstIndex { $0.state == .playing }
        if let p = playingIdx, p != idx {
            // Pre-roll only once the playing segment nears its end (known only when ready).
            guard queue[p].endMarked, preRollDue(p) else { return }
        }
        guard queue[idx].state != .pending else { return }
        forwardingID = queue[idx].id
        await flush(idx)
    }

    private var lastPosition: (UUID, TimeInterval)?

    private func preRollDue(_ playingIndex: Int) -> Bool {
        let seg = queue[playingIndex]
        guard let (id, pos) = lastPosition, id == seg.id else { return false }
        return pos >= seg.duration - Self.preRollSeconds
    }

    private func flush(_ idx: Int) async {
        let id = queue[idx].id
        while let i = queue.firstIndex(where: { $0.id == id }), queue[i].forwardedBuffers < queue[i].buffers.count {
            let buffer = queue[i].buffers[queue[i].forwardedBuffers]
            queue[i].forwardedBuffers += 1
            await sink.enqueue(buffer, segmentID: id)
        }
        guard let i = queue.firstIndex(where: { $0.id == id }) else { return }
        if queue[i].synthesisComplete, (queue[i].state == .ready || queue[i].state == .playing), !queue[i].endMarked {
            queue[i].endMarked = true
            await sink.markSegmentEnd(id)
            forwardingID = nil
            // Immediately consider the next one (it will wait for pre-roll if something is playing).
            await forwardHead()
        }
    }

    // MARK: - Sink events

    private func handleSink(_ event: PlaybackEvent) async {
        switch event {
        case .segmentStarted(let id, let at):
            guard let idx = queue.firstIndex(where: { $0.id == id }) else { return }
            queue[idx].state = .playing
            queue[idx].metrics.playStartedAt = at
            lastPosition = (id, 0)
            broadcast.send(.segmentStarted(queue[idx]))
            log.debug("segment \(id.uuidString.prefix(8)) playing")
            evaluate()
            publishQueue()
        case .segmentFinished(let id, let at):
            guard let idx = queue.firstIndex(where: { $0.id == id }) else { return }
            var seg = queue.remove(at: idx)
            seg.state = .finished
            seg.metrics.finishedAt = at
            var gap: TimeInterval?
            if let started = seg.metrics.playStartedAt, let previous = lastFinishedAt {
                gap = started.timeIntervalSince(previous)
                if let g = gap { recentGaps.append(g); if recentGaps.count > 100 { recentGaps.removeFirst() } }
                if let g = gap, g > 0.05 {
                    log.notice("gap \(Int(g * 1000)) ms before segment \(id.uuidString.prefix(8)) starved=\(seg.metrics.readyAt.map { $0 > previous } ?? true)")
                }
            }
            lastFinishedAt = at
            let ttfa = seg.metrics.ttfa.map { Int($0 * 1000) } ?? -1
            log.info("segment finished id=\(id.uuidString.prefix(8)) ttfa=\(ttfa)ms wait=\(Int((seg.metrics.wait ?? 0) * 1000))ms gap=\(Int((gap ?? 0) * 1000))ms frames=\(seg.totalFrames) buffers=\(seg.buffers.count) backend=\(seg.metrics.backend ?? "-")")
            broadcast.send(.segmentFinished(seg, gap: gap))
            await forwardHead()
            evaluate()
            publishQueue()
        case .position(let id, let t):
            lastPosition = (id, t)
            broadcast.send(.position(id, t))
            if let p = queue.firstIndex(where: { $0.state == .playing }), queue[p].id == id, forwardingID == nil, preRollDue(p) {
                await forwardHead()
            }
        case .paused:
            broadcast.send(.paused)
        case .resumed:
            broadcast.send(.resumed)
        case .drained:
            if queue.isEmpty { broadcast.send(.drained) } else { await forwardHead() }
        case .deviceChanged:
            log.notice("device changed; re-enqueueing ready segments")
            forwardingID = nil
            for i in queue.indices { queue[i].forwardedBuffers = 0; queue[i].endMarked = false; if queue[i].state == .playing { queue[i].state = .ready } }
            await forwardHead()
        }
    }

    private func publishQueue() {
        broadcast.send(.queueChanged(count: queuedCount, seconds: queuedSeconds))
    }

    // MARK: - Approximated boundaries (document 05 §9)

    public static func approximateBoundaries(text: String, duration: TimeInterval) -> [WordBoundary] {
        let ranges = MockBackend.wordRanges(in: text)
        guard !ranges.isEmpty, duration > 0 else { return [] }
        let weights = ranges.map { Double(max(1, text.distance(from: $0.lowerBound, to: $0.upperBound) + 1)) }
        let total = weights.reduce(0, +)
        var offset = 0.0
        var out: [WordBoundary] = []
        for (r, w) in zip(ranges, weights) {
            let d = duration * w / total
            out.append(WordBoundary(textRange: r, audioOffset: offset, duration: d, approximate: true))
            offset += d
        }
        return out
    }
}
