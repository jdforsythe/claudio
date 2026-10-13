import Foundation
import Synchronization
import os

public enum LogLevel: String, Codable, Sendable, CaseIterable, Comparable {
    case debug
    case info
    case notice
    case warning
    case error
    case fault

    private var rank: Int {
        switch self {
        case .debug: 0
        case .info: 1
        case .notice: 2
        case .warning: 3
        case .error: 4
        case .fault: 5
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rank < rhs.rank }

    public var label: String {
        switch self {
        case .debug: "DEBUG"
        case .info: "INFO "
        case .notice: "NOTE "
        case .warning: "WARN "
        case .error: "ERROR"
        case .fault: "FAULT"
        }
    }
}

/// One logging category: forwards to `os.Logger` and to the file mirror (document 11 §1).
public struct LogChannel: Sendable {
    public let category: String
    private let logger: Logger

    public init(category: String) {
        self.category = category
        self.logger = Logger(subsystem: Log.subsystem, category: category)
    }

    public func debug(_ message: @autoclosure () -> String) { emit(.debug, message()) }
    public func info(_ message: @autoclosure () -> String) { emit(.info, message()) }
    public func notice(_ message: @autoclosure () -> String) { emit(.notice, message()) }
    public func warning(_ message: @autoclosure () -> String) { emit(.warning, message()) }
    public func error(_ message: @autoclosure () -> String) { emit(.error, message()) }
    public func fault(_ message: @autoclosure () -> String) { emit(.fault, message()) }

    private func emit(_ level: LogLevel, _ message: String) {
        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info: logger.info("\(message, privacy: .public)")
        case .notice: logger.notice("\(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        case .fault: logger.fault("\(message, privacy: .public)")
        }
        Log.fileSink.write(level: level, category: category, message: message)
    }
}

/// Namespace of loggers under one subsystem.
public enum Log {
    public static let subsystem = "com.jdforsythe.claudio"
    public static let transcript = LogChannel(category: "transcript")
    public static let ingest = LogChannel(category: "ingest")
    public static let sessions = LogChannel(category: "sessions")
    public static let arbiter = LogChannel(category: "arbiter")
    public static let speech = LogChannel(category: "speech")
    public static let render = LogChannel(category: "render")
    public static let scheduler = LogChannel(category: "scheduler")
    public static let playback = LogChannel(category: "playback")
    public static let edge = LogChannel(category: "backend.edge")
    public static let apple = LogChannel(category: "backend.apple")
    public static let openai = LogChannel(category: "backend.openai")
    public static let control = LogChannel(category: "control")
    public static let hooks = LogChannel(category: "hooks")
    public static let ui = LogChannel(category: "ui")
    public static let settings = LogChannel(category: "settings")
    public static let fileSink = FileLogSink()
}

/// Mirrors log lines to `~/Library/Logs/Claudio/claudio.log`, rotated 5 × 5 MiB (document 08 §8).
public final class FileLogSink: Sendable {
    private struct State {
        var url: URL?
        var handle: FileHandle?
        var threshold: LogLevel = .info
        var bytesWritten: UInt64 = 0
    }

    private let state = Mutex(State())
    private let envOverride: LogLevel? = ProcessInfo.processInfo.environment["CLAUDIO_LOG_LEVEL"].flatMap(LogLevel.init(rawValue:))
    public static let maxBytes: UInt64 = 5 * 1024 * 1024
    public static let rotations = 5

    private static func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().timeZone(separator: .omitted).time(includingFractionalSeconds: true))
    }

    init() {
        if let env = ProcessInfo.processInfo.environment["CLAUDIO_LOG_LEVEL"], let level = LogLevel(rawValue: env) {
            state.withLock { $0.threshold = level }
        }
    }

    public func configure(url: URL, threshold: LogLevel) {
        state.withLock { s in
            s.threshold = envOverride ?? threshold
            if s.url != url {
                try? s.handle?.close()
                s.handle = nil
                s.url = url
                s.bytesWritten = 0
            }
        }
    }

    public func setThreshold(_ level: LogLevel) {
        state.withLock { $0.threshold = envOverride ?? level }
    }

    func write(level: LogLevel, category: String, message: String) {
        state.withLock { s in
            guard let url = s.url, level >= s.threshold else { return }
            if s.handle == nil { open(&s, url: url) }
            guard let handle = s.handle else { return }
            let line = "\(Self.timestamp(Date())) \(level.label) \(category.padding(toLength: 13, withPad: " ", startingAt: 0)) \(message)\n"
            let data = Data(line.utf8)
            handle.write(data)
            s.bytesWritten += UInt64(data.count)
            if s.bytesWritten > Self.maxBytes { rotate(&s, url: url) }
        }
    }

    private func open(_ s: inout State, url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        handle.seekToEndOfFile()
        s.handle = handle
        s.bytesWritten = (try? fm.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
    }

    private func rotate(_ s: inout State, url: URL) {
        try? s.handle?.close()
        s.handle = nil
        let fm = FileManager.default
        let base = url.path
        let oldest = "\(base).\(Self.rotations - 1)"
        try? fm.removeItem(atPath: oldest)
        for i in stride(from: Self.rotations - 2, through: 1, by: -1) {
            let from = "\(base).\(i)"
            if fm.fileExists(atPath: from) { try? fm.moveItem(atPath: from, toPath: "\(base).\(i + 1)") }
        }
        try? fm.moveItem(atPath: base, toPath: "\(base).1")
        s.bytesWritten = 0
        open(&s, url: url)
    }
}
