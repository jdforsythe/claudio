import CoreServices
import Foundation
import Synchronization

/// FSEvents watcher over `<root>` directories (document 03 §4).
public final class SessionDiscovery: Sendable {
    public enum Event: Sendable, Equatable {
        case mainTranscriptChanged(url: URL, sessionID: SessionID, root: URL)
        case subagentTranscriptChanged(url: URL, sessionID: SessionID, agentID: String, root: URL)
        case rootUnavailable(URL)
    }

    public static let debounceSeconds: TimeInterval = 0.05
    public static let fsEventsLatency: TimeInterval = 0.1

    private struct Watched {
        var root: URL  // the `projects` directory
        var watchedPath: String  // root or its parent while root is missing
        var stream: UncheckedSendable<FSEventStreamRef>?
    }

    private struct State {
        var roots: [URL] = []
        var watched: [String: Watched] = [:]
        var debounce: [String: Task<Void, Never>] = [:]
        var started = false
        var retry: Task<Void, Never>?
    }

    private let state = Mutex(State())
    private let broadcast = Broadcast<Event>()
    private let clock: any ClaudioClock
    private let livenessWindow: TimeInterval
    private let queue = DispatchQueue(label: "com.jdforsythe.claudio.fsevents")
    private let log = Log.ingest

    public init(roots: [URL], clock: any ClaudioClock = SystemClock(), livenessWindow: TimeInterval = 24 * 3600) {
        self.clock = clock
        self.livenessWindow = livenessWindow
        state.withLock { $0.roots = roots.map { $0.standardizedFileURL } }
    }

    public var events: AsyncStream<Event> { broadcast.subscribe() }

    public func start() {
        let roots: [URL] = state.withLock { s in
            s.started = true
            return s.roots
        }
        for root in roots { watch(root) }
        scan(roots: roots)
        scheduleRetry()
    }

    public func stop() {
        let streams: [UncheckedSendable<FSEventStreamRef>] = state.withLock { s in
            s.started = false
            s.retry?.cancel()
            s.retry = nil
            let out = s.watched.values.compactMap(\.stream)
            s.watched.removeAll()
            for t in s.debounce.values { t.cancel() }
            s.debounce.removeAll()
            return out
        }
        for stream in streams { release(stream.value) }
    }

    /// Diffs roots and (re)starts only the changed streams.
    public func updateRoots(_ roots: [URL]) {
        let normalized = roots.map { $0.standardizedFileURL }
        let (added, removed, started): ([URL], [UncheckedSendable<FSEventStreamRef>], Bool) = state.withLock { s in
            let old = Set(s.roots.map(\.path))
            let new = Set(normalized.map(\.path))
            let added = normalized.filter { !old.contains($0.path) }
            var removed: [UncheckedSendable<FSEventStreamRef>] = []
            for path in old.subtracting(new) {
                if let w = s.watched.removeValue(forKey: path), let st = w.stream { removed.append(st) }
            }
            s.roots = normalized
            return (added, removed, s.started)
        }
        for st in removed { release(st.value) }
        guard started else { return }
        for root in added { watch(root) }
        scan(roots: added)
    }

    // MARK: FSEvents

    private func watch(_ root: URL) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: root.path, isDirectory: &isDir) && isDir.boolValue
        let watchPath = exists ? root.path : root.deletingLastPathComponent().path
        if !exists { log.notice("root \(root.path) has no projects dir; watching parent") }
        guard let stream = makeStream(path: watchPath) else {
            log.error("fsevents start failed for \(root.path)")
            broadcast.send(.rootUnavailable(root))
            return
        }
        state.withLock { s in
            if let old = s.watched[root.path]?.stream { release(old.value) }
            s.watched[root.path] = Watched(root: root, watchedPath: watchPath, stream: UncheckedSendable(stream))
        }
    }

    private func makeStream(path: String) -> FSEventStreamRef? {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil,
                                           release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        let callback: FSEventStreamCallback = { _, info, count, paths, eventFlags, _ in
            guard let info else { return }
            let discovery = Unmanaged<SessionDiscovery>.fromOpaque(info).takeUnretainedValue()
            guard let array = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
            var list: [(String, UInt32)] = []
            for i in 0..<count { list.append((array[i], eventFlags[i])) }
            discovery.handle(list)
        }
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, [path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                               Self.fsEventsLatency, flags) else { return nil }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        return stream
    }

    private func release(_ stream: FSEventStreamRef) {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    private func handle(_ events: [(path: String, flags: UInt32)]) {
        let roots: [Watched] = state.withLock { Array($0.watched.values) }
        for (path, flags) in events {
            if flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0 || flags & UInt32(kFSEventStreamEventFlagRootChanged) != 0 {
                scan(roots: roots.map(\.root))
                continue
            }
            // A root that appeared under a watched parent: switch the stream to it.
            for w in roots where w.watchedPath != w.root.path {
                if URL(fileURLWithPath: path).standardizedFileURL.path == w.root.path,
                   flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0 {
                    watch(w.root)
                    scan(roots: [w.root])
                }
            }
            guard path.hasSuffix(".jsonl") else { continue }
            let url = URL(fileURLWithPath: path)
            for w in roots {
                if let classified = ProjectPathEncoding.classify(url, root: w.root) {
                    debounce(url: url, classified: classified, root: w.root)
                    break
                }
            }
        }
    }

    private func debounce(url: URL, classified: ProjectPathEncoding.Classified, root: URL) {
        let key = url.path
        let already: Bool = state.withLock { s in
            if s.debounce[key] != nil { return true }
            let task = Task { [weak self] in
                guard let self else { return }
                try? await self.clock.sleep(for: Self.debounceSeconds)
                self.state.withLock { _ = $0.debounce.removeValue(forKey: key) }
                guard !Task.isCancelled else { return }
                self.emit(url: url, classified: classified, root: root)
            }
            s.debounce[key] = task
            return false
        }
        _ = already
    }

    private func emit(url: URL, classified: ProjectPathEncoding.Classified, root: URL) {
        switch classified {
        case .main(let sessionID, _):
            broadcast.send(.mainTranscriptChanged(url: url, sessionID: sessionID, root: root))
        case .subagent(let sessionID, let agentID, _):
            broadcast.send(.subagentTranscriptChanged(url: url, sessionID: sessionID, agentID: agentID, root: root))
        }
    }

    // MARK: Initial scan

    /// Enumerates each root up to three levels and emits events for recent transcripts (document 03 §4.4).
    public func scan(roots: [URL]) {
        let fm = FileManager.default
        let cutoff = clock.now.addingTimeInterval(-livenessWindow)
        for root in roots {
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                                                 options: [.skipsHiddenFiles]) else { continue }
            let rootDepth = root.standardizedFileURL.pathComponents.count
            var found: [(URL, ProjectPathEncoding.Classified, Date)] = []
            for case let url as URL in enumerator {
                let depth = url.standardizedFileURL.pathComponents.count - rootDepth
                if depth > 4 { enumerator.skipDescendants(); continue }
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
                if values?.isDirectory == true {
                    let name = url.lastPathComponent
                    if depth == 2, name == "memory" || name == "tool-results" || name == "scratchpad" { enumerator.skipDescendants() }
                    continue
                }
                guard url.pathExtension == "jsonl", let classified = ProjectPathEncoding.classify(url, root: root) else { continue }
                let modified = values?.contentModificationDate ?? .distantPast
                guard modified >= cutoff else { continue }
                found.append((url, classified, modified))
            }
            // Main transcripts first (oldest first), then subagents, so sessions exist before their agents.
            let mains = found.filter { if case .main = $0.1 { true } else { false } }.sorted { $0.2 < $1.2 }
            let subs = found.filter { if case .subagent = $0.1 { true } else { false } }.sorted { $0.2 < $1.2 }
            for (url, classified, _) in mains + subs { emit(url: url, classified: classified, root: root) }
        }
    }

    private func scheduleRetry() {
        state.withLock { s in
            s.retry?.cancel()
            s.retry = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    try? await self.clock.sleep(for: 30)
                    let missing: [URL] = self.state.withLock { st in
                        st.roots.filter { st.watched[$0.path] == nil }
                    }
                    for root in missing { self.watch(root) }
                }
            }
        }
    }
}
