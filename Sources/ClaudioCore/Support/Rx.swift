import Foundation

/// Thin Sendable wrapper over `NSRegularExpression` (Swift `Regex` is not Sendable, so it cannot be a static).
public struct Rx: Sendable {
    public let regex: NSRegularExpression
    public let pattern: String

    public init(_ pattern: String, options: NSRegularExpression.Options = []) {
        self.pattern = pattern
        // swiftlint:disable:next force_try
        self.regex = try! NSRegularExpression(pattern: pattern, options: options)
    }

    public func matches(_ s: String) -> Bool {
        regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    public func firstMatch(_ s: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
    }

    public func replace(_ s: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    /// Replacement with a closure receiving capture groups (group 0 is the whole match).
    public func replace(_ s: String, _ transform: ([String]) -> String) -> String {
        let ns = s as NSString
        let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return s }
        var out = ""
        var cursor = 0
        for m in matches {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            var groups: [String] = []
            for i in 0..<m.numberOfRanges {
                let r = m.range(at: i)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            out += transform(groups)
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    public func captures(_ s: String) -> [String]? {
        guard let m = firstMatch(s) else { return nil }
        let ns = s as NSString
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }
}
