import ClaudioCore
import SwiftUI

struct SessionsTab: View {
    @Environment(SettingsViewModel.self) private var vm
    @State private var candidates: [URL] = []
    @State private var showAddProject = false

    var body: some View {
        @Bindable var settings = vm.settings
        Form {
            Section("Transcript folders") {
                HelpText("Claudio always watches ~/.claude/projects. Add more folders for other Claude accounts, for example Orca account homes.")
                ForEach(settings.extraTranscriptRoots, id: \.path) { root in
                    HStack {
                        Circle().fill(FileManager.default.fileExists(atPath: root.path) ? Color.green : Color.red).frame(width: 8, height: 8)
                        Text(root.path.abbreviatingHome).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { vm.removeRoot(root) } label: { Image(systemName: "minus") }.buttonStyle(.borderless)
                    }
                }
                Button { pickFolder() } label: { Label("Add folder…", systemImage: "plus") }
            }
            Section {
                LabeledContent("Keep sessions for", value: "\(settings.sessionExpiryHours) hours after last activity")
            }
            Section("Project defaults") {
                HelpText("A project's default level applies when one of its sessions becomes active. Worktrees inherit their parent folder's default.")
                ForEach(vm.projectEntries, id: \.0.path) { url, entry in
                    HStack {
                        Text(url.path.abbreviatingHome).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Picker("", selection: Binding(get: { entry.defaultLevel }, set: { vm.setProjectDefault($0, for: url) })) {
                            ForEach(SpeechLevel.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 180)
                        Button { vm.removeProjectDefault(for: url) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
                Menu("Add current project…") {
                    ForEach(candidates, id: \.path) { url in
                        Button(url.path.abbreviatingHome) { vm.setProjectDefault(settings.defaultLevelActive, for: url) }
                    }
                    if candidates.isEmpty { Text("No known sessions") }
                }
                .task { candidates = await vm.knownProjectPaths }
            }
        }
        .formStyle(.grouped)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { vm.addRoot(url) }
    }
}
