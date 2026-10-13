import CryptoKit
import Foundation
import Synchronization

/// The `Sec-MS-GEC` proof and clock-skew correction (document 06 §2.2).
public enum EdgeDRM {
    public static let windowsEpochOffset: Double = 11_644_473_600
    private static let skew = Mutex<Double>(0)

    public static var clockSkewSeconds: Double {
        get { skew.withLock { $0 } }
        set { skew.withLock { $0 = newValue } }
    }

    public static func secMSGEC(now: Date = Date(), skew: Double? = nil) -> String {
        var ticks = now.timeIntervalSince1970 + (skew ?? clockSkewSeconds)
        ticks += windowsEpochOffset
        ticks -= ticks.truncatingRemainder(dividingBy: 300)
        ticks *= 10_000_000
        let s = String(format: "%.0f", ticks) + EdgeConstants.trustedClientToken
        return SHA256.hash(data: Data(s.utf8)).map { String(format: "%02X", $0) }.joined()
    }

    public static func connectionID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    public static func muid() -> String {
        (0..<16).map { _ in String(format: "%02X", UInt8.random(in: 0...255)) }.joined()
    }

    /// Parses an RFC 2616 `Date` header in UTC.
    public static func parseHTTPDate(_ value: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: value)
    }

    public static func webSocketURL(now: Date = Date()) -> URL {
        let s = EdgeConstants.wssURL + "&ConnectionId=\(connectionID())&Sec-MS-GEC=\(secMSGEC(now: now))&Sec-MS-GEC-Version=\(EdgeConstants.secMSGECVersion)"
        // swiftlint:disable:next force_unwrapping
        return URL(string: s)!
    }
}
