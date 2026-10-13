import SwiftUI

struct PromptStackView: View {
    @Environment(HUDViewModel.self) private var hud

    var body: some View {
        ForEach(hud.prompts) { prompt in
            HStack(spacing: 4) {
                Text("\(prompt.title) \(prompt.verb) — ")
                Button("Switch (↩)") { hud.acceptPrompt(prompt.id) }.buttonStyle(.link)
                Spacer()
                Button { hud.dismissPrompt(prompt.id) } label: { Image(systemName: "xmark").font(.caption2) }
                    .buttonStyle(.borderless).accessibilityLabel("Dismiss")
            }
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 22)
            .contentShape(Rectangle())
            .onTapGesture { hud.acceptPrompt(prompt.id) }
        }
    }
}
