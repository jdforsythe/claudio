import Foundation

/// Decides who gets the voice (document 01 §7–§9, document 02 §7.2).
public actor Arbiter {
    private let registry: SessionRegistry
    private let pipeline: SpeechPipeline
    private let settings: AppSettings
    private let clock: any ClaudioClock
    private let log = Log.arbiter
    private var filter: ContentFilter
    private var snapshot: AppSettingsSnapshot
    private var state = ArbiterState()
    private var previousMode: ArbiterMode = .idle
    private var heldLiveItems: [SpeechItem] = []
    private var catchUpItemIDs: [UUID] = []
    private var catchUpFinished = Set<UUID>()
    private var catchUpSegmentTotals: [UUID: Int] = [:]
    private var catchUpSegmentsDone: [UUID: Int] = [:]
    private var tasks: [Task<Void, Never>] = []
    private let stateBroadcast = Broadcast<ArbiterState>(replayLatest: true, bufferingPolicy: .bufferingNewest(1))
    private let eventBroadcast = Broadcast<ArbiterEvent>()
    private var announcedFinished: [SessionID: TurnID] = [:]
    private var pendingSingleActivation = false

    public init(registry: SessionRegistry, pipeline: SpeechPipeline, settings: AppSettings,
                clock: any ClaudioClock = SystemClock()) {
        self.registry = registry
        self.pipeline = pipeline
        self.settings = settings
        self.clock = clock
        self.snapshot = settings.snapshot
        self.filter = ContentFilter(snapshot: settings.snapshot)
        self.state.eventsMuted = !settings.snapshot.eventsEnabled
    }

    public nonisolated func stateStream() -> AsyncStream<ArbiterState> { stateBroadcast.subscribe() }
    public nonisolated func events() -> AsyncStream<ArbiterEvent> { eventBroadcast.subscribe() }
    public var currentState: ArbiterState { state }
    public var activeSessionID: SessionID? { state.activeSessionID }
    public var mode: ArbiterMode { state.mode }

    public func start() async {
        let registryEvents = registry.events()
        tasks.append(Task { [weak self] in
            for await event in registryEvents {
                guard let self else { return }
                await self.handle(event)
            }
        })
        let schedulerEvents = await pipeline.schedulerRef.events()
        tasks.append(Task { [weak self] in
            for await event in schedulerEvents {
                guard let self else { return }
                await self.handleScheduler(event)
            }
        })
        let settingsChanges = settings.changes()
        tasks.append(Task { [weak self] in
            for await snap in settingsChanges {
                guard let self else { return }
                await self.applySettings(snap)
            }
        })
        if let restored = await registry.activeID {
            state.activeSessionID = restored
            state.mode = .live(restored)
            log.info("activate reason=restore session=\(restored.prefix(8))")
        } else {
            await autoActivateIfSingle()
        }
        publish()
    }

    public func stop() {
        for t in tasks { t.cancel() }
        tasks.removeAll()
    }

    private func applySettings(_ snap: AppSettingsSnapshot) async {
        let old = filter
        snapshot = snap
        filter = ContentFilter(snapshot: snap)
        state.eventsMuted = !snap.eventsEnabled
        if let active = state.activeSessionID, let session = await registry.session(active) {
            var excluded = Set<ContentCategory>()
            for c in ContentCategory.allCases where old.includes(c, at: session.level) && !filter.includes(c, at: session.level) {
                excluded.insert(c)
            }
            if !excluded.isEmpty { await pipeline.dropCategories(excluded, in: active) }
        }
        publish()
    }

    // MARK: - Registry events

    private func handle(_ event: RegistryEvent) async {
        switch event {
        case .item(let item):
            await handleItem(item)
        case .turnStarted(let id, _):
            if id == state.activeSessionID {
                log.info("cancel reason=userPrompt session=\(id.prefix(8))")
                await pipeline.cancelSession(id, reason: .userPrompt)
                heldLiveItems.removeAll()
                if case .catchingUp = state.mode {
                    await registry.markAllRead(in: id)
                    clearCatchUp()
                    state.mode = .live(id)
                    publish()
                }
            }
        case .turnEnded(let id, let turnID, let text, let reason):
            guard reason == .completed || reason == .hookStop else { return }
            if id != state.activeSessionID, text != nil, announcedFinished[id] != turnID {
                announcedFinished[id] = turnID
                if let session = await registry.session(id), !session.muted {
                    await announce(Cues.finished(session.title), chime: .finished, sessionID: id)
                    eventBroadcast.send(.prompt(sessionID: id, title: session.title, verb: "finished"))
                }
            }
        case .statusChanged(let id, let status):
            if status == .waiting, id != state.activeSessionID, let session = await registry.session(id) {
                eventBroadcast.send(.prompt(sessionID: id, title: session.title, verb: "needs you"))
            }
        case .levelChanged(let id, let from, let to):
            guard id == state.activeSessionID else { return }
            let excluded = filter.newlyExcluded(from: from, to: to)
            if !excluded.isEmpty { await pipeline.dropCategories(excluded, in: id) }
        case .sessionAppeared:
            await autoActivateIfSingle()
        case .sessionRemoved(let id):
            if state.activeSessionID == id {
                state.activeSessionID = nil
                state.mode = .idle
                clearCatchUp()
                publish()
            }
        case .sessionEnded, .titleChanged:
            break
        }
    }

    private func handleItem(_ item: SpeechItem) async {
        let isActive = item.sessionID == state.activeSessionID
        if item.category == .event {
            guard filter.includes(item, at: .quiet) else {
                log.debug("dropped event (events disabled) session=\(item.sessionID.prefix(8))")
                return
            }
            if isActive {
                await pipeline.enqueue(item)
            } else {
                await announce(item.text, chime: .attention, sessionID: item.sessionID)
                if let session = await registry.session(item.sessionID) {
                    let verb = item.text.contains("permission") ? "needs permission"
                        : item.text.contains("input") ? "needs input" : item.text.contains("waiting") ? "is waiting" : nil
                    if let verb { eventBroadcast.send(.prompt(sessionID: item.sessionID, title: session.title, verb: verb)) }
                }
            }
            return
        }
        guard isActive, let session = await registry.session(item.sessionID) else {
            log.debug("dropped item (inactive session) session=\(item.sessionID.prefix(8)) category=\(item.category.rawValue)")
            return
        }
        guard filter.includes(item, at: session.level) else {
            log.debug("dropped item (level=\(session.level.rawValue) excludes \(item.category.rawValue))")
            return
        }
        if case .catchingUp = state.mode {
            heldLiveItems.append(item)
            return
        }
        await pipeline.enqueue(item)
    }

    private func announce(_ text: String, chime: Chime, sessionID: SessionID) async {
        guard snapshot.eventsEnabled else { return }
        if case .paused = state.mode { return }
        if snapshot.chimesEnabled { await pipeline.enqueueChime(chime, sessionID: sessionID) }
        let item = SpeechItem(sessionID: sessionID, turnID: nil, category: .event, text: text, timestamp: clock.now)
        await pipeline.enqueue(item)
    }

    // MARK: - Activation and catch-up

    private func autoActivateIfSingle() async {
        guard state.activeSessionID == nil else { return }
        let live = await registry.sessions.filter(\.isLive)
        if live.count == 1 {
            await activate(live[0].id, reason: "single-live-session")
        }
    }

    public func activate(_ id: SessionID, reason: String = "user") async {
        guard let session = await registry.session(id) else { return }
        if state.activeSessionID == id, case .live = state.mode { return }
        log.info("activate reason=\(reason) session=\(id.prefix(8))")
        if let previous = state.activeSessionID, previous != id {
            await pipeline.cancelSession(previous, reason: .sessionSwitch)
        }
        await pipeline.cancelSession(id, reason: .sessionSwitch)
        clearCatchUp()
        heldLiveItems.removeAll()
        let updated = await registry.setActive(id) ?? session
        state.activeSessionID = id
        eventBroadcast.send(.activated(id, reason: reason))
        let plan = CatchUpPlan(session: updated)
        if snapshot.chimesEnabled, reason == "user" { await pipeline.enqueueChime(.switched, sessionID: id) }
        if plan.isEmpty {
            let cue = updated.status == .busy ? Cues.switchedLive(updated.title) : Cues.switchedIdle(updated.title)
            if reason == "user" { await pipeline.enqueue(cueItem(cue, sessionID: id)) }
            state.mode = .live(id)
            publish()
            return
        }
        state.mode = .catchingUp(id)
        state.catchUpProgress = .init(index: 0, total: plan.turns.count)
        log.info("catch-up session=\(id.prefix(8)) plan=\(plan.turns.count) dropped=\(plan.droppedCount)")
        await pipeline.enqueue(cueItem(Cues.catchingUp(updated.title, turns: plan.turns.count), sessionID: id))
        for item in plan.items(at: clock.now) {
            catchUpItemIDs.append(item.id)
            await pipeline.enqueue(item)
        }
        for dropped in updated.unreadTurns.prefix(plan.droppedCount) {
            await registry.markTurnRead(dropped.turnID, in: id)
        }
        publish()
    }

    public func deactivate() async {
        if let active = state.activeSessionID { await pipeline.cancelSession(active, reason: .userCancel) }
        _ = await registry.setActive(nil)
        state.activeSessionID = nil
        state.mode = .idle
        clearCatchUp()
        publish()
    }

    private func cueItem(_ text: String, sessionID: SessionID) -> SpeechItem {
        SpeechItem(sessionID: sessionID, turnID: nil, category: .event, text: Cues.mark(text), timestamp: clock.now)
    }

    private func clearCatchUp() {
        catchUpItemIDs.removeAll()
        catchUpFinished.removeAll()
        catchUpSegmentTotals.removeAll()
        catchUpSegmentsDone.removeAll()
        state.catchUpProgress = nil
    }

    private func handleScheduler(_ event: SchedulerEvent) async {
        guard case .catchingUp(let id) = state.mode else { return }
        switch event {
        case .segmentStarted(let seg) where seg.item.isCatchUp:
            if let idx = catchUpItemIDs.firstIndex(of: seg.item.id) {
                state.catchUpProgress = .init(index: idx + 1, total: catchUpItemIDs.count)
                publish()
            }
        case .segmentFinished(let seg, _) where seg.item.isCatchUp:
            if let turnID = seg.item.turnID {
                // Mark the turn read once any of its segments has played.
                await registry.markTurnRead(turnID, in: id)
            }
            await checkCatchUpComplete(id: id)
        case .segmentDropped:
            await checkCatchUpComplete(id: id)
        case .drained:
            await checkCatchUpComplete(id: id, force: true)
        default:
            break
        }
    }

    private func checkCatchUpComplete(id: SessionID, force: Bool = false) async {
        let remaining = await pipeline.queueSnapshot().contains { $0.item.isCatchUp && $0.item.sessionID == id }
        if remaining && !force { return }
        if remaining, force { return }
        await finishCatchUp(id: id)
    }

    private func finishCatchUp(id: SessionID) async {
        guard case .catchingUp = state.mode else { return }
        await registry.markAllRead(in: id)
        let session = await registry.session(id)
        let cue = session?.status == .busy ? Cues.live : Cues.caughtUp
        clearCatchUp()
        state.mode = .live(id)
        await pipeline.enqueue(cueItem(cue, sessionID: id))
        let held = heldLiveItems
        heldLiveItems.removeAll()
        for item in held { await pipeline.enqueue(item) }
        log.info("catch-up complete session=\(id.prefix(8)) held=\(held.count)")
        publish()
    }

    public func skipToLive() async {
        guard case .catchingUp(let id) = state.mode else {
            await pipeline.skipSegment()
            return
        }
        log.info("skipToLive session=\(id.prefix(8))")
        await pipeline.cancelCatchUp(id)
        await finishCatchUp(id: id)
    }

    // MARK: - Transport

    public func pause() async {
        guard state.mode != .paused else { return }
        previousMode = state.mode
        state.mode = .paused
        await pipeline.pause()
        publish()
    }

    public func resume() async {
        guard state.mode == .paused else { return }
        state.mode = previousMode
        await pipeline.resume()
        publish()
    }

    public func togglePause() async {
        if state.mode == .paused { await resume() } else { await pause() }
    }

    public func skipSegment() async { await pipeline.skipSegment() }

    public func setEventsMuted(_ muted: Bool) {
        settings.eventsEnabled = !muted
        state.eventsMuted = muted
        publish()
    }

    /// `claudio say`: spoken immediately between segments.
    public func say(_ text: String) async {
        let item = SpeechItem(sessionID: "cli", turnID: nil, category: .event, text: Cues.mark(text), timestamp: clock.now)
        await pipeline.enqueue(item)
    }

    public func speakCue(_ text: String) async {
        await pipeline.enqueue(cueItem(text, sessionID: state.activeSessionID ?? "system"))
    }

    public func cycleLevelOfActive() async -> SpeechLevel? {
        guard let id = state.activeSessionID, let session = await registry.session(id) else { return nil }
        let next: SpeechLevel = switch session.level {
        case .quiet: .answers
        case .answers: .narrate
        case .narrate: .quiet
        }
        await registry.setLevel(next, for: id)
        await speakCue(Cues.levelName(next))
        return next
    }

    private func publish() {
        stateBroadcast.send(state)
    }
}
