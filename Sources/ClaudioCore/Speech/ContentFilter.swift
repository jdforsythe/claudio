import Foundation

/// Level + toggles → include? (document 05 §2).
public struct ContentFilter: Sendable, Equatable {
    public var speakThinking: Bool
    public var speakToolResults: Bool
    public var eventsEnabled: Bool

    public init(speakThinking: Bool = false, speakToolResults: Bool = false, eventsEnabled: Bool = true) {
        self.speakThinking = speakThinking
        self.speakToolResults = speakToolResults
        self.eventsEnabled = eventsEnabled
    }

    public init(snapshot: AppSettingsSnapshot) {
        self.init(speakThinking: snapshot.speakThinking, speakToolResults: snapshot.speakToolErrors,
                  eventsEnabled: snapshot.eventsEnabled)
    }

    public func includes(_ category: ContentCategory, at level: SpeechLevel) -> Bool {
        switch category {
        case .event: eventsEnabled
        case .finalAnswer: level != .quiet
        case .narration, .toolCall: level == .narrate
        case .toolResult: level == .narrate && speakToolResults
        case .thinking: level == .narrate && speakThinking
        }
    }

    /// Full decision for an item, honouring catch-up and cue exemptions.
    public func includes(_ item: SpeechItem, at level: SpeechLevel) -> Bool {
        if item.isCatchUp { return true }
        if item.category == .event, Cues.isCue(item.text) { return true }
        return includes(item.category, at: level)
    }

    /// Categories excluded at `to` that were included at `from`.
    public func newlyExcluded(from: SpeechLevel, to: SpeechLevel) -> Set<ContentCategory> {
        Set(ContentCategory.allCases.filter { includes($0, at: from) && !includes($0, at: to) })
    }
}
