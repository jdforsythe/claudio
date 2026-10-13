import SwiftUI

struct IntegrationTab: View {
    @Environment(SettingsViewModel.self) private var vm

    var body: some View {
        @Bindable var settings = vm.settings
        Form {
            Section {
                Toggle("Install Claude Code hooks", isOn: Binding(get: { settings.hooksEnabled }, set: { on in if on { vm.installHooks() } else { vm.uninstallHooks() } }))
                    .disabled(!vm.isBundled)
                HelpText(vm.isBundled ? "Adds entries to ~/.claude/settings.json so Claudio hears prompts and turn ends instantly. Existing hooks are left untouched. Turning this off removes only Claudio's entries." : "Install the app to enable hooks")
                HStack {
                    statusLine
                    Spacer()
                    if case .needsRepair = vm.hooksStatus { Button("Repair") { vm.repairHooks() } }
                    if case .error = vm.hooksStatus { Button("Open file") { vm.revealClaudeSettings() } }
                }
            }
            Section {
                HStack {
                    Button(vm.cliLinked ? "Remove `claudio` command" : "Install `claudio` command") {
                        Task { if vm.cliLinked { await vm.unlinkCLI() } else { await vm.linkCLI() } }
                    }
                    if vm.cliLinked { Text("Installed at /usr/local/bin/claudio").font(.caption).foregroundStyle(.secondary) }
                }
                HelpText("Links /usr/local/bin/claudio to the copy inside this app so you can run it from any terminal.")
                Button(vm.skillInstalled ? "Remove /speak skill" : "Install /speak skill") {
                    if vm.skillInstalled { vm.uninstallSkill() } else { vm.installSkill() }
                }
                HelpText("Adds a Claude Code skill that controls Claudio from inside a session (/speak off, /speak narrate).")
                Button("Open ~/.claude/settings.json") { vm.revealClaudeSettings() }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var statusLine: some View {
        switch vm.hooksStatus {
        case .disabled: Text("Hooks are off.")
        case .installed(let n): Text("\(n) hooks installed, all pointing at this app.")
        case .needsRepair: Text("Hooks point at a different Claudio location.").foregroundStyle(.orange)
        case .error: Text("settings.json could not be parsed. Nothing was changed.").foregroundStyle(.red)
        }
    }
}
