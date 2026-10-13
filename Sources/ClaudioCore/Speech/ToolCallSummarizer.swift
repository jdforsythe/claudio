import Foundation

/// Turns a `tool_use` block into a short spoken phrase (document 05 §3).
public struct ToolCallSummarizer: Sendable {
    public static let wordCap = 12
    public static let dedupeWindow: TimeInterval = 5
    public static let silentTools: Set<String> = ["ToolSearch", "ListAgents", "Monitor"]

    public init() {}

    /// Pure summary with no dedupe; returns nil for tools that are never spoken.
    public func summarize(toolName: String, input: [String: JSONValue]) -> String? {
        if Self.silentTools.contains(toolName) { return nil }
        let raw: String
        switch toolName {
        case "Bash":
            if let d = input["description"]?.stringValue, !d.isEmpty, d.split(separator: " ").count <= 12 {
                raw = d
            } else {
                let command = input["command"]?.stringValue ?? ""
                let words = command.split(whereSeparator: \.isWhitespace).map(String.init)
                    .filter { !$0.hasPrefix("-") }
                    .prefix(8)
                raw = "Running: " + words.joined(separator: " ")
            }
        case "Read":
            raw = "Reading " + Self.filename(input["file_path"]?.stringValue)
        case "Edit", "MultiEdit":
            raw = "Editing " + Self.filename(input["file_path"]?.stringValue)
        case "Write":
            raw = "Writing " + Self.filename(input["file_path"]?.stringValue)
        case "NotebookEdit":
            raw = "Editing " + Self.filename(input["notebook_path"]?.stringValue)
        case "Grep":
            let pattern = input["pattern"]?.stringValue ?? ""
            let cleaned = pattern.replacingOccurrences(of: #"[\\^$.|?*+()\[\]{}]"#, with: " ", options: .regularExpression)
            let words = cleaned.split(whereSeparator: \.isWhitespace).prefix(6).joined(separator: " ")
            raw = "Searching for " + (words.isEmpty ? "a pattern" : words)
        case "Glob":
            let pattern = input["pattern"]?.stringValue ?? ""
            raw = "Finding " + Self.globPhrase(pattern)
        case "Agent", "Task":
            let d = input["description"]?.stringValue ?? input["subagent_type"]?.stringValue ?? "agent"
            raw = "Agent started: " + d
        case "Skill":
            let name = input["skill"]?.stringValue ?? input["name"]?.stringValue ?? "skill"
            raw = "Using skill " + name.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: ":", with: " ")
        case "WebFetch":
            let url = input["url"]?.stringValue ?? ""
            let host = URL(string: url)?.host ?? url
            raw = "Fetching " + host.replacingOccurrences(of: "www.", with: "")
        case "WebSearch":
            let q = input["query"]?.stringValue ?? ""
            raw = "Searching the web for " + q.split(whereSeparator: \.isWhitespace).prefix(6).joined(separator: " ")
        case "TodoWrite", "TaskCreate", "TaskUpdate", "TaskList", "TaskGet":
            raw = "Updating tasks"
        case "AskUserQuestion":
            raw = "Asking a question"
        case "EnterPlanMode":
            raw = "Entering plan mode"
        case "ExitPlanMode":
            raw = "Leaving plan mode"
        default:
            if toolName.hasPrefix("mcp__") {
                let parts = toolName.dropFirst(5).components(separatedBy: "__")
                let server = (parts.first ?? "").replacingOccurrences(of: "claude_ai_", with: "")
                    .replacingOccurrences(of: "plugin_", with: "").replacingOccurrences(of: "_", with: " ")
                let tool = parts.dropFirst().joined(separator: " ").replacingOccurrences(of: "_", with: " ")
                raw = "Calling " + [server, tool].filter { !$0.isEmpty }.joined(separator: " ")
            } else {
                raw = "Using " + Self.splitCamel(toolName)
            }
        }
        return Self.postProcess(raw)
    }

    public static func postProcess(_ raw: String) -> String {
        var words = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.count > wordCap { words = Array(words.prefix(wordCap)) }
        var s = words.joined(separator: " ")
        while let last = s.last, ".,;:!?".contains(last) { s.removeLast() }
        s = s.trimmingCharacters(in: .whitespaces)
        return s + "."
    }

    static func filename(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return "a file" }
        let name = (path as NSString).lastPathComponent
        return SpeechTextRenderer.inlineCodeCleanup(name)
    }

    static func globPhrase(_ pattern: String) -> String {
        let ext = pattern.split(separator: ".").last.map(String.init) ?? ""
        if pattern.hasSuffix("*." + ext), !ext.isEmpty, !ext.contains("*") {
            return "\(ext) files"
        }
        return SpeechTextRenderer.inlineCodeCleanup(pattern.replacingOccurrences(of: "*", with: " ").replacingOccurrences(of: "/", with: " "))
    }

    public static func splitCamel(_ s: String) -> String {
        let chars = Array(s)
        var out = ""
        for (i, ch) in chars.enumerated() {
            if i > 0, ch.isUppercase {
                let p = chars[i - 1]
                let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
                if p.isLowercase || p.isNumber || (p.isUppercase && next?.isLowercase == true) { out.append(" ") }
            }
            out.append(ch)
        }
        return out
    }
}

/// Consecutive-dedupe state, one per session (document 05 §3 post-processing rule 3).
public struct ToolCallDeduper: Sendable {
    private var last: (text: String, at: Date)?
    public init() {}

    public mutating func accept(_ text: String, at: Date) -> Bool {
        if let l = last, l.text == text, at.timeIntervalSince(l.at) < ToolCallSummarizer.dedupeWindow {
            return false
        }
        last = (text, at)
        return true
    }
}
