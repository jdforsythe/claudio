import AppKit
import AVFoundation
import CoreAudio
import ClaudioBackends
import ClaudioCore
import Foundation
import ServiceManagement

/// App-side operations the Core dispatcher delegates (document 04 §5.5, document 11 §2).
final class AppControlHost: ControlHostDelegate {
    private let root: CompositionRoot

    @MainActor init(root: CompositionRoot) { self.root = root }

    func linkCLI(_ create: Bool) async throws -> String {
        let paths = await root.paths
        let link = paths.cliSymlink
        let fm = FileManager.default
        if create {
            guard let target = paths.cliExecutable else { throw MessageError("Install the app to enable the claudio command") }
            if fm.isWritableFile(atPath: link.deletingLastPathComponent().path) || !fm.fileExists(atPath: link.deletingLastPathComponent().path) {
                try? fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: link)
                try fm.createSymbolicLink(at: link, withDestinationURL: target)
            } else {
                try Self.privileged("mkdir -p /usr/local/bin && ln -sf \(Self.shellQuote(target.path)) \(Self.shellQuote(link.path))")
            }
            return "Linked \(link.path)"
        }
        guard let dest = try? fm.destinationOfSymbolicLink(atPath: link.path), dest.contains("Claudio.app") || dest.contains("claudio") else {
            return "No Claudio symlink at \(link.path)"
        }
        if fm.isWritableFile(atPath: link.deletingLastPathComponent().path) {
            try fm.removeItem(at: link)
        } else {
            try Self.privileged("rm -f \(Self.shellQuote(link.path))")
        }
        return "Removed \(link.path)"
    }

    func isCLILinked() async -> Bool {
        let link = await root.paths.cliSymlink
        guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else { return false }
        return dest.contains("Claudio.app") || dest.hasSuffix("/claudio")
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func privileged(_ command: String) throws {
        let script = "do shell script \"\(command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        var error: NSDictionary?
        guard let apple = NSAppleScript(source: script) else { throw MessageError("could not build privileged command") }
        apple.executeAndReturnError(&error)
        if let error { throw MessageError("\(error[NSAppleScript.errorMessage] ?? "privileged command failed")") }
    }

    func voices(backend: BackendID?) async throws -> [Voice] {
        let configured = await root.settings.backendID
        let id = backend ?? configured
        return try await root.voiceCatalog.voices(for: id)
    }

    func currentVoiceName() async -> String { await root.settings.voiceID }

    func activateUI() async {
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func quit() async {
        await MainActor.run { NSApp.terminate(nil) }
    }

    func doctorChecks() async -> [DoctorCheck] {
        var checks: [DoctorCheck] = []
        do {
            let voices = try await root.edge.voices()
            checks.append(DoctorCheck(name: "Edge reachability", state: "pass", detail: "voices list returned \(voices.count) voices"))
        } catch let e as BackendError {
            checks.append(DoctorCheck(name: "Edge reachability", state: { if case .auth = e { "warn" } else { "fail" } }(), detail: e.shortDescription))
        } catch {
            checks.append(DoctorCheck(name: "Edge reachability", state: "fail", detail: String(describing: error)))
        }
        let premium = await root.apple.hasHighQualityVoice
        checks.append(DoctorCheck(name: "Apple voices", state: premium ? "pass" : "warn",
                                  detail: premium ? "Premium or Enhanced voice installed" : "only default-quality voices; see Settings → Voice"))
        let fallbackID = await root.settings.fallbackVoiceID
        if let fallbackID {
            let exists = AVSpeechSynthesisVoice(identifier: fallbackID) != nil
            checks.append(DoctorCheck(name: "Fallback voice", state: exists ? "pass" : "warn", detail: exists ? fallbackID : "configured voice missing; auto-pairing"))
        } else {
            checks.append(DoctorCheck(name: "Fallback voice", state: "pass", detail: "auto-paired"))
        }
        let wantLogin = await root.settings.launchAtLogin
        let status = SMAppService.mainApp.status
        let loginState: String = switch status {
        case .enabled: wantLogin ? "pass" : "warn"
        case .requiresApproval: "warn"
        case .notRegistered: wantLogin ? "warn" : "pass"
        default: "warn"
        }
        checks.append(DoctorCheck(name: "Login item", state: loginState, detail: "status \(status.rawValue), setting \(wantLogin)"))
        let hasOutput = Self.defaultOutputDeviceExists()
        checks.append(DoctorCheck(name: "Audio output", state: hasOutput ? "pass" : "fail", detail: hasOutput ? "default output device present" : "no output device"))
        return checks
    }

    func bench(backend: String?, fixture: String?, runs: Int) async -> String {
        let configured = await root.settings.backendID
        let id = backend ?? configured
        let target: any TTSBackend = switch id {
        case "apple": await root.apple
        case "openai": await root.openAI
        default: await root.edge
        }
        let text = fixture.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
            ?? "Claudio reads your Claude Code sessions aloud. It tails transcripts, renders markdown into speech, and plays it gaplessly. Each sentence is one segment, and the scheduler keeps two of them synthesized ahead of playback."
        let segments = SpeechTextRenderer().renderSegments(text)
        let voiceID = await root.settings.voiceID(for: id)
        let voice = await root.voiceCatalog.resolve(id: voiceID, backend: id)
        var ttfas: [Double] = []
        var totals: [Double] = []
        var failures = 0
        for _ in 0..<max(1, runs) {
            for seg in segments {
                let start = Date()
                var first: Date?
                do {
                    for try await event in target.synthesize(SynthesisRequest(text: seg.text, voice: voice, rate: 1.0)) {
                        if case .audio = event, first == nil { first = Date() }
                    }
                    if let first { ttfas.append(first.timeIntervalSince(start) * 1000) }
                    totals.append(Date().timeIntervalSince(start) * 1000)
                } catch {
                    failures += 1
                }
            }
        }
        func pct(_ v: [Double], _ p: Double) -> Int {
            guard !v.isEmpty else { return 0 }
            let s = v.sorted()
            return Int(s[min(s.count - 1, Int(Double(s.count - 1) * p))])
        }
        let metrics = await root.pipeline.metrics()
        return """
        backend=\(id) voice=\(voice.id) rate=1.0 runs=\(runs) segments=\(segments.count)
        time-to-first-audio   p50 \(pct(ttfas, 0.5)) ms   p95 \(pct(ttfas, 0.95)) ms   max \(Int(ttfas.max() ?? 0)) ms
        synth per segment     p50 \(pct(totals, 0.5)) ms   p95 \(pct(totals, 0.95)) ms
        inter-segment gap     p50 \(Int(metrics["playback.gap.p50"] ?? 0)) ms   p95 \(Int(metrics["playback.gap.p95"] ?? 0)) ms   (live pipeline history)
        failures              \(failures)
        """
    }
}

extension AppControlHost {
    static func defaultOutputDeviceExists() -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != 0
    }
}
