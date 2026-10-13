import Foundation
import Synchronization

/// Writes response lines back to one client connection.
public final class ResponseWriter: Sendable {
    private let fd: Int32
    private let closed = Mutex(false)

    init(fd: Int32) { self.fd = fd }

    @discardableResult
    public func write(_ response: ControlResponse) -> Bool {
        guard let data = try? ControlCoding.encodeLine(response) else { return false }
        return writeAll(data)
    }

    private func writeAll(_ data: Data) -> Bool {
        if closed.withLock({ $0 }) { return false }
        var offset = 0
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            while offset < raw.count {
                let n = Foundation.write(fd, base + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += n
            }
            return true
        }
    }

    func close() {
        let was = closed.withLock { c -> Bool in
            let w = c
            c = true
            return w
        }
        if !was { Foundation.close(fd) }
    }

    public var isClosed: Bool { closed.withLock { $0 } }
}

/// Unix-socket listener (document 04 §5). One request per connection; subscriptions stream until the client closes.
public final class ControlServer: Sendable {
    public typealias Handler = @Sendable (ControlEnvelope, ResponseWriter) async -> Void

    public enum ServerError: Error, Equatable {
        case anotherInstanceRunning
        case bindFailed(Int32)
        case listenFailed(Int32)
    }

    public static let readDeadlineMs: Int32 = 2000
    public static let maxConnections = 64

    private let path: String
    private let handler: Handler
    private let log = Log.control
    private let acceptQueue = DispatchQueue(label: "com.jdforsythe.claudio.control.accept")
    private let workQueue = DispatchQueue(label: "com.jdforsythe.claudio.control.work", attributes: .concurrent)
    private let state = Mutex<(fd: Int32, source: UncheckedSendable<(any DispatchSourceRead)>?, active: Int)>((fd: -1, source: nil, active: 0))

    public init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    public var socketPath: String { path }

    public func start() throws {
        // Stale socket handling: only replace when a connect attempt is refused.
        if FileManager.default.fileExists(atPath: path) {
            let client = ControlClient(socketPath: path, connectTimeoutMs: 500)
            if let fd = try? client.connect() {
                close(fd)
                throw ServerError.anotherInstanceRunning
            }
            unlink(path)
            log.notice("replaced stale socket at \(path)")
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.bindFailed(errno) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw ServerError.bindFailed(ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bound == 0 else {
            let err = errno
            close(fd)
            throw ServerError.bindFailed(err)
        }
        chmod(path, 0o600)
        guard listen(fd, 64) == 0 else {
            let err = errno
            close(fd)
            unlink(path)
            throw ServerError.listenFailed(err)
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptPending(listenFD: fd) }
        source.resume()
        state.withLock { s in
            s.fd = fd
            s.source = UncheckedSendable(source)
        }
        log.info("control socket listening at \(path)")
    }

    public func stop() {
        let (fd, source) = state.withLock { s -> (Int32, UncheckedSendable<(any DispatchSourceRead)>?) in
            let out = (s.fd, s.source)
            s.fd = -1
            s.source = nil
            return out
        }
        source?.value.cancel()
        if fd >= 0 { close(fd) }
        unlink(path)
    }

    private func acceptPending(listenFD: Int32) {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 { return }
            let overloaded = state.withLock { s -> Bool in
                if s.active >= Self.maxConnections { return true }
                s.active += 1
                return false
            }
            if overloaded {
                close(client)
                continue
            }
            workQueue.async { [weak self] in
                self?.serve(client)
            }
        }
    }

    private func serve(_ fd: Int32) {
        defer { state.withLock { $0.active -= 1 } }
        guard let line = readLine(fd: fd) else {
            close(fd)
            return
        }
        let envelope: ControlEnvelope
        do {
            envelope = try ControlCoding.decoder().decode(ControlEnvelope.self, from: line)
        } catch {
            let writer = ResponseWriter(fd: fd)
            writer.write(.failure("malformed request: \(error)"))
            writer.close()
            return
        }
        let writer = ResponseWriter(fd: fd)
        if envelope.v > ControlProtocolVersion.current {
            writer.write(.failure("protocol version \(envelope.v) not supported; update Claudio.app"))
            writer.close()
            return
        }
        if envelope.kind == "hook" {
            writer.close()
            Task { await self.handler(envelope, ResponseWriter(fd: -1)) }
            return
        }
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await self.handler(envelope, writer)
            writer.close()
            semaphore.signal()
        }
        semaphore.wait()
    }

    private func readLine(fd: Int32) -> Data? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pr = poll(&pfd, 1, Self.readDeadlineMs)
            if pr <= 0 { return nil }
            let n = read(fd, &chunk, chunk.count)
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if n == 0 { return buffer.isEmpty ? nil : buffer }
            if let nl = chunk[0..<n].firstIndex(of: 0x0A) {
                buffer.append(contentsOf: chunk[0..<nl])
                return buffer
            }
            buffer.append(contentsOf: chunk[0..<n])
            if buffer.count > ControlCoding.maxLineBytes { return nil }
        }
    }
}
