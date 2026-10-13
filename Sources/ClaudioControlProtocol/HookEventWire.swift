import Foundation

/// The fully decoded hook event, built on the app side from a hook envelope (document 04 §6).
public struct HookEvent: Sendable, Equatable {
    public let name: String
    public let sessionID: String
    public let promptID: String?
    public let transcriptPath: String?
    public let cwd: String?
    public let agentID: String?
    public let agentType: String?
    public let receivedAt: Date
    public let fields: [String: JSONValue]
    public let raw: Data?

    public init(name: String, sessionID: String, promptID: String? = nil, transcriptPath: String? = nil,
                cwd: String? = nil, agentID: String? = nil, agentType: String? = nil, receivedAt: Date,
                fields: [String: JSONValue] = [:], raw: Data? = nil) {
        self.name = name
        self.sessionID = sessionID
        self.promptID = promptID
        self.transcriptPath = transcriptPath
        self.cwd = cwd
        self.agentID = agentID
        self.agentType = agentType
        self.receivedAt = receivedAt
        self.fields = fields
        self.raw = raw
    }

    public static func decode(envelope: ControlEnvelope, now: Date) -> HookEvent? {
        guard envelope.kind == "hook" else { return nil }
        guard let payload = envelope.payload, let value = payload.jsonValue, let object = value.objectValue else {
            guard let name = envelope.event, let session = envelope.session else { return nil }
            return HookEvent(name: name, sessionID: session, receivedAt: now, raw: envelope.payload?.data)
        }
        let name = envelope.event ?? object["hook_event_name"]?.stringValue ?? ""
        let session = envelope.session ?? object["session_id"]?.stringValue ?? ""
        guard !name.isEmpty, !session.isEmpty else { return nil }
        return HookEvent(
            name: name,
            sessionID: session,
            promptID: object["prompt_id"]?.stringValue,
            transcriptPath: object["transcript_path"]?.stringValue,
            cwd: object["cwd"]?.stringValue,
            agentID: object["agent_id"]?.stringValue,
            agentType: object["agent_type"]?.stringValue,
            receivedAt: now,
            fields: object,
            raw: payload.data
        )
    }

    public func string(_ key: String) -> String? { fields[key]?.stringValue }
    public func bool(_ key: String) -> Bool? { fields[key]?.boolValue }
}
