import Foundation

public struct LiveAgent: Sendable, Equatable, Codable {
    public let pid: Int32?
    public let cwd: String?
    public let kind: String?
    public let startedAt: Double?
    public let sessionId: String?
    public let name: String?
    public let status: String?

    public init(pid: Int32?, cwd: String?, kind: String?, startedAt: Double?, sessionId: String?, name: String?, status: String?) {
        self.pid = pid
        self.cwd = cwd
        self.kind = kind
        self.startedAt = startedAt
        self.sessionId = sessionId
        self.name = name
        self.status = status
    }
}

/// Polls `claude agents --json` (document 03 §8.5, decision D-26).
public actor LiveAgentsProbe {
    public enum Outcome: Sendable, Equatable {
        case agents([LiveAgent])
        case failed(String)
    }

    public static let timeoutSeconds: TimeInterval = 3
    public static let backoffInterval: TimeInterval = 60

    private let clock: any ClaudioClock
    private let log = Log.sessions
    private var interval: TimeInterval
    private var task: Task<Void, Never>?
    private var consecutiveFailures = 0
    private var loggedBackoff = false
    private let broadcast = Broadcast<Outcome>()
    private let runner: @Sendable () async -> Result<Data, MessageError>
    public private(set) var lastLatencyMs: Double = 0
    public private(set) var lastOutcome: Outcome?

    public init(clock: any ClaudioClock = SystemClock(), interval: TimeInterval = 10,
                runner: (@Sendable () async -> Result<Data, MessageError>)? = nil) {
        self.clock = clock
        self.interval = interval
        self.runner = runner ?? LiveAgentsProbe.runClaudeAgents
    }

    public nonisolated func outcomes() -> AsyncStream<Outcome> { broadcast.subscribe() }

    public func setInterval(_ seconds: TimeInterval) { interval = max(2, seconds) }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.probeOnce()
                let wait = await self.currentWait()
                try? await self.clock.sleep(for: wait)
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    private func currentWait() -> TimeInterval {
        consecutiveFailures >= 3 ? Self.backoffInterval : interval
    }

    public func probeOnce() async {
        let started = clock.now
        let result = await runner()
        lastLatencyMs = clock.now.timeIntervalSince(started) * 1000
        switch result {
        case .success(let data):
            if let agents = Self.parse(data) {
                consecutiveFailures = 0
                loggedBackoff = false
                lastOutcome = .agents(agents)
                broadcast.send(.agents(agents))
            } else {
                fail("invalid JSON")
            }
        case .failure(let reason):
            fail(reason.message)
        }
    }

    private func fail(_ reason: String) {
        consecutiveFailures += 1
        lastOutcome = .failed(reason)
        if consecutiveFailures >= 3, !loggedBackoff {
            loggedBackoff = true
            log.error("claude agents probe failing: \(reason)")
        }
        broadcast.send(.failed(reason))
    }

    public static func parse(_ data: Data) -> [LiveAgent]? {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return array.map { o in
            LiveAgent(pid: (o["pid"] as? NSNumber)?.int32Value, cwd: o["cwd"] as? String, kind: o["kind"] as? String,
                      startedAt: (o["startedAt"] as? NSNumber)?.doubleValue, sessionId: o["sessionId"] as? String,
                      name: o["name"] as? String, status: o["status"] as? String)
        }
    }

    /// Runs the real command with an extended PATH and a 3 s timeout.
    public static let runClaudeAgents: @Sendable () async -> Result<Data, MessageError> = {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["claude", "agents", "--json"]
            var env = ProcessInfo.processInfo.environment
            let home = NSHomeDirectory()
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(home)/.local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
            process.environment = env
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            let box = UncheckedSendable(process)
            let finished = NSLock()
            nonisolated(unsafe) var resumed = false
            process.terminationHandler = { p in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                finished.lock()
                defer { finished.unlock() }
                guard !resumed else { return }
                resumed = true
                if p.terminationStatus == 0 {
                    continuation.resume(returning: .success(data))
                } else {
                    continuation.resume(returning: .failure(MessageError("exit \(p.terminationStatus)")))
                }
            }
            do {
                try process.run()
            } catch {
                finished.lock()
                resumed = true
                finished.unlock()
                continuation.resume(returning: .failure(MessageError("not found")))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
                finished.lock()
                let already = resumed
                if !already { resumed = true }
                finished.unlock()
                if !already {
                    box.value.terminate()
                    continuation.resume(returning: .failure(MessageError("timeout")))
                }
            }
        }
    }
}
