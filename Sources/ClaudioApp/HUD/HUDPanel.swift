import AppKit
import SwiftUI

/// Floating non-activating panel (document 07 §4.1).
final class HUDPanel: NSPanel {
    init(viewModel: HUDViewModel, playback: PlaybackViewModel, sessions: SessionsViewModel, settings: SettingsViewModel) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        let root = HUDView()
            .environment(viewModel)
            .environment(playback)
            .environment(sessions)
            .environment(settings)
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = [.preferredContentSize]
        contentView = hosting
        setAccessibilityRole(.group)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 { onReturn?() } else { super.keyDown(with: event) }
    }

    var onReturn: (() -> Void)?
}
