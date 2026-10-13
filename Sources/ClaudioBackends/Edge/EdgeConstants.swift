import Foundation

/// Everything that has ever changed when Microsoft tightened the protocol lives here (document 06 §2.1, §2.7).
public enum EdgeConstants {
    public static let trustedClientToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    public static let baseHost = "speech.platform.bing.com"
    public static let basePath = "/consumer/speech/synthesize/readaloud"
    public static let wssURL = "wss://\(baseHost)\(basePath)/edge/v1?TrustedClientToken=\(trustedClientToken)"
    public static let voiceListURL = "https://\(baseHost)\(basePath)/voices/list?trustedclienttoken=\(trustedClientToken)"

    public static let chromiumFullVersion = "143.0.3650.75"
    public static var chromiumMajor: String { String(chromiumFullVersion.split(separator: ".").first ?? "143") }
    public static var secMSGECVersion: String { "1-\(chromiumFullVersion)" }

    public static var userAgent: String {
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) "
            + "Chrome/\(chromiumMajor).0.0.0 Safari/537.36 Edg/\(chromiumMajor).0.0.0"
    }

    public static let origin = "chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold"
    public static let outputFormat = "audio-24khz-48kbitrate-mono-mp3"
    public static let ticksPerSecond: Double = 10_000_000
    public static let mp3BitrateBps: Double = 48_000
    public static let maxRequestBytes = 4096
    public static let defaultVoiceID = "en-US-GuyNeural"

    public static func webSocketHeaders(muid: String) -> [(String, String)] {
        [
            ("Pragma", "no-cache"),
            ("Cache-Control", "no-cache"),
            ("Origin", origin),
            ("User-Agent", userAgent),
            ("Accept-Encoding", "gzip, deflate, br, zstd"),
            ("Accept-Language", "en-US,en;q=0.9"),
            ("Cookie", "muid=\(muid);"),
        ]
    }

    public static var voiceListHeaders: [(String, String)] {
        [
            ("Authority", baseHost),
            ("Sec-CH-UA", "\" Not;A Brand\";v=\"99\", \"Microsoft Edge\";v=\"\(chromiumMajor)\", \"Chromium\";v=\"\(chromiumMajor)\""),
            ("Sec-CH-UA-Mobile", "?0"),
            ("User-Agent", userAgent),
            ("Accept", "*/*"),
            ("Sec-Fetch-Site", "none"),
            ("Sec-Fetch-Mode", "cors"),
            ("Sec-Fetch-Dest", "empty"),
            ("Accept-Encoding", "gzip, deflate, br, zstd"),
            ("Accept-Language", "en-US,en;q=0.9"),
        ]
    }

    /// Built-in list used when the voices endpoint is unreachable and no cache exists (document 11 §3.8).
    public static let builtInVoices: [(id: String, name: String, locale: String, gender: String)] = [
        ("en-US-GuyNeural", "Guy", "en-US", "Male"), ("en-US-AriaNeural", "Aria", "en-US", "Female"),
        ("en-US-JennyNeural", "Jenny", "en-US", "Female"), ("en-US-ChristopherNeural", "Christopher", "en-US", "Male"),
        ("en-US-EricNeural", "Eric", "en-US", "Male"), ("en-US-MichelleNeural", "Michelle", "en-US", "Female"),
        ("en-US-RogerNeural", "Roger", "en-US", "Male"), ("en-US-SteffanNeural", "Steffan", "en-US", "Male"),
        ("en-GB-RyanNeural", "Ryan", "en-GB", "Male"), ("en-GB-SoniaNeural", "Sonia", "en-GB", "Female"),
        ("en-AU-NatashaNeural", "Natasha", "en-AU", "Female"), ("en-AU-WilliamNeural", "William", "en-AU", "Male"),
    ]
}
