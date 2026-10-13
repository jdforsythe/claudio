import ServiceManagement
import SwiftUI

struct GeneralTab: View {
    @Environment(SettingsViewModel.self) private var vm

    var body: some View {
        @Bindable var settings = vm.settings
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(get: { settings.launchAtLogin }, set: { vm.setLaunchAtLogin($0) }))
                    .disabled(!vm.isBundled)
                HelpText(vm.isBundled ? "Starts Claudio when you log in." : "Install the app to enable.")
                if vm.loginItemStatus == .requiresApproval {
                    HStack {
                        Text("Approval required in System Settings → General → Login Items.").font(.caption)
                        Button("Open") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") { NSWorkspace.shared.open(url) }
                        }
                    }
                }
            }
            Section {
                Toggle("Show floating HUD", isOn: $settings.showHUD)
                HelpText("A small panel shows what's being spoken and which session is active.")
                Toggle("Open captions by default", isOn: $settings.hudCaptionsExpanded)
                HelpText("Show the spoken text in the HUD. You can always toggle it with the chevron.")
            }
            Section {
                Toggle("Announce events", isOn: $settings.eventsEnabled)
                HelpText("Say when a background session finishes or needs you.")
                Toggle("Play chimes", isOn: $settings.chimesEnabled).disabled(!settings.eventsEnabled)
                HelpText("A short sound before announcements.")
                Slider(value: $settings.chimeVolume, in: 0...1) { Text("Chime volume") }
            }
        }
        .formStyle(.grouped)
    }
}
