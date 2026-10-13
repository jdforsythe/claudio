import Foundation

/// Fixed wordings for events and navigation cues (document 05 §10).
public enum Cues {
    /// Prefix marker that makes a cue always-speak regardless of the events toggle.
    public static let marker = "\u{200B}CUE:"

    public static func isCue(_ text: String) -> Bool { text.hasPrefix(marker) }
    public static func mark(_ text: String) -> String { marker + text }
    public static func strip(_ text: String) -> String {
        text.hasPrefix(marker) ? String(text.dropFirst(marker.count)) : text
    }

    public static func finished(_ name: String) -> String { "\(name) finished." }
    public static func needsPermission(_ name: String) -> String { "\(name) needs permission." }
    public static func needsInput(_ name: String) -> String { "\(name) needs input." }
    public static func isWaiting(_ name: String) -> String { "\(name) is waiting." }
    public static func hitError(_ name: String, reason: String) -> String { "\(name) hit an error: \(reason)." }
    public static func catchingUp(_ name: String, turns: Int) -> String {
        "\(name). Catching up on \(turns) \(turns == 1 ? "turn" : "turns")."
    }
    public static func switchedLive(_ name: String) -> String { "\(name). Live." }
    public static func switchedIdle(_ name: String) -> String { "\(name)." }
    public static let live = "Live."
    public static let caughtUp = "You're caught up."
    public static func voicePreview(_ voiceName: String) -> String {
        "This is \(voiceName). Claudio reads your Claude Code sessions aloud."
    }
    public static let ratePreview = "This is how fast I'll talk."
    public static func levelName(_ level: SpeechLevel) -> String { level.displayName + "." }
}

public enum Chime: String, Sendable, CaseIterable {
    case finished
    case attention
    case switched = "switch"
    case tick

    public var resourceName: String { rawValue }
}
