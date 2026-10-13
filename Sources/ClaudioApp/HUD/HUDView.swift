import ClaudioCore
import SwiftUI

struct HUDView: View {
    static let width: CGFloat = 460

    @Environment(HUDViewModel.self) private var hud
    @Environment(PlaybackViewModel.self) private var playback
    @Environment(SessionsViewModel.self) private var sessions
    @Environment(SettingsViewModel.self) private var settings
    @State private var hovering = false

    var body: some View {
        @Bindable var hud = hud
        HStack(spacing: 0) {
            Rectangle()
                .fill(hud.activeColorIndex.map { SessionColor.color(for: $0) } ?? Color.gray)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 0) {
                titleRow
                controlRow
                if let progress = hud.catchUpProgress {
                    HStack(spacing: 6) {
                        Text("Catching up \(progress.index)/\(progress.total)")
                        Button("Skip to live") { playback.skipToLive() }.buttonStyle(.link)
                    }
                    .font(.caption)
                    .frame(height: 20)
                    .padding(.horizontal, 12)
                }
                PromptStackView()
                if let notice = hud.notice {
                    Text(notice).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).frame(height: 20)
                }
                if hud.captionsExpanded {
                    Divider()
                    CaptionView()
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
            }
        }
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator, lineWidth: 0.5))
        .onHover { h in
            hovering = h
            CompositionRoot.shared.hudController?.setHovered(h)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: hud.captionsExpanded)
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // Row 1: session picker (title on its own line), state, progress.
    private var titleRow: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(sessions.sortedSessions) { session in
                    Button {
                        sessions.activate(session.id)
                    } label: {
                        HStack {
                            Text(session.id == sessions.activeSessionID ? "● " : "○ ") + Text(session.title)
                            Text(" · \(StatusText.text(for: session))")
                        }
                    }
                }
                if sessions.sessions.isEmpty { Text("No sessions") }
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(hud.activeColorIndex.map { SessionColor.color(for: $0) } ?? .gray).frame(width: 8, height: 8)
                    Text(hud.activeTitle ?? "No session").font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: false, vertical: true)
            .help("Switch session")
            Spacer(minLength: 8)
            stateGlyph
            if let p = hud.segmentProgress, p.total > 0 {
                ProgressView(value: Double(p.done), total: Double(p.total)).progressViewStyle(.linear).frame(width: 70)
                Text("\(p.done) / \(p.total)")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .help("Sentence \(p.done) of \(p.total) in this answer")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .frame(height: 36)
    }

    // Row 2: transport, voice, speed, captions, pin.
    private var controlRow: some View {
        @Bindable var hud = hud
        return HStack(spacing: 6) {
            hudButton(playback.isPaused ? "play.fill" : "pause.fill", playback.isPaused ? "Resume" : "Pause") { playback.togglePause() }
            hudButton("forward.fill", "Skip this sentence") { playback.skipSegment() }
            if playback.isCatchingUp {
                Button { playback.skipToLive() } label: {
                    Label("Skip to live", systemImage: "forward.end.alt.fill").font(.caption)
                }
                .buttonStyle(.bordered).controlSize(.small).help("Abandon the catch-up and jump to what is being written now")
            }
            Spacer(minLength: 8)
            voiceMenu
            speedStepper
            hudButton(hud.captionsExpanded ? "chevron.up" : "chevron.down", hud.captionsExpanded ? "Hide transcript" : "Show transcript") { hud.captionsExpanded.toggle() }
            hudButton(hud.pinned ? "pin.fill" : "pin", hud.pinned ? "Unpin (hide when idle)" : "Pin (keep visible)") { hud.pinned.toggle() }
        }
        .opacity(hovering ? 1 : 0.7)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .frame(height: 40)
    }

    private var voiceMenu: some View {
        @Bindable var app = settings.settings
        let current = settings.voices.first { $0.id == app.voiceID }
        let language = current?.languageCode ?? "en"
        let shown = settings.voices.filter { $0.languageCode == language }
        return Menu {
            Picker("Engine", selection: $app.backendID) {
                Text("Edge (online)").tag("edge")
                Text("Apple (offline)").tag("apple")
                Text("OpenAI").tag("openai")
            }
            Divider()
            ForEach(shown, id: \.id) { voice in
                Button {
                    app.voiceID = voice.id
                } label: {
                    Text((voice.id == app.voiceID ? "✓ " : "") + voice.displayName)
                }
            }
            if shown.count < settings.voices.count {
                Divider()
                Button("All voices in Settings…") { CompositionRoot.shared.openSettings() }
            }
        } label: {
            Label(current?.displayName.split(separator: " (").first.map(String.init) ?? app.voiceID, systemImage: "person.wave.2")
                .font(.caption).lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Voice")
    }

    private var speedStepper: some View {
        @Bindable var app = settings.settings
        return HStack(spacing: 2) {
            Button { app.rate = (app.rate - 0.05).rounded(toNearest: 0.05) } label: { Image(systemName: "minus") }
                .buttonStyle(.borderless).help("Slower")
            Text(String(format: "%.2f×", app.rate)).font(.caption.monospacedDigit()).frame(width: 44).help("Speed; applies to the next sentence")
            Button { app.rate = (app.rate + 0.05).rounded(toNearest: 0.05) } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless).help("Faster")
        }
    }

    private func hudButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 22, height: 22) }
            .buttonStyle(.borderless).accessibilityLabel(label).help(label)
    }

    @ViewBuilder private var stateGlyph: some View {
        switch playback.menuState {
        case .speaking: Image(systemName: "waveform").symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
        case .paused: Image(systemName: "pause.fill")
        case .catchingUp: Image(systemName: "clock.arrow.circlepath")
        case .muted: Image(systemName: "speaker.slash").foregroundStyle(.tertiary)
        case .idle: Image(systemName: "waveform").foregroundStyle(.tertiary)
        }
    }
}

extension Double {
    func rounded(toNearest step: Double) -> Double { (self / step).rounded() * step }
}
