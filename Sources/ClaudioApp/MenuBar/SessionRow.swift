import ClaudioCore
import SwiftUI

struct SessionRow: View {
    @Environment(SessionsViewModel.self) private var sessions
    let session: Session
    let isActive: Bool

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(session.isLive ? SessionColor.color(for: session.colorIndex) : Color.clear)
                .overlay(Circle().stroke(SessionColor.color(for: session.colorIndex), lineWidth: session.isLive ? 0 : 1.5))
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: entrypointSymbol).font(.caption2).foregroundStyle(.tertiary)
                    Text(session.title).font(.body.weight(.medium)).lineLimit(1).truncationMode(.tail).help(session.id)
                    if isActive {
                        Text("ACTIVE").font(.caption2.weight(.bold)).foregroundStyle(Color.accentColor)
                    }
                    if !isActive, session.unreadTurns.count > 0 {
                        Text("\(session.unreadTurns.count)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .background(Capsule().fill(Color.accentColor))
                            .accessibilityLabel("\(session.unreadTurns.count) unread turns")
                    }
                }
                HStack(spacing: 4) {
                    Text(session.cwd.path.abbreviatingHome).lineLimit(1).truncationMode(.middle)
                    Text("·")
                    StatusGlyph(status: session.status)
                    Text(StatusText.text(for: session)).foregroundStyle(session.status == .waiting ? Color.orange : Color.secondary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Picker("", selection: sessions.binding(forLevelOf: session.id)) {
                Text("Quiet").tag(SpeechLevel.quiet)
                Text("Answers").tag(SpeechLevel.answers)
                Text("Narrate").tag(SpeechLevel.narrate)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 132)
            .controlSize(.small)
            .accessibilityLabel("Speech level for \(session.title)")
        }
        .padding(.horizontal, 12)
        .frame(height: 56)
        .background(RoundedRectangle(cornerRadius: 8).fill(isActive ? Color.accentColor.opacity(0.04) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { sessions.activate(session.id) }
        .focusable()
        .accessibilityElement(children: .combine)
        .accessibilityValue("\(session.title), \(StatusText.text(for: session)), \(session.unreadTurns.count) unread, level \(session.level.rawValue)")
        .accessibilityAction(named: "Activate") { sessions.activate(session.id) }
    }

    private var entrypointSymbol: String {
        switch session.entrypoint {
        case .cli: "terminal"
        case .claudeDesktop: "macwindow"
        case .orca: "square.grid.2x2"
        case .unknown: "questionmark.circle"
        }
    }
}
