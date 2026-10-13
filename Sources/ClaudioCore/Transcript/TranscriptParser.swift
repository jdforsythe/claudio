import Foundation

public enum ParseError: Error, Sendable, Equatable {
    case malformed(offset: Int, prefix: String)
}

/// Tolerant two-phase JSONL record decoder (document 03 §3).
public struct TranscriptParser: Sendable {
    public struct Metrics: Sendable, Equatable {
        public var lines = 0
        public var decoded = 0
        public var malformed = 0
        public var unknownTypes: [String: Int] = [:]
        public var bytes = 0
        public init() {}
        public var unknownCount: Int { unknownTypes.values.reduce(0, +) }
    }

    private struct TypeProbe: Decodable {
        let type: String?
    }

    private struct RawBlock: Decodable {
        let type: String?
        let text: String?
        let thinking: String?
        let id: String?
        let name: String?
        let input: [String: JSONValue]?
        let tool_use_id: String?
        let is_error: Bool?
        let content: JSONValue?
    }

    private enum RawContent: Decodable {
        case string(String)
        case blocks([RawBlock])

        init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) {
                self = .string(s)
            } else if let b = try? c.decode([RawBlock].self) {
                self = .blocks(b)
            } else {
                self = .string("")
            }
        }
    }

    private struct RawMessage: Decodable {
        let id: String?
        let role: String?
        let content: RawContent?
        let stop_reason: String?
    }

    private struct RawOrigin: Decodable {
        let kind: String?
    }

    private struct RawAttachment: Decodable {
        let type: String?
        let hookEvent: String?
        let command: String?
        let exitCode: Int?
    }

    private struct RawHookInfo: Decodable {
        let command: String?
    }

    private struct RawRecord: Decodable {
        let type: String
        let uuid: String?
        let sessionId: String?
        let session_id: String?
        let promptId: String?
        let timestamp: String?
        let cwd: String?
        let entrypoint: String?
        let version: String?
        let isSidechain: Bool?
        let agentId: String?
        let isMeta: Bool?
        let message: RawMessage?
        let requestId: String?
        let apiBlockIndex: Int?
        let origin: RawOrigin?
        let promptSource: String?
        let turnOrigin: String?
        let toolUseResult: JSONValue?
        let subtype: String?
        let durationMs: Int?
        let messageCount: Int?
        let pendingBackgroundAgentCount: Int?
        let hookInfos: [RawHookInfo]?
        let hookErrors: [JSONValue]?
        let attachment: RawAttachment?
        let aiTitle: String?
        let permissionMode: String?
    }

    public static let ignoredTypes: Set<String> = [
        "last-prompt", "mode", "atis-latch", "queue-operation", "file-history-snapshot", "file-history-delta",
        "cost-state", "fork-context-ref",
    ]

    public init() {}

    public func parse(line: Data, offset: Int = 0) -> Result<TranscriptRecord, ParseError> {
        let decoder = JSONDecoder()
        let probe: TypeProbe
        do {
            probe = try decoder.decode(TypeProbe.self, from: line)
        } catch {
            return .failure(.malformed(offset: offset, prefix: Self.prefix(of: line)))
        }
        guard let type = probe.type else {
            return .success(TranscriptRecord(envelope: .init(type: ""), payload: .unknown(type: ""), rawLength: line.count))
        }
        if type == "file-history-snapshot" || type == "file-history-delta" {
            return .success(TranscriptRecord(envelope: .init(type: type), payload: .ignored, rawLength: line.count))
        }
        let raw: RawRecord
        do {
            raw = try decoder.decode(RawRecord.self, from: line)
        } catch {
            return .failure(.malformed(offset: offset, prefix: Self.prefix(of: line)))
        }
        let envelope = TranscriptRecord.Envelope(
            type: raw.type, uuid: raw.uuid, sessionID: raw.sessionId ?? raw.session_id, promptID: raw.promptId,
            timestamp: raw.timestamp.flatMap(Self.parseDate), cwd: raw.cwd, entrypoint: raw.entrypoint,
            version: raw.version, isSidechain: raw.isSidechain ?? false, agentID: raw.agentId, isMeta: raw.isMeta ?? false)
        let payload = Self.payload(for: raw)
        return .success(TranscriptRecord(envelope: envelope, payload: payload, rawLength: line.count))
    }

    private static func payload(for raw: RawRecord) -> TranscriptRecord.Payload {
        switch raw.type {
        case "user":
            return userPayload(raw)
        case "assistant":
            return assistantPayload(raw)
        case "system":
            switch raw.subtype {
            case "turn_duration":
                return .turnDuration(durationMs: raw.durationMs ?? 0, messageCount: raw.messageCount,
                                     pendingBackgroundAgents: raw.pendingBackgroundAgentCount)
            case "stop_hook_summary":
                return .stopHookSummary(commands: (raw.hookInfos ?? []).compactMap(\.command),
                                        errorCount: raw.hookErrors?.count ?? 0)
            default:
                return .ignored
            }
        case "attachment":
            if let a = raw.attachment, let t = a.type, t == "hook_success" || t == "hook_failure" {
                return .hookAttachment(hookEvent: a.hookEvent ?? "", command: a.command ?? "", exitCode: a.exitCode)
            }
            return .ignored
        case "ai-title":
            return .aiTitle(raw.aiTitle ?? "")
        case "permission-mode":
            return .permissionMode(raw.permissionMode ?? "")
        default:
            if ignoredTypes.contains(raw.type) { return .ignored }
            return .unknown(type: raw.type)
        }
    }

    private static func userPayload(_ raw: RawRecord) -> TranscriptRecord.Payload {
        guard let content = raw.message?.content else {
            return .humanPrompt(text: "", originKind: raw.origin?.kind, promptSource: raw.promptSource,
                                turnOrigin: raw.turnOrigin)
        }
        switch content {
        case .string(let s):
            return .humanPrompt(text: s, originKind: raw.origin?.kind, promptSource: raw.promptSource,
                                turnOrigin: raw.turnOrigin)
        case .blocks(let blocks):
            if let result = blocks.first(where: { $0.type == "tool_result" }) {
                var isError = result.is_error ?? false
                var summary: String?
                if case .string(let s)? = result.content {
                    summary = s
                } else if case .array(let arr)? = result.content {
                    summary = arr.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
                }
                if let tur = raw.toolUseResult?.objectValue {
                    if tur["success"]?.boolValue == false { isError = true }
                    if let err = tur["error"]?.stringValue, !err.isEmpty {
                        isError = true
                        if summary == nil || summary?.isEmpty == true { summary = err }
                    }
                    if tur["interrupted"]?.boolValue == true { isError = true }
                } else if case .string(let s)? = raw.toolUseResult, summary == nil {
                    summary = s
                }
                return .toolResult(toolUseID: result.tool_use_id ?? "", isError: isError, summary: summary)
            }
            let text = blocks.filter { $0.type == "text" }.compactMap(\.text).joined(separator: "\n")
            return .humanPrompt(text: text, originKind: raw.origin?.kind, promptSource: raw.promptSource,
                                turnOrigin: raw.turnOrigin)
        }
    }

    private static func assistantPayload(_ raw: RawRecord) -> TranscriptRecord.Payload {
        let messageID = raw.message?.id ?? raw.uuid ?? ""
        let stop = raw.message?.stop_reason
        guard case .blocks(let blocks)? = raw.message?.content, let block = blocks.first else {
            if case .string(let s)? = raw.message?.content {
                return .assistantText(messageID: messageID, requestID: raw.requestId, blockIndex: raw.apiBlockIndex,
                                      stopReason: stop, text: s)
            }
            return .ignored
        }
        switch block.type {
        case "text":
            return .assistantText(messageID: messageID, requestID: raw.requestId, blockIndex: raw.apiBlockIndex,
                                  stopReason: stop, text: block.text ?? "")
        case "thinking":
            return .assistantThinking(messageID: messageID, stopReason: stop, text: block.thinking ?? "")
        case "tool_use":
            return .assistantToolUse(messageID: messageID, stopReason: stop, toolUseID: block.id ?? "",
                                     name: block.name ?? "", input: block.input ?? [:])
        default:
            return .ignored
        }
    }

    private static func prefix(of data: Data) -> String {
        String(decoding: data.prefix(80), as: UTF8.self)
    }

    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let dateLock = NSLock()

    public static func parseDate(_ s: String) -> Date? {
        dateLock.lock()
        defer { dateLock.unlock() }
        return fractional.date(from: s) ?? plain.date(from: s)
    }

    public static func formatDate(_ d: Date) -> String {
        dateLock.lock()
        defer { dateLock.unlock() }
        return fractional.string(from: d)
    }
}
