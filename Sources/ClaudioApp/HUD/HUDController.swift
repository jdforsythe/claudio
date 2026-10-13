import AppKit
import ClaudioCore
import SwiftUI

/// Show/hide/position policy (document 07 §4.5–§4.7).
@MainActor
final class HUDController {
    static let hideDelay: TimeInterval = 4
    static let defaultSize = NSSize(width: HUDView.width, height: 84)

    private let panel: HUDPanel
    private let viewModel: HUDViewModel
    private let playback: PlaybackViewModel
    private let settings: AppSettings
    private var hideTask: Task<Void, Never>?
    private var observation: Task<Void, Never>?
    private var hovered = false
    private var screenObserver: (any NSObjectProtocol)?

    init(viewModel: HUDViewModel, playback: PlaybackViewModel, sessions: SessionsViewModel, settingsViewModel: SettingsViewModel,
         settings: AppSettings) {
        self.viewModel = viewModel
        self.playback = playback
        self.settings = settings
        panel = HUDPanel(viewModel: viewModel, playback: playback, sessions: sessions, settings: settingsViewModel)
        panel.onReturn = { [weak viewModel] in viewModel?.acceptNewestPrompt() }
        restoreFrame()
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.didMove() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.didResize() }
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.clampToScreen() }
        }
        observe()
    }

    private func observe() {
        observation = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.evaluate()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private var lastAudible = false
    private var lastPrompts = false

    func evaluate() {
        let audible = playback.isAudible || playback.queueDepth > 0 || playback.isPaused
        let prompts = viewModel.hasPrompts
        let notice = viewModel.notice != nil
        guard settings.showHUD else {
            if panel.isVisible { panel.orderOut(nil) }
            return
        }
        if audible || prompts || notice || settings.hudPinned {
            hideTask?.cancel()
            hideTask = nil
            if !panel.isVisible { show() }
        } else if panel.isVisible, hideTask == nil, !hovered {
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.hideDelay))
                guard !Task.isCancelled, let self, !self.hovered, !self.settings.hudPinned else { return }
                self.panel.orderOut(nil)
            }
        }
        lastAudible = audible
        lastPrompts = prompts
    }

    func setHovered(_ h: Bool) {
        hovered = h
        if h { hideTask?.cancel(); hideTask = nil } else { evaluate() }
    }

    func show() {
        clampToScreen()
        anchorTopLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        panel.orderFrontRegardless()
    }

    func toggle() {
        settings.showHUD.toggle()
        evaluate()
    }

    /// Content-driven resizes keep the top-left corner fixed (document 07 §4.2); drags update the anchor.
    private var anchorTopLeft: NSPoint?
    private var adjusting = false

    private func didMove() {
        guard !adjusting else { return }
        anchorTopLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        saveFrame()
    }

    private func didResize() {
        guard !adjusting, let anchor = anchorTopLeft else {
            anchorTopLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
            return
        }
        var frame = panel.frame
        if abs(frame.maxY - anchor.y) > 0.5 || abs(frame.minX - anchor.x) > 0.5 {
            frame.origin = NSPoint(x: anchor.x, y: anchor.y - frame.height)
            adjusting = true
            panel.setFrame(frame, display: true, animate: false)
            adjusting = false
        }
        saveFrame()
    }

    func panelDidResize(height: CGFloat) {
        // Sizing is driven by NSHostingView.sizingOptions; nothing to do here.
    }

    // MARK: Position (document 07 §4.6)

    private func restoreFrame() {
        if let saved = settings.hudFrame {
            panel.setFrame(saved, display: false)
        } else {
            panel.setFrame(Self.defaultFrame(), display: false)
        }
        clampToScreen()
    }

    static func defaultFrame(screen: NSScreen? = NSScreen.main) -> NSRect {
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(x: visible.maxX - defaultSize.width - 12, y: visible.maxY - defaultSize.height - 12,
                      width: defaultSize.width, height: defaultSize.height)
    }

    static func clamp(_ frame: NSRect, screens: [NSScreen]) -> NSRect {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        guard let screen = screens.first(where: { $0.frame.contains(center) }) else { return defaultFrame() }
        var f = frame
        let v = screen.visibleFrame
        f.origin.x = min(max(f.origin.x, v.minX), v.maxX - f.width)
        f.origin.y = min(max(f.origin.y, v.minY), v.maxY - f.height)
        return f
    }

    private func clampToScreen() {
        let clamped = Self.clamp(panel.frame, screens: NSScreen.screens)
        if clamped != panel.frame { panel.setFrame(clamped, display: true) }
    }

    private func saveFrame() {
        settings.hudFrame = panel.frame
    }
}
