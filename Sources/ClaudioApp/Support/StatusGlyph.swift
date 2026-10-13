import ClaudioCore
import SwiftUI

struct StatusGlyph: View {
    let status: SessionStatus

    var body: some View {
        switch status {
        case .busy:
            Image(systemName: "circle.dotted").symbolEffect(.rotate, isActive: !reduceMotion).foregroundStyle(.secondary)
        case .waiting:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .idle:
            EmptyView()
        case .ended:
            Image(systemName: "stop.circle").foregroundStyle(.secondary)
        }
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

enum StatusText {
    static func text(for session: Session, now: Date = Date()) -> String {
        switch session.status {
        case .busy: "working"
        case .waiting: "needs you"
        case .idle:
            "idle " + RelativeDateTimeFormatter.abbreviated.localizedString(for: session.lastActivity, relativeTo: now)
        case .ended: "ended"
        }
    }
}

extension RelativeDateTimeFormatter {
    nonisolated(unsafe) static let abbreviated: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}
