import AppKit
import SwiftUI

/// Popover-shaped hint shown once (document 07 §1.4).
@MainActor
enum FirstLaunchHint {
    private static var panel: NSPanel?

    static func show(openSettings: @escaping () -> Void) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 150), styleMask: [.titled, .nonactivatingPanel, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "Claudio"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        let view = VStack(alignment: .leading, spacing: 8) {
            Text("Claudio is in your menu bar.").font(.headline)
            Text("Start a Claude Code session in any terminal and it appears here. Click a session to hear it.")
            Text("For instant stop when you type a new prompt, turn on **Hooks** in Settings → Integration.")
            HStack {
                Spacer()
                Button("Open Settings") { dismiss(); openSettings() }
                Button("Got it") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .font(.callout)
        .padding(16)
        .frame(width: 340)
        panel.contentView = NSHostingView(rootView: view)
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX - 352, y: frame.maxY - 12))
        }
        panel.orderFrontRegardless()
        Self.panel = panel
        Task {
            try? await Task.sleep(for: .seconds(30))
            dismiss()
        }
    }

    static func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }
}
