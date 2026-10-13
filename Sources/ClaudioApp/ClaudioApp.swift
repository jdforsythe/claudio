import AppKit
import ClaudioCore
import KeyboardShortcuts
import SwiftUI

@main
struct ClaudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var root = CompositionRoot.shared

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environment(root.sessionsViewModel)
                .environment(root.playbackViewModel)
                .environment(root.settingsViewModel)
        } label: {
            MenuBarLabel()
                .environment(root.playbackViewModel)
                .environment(root.sessionsViewModel)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsWindow()
                .environment(root.settingsViewModel)
                .environment(root.sessionsViewModel)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        CompositionRoot.shared.didFinishLaunching()
    }

    func applicationWillTerminate(_ notification: Notification) {
        CompositionRoot.shared.willTerminate()
    }
}
