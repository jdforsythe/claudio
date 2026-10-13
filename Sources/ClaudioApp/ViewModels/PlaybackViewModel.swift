import ClaudioCore
import SwiftUI

@MainActor @Observable
final class PlaybackViewModel {
    enum MenuState: Equatable { case idle, speaking, paused, muted, catchingUp }

    private(set) var isAudible = false
    private(set) var isPaused = false
    private(set) var isMuted = false
    private(set) var arbiterMode: ArbiterMode = .idle
    private(set) var activeTitle: String?
    private(set) var currentSegmentText: String?
    private(set) var previousSegmentText: String?
    private(set) var currentWordRange: Range<String.Index>?
    private(set) var currentWordApproximate = false
    private(set) var queueDepth = 0
    private(set) var utteranceProgress: (done: Int, total: Int)?
    private(set) var catchUpProgress: ArbiterState.CatchUpProgress?

    private let arbiter: Arbiter
    private let pipeline: SpeechPipeline
    private let settings: AppSettings
    private var tasks: [Task<Void, Never>] = []

    init(arbiter: Arbiter, pipeline: SpeechPipeline, settings: AppSettings) {
        self.arbiter = arbiter
        self.pipeline = pipeline
        self.settings = settings
        isMuted = !settings.eventsEnabled
    }

    func start() {
        let pipelineStates = pipeline.stateStream()
        tasks.append(Task { [weak self] in
            for await state in pipelineStates {
                guard let self else { return }
                self.isAudible = state.mode == .speaking
                self.isPaused = state.mode == .paused
                self.currentSegmentText = state.currentSegment?.text
                self.previousSegmentText = state.previousSegment?.text
                self.currentWordRange = state.currentWordRange
                self.currentWordApproximate = state.currentWordApproximate
                self.queueDepth = state.queuedSegments + (state.currentSegment == nil ? 0 : 1)
                self.utteranceProgress = state.utteranceProgress
            }
        })
        let arbiterStates = arbiter.stateStream()
        tasks.append(Task { [weak self] in
            for await state in arbiterStates {
                guard let self else { return }
                self.arbiterMode = state.mode
                self.isMuted = state.eventsMuted
                self.catchUpProgress = state.catchUpProgress
            }
        })
    }

    func setActiveTitle(_ title: String?) { activeTitle = title }

    /// Muted wins over paused, paused over catching up, catching up over speaking, speaking over idle (document 07 §9).
    var menuState: MenuState {
        if isMuted { return .muted }
        if isPaused || arbiterMode == .paused { return .paused }
        if case .catchingUp = arbiterMode { return .catchingUp }
        if isAudible { return .speaking }
        return .idle
    }

    var statusText: String {
        let title = activeTitle ?? ""
        switch menuState {
        case .idle: return "Idle"
        case .speaking: return "Speaking · \(title)"
        case .paused: return "Paused · \(title)"
        case .catchingUp: return "Catching up · \(title)"
        case .muted: return "Muted"
        }
    }

    var isCatchingUp: Bool { if case .catchingUp = arbiterMode { true } else { false } }

    func togglePause() { Task { await arbiter.togglePause() } }
    func toggleMute() { Task { await arbiter.setEventsMuted(!isMuted) } }
    func skipSegment() { Task { await arbiter.skipSegment() } }
    func skipToLive() { Task { await arbiter.skipToLive() } }
}
