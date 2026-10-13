import Foundation

/// Tails one transcript file; attaches at EOF and never replays history (document 03 §5).
public final class TranscriptTailer: Sendable {
    public struct Output: Sendable {
        public let record: TranscriptRecord
        public let fileOffset: UInt64
    }

    public static let readCap = 1_048_576
    public static let idleCloseInterval: TimeInterval = 600
    public static let missingGrace: TimeInterval = 60
    public static let partialWarnAfter: TimeInterval = 5

    private actor Core {
        let url: URL
        let sessionID: SessionID
        let parser: TranscriptParser
        let log: LogChannel
        let clock: any ClaudioClock
        let continuation: AsyncStream<Output>.Continuation
        var fd: Int32 = -1
        var inode: UInt64 = 0
        var offset: UInt64 = 0
        var attached = false
        var attachedAt: Date?
        var partial = Data()
        var partialSince: Date?
        var lastWake: Date?
        var missingSince: Date?
        var finished = false
        var filterOldTimestamps = false
        var metrics = TranscriptParser.Metrics()
        var pendingRewake = false

        init(url: URL, sessionID: SessionID, parser: TranscriptParser, log: LogChannel, clock: any ClaudioClock,
             continuation: AsyncStream<Output>.Continuation) {
            self.url = url
            self.sessionID = sessionID
            self.parser = parser
            self.log = log
            self.clock = clock
            self.continuation = continuation
        }

        func wake() {
            guard !finished else { return }
            let now = clock.now
            lastWake = now
            if fd < 0 {
                guard open() else {
                    if missingSince == nil { missingSince = now }
                    if let since = missingSince, now.timeIntervalSince(since) >= TranscriptTailer.missingGrace {
                        log.notice("transcript gone \(url.lastPathComponent)")
                        finish()
                    }
                    return
                }
            }
            missingSince = nil
            var st = stat()
            guard fstat(fd, &st) == 0 else {
                closeHandle()
                return
            }
            let currentInode = UInt64(st.st_ino)
            let size = UInt64(st.st_size)
            if !attached {
                inode = currentInode
                offset = size
                attached = true
                attachedAt = now
                log.debug("attached \(url.lastPathComponent) at \(size)")
                return
            }
            if currentInode != inode {
                log.notice("transcript replaced \(url.lastPathComponent)")
                closeHandle()
                guard open() else { return }
                var st2 = stat()
                _ = fstat(fd, &st2)
                inode = UInt64(st2.st_ino)
                offset = 0
                partial.removeAll()
                filterOldTimestamps = true
            } else if size < offset {
                log.notice("transcript truncated \(url.lastPathComponent)")
                offset = 0
                partial.removeAll()
                filterOldTimestamps = true
            }
            readAvailable(upTo: size)
        }

        private func readAvailable(upTo size: UInt64) {
            let readOffset = offset + UInt64(partial.count)
            guard size > readOffset else {
                checkStuckPartial()
                return
            }
            let toRead = Int(min(UInt64(TranscriptTailer.readCap), size - readOffset))
            var buffer = [UInt8](repeating: 0, count: toRead)
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                pread(fd, raw.baseAddress, toRead, off_t(readOffset))
            }
            guard n > 0 else { return }
            partial.append(contentsOf: buffer[0..<n])
            var consumed: UInt64 = 0
            var start = partial.startIndex
            while let nl = partial[start...].firstIndex(of: 0x0A) {
                var line = partial[start..<nl]
                if line.last == 0x0D { line = line.dropLast() }
                let lineLength = UInt64(nl - start + 1)
                emit(line: Data(line), at: offset + consumed)
                consumed += lineLength
                start = nl + 1
            }
            if start > partial.startIndex {
                partial = Data(partial[start...])
            }
            offset += consumed
            if partial.isEmpty {
                partialSince = nil
            } else if partialSince == nil {
                partialSince = clock.now
            }
            if readOffset + UInt64(n) < size {
                // More remains (the 1 MiB cap); continue from where this read stopped.
                readAvailable(upTo: size)
            }
        }

        private func checkStuckPartial() {
            if let since = partialSince, clock.now.timeIntervalSince(since) > TranscriptTailer.partialWarnAfter {
                log.warning("partial line stuck in \(url.lastPathComponent)")
                partialSince = clock.now
            }
        }

        private func emit(line: Data, at fileOffset: UInt64) {
            guard !line.isEmpty, line.contains(where: { $0 != 0x20 && $0 != 0x09 }) else { return }
            metrics.lines += 1
            metrics.bytes += line.count
            switch parser.parse(line: line, offset: Int(fileOffset)) {
            case .success(let record):
                metrics.decoded += 1
                if case .unknown(let t) = record.payload {
                    metrics.unknownTypes[t, default: 0] += 1
                }
                if filterOldTimestamps, let ts = record.envelope.timestamp, let attachedAt, ts <= attachedAt {
                    return
                }
                continuation.yield(Output(record: record, fileOffset: fileOffset))
            case .failure(.malformed(let off, let prefix)):
                metrics.malformed += 1
                log.warning("malformed line at \(off) in \(url.lastPathComponent): \(prefix)")
            }
        }

        private func open() -> Bool {
            let newFD = Foundation.open(url.path, O_RDONLY)
            guard newFD >= 0 else { return false }
            fd = newFD
            return true
        }

        private func closeHandle() {
            if fd >= 0 { Foundation.close(fd) }
            fd = -1
        }

        func closeIfIdle(now: Date) {
            guard fd >= 0, let last = lastWake, now.timeIntervalSince(last) >= TranscriptTailer.idleCloseInterval else { return }
            closeHandle()
            log.debug("closed idle handle \(url.lastPathComponent)")
        }

        func checkMissing(now: Date) {
            guard !finished, !FileManager.default.fileExists(atPath: url.path) else {
                missingSince = nil
                return
            }
            if missingSince == nil { missingSince = now }
            if let since = missingSince, now.timeIntervalSince(since) >= TranscriptTailer.missingGrace {
                log.notice("transcript gone \(url.lastPathComponent)")
                finish()
            }
        }

        func finish() {
            guard !finished else { return }
            finished = true
            closeHandle()
            continuation.finish()
        }

        var isOpen: Bool { fd >= 0 }
        var currentMetrics: TranscriptParser.Metrics { metrics }
    }

    public let url: URL
    public let sessionID: SessionID
    public let records: AsyncStream<Output>
    private let core: Core

    public init(url: URL, sessionID: SessionID, parser: TranscriptParser = TranscriptParser(),
                log: LogChannel = Log.ingest, clock: any ClaudioClock = SystemClock()) {
        self.url = url
        self.sessionID = sessionID
        let (stream, continuation) = AsyncStream<Output>.makeStream(bufferingPolicy: .unbounded)
        self.records = stream
        self.core = Core(url: url, sessionID: sessionID, parser: parser, log: log, clock: clock,
                         continuation: continuation)
    }

    /// Called by the registry on each discovery event. Serialized by the internal actor.
    public func wake() {
        Task { await core.wake() }
    }

    /// Same as `wake()` but awaits completion; used by tests and the initial scan.
    public func wakeAndWait() async {
        await core.wake()
    }

    public func closeIfIdle(now: Date) async { await core.closeIfIdle(now: now) }
    public func checkMissing(now: Date) async { await core.checkMissing(now: now) }
    public func close() { Task { await core.finish() } }
    public var isOpen: Bool { get async { await core.isOpen } }
    public var metrics: TranscriptParser.Metrics { get async { await core.currentMetrics } }

    /// Reads the last 64 KiB and returns the last `ai-title` (document 03 §5.6).
    public static func peekTitle(url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 65_536
        let start = size > window ? size - window : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        let marker = Data("\"ai-title\"".utf8)
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        if start > 0 { lines = Array(lines.dropFirst()) }
        for line in lines.reversed() where line.range(of: marker) != nil {
            if case .success(let record) = TranscriptParser().parse(line: Data(line)),
               case .aiTitle(let title) = record.payload, !title.isEmpty {
                return title
            }
        }
        return nil
    }

    /// Reads the last `cwd` seen in the tail of the file, for labelling before the first live record.
    public static func peekCwd(url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 65_536
        let start = size > window ? size - window : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        if start > 0 { lines = Array(lines.dropFirst()) }
        let parser = TranscriptParser()
        for line in lines.reversed() {
            if case .success(let record) = parser.parse(line: Data(line)), let cwd = record.envelope.cwd {
                return cwd
            }
        }
        return nil
    }
}
