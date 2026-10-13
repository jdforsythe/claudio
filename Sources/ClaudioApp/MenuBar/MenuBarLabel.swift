import SwiftUI

struct MenuBarLabel: View {
    @Environment(PlaybackViewModel.self) private var playback
    @Environment(SessionsViewModel.self) private var sessions

    var body: some View {
        let unread = sessions.totalUnread
        ZStack(alignment: .topTrailing) {
            symbol
            if unread > 0 {
                Text(unread > 9 ? "9+" : "\(unread)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .frame(height: 12)
                    .background(Capsule().fill(Color.accentColor))
                    .offset(x: 7, y: -5)
            }
        }
        .help(tooltip)
        .accessibilityLabel(tooltip)
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    @ViewBuilder private var symbol: some View {
        switch playback.menuState {
        case .idle:
            Image(systemName: "waveform").foregroundStyle(.secondary)
        case .speaking:
            Image(systemName: "waveform").symbolEffect(.variableColor.iterative.reversing, isActive: !reduceMotion)
        case .paused:
            Image(systemName: "pause.circle")
        case .muted:
            Image(systemName: "speaker.slash").foregroundStyle(.secondary)
        case .catchingUp:
            Image(systemName: "waveform").symbolEffect(.variableColor.iterative.reversing, isActive: !reduceMotion)
                .overlay(alignment: .bottomTrailing) { Image(systemName: "clock.arrow.circlepath").font(.system(size: 8)) }
        }
    }

    private var tooltip: String {
        let title = sessions.activeSession?.title ?? ""
        switch playback.menuState {
        case .idle: return "Claudio — idle"
        case .speaking: return "Claudio — speaking: \(title)"
        case .paused: return "Claudio — paused"
        case .muted: return "Claudio — muted"
        case .catchingUp: return "Claudio — catching up on \(title)"
        }
    }
}
