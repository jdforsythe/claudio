import SwiftUI

struct PopoverFooter: View {
    @Environment(SettingsViewModel.self) private var settings
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack {
            hooksLabel
            Spacer()
            if let version = CompositionRoot.shared.updater.availableVersion {
                Button("Update to \(version)") { Task { await CompositionRoot.shared.updater.installLatest() } }
                    .buttonStyle(.link).font(.caption)
            }
            Button { open() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Settings")
                .keyboardShortcut(",", modifiers: .command)
            Text("v\(versionText)").font(.caption2).foregroundStyle(.tertiary)
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.caption)
                .keyboardShortcut("q", modifiers: .command)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .frame(height: 36)
    }

    private func open() {
        CompositionRoot.shared.openSettings()
        openSettings()
    }

    private var versionText: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    @ViewBuilder private var hooksLabel: some View {
        switch settings.hooksStatus {
        case .disabled:
            Text("Hooks: off")
            Button("Turn on…") { open() }.buttonStyle(.link).font(.caption)
        case .installed(let count):
            Text("Hooks: \(count) installed")
        case .needsRepair:
            Text("Hooks: point elsewhere").foregroundStyle(.orange)
            Button("Repair") { settings.repairHooks() }.buttonStyle(.link).font(.caption)
        case .error(let message):
            Text("Hooks: error").foregroundStyle(.red).help(message)
            Button("Details…") { open() }.buttonStyle(.link).font(.caption)
        }
    }
}
