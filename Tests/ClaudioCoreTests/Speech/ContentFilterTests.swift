import ClaudioCore
import TestSupport
import XCTest

final class ContentFilterTests: XCTestCase {
    func test_ContentFilter_truthTable_matchesSpec() {
        for thinking in [false, true] {
            for tools in [false, true] {
                for events in [false, true] {
                    let f = ContentFilter(speakThinking: thinking, speakToolResults: tools, eventsEnabled: events)
                    for level in SpeechLevel.allCases {
                        XCTAssertEqual(f.includes(.event, at: level), events)
                        XCTAssertEqual(f.includes(.finalAnswer, at: level), level != .quiet)
                        XCTAssertEqual(f.includes(.narration, at: level), level == .narrate)
                        XCTAssertEqual(f.includes(.toolCall, at: level), level == .narrate)
                        XCTAssertEqual(f.includes(.toolResult, at: level), level == .narrate && tools)
                        XCTAssertEqual(f.includes(.thinking, at: level), level == .narrate && thinking)
                    }
                }
            }
        }
    }

    func test_ContentFilter_catchUpBypassesLevel_andCuesBypassEventsToggle() {
        let f = ContentFilter(eventsEnabled: false)
        let catchUp = SpeechItem(sessionID: "s", turnID: "t", category: .finalAnswer, text: "x", timestamp: Date(), isCatchUp: true)
        XCTAssertTrue(f.includes(catchUp, at: .quiet))
        let cue = SpeechItem(sessionID: "s", turnID: nil, category: .event, text: Cues.mark("Live."), timestamp: Date())
        XCTAssertTrue(f.includes(cue, at: .quiet))
        let event = SpeechItem(sessionID: "s", turnID: nil, category: .event, text: "Yard finished.", timestamp: Date())
        XCTAssertFalse(f.includes(event, at: .narrate))
    }

    func test_ContentFilter_newlyExcluded() {
        let f = ContentFilter()
        XCTAssertEqual(f.newlyExcluded(from: .narrate, to: .answers), [.narration, .toolCall])
        XCTAssertEqual(f.newlyExcluded(from: .answers, to: .quiet), [.finalAnswer])
        XCTAssertEqual(f.newlyExcluded(from: .quiet, to: .narrate), [])
    }

    func test_Cues_wordings() {
        XCTAssertEqual(Cues.catchingUp("Vea", turns: 3), "Vea. Catching up on 3 turns.")
        XCTAssertEqual(Cues.catchingUp("Vea", turns: 1), "Vea. Catching up on 1 turn.")
        XCTAssertEqual(Cues.strip(Cues.mark("Live.")), "Live.")
        XCTAssertEqual(Cues.finished("Yard"), "Yard finished.")
    }
}
