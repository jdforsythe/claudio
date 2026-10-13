import Foundation

/// One decoded transcript line (document 03 §3).
public struct TranscriptRecord: Sendable {
    public let envelope: Envelope
    public let payload: Payload
    public let rawLength: Int

    public struct Envelope: Sendable {
        public let type: String
        public let uuid: String?
        public let sessionID: SessionID?
        public let promptID: TurnID?
        public let timestamp: Date?
        public let cwd: String?
        public let entrypoint: String?
        public let version: String?
        public let isSidechain: Bool
        public let agentID: String?
        public let isMeta: Bool

        public init(type: String, uuid: String? = nil, sessionID: SessionID? = nil, promptID: TurnID? = nil,
                    timestamp: Date? = nil, cwd: String? = nil, entrypoint: String? = nil, version: String? = nil,
                    isSidechain: Bool = false, agentID: String? = nil, isMeta: Bool = false) {
            self.type = type
            self.uuid = uuid
            self.sessionID = sessionID
            self.promptID = promptID
            self.timestamp = timestamp
            self.cwd = cwd
            self.entrypoint = entrypoint
            self.version = version
            self.isSidechain = isSidechain
            self.agentID = agentID
            self.isMeta = isMeta
        }
    }

    public enum Payload: Sendable {
        case humanPrompt(text: String, originKind: String?, promptSource: String?, turnOrigin: String?)
        case toolResult(toolUseID: String, isError: Bool, summary: String?)
        case assistantText(messageID: String, requestID: String?, blockIndex: Int?, stopReason: String?, text: String)
        case assistantThinking(messageID: String, stopReason: String?, text: String)
        case assistantToolUse(messageID: String, stopReason: String?, toolUseID: String, name: String,
                              input: [String: JSONValue])
        case turnDuration(durationMs: Int, messageCount: Int?, pendingBackgroundAgents: Int?)
        case stopHookSummary(commands: [String], errorCount: Int)
        case aiTitle(String)
        case permissionMode(String)
        case hookAttachment(hookEvent: String, command: String, exitCode: Int?)
        case ignored
        case unknown(type: String)
    }

    public init(envelope: Envelope, payload: Payload, rawLength: Int = 0) {
        self.envelope = envelope
        self.payload = payload
        self.rawLength = rawLength
    }

    public var payloadKind: String {
        switch payload {
        case .humanPrompt: "humanPrompt"
        case .toolResult: "toolResult"
        case .assistantText: "assistantText"
        case .assistantThinking: "assistantThinking"
        case .assistantToolUse: "assistantToolUse"
        case .turnDuration: "turnDuration"
        case .stopHookSummary: "stopHookSummary"
        case .aiTitle: "aiTitle"
        case .permissionMode: "permissionMode"
        case .hookAttachment: "hookAttachment"
        case .ignored: "ignored"
        case .unknown(let t): "unknown(\(t))"
        }
    }
}
