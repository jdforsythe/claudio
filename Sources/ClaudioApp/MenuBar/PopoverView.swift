import ClaudioCore
import SwiftUI

struct PopoverView: View {
    @Environment(SessionsViewModel.self) private var sessions
    @Environment(PlaybackViewModel.self) private var playback
    @Environment(SettingsViewModel.self) private var settings
    @FocusState private var focusedSessionID: SessionID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if sessions.sessions.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(sessions.sortedSessions) { session in
                            SessionRow(session: session, isActive: session.id == sessions.activeSessionID)
                                .focused($focusedSessionID, equals: session.id)
                        }
                    }
                }
                .frame(maxHeight: 560 - 44 - 36)
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            PopoverFooter()
        }
        .frame(width: 360)
        .onAppear { playback.setActiveTitle(sessions.activeSession?.title) }
        .onChange(of: sessions.activeSessionID) { _, _ in playback.setActiveTitle(sessions.activeSession?.title) }
        .onChange(of: sessions.sessions) { _, _ in playback.setActiveTitle(sessions.activeSession?.title) }
        .onKeyPress(.space) { playback.togglePause(); return .handled }
        .onKeyPress(.return) {
            if let id = focusedSessionID { sessions.activate(id); return .handled }
            return .ignored
        }
        .onKeyPress(.upArrow) { moveFocus(-1); return .handled }
        .onKeyPress(.downArrow) { moveFocus(1); return .handled }
        .onKeyPress("1") { setFocusedLevel(.quiet) }
        .onKeyPress("2") { setFocusedLevel(.answers) }
        .onKeyPress("3") { setFocusedLevel(.narrate) }
    }

    private func moveFocus(_ delta: Int) {
        let ordered = sessions.sortedSessions
        guard !ordered.isEmpty else { return }
        guard let current = focusedSessionID, let idx = ordered.firstIndex(where: { $0.id == current }) else {
            focusedSessionID = ordered[0].id
            return
        }
        focusedSessionID = ordered[max(0, min(ordered.count - 1, idx + delta))].id
    }

    private func setFocusedLevel(_ level: SpeechLevel) -> KeyPress.Result {
        guard let id = focusedSessionID else { return .ignored }
        sessions.setLevel(level, for: id)
        return .handled
    }

    private var header: some View {
        HStack(spacing: 4) {
            transportButton(playback.isMuted ? "speaker.slash" : "speaker.wave.2", label: playback.isMuted ? "Unmute" : "Mute") { playback.toggleMute() }
            transportButton(playback.isPaused ? "play.fill" : "pause.fill", label: playback.isPaused ? "Resume" : "Pause") { playback.togglePause() }
            transportButton("forward.end.fill", label: "Skip sentence") { playback.skipSegment() }
                .disabled(playback.queueDepth == 0)
            transportButton("forward.end.alt.fill", label: "Skip to live") { playback.skipToLive() }
                .disabled(!playback.isCatchingUp)
            Spacer()
            Text(playback.statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    private func transportButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 28, height: 28)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
        .help(label)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.slash").font(.system(size: 32)).foregroundStyle(.tertiary)
            Text("No Claude Code sessions yet.").font(.body.weight(.semibold))
            Text("Start one in a terminal and it appears here.").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 160)
    }
}
