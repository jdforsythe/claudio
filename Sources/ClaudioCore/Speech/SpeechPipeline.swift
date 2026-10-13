import Foundation

public struct PipelineState: Sendable, Equatable {
    public enum Mode: Sendable, Equatable { case idle, speaking, paused }
    public var mode: Mode = .idle
    public var currentSegment: Utterance.Segment?
    public var previousSegment: Utterance.Segment?
    public var currentItem: SpeechItem?
    public var currentWordRange: Range<String.Index>?
    public var currentWordApproximate = false
    public var queuedSegments = 0
    public var queuedSeconds: Double = 0
    public var utteranceProgress: (done: Int, total: Int)? {
        guard utteranceTotal > 0 else { return nil }
        return (utteranceDone, utteranceTotal)
    }
    public var utteranceDone = 0
    public var utteranceTotal = 0
    public var lastDroppedAt: Date?
    public var isAudible: Bool { mode == .speaking }

    public init() {}
}

public enum CancelReason: String, Sendable {
    case userPrompt, sessionSwitch, levelDowngrade, userCancel, shutdown, skipToLive
}

/// Façade the Arbiter talks to: render → segment → schedule → play (document 05 §1).
public actor SpeechPipeline {
    private let scheduler: SynthesisScheduler
    private let sink: any PlaybackSink
    private var renderer: SpeechTextRenderer
    private let clock: any ClaudioClock
    private let log = Log.speech
    private var state = PipelineState()
    private let broadcast = Broadcast<PipelineState>(replayLatest: true, bufferingPolicy: .bufferingNewest(1))
    private var boundaries: [UUID: [WordBoundary]] = [:]
    private var chimes: [Chime: PCMBuffer] = [:]
    private var chimeVolume: Double = 0.6
    private var chimesEnabled = true
    private var eventsTask: Task<Void, Never>?
    private var lastWordEmit: Date = .distantPast
    private var utteranceCounts: [UUID: Int] = [:]   // item id → total segments
    private var utteranceDoneCounts: [UUID: Int] = [:]

    public init(backend: any TTSBackend, sink: any PlaybackSink, clock: any ClaudioClock = SystemClock(),
                rate: Double = 1.0, lookahead: Int = 2, renderer: SpeechTextRenderer = SpeechTextRenderer(),
                voiceProvider: @escaping @Sendable (BackendID) -> Voice) {
        self.sink = sink
        self.clock = clock
        self.renderer = renderer
        self.scheduler = SynthesisScheduler(backend: backend, sink: sink, clock: clock, rate: rate, lookahead: lookahead,
                                            voiceProvider: voiceProvider)
    }

    public func start() async {
        await scheduler.start()
        guard eventsTask == nil else { return }
        let stream = scheduler.events()
        eventsTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    public func stop() async {
        eventsTask?.cancel()
        eventsTask = nil
        await scheduler.stop()
    }

    public nonisolated func stateStream() -> AsyncStream<PipelineState> { broadcast.subscribe() }
    public var currentState: PipelineState { state }
    public var schedulerRef: SynthesisScheduler { scheduler }

    // MARK: Input

    public func enqueue(_ item: SpeechItem) async {
        let utterance = renderer.render(item)
        await enqueue(utterance)
    }

    public func enqueue(_ utterance: Utterance) async {
        guard !utterance.segments.isEmpty else {
            log.debug("empty utterance for item \(utterance.item.id.uuidString.prefix(8)); nothing to speak")
            return
        }
        utteranceCounts[utterance.item.id] = utterance.segments.count
        utteranceDoneCounts[utterance.item.id] = 0
        await scheduler.append(utterance)
    }

    public func render(_ markdown: String) -> [Utterance.Segment] {
        renderer.renderSegments(markdown)
    }

    public func registerChime(_ chime: Chime, buffer: PCMBuffer) {
        chimes[chime] = buffer
    }

    public func enqueueChime(_ chime: Chime, sessionID: SessionID = "system") async {
        guard chimesEnabled, let buffer = chimes[chime] else { return }
        let item = SpeechItem(sessionID: sessionID, turnID: nil, category: .event, text: "", timestamp: clock.now)
        await scheduler.appendReady(buffer: buffer.scaled(by: Float(chimeVolume)), item: item, text: "")
    }

    // MARK: Control

    public func cancelAll(reason: CancelReason) async {
        log.info("cancelAll reason=\(reason.rawValue)")
        await scheduler.cancelAll()
        resetWord()
    }

    public func cancelSession(_ id: SessionID, reason: CancelReason) async {
        log.info("cancelSession \(id.prefix(8)) reason=\(reason.rawValue)")
        await scheduler.removeAll(where: { $0.item.sessionID == id })
        resetWord()
    }

    public func cancelCatchUp(_ id: SessionID) async {
        await scheduler.removeAll(where: { $0.item.sessionID == id && $0.item.isCatchUp })
    }

    public func dropCategories(_ categories: Set<ContentCategory>, in session: SessionID) async {
        guard !categories.isEmpty else { return }
        let before = await scheduler.queuedCount
        await scheduler.removeAll(where: { seg in
            seg.item.sessionID == session && categories.contains(seg.item.category) && !seg.item.isCatchUp && seg.state != .playing
        })
        let after = await scheduler.queuedCount
        log.info("filter.dropped count=\(before - after) session=\(session.prefix(8)) categories=\(categories.map(\.rawValue).sorted())")
    }

    public func skipSegment() async { await scheduler.skipCurrent() }

    public func pause() async {
        await scheduler.pause()
        state.mode = .paused
        publish()
    }

    public func resume() async {
        await scheduler.resume()
        state.mode = state.currentSegment == nil && state.queuedSegments == 0 ? .idle : .speaking
        publish()
    }

    public var isPaused: Bool { get async { await scheduler.isPaused } }

    public func setRate(_ multiplier: Double) async { await scheduler.setRate(multiplier) }
    public func setBackend(_ backend: any TTSBackend) async { await scheduler.setBackend(backend) }
    public func setLookahead(_ n: Int) async { await scheduler.setLookahead(n) }
    public func setVoiceProvider(_ provider: @escaping @Sendable (BackendID) -> Voice) async {
        await scheduler.setVoiceProvider(provider)
    }
    public func setChimeVolume(_ v: Double) { chimeVolume = min(1, max(0, v)) }
    public func setChimesEnabled(_ enabled: Bool) { chimesEnabled = enabled }
    public func metrics() async -> [String: Double] { await scheduler.metricsSummary() }
    public func queueSnapshot() async -> [ScheduledSegment] { await scheduler.snapshot }

    // MARK: Events

    private func handle(_ event: SchedulerEvent) async {
        switch event {
        case .segmentStarted(let seg):
            state.previousSegment = state.currentSegment
            state.currentSegment = seg.segment
            state.currentItem = seg.item
            state.currentWordRange = nil
            state.mode = .speaking
            if let b = boundaries[seg.id], !b.isEmpty {
                state.currentWordRange = b.first?.textRange
                state.currentWordApproximate = b.first?.approximate ?? false
            }
            let total = utteranceCounts[seg.item.id] ?? 1
            let done = utteranceDoneCounts[seg.item.id] ?? 0
            state.utteranceTotal = total
            state.utteranceDone = done + 1
            publish()
        case .segmentFinished(let seg, _):
            boundaries.removeValue(forKey: seg.id)
            utteranceDoneCounts[seg.item.id, default: 0] += 1
            if utteranceDoneCounts[seg.item.id] ?? 0 >= utteranceCounts[seg.item.id] ?? 0 {
                utteranceCounts.removeValue(forKey: seg.item.id)
                utteranceDoneCounts.removeValue(forKey: seg.item.id)
            }
            if state.currentSegment?.id == seg.id {
                state.previousSegment = seg.segment
                state.currentSegment = nil
                state.currentItem = nil
                state.currentWordRange = nil
            }
            publish()
        case .segmentDropped(let id, let reason):
            boundaries.removeValue(forKey: id)
            state.lastDroppedAt = clock.now
            log.error("segment dropped \(id.uuidString.prefix(8)): \(reason)")
            publish()
        case .boundaries(let id, let list):
            boundaries[id] = list
        case .position(let id, let t):
            guard state.currentSegment?.id == id, let list = boundaries[id] else { return }
            if let word = list.last(where: { $0.audioOffset <= t }) {
                if state.currentWordRange != word.textRange {
                    state.currentWordRange = word.textRange
                    state.currentWordApproximate = word.approximate
                    let now = clock.now
                    if now.timeIntervalSince(lastWordEmit) >= 1.0 / 60 {
                        lastWordEmit = now
                        publish()
                    }
                }
            }
        case .queueChanged(let count, let seconds):
            state.queuedSegments = count
            state.queuedSeconds = seconds
            if state.mode != .paused { state.mode = (count == 0 && state.currentSegment == nil) ? .idle : .speaking }
            publish()
        case .paused:
            state.mode = .paused
            publish()
        case .resumed:
            state.mode = state.currentSegment == nil && state.queuedSegments == 0 ? .idle : .speaking
            publish()
        case .drained:
            state.currentSegment = nil
            state.currentItem = nil
            state.currentWordRange = nil
            state.queuedSegments = 0
            state.queuedSeconds = 0
            state.utteranceTotal = 0
            state.utteranceDone = 0
            if state.mode != .paused { state.mode = .idle }
            publish()
        }
    }

    private func resetWord() {
        state.currentWordRange = nil
        publish()
    }

    private func publish() {
        broadcast.send(state)
    }
}
