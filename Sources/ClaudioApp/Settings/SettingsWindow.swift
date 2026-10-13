import SwiftUI

struct SettingsWindow: View {
    @Environment(SettingsViewModel.self) private var settings

    var body: some View {
        @Bindable var vm = settings
        TabView {
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }
            VoiceTab().tabItem { Label("Voice", systemImage: "waveform") }
            OpenAITab().tabItem { Label("OpenAI", systemImage: "key") }
            LevelsTab().tabItem { Label("Levels", systemImage: "slider.horizontal.3") }
            HotkeysTab().tabItem { Label("Hotkeys", systemImage: "keyboard") }
            SessionsTab().tabItem { Label("Sessions", systemImage: "folder") }
            IntegrationTab().tabItem { Label("Integration", systemImage: "link") }
            AdvancedTab().tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 520)
        .frame(minHeight: 420)
        .alert("Claudio", isPresented: Binding(get: { vm.lastError != nil }, set: { if !$0 { vm.lastError = nil } })) {
            Button("OK") { vm.lastError = nil }
        } message: {
            Text(vm.lastError ?? "")
        }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }
}

struct HelpText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.caption).foregroundStyle(.secondary) }
}
