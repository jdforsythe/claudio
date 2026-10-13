import Foundation

/// Installs the `/speak` skill into `~/.claude/skills/speak/SKILL.md` (document 04 §8).
public struct SkillInstaller: Sendable {
    public static let marker = "<!-- claudio-skill v1 -->"

    public enum SkillError: Error, Equatable {
        case foreignSkillPresent
    }

    public let skillDirectory: URL
    public let cliPath: String?

    public init(skillDirectory: URL, cliPath: String?) {
        self.skillDirectory = skillDirectory
        self.cliPath = cliPath
    }

    public var fileURL: URL { skillDirectory.appendingPathComponent("SKILL.md") }

    public func isInstalled() -> Bool {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return false }
        return text.contains(Self.marker)
    }

    public func install() throws {
        if let existing = try? String(contentsOf: fileURL, encoding: .utf8), !existing.contains(Self.marker) {
            throw SkillError.foreignSkillPresent
        }
        try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        try AtomicFile.write(Data(Self.content(cliPath: cliPath).utf8), to: fileURL)
    }

    public func uninstall() throws {
        guard isInstalled() else { return }
        try FileManager.default.removeItem(at: fileURL)
        if let remaining = try? FileManager.default.contentsOfDirectory(atPath: skillDirectory.path), remaining.isEmpty {
            try? FileManager.default.removeItem(at: skillDirectory)
        }
    }

    public static func content(cliPath: String?) -> String {
        let path = cliPath ?? "/Applications/Claudio.app/Contents/Helpers/claudio"
        return """
        ---
        name: speak
        description: Control Claudio voice output for this session — toggle, set level (quiet/answers/narrate), switch the active session, pause, skip, or catch up to live
        ---
        \(marker)
        # Claudio voice control

        Claudio is a menu bar app that reads Claude Code sessions aloud. This skill controls it for the current session.

        ## Usage
        /speak                     Make this session the active (spoken) one
        /speak on                  Same as above
        /speak off                 Set this session to quiet (events only)
        /speak quiet|answers|narrate   Set this session's level
        /speak pause | resume | toggle
        /speak skip                Skip the current sentence
        /speak live                Abandon catch-up, jump to live
        /speak status
        /speak sessions

        ## Instructions
        Run exactly one of the following shell commands based on the argument, then report its output in one line. Do not add commentary. `CLAUDIO` resolves to the bundled CLI; fall back to the symlink.

        CLAUDIO="\(path)"; [ -x "$CLAUDIO" ] || CLAUDIO="claudio"

        - no argument or `on`:     $CLAUDIO switch
        - `off`:                   $CLAUDIO level quiet
        - `quiet`/`answers`/`narrate`: $CLAUDIO level <arg>
        - `pause`/`resume`/`toggle`/`skip`/`live`/`status`/`sessions`: $CLAUDIO <arg>

        The CLI identifies this session from $CLAUDE_CODE_SESSION_ID automatically. If the command exits 1, tell the user "Claudio is not running" and stop.

        """
    }
}
