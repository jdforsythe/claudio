import ClaudioCore
import Foundation

/// Frame builders and parsers for the Edge read-aloud WebSocket protocol (document 06 §2.3).
public enum EdgeProtocol {
    public struct TextFrame: Equatable, Sendable {
        public let headers: [String: String]
        public let body: String
        public var path: String? { headers["Path"] }
    }

    public struct BinaryFrame: Equatable, Sendable {
        public let headers: [String: String]
        public let payload: Data
        public var path: String? { headers["Path"] }
        public var contentType: String? { headers["Content-Type"] }
    }

    public struct Boundary: Equatable, Sendable {
        public let type: String
        public let offsetSeconds: TimeInterval
        public let durationSeconds: TimeInterval
        public let text: String
    }

    public static func timestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE MMM dd yyyy HH:mm:ss 'GMT+0000 (Coordinated Universal Time)'"
        return f.string(from: date)
    }

    public static func speechConfigFrame(wordBoundaries: Bool, now: Date) -> String {
        let word = wordBoundaries ? "true" : "false"
        let sentence = wordBoundaries ? "false" : "true"
        return "X-Timestamp:\(timestamp(now))\r\n"
            + "Content-Type:application/json; charset=utf-8\r\n"
            + "Path:speech.config\r\n\r\n"
            + "{\"context\":{\"synthesis\":{\"audio\":{\"metadataoptions\":{\"sentenceBoundaryEnabled\":\"\(sentence)\",\"wordBoundaryEnabled\":\"\(word)\"},\"outputFormat\":\"\(EdgeConstants.outputFormat)\"}}}}\r\n"
    }

    public static func rateString(_ rate: Double) -> String {
        let pct = Int(((rate - 1.0) * 100).rounded())
        return pct >= 0 ? "+\(pct)%" : "\(pct)%"
    }

    public static func prepareText(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if v == 0x0A || v == 0x09 {
                out.append(" ")
            } else if v < 0x20 || (v >= 0x7F && v <= 0x9F) || v == 0xFFFE || v == 0xFFFF {
                continue
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    public static func xmlEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    public static func ssml(text: String, voice: String, rate: Double, lang: String = "en-US") -> String {
        "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='\(lang)'><voice name='\(voice)'><prosody pitch='+0Hz' rate='\(rateString(rate))' volume='+0%'>\(xmlEscape(prepareText(text)))</prosody></voice></speak>"
    }

    public static func ssmlFrame(requestID: String, ssml: String, now: Date) throws -> String {
        guard ssml.utf8.count <= EdgeConstants.maxRequestBytes else { throw BackendError.decode("text too long") }
        return "X-RequestId:\(requestID)\r\n"
            + "Content-Type:application/ssml+xml\r\n"
            + "X-Timestamp:\(timestamp(now))Z\r\n"
            + "Path:ssml\r\n\r\n"
            + ssml
    }

    public static func requestID() -> String { EdgeDRM.connectionID() }

    // MARK: Parsing

    static func parseHeaders(_ block: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in block.split(separator: "\r\n", omittingEmptySubsequences: true) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            out[String(line[..<colon])] = String(line[line.index(after: colon)...])
        }
        return out
    }

    public static func parseTextFrame(_ text: String) -> TextFrame {
        if let range = text.range(of: "\r\n\r\n") {
            return TextFrame(headers: parseHeaders(String(text[..<range.lowerBound])), body: String(text[range.upperBound...]))
        }
        return TextFrame(headers: parseHeaders(text), body: "")
    }

    public static func parseBinaryFrame(_ data: Data) throws -> BinaryFrame {
        guard data.count >= 2 else { throw BackendError.decode("malformed binary frame") }
        let headerLength = Int(data[data.startIndex]) << 8 | Int(data[data.startIndex + 1])
        guard headerLength <= data.count - 2 else { throw BackendError.decode("malformed binary frame") }
        let headerData = data[(data.startIndex + 2)..<(data.startIndex + 2 + headerLength)]
        let headers = parseHeaders(String(decoding: headerData, as: UTF8.self))
        let payload = Data(data[(data.startIndex + 2 + headerLength)...])
        return BinaryFrame(headers: headers, payload: payload)
    }

    public static func parseMetadata(_ body: String) -> [Boundary] {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["Metadata"] as? [[String: Any]] else { return [] }
        var out: [Boundary] = []
        for entry in list {
            guard let type = entry["Type"] as? String, let d = entry["Data"] as? [String: Any] else { continue }
            let offset = (d["Offset"] as? NSNumber)?.doubleValue ?? 0
            let duration = (d["Duration"] as? NSNumber)?.doubleValue ?? 0
            let text = ((d["text"] as? [String: Any])?["Text"] as? String) ?? ""
            out.append(Boundary(type: type, offsetSeconds: offset / EdgeConstants.ticksPerSecond,
                                durationSeconds: duration / EdgeConstants.ticksPerSecond, text: htmlUnescape(text)))
        }
        return out
    }

    static func htmlUnescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Locates boundary words in the request text in order (document 06 §2.3).
    public struct WordLocator: Sendable {
        let text: String
        var cursor: String.Index

        public init(text: String) {
            self.text = text
            cursor = text.startIndex
        }

        public mutating func locate(_ word: String) -> Range<String.Index> {
            if !word.isEmpty, let r = text.range(of: word, range: cursor..<text.endIndex) {
                cursor = r.upperBound
                return r
            }
            // Fall back to the next whitespace-delimited token.
            var start = cursor
            while start < text.endIndex, text[start].isWhitespace { start = text.index(after: start) }
            var end = start
            while end < text.endIndex, !text[end].isWhitespace { end = text.index(after: end) }
            cursor = end
            return start..<end
        }
    }
}
