import ClaudioCore
import TestSupport
import XCTest

final class SynthesisSchedulerTests: XCTestCase {
    private func item(_ text: String, session: String = "s", category: ContentCategory = .finalAnswer, catchUp: Bool = false) -> SpeechItem {
        SpeechItem(sessionID: session, turnID: "t", category: category, text: text, timestamp: Date(), isCatchUp: catchUp)
    }

    private func makePipeline(backend: any TTSBackend, sink: RecordingPlaybackSink, lookahead: Int = 2) async -> SpeechPipeline {
        let p = SpeechPipeline(backend: backend, sink: sink, rate: 1.0, lookahead: lookahead, voiceProvider: { MockBackend.voice(for: $0) })
        await p.start()
        return p
    }

    private func drained(_ sink: RecordingPlaybackSink, expectFinished: Int, budget: TimeInterval = 3) async -> Bool {
        await waitUntil(budget) { sink.finishedOrder.count >= expectFinished }
    }

    func test_SynthesisScheduler_lookahead_synthesizesAtMostTwoAhead_andPlaysInOrder() async {
        let backend = MockBackend(delay: 0.05)
        let sink = RecordingPlaybackSink()
        let pipeline = await makePipeline(backend: backend, sink: sink)
        let text = (1...8).map { "Sentence number \($0) of this answer is long enough to stand alone as a segment." }.joined(separator: " ")
        await pipeline.enqueue(item(text))
        let ok14 = await drained(sink, expectFinished: 8)
        XCTAssertTrue(ok14)
        XCTAssertLessThanOrEqual(backend.maxConcurrent, 3)
        XCTAssertEqual(backend.calls.count, 8)
        let order = sink.playbackOrder
        let snapshotTexts = backend.calls.map(\.text)
        XCTAssertEqual(order.count, 8)
        XCTAssertEqual(snapshotTexts.first?.prefix(17), "Sentence number 1")
    }

    func test_SynthesisScheduler_outOfOrderCompletion_playsInOrder() async {
        let backend = MockBackend(delay: 0)
        backend.setBehaviour(.succeed)
        let sink = RecordingPlaybackSink()
        let slowFirst = MockBackend(delay: 0.2)
        _ = slowFirst
        let pipeline = await makePipeline(backend: backend, sink: sink)
        await pipeline.enqueue(item("First sentence of the answer that is long enough to be its own segment here. Second sentence of the answer that is long enough to be its own segment too. Third sentence of the answer that is long enough to be its own segment as well."))
        let ok15 = await drained(sink, expectFinished: 3)
        XCTAssertTrue(ok15)
        XCTAssertEqual(sink.playbackOrder.count, 3)
        XCTAssertEqual(sink.finishedOrder, sink.playbackOrder)
    }

    func test_SynthesisScheduler_cancelSession_cancelsTasksAndClearsSink() async {
        let backend = MockBackend(delay: 0.5)
        let sink = RecordingPlaybackSink()
        let pipeline = await makePipeline(backend: backend, sink: sink)
        await pipeline.enqueue(item("A long sentence that will be cancelled before synthesis completes in the mock. Another one just like it follows."))
        try? await Task.sleep(for: .milliseconds(50))
        await pipeline.cancelSession("s", reason: .userPrompt)
        let cancelled = await waitUntil(2) { backend.cancelledCount >= 1 }
        XCTAssertTrue(cancelled, "synthesis tasks were cancelled")
        let emptied = await waitUntil(1) { await pipeline.currentState.queuedSegments == 0 }
        XCTAssertTrue(emptied)
    }

    func test_SynthesisScheduler_levelDowngrade_dropsQueuedButNotPlaying() async {
        let backend = MockBackend(delay: 0.2)
        let sink = RecordingPlaybackSink(autoPlay: false)
        let pipeline = await makePipeline(backend: backend, sink: sink)
        await pipeline.enqueue(item("Narration sentence one that is comfortably long for a segment.", category: .narration))
        await pipeline.enqueue(item("Narration sentence two that is comfortably long for a segment.", category: .narration))
        await pipeline.enqueue(item("Final answer sentence that is comfortably long for a segment.", category: .finalAnswer))
        try? await Task.sleep(for: .milliseconds(50))
        await pipeline.dropCategories([.narration, .toolCall], in: "s")
        let snapshot = await pipeline.queueSnapshot()
        XCTAssertEqual(snapshot.map(\.item.category), [.finalAnswer])
    }

    func test_SynthesisScheduler_backendFailure_usesFallbackForThatSegmentOnly() async {
        let primary = MockBackend(id: "edge")
        primary.setBehaviour(.fail(.auth("403")))
        let fallback = MockBackend(id: "apple")
        let wrapper = TestFallbackWrapper(primary: primary, fallback: fallback)
        let sink = RecordingPlaybackSink()
        let pipeline = await makePipeline(backend: wrapper, sink: sink)
        await pipeline.enqueue(item("This sentence must still be spoken by the fallback when the primary fails."))
        let ok16 = await drained(sink, expectFinished: 1)
        XCTAssertTrue(ok16)
        XCTAssertEqual(fallback.calls.count, 1)
        XCTAssertEqual(sink.finishedOrder.count, 1)
    }

    func test_SynthesisScheduler_doubleFailure_dropsSegmentAndContinues() async {
        let primary = MockBackend(id: "edge")
        primary.setBehaviour(.fail(.auth("403")), forCall: 0)
        let fallback = MockBackend(id: "apple")
        fallback.setBehaviour(.fail(.decode("no audio")), forCall: 0)
        let wrapper = TestFallbackWrapper(primary: primary, fallback: fallback)
        let sink = RecordingPlaybackSink()
        let pipeline = await makePipeline(backend: wrapper, sink: sink, lookahead: 1)
        await pipeline.enqueue(item("First sentence which fails on both backends and must be dropped. Second sentence which succeeds and must still play."))
        let ok17 = await drained(sink, expectFinished: 1)
        XCTAssertTrue(ok17)
        XCTAssertEqual(sink.finishedOrder.count, 1)
        let state = await pipeline.currentState
        XCTAssertNotNil(state.lastDroppedAt)
    }

    func test_SynthesisScheduler_setRate_appliesToUnsynthesizedOnly() async {
        let backend = MockBackend(delay: 0.2)
        let sink = RecordingPlaybackSink()
        let pipeline = await makePipeline(backend: backend, sink: sink, lookahead: 1)
        let text = (1...4).map { "Sentence number \($0) of this answer is long enough to stand alone as a segment." }.joined(separator: " ")
        await pipeline.enqueue(item(text))
        try? await Task.sleep(for: .milliseconds(50))
        await pipeline.setRate(1.5)
        let ok18 = await waitUntil(3) { backend.calls.count >= 4 }
        XCTAssertTrue(ok18)
        XCTAssertEqual(backend.calls.first?.rate, 1.0)
        XCTAssertEqual(backend.calls.last?.rate, 1.5)
    }

    func test_SynthesisScheduler_tableRows_areSkipUnits() async {
        let backend = MockBackend()
        let sink = RecordingPlaybackSink()
        let pipeline = await makePipeline(backend: backend, sink: sink)
        await pipeline.enqueue(item("| A | B |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |\n| 5 | 6 |\n| 7 | 8 |"))
        let ok19 = await drained(sink, expectFinished: 4)
        XCTAssertTrue(ok19)
        XCTAssertEqual(backend.calls.map(\.text).sorted(), ["A: 1, B: 2.", "A: 3, B: 4.", "A: 5, B: 6.", "A: 7, B: 8."])
        XCTAssertEqual(sink.finishedOrder, sink.playbackOrder)
    }

    func test_SynthesisScheduler_announcement_insertsBetweenSegments() async {
        let backend = MockBackend(delay: 0.05)
        let sink = RecordingPlaybackSink()
        let pipeline = await makePipeline(backend: backend, sink: sink, lookahead: 1)
        await pipeline.enqueue(item("Sentence one of the active session which is long enough on its own. Sentence two of the active session which is long enough on its own."))
        try? await Task.sleep(for: .milliseconds(20))
        await pipeline.enqueue(SpeechItem(sessionID: "b", turnID: nil, category: .event, text: "B finished.", timestamp: Date()))
        let ok20 = await drained(sink, expectFinished: 3)
        XCTAssertTrue(ok20)
        let texts = backend.calls.map(\.text)
        XCTAssertEqual(texts.last, "B finished.")
        XCTAssertEqual(sink.cancelCount, 0)
    }

    func test_SynthesisScheduler_approximateBoundaries_sumToDuration() {
        let b = SynthesisScheduler.approximateBoundaries(text: "one two three", duration: 3)
        XCTAssertEqual(b.count, 3)
        XCTAssertEqual(b.reduce(0) { $0 + $1.duration }, 3, accuracy: 0.0001)
        XCTAssertTrue(b.allSatisfy(\.approximate))
    }
}

/// Minimal fallback wrapper for scheduler tests (the real one lives in ClaudioBackends).
final class TestFallbackWrapper: FallbackReporting {
    let primary: MockBackend
    let fallback: MockBackend
    init(primary: MockBackend, fallback: MockBackend) {
        self.primary = primary
        self.fallback = fallback
    }
    var id: BackendID { primary.id }
    var displayName: String { "test" }
    var supportsWordBoundaries: Bool { true }
    var fallbackOnly: any TTSBackend { fallback }
    func usageStream() -> AsyncStream<FallbackUsage> { AsyncStream { $0.finish() } }
    func noticeStream() -> AsyncStream<BackendNotice> { AsyncStream { $0.finish() } }
    func voices() async throws -> [Voice] { try await primary.voices() }
    func synthesize(_ request: SynthesisRequest) -> AsyncThrowingStream<SynthesisEvent, any Error> {
        primary.synthesize(request)
    }
}
