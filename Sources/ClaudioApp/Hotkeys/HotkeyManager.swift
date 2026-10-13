import ClaudioCore
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let pauseResume = Self("pauseResume", default: .init(.j, modifiers: [.control, .option]))
    static let skipSegment = Self("skipSegment", default: .init(.k, modifiers: [.control, .option]))
    static let skipToLive = Self("skipToLive", default: .init(.l, modifiers: [.control, .option]))
    static let cycleSession = Self("cycleSession", default: .init(.semicolon, modifiers: [.control, .option]))
    static let cycleLevel = Self("cycleLevel", default: .init(.quote, modifiers: [.control, .option]))
    static let toggleMute = Self("toggleMute")
    static let toggleHUD = Self("toggleHUD")
}

/// Global hotkeys (document 07 §6).
@MainActor
final class HotkeyManager {
    private let sessions: SessionsViewModel
    private let playback: PlaybackViewModel
    private let settings: AppSettings
    private let arbiter: Arbiter
    private let pipeline: SpeechPipeline

    init(sessions: SessionsViewModel, playback: PlaybackViewModel, settings: AppSettings, arbiter: Arbiter, pipeline: SpeechPipeline) {
        self.sessions = sessions
        self.playback = playback
        self.settings = settings
        self.arbiter = arbiter
        self.pipeline = pipeline
        register()
    }

    private func register() {
        KeyboardShortcuts.onKeyDown(for: .pauseResume) { [weak self] in
            guard let self else { return }
            if self.sessions.activeSessionID == nil { self.tick() } else { self.playback.togglePause() }
        }
        KeyboardShortcuts.onKeyDown(for: .skipSegment) { [weak self] in
            guard let self else { return }
            if self.sessions.activeSessionID == nil { self.tick() } else { self.playback.skipSegment() }
        }
        KeyboardShortcuts.onKeyDown(for: .skipToLive) { [weak self] in self?.playback.skipToLive() }
        KeyboardShortcuts.onKeyDown(for: .cycleSession) { [weak self] in self?.sessions.activateNext() }
        KeyboardShortcuts.onKeyDown(for: .cycleLevel) { [weak self] in
            guard let self else { return }
            if self.sessions.activeSessionID == nil { self.tick() } else { self.sessions.cycleLevelOfActive() }
        }
        KeyboardShortcuts.onKeyDown(for: .toggleMute) { [weak self] in self?.playback.toggleMute() }
        KeyboardShortcuts.onKeyDown(for: .toggleHUD) { [weak self] in self?.settings.showHUD.toggle() }
    }

    private func tick() {
        Task { await pipeline.enqueueChime(.tick) }
    }
}
