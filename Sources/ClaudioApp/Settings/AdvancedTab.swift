import ClaudioCore
import SwiftUI

struct AdvancedTab: View {
    @Environment(SettingsViewModel.self) private var vm
    @State private var confirmReset = false

    var body: some View {
        @Bindable var settings = vm.settings
        Form {
            Section {
                Picker("Log level", selection: $settings.logLevel) {
                    Text("Error").tag(LogLevel.error)
                    Text("Info").tag(LogLevel.info)
                    Text("Debug").tag(LogLevel.debug)
                }
                Button("Open logs folder") { vm.revealLogs() }
                Button("Export diagnostics…") { vm.exportDiagnostics(to: URL(fileURLWithPath: NSHomeDirectory() + "/Desktop")) }
                HelpText("Writes a support bundle zip to your Desktop.")
            }
            Section {
                Button("Reset HUD position") { settings.hudFrame = nil }
                Button("Reset all settings…", role: .destructive) { confirmReset = true }
                    .confirmationDialog("Reset Claudio?", isPresented: $confirmReset) {
                        Button("Reset", role: .destructive) { vm.resetAll() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Settings, project defaults and the session cache are removed. Hooks and the Keychain key are not touched.")
                    }
            }
        }
        .formStyle(.grouped)
    }
}
