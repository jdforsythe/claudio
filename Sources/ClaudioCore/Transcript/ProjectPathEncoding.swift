import Foundation

/// cwd ⇄ `~/.claude/projects/<encoded>` (document 03 §1.2).
public enum ProjectPathEncoding {
    public static func encode(_ cwd: String) -> String {
        String(cwd.map { ch in ch.isASCII && (ch.isLetter || ch.isNumber) ? ch : "-" })
    }

    /// Best-effort reverse: `-` → `/`, verified against the filesystem. Falls back to the folder name verbatim.
    public static func decodeBestEffort(_ encoded: String, fileManager: FileManager = .default) -> String {
        let candidate = encoded.replacingOccurrences(of: "-", with: "/")
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: candidate, isDirectory: &isDir), isDir.boolValue {
            return candidate
        }
        return encoded
    }

    static let uuidPattern = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
    public static let mainTranscriptPattern = Rx("^" + uuidPattern + "\\.jsonl$")
    public static let subagentPattern = Rx("^agent-[0-9a-z]+\\.jsonl$")
    public static let sessionIDPattern = Rx("^" + uuidPattern + "$")

    public enum Classified: Equatable, Sendable {
        case main(sessionID: SessionID, projectDir: URL)
        case subagent(sessionID: SessionID, agentID: String, projectDir: URL)
    }

    /// Classifies a path relative to a `projects` root.
    public static func classify(_ url: URL, root: URL) -> Classified? {
        guard url.pathExtension == "jsonl" else { return nil }
        let rootComponents = root.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        guard components.count > rootComponents.count,
              Array(components.prefix(rootComponents.count)) == rootComponents else { return nil }
        let rel = Array(components.dropFirst(rootComponents.count))
        let name = url.lastPathComponent
        if rel.count == 2, mainTranscriptPattern.matches(name) {
            return .main(sessionID: String(name.dropLast(6)), projectDir: URL(fileURLWithPath: url.deletingLastPathComponent().path))
        }
        if rel.count == 4, rel[2] == "subagents", subagentPattern.matches(name),
           sessionIDPattern.matches(rel[1]) {
            let agentID = String(name.dropFirst(6).dropLast(6))
            let projectDir = url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            return .subagent(sessionID: rel[1], agentID: agentID, projectDir: URL(fileURLWithPath: projectDir.path))
        }
        return nil
    }
}
