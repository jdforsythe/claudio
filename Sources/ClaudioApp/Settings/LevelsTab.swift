import ClaudioCore
import SwiftUI

struct LevelsTab: View {
    @Environment(SettingsViewModel.self) private var vm

    var body: some View {
        @Bindable var settings = vm.settings
        Form {
            Section {
                Picker("New sessions start at", selection: $settings.defaultLevelNewSession) {
                    ForEach(SpeechLevel.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }.pickerStyle(.segmented)
                HelpText("Applies to sessions that are not active.")
                Picker("Active session starts at", selection: $settings.defaultLevelActive) {
                    ForEach(SpeechLevel.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }.pickerStyle(.segmented)
                HelpText("Applied when you activate a session that has no project default.")
            }
            Section("Advanced") {
                Toggle("Speak thinking", isOn: $settings.speakThinking)
                HelpText("Reads Claude's reasoning when the level is Narrate. Verbose.")
                Toggle("Speak tool errors", isOn: $settings.speakToolErrors)
                HelpText("Reads failed tool results when the level is Narrate.")
            }
        }
        .formStyle(.grouped)
    }
}
