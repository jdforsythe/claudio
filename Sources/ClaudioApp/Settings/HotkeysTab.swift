import KeyboardShortcuts
import SwiftUI

struct HotkeysTab: View {
    var body: some View {
        Form {
            KeyboardShortcuts.Recorder("Pause / resume", name: .pauseResume)
            KeyboardShortcuts.Recorder("Skip sentence", name: .skipSegment)
            KeyboardShortcuts.Recorder("Skip to live", name: .skipToLive)
            KeyboardShortcuts.Recorder("Next session", name: .cycleSession)
            KeyboardShortcuts.Recorder("Cycle level of active session", name: .cycleLevel)
            KeyboardShortcuts.Recorder("Toggle mute", name: .toggleMute)
            KeyboardShortcuts.Recorder("Show / hide HUD", name: .toggleHUD)
            HelpText("Shortcuts are global. Pick combinations your terminal doesn't use.")
            Button("Reset to defaults") {
                KeyboardShortcuts.reset(.pauseResume, .skipSegment, .skipToLive, .cycleSession, .cycleLevel, .toggleMute, .toggleHUD)
            }
        }
        .formStyle(.grouped)
    }
}
