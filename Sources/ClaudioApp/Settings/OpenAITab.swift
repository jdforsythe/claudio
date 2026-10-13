import ClaudioBackends
import SwiftUI

struct OpenAITab: View {
    @Environment(SettingsViewModel.self) private var vm
    @State private var key = ""
    @State private var testing = false

    var body: some View {
        @Bindable var settings = vm.settings
        Form {
            Section {
                SecureField("API key", text: $key, onCommit: save)
                    .onSubmit(save)
                HelpText(vm.openAIKeyPresent ? "A key is stored in your Keychain, never in a file." : "Stored in your Keychain, never in a file.")
                HStack {
                    Button("Save") { save() }.disabled(key.isEmpty)
                    Button("Test") { testing = true; Task { await vm.testOpenAI(); testing = false } }.disabled(!vm.openAIKeyPresent || testing)
                    if let result = vm.openAITestResult { Text(result).font(.caption).foregroundStyle(result == "Works" ? .green : .orange) }
                    Spacer()
                    Button("Remove key", role: .destructive) { try? vm.removeOpenAIKey() }.disabled(!vm.openAIKeyPresent)
                }
            }
            Section {
                Picker("Model", selection: $settings.openAIModel) {
                    Text("gpt-4o-mini-tts").tag("gpt-4o-mini-tts")
                    Text("tts-1").tag("tts-1")
                    Text("tts-1-hd").tag("tts-1-hd")
                }
                Picker("Voice", selection: $settings.openAIVoice) {
                    ForEach(OpenAITTSBackend.voiceNames, id: \.self) { Text($0.capitalized).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func save() {
        guard !key.isEmpty else { return }
        do {
            try vm.setOpenAIKey(key)
            key = ""
        } catch {
            vm.lastError = String(describing: error)
        }
    }
}
