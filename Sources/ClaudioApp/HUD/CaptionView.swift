import SwiftUI

/// Current segment with the spoken word highlighted (document 07 §4.4).
struct CaptionView: View {
    @Environment(PlaybackViewModel.self) private var playback
    @Environment(HUDViewModel.self) private var hud

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let previous = playback.previousSegmentText, !previous.isEmpty {
                Text(previous).foregroundStyle(.secondary).opacity(0.6).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            if let current = playback.currentSegmentText {
                Text(attributed(current))
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .id(current)
                    .transition(reduceMotion ? .identity : .opacity.animation(.easeInOut(duration: 0.12)))
            } else {
                Text(" ").foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 13).monospacedDigit())
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func attributed(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        out.foregroundColor = .primary.opacity(0.85)
        if let range = playback.currentWordRange, range.lowerBound >= text.startIndex, range.upperBound <= text.endIndex,
           let lower = AttributedString.Index(range.lowerBound, within: out),
           let upper = AttributedString.Index(range.upperBound, within: out), lower < upper {
            let color = hud.activeColorIndex.map { SessionColor.color(for: $0) } ?? .accentColor
            out[lower..<upper].backgroundColor = color.opacity(playback.currentWordApproximate ? 0.2 : 0.35)
            out[lower..<upper].foregroundColor = .primary
        }
        return out
    }
}
