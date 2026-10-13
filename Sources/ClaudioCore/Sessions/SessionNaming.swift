import Foundation

/// Title resolution and duplicate suffixing (document 03 §8.2).
public enum SessionNaming {
    /// Priority: ai-title → hook session_title → probe name → cwd folder → id prefix.
    public static func baseTitle(aiTitle: String?, hookTitle: String?, probeName: String?, cwd: URL?, id: SessionID,
                                 projectDisplayName: String? = nil) -> String {
        if let p = projectDisplayName, !p.isEmpty { return p }
        if let t = aiTitle, !t.isEmpty { return t }
        if let t = hookTitle, !t.isEmpty { return t }
        if let n = probeName, !n.isEmpty { return n }
        if let cwd, !cwd.lastPathComponent.isEmpty, cwd.lastPathComponent != "/" { return cwd.lastPathComponent }
        return String(id.prefix(8))
    }

    /// Applies " (<folder>)" or " (<id prefix>)" suffixes to live sessions sharing a display title.
    public static func disambiguate(_ sessions: [Session]) -> [SessionID: String] {
        var result: [SessionID: String] = [:]
        let live = sessions.filter(\.isLive)
        let groups = Dictionary(grouping: live, by: \.baseTitle)
        for session in sessions {
            guard session.isLive, let group = groups[session.baseTitle], group.count > 1 else {
                result[session.id] = session.baseTitle
                continue
            }
            let folders = Set(group.map { $0.cwd.lastPathComponent })
            if folders.count == group.count {
                result[session.id] = "\(session.baseTitle) (\(session.cwd.lastPathComponent))"
            } else {
                result[session.id] = "\(session.baseTitle) (\(session.id.prefix(8)))"
            }
        }
        return result
    }
}
