import ClaudioCore
import SwiftUI

@MainActor @Observable
final class HUDViewModel {
    struct Prompt: Identifiable, Equatable {
        let id: UUID
        let sessionID: SessionID
        let title: String
        let verb: String
        let shownAt: Date
    }

    struct SegmentProgress: Equatable { let done: Int; let total: Int }

    private(set) var prompts: [Prompt] = []
    private(set) var segmentProgress: SegmentProgress?
    private(set) var catchUpProgress: (index: Int, total: Int)?
    private(set) var activeTitle: String?
    private(set) var activeColorIndex: Int?
    private(set) var activeSessionID: SessionID?
    private(set) var notice: String?
    private(set) var droppedNoticeUntil: Date?

    static let promptLifetime: TimeInterval = 20
    static let maxPrompts = 3

    private let arbiter: Arbiter
    private let pipeline: SpeechPipeline
    private let registry: SessionRegistry
    private let settings: AppSettings
    private var tasks: [Task<Void, Never>] = []
    private var dismissTasks: [UUID: Task<Void, Never>] = [:]

    init(arbiter: Arbiter, pipeline: SpeechPipeline, registry: SessionRegistry, settings: AppSettings) {
        self.arbiter = arbiter
        self.pipeline = pipeline
        self.registry = registry
        self.settings = settings
    }

    var captionsExpanded: Bool {
        get { settings.hudCaptionsExpanded }
        set { settings.hudCaptionsExpanded = newValue }
    }

    var pinned: Bool {
        get { settings.hudPinned }
        set { settings.hudPinned = newValue }
    }

    func start() {
        let states = pipeline.stateStream()
        tasks.append(Task { [weak self] in
            for await state in states {
                guard let self else { return }
                self.segmentProgress = state.utteranceProgress.map { SegmentProgress(done: $0.done, total: $0.total) }
                if let dropped = state.lastDroppedAt, self.droppedNoticeUntil == nil || dropped > self.droppedNoticeUntil! {  // swiftlint:disable:this force_unwrapping
                    self.showNotice("Couldn't speak a sentence")
                    self.droppedNoticeUntil = dropped
                }
            }
        })
        let arbiterStates = arbiter.stateStream()
        tasks.append(Task { [weak self] in
            for await state in arbiterStates {
                guard let self else { return }
                self.catchUpProgress = state.catchUpProgress.map { ($0.index, $0.total) }
                self.activeSessionID = state.activeSessionID
                if let id = state.activeSessionID, let s = await self.registry.session(id) {
                    self.activeTitle = s.title
                    self.activeColorIndex = s.colorIndex
                } else {
                    self.activeTitle = nil
                    self.activeColorIndex = nil
                }
                self.prompts.removeAll { $0.sessionID == state.activeSessionID }
            }
        })
        let events = arbiter.events()
        tasks.append(Task { [weak self] in
            for await event in events {
                guard let self else { return }
                switch event {
                case .prompt(let sessionID, let title, let verb):
                    self.addPrompt(sessionID: sessionID, title: title, verb: verb)
                case .notice(let text):
                    self.showNotice(text)
                case .activated:
                    break
                }
            }
        })
        let registryChanges = registry.changes()
        tasks.append(Task { [weak self] in
            for await snapshot in registryChanges {
                guard let self, let id = self.activeSessionID, let s = snapshot.sessions.first(where: { $0.id == id }) else { continue }
                self.activeTitle = s.title
                self.activeColorIndex = s.colorIndex
            }
        })
    }

    func addPrompt(sessionID: SessionID, title: String, verb: String) {
        guard sessionID != activeSessionID else { return }
        prompts.removeAll { $0.sessionID == sessionID }
        let prompt = Prompt(id: UUID(), sessionID: sessionID, title: title, verb: verb, shownAt: Date())
        prompts.append(prompt)
        if prompts.count > Self.maxPrompts { dismissPrompt(prompts[0].id) }
        dismissTasks[prompt.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.promptLifetime))
            guard !Task.isCancelled else { return }
            self?.dismissPrompt(prompt.id)
        }
    }

    func acceptPrompt(_ id: UUID) {
        guard let prompt = prompts.first(where: { $0.id == id }) else { return }
        Task { await arbiter.activate(prompt.sessionID) }
        dismissPrompt(id)
    }

    func acceptNewestPrompt() {
        if let last = prompts.last { acceptPrompt(last.id) }
    }

    func dismissPrompt(_ id: UUID) {
        prompts.removeAll { $0.id == id }
        dismissTasks[id]?.cancel()
        dismissTasks.removeValue(forKey: id)
    }

    func showNotice(_ text: String) {
        notice = text
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            if self?.notice == text { self?.notice = nil }
        }
    }

    var hasPrompts: Bool { !prompts.isEmpty }
}
