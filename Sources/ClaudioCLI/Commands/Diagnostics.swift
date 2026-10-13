import ArgumentParser
import ClaudioControlProtocol
import Foundation

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check the installation and report PASS/WARN/FAIL per item.")
    @OptionGroup var options: GlobalOptions
    @Flag(name: .long, help: "Write a support bundle zip to the Desktop.") var bundle = false

    func run() {
        var checks: [DoctorCheck] = []
        let cli = CLI(options: options)
        let home = NSHomeDirectory()
        let settingsPath = (ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? "\(home)/.claude") + "/settings.json"
        if let data = FileManager.default.contents(atPath: settingsPath) {
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                checks.append(DoctorCheck(name: "settings.json", state: obj["hooks"] == nil ? "warn" : "pass",
                                          detail: obj["hooks"] == nil ? "parses, no hooks key" : "parses"))
            } else {
                checks.append(DoctorCheck(name: "settings.json", state: "fail", detail: "invalid JSON at \(settingsPath)"))
            }
        } else {
            checks.append(DoctorCheck(name: "settings.json", state: "warn", detail: "missing (\(settingsPath))"))
        }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
        if exe.contains("/Applications/Claudio.app/") {
            checks.append(DoctorCheck(name: "App location", state: "pass", detail: "/Applications/Claudio.app"))
        } else if exe.contains("Claudio.app/") {
            checks.append(DoctorCheck(name: "App location", state: "warn", detail: "bundle outside /Applications (login item may not persist)"))
        } else {
            checks.append(DoctorCheck(name: "App location", state: "warn", detail: "unbundled binary"))
        }
        var running = false
        if let response = try? cli.client.send(.doctor), response.ok, case .doctor(let remote)? = response.result {
            running = true
            checks.insert(DoctorCheck(name: "App running", state: "pass", detail: "socket ping succeeded"), at: 0)
            checks.append(contentsOf: remote)
        } else {
            checks.insert(DoctorCheck(name: "App running", state: "fail", detail: "no socket at \(SocketPath.resolve()) or connection refused"), at: 0)
        }
        if options.json {
            print(CLI.jsonString(checks))
        } else {
            for c in checks {
                print("\(c.state.uppercased().padding(toLength: 5, withPad: " ", startingAt: 0)) \(c.name.padding(toLength: 20, withPad: " ", startingAt: 0)) \(c.detail)")
            }
        }
        if bundle { writeBundle(checks: checks, running: running) }
        if !running { Foundation.exit(2) }
        if checks.contains(where: { $0.state == "fail" }) { Foundation.exit(1) }
    }

    private func writeBundle(checks: [DoctorCheck], running: Bool) {
        let cli = CLI(options: options)
        let fm = FileManager.default
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = f.string(from: Date())
        let dir = fm.temporaryDirectory.appendingPathComponent("claudio-support-\(stamp)")
        try? fm.createDirectory(at: dir.appendingPathComponent("logs"), withIntermediateDirectories: true)
        func write(_ name: String, _ text: String) { try? text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        write("doctor.txt", checks.map { "\($0.state.uppercased()) \($0.name): \($0.detail)" }.joined(separator: "\n"))
        if running {
            if let r = try? cli.client.send(.status) { write("status.json", CLI.jsonString(r)) }
            if let r = try? cli.client.send(.sessions) { write("sessions.json", CLI.jsonString(r)) }
            if let r = try? cli.client.send(.dumpState), case .text(let t)? = r.result { write("state.txt", t) }
        }
        let home = NSHomeDirectory()
        let settingsPath = (ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? "\(home)/.claude") + "/settings.json"
        if let data = fm.contents(atPath: settingsPath), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let hooks = obj["hooks"], let out = try? JSONSerialization.data(withJSONObject: hooks, options: [.prettyPrinted]) {
            try? out.write(to: dir.appendingPathComponent("claude-settings-hooks.json"))
        }
        let logsDir = "\(home)/Library/Logs/Claudio"
        for name in (try? fm.contentsOfDirectory(atPath: logsDir)) ?? [] where name.hasPrefix("claudio.log") {
            try? fm.copyItem(atPath: "\(logsDir)/\(name)", toPath: dir.appendingPathComponent("logs/\(name)").path)
        }
        let env = """
        macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        claudio \(BuildInfo.versionString)
        binary \(CommandLine.arguments[0])
        """
        write("environment.txt", env)
        let zip = "\(home)/Desktop/claudio-support-\(stamp).zip"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", dir.path, zip]
        try? process.run()
        process.waitUntilExit()
        try? fm.removeItem(at: dir)
        print("Support bundle written to \(zip)")
        print("Note: sessions.json includes project paths and session titles; remove it before sharing if needed.")
    }
}

struct Tail: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stream speech items as the app produces them (Ctrl-C to stop).")
    @OptionGroup var options: GlobalOptions
    @Argument(help: "Session query; omit for all sessions.") var query: String?
    @Flag(name: .long, help: "Show every session (default when no query is given).") var allSessions = false
    @Flag(name: .long, help: "Print raw registry events instead of speech items.") var raw = false

    func run() {
        let cli = CLI(options: options)
        let kind: SubscriptionKind = raw ? .rawRecords : .items
        do {
            try cli.client.subscribe(.subscribe(kind, session: allSessions ? nil : query)) { response in
                if options.json {
                    print(CLI.jsonString(response))
                    return true
                }
                switch response.result {
                case .item(let i)?:
                    let f = ISO8601DateFormatter()
                    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    print("\(f.string(from: i.timestamp)) \(i.session.prefix(8)) \(i.turn?.prefix(8) ?? "--------") \(i.category.rawValue.padding(toLength: 11, withPad: " ", startingAt: 0)) filtered=\(i.filtered) \(i.text.prefix(80).replacingOccurrences(of: "\n", with: " "))")
                case .record(let type, _, let summary)?:
                    print("\(type) \(summary)")
                default:
                    if let e = response.error { print("error: \(e)") }
                }
                return true
            }
        } catch {
            cli.fail("Claudio is not running", code: CLIExit.notRunning)
        }
    }
}

struct Render: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Render a markdown file to speakable segments.")
    @OptionGroup var options: GlobalOptions
    @Argument(help: "Markdown file, or - for stdin.") var file: String
    @Flag(name: .long, help: "One line per segment with its kind.") var segments = false

    func run() {
        let cli = CLI(options: options)
        let markdown: String
        if file == "-" {
            markdown = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        } else {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { cli.fail("cannot read \(file)", code: CLIExit.usage) }
            markdown = text
        }
        cli.run(.render(markdown: markdown)) { r in
            guard case .segments(let list) = r else { return nil }
            if segments { return list.map { "\($0.kind.padding(toLength: 10, withPad: " ", startingAt: 0)) \($0.text)" }.joined(separator: "\n") }
            return list.map(\.text).joined(separator: "\n")
        }
    }
}

struct Bench: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Measure time-to-first-audio and inter-segment gaps against a real backend.")
    @OptionGroup var options: GlobalOptions
    @Option(name: .long) var backend: String?
    @Option(name: .long) var fixture: String?
    @Option(name: .long) var runs: Int = 3

    func run() {
        CLI(options: options).run(.bench(backend: backend, fixture: fixture, runs: runs)) { r in
            if case .text(let t) = r { t } else { nil }
        }
    }
}

struct Debug: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Hidden diagnostics.", shouldDisplay: false,
                                                    subcommands: [DumpState.self, TailAndSpeak.self])

    struct DumpState: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "dump-state")
        @OptionGroup var options: GlobalOptions
        func run() { CLI(options: options).run(.dumpState) { r in if case .text(let t) = r { t } else { nil } } }
    }

    /// Milestone-1 harness: activate one session at a level through the running app.
    struct TailAndSpeak: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "speak-session", abstract: "Activate a session at a level.")
        @OptionGroup var options: GlobalOptions
        @Argument var session: String
        @Option(name: .long) var level: String = "narrate"
        func run() {
            CLI(options: options).run(.speakSession(session: session, level: SpeechLevel(rawValue: level) ?? .narrate)) { r in
                if case .session(let s) = r { "Active: \(s.title) at \(s.level.rawValue)" } else { nil }
            }
        }
    }
}
