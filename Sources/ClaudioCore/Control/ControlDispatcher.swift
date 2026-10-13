import Foundation

/// App-level operations the dispatcher cannot perform from Core (symlinks, login item, voices, quit).
public protocol ControlHostDelegate: Sendable {
    func linkCLI(_ create: Bool) async throws -> String
    func isCLILinked() async -> Bool
    func voices(backend: BackendID?) async throws -> [Voice]
    func doctorChecks() async -> [DoctorCheck]
    func activateUI() async
    func quit() async
    func currentVoiceName() async -> String
    func bench(backend: String?, fixture: String?, runs: Int) async -> String
}

/// Routes `ControlRequest`s to the registry, arbiter, pipeline and settings (document 04 §5.5).
public final class ControlDispatcher: Sendable {
    private let registry: SessionRegistry
    private let arbiter: Arbiter
    private let pipeline: SpeechPipeline
    private let settings: AppSettings
    private let hookInstaller: HookInstaller
    private let skillInstaller: SkillInstaller
    private let host: any ControlHostDelegate
    private let paths: Paths
    private let clock: any ClaudioClock
    private let startedAt: Date
    private let log = Log.control

    public init(registry: SessionRegistry, arbiter: Arbiter, pipeline: SpeechPipeline, settings: AppSettings,
                hookInstaller: HookInstaller, skillInstaller: SkillInstaller, host: any ControlHostDelegate, paths: Paths,
                clock: any ClaudioClock = SystemClock()) {
        self.registry = registry
        self.arbiter = arbiter
        self.pipeline = pipeline
        self.settings = settings
        self.hookInstaller = hookInstaller
        self.skillInstaller = skillInstaller
        self.host = host
        self.paths = paths
        self.clock = clock
        self.startedAt = clock.now
    }

    public func handle(_ envelope: ControlEnvelope, writer: ResponseWriter) async {
        if envelope.kind == "hook" {
            guard let event = HookEvent.decode(envelope: envelope, now: clock.now) else {
                log.debug("undecodable hook envelope")
                return
            }
            await registry.ingestHook(event)
            return
        }
        guard let request = envelope.request else {
            writer.write(.failure("missing request"))
            return
        }
        do {
            let result = try await dispatch(request, writer: writer)
            if let result { writer.write(.success(result)) }
        } catch {
            writer.write(.failure(String(describing: error)))
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    public func dispatch(_ request: ControlRequest, writer: ResponseWriter) async throws -> ControlResult? {
        switch request {
        case .ping:
            return ControlResult.none
        case .activate:
            await host.activateUI()
            return ControlResult.none
        case .quit:
            await host.quit()
            return ControlResult.none
        case .version:
            return .text(BuildInfo.versionString)
        case .status:
            return .status(await statusReport())
        case .sessions:
            return .sessions(await registry.summaries())
        case .switch(let query):
            guard let query else { throw MessageError("no session query and none could be inferred") }
            let session = try await registry.resolve(query).get()
            await arbiter.activate(session.id)
            let updated = await registry.session(session.id) ?? session
            return .session(updated.summary(active: true))
        case .level(let level, let query):
            let target: Session
            if let query, case .success(let s) = await registry.resolve(query) {
                target = s
            } else if let active = await arbiter.activeSessionID, let s = await registry.session(active) {
                target = s
            } else {
                throw MessageError("no session matches and no active session")
            }
            await registry.setLevel(level, for: target.id)
            let updated = await registry.session(target.id) ?? target
            return .session(updated.summary(active: updated.id == (await arbiter.activeSessionID)))
        case .pause:
            await arbiter.pause()
            return .text("Paused")
        case .resume:
            await arbiter.resume()
            return .text("Resumed")
        case .toggle:
            await arbiter.togglePause()
            return .text(await arbiter.mode == .paused ? "Paused" : "Resumed")
        case .skip:
            await arbiter.skipSegment()
            return .text("Skipped")
        case .live:
            await arbiter.skipToLive()
            return .text("Live")
        case .mute(let muted):
            await arbiter.setEventsMuted(muted)
            return .text(muted ? "Events muted" : "Events on")
        case .say(let text):
            await arbiter.say(text)
            return ControlResult.none
        case .hooksStatus:
            return .hooks(hookInstaller.status())
        case .hooksInstall:
            try hookInstaller.install()
            settings.hooksEnabled = true
            return .hooks(hookInstaller.status())
        case .hooksUninstall:
            try hookInstaller.uninstall()
            settings.hooksEnabled = false
            return .hooks(hookInstaller.status())
        case .link(let create):
            return .text(try await host.linkCLI(create))
        case .skill(let install):
            if install {
                try skillInstaller.install()
                return .text("Installed \(skillInstaller.skillDirectory.path.abbreviatingHome)")
            }
            try skillInstaller.uninstall()
            return .text("Removed \(skillInstaller.skillDirectory.path.abbreviatingHome)")
        case .render(let markdown):
            let segments = await pipeline.render(markdown)
            return .segments(segments.map { SegmentSummary(kind: $0.kind.rawValue, text: $0.text) })
        case .subscribe(let kind, let query):
            try await subscribe(kind, query: query, writer: writer)
            return nil
        case .bench(let backend, let fixture, let runs):
            return .text(await host.bench(backend: backend, fixture: fixture, runs: runs))
        case .doctor:
            return .doctor(await doctor())
        case .dumpState:
            return .text(await dumpState())
        case .voices(let backend):
            let voices = try await host.voices(backend: backend)
            return .voices(voices.map(\.summary))
        case .speakSession(let query, let level):
            let session = try await registry.resolve(query).get()
            await registry.setLevel(level, for: session.id)
            await arbiter.activate(session.id)
            return .session((await registry.session(session.id) ?? session).summary(active: true))
        }
    }

    private func statusReport() async -> StatusReport {
        let arbiterState = await arbiter.currentState
        let pipelineState = await pipeline.currentState
        let playback: String = switch arbiterState.mode {
        case .paused: "paused"
        case .catchingUp: "catchingUp"
        default: pipelineState.mode == .speaking ? "speaking" : "idle"
        }
        var active: SessionSummary?
        if let id = arbiterState.activeSessionID, let s = await registry.session(id) { active = s.summary(active: true) }
        var metrics = await pipeline.metrics()
        metrics["unknownRecordRatio"] = await registry.unknownRecordRatio()
        metrics["pipeline.queuedSeconds"] = pipelineState.queuedSeconds
        let counts = await registry.counts()
        return StatusReport(version: BuildInfo.versionString, playback: playback, activeSession: active,
                            backend: settings.backendID, voice: settings.voiceID, rate: settings.rate,
                            eventsMuted: !settings.eventsEnabled, hooks: hookInstaller.status(), sessionsLive: counts.live,
                            metrics: metrics, socketPath: paths.controlSocket.path, pid: ProcessInfo.processInfo.processIdentifier,
                            uptimeSeconds: clock.now.timeIntervalSince(startedAt))
    }

    private func subscribe(_ kind: SubscriptionKind, query: String?, writer: ResponseWriter) async throws {
        var filterID: SessionID?
        if let query { filterID = try await registry.resolve(query).get().id }
        let stream = registry.events()
        for await event in stream {
            if writer.isClosed { return }
            switch (kind, event) {
            case (.items, .item(let item)):
                if let filterID, item.sessionID != filterID { continue }
                let session = await registry.session(item.sessionID)
                let level = session?.level ?? .answers
                let active = await arbiter.activeSessionID == item.sessionID
                let filter = ContentFilter(snapshot: settings.snapshot)
                let filtered = !(active && filter.includes(item, at: level)) && item.category != .event
                let summary = SpeechItemSummary(session: item.sessionID, turn: item.turnID, category: item.category,
                                                text: String(item.text.prefix(200)), filtered: filtered, timestamp: item.timestamp)
                if !writer.write(.success(.item(summary))) { return }
            case (.rawRecords, _):
                let text = String(describing: event)
                if !writer.write(.success(.record(type: "event", uuid: nil, summary: String(text.prefix(200))))) { return }
            default:
                continue
            }
        }
    }

    private func doctor() async -> [DoctorCheck] {
        var checks: [DoctorCheck] = []
        let roots = paths.transcriptRoots(extra: settings.extraTranscriptRoots)
        if roots.isEmpty {
            checks.append(DoctorCheck(name: "Roots", state: "fail", detail: "no transcript root exists; expected \(paths.defaultTranscriptRoot.path)"))
        } else {
            let projects = (try? FileManager.default.contentsOfDirectory(atPath: roots[0].path))?.count ?? 0
            checks.append(DoctorCheck(name: "Roots", state: projects > 0 ? "pass" : "warn",
                                      detail: "\(roots.count) root(s); \(projects) project dirs under \(roots[0].path.abbreviatingHome)"))
        }
        switch await registry.lastProbeOutcome {
        case .agents(let a): checks.append(DoctorCheck(name: "claude CLI", state: "pass", detail: "claude agents --json lists \(a.count) agent(s)"))
        case .failed(let r): checks.append(DoctorCheck(name: "claude CLI", state: "warn", detail: "probe failing: \(r)"))
        case nil: checks.append(DoctorCheck(name: "claude CLI", state: "warn", detail: "no probe result yet"))
        }
        let ratio = await registry.unknownRecordRatio()
        checks.append(DoctorCheck(name: "Transcript schema", state: ratio < 0.05 ? "pass" : (ratio < 0.2 ? "warn" : "fail"),
                                  detail: String(format: "%.1f%% unknown record types in the last hour", ratio * 100)))
        let hooks = hookInstaller.status()
        let hooksState: String
        switch hooks {
        case .notInstalled: hooksState = settings.hooksEnabled ? "warn" : "pass"
        case .installed: hooksState = "pass"
        case .partial, .installedElsewhere: hooksState = "warn"
        case .settingsUnreadable: hooksState = "fail"
        }
        checks.append(DoctorCheck(name: "Hooks", state: hooksState, detail: hooks.humanDescription))
        let settingsExists = FileManager.default.fileExists(atPath: paths.claudeSettingsFile.path)
        checks.append(DoctorCheck(name: "settings.json", state: settingsExists ? "pass" : "warn",
                                  detail: settingsExists ? "parses" : "missing"))
        let sockPath = paths.controlSocket.path
        let mode = (try? FileManager.default.attributesOfItem(atPath: sockPath)[.posixPermissions] as? Int) ?? 0
        checks.append(DoctorCheck(name: "Socket permissions", state: mode == 0o600 ? "pass" : "fail", detail: String(format: "mode %o at %@", mode, sockPath.abbreviatingHome)))
        let writable = FileManager.default.isWritableFile(atPath: paths.applicationSupport.path)
        checks.append(DoctorCheck(name: "Disk", state: writable ? "pass" : "fail", detail: paths.applicationSupport.path.abbreviatingHome))
        checks.append(contentsOf: await host.doctorChecks())
        return checks
    }

    private func dumpState() async -> String {
        var lines: [String] = []
        let arbiterState = await arbiter.currentState
        lines.append("arbiter mode=\(arbiterState.mode.label) active=\(arbiterState.activeSessionID ?? "none")")
        for s in await registry.sessions.sorted(by: { $0.lastActivity > $1.lastActivity }) {
            lines.append("session \(s.id.prefix(8)) \"\(s.title)\" status=\(s.status.rawValue) level=\(s.level.rawValue) unread=\(s.unreadTurns.count) cwd=\(s.cwd.path.abbreviatingHome) pid=\(s.pid.map(String.init) ?? "-")")
            for t in await registry.turns(for: s.id) {
                lines.append("  turn \(t.id.prefix(8)) started=\(TranscriptParser.formatDate(t.startedAt)) ended=\(t.endedAt.map(TranscriptParser.formatDate) ?? "-") finals=\(t.finalAnswerTexts.count) prompt=\(String(t.promptText.prefix(60)))")
            }
        }
        for seg in await pipeline.queueSnapshot() {
            lines.append("segment \(seg.id.uuidString.prefix(8)) state=\(seg.state.rawValue) session=\(seg.item.sessionID.prefix(8)) category=\(seg.item.category.rawValue) text=\(String(seg.segment.text.prefix(60)))")
        }
        lines.append("settings \(settings.snapshot)")
        return lines.joined(separator: "\n")
    }
}
