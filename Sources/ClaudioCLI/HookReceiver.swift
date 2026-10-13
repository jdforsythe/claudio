import ClaudioControlProtocol
import Foundation

/// The hot path: stdin → one NDJSON line → socket → exit 0 (document 04 §4). No ArgumentParser, no Foundation JSON.
enum HookReceiver {
    static let stdinDeadlineMs: Int32 = 50
    static let maxBytes = 1_048_576

    static func run() -> Int32 {
        let debug = ProcessInfo.processInfo.environment["CLAUDIO_HOOK_DEBUG"] == "1"
        let input = readStdin()
        guard let payload = validate(input),
              let event = extract(key: "hook_event_name", from: payload),
              let session = extract(key: "session_id", from: payload) else {
            if debug { FileHandle.standardError.write(Data("claudio hook: invalid payload\n".utf8)) }
            return 0
        }
        var line = Data("{\"v\":1,\"kind\":\"hook\",\"event\":\"\(event)\",\"session\":\"\(session)\",\"payload\":".utf8)
        line.append(payload)
        line.append(Data("}\n".utf8))
        let path = SocketPath.resolve()
        let client = ControlClient(socketPath: path, connectTimeoutMs: 20)
        do {
            let fd = try client.connect()
            defer { close(fd) }
            var offset = 0
            line.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                while offset < raw.count {
                    let n = write(fd, base + offset, raw.count - offset)
                    if n <= 0 { if errno == EINTR { continue } else { break } }
                    offset += n
                }
            }
            shutdown(fd, SHUT_WR)
            if debug { FileHandle.standardError.write(Data("claudio hook: forwarded \(event) for \(session.prefix(8)) (\(line.count) bytes)\n".utf8)) }
        } catch {
            if debug { FileHandle.standardError.write(Data("claudio hook: app not running (\(error))\n".utf8)) }
        }
        return 0
    }

    static func readStdin() -> Data {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        let start = Date()
        while buffer.count < maxBytes {
            let elapsed = Int32(Date().timeIntervalSince(start) * 1000)
            let remaining = stdinDeadlineMs - elapsed
            if remaining <= 0 { break }
            var pfd = pollfd(fd: 0, events: Int16(POLLIN), revents: 0)
            let pr = poll(&pfd, 1, remaining)
            if pr <= 0 { break }
            let n = read(0, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
        }
        return buffer
    }

    /// First non-whitespace byte `{`, last `}`; returns the trimmed object bytes.
    static func validate(_ data: Data) -> Data? {
        let ws: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]
        guard let first = data.firstIndex(where: { !ws.contains($0) }), data[first] == 0x7B,
              let last = data.lastIndex(where: { !ws.contains($0) }), data[last] == 0x7D, last > first else { return nil }
        return data[first...last]
    }

    /// Byte scan for `"key":"value"` (top-level keys in every payload Claude Code produces).
    static func extract(key: String, from data: Data) -> String? {
        let needle = Array("\"\(key)\"".utf8)
        let bytes = Array(data)
        guard bytes.count > needle.count else { return nil }
        var i = 0
        while i + needle.count <= bytes.count {
            if Array(bytes[i..<(i + needle.count)]) == needle {
                var j = i + needle.count
                while j < bytes.count, bytes[j] == 0x20 || bytes[j] == 0x3A { j += 1 }
                guard j < bytes.count, bytes[j] == 0x22 else { return nil }
                j += 1
                var out: [UInt8] = []
                while j < bytes.count, bytes[j] != 0x22 {
                    if bytes[j] == 0x5C, j + 1 < bytes.count { j += 1 }
                    out.append(bytes[j])
                    j += 1
                }
                let value = String(decoding: out, as: UTF8.self)
                return value.isEmpty ? nil : value
            }
            i += 1
        }
        return nil
    }
}
