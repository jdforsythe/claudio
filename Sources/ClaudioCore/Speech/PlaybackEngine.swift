@preconcurrency import AVFoundation
import Foundation

/// Production `PlaybackSink`: one `AVAudioEngine`, one `AVAudioPlayerNode`, gapless scheduling, 15 ms fade on cancel
/// (document 05 §7). The only `@unchecked Sendable` in the package: every access to the AVFoundation objects happens
/// on `queue`, and completion handlers check `generation` before touching state.
public final class PlaybackEngine: PlaybackSink, @unchecked Sendable {
    public static let idleStopSeconds: TimeInterval = 30
    public static let positionHz: Double = 30

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let queue = DispatchQueue(label: "com.jdforsythe.claudio.playback")
    private let broadcast = Broadcast<PlaybackEvent>()
    private let log = Log.playback
    private let clock: any ClaudioClock

    // All state below is confined to `queue`.
    private var generation: UInt64 = 0
    private var scheduledFrames: AVAudioFramePosition = 0
    private var segmentOrder: [UUID] = []
    private var segmentStartFrame: [UUID: AVAudioFramePosition] = [:]
    private var segmentFrames: [UUID: AVAudioFramePosition] = [:]
    private var pendingBuffers: [UUID: Int] = [:]
    private var endMarked: Set<UUID> = []
    private var startedSegments: Set<UUID> = []
    private var currentSegment: UUID?
    private var idleTimer: DispatchWorkItem?
    private var positionTimer: (any DispatchSourceTimer)?
    private var paused = false
    private var started = false
    private var configObserver: (any NSObjectProtocol)?
    private var converterLoggedOnce = false
    private var outputLatency: TimeInterval = 0
    private let startedAt = Date()

    public init(clock: any ClaudioClock = SystemClock()) {
        self.clock = clock
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: PCMFormat.canonical)
        engine.prepare()
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                                queue: nil) { [weak self] _ in
            self?.queue.async { self?.handleConfigurationChange() }
        }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    public func events() -> AsyncStream<PlaybackEvent> { broadcast.subscribe() }

    public var isRunning: Bool { queue.sync { engine.isRunning } }

    // MARK: - PlaybackSink

    public func enqueue(_ buffer: PCMBuffer, segmentID: UUID) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async {
                self.enqueueOnQueue(buffer, segmentID: segmentID)
                c.resume()
            }
        }
    }

    public func markSegmentEnd(_ segmentID: UUID) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async {
                self.endMarked.insert(segmentID)
                self.checkFinished(segmentID)
                c.resume()
            }
        }
    }

    public func pause() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async {
                self.paused = true
                self.player.pause()
                self.idleTimer?.cancel()
                self.idleTimer = nil
                self.broadcast.send(.paused)
                c.resume()
            }
        }
    }

    public func resume() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async {
                self.paused = false
                if self.engine.isRunning { self.player.play() }
                self.broadcast.send(.resumed)
                c.resume()
            }
        }
    }

    public func cancelAll(fade: TimeInterval) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async {
                self.cancelOnQueue(fade: fade)
                self.broadcast.send(.drained)
                c.resume()
            }
        }
    }

    public func skipSegment(_ segmentID: UUID, fade: TimeInterval) async {
        await cancelAll(fade: fade)
    }

    // MARK: - Queue-confined implementation

    private func ensureStarted() {
        idleTimer?.cancel()
        idleTimer = nil
        guard !engine.isRunning else { return }
        do {
            try engine.start()
            outputLatency = engine.outputNode.presentationLatency
            player.play()
            started = true
            startPositionTimer()
            log.info("engine started latency=\(Int(outputLatency * 1000))ms")
        } catch {
            log.error("engine start failed: \(error)")
        }
    }

    private func enqueueOnQueue(_ buffer: PCMBuffer, segmentID: UUID) {
        ensureStarted()
        guard let av = buffer.makeAVBuffer() else { return }
        let frames = AVAudioFramePosition(av.frameLength)
        if !segmentOrder.contains(segmentID) {
            segmentOrder.append(segmentID)
            segmentFrames[segmentID] = 0
        }
        segmentFrames[segmentID, default: 0] += frames
        pendingBuffers[segmentID, default: 0] += 1
        scheduledFrames += frames
        let gen = generation
        log.debug("scheduled frames=\(frames) segment=\(segmentID.uuidString.prefix(8))")
        let isFirstOfSegment = segmentFrames[segmentID] == frames
        player.scheduleBuffer(av, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                guard gen == self.generation else { return }
                self.pendingBuffers[segmentID, default: 1] -= 1
                self.checkFinished(segmentID)
            }
        }
        if currentSegment == nil, isFirstOfSegment {
            beginSegment(segmentID, chainedAfter: nil)
        }
        if paused { player.pause() } else if !player.isPlaying { player.play() }
    }

    /// Anchors the segment's first frame on the player's sample clock. A segment that follows another back-to-back
    /// starts exactly where the previous one ended; a segment that starts from silence starts at the clock's current
    /// position, because the player keeps counting samples while it renders silence (the position timer measures
    /// against this anchor, so captions track the words actually being rendered).
    private func beginSegment(_ id: UUID, chainedAfter previous: (start: AVAudioFramePosition, frames: AVAudioFramePosition)?) {
        guard !startedSegments.contains(id) else { return }
        startedSegments.insert(id)
        currentSegment = id
        if let previous {
            segmentStartFrame[id] = previous.start + previous.frames
        } else if let nodeTime = player.lastRenderTime, let playerTime = player.playerTime(forNodeTime: nodeTime) {
            segmentStartFrame[id] = playerTime.sampleTime
        } else {
            segmentStartFrame[id] = 0
        }
        broadcast.send(.segmentStarted(id, at: clock.now))
    }

    private func checkFinished(_ id: UUID) {
        guard endMarked.contains(id), (pendingBuffers[id] ?? 0) <= 0, segmentOrder.first == id else { return }
        segmentOrder.removeFirst()
        endMarked.remove(id)
        pendingBuffers.removeValue(forKey: id)
        startedSegments.remove(id)
        let finishedStart = segmentStartFrame.removeValue(forKey: id)
        let finishedFrames = segmentFrames.removeValue(forKey: id)
        currentSegment = nil
        broadcast.send(.segmentFinished(id, at: clock.now))
        if let next = segmentOrder.first {
            // The next segment's buffers were scheduled back-to-back only if they were already enqueued; if the
            // queue was empty for a moment, the player rendered silence and the clock anchor must be re-read.
            if let finishedStart, let finishedFrames, (pendingBuffers[next] ?? 0) > 0 {
                beginSegment(next, chainedAfter: (finishedStart, finishedFrames))
            } else {
                beginSegment(next, chainedAfter: nil)
            }
        } else {
            broadcast.send(.drained)
            scheduleIdleStop()
        }
    }

    private func cancelOnQueue(fade: TimeInterval) {
        let v0 = player.volume
        if engine.isRunning, player.isPlaying, fade > 0 {
            let steps = max(1, Int(fade * 1000))
            for i in 1...steps {
                player.volume = v0 * Float(1 - Double(i) / Double(steps))
                usleep(1000)
            }
        }
        generation &+= 1
        player.stop()
        player.reset()
        player.volume = v0
        if engine.isRunning, !paused { player.play() }
        scheduledFrames = 0
        segmentOrder.removeAll()
        segmentStartFrame.removeAll()
        segmentFrames.removeAll()
        pendingBuffers.removeAll()
        endMarked.removeAll()
        startedSegments.removeAll()
        currentSegment = nil
        scheduleIdleStop()
    }

    private func scheduleIdleStop() {
        idleTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.paused, self.segmentOrder.isEmpty else { return }
            self.positionTimer?.cancel()
            self.positionTimer = nil
            self.player.stop()
            self.engine.stop()
            self.log.info("engine stopped after idle")
        }
        idleTimer = item
        queue.asyncAfter(deadline: .now() + Self.idleStopSeconds, execute: item)
    }

    private func startPositionTimer() {
        positionTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / Self.positionHz)
        timer.setEventHandler { [weak self] in
            guard let self, let id = self.currentSegment, !self.paused,
                  let nodeTime = self.player.lastRenderTime,
                  let playerTime = self.player.playerTime(forNodeTime: nodeTime),
                  let start = self.segmentStartFrame[id] else { return }
            let pos = Double(playerTime.sampleTime - start) / PCMFormat.sampleRate - self.outputLatency
            if pos >= 0 { self.broadcast.send(.position(id, pos)) }
        }
        timer.resume()
        positionTimer = timer
    }

    private func handleConfigurationChange() {
        log.notice("audio configuration changed; rebuilding graph")
        generation &+= 1
        player.stop()
        engine.stop()
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: PCMFormat.canonical)
        scheduledFrames = 0
        segmentOrder.removeAll()
        segmentStartFrame.removeAll()
        segmentFrames.removeAll()
        pendingBuffers.removeAll()
        endMarked.removeAll()
        startedSegments.removeAll()
        currentSegment = nil
        engine.prepare()
        broadcast.send(.deviceChanged)
    }
}
