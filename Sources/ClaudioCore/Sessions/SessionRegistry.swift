import Foundation

public enum RegistryEvent: Sendable, Equatable {
    case item(SpeechItem)
    case turnStarted(SessionID, TurnID)
    case turnEnded(SessionID, TurnID, finalAnswerText: String?, reason: TurnEndReason)
    case statusChanged(SessionID, SessionStatus)
    case levelChanged(SessionID, from: SpeechLevel, to: SpeechLevel)
    case sessionAppeared(SessionID)
    case sessionEnded(SessionID)
    case sessionRemoved(SessionID)
    case titleChanged(SessionID, String)
}

public struct RegistrySnapshot: Sendable, Equatable {
    public var sessions: [Session]
    public var activeSessionID: SessionID?
    public init(sessions: [Session], activeSessionID: SessionID?) {
        self.sessions = sessions
        self.activeSessionID = activeSessionID
    }
}

/// All sessions, their tailers and assemblers, liveness, naming and persistence (document 03 §8).
public actor SessionRegistry {
    private struct Entry {
        var session: Session
        let assembler: TurnAssembler
        var mainTailer: TranscriptTailer?
        var subagentTailers: [String: TranscriptTailer] = [:]
        var tasks: [Task<Void, Never>] = []
        var turns: [TurnID: Turn] = [:]
        var turnOrder: [TurnID] = []
        var hookTitle: String?
        var aiTitle: String?
        var activatedOnce = false
        var lastProbeSeen: Date?
        var missedProbes = 0
    }

    private var entries: [SessionID: Entry] = [:]
    private var activeSessionID: SessionID?
    private let discovery: SessionDiscovery
    private let probe: LiveAgentsProbe?
    private let store: SessionStateCache?
    private let settings: AppSettings
    private let projectPrefs: ProjectPreferences
    private let paths: Paths
    private let clock: any ClaudioClock
    private let log = Log.sessions
    private let eventBroadcast = Broadcast<RegistryEvent>()
    private let changeBroadcast = Broadcast<RegistrySnapshot>(replayLatest: true, bufferingPolicy: .bufferingNewest(1))
    private var tasks: [Task<Void, Never>] = []
    private var snapshot: AppSettingsSnapshot
    private var lastRecordAt: [SessionID: Date] = [:]
    private var recordsInWindow: [Date] = []
    private var unknownInWindow: [Date] = []
    public private(set) var hooksObservedAt: Date?
    public private(set) var lastProbeOutcome: LiveAgentsProbe.Outcome?

    public init(discovery: SessionDiscovery, probe: LiveAgentsProbe?, store: SessionStateCache?, settings: AppSettings,
                projectPrefs: ProjectPreferences, paths: Paths, clock: any ClaudioClock = SystemClock()) {
        self.discovery = discovery
        self.probe = probe
        self.store = store
        self.settings = settings
        self.projectPrefs = projectPrefs
        self.paths = paths
        self.clock = clock
        self.snapshot = settings.snapshot
    }

    public nonisolated func events() -> AsyncStream<RegistryEvent> { eventBroadcast.subscribe() }
    public nonisolated func changes() -> AsyncStream<RegistrySnapshot> { changeBroadcast.subscribe() }

    public var sessions: [Session] { entries.values.map(\.session) }
    public func session(_ id: SessionID) -> Session? { entries[id]?.session }
    public var activeID: SessionID? { activeSessionID }

    // MARK: - Lifecycle

    public func start() async {
        await restore()
        let discoveryEvents = discovery.events
        tasks.append(Task { [weak self] in
            for await event in discoveryEvents {
                guard let self else { return }
                await self.handleDiscovery(event)
            }
        })
        if let probe {
            let outcomes = probe.outcomes()
            tasks.append(Task { [weak self] in
                for await outcome in outcomes {
                    guard let self else { return }
                    await self.handleProbe(outcome)
                }
            })
        }
        let settingsChanges = settings.changes()
        tasks.append(Task { [weak self] in
            for await snap in settingsChanges {
                guard let self else { return }
                await self.applySettings(snap)
            }
        })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await self.clock.sleep(for: 60)
                await self.sweep()
            }
        })
        discovery.start()
        await probe?.start()
        publishChange()
    }

    public func stop() async {
        for t in tasks { t.cancel() }
        tasks.removeAll()
        for entry in entries.values {
            for t in entry.tasks { t.cancel() }
        }
        discovery.stop()
        await probe?.stop()
        try? await store?.saveNow(persistedSnapshot())
    }

    private func applySettings(_ snap: AppSettingsSnapshot) {
        let rootsChanged = snap.extraTranscriptRoots != snapshot.extraTranscriptRoots
        snapshot = snap
        if rootsChanged {
            discovery.updateRoots(paths.allTranscriptRootCandidates(extra: snap.extraTranscriptRoots))
        }
        Task { await probe?.setInterval(snap.liveAgentsProbeInterval) }
    }

    // MARK: - Discovery

    private func handleDiscovery(_ event: SessionDiscovery.Event) async {
        switch event {
        case .mainTranscriptChanged(let url, let sessionID, let root):
            if entries[sessionID] == nil {
                await createSession(id: sessionID, transcriptURL: url, root: root, cwdHint: nil)
            }
            entries[sessionID]?.mainTailer?.wake()
        case .subagentTranscriptChanged(let url, let sessionID, let agentID, let root):
            if entries[sessionID] == nil {
                let mainURL = url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent("\(sessionID).jsonl")
                guard FileManager.default.fileExists(atPath: mainURL.path) else { return }
                await createSession(id: sessionID, transcriptURL: mainURL, root: root, cwdHint: nil)
            }
            if entries[sessionID]?.subagentTailers[agentID] == nil {
                attachSubagent(sessionID: sessionID, agentID: agentID, url: url)
            }
            entries[sessionID]?.subagentTailers[agentID]?.wake()
        case .rootUnavailable(let root):
            log.error("root unavailable: \(root.path)")
        }
    }

    private func createSession(id: SessionID, transcriptURL: URL, root: URL, cwdHint: String?, title hookTitle: String? = nil,
                               restored: PersistedSession? = nil) async {
        let folderEncoded = transcriptURL.deletingLastPathComponent().lastPathComponent
        let cwdPath = restored?.cwd ?? cwdHint ?? TranscriptTailer.peekCwd(url: transcriptURL)
            ?? ProjectPathEncoding.decodeBestEffort(folderEncoded)
        let cwd = URL(fileURLWithPath: cwdPath)
        let pref = await projectPrefs.entry(matching: cwd)?.1
        let aiTitle = restored == nil ? TranscriptTailer.peekTitle(url: transcriptURL) : nil
        var session = Session(
            id: id,
            title: "",
            cwd: cwd,
            transcriptURL: transcriptURL,
            root: root,
            entrypoint: restored?.entrypoint ?? .unknown,
            status: restored.map { $0.status == .ended ? .ended : .idle } ?? .idle,
            level: restored?.level ?? pref?.defaultLevel ?? snapshot.defaultLevelNewSession,
            colorIndex: Session.colorIndex(for: id),
            lastActivity: restored?.lastActivity ?? ((try? FileManager.default.attributesOfItem(atPath: transcriptURL.path)[.modificationDate] as? Date) ?? clock.now),
            unreadTurns: restored?.unreadTurns.map { UnreadTurn(turnID: $0.turnID, endedAt: $0.endedAt, finalAnswerText: $0.finalAnswerText) } ?? [],
            muted: pref?.muted ?? false
        )
        session.hasSeenAITitle = aiTitle != nil
        let assembler = TurnAssembler(sessionID: id, clock: clock)
        var entry = Entry(session: session, assembler: assembler)
        entry.aiTitle = aiTitle ?? restored?.title
        entry.hookTitle = hookTitle
        entries[id] = entry
        recomputeTitles()
        let tailer = TranscriptTailer(url: transcriptURL, sessionID: id, clock: clock)
        entries[id]?.mainTailer = tailer
        let stream = tailer.records
        entries[id]?.tasks.append(Task { [weak self] in
            for await output in stream {
                guard let self else { return }
                await self.ingestMain(sessionID: id, output: output)
            }
            await self?.tailerEnded(sessionID: id)
        })
        let asyncEvents = assembler.asyncEvents()
        entries[id]?.tasks.append(Task { [weak self] in
            for await events in asyncEvents {
                guard let self else { return }
                await self.apply(events, to: id)
            }
        })
        log.info("\(id.prefix(8)) sessionAppeared title=\(entries[id]?.session.title ?? "") cwd=\(cwd.path)")
        eventBroadcast.send(.sessionAppeared(id))
        publishChange()
        if restored == nil { discoverExistingSubagents(sessionID: id, transcriptURL: transcriptURL) }
    }

    private func discoverExistingSubagents(sessionID: SessionID, transcriptURL: URL) {
        let dir = transcriptURL.deletingPathExtension().appendingPathComponent("subagents")
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for url in items where url.pathExtension == "jsonl" {
            let agentID = String(url.lastPathComponent.dropFirst(6).dropLast(6))
            attachSubagent(sessionID: sessionID, agentID: agentID, url: url)
            entries[sessionID]?.subagentTailers[agentID]?.wake()
        }
    }

    private func attachSubagent(sessionID: SessionID, agentID: String, url: URL) {
        let tailer = TranscriptTailer(url: url, sessionID: sessionID, clock: clock)
        entries[sessionID]?.subagentTailers[agentID] = tailer
        let stream = tailer.records
        let metaURL = url.deletingPathExtension().appendingPathExtension("meta.json")
        entries[sessionID]?.tasks.append(Task { [weak self] in
            for await output in stream {
                guard let self else { return }
                await self.ingestSubagent(sessionID: sessionID, agentID: agentID, output: output, metaURL: metaURL)
            }
        })
    }

    private func ingestMain(sessionID: SessionID, output: TranscriptTailer.Output) async {
        guard let entry = entries[sessionID] else { return }
        let now = clock.now
        recordsInWindow.append(now)
        if case .unknown = output.record.payload { unknownInWindow.append(now) }
        if recordsInWindow.count > 5000 { recordsInWindow.removeFirst(recordsInWindow.count - 5000) }
        let events = await entry.assembler.ingest(output.record)
        touch(sessionID, at: output.record.envelope.timestamp ?? now)
        await apply(events, to: sessionID)
    }

    private func ingestSubagent(sessionID: SessionID, agentID: String, output: TranscriptTailer.Output, metaURL: URL) async {
        guard let entry = entries[sessionID] else { return }
        let events = await entry.assembler.ingestSubagent(output.record, agentID: agentID, metaURL: metaURL)
        entries[sessionID]?.session.subagentActivity = await entry.assembler.subagentActivity
        await apply(events, to: sessionID)
    }

    private func tailerEnded(sessionID: SessionID) {
        guard var entry = entries[sessionID], entry.session.status != .ended else { return }
        entry.session.status = .ended
        entries[sessionID] = entry
        eventBroadcast.send(.statusChanged(sessionID, .ended))
        eventBroadcast.send(.sessionEnded(sessionID))
        publishChange()
    }

    private func touch(_ id: SessionID, at: Date) {
        guard var entry = entries[id] else { return }
        if at > entry.session.lastActivity { entry.session.lastActivity = at }
        lastRecordAt[id] = clock.now
        if entry.session.status == .ended { entry.session.status = .idle }
        entries[id] = entry
    }

    // MARK: - Applying turn events

    private func apply(_ events: [TurnEvent], to id: SessionID) async {
        guard !events.isEmpty, entries[id] != nil else { return }
        var changed = false
        for event in events {
            guard var entry = entries[id] else { return }
            switch event {
            case .turnStarted(let turnID, let promptText, let at):
                entry.turns[turnID] = Turn(id: turnID, startedAt: at, promptText: promptText)
                entry.turnOrder.append(turnID)
                if entry.turnOrder.count > 50, let old = entry.turnOrder.first {
                    entry.turnOrder.removeFirst()
                    entry.turns.removeValue(forKey: old)
                }
                entry.session.currentTurn = turnID
                if !promptText.isEmpty { entry.session.lastPrompt = String(promptText.prefix(200)) }
                entries[id] = entry
                eventBroadcast.send(.turnStarted(id, turnID))
                changed = true
            case .item(let item):
                if item.category == .finalAnswer, let turnID = item.turnID {
                    entry.turns[turnID]?.finalAnswerTexts.append(item.text)
                    entries[id] = entry
                }
                if entry.session.muted, item.category != .event { break }
                eventBroadcast.send(.item(item))
            case .turnEnded(let turnID, let at, let reason):
                var text: String?
                if var turn = entry.turns[turnID] {
                    turn.endedAt = at
                    turn.reason = reason
                    entry.turns[turnID] = turn
                    text = turn.finalAnswerTexts.isEmpty ? nil : turn.finalAnswerText
                }
                if entry.session.currentTurn == turnID { entry.session.currentTurn = nil }
                let completed = reason == .completed || reason == .hookStop
                if completed, let text, !text.isEmpty,
                   (id != activeSessionID || entry.session.level == .quiet), !entry.session.muted {
                    entry.session.unreadTurns.append(UnreadTurn(turnID: turnID, endedAt: at, finalAnswerText: text))
                    if entry.session.unreadTurns.count > SessionStateCache.maxUnreadPerSession {
                        entry.session.unreadTurns.removeFirst(entry.session.unreadTurns.count - SessionStateCache.maxUnreadPerSession)
                    }
                }
                entries[id] = entry
                if !entry.session.muted || reason != .completed {
                    eventBroadcast.send(.turnEnded(id, turnID, finalAnswerText: text, reason: reason))
                }
                changed = true
            case .statusChanged(let status):
                if entry.session.status != status {
                    entry.session.status = status
                    entries[id] = entry
                    log.info("\(id.prefix(8)) status=\(status.rawValue)")
                    eventBroadcast.send(.statusChanged(id, status))
                    changed = true
                }
            case .titleChanged(let title):
                entry.aiTitle = title
                entry.session.hasSeenAITitle = true
                entries[id] = entry
                recomputeTitles()
                changed = true
            case .hookTitle(let title):
                entry.hookTitle = title
                entries[id] = entry
                recomputeTitles()
                changed = true
            case .permissionModeChanged(let mode):
                entry.session.permissionMode = mode
                entries[id] = entry
                changed = true
            case .cwdObserved(let cwd):
                if entry.session.cwd != cwd {
                    entry.session.cwd = cwd
                    entries[id] = entry
                    let pref = await projectPrefs.entry(matching: cwd)?.1
                    if let pref { entries[id]?.session.muted = pref.muted ?? false }
                    recomputeTitles()
                    refreshEntrypoint(id)
                    changed = true
                }
            case .entrypointObserved(let ep):
                entry.session.entrypoint = ep
                entries[id] = entry
                refreshEntrypoint(id)
                changed = true
            case .subagentStarted, .subagentFinished:
                changed = true
            case .sessionEnded:
                entry.session.status = .ended
                entries[id] = entry
                eventBroadcast.send(.statusChanged(id, .ended))
                eventBroadcast.send(.sessionEnded(id))
                changed = true
            case .sessionCleared:
                changed = true
            case .hooksObserved:
                hooksObservedAt = clock.now
            }
        }
        if changed {
            publishChange()
            scheduleSave()
        }
    }

    private func refreshEntrypoint(_ id: SessionID) {
        guard var entry = entries[id], entry.session.entrypoint == .cli || entry.session.entrypoint == .unknown else { return }
        let cwd = entry.session.cwd.path
        if cwd.contains("/.orca/") || snapshot.orcaWorktreeRoots.contains(where: { cwd.hasPrefix($0.path) }) {
            entry.session.entrypoint = .orca
            entries[id] = entry
        }
    }

    // MARK: - Naming

    private func recomputeTitles() {
        for (id, entry) in entries {
            var e = entry
            e.session.baseTitle = SessionNaming.baseTitle(aiTitle: e.aiTitle, hookTitle: e.hookTitle, probeName: e.session.probeName,
                                                           cwd: e.session.cwd, id: id)
            entries[id] = e
        }
        let titles = SessionNaming.disambiguate(entries.values.map(\.session))
        for (id, title) in titles {
            if entries[id]?.session.title != title {
                entries[id]?.session.title = title
                eventBroadcast.send(.titleChanged(id, title))
            }
        }
    }

    // MARK: - Hooks

    public func ingestHook(_ event: HookEvent) async {
        if entries[event.sessionID] == nil {
            guard let path = event.transcriptPath else {
                log.debug("hook \(event.name) for unknown session \(event.sessionID.prefix(8)) without transcript_path")
                return
            }
            let url = URL(fileURLWithPath: path)
            let root = url.deletingLastPathComponent().deletingLastPathComponent()
            await createSession(id: event.sessionID, transcriptURL: url, root: root, cwdHint: event.cwd,
                                title: event.string("session_title"))
            entries[event.sessionID]?.mainTailer?.wake()
        }
        guard let entry = entries[event.sessionID] else { return }
        log.info("\(event.sessionID.prefix(8)) hook \(event.name) received")
        hooksObservedAt = clock.now
        touch(event.sessionID, at: event.receivedAt)
        let events = await entry.assembler.ingestHook(event, title: entry.session.title)
        await apply(events, to: event.sessionID)
        if event.name == "SessionStart" || event.name == "UserPromptSubmit" {
            entries[event.sessionID]?.mainTailer?.wake()
        }
    }

    // MARK: - Probe

    private func handleProbe(_ outcome: LiveAgentsProbe.Outcome) async {
        lastProbeOutcome = outcome
        guard case .agents(let agents) = outcome else { return }
        let now = clock.now
        var seen = Set<SessionID>()
        for agent in agents {
            guard let id = agent.sessionId else { continue }
            seen.insert(id)
            if entries[id] == nil, let cwd = agent.cwd {
                for root in paths.transcriptRoots(extra: snapshot.extraTranscriptRoots) {
                    let url = root.appendingPathComponent(ProjectPathEncoding.encode(cwd)).appendingPathComponent("\(id).jsonl")
                    if FileManager.default.fileExists(atPath: url.path) {
                        await createSession(id: id, transcriptURL: url, root: root, cwdHint: cwd)
                        entries[id]?.mainTailer?.wake()
                        break
                    }
                }
            }
            guard var entry = entries[id] else { continue }
            entry.session.pid = agent.pid
            entry.session.probeName = agent.name
            entry.lastProbeSeen = now
            entry.missedProbes = 0
            if entry.session.status == .ended { entry.session.status = .idle }
            if let s = agent.status, entry.session.status == .idle || entry.session.status == .busy {
                switch s {
                case "busy": entry.session.status = .busy
                case "idle": if entry.session.currentTurn == nil { entry.session.status = .idle }
                case "waiting": entry.session.status = .waiting
                default: break
                }
            }
            entries[id] = entry
        }
        for (id, entry) in entries where !seen.contains(id) && entry.lastProbeSeen != nil && entry.session.status != .ended {
            var e = entry
            e.missedProbes += 1
            let quiet = (lastRecordAt[id].map { now.timeIntervalSince($0) } ?? .infinity) > 5
            if e.missedProbes >= 1, quiet {
                e.session.status = .ended
                e.session.pid = nil
                log.info("\(id.prefix(8)) ended (absent from probe)")
                eventBroadcast.send(.statusChanged(id, .ended))
                eventBroadcast.send(.sessionEnded(id))
            }
            entries[id] = e
        }
        recomputeTitles()
        publishChange()
    }

    // MARK: - Liveness

    public func sweep() async {
        let now = clock.now
        let expiry = TimeInterval(snapshot.sessionExpiryHours) * 3600
        for (id, entry) in entries {
            if now.timeIntervalSince(entry.session.lastActivity) > expiry {
                remove(id, reason: "expired")
                continue
            }
            await entry.mainTailer?.closeIfIdle(now: now)
            await entry.mainTailer?.checkMissing(now: now)
        }
        publishChange()
        scheduleSave()
    }

    private func remove(_ id: SessionID, reason: String) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        for t in entry.tasks { t.cancel() }
        entry.mainTailer?.close()
        for t in entry.subagentTailers.values { t.close() }
        if activeSessionID == id { activeSessionID = nil }
        log.info("\(id.prefix(8)) removed: \(reason)")
        eventBroadcast.send(.sessionRemoved(id))
        recomputeTitles()
    }

    // MARK: - Commands

    public func setLevel(_ level: SpeechLevel, for id: SessionID) {
        guard var entry = entries[id], entry.session.level != level else { return }
        let from = entry.session.level
        entry.session.level = level
        entries[id] = entry
        log.info("\(id.prefix(8)) level \(from.rawValue) → \(level.rawValue)")
        eventBroadcast.send(.levelChanged(id, from: from, to: level))
        publishChange()
        scheduleSave()
    }

    public func markTurnRead(_ turn: TurnID, in id: SessionID) {
        entries[id]?.session.unreadTurns.removeAll { $0.turnID == turn }
        publishChange()
        scheduleSave()
    }

    public func markAllRead(in id: SessionID) {
        entries[id]?.session.unreadTurns.removeAll()
        publishChange()
        scheduleSave()
    }

    /// Records the active session and applies the first-activation level (document 01 §6).
    public func setActive(_ id: SessionID?) async -> Session? {
        activeSessionID = id
        guard let id, var entry = entries[id] else {
            publishChange()
            scheduleSave()
            return nil
        }
        if !entry.activatedOnce {
            entry.activatedOnce = true
            let projectLevel = await projectPrefs.defaultLevel(forCwd: entry.session.cwd)
            let level = projectLevel ?? snapshot.defaultLevelActive
            if entry.session.level != level {
                let from = entry.session.level
                entry.session.level = level
                entries[id] = entry
                eventBroadcast.send(.levelChanged(id, from: from, to: level))
            }
        }
        entries[id] = entry
        publishChange()
        scheduleSave()
        return entry.session
    }

    public func updateStatus(_ id: SessionID, _ status: SessionStatus) {
        guard var entry = entries[id], entry.session.status != status else { return }
        entry.session.status = status
        entries[id] = entry
        eventBroadcast.send(.statusChanged(id, status))
        publishChange()
    }

    /// Query resolution for the CLI (document 04 §7.4).
    public func resolve(_ query: String) -> Result<Session, MessageError> {
        let live = entries.values.map(\.session).filter(\.isLive)
        let all = entries.values.map(\.session)
        var q = query
        if q.hasPrefix("id:") {
            q = String(q.dropFirst(3))
            if let s = entries[q]?.session { return .success(s) }
            return .failure(MessageError("no session with id \(q)"))
        }
        if let s = entries[q]?.session { return .success(s) }
        func unique(_ candidates: [Session]) -> Result<Session, MessageError>? {
            if candidates.count == 1 { return .success(candidates[0]) }
            if candidates.count > 1 {
                let list = candidates.map { "\($0.title) (\($0.id.prefix(8)))" }.joined(separator: ", ")
                return .failure(MessageError("ambiguous: \(list)"))
            }
            return nil
        }
        let pool = live.isEmpty ? all : live
        if q.count >= 4, let r = unique(pool.filter { $0.id.hasPrefix(q) }) { return r }
        if let r = unique(pool.filter { $0.title.lowercased() == q.lowercased() }) { return r }
        if let r = unique(pool.filter { $0.title.lowercased().contains(q.lowercased()) }) { return r }
        if q.hasPrefix("/") || q.hasPrefix("~") {
            let path = ProjectPreferences.canonical(URL(fileURLWithPath: (q as NSString).expandingTildeInPath))
            if let r = unique(pool.filter { ProjectPreferences.canonical($0.cwd) == path }) { return r }
            let ancestors = pool.filter { path.hasPrefix(ProjectPreferences.canonical($0.cwd) + "/") }
            if let deepest = ancestors.max(by: { $0.cwd.path.count < $1.cwd.path.count }) { return .success(deepest) }
        }
        return .failure(MessageError("no session matches \(query)"))
    }

    public func summaries() -> [SessionSummary] {
        entries.values.map { $0.session.summary(active: $0.session.id == activeSessionID) }
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    public func unknownRecordRatio() -> Double {
        let cutoff = clock.now.addingTimeInterval(-3600)
        let records = recordsInWindow.filter { $0 > cutoff }.count
        let unknown = unknownInWindow.filter { $0 > cutoff }.count
        guard records > 0 else { return 0 }
        return Double(unknown) / Double(records)
    }

    public func turns(for id: SessionID) -> [Turn] {
        guard let entry = entries[id] else { return [] }
        return entry.turnOrder.compactMap { entry.turns[$0] }
    }

    /// Diagnostics: counts of live sessions by status.
    public func counts() -> (live: Int, busy: Int, waiting: Int, idle: Int, ended: Int) {
        var c = (live: 0, busy: 0, waiting: 0, idle: 0, ended: 0)
        for e in entries.values {
            switch e.session.status {
            case .busy: c.busy += 1; c.live += 1
            case .waiting: c.waiting += 1; c.live += 1
            case .idle: c.idle += 1; c.live += 1
            case .ended: c.ended += 1
            }
        }
        return c
    }

    /// Test/diagnostic hook: injects a transcript record as if tailed from the main transcript.
    public func inject(record: TranscriptRecord, into id: SessionID, transcriptURL: URL? = nil, root: URL? = nil) async {
        if entries[id] == nil {
            let url = transcriptURL ?? URL(fileURLWithPath: "/tmp/\(id).jsonl")
            await createSession(id: id, transcriptURL: url, root: root ?? url.deletingLastPathComponent(), cwdHint: record.envelope.cwd)
        }
        await ingestMain(sessionID: id, output: TranscriptTailer.Output(record: record, fileOffset: 0))
    }

    // MARK: - Persistence

    private func publishChange() {
        changeBroadcast.send(RegistrySnapshot(sessions: sessions, activeSessionID: activeSessionID))
    }

    private func scheduleSave() {
        guard let store else { return }
        let snap = persistedSnapshot()
        Task { await store.scheduleSave(snap) }
    }

    public func saveNow() async {
        try? await store?.saveNow(persistedSnapshot())
    }

    private func persistedSnapshot() -> SessionStateCache.Snapshot {
        let persisted = entries.values.map { e in
            PersistedSession(id: e.session.id, title: e.session.baseTitle, cwd: e.session.cwd.path,
                             transcriptPath: e.session.transcriptURL.path, root: e.session.root.path,
                             entrypoint: e.session.entrypoint, level: e.session.level, colorIndex: e.session.colorIndex,
                             lastActivity: e.session.lastActivity, status: e.session.status,
                             unreadTurns: e.session.unreadTurns.map { PersistedUnreadTurn(turnID: $0.turnID, endedAt: $0.endedAt, finalAnswerText: $0.finalAnswerText) })
        }
        return SessionStateCache.Snapshot(savedAt: clock.now, activeSessionID: activeSessionID, sessions: persisted)
    }

    private func restore() async {
        guard let store, let snap = try? await store.load() else { return }
        let expiry = TimeInterval(snapshot.sessionExpiryHours) * 3600
        let now = clock.now
        for ps in snap.sessions {
            guard now.timeIntervalSince(ps.lastActivity) <= expiry,
                  FileManager.default.fileExists(atPath: ps.transcriptPath) else { continue }
            await createSession(id: ps.id, transcriptURL: URL(fileURLWithPath: ps.transcriptPath),
                                root: URL(fileURLWithPath: ps.root), cwdHint: ps.cwd, restored: ps)
            entries[ps.id]?.mainTailer?.wake()
        }
        if let active = snap.activeSessionID, entries[active] != nil {
            activeSessionID = active
            entries[active]?.activatedOnce = true
            log.info("restored active session \(active.prefix(8))")
        }
        log.info("restored \(entries.count) sessions")
    }
}
