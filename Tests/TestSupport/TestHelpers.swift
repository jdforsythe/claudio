import ClaudioCore
import Foundation
import Synchronization

/// Builds transcript JSON lines shaped like Claude Code 2.1.x output.
public enum RecordBuilder {
    public static let session = "562358f2-0209-4cc5-b2be-9157fd4b6a9d"
    public static let cwd = "/Users/fixture/project-1"

    public static func envelope(type: String, uuid: String = UUID().uuidString, promptID: String? = nil, timestamp: String = "2026-10-05T19:38:43.907Z",
                         sidechain: Bool = false, agentID: String? = nil, extra: [String: Any] = [:]) -> [String: Any] {
        var o: [String: Any] = ["type": type, "uuid": uuid, "parentUuid": NSNull(), "sessionId": session, "timestamp": timestamp,
                                "cwd": cwd, "entrypoint": "cli", "version": "2.1.290", "isSidechain": sidechain, "userType": "external"]
        if let promptID { o["promptId"] = promptID }
        if let agentID { o["agentId"] = agentID }
        for (k, v) in extra { o[k] = v }
        return o
    }

    public static func line(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])  // swiftlint:disable:this force_try
    }

    public static func humanPrompt(_ text: String, promptID: String, uuid: String = UUID().uuidString, timestamp: String = "2026-10-05T19:38:43.907Z") -> Data {
        line(envelope(type: "user", uuid: uuid, promptID: promptID, timestamp: timestamp, extra: [
            "message": ["role": "user", "content": text], "origin": ["kind": "human"], "promptSource": "typed", "turnOrigin": "human",
        ]))
    }

    public static func skillPrompt(_ text: String, promptID: String) -> Data {
        line(envelope(type: "user", promptID: promptID, extra: [
            "message": ["role": "user", "content": [["type": "text", "text": text]]], "promptSource": "skill", "turnOrigin": "system",
        ]))
    }

    public static func metaPrompt(_ text: String, promptID: String) -> Data {
        line(envelope(type: "user", promptID: promptID, extra: ["message": ["role": "user", "content": text], "isMeta": true]))
    }

    public static func toolResult(toolUseID: String, content: String, isError: Bool? = nil, toolUseResult: [String: Any]? = nil, promptID: String) -> Data {
        var block: [String: Any] = ["type": "tool_result", "tool_use_id": toolUseID, "content": content]
        if let isError { block["is_error"] = isError }
        var extra: [String: Any] = ["message": ["role": "user", "content": [block]]]
        if let toolUseResult { extra["toolUseResult"] = toolUseResult }
        return line(envelope(type: "user", promptID: promptID, extra: extra))
    }

    public static func assistant(block: [String: Any], messageID: String, stopReason: Any, promptID: String? = nil, uuid: String = UUID().uuidString,
                          timestamp: String = "2026-10-05T19:38:50.318Z", sidechain: Bool = false, agentID: String? = nil, index: Int = 0) -> Data {
        line(envelope(type: "assistant", uuid: uuid, promptID: promptID, timestamp: timestamp, sidechain: sidechain, agentID: agentID, extra: [
            "requestId": "req_x", "apiBlockIndex": index,
            "message": ["id": messageID, "role": "assistant", "model": "claude-fable-5-1", "content": [block], "stop_reason": stopReason],
        ]))
    }

    public static func text(_ text: String, messageID: String, stopReason: Any = "end_turn", promptID: String? = nil, uuid: String = UUID().uuidString, index: Int = 0) -> Data {
        assistant(block: ["type": "text", "text": text], messageID: messageID, stopReason: stopReason, promptID: promptID, uuid: uuid, index: index)
    }

    public static func thinking(_ text: String, messageID: String, stopReason: Any = "tool_use") -> Data {
        assistant(block: ["type": "thinking", "thinking": text, "signature": "REDACTED"], messageID: messageID, stopReason: stopReason)
    }

    public static func toolUse(name: String, input: [String: Any], id: String = "toolu_\(UUID().uuidString.prefix(8))", messageID: String, stopReason: Any = "tool_use", index: Int = 1) -> Data {
        assistant(block: ["type": "tool_use", "id": id, "name": name, "input": input], messageID: messageID, stopReason: stopReason, index: index)
    }

    public static func turnDuration(ms: Int = 1000, timestamp: String = "2026-10-05T19:41:12.232Z") -> Data {
        line(envelope(type: "system", timestamp: timestamp, extra: ["subtype": "turn_duration", "durationMs": ms, "messageCount": 3]))
    }

    public static func aiTitle(_ title: String) -> Data {
        line(["type": "ai-title", "aiTitle": title, "sessionId": session])
    }

    public static func unknown(_ type: String) -> Data {
        line(["type": type, "sessionId": session, "whatever": 1])
    }
}

extension TranscriptParser {
    public func record(_ data: Data) -> TranscriptRecord {
        switch parse(line: data) {
        case .success(let r): return r
        case .failure(let e): fatalError("parse failed: \(e)")
        }
    }
}

public enum TestFixtures {
    public static func url(_ relative: String) -> URL? {
        Bundle.module.resourceURL?.appendingPathComponent("Fixtures").appendingPathComponent(relative)
    }

    public static func lines(_ relative: String) -> [Data] {
        guard let url = url(relative), let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: UInt8(0x0A), omittingEmptySubsequences: true).map { Data($0) }
    }
}

public struct TempRoot: Sendable {
    public let url: URL
    public init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("claudio-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    public func path(_ p: String) -> URL { url.appendingPathComponent(p) }
    public func cleanup() { try? FileManager.default.removeItem(at: url) }
}

public func makeTestSettings() -> AppSettings {
    let suite = "com.jdforsythe.claudio.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!  // swiftlint:disable:this force_unwrapping
    defaults.removePersistentDomain(forName: suite)
    return AppSettings(defaults: defaults)
}

/// Polls until the condition holds or the budget elapses (used only where real time is involved).
public func waitUntil(_ seconds: TimeInterval = 2, isolation: isolated (any Actor)? = #isolation,
                      _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

public func waitSync(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return condition()
}

/// Collects a tailer's records on a background task so tests can poll without holding an iterator.
public final class RecordCollector: Sendable {
    private final class Store: Sendable {
        let storage = Mutex<[TranscriptRecord]>([])
    }

    private let store = Store()
    private let task: Task<Void, Never>

    public init(_ stream: AsyncStream<TranscriptTailer.Output>) {
        let store = self.store
        task = Task {
            for await output in stream { store.storage.withLock { $0.append(output.record) } }
        }
    }

    public var records: [TranscriptRecord] { store.storage.withLock { $0 } }
    public func cancel() { task.cancel() }
}
