import AppKit
import ClaudioBackends
import ClaudioCore
import Foundation
import KeyboardShortcuts
import ServiceManagement
import SwiftUI
import Synchronization

/// Builds the whole object graph once (document 07 §1.2).
@MainActor
final class CompositionRoot {
    static let shared = CompositionRoot()

    let paths: Paths
    let settings: AppSettings
    let keychain = KeychainStore()
    let projectPrefs: ProjectPreferences
    let sessionStore: SessionStateCache
    let edge: EdgeTTSBackend
    let apple: AppleSpeechBackend
    let openAI: OpenAITTSBackend
    let voiceCatalog: VoiceCatalog
    let playbackEngine: PlaybackEngine
    let pipeline: SpeechPipeline
    let discovery: SessionDiscovery
    let probe: LiveAgentsProbe
    let registry: SessionRegistry
    let arbiter: Arbiter
    let hookInstaller: HookInstaller
    let skillInstaller: SkillInstaller
    private(set) var controlServer: ControlServer?
    let sessionsViewModel: SessionsViewModel
    let playbackViewModel: PlaybackViewModel
    let hudViewModel: HUDViewModel
    let settingsViewModel: SettingsViewModel
    private(set) var hudController: HUDController?
    let updater: Updater
    private(set) var hotkeys: HotkeyManager?
    private let voiceCache = VoiceCache()
    private var currentFallback: FallbackBackend
    private var tasks: [Task<Void, Never>] = []
    private let clock = SystemClock()

    private init() {
        paths = Paths()
        try? paths.ensureDirectories()
        if Bundle.main.bundleIdentifier == nil {
            // Unbundled debug binary: KeyboardShortcuts stores under UserDefaults.standard; share our suite with it.
            UserDefaults.standard.addSuite(named: AppSettings.suiteName)
        }
        SingleInstance.ensure(socketPath: paths.controlSocket.path)
        settings = AppSettings()
        Log.fileSink.configure(url: paths.logFile, threshold: settings.logLevel)
        projectPrefs = ProjectPreferences(fileURL: paths.projectsFile)
        sessionStore = SessionStateCache(fileURL: paths.sessionsFile, clock: clock)

        edge = EdgeTTSBackend(clock: clock)
        apple = AppleSpeechBackend()
        let settingsRef = settings
        openAI = OpenAITTSBackend(model: { settingsRef.openAIModel })
        let catalog = VoiceCatalog(backends: [edge, apple, openAI], cacheDirectory: paths.applicationSupport, clock: clock,
                                   overrides: { settingsRef.fallbackVoiceOverrides },
                                   preferredFallbackID: { settingsRef.fallbackVoiceID })
        voiceCatalog = catalog
        let primary: any TTSBackend = Self.backend(for: settings.backendID, edge: edge, apple: apple, openAI: openAI)
        let fallback = FallbackBackend(primary: primary, fallback: apple, firstAudioTimeout: settings.fallbackTimeoutSeconds,
                                       clock: clock, fallbackVoice: { await catalog.fallbackVoice(for: $0) })
        currentFallback = fallback
        playbackEngine = PlaybackEngine(clock: clock)
        let cache = voiceCache
        pipeline = SpeechPipeline(backend: fallback, sink: playbackEngine, clock: clock, rate: settings.rate,
                                  lookahead: settings.lookahead, voiceProvider: { id in
            cache.get(id) ?? Voice(backend: id, id: settingsRef.voiceID(for: id), displayName: settingsRef.voiceID(for: id), locale: "en-US")
        })
        discovery = SessionDiscovery(roots: paths.allTranscriptRootCandidates(extra: settings.extraTranscriptRoots), clock: clock,
                                     livenessWindow: TimeInterval(settings.sessionExpiryHours) * 3600)
        probe = LiveAgentsProbe(clock: clock, interval: settings.liveAgentsProbeInterval)
        registry = SessionRegistry(discovery: discovery, probe: probe, store: sessionStore, settings: settings,
                                   projectPrefs: projectPrefs, paths: paths, clock: clock)
        arbiter = Arbiter(registry: registry, pipeline: pipeline, settings: settings, clock: clock)
        hookInstaller = HookInstaller(settingsURL: paths.claudeSettingsFile, backupsDirectory: paths.backupsDirectory,
                                      bundleURL: paths.isBundled ? Bundle.main.bundleURL : nil, clock: clock)
        skillInstaller = SkillInstaller(skillDirectory: paths.speakSkillDir, cliPath: paths.cliExecutable?.path)
        sessionsViewModel = SessionsViewModel(registry: registry, arbiter: arbiter)
        playbackViewModel = PlaybackViewModel(arbiter: arbiter, pipeline: pipeline, settings: settings)
        hudViewModel = HUDViewModel(arbiter: arbiter, pipeline: pipeline, registry: registry, settings: settings)
        updater = Updater(settings: settings, bundleURL: Bundle.main.bundleURL, isBundled: paths.isBundled)
        settingsViewModel = SettingsViewModel(settings: settings, catalog: voiceCatalog, apple: apple, hookInstaller: hookInstaller,
                                              skillInstaller: skillInstaller, keychain: keychain, projectPrefs: projectPrefs,
                                              paths: paths, arbiter: arbiter, pipeline: pipeline, registry: registry)
    }

    static func backend(for id: BackendID, edge: EdgeTTSBackend, apple: AppleSpeechBackend, openAI: OpenAITTSBackend) -> any TTSBackend {
        switch id {
        case "apple": apple
        case "openai": openAI.isConfigured ? openAI : apple
        default: edge
        }
    }

    func didFinishLaunching() {
        let host = AppControlHost(root: self)
        let dispatcher = ControlDispatcher(registry: registry, arbiter: arbiter, pipeline: pipeline, settings: settings,
                                           hookInstaller: hookInstaller, skillInstaller: skillInstaller, host: host, paths: paths,
                                           clock: clock)
        let server = ControlServer(path: paths.controlSocket.path) { envelope, writer in
            await dispatcher.handle(envelope, writer: writer)
        }
        do {
            try server.start()
            controlServer = server
        } catch ControlServer.ServerError.anotherInstanceRunning {
            let alert = NSAlert()
            alert.messageText = "Claudio is already running"
            alert.runModal()
            exit(0)
        } catch {
            Log.control.error("control server failed: \(error)")
        }
        signal(SIGTERM) { _ in
            Task { @MainActor in CompositionRoot.shared.willTerminate() }
            exit(0)
        }
        for (chime, buffer) in ChimeResources.load() {
            Task { await pipeline.registerChime(chime, buffer: buffer) }
        }
        Task {
            await pipeline.setChimeVolume(settings.chimeVolume)
            await pipeline.setChimesEnabled(settings.chimesEnabled)
            await pipeline.start()
            await registry.start()
            await arbiter.start()
            await refreshVoiceCache()
            sessionsViewModel.start()
            playbackViewModel.start()
            hudViewModel.start()
            settingsViewModel.start()
            hudController = HUDController(viewModel: hudViewModel, playback: playbackViewModel, sessions: sessionsViewModel,
                                          settingsViewModel: settingsViewModel, settings: settings)
            updater.start()
            hotkeys = HotkeyManager(sessions: sessionsViewModel, playback: playbackViewModel, settings: settings, arbiter: arbiter, pipeline: pipeline)
            observeSettings()
            observeNotices()
            reconcileHooks(atLaunch: true)
            await edge.warmUp()
            if !settings.firstLaunchCompleted {
                settings.firstLaunchCompleted = true
                try? await Task.sleep(for: .seconds(1.5))
                FirstLaunchHint.show(openSettings: { [weak self] in self?.openSettings() })
            }
        }
        Log.ui.info("launched \(BuildInfo.versionString) bundled=\(paths.isBundled)")
        if ProcessInfo.processInfo.environment["CLAUDIO_SELFTEST"] == "1" { runSelfTest() }
    }

    /// Exercises the code paths that depend on bundled resources (chimes, the hotkey recorder's localized
    /// strings) and exits 0, so a packaged build can be checked on a machine that did not build it.
    private func runSelfTest() {
        let chimes = ChimeResources.load()
        let recorder = NSHostingView(rootView: KeyboardShortcuts.Recorder("Pause / resume", name: .pauseResume))
        recorder.frame = NSRect(x: 0, y: 0, width: 300, height: 40)
        recorder.layoutSubtreeIfNeeded()
        let placeholder = "record_shortcut".localizedSelfTest
        FileHandle.standardError.write(Data("selftest ok: chimes=\(chimes.count) resourceBundle=\(ChimeResources.resourceBundle != nil) recorderPlaceholder=\(placeholder)\n".utf8))
        exit(0)
    }

    func willTerminate() {
        controlServer?.stop()
        let registry = registry
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await registry.saveNow()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 0.5)
    }

    func openSettings() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if #available(macOS 14, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }

    // MARK: Settings observation (document 08 §2.4)

    private var lastSnapshot: AppSettingsSnapshot?

    private func observeSettings() {
        lastSnapshot = settings.snapshot
        let stream = settings.changes()
        tasks.append(Task { [weak self] in
            for await snap in stream {
                guard let self else { return }
                await self.apply(snap)
            }
        })
    }

    private func apply(_ snap: AppSettingsSnapshot) async {
        let old = lastSnapshot
        lastSnapshot = snap
        Log.fileSink.setThreshold(snap.logLevel)
        if old?.rate != snap.rate { await pipeline.setRate(snap.rate) }
        if old?.lookahead != snap.lookahead { await pipeline.setLookahead(snap.lookahead) }
        if old?.chimeVolume != snap.chimeVolume { await pipeline.setChimeVolume(snap.chimeVolume) }
        if old?.chimesEnabled != snap.chimesEnabled { await pipeline.setChimesEnabled(snap.chimesEnabled) }
        if old?.backendID != snap.backendID || old?.fallbackTimeoutSeconds != snap.fallbackTimeoutSeconds {
            let primary = Self.backend(for: snap.backendID, edge: edge, apple: apple, openAI: openAI)
            let catalog = voiceCatalog
            let fb = FallbackBackend(primary: primary, fallback: apple, firstAudioTimeout: snap.fallbackTimeoutSeconds, clock: clock,
                                     fallbackVoice: { await catalog.fallbackVoice(for: $0) })
            currentFallback = fb
            await pipeline.setBackend(fb)
            observeNotices()
            if snap.backendID == "edge" { await edge.warmUp() }
        }
        if old?.voiceID != snap.voiceID || old?.backendID != snap.backendID || old?.openAIVoice != snap.openAIVoice {
            await refreshVoiceCache()
        }
        if old?.hooksEnabled != snap.hooksEnabled { reconcileHooks(atLaunch: false) }
    }

    func refreshVoiceCache() async {
        var cache: [BackendID: Voice] = [:]
        cache["edge"] = await voiceCatalog.resolve(id: settings.voiceID(for: "edge"), backend: "edge")
        cache["openai"] = await voiceCatalog.resolve(id: settings.openAIVoice, backend: "openai")
        let appleID = settings.backendID == "apple" ? settings.voiceID : (settings.fallbackVoiceID ?? "")
        cache["apple"] = await voiceCatalog.resolve(id: appleID, backend: "apple")
        voiceCache.set(cache)
    }

    private var noticeTask: Task<Void, Never>?

    private func observeNotices() {
        noticeTask?.cancel()
        let notices = currentFallback.noticeStream()
        noticeTask = Task { [weak self] in
            for await notice in notices {
                self?.hudViewModel.showNotice(notice.text)
            }
        }
    }

    func reconcileHooks(atLaunch: Bool) {
        guard settings.hooksEnabled else { return }
        let status = hookInstaller.status()
        switch status {
        case .installed:
            break
        case .notInstalled, .partial:
            do {
                try hookInstaller.install()
                Log.hooks.notice("hooks: repaired after external change")
            } catch {
                Log.hooks.error("hook reinstall failed: \(error)")
            }
        case .installedElsewhere:
            if atLaunch { settingsViewModel.offerRepair = true }
        case .settingsUnreadable:
            break
        }
        settingsViewModel.refreshHooksStatus()
    }

    var fallbackBackend: FallbackBackend { currentFallback }
}

/// Reference-typed voice lookup shared with the scheduler's synchronous voice provider.
final class VoiceCache: Sendable {
    private let storage = Mutex<[BackendID: Voice]>([:])
    func get(_ id: BackendID) -> Voice? { storage.withLock { $0[id] } }
    func set(_ all: [BackendID: Voice]) { storage.withLock { $0 = all } }
}
