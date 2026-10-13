import ClaudioCore
import SwiftUI

struct VoiceTab: View {
    @Environment(SettingsViewModel.self) private var vm
    @State private var search = ""

    var body: some View {
        @Bindable var settings = vm.settings
        Form {
            Section {
                Picker("Engine", selection: $settings.backendID) {
                    Text("Edge (Microsoft, online)").tag("edge")
                    Text("Apple (offline)").tag("apple")
                    Text("OpenAI (API key)").tag("openai")
                }
                .onChange(of: settings.backendID) { _, _ in Task { await vm.refreshVoices() } }
                HelpText("Edge gives natural voices for free. Apple works offline and is the fallback. OpenAI needs a key.")
                if settings.backendID == "openai", !vm.openAIKeyPresent {
                    Label("No API key. Add one in the OpenAI tab. Using Apple until then.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
                }
            }
            Section("Voice") {
                TextField("Search voices", text: $search)
                if vm.voicesLoading { ProgressView().controlSize(.small) }
                if let err = vm.voicesError { Text("Voice list unavailable: \(err)").font(.caption).foregroundStyle(.orange) }
                List {
                    ForEach(groupedVoices, id: \.0) { locale, voices in
                        Section(locale) {
                            ForEach(voices, id: \.id) { voice in
                                HStack {
                                    Image(systemName: settings.voiceID == voice.id ? "checkmark" : "")
                                        .frame(width: 14)
                                    Text(voice.displayName)
                                    Spacer()
                                    Button { vm.previewVoice(voice) } label: { Image(systemName: "play.circle") }
                                        .buttonStyle(.borderless).accessibilityLabel("Preview \(voice.displayName)")
                                }
                                .contentShape(Rectangle())
                                .onTapGesture { settings.voiceID = voice.id }
                            }
                        }
                    }
                }
                .frame(minHeight: 180)
            }
            Section {
                HStack {
                    Slider(value: $settings.rate, in: 0.5...2.0, step: 0.05, onEditingChanged: { editing in if !editing { vm.previewRate() } }) { Text("Speed") }
                    Text(String(format: "%.2f×", settings.rate)).monospacedDigit().frame(width: 52)
                }
                HelpText("Applies to the next sentence.")
            }
            Section {
                Picker("Fallback voice (Apple)", selection: Binding(get: { settings.fallbackVoiceID ?? "" }, set: { settings.fallbackVoiceID = $0.isEmpty ? nil : $0 })) {
                    Text("Automatic").tag("")
                    ForEach(vm.appleVoices, id: \.id) { v in Text("\(v.displayName) (\(v.locale))").tag(v.id) }
                }
                HelpText("Used when the engine is unavailable or slow.")
                if !vm.hasPremiumAppleVoice {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Better offline voices are available. Download a Premium voice in System Settings → Accessibility → Spoken Content → System Voice → Manage Voices.").font(.caption)
                        HStack {
                            Button("Open Spoken Content Settings") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent") { NSWorkspace.shared.open(url) }
                            }
                            Button("Recheck") { Task { await vm.refreshVoices(force: true) } }
                        }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.yellow.opacity(0.15)))
                }
            }
        }
        .formStyle(.grouped)
    }

    private var groupedVoices: [(String, [Voice])] {
        let filtered = vm.voices.filter { search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search) }
        let groups = Dictionary(grouping: filtered, by: \.locale)
        return groups.keys.sorted { a, b in
            if a.hasPrefix("en") != b.hasPrefix("en") { return a.hasPrefix("en") }
            return a < b
        }.map { ($0, groups[$0] ?? []) }
    }
}
