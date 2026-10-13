import ClaudioCore
import SwiftUI

struct HUDView: View {
    @Environment(HUDViewModel.self) private var hud
    @Environment(PlaybackViewModel.self) private var playback
    @State private var hovering = false

    var body: some View {
        @Bindable var hud = hud
        HStack(spacing: 0) {
            Rectangle()
                .fill(hud.activeColorIndex.map { SessionColor.color(for: $0) } ?? Color.gray)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 0) {
                topRow
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
        .frame(width: 320)
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

    private var topRow: some View {
        @Bindable var hud = hud
        return HStack(spacing: 8) {
            Circle().fill(hud.activeColorIndex.map { SessionColor.color(for: $0) } ?? .gray).frame(width: 8, height: 8)
            Text(hud.activeTitle ?? "No session").font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.tail)
            stateGlyph
            if let p = hud.segmentProgress, p.total > 0 {
                ProgressView(value: Double(p.done), total: Double(p.total)).progressViewStyle(.linear).frame(width: 60)
                Text("\(p.done)/\(p.total)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Group {
                hudButton(playback.isPaused ? "play.fill" : "pause.fill", playback.isPaused ? "Resume" : "Pause") { playback.togglePause() }
                hudButton("forward.end.fill", "Skip sentence") { playback.skipSegment() }
                hudButton("forward.end.alt.fill", "Skip to live") { playback.skipToLive() }.disabled(!playback.isCatchingUp)
                hudButton(hud.captionsExpanded ? "chevron.up" : "chevron.down", "Captions") { hud.captionsExpanded.toggle() }
                hudButton(hud.pinned ? "pin.fill" : "pin", hud.pinned ? "Unpin" : "Pin") { hud.pinned.toggle() }
            }
            .opacity(hovering ? 1 : 0.55)
        }
        .padding(.horizontal, 12)
        .frame(height: 56)
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
