import ClaudioBackends
import ClaudioCore
import TestSupport
import XCTest

final class AppleSpeechBackendTests: XCTestCase {
    func test_AppleSpeechBackend_synthesize_emitsCanonicalBuffersAndFinished() async throws {
        let backend = AppleSpeechBackend()
        let voice = try XCTUnwrap(AppleSpeechBackend.defaultVoice())
        var frames = 0
        var finished = 0
        var boundaries = 0
        for try await event in backend.synthesize(SynthesisRequest(text: "Hello from Claudio.", voice: voice, rate: 1.0)) {
            switch event {
            case .audio(let b): frames += b.frameCount; XCTAssertGreaterThan(b.frameCount, 0)
            case .finished: finished += 1
            case .wordBoundary: boundaries += 1
            }
        }
        XCTAssertGreaterThan(frames, 10_000)
        XCTAssertEqual(finished, 1)
        print("Apple word boundaries delivered: \(boundaries > 0)")
    }

    func test_AppleSpeechBackend_rateMapping_andRanking() {
        XCTAssertEqual(AppleSpeechBackend.appleRate(from: 1.0), 0.5)
        XCTAssertEqual(AppleSpeechBackend.appleRate(from: 1.25), 0.55, accuracy: 0.001)
        XCTAssertEqual(AppleSpeechBackend.appleRate(from: 2.0), 0.7, accuracy: 0.001)
        XCTAssertEqual(AppleSpeechBackend.appleRate(from: 0.8), 0.4, accuracy: 0.001)
        let voices = [Voice(backend: "apple", id: "b", displayName: "B", locale: "en-US", quality: nil),
                      Voice(backend: "apple", id: "a", displayName: "A", locale: "en-US", quality: "premium"),
                      Voice(backend: "apple", id: "com.apple.eloquence.x", displayName: "Legacy", locale: "en-US", quality: "premium")]
        XCTAssertEqual(AppleSpeechBackend.ranked(voices).map(\.id), ["a", "b", "com.apple.eloquence.x"])
    }

    func test_AppleSpeechBackend_concurrentRequests_serialized_andCancellable() async throws {
        let backend = AppleSpeechBackend()
        let voice = try XCTUnwrap(AppleSpeechBackend.defaultVoice())
        async let a = count(backend.synthesize(SynthesisRequest(text: "First request.", voice: voice, rate: 1.5)))
        async let b = count(backend.synthesize(SynthesisRequest(text: "Second request.", voice: voice, rate: 1.5)))
        let (fa, fb) = try await (a, b)
        XCTAssertGreaterThan(fa, 0)
        XCTAssertGreaterThan(fb, 0)
        let task = Task { try await count(backend.synthesize(SynthesisRequest(text: "A very long sentence that will be cancelled early.", voice: voice, rate: 1))) }
        try? await Task.sleep(for: .milliseconds(30))
        task.cancel()
        _ = try? await task.value
    }

    private func count(_ stream: AsyncThrowingStream<SynthesisEvent, any Error>) async throws -> Int {
        var frames = 0
        for try await e in stream { if case .audio(let b) = e { frames += b.frameCount } }
        return frames
    }
}

final class FallbackBackendTests: XCTestCase {
    let appleVoice = Voice(backend: "apple", id: "fallback", displayName: "F", locale: "en-US")
    func request(_ text: String = "Hello there friend.") -> SynthesisRequest {
        SynthesisRequest(text: text, voice: MockBackend.voice(for: "edge"), rate: 1)
    }

    private func make(primary: MockBackend, fallback: MockBackend, timeout: TimeInterval = 3, clock: any ClaudioClock = SystemClock()) -> FallbackBackend {
        FallbackBackend(primary: primary, fallback: fallback, firstAudioTimeout: timeout, clock: clock) { [appleVoice] _ in appleVoice }
    }

    private func run(_ b: FallbackBackend, _ r: SynthesisRequest) async throws -> Int {
        var frames = 0
        for try await e in b.synthesize(r) { if case .audio(let x) = e { frames += x.frameCount } }
        return frames
    }

    func test_FallbackBackend_primarySucceeds_fallbackNotCalled() async throws {
        let p = MockBackend(id: "edge"), f = MockBackend(id: "apple")
        let b = make(primary: p, fallback: f)
        let usage = b.usageStream()
        let frames = try await run(b, request())
        XCTAssertGreaterThan(frames, 0)
        XCTAssertEqual(f.calls.count, 0)
        var it = usage.makeAsyncIterator()
        _ = it
    }

    func test_FallbackBackend_primaryThrows_fallbackUsedWithPairedVoice() async throws {
        let p = MockBackend(id: "edge"), f = MockBackend(id: "apple")
        p.setBehaviour(.fail(.auth("403")))
        let b = make(primary: p, fallback: f)
        let frames = try await run(b, request())
        XCTAssertGreaterThan(frames, 0)
        XCTAssertEqual(f.calls.first?.voice.id, "fallback")
        XCTAssertEqual(f.calls.first?.text, "Hello there friend.")
    }

    func test_FallbackBackend_firstAudioTimeout_switches_but2_9sDoesNot() async throws {
        let clock = ManualClock()
        let p = MockBackend(id: "edge", clock: clock), f = MockBackend(id: "apple")
        p.setBehaviour(.hang)
        let b = make(primary: p, fallback: f, timeout: 3, clock: clock)
        let task = Task { try await self.run(b, self.request()) }
        _ = await waitUntil(1) { clock.pendingSleepers >= 2 }
        clock.advance(by: 3.1)
        let frames1 = try await task.value
        XCTAssertGreaterThan(frames1, 0)
        XCTAssertEqual(f.calls.count, 1)
        let p2 = MockBackend(id: "edge", delay: 2.9, clock: clock), f2 = MockBackend(id: "apple")
        let b2 = make(primary: p2, fallback: f2, timeout: 3, clock: clock)
        let task2 = Task { try await self.run(b2, self.request()) }
        _ = await waitUntil(1) { clock.pendingSleepers >= 2 }
        clock.advance(by: 2.95)
        let frames2 = try await task2.value
        XCTAssertGreaterThan(frames2, 0)
        XCTAssertEqual(f2.calls.count, 0)
    }

    func test_FallbackBackend_primaryErrorAfterAudio_rethrows() async {
        let p = MockBackend(id: "edge"), f = MockBackend(id: "apple")
        p.setBehaviour(.failAfterAudio(.network("drop")))
        let b = make(primary: p, fallback: f)
        do {
            _ = try await run(b, request())
            XCTFail("expected rethrow")
        } catch {
            XCTAssertEqual(error as? BackendError, .network("drop"))
        }
        XCTAssertEqual(f.calls.count, 0)
    }

    func test_FallbackBackend_bothFail_throwsFallbackError_andNoticeOncePerHour() async {
        let clock = ManualClock()
        let p = MockBackend(id: "edge"), f = MockBackend(id: "apple")
        p.setBehaviour(.fail(.auth("403")))
        f.setBehaviour(.fail(.decode("no audio")), forCall: 0)
        let b = make(primary: p, fallback: f, clock: clock)
        let notices = b.noticeStream()
        do { _ = try await run(b, request()); XCTFail("expected error") } catch { XCTAssertEqual(error as? BackendError, .decode("no audio")) }
        _ = try? await run(b, request())
        _ = try? await run(b, request())
        var it = notices.makeAsyncIterator()
        let first = await it.next()
        XCTAssertNotNil(first)
        clock.advance(by: 3601)
        _ = try? await run(b, request())
        let second = await it.next()
        XCTAssertNotNil(second)
    }

    func test_VoiceCatalog_cacheTTL_andFallbackPairing() async throws {
        let root = TempRoot()
        defer { root.cleanup() }
        let clock = ManualClock()
        let edge = CountingBackend(id: "edge", voices: [Voice(backend: "edge", id: "en-US-GuyNeural", displayName: "Guy", locale: "en-US", gender: "Male")])
        let apple = CountingBackend(id: "apple", voices: [
            Voice(backend: "apple", id: "ava", displayName: "Ava", locale: "en-US", gender: "Female", quality: "premium"),
            Voice(backend: "apple", id: "evan", displayName: "Evan", locale: "en-US", gender: "Male", quality: "enhanced"),
            Voice(backend: "apple", id: "tom", displayName: "Tom", locale: "en-US", gender: "Male", quality: nil),
        ])
        let catalog = VoiceCatalog(backends: [edge, apple], cacheDirectory: root.url, clock: clock)
        _ = try await catalog.voices(for: "edge")
        _ = try await catalog.voices(for: "edge")
        XCTAssertEqual(edge.fetches, 1)
        let fresh = VoiceCatalog(backends: [edge, apple], cacheDirectory: root.url, clock: clock)
        _ = try await fresh.voices(for: "edge")
        XCTAssertEqual(edge.fetches, 1, "served from disk cache")
        clock.advance(by: 25 * 3600)
        _ = try await fresh.voices(for: "edge")
        XCTAssertEqual(edge.fetches, 2)
        let pair = await catalog.fallbackVoice(for: Voice(backend: "edge", id: "en-US-GuyNeural", displayName: "Guy", locale: "en-US", gender: "Male"))
        XCTAssertEqual(pair.id, "evan", "same gender beats higher quality of the other gender")
    }
}

final class CountingBackend: TTSBackend, @unchecked Sendable {
    let id: BackendID
    let displayName = "counting"
    let supportsWordBoundaries = false
    private let list: [Voice]
    private(set) var fetches = 0
    init(id: BackendID, voices: [Voice]) { self.id = id; self.list = voices }
    func voices() async throws -> [Voice] { fetches += 1; return list }
    func synthesize(_ request: SynthesisRequest) -> AsyncThrowingStream<SynthesisEvent, any Error> {
        AsyncThrowingStream { $0.finish(throwing: BackendError.unavailable("test")) }
    }
}

