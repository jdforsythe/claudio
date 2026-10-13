import AppKit
import ClaudioBackends
import ClaudioCore
import KeyboardShortcuts
import ServiceManagement
import SwiftUI

enum HooksStatus: Equatable {
    case disabled
    case installed(Int)
    case needsRepair
    case error(String)
}

@MainActor @Observable
final class SettingsViewModel {
    let settings: AppSettings
    private(set) var voices: [Voice] = []
    private(set) var appleVoices: [Voice] = []
    private(set) var hasPremiumAppleVoice = true
    private(set) var hooksStatus: HooksStatus = .disabled
    private(set) var hooksDetail: String = ""
    private(set) var cliLinked = false
    private(set) var skillInstalled = false
    private(set) var openAIKeyPresent = false
    private(set) var loginItemStatus: SMAppService.Status = .notRegistered
    private(set) var projectEntries: [(URL, ProjectPreferences.Entry)] = []
    private(set) var voicesLoading = false
    private(set) var voicesError: String?
    private(set) var openAITestResult: String?
    var offerRepair = false
    var lastError: String?

    private let catalog: VoiceCatalog
    private let apple: AppleSpeechBackend
    private let hookInstaller: HookInstaller
    private let skillInstaller: SkillInstaller
    private let keychain: KeychainStore
    private let projectPrefs: ProjectPreferences
    private let paths: Paths
    private let arbiter: Arbiter
    private let pipeline: SpeechPipeline
    private let registry: SessionRegistry

    init(settings: AppSettings, catalog: VoiceCatalog, apple: AppleSpeechBackend, hookInstaller: HookInstaller,
         skillInstaller: SkillInstaller, keychain: KeychainStore, projectPrefs: ProjectPreferences, paths: Paths,
         arbiter: Arbiter, pipeline: SpeechPipeline, registry: SessionRegistry) {
        self.settings = settings
        self.catalog = catalog
        self.apple = apple
        self.hookInstaller = hookInstaller
        self.skillInstaller = skillInstaller
        self.keychain = keychain
        self.projectPrefs = projectPrefs
        self.paths = paths
        self.arbiter = arbiter
        self.pipeline = pipeline
        self.registry = registry
    }

    var isBundled: Bool { paths.isBundled }

    func start() {
        refreshHooksStatus()
        skillInstalled = skillInstaller.isInstalled()
        openAIKeyPresent = keychain.exists(.openAI)
        loginItemStatus = SMAppService.mainApp.status
        settings.launchAtLogin = loginItemStatus == .enabled
        if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: paths.cliSymlink.path) {
            cliLinked = dest.contains("Claudio.app") || dest.hasSuffix("/claudio")
        }
        Task { await refreshVoices() }
        Task { await refreshProjects() }
    }

    func refreshHooksStatus() {
        let status = hookInstaller.status()
        hooksDetail = status.humanDescription
        switch status {
        case .notInstalled: hooksStatus = .disabled
        case .installed(let count, _): hooksStatus = .installed(count)
        case .installedElsewhere, .partial: hooksStatus = .needsRepair
        case .settingsUnreadable(let reason): hooksStatus = .error(reason)
        }
    }

    // MARK: Voices

    func refreshVoices(force: Bool = false) async {
        voicesLoading = true
        defer { voicesLoading = false }
        hasPremiumAppleVoice = apple.hasHighQualityVoice
        appleVoices = (try? await catalog.voices(for: "apple", forceRefresh: force)) ?? []
        do {
            voices = try await catalog.voices(for: settings.backendID, forceRefresh: force)
            voicesError = nil
        } catch {
            voices = []
            voicesError = String(describing: error)
        }
    }

    func previewVoice(_ voice: Voice) {
        Task {
            let item = SpeechItem(sessionID: "preview", turnID: nil, category: .event,
                                  text: Cues.mark(Cues.voicePreview(voice.displayName)), timestamp: Date())
            await pipeline.enqueue(item)
        }
    }

    func previewRate() {
        Task { await arbiter.speakCue(Cues.ratePreview) }
    }

    // MARK: OpenAI

    func setOpenAIKey(_ key: String) throws {
        try keychain.set(key, for: .openAI)
        openAIKeyPresent = true
    }

    func removeOpenAIKey() throws {
        try keychain.delete(.openAI)
        openAIKeyPresent = false
    }

    func testOpenAI() async {
        let backend = OpenAITTSBackend(model: { [settings] in settings.openAIModel })
        let voice = Voice(backend: "openai", id: settings.openAIVoice, displayName: settings.openAIVoice, locale: "en-US")
        do {
            var frames = 0
            for try await event in backend.synthesize(SynthesisRequest(text: "Works.", voice: voice, rate: 1.0)) {
                if case .audio(let b) = event { frames += b.frameCount }
            }
            openAITestResult = frames > 0 ? "Works" : "No audio returned"
        } catch {
            openAITestResult = (error as? BackendError)?.shortDescription ?? String(describing: error)
        }
    }

    // MARK: Hooks / CLI / skill

    func installHooks() {
        do {
            try hookInstaller.install()
            settings.hooksEnabled = true
            lastError = nil
        } catch {
            settings.hooksEnabled = false
            lastError = Self.describe(error)
        }
        refreshHooksStatus()
    }

    func uninstallHooks() {
        do {
            try hookInstaller.uninstall()
            lastError = nil
        } catch {
            lastError = Self.describe(error)
        }
        settings.hooksEnabled = false
        refreshHooksStatus()
    }

    func repairHooks() {
        do {
            try hookInstaller.repair()
            settings.hooksEnabled = true
            offerRepair = false
        } catch {
            lastError = Self.describe(error)
        }
        refreshHooksStatus()
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case HookInstallerError.unbundled: "Install the app to enable hooks"
        case HookInstallerError.settingsMalformed(let r): "settings.json could not be parsed. Nothing was changed. (\(r))"
        case HookInstallerError.verifyFailed: "Verification failed; the previous settings.json was restored"
        case HookInstallerError.writeFailed(let r): "Could not write settings.json: \(r)"
        case SkillInstaller.SkillError.foreignSkillPresent: "A different /speak skill is already installed; remove it first"
        default: String(describing: error)
        }
    }

    func linkCLI() async {
        let host = await AppControlHost(root: CompositionRoot.shared)
        do {
            _ = try await host.linkCLI(true)
            cliLinked = true
        } catch {
            lastError = Self.describe(error)
        }
    }

    func unlinkCLI() async {
        let host = await AppControlHost(root: CompositionRoot.shared)
        do {
            _ = try await host.linkCLI(false)
            cliLinked = false
        } catch {
            lastError = Self.describe(error)
        }
    }

    func installSkill() {
        do {
            try skillInstaller.install()
            skillInstalled = true
        } catch {
            lastError = Self.describe(error)
        }
    }

    func uninstallSkill() {
        do {
            try skillInstaller.uninstall()
            skillInstalled = false
        } catch {
            lastError = Self.describe(error)
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            lastError = String(describing: error)
        }
        loginItemStatus = SMAppService.mainApp.status
        settings.launchAtLogin = loginItemStatus == .enabled
    }

    // MARK: Roots and projects

    func addRoot(_ url: URL) {
        var roots = settings.extraTranscriptRoots
        if !roots.contains(url) { roots.append(url) }
        settings.extraTranscriptRoots = roots
    }

    func removeRoot(_ url: URL) {
        settings.extraTranscriptRoots.removeAll { $0 == url }
    }

    func refreshProjects() async {
        projectEntries = await projectPrefs.entries().sorted { $0.key.path < $1.key.path }.map { ($0.key, $0.value) }
    }

    func setProjectDefault(_ level: SpeechLevel, for cwd: URL) {
        Task {
            var entry = await projectPrefs.entry(matching: cwd).flatMap { ProjectPreferences.canonical($0.0) == ProjectPreferences.canonical(cwd) ? $0.1 : nil }
                ?? ProjectPreferences.Entry(defaultLevel: level)
            entry.defaultLevel = level
            do { try await projectPrefs.set(entry, for: cwd) } catch { lastError = String(describing: error) }
            await refreshProjects()
        }
    }

    func removeProjectDefault(for cwd: URL) {
        Task {
            do { try await projectPrefs.remove(for: cwd) } catch { lastError = String(describing: error) }
            await refreshProjects()
        }
    }

    var knownProjectPaths: [URL] {
        get async { Array(Set(await registry.sessions.map(\.cwd))).sorted { $0.path < $1.path } }
    }

    // MARK: Reset

    func resetAll() {
        settings.resetAll()
        let fm = FileManager.default
        try? fm.removeItem(at: paths.projectsFile)
        try? fm.removeItem(at: paths.sessionsFile)
        for name in (try? fm.contentsOfDirectory(atPath: paths.applicationSupport.path)) ?? [] where name.hasPrefix("voices-") {
            try? fm.removeItem(at: paths.applicationSupport.appendingPathComponent(name))
        }
        KeyboardShortcuts.reset(.pauseResume, .skipSegment, .skipToLive, .cycleSession, .cycleLevel, .toggleMute, .toggleHUD)
        Task { await refreshProjects() }
    }

    func exportDiagnostics(to url: URL) {
        let process = Process()
        process.executableURL = paths.cliExecutable
        process.arguments = ["doctor", "--bundle"]
        try? process.run()
        process.waitUntilExit()
    }

    func revealLogs() { NSWorkspace.shared.activateFileViewerSelecting([paths.logFile]) }
    func revealClaudeSettings() { NSWorkspace.shared.activateFileViewerSelecting([paths.claudeSettingsFile]) }
}
