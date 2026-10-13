import ArgumentParser
import ClaudioControlProtocol
import Foundation

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show playback state, active session, backend and hooks.")
    @OptionGroup var options: GlobalOptions

    func run() {
        CLI(options: options).run(.status) { result in
            guard case .status(let s) = result else { return nil }
            var lines: [String] = []
            let uptime = Int(s.uptimeSeconds)
            lines.append("Claudio \(s.version) — running (pid \(s.pid)), uptime \(uptime / 3600)h\(uptime % 3600 / 60)m")
            lines.append("Backend     \(s.backend) (\(s.voice), rate \(String(format: "%.2f", s.rate)))")
            if let a = s.activeSession {
                lines.append("Active      \"\(a.title)\" — \(s.playback), \(a.level.rawValue)")
            } else {
                lines.append("Active      none — \(s.playback)")
            }
            lines.append("Sessions    \(s.sessionsLive) live")
            lines.append("Events      \(s.eventsMuted ? "muted" : "on")")
            lines.append("Hooks       \(s.hooks.humanDescription)")
            lines.append("Socket      \(s.socketPath)")
            if let ratio = s.metrics["unknownRecordRatio"] {
                lines.append(String(format: "Unknown     %.1f%% unknown record types in the last hour", ratio * 100))
            }
            if let p50 = s.metrics["synth.ttfa.p50"], let p95 = s.metrics["synth.ttfa.p95"], p50 > 0 {
                lines.append(String(format: "Synthesis   time-to-first-audio p50 %.0f ms, p95 %.0f ms", p50, p95))
            }
            return lines.joined(separator: "\n")
        }
    }
}

struct Sessions: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List sessions.")
    @OptionGroup var options: GlobalOptions
    @Flag(name: .long, help: "Include ended sessions.") var all = false

    func run() {
        CLI(options: options).run(.sessions) { result in
            guard case .sessions(let list) = result else { return nil }
            let rows = all ? list : list.filter { $0.status != .ended }
            if rows.isEmpty { return "No sessions." }
            var out = ["   TITLE                                   STATUS   LEVEL    UNREAD  CWD                       ID"]
            for s in rows {
                let marker = s.active ? " * " : "   "
                let title = s.title.count > 38 ? String(s.title.prefix(37)) + "…" : s.title.padding(toLength: 38, withPad: " ", startingAt: 0)
                let cwd = s.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~")
                let cwdCol = cwd.count > 25 ? "…" + cwd.suffix(24) : cwd.padding(toLength: 25, withPad: " ", startingAt: 0)
                out.append("\(marker)\(title)  \(s.status.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0))  \(s.level.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0))  \(String(s.unread).padding(toLength: 6, withPad: " ", startingAt: 0))  \(cwdCol) \(s.id.prefix(8))")
            }
            return out.joined(separator: "\n")
        }
    }
}

struct Switch: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Make a session the active (spoken) one.")
    @OptionGroup var options: GlobalOptions
    @Argument(help: "Session id, id prefix, title, or path. Defaults to this session.") var query: String?

    func run() {
        let q = query ?? CLI.inferredSessionQuery()
        CLI(options: options).run(.switch(query: q)) { result in
            guard case .session(let s) = result else { return nil }
            return "Active: \(s.title)"
        }
    }
}

struct Level: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Set a session's speech level.")
    @OptionGroup var options: GlobalOptions
    @Argument(help: "quiet, answers or narrate") var level: String
    @Option(name: .long, help: "Session query; defaults to this session, else the active one.") var session: String?

    func validate() throws {
        guard SpeechLevel(rawValue: level) != nil else { throw ValidationError("level must be quiet, answers or narrate") }
    }

    func run() {
        let l = SpeechLevel(rawValue: level) ?? .answers
        let cli = CLI(options: options)
        let q = session ?? CLI.inferredSessionQuery()
        // Try the inferred session first; the server falls back to the active session when it does not resolve.
        cli.run(.level(l, session: q)) { result in
            guard case .session(let s) = result else { return nil }
            return CLI.sessionLine(s)
        }
    }
}

struct Pause: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Pause playback.")
    @OptionGroup var options: GlobalOptions
    func run() { CLI(options: options).run(.pause) { r in if case .text(let t) = r { t } else { nil } } }
}

struct Resume: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Resume playback.")
    @OptionGroup var options: GlobalOptions
    func run() { CLI(options: options).run(.resume) { r in if case .text(let t) = r { t } else { nil } } }
}

struct Toggle: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Toggle pause.")
    @OptionGroup var options: GlobalOptions
    func run() { CLI(options: options).run(.toggle) { r in if case .text(let t) = r { t } else { nil } } }
}

struct Skip: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Skip the current sentence.")
    @OptionGroup var options: GlobalOptions
    func run() { CLI(options: options).run(.skip) { r in if case .text(let t) = r { t } else { nil } } }
}

struct Live: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Abandon catch-up and jump to live.")
    @OptionGroup var options: GlobalOptions
    func run() { CLI(options: options).run(.live) { r in if case .text(let t) = r { t } else { nil } } }
}

struct Mute: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Mute event announcements.")
    @OptionGroup var options: GlobalOptions
    func run() { CLI(options: options).run(.mute(true)) { r in if case .text(let t) = r { t } else { nil } } }
}

struct Unmute: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Unmute event announcements.")
    @OptionGroup var options: GlobalOptions
    func run() { CLI(options: options).run(.mute(false)) { r in if case .text(let t) = r { t } else { nil } } }
}

struct Say: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Speak text immediately, between sentences.")
    @OptionGroup var options: GlobalOptions
    @Argument(parsing: .captureForPassthrough, help: "Text to speak, or - to read stdin.") var words: [String] = []

    func run() {
        var text = words.joined(separator: " ")
        if text == "-" || text.isEmpty {
            text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty else { CLI(options: options).fail("nothing to say", code: CLIExit.usage) }
        CLI(options: options).run(.say(text: text)) { _ in nil }
    }
}

struct Hook: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Hook receiver (executed by Claude Code).")
    func run() { Foundation.exit(HookReceiver.run()) }
}

struct Version: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print CLI and app versions.")
    @OptionGroup var options: GlobalOptions

    func run() {
        let cli = CLI(options: options)
        if let response = try? cli.client.send(.version), case .text(let app)? = response.result {
            if options.json { print(CLI.jsonString(response)) } else { print("claudio \(BuildInfo.versionString) (app \(app))") }
        } else {
            print("claudio \(BuildInfo.versionString) (app not running)")
        }
    }
}
