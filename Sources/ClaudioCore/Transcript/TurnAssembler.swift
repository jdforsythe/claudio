import Foundation

public enum TurnEvent: Sendable, Equatable {
    case turnStarted(TurnID, promptText: String, at: Date)
    case item(SpeechItem)
    case turnEnded(TurnID, at: Date, reason: TurnEndReason)
    case statusChanged(SessionStatus)
    case titleChanged(String)
    case permissionModeChanged(String)
    case cwdObserved(URL)
    case entrypointObserved(SessionEntrypoint)
    case subagentStarted(agentID: String, description: String)
    case subagentFinished(agentID: String, description: String)
    case sessionEnded
    case sessionCleared
    case hookTitle(String)
    case hooksObserved  // our own hook ran, per a hook_success attachment
}

/// Records → turns and speech items (document 03 §6, §7, §9).
public actor TurnAssembler {
    public static let pendingTimeout: TimeInterval = 1.5
    public static let startDedupWindow: TimeInterval = 10
    public static let endDedupWindow: TimeInterval = 30
    public static let hookAnswerWindow: TimeInterval = 30
    public static let seenCapacity = 4096

    private struct PendingText {
        let record: TranscriptRecord
        let text: String
        let messageID: String
    }

    private let sessionID: SessionID
    private let clock: any ClaudioClock
    private let log: LogChannel
    private let summarizer = ToolCallSummarizer()
    private var deduper = ToolCallDeduper()

    public private(set) var openTurn: TurnID?
    private var pendingTexts: [PendingText] = []
    private var pendingTask: Task<Void, Never>?
    private var seen: [String] = []
    private var seenSet = Set<String>()
    private var toolNamesByUseID: [String: String] = [:]
    private var pendingAgentDescriptions: [(toolUseID: String, promptID: TurnID?, description: String)] = []
    private var subagentDescriptions: [String: String] = [:]
    private var subagentStartAnnounced = Set<String>()
    private var subagentFinished = Set<String>()
    private var subagentToolUseCount: [String: Int] = [:]
    private var cwdSeen = Set<String>()
    private var entrypointSeen = false
    private var hasAITitle = false
    private var currentMessageID: String?
    private var lastEndedTurn: TurnID?
    // Reconciliation windows (document 03 §9)
    private var turnStartTimes: [TurnID: Date] = [:]
    private var turnEndTimes: [TurnID: Date] = [:]
    private var hookFinalAnswers: [TurnID: (text: String, at: Date)] = [:]
    private var transcriptFinalAnswers: [TurnID: [String]] = [:]
    private var orphanCounter = 0
    private var turnAliases: [TurnID: TurnID] = [:]
    private var recentHookEnd: (turn: TurnID, at: Date)?
    private var openTurnSource: String?
    public static let crossSourceAliasWindow: TimeInterval = 3
    private let broadcast = Broadcast<[TurnEvent]>()
    public private(set) var subagentActivity = 0

    public init(sessionID: SessionID, clock: any ClaudioClock = SystemClock(), log: LogChannel = Log.sessions) {
        self.sessionID = sessionID
        self.clock = clock
        self.log = log
    }

    /// Events produced by timers (pending-text timeout) rather than by `ingest`.
    public nonisolated func asyncEvents() -> AsyncStream<[TurnEvent]> { broadcast.subscribe() }

    // MARK: - Main transcript

    public func ingest(_ record: TranscriptRecord) -> [TurnEvent] {
        var events: [TurnEvent] = []
        if let uuid = record.envelope.uuid, !markSeen(uuid) {
            log.debug("dropped duplicate record \(uuid.prefix(8)) for \(sessionID.prefix(8))")
            return []
        }
        if record.envelope.isSidechain { return [] }
        let now = record.envelope.timestamp ?? clock.now
        events.append(contentsOf: envelopeEvents(record))

        switch record.payload {
        case .humanPrompt(let text, let originKind, let promptSource, let turnOrigin):
            guard Self.isHumanPrompt(record: record, originKind: originKind, promptSource: promptSource,
                                     turnOrigin: turnOrigin) else {
                log.debug("non-human prompt ignored (source=\(promptSource ?? "-") origin=\(originKind ?? "-"))")
                break
            }
            let turnID = record.envelope.promptID ?? "prompt-\(record.envelope.uuid ?? UUID().uuidString)"
            events.append(contentsOf: startTurn(turnID, promptText: text, at: now, source: "transcript"))

        case .toolResult(let toolUseID, let isError, let summary):
            if isError || Self.looksLikeError(summary) {
                let name = toolNamesByUseID[toolUseID] ?? "Tool"
                let firstLine = (summary ?? "").split(separator: "\n").first.map(String.init) ?? "error"
                let text = "\(name) failed: \(firstLine.truncated(to: 120))"
                events.append(.item(makeItem(.toolResult, text: text, record: record, at: now)))
            }
            events.append(.statusChanged(.busy))

        case .assistantText(let messageID, _, _, let stopReason, let text):
            events.append(contentsOf: handleMessageBoundary(messageID))
            currentMessageID = messageID
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { break }
            events.append(contentsOf: ensureOpenTurn(messageID: messageID, at: now))
            switch stopReason {
            case "end_turn", "max_tokens", "stop_sequence":
                events.append(contentsOf: emitFinal(text: text, record: record, at: now))
            case "tool_use":
                events.append(.item(makeItem(.narration, text: text, record: record, at: now)))
            default:
                pendingTexts.append(PendingText(record: record, text: text, messageID: messageID))
                schedulePendingTimeout()
            }

        case .assistantThinking(let messageID, _, let text):
            events.append(contentsOf: handleMessageBoundary(messageID))
            currentMessageID = messageID
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { break }
            events.append(contentsOf: ensureOpenTurn(messageID: messageID, at: now))
            events.append(.item(makeItem(.thinking, text: text, record: record, at: now)))

        case .assistantToolUse(let messageID, _, let toolUseID, let name, let input):
            if messageID == currentMessageID || currentMessageID == nil {
                // Tertiary rule: pending texts of the same message become narration.
                let same = pendingTexts.filter { $0.messageID == messageID }
                pendingTexts.removeAll { $0.messageID == messageID }
                for p in same { events.append(.item(makeItem(.narration, text: p.text, record: p.record, at: now))) }
            } else {
                events.append(contentsOf: handleMessageBoundary(messageID))
            }
            currentMessageID = messageID
            events.append(contentsOf: ensureOpenTurn(messageID: messageID, at: now))
            toolNamesByUseID[toolUseID] = name
            if name == "Task" || name == "Agent" {
                let description = input["description"]?.stringValue ?? input["subagent_type"]?.stringValue ?? "agent"
                pendingAgentDescriptions.append((toolUseID, openTurn, description))
            }
            if let summary = summarizer.summarize(toolName: name, input: input), deduper.accept(summary, at: now) {
                events.append(.item(makeItem(.toolCall, text: summary, record: record, at: now)))
            }
            if name == "AskUserQuestion" { events.append(.statusChanged(.waiting)) }

        case .turnDuration:
            events.append(contentsOf: flushPending(as: .finalAnswer, at: now))
            if let open = openTurn {
                events.append(contentsOf: endTurn(open, at: now, reason: .completed, source: "transcript"))
            }

        case .aiTitle(let title):
            if !title.isEmpty {
                hasAITitle = true
                events.append(.titleChanged(title))
            }

        case .permissionMode(let mode):
            events.append(.permissionModeChanged(mode))

        case .hookAttachment(let hookEvent, let command, _):
            if command.contains("claudio hook") {
                log.debug("own hook ran: \(hookEvent)")
                events.append(.hooksObserved)
            }

        case .stopHookSummary, .ignored:
            break

        case .unknown(let type):
            log.debug("unknown record type \(type)")
        }
        return events
    }

    // MARK: - Subagents

    public func ingestSubagent(_ record: TranscriptRecord, agentID: String, metaURL: URL?) -> [TurnEvent] {
        var events: [TurnEvent] = []
        if let uuid = record.envelope.uuid, !markSeen("agent:" + uuid) { return [] }
        if subagentDescriptions[agentID] == nil {
            let description = Self.readMetaDescription(metaURL)
                ?? bindPendingAgentDescription(promptID: record.envelope.promptID)
                ?? Self.promptDescription(record)
                ?? "agent"
            subagentDescriptions[agentID] = description
            if !subagentStartAnnounced.contains(agentID), pendingAgentDescriptions.isEmpty {
                subagentStartAnnounced.insert(agentID)
                events.append(.subagentStarted(agentID: agentID, description: description))
            } else {
                subagentStartAnnounced.insert(agentID)
            }
        }
        switch record.payload {
        case .assistantToolUse:
            subagentToolUseCount[agentID, default: 0] += 1
            subagentActivity += 1
        case .turnDuration:
            events.append(contentsOf: finishSubagent(agentID, at: record.envelope.timestamp ?? clock.now))
        default:
            break
        }
        return events
    }

    private func finishSubagent(_ agentID: String, at: Date) -> [TurnEvent] {
        guard !subagentFinished.contains(agentID) else {
            log.debug("dropped duplicate subagent finish for \(agentID)")
            return []
        }
        subagentFinished.insert(agentID)
        let description = subagentDescriptions[agentID] ?? "agent"
        let item = SpeechItem(sessionID: sessionID, turnID: openTurn, category: .toolCall,
                              text: ToolCallSummarizer.postProcess("Agent finished: " + description),
                              sourceUUID: "agent:" + agentID, timestamp: at)
        return [.subagentFinished(agentID: agentID, description: description), .item(item)]
    }

    private func bindPendingAgentDescription(promptID: TurnID?) -> String? {
        if let idx = pendingAgentDescriptions.firstIndex(where: { $0.promptID == promptID || promptID == nil }) {
            return pendingAgentDescriptions.remove(at: idx).description
        }
        if !pendingAgentDescriptions.isEmpty { return pendingAgentDescriptions.removeFirst().description }
        return nil
    }

    static func readMetaDescription(_ url: URL?) -> String? {
        guard let url, let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let d = obj["description"] as? String, !d.isEmpty { return d }
        if let t = obj["agentType"] as? String, !t.isEmpty { return t }
        return nil
    }

    static func promptDescription(_ record: TranscriptRecord) -> String? {
        if case .humanPrompt(let text, _, _, _) = record.payload, !text.isEmpty {
            return String(text.prefix(80))
        }
        return nil
    }

    // MARK: - Hooks (document 04 §6)

    public func ingestHook(_ event: HookEvent, title: String) -> [TurnEvent] {
        var events: [TurnEvent] = []
        let now = event.receivedAt
        switch event.name {
        case "UserPromptSubmit":
            if event.bool("is_continuation") == true { return [] }
            let turnID = event.promptID ?? "hook-prompt-\(UUID().uuidString)"
            events.append(contentsOf: startTurn(turnID, promptText: event.string("prompt_text") ?? event.string("prompt") ?? "",
                                                at: now, source: "hook"))
        case "Stop":
            let turnID = openTurn ?? event.promptID ?? lastEndedTurn ?? "hook-stop"
            if let message = event.string("last_assistant_message"), !message.isEmpty {
                events.append(contentsOf: hookFinalAnswer(message, turnID: turnID, at: now))
            }
            events.append(contentsOf: flushPending(as: .finalAnswer, at: now))
            events.append(contentsOf: endTurn(turnID, at: now, reason: .hookStop, source: "hook"))
        case "StopFailure":
            let turnID = openTurn ?? event.promptID ?? "hook-stop-failure"
            events.append(contentsOf: endTurn(turnID, at: now, reason: .hookStopFailure, source: "hook"))
            let reason = Self.humanise(errorType: event.string("error_type") ?? "error")
            events.append(.item(eventItem("\(title) hit an error: \(reason).", at: now)))
        case "SubagentStop":
            guard let agentID = event.agentID ?? event.string("agent_id") else { return [] }
            if subagentDescriptions[agentID] == nil {
                subagentDescriptions[agentID] = bindPendingAgentDescription(promptID: event.promptID)
                    ?? event.agentType ?? "agent"
            }
            events.append(contentsOf: finishSubagent(agentID, at: now))
        case "Notification":
            switch event.string("notification_type") {
            case "permission_prompt":
                events.append(.statusChanged(.waiting))
                events.append(.item(eventItem("\(title) needs permission.", at: now)))
            case "idle_prompt":
                events.append(.statusChanged(.waiting))
                events.append(.item(eventItem("\(title) is waiting.", at: now)))
            case "agent_needs_input":
                events.append(.statusChanged(.waiting))
                events.append(.item(eventItem("\(title) needs input.", at: now)))
            case "agent_completed":
                if let open = openTurn {
                    events.append(contentsOf: endTurn(open, at: now, reason: .hookStop, source: "hook:agent_completed"))
                }
            default:
                break
            }
        case "SessionStart":
            if let t = event.string("session_title"), !t.isEmpty, !hasAITitle { events.append(.hookTitle(t)) }
            if event.string("source") == "clear", let open = openTurn {
                events.append(contentsOf: endTurn(open, at: now, reason: .sessionEnded, source: "hook"))
                events.append(.sessionCleared)
            }
        case "SessionEnd":
            let reason = event.string("reason") ?? ""
            if reason == "clear" || reason == "resume" {
                if let open = openTurn { events.append(contentsOf: endTurn(open, at: now, reason: .sessionEnded, source: "hook")) }
                events.append(.statusChanged(.idle))
            } else {
                if let open = openTurn { events.append(contentsOf: endTurn(open, at: now, reason: .sessionEnded, source: "hook")) }
                events.append(.sessionEnded)
            }
        default:
            log.debug("hook \(event.name) dropped (not handled)")
        }
        return events
    }

    private func hookFinalAnswer(_ message: String, turnID: TurnID, at: Date) -> [TurnEvent] {
        let normalizedHook = message.whitespaceNormalized
        if let texts = transcriptFinalAnswers[turnID] {
            for t in texts {
                let n = t.whitespaceNormalized
                if !n.isEmpty, normalizedHook.hasPrefix(n) || n == normalizedHook || n.hasPrefix(normalizedHook) {
                    log.debug("dedup: hook Stop matched transcript finalAnswer turn=\(turnID.prefix(8))")
                    return []
                }
            }
        }
        hookFinalAnswers[turnID] = (normalizedHook, clock.now)
        let item = SpeechItem(sessionID: sessionID, turnID: turnID, category: .finalAnswer, text: message,
                              sourceUUID: "hook:" + turnID, timestamp: at)
        log.info("\(sessionID.prefix(8)) finalAnswer from hook turn=\(turnID.prefix(8))")
        return [.item(item)]
    }

    public static func humanise(errorType: String) -> String {
        switch errorType {
        case "rate_limit": "rate limit"
        case "overloaded": "overloaded API"
        case "authentication_failed": "authentication failure"
        case "server_error": "server error"
        default: errorType.replacingOccurrences(of: "_", with: " ")
        }
    }

    // MARK: - Turn lifecycle

    private func startTurn(_ turnID: TurnID, promptText: String, at: Date, source: String) -> [TurnEvent] {
        let arrival = clock.now
        if let started = turnStartTimes[turnID], arrival.timeIntervalSince(started) < Self.startDedupWindow {
            log.debug("dropped duplicate turn start for \(turnID.prefix(8)) from \(source)")
            return []
        }
        if let open = openTurn, open != turnID, let started = turnStartTimes[open], openTurnSource != source,
           arrival.timeIntervalSince(started) < Self.crossSourceAliasWindow {
            log.debug("aliasing turn start \(turnID.prefix(8)) from \(source) to open turn \(open.prefix(8))")
            turnAliases[turnID] = open
            turnStartTimes[turnID] = arrival
            return []
        }
        var events: [TurnEvent] = []
        events.append(contentsOf: flushPending(as: .finalAnswer, at: at))
        if let open = openTurn, open != turnID {
            events.append(contentsOf: endTurn(open, at: at, reason: .interruptedByPrompt, source: source))
        }
        turnStartTimes[turnID] = arrival
        openTurn = turnID
        openTurnSource = source
        recentHookEnd = nil
        currentMessageID = nil
        log.info("\(sessionID.prefix(8)) turnStarted \(turnID.prefix(8)) via \(source)")
        events.append(.turnStarted(turnID, promptText: promptText, at: at))
        events.append(.statusChanged(.busy))
        return events
    }

    private func endTurn(_ requestedTurnID: TurnID, at: Date, reason: TurnEndReason, source: String) -> [TurnEvent] {
        let turnID = turnAliases[requestedTurnID] ?? requestedTurnID
        let arrival = clock.now
        if let ended = turnEndTimes[turnID], arrival.timeIntervalSince(ended) < Self.endDedupWindow {
            log.debug("dropped duplicate turn end for \(turnID.prefix(8)) from \(source)")
            if openTurn == turnID { openTurn = nil }
            return []
        }
        turnEndTimes[turnID] = arrival
        if openTurn == turnID { openTurn = nil }
        lastEndedTurn = turnID
        if reason == .hookStop { recentHookEnd = (turnID, arrival) }
        currentMessageID = nil
        log.info("\(sessionID.prefix(8)) turnEnded \(turnID.prefix(8)) reason=\(reason.rawValue) via \(source)")
        var events: [TurnEvent] = [.turnEnded(turnID, at: at, reason: reason)]
        if reason != .interruptedByPrompt { events.append(.statusChanged(.idle)) }
        return events
    }

    private func ensureOpenTurn(messageID: String, at: Date) -> [TurnEvent] {
        guard openTurn == nil else { return [] }
        if recentHookTurn != nil { return [] }
        orphanCounter += 1
        let id = "orphan-\(messageID)"
        openTurn = id
        turnStartTimes[id] = at
        log.info("orphan text, synthetic turn \(id)")
        return [.turnStarted(id, promptText: "", at: at), .statusChanged(.busy)]
    }

    private func handleMessageBoundary(_ messageID: String) -> [TurnEvent] {
        guard let current = currentMessageID, current != messageID, !pendingTexts.isEmpty else { return [] }
        return flushPending(as: .finalAnswer, at: clock.now)
    }

    private func emitFinal(text: String, record: TranscriptRecord, at: Date) -> [TurnEvent] {
        let turnID = openTurn ?? recentHookTurn ?? "unknown"
        if let hook = hookFinalAnswers[turnID], clock.now.timeIntervalSince(hook.at) < Self.hookAnswerWindow {
            log.debug("dropped transcript finalAnswer after hook text for \(turnID.prefix(8))")
            return []
        }
        transcriptFinalAnswers[turnID, default: []].append(text)
        return [.item(makeItem(.finalAnswer, text: text, record: record, at: at))]
    }

    private func flushPending(as category: ContentCategory, at: Date) -> [TurnEvent] {
        guard !pendingTexts.isEmpty else { return [] }
        pendingTask?.cancel()
        pendingTask = nil
        let items = pendingTexts
        pendingTexts.removeAll()
        var events: [TurnEvent] = []
        for p in items {
            if category == .finalAnswer {
                events.append(contentsOf: emitFinal(text: p.text, record: p.record, at: at))
            } else {
                events.append(.item(makeItem(category, text: p.text, record: p.record, at: at)))
            }
        }
        return events
    }

    private func schedulePendingTimeout() {
        pendingTask?.cancel()
        pendingTask = Task { [weak self] in
            guard let self else { return }
            try? await self.clock.sleep(for: Self.pendingTimeout)
            guard !Task.isCancelled else { return }
            await self.pendingTimedOut()
        }
    }

    private func pendingTimedOut() {
        guard !pendingTexts.isEmpty else { return }
        log.debug("stop_reason absent; resolved by timeout")
        let events = flushPending(as: .finalAnswer, at: clock.now)
        if !events.isEmpty { broadcast.send(events) }
    }

    /// Force-resolves pending text now (tests and shutdown).
    public func flushPendingNow() -> [TurnEvent] {
        flushPending(as: .finalAnswer, at: clock.now)
    }

    // MARK: - Helpers

    private func envelopeEvents(_ record: TranscriptRecord) -> [TurnEvent] {
        var events: [TurnEvent] = []
        if let cwd = record.envelope.cwd, !cwd.isEmpty, cwdSeen.insert(cwd).inserted {
            events.append(.cwdObserved(URL(fileURLWithPath: cwd)))
        }
        if let ep = record.envelope.entrypoint, !entrypointSeen {
            entrypointSeen = true
            events.append(.entrypointObserved(ep == "claude-desktop" ? .claudeDesktop : (ep == "cli" ? .cli : .unknown)))
        }
        return events
    }

    private func makeItem(_ category: ContentCategory, text: String, record: TranscriptRecord, at: Date) -> SpeechItem {
        SpeechItem(sessionID: sessionID, turnID: openTurn ?? recentHookTurn, category: category, text: text,
                   sourceUUID: record.envelope.uuid, timestamp: at)
    }

    /// The turn a hook closed within the last 30 s, to which lagging transcript records still belong.
    private var recentHookTurn: TurnID? {
        guard let r = recentHookEnd, clock.now.timeIntervalSince(r.at) < Self.hookAnswerWindow else { return nil }
        return r.turn
    }

    private func eventItem(_ text: String, at: Date) -> SpeechItem {
        SpeechItem(sessionID: sessionID, turnID: openTurn, category: .event, text: text, timestamp: at)
    }

    private func markSeen(_ uuid: String) -> Bool {
        guard seenSet.insert(uuid).inserted else { return false }
        seen.append(uuid)
        if seen.count > Self.seenCapacity {
            let evicted = seen.removeFirst()
            seenSet.remove(evicted)
        }
        return true
    }

    static func isHumanPrompt(record: TranscriptRecord, originKind: String?, promptSource: String?,
                              turnOrigin: String?) -> Bool {
        guard !record.envelope.isSidechain, !record.envelope.isMeta else { return false }
        if turnOrigin == "system" { return false }
        if let promptSource, promptSource == "command" || promptSource == "skill" { return false }
        if originKind == "human" || promptSource == "typed" { return true }
        if originKind == nil, promptSource == nil {
            if case .humanPrompt(let text, _, _, _) = record.payload {
                return !text.isEmpty && !text.hasPrefix("<") && !text.hasPrefix("Base directory for this skill")
            }
        }
        return false
    }

    static func looksLikeError(_ summary: String?) -> Bool {
        guard let s = summary else { return false }
        if s.hasPrefix("Error:") { return true }
        for marker in ["command not found", "No such file", "Permission denied"] where s.contains(marker) { return true }
        if let m = Rx(#"exit code[: ]+([0-9]+)"#).captures(s), let code = Int(m[1]), code != 0 { return true }
        return false
    }
}
