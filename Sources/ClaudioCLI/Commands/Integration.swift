import ArgumentParser
import ClaudioControlProtocol
import Foundation

struct Hooks: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Manage Claude Code hook entries.",
                                                    subcommands: [HooksStatus.self, HooksInstall.self, HooksUninstall.self],
                                                    defaultSubcommand: HooksStatus.self)

    struct HooksStatus: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "status", abstract: "Show hook installation state.")
        @OptionGroup var options: GlobalOptions
        func run() { CLI(options: options).run(.hooksStatus) { r in if case .hooks(let h) = r { h.humanDescription } else { nil } } }
    }

    struct HooksInstall: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "install", abstract: "Install Claudio's hooks into ~/.claude/settings.json.")
        @OptionGroup var options: GlobalOptions
        func run() { CLI(options: options).run(.hooksInstall) { r in if case .hooks(let h) = r { h.humanDescription } else { nil } } }
    }

    struct HooksUninstall: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "uninstall", abstract: "Remove Claudio's hooks only.")
        @OptionGroup var options: GlobalOptions
        func run() { CLI(options: options).run(.hooksUninstall) { r in if case .hooks(let h) = r { h.humanDescription } else { nil } } }
    }
}

struct Link: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Create or remove /usr/local/bin/claudio.")
    @OptionGroup var options: GlobalOptions
    @Flag(name: .long, help: "Remove the symlink.") var remove = false
    func run() { CLI(options: options).run(.link(!remove)) { r in if case .text(let t) = r { t } else { nil } } }
}

struct SkillCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "skill", abstract: "Install or remove the /speak skill.",
                                                    subcommands: [SkillInstall.self, SkillUninstall.self])

    struct SkillInstall: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "install")
        @OptionGroup var options: GlobalOptions
        func run() { CLI(options: options).run(.skill(install: true)) { r in if case .text(let t) = r { t } else { nil } } }
    }

    struct SkillUninstall: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "uninstall")
        @OptionGroup var options: GlobalOptions
        func run() { CLI(options: options).run(.skill(install: false)) { r in if case .text(let t) = r { t } else { nil } } }
    }
}

struct Voices: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List voices for a backend.")
    @OptionGroup var options: GlobalOptions
    @Option(name: .long, help: "edge, apple or openai (default: the configured backend)") var backend: String?
    @Flag(name: .long, help: "Shortcut for --backend apple.") var apple = false

    func run() {
        let b = apple ? "apple" : backend
        CLI(options: options).run(.voices(backend: b)) { r in
            guard case .voices(let list) = r else { return nil }
            var lines = list.map { v in
                "\(v.id.padding(toLength: 44, withPad: " ", startingAt: 0)) \(v.displayName) \(v.gender ?? "")"
            }
            if b == "apple", !list.contains(where: { $0.quality == "premium" || $0.quality == "enhanced" }) {
                lines.append("For better Apple voices, download a Premium voice in System Settings → Accessibility → Spoken Content → System Voice → Manage Voices, then relaunch Claudio.")
            }
            return lines.joined(separator: "\n")
        }
    }
}

struct Update: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check GitHub for a newer Claudio; --install downloads it, replaces the app and relaunches.")
    @OptionGroup var options: GlobalOptions
    @Flag(name: .long, help: "Install the update if one is available.") var install = false
    func run() {
        let cli = CLI(options: options)
        let response = (try? cli.client.send(.update(install: install), readTimeoutMs: 120_000)) ?? ControlResponse.failure("Claudio is not running")
        if options.json { print(CLI.jsonString(response)); return }
        if case .text(let t)? = response.result { print(t) } else { cli.fail(response.error ?? "Claudio is not running", code: CLIExit.notRunning) }
    }
}

struct Uninstall: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Remove hooks, the /speak skill and the CLI symlink; --all also removes app data.")
    @OptionGroup var options: GlobalOptions
    @Flag(name: .long, help: "Also remove Application Support, logs, Keychain item and preferences after quitting the app.") var all = false

    func run() {
        let cli = CLI(options: options)
        var removed: [String] = []
        if let r = try? cli.client.send(.hooksUninstall), r.ok { removed.append("hook entries in ~/.claude/settings.json") }
        if let r = try? cli.client.send(.skill(install: false)), r.ok { removed.append("~/.claude/skills/speak") }
        if let r = try? cli.client.send(.link(false)), r.ok { removed.append("/usr/local/bin/claudio") }
        if all {
            _ = try? cli.client.send(.quit)
            Thread.sleep(forTimeInterval: 1.0)
            let home = NSHomeDirectory()
            let fm = FileManager.default
            for path in ["\(home)/Library/Application Support/Claudio", "\(home)/Library/Logs/Claudio"] where fm.fileExists(atPath: path) {
                try? fm.removeItem(atPath: path)
                removed.append(path.replacingOccurrences(of: home, with: "~"))
            }
            UserDefaults.standard.removePersistentDomain(forName: "com.jdforsythe.claudio")
            removed.append("UserDefaults domain com.jdforsythe.claudio")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            process.arguments = ["delete-generic-password", "-s", "com.jdforsythe.claudio", "-a", "openai"]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 { removed.append("Keychain item") }
        }
        if !options.quiet {
            for item in removed { print("Removed \(item)") }
            if removed.isEmpty { print("Nothing to remove (is Claudio running?)") }
            print("Drag Claudio.app to the Trash to finish.")
        }
    }
}
