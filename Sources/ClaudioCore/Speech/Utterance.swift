import Foundation

/// Rendered, speakable text for one item, divided into skip units (document 02 §4).
public struct Utterance: Sendable, Equatable {
    public let item: SpeechItem
    public var segments: [Segment]

    public struct Segment: Sendable, Identifiable, Equatable {
        public let id: UUID
        public let text: String
        public let kind: Kind

        public enum Kind: String, Sendable, Codable {
            case sentence
            case tableRow
            case listItem
            case heading
            case cue
        }

        public init(id: UUID = UUID(), text: String, kind: Kind) {
            self.id = id
            self.text = text
            self.kind = kind
        }
    }

    public init(item: SpeechItem, segments: [Segment]) {
        self.item = item
        self.segments = segments
    }

    public var characterCount: Int { segments.reduce(0) { $0 + $1.text.count } }
}
