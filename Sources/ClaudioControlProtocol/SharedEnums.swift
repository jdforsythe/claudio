import Foundation

/// Per-session speech filter. Levels are cumulative (document 01 §6).
public enum SpeechLevel: String, Codable, CaseIterable, Sendable {
    case quiet
    case answers
    case narrate

    public var displayName: String {
        switch self {
        case .quiet: "Quiet"
        case .answers: "Answers"
        case .narrate: "Narrate"
        }
    }
}

/// The kind of a speech item (document 01 §5).
public enum ContentCategory: String, Codable, Sendable, CaseIterable {
    case finalAnswer
    case narration
    case toolCall
    case toolResult
    case thinking
    case event
}

public enum SessionStatus: String, Codable, Sendable {
    case busy
    case waiting
    case idle
    case ended
}

public enum SessionEntrypoint: String, Codable, Sendable {
    case cli
    case claudeDesktop
    case orca
    case unknown
}

/// Backend identifier: "edge", "apple", "openai".
public typealias BackendID = String

/// Result of inspecting `~/.claude/settings.json` for Claudio's hook entries (document 04 §3).
public enum HookInstallStatus: Sendable, Equatable, Codable {
    case notInstalled
    case installed(count: Int, bundlePath: String)
    case installedElsewhere(count: Int, bundlePath: String)
    case partial(installed: Int, expected: Int)
    case settingsUnreadable(String)

    public var humanDescription: String {
        switch self {
        case .notInstalled:
            "Hooks are off."
        case .installed(let count, let path):
            "\(count) hooks installed, pointing at \(path)"
        case .installedElsewhere(let count, let path):
            "\(count) hooks installed, but they point at \(path)"
        case .partial(let installed, let expected):
            "\(installed) of \(expected) hooks installed"
        case .settingsUnreadable(let reason):
            "settings.json could not be parsed: \(reason)"
        }
    }
}
