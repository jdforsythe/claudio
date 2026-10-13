import Foundation

/// Minimal POSIX Unix-socket client used by the CLI and the single-instance guard.
/// One request per connection: write one line, shutdown write side, read one line (or many for subscriptions).
public struct ControlClient: Sendable {
    public enum ClientError: Error, Sendable, Equatable {
        case notRunning
        case connectTimeout
        case writeFailed
        case readFailed
        case oversized
        case protocolMismatch(Int)
        case decode(String)
    }

    public let socketPath: String
    public let connectTimeoutMs: Int32

    public init(socketPath: String = SocketPath.resolve(), connectTimeoutMs: Int32 = 500) {
        self.socketPath = socketPath
        self.connectTimeoutMs = connectTimeoutMs
    }

    public func send(_ request: ControlRequest, readTimeoutMs: Int32 = 10_000) throws -> ControlResponse {
        let envelope = ControlEnvelope(request: request)
        let line = try ControlCoding.encodeLine(envelope)
        let fd = try connect()
        defer { close(fd) }
        try writeAll(fd: fd, data: line)
        shutdown(fd, SHUT_WR)
        guard let responseLine = try readLine(fd: fd, timeoutMs: readTimeoutMs) else {
            throw ClientError.readFailed
        }
        return try Self.decodeResponse(responseLine)
    }

    /// Sends a hook envelope with no response expected.
    public func sendHook(_ envelope: ControlEnvelope) throws {
        let line = try ControlCoding.encodeLine(envelope)
        let fd = try connect()
        defer { close(fd) }
        try writeAll(fd: fd, data: line)
        shutdown(fd, SHUT_WR)
    }

    /// Streams responses for a subscription until the server closes or the handler returns false.
    public func subscribe(_ request: ControlRequest, handler: (ControlResponse) -> Bool) throws {
        let envelope = ControlEnvelope(request: request)
        let line = try ControlCoding.encodeLine(envelope)
        let fd = try connect()
        defer { close(fd) }
        try writeAll(fd: fd, data: line)
        shutdown(fd, SHUT_WR)
        while let responseLine = try readLine(fd: fd, timeoutMs: -1) {
            let response = try Self.decodeResponse(responseLine)
            if !handler(response) { return }
        }
    }

    public static func decodeResponse(_ data: Data) throws -> ControlResponse {
        do {
            let response = try ControlCoding.decoder().decode(ControlResponse.self, from: data)
            if response.v > ControlProtocolVersion.current {
                throw ClientError.protocolMismatch(response.v)
            }
            return response
        } catch let e as ClientError {
            throw e
        } catch {
            throw ClientError.decode(String(describing: error))
        }
    }

    // MARK: - POSIX

    public func connect() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClientError.notRunning }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw ClientError.notRunning
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in pathBytes.enumerated() { raw[i] = b }
            raw[pathBytes.count] = 0
        }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Foundation.connect(fd, sa, len)
            }
        }
        if rc != 0 {
            if errno == EINPROGRESS {
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let pr = poll(&pfd, 1, connectTimeoutMs)
                if pr <= 0 {
                    close(fd)
                    throw ClientError.connectTimeout
                }
                var err: Int32 = 0
                var errLen = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &errLen)
                if err != 0 {
                    close(fd)
                    throw ClientError.notRunning
                }
            } else {
                close(fd)
                throw ClientError.notRunning
            }
        }
        _ = fcntl(fd, F_SETFL, flags)
        return fd
    }

    private func writeAll(fd: Int32, data: Data) throws {
        var offset = 0
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            while offset < raw.count {
                let n = write(fd, base + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw ClientError.writeFailed
                }
                offset += n
            }
        }
    }

    /// Reads up to and including a newline; returns nil at EOF with no data.
    private func readLine(fd: Int32, timeoutMs: Int32) throws -> Data? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            if timeoutMs >= 0 {
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let pr = poll(&pfd, 1, timeoutMs)
                if pr <= 0 { throw ClientError.readFailed }
            }
            let n = read(fd, &chunk, chunk.count)
            if n < 0 {
                if errno == EINTR { continue }
                throw ClientError.readFailed
            }
            if n == 0 {
                return buffer.isEmpty ? nil : buffer
            }
            if let nl = chunk[0..<n].firstIndex(of: 0x0A) {
                buffer.append(contentsOf: chunk[0..<nl])
                return buffer
            }
            buffer.append(contentsOf: chunk[0..<n])
            if buffer.count > ControlCoding.maxLineBytes { throw ClientError.oversized }
        }
    }
}
