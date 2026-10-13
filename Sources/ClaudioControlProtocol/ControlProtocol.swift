import Foundation

/// Wire protocol version carried by every message (document 04 §5.4).
public enum ControlProtocolVersion {
    public static let current = 1
}

/// Raw JSON bytes preserved verbatim through Codable (used for hook payloads).
public struct RawJSON: Codable, Sendable, Equatable {
    public let data: Data

    public init(data: Data) { self.data = data }
    public init(string: String) { self.data = Data(string.utf8) }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(JSONValue.self)
        let obj = value.foundationObject
        if JSONSerialization.isValidJSONObject(obj) {
            data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        } else {
            data = try JSONEncoder().encode(value)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        let value = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
        try container.encode(value)
    }

    public var jsonValue: JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: data)
    }
}

public struct ControlEnvelope: Codable, Sendable, Equatable {
    public let v: Int
    public let kind: String  // "hook" | "request"
    // hook fields
    public let event: String?
    public let session: String?
    public let payload: RawJSON?
    // request fields
    public let request: ControlRequest?

    public init(request: ControlRequest) {
        self.v = ControlProtocolVersion.current
        self.kind = "request"
        self.event = nil
        self.session = nil
        self.payload = nil
        self.request = request
    }

    public init(hookEvent: String, session: String, payload: RawJSON) {
        self.v = ControlProtocolVersion.current
        self.kind = "hook"
        self.event = hookEvent
        self.session = session
        self.payload = payload
        self.request = nil
    }
}

public enum SubscriptionKind: String, Codable, Sendable {
    case items
    case rawRecords
}

public enum ControlRequest: Codable, Sendable, Equatable {
    case status
    case sessions
    case `switch`(query: String?)
    case level(SpeechLevel, session: String?)
    case pause
    case resume
    case toggle
    case skip
    case live
    case mute(Bool)
    case say(text: String)
    case hooksStatus
    case hooksInstall
    case hooksUninstall
    case link(Bool)
    case skill(install: Bool)
    case version
    case ping
    case activate
    case quit
    case render(markdown: String)
    case subscribe(SubscriptionKind, session: String?)
    case bench(backend: String?, fixture: String?, runs: Int)
    case doctor
    case dumpState
    case voices(backend: String?)
    case speakSession(session: String, level: SpeechLevel)
    case update(install: Bool)
}

public struct SegmentSummary: Codable, Sendable, Equatable {
    public let kind: String
    public let text: String
    public init(kind: String, text: String) {
        self.kind = kind
        self.text = text
    }
}

public struct SpeechItemSummary: Codable, Sendable, Equatable {
    public let session: String
    public let turn: String?
    public let category: ContentCategory
    public let text: String
    public let filtered: Bool
    public let timestamp: Date
    public init(session: String, turn: String?, category: ContentCategory, text: String, filtered: Bool, timestamp: Date) {
        self.session = session
        self.turn = turn
        self.category = category
        self.text = text
        self.filtered = filtered
        self.timestamp = timestamp
    }
}

public struct DoctorCheck: Codable, Sendable, Equatable {
    public let name: String
    public let state: String  // pass | warn | fail
    public let detail: String
    public init(name: String, state: String, detail: String) {
        self.name = name
        self.state = state
        self.detail = detail
    }
}

public struct VoiceSummary: Codable, Sendable, Equatable {
    public let backend: String
    public let id: String
    public let displayName: String
    public let locale: String
    public let gender: String?
    public let quality: String?
    public init(backend: String, id: String, displayName: String, locale: String, gender: String?, quality: String?) {
        self.backend = backend
        self.id = id
        self.displayName = displayName
        self.locale = locale
        self.gender = gender
        self.quality = quality
    }
}

public struct SessionSummary: Codable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let cwd: String
    public let entrypoint: SessionEntrypoint
    public let status: SessionStatus
    public let level: SpeechLevel
    public let unread: Int
    public let active: Bool
    public let lastActivity: Date
    public let pid: Int32?

    public init(id: String, title: String, cwd: String, entrypoint: SessionEntrypoint, status: SessionStatus,
                level: SpeechLevel, unread: Int, active: Bool, lastActivity: Date, pid: Int32? = nil) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.entrypoint = entrypoint
        self.status = status
        self.level = level
        self.unread = unread
        self.active = active
        self.lastActivity = lastActivity
        self.pid = pid
    }
}

public struct StatusReport: Codable, Sendable, Equatable {
    public let version: String
    public let playback: String  // idle | speaking | paused | catchingUp
    public let activeSession: SessionSummary?
    public let backend: String
    public let voice: String
    public let rate: Double
    public let eventsMuted: Bool
    public let hooks: HookInstallStatus
    public let sessionsLive: Int
    public let metrics: [String: Double]
    public let socketPath: String
    public let pid: Int32
    public let uptimeSeconds: Double

    public init(version: String, playback: String, activeSession: SessionSummary?, backend: String, voice: String,
                rate: Double, eventsMuted: Bool, hooks: HookInstallStatus, sessionsLive: Int,
                metrics: [String: Double], socketPath: String, pid: Int32, uptimeSeconds: Double) {
        self.version = version
        self.playback = playback
        self.activeSession = activeSession
        self.backend = backend
        self.voice = voice
        self.rate = rate
        self.eventsMuted = eventsMuted
        self.hooks = hooks
        self.sessionsLive = sessionsLive
        self.metrics = metrics
        self.socketPath = socketPath
        self.pid = pid
        self.uptimeSeconds = uptimeSeconds
    }
}

public enum ControlResult: Codable, Sendable, Equatable {
    case status(StatusReport)
    case sessions([SessionSummary])
    case session(SessionSummary)
    case hooks(HookInstallStatus)
    case text(String)
    case segments([SegmentSummary])
    case item(SpeechItemSummary)
    case record(type: String, uuid: String?, summary: String)
    case doctor([DoctorCheck])
    case voices([VoiceSummary])
    case none
}

public struct ControlResponse: Codable, Sendable, Equatable {
    public let v: Int
    public let ok: Bool
    public let error: String?
    public let result: ControlResult?

    public init(ok: Bool, error: String? = nil, result: ControlResult? = nil) {
        self.v = ControlProtocolVersion.current
        self.ok = ok
        self.error = error
        self.result = result
    }

    public static func success(_ result: ControlResult = .none) -> ControlResponse {
        ControlResponse(ok: true, result: result)
    }

    public static func failure(_ message: String) -> ControlResponse {
        ControlResponse(ok: false, error: message)
    }
}

/// Shared JSON coding configuration (document 04 §5.3).
public enum ControlCoding {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public static let maxLineBytes = 1_048_576

    public static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        var data = try encoder().encode(value)
        data.append(0x0A)
        return data
    }
}
