import ArgumentParser
import ClaudioControlProtocol
import Foundation

struct GlobalOptions: ParsableArguments {
    @Flag(name: .long, help: "Print the raw ControlResponse JSON.")
    var json = false

    @Option(name: .long, help: "Override the control socket path.")
    var socket: String?

    @Flag(name: [.short, .long], help: "Suppress human output; exit code only.")
    var quiet = false
}

enum CLIExit {
    static let notRunning: Int32 = 1
    static let rejected: Int32 = 2
    static let usage: Int32 = 3
    static let protocolMismatch: Int32 = 4
}

/// Shared request/response plumbing for every subcommand (document 04 §7).
struct CLI {
    let options: GlobalOptions

    var client: ControlClient {
        ControlClient(socketPath: options.socket ?? SocketPath.resolve(), connectTimeoutMs: 500)
    }

    func send(_ request: ControlRequest) -> ControlResponse {
        do {
            return try client.send(request)
        } catch ControlClient.ClientError.protocolMismatch(let v) {
            fail("protocol version \(v) not supported; update Claudio.app", code: CLIExit.protocolMismatch)
        } catch {
            fail("Claudio is not running", code: CLIExit.notRunning)
        }
    }

    func fail(_ message: String, code: Int32) -> Never {
        if !options.quiet { FileHandle.standardError.write(Data((message + "\n").utf8)) }
        exit(code)
    }

    /// Sends, prints JSON when requested, and returns the result or exits 2 on rejection.
    @discardableResult
    func run(_ request: ControlRequest, human: (ControlResult) -> String?) -> ControlResult? {
        let response = send(request)
        if options.json {
            print(Self.jsonString(response))
            if !response.ok { exit(CLIExit.rejected) }
            return response.result
        }
        guard response.ok else { fail(response.error ?? "request rejected", code: CLIExit.rejected) }
        if !options.quiet, let text = human(response.result ?? .none) { print(text) }
        return response.result
    }

    static func jsonString<T: Encodable>(_ value: T) -> String {
        let encoder = ControlCoding.encoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// "This session" from the caller's environment (document 04 §7.4).
    static func inferredSessionQuery() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let id = env["CLAUDE_CODE_SESSION_ID"], !id.isEmpty { return "id:" + id }
        if let orca = env["ORCA_WORKTREE_PATH"], !orca.isEmpty { return orca }
        if let pwd = env["PWD"], !pwd.isEmpty { return pwd }
        return FileManager.default.currentDirectoryPath
    }

    static func sessionLine(_ s: SessionSummary) -> String {
        "\(s.title): \(s.level.rawValue)"
    }
}

struct Claudio: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "claudio",
        abstract: "Control Claudio, the menu bar app that reads Claude Code sessions aloud.",
        version: BuildInfo.versionString,
        subcommands: [
            Status.self, Sessions.self, Switch.self, Level.self, Pause.self, Resume.self, Toggle.self, Skip.self, Live.self,
            Mute.self, Unmute.self, Say.self, Hook.self, Hooks.self, Link.self, SkillCommand.self, Version.self, Doctor.self,
            Tail.self, Render.self, Bench.self, Voices.self, Debug.self, Update.self, Uninstall.self,
        ]
    )
}
