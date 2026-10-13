@testable import ClaudioBackends
import ClaudioCore
import TestSupport
import XCTest

final class EdgeTests: XCTestCase {
    let reference = Date(timeIntervalSince1970: 1_791_228_600)  // 2026-10-05T19:30:00Z

    func test_EdgeDRM_secMsGec_matchesKnownVector() {
        XCTAssertEqual(EdgeDRM.secMSGEC(now: reference, skew: 0), "3B586E574C155E70B7B684E075B31E0522E824CF8671B7F09D71323CECC13FA3")
    }

    func test_EdgeDRM_roundsDownToFiveMinutes_andSkewApplied() {
        let a = EdgeDRM.secMSGEC(now: reference, skew: 0)
        XCTAssertEqual(EdgeDRM.secMSGEC(now: reference.addingTimeInterval(240), skew: 0), a)
        XCTAssertNotEqual(EdgeDRM.secMSGEC(now: reference.addingTimeInterval(300), skew: 0), a)
        XCTAssertEqual(EdgeDRM.secMSGEC(now: reference, skew: 300), EdgeDRM.secMSGEC(now: reference.addingTimeInterval(300), skew: 0))
        XCTAssertEqual(EdgeDRM.connectionID().count, 32)
        XCTAssertEqual(EdgeDRM.muid().count, 32)
        XCTAssertEqual(EdgeDRM.parseHTTPDate("Mon, 05 Oct 2026 19:30:00 GMT"), reference)
    }

    func test_EdgeProtocol_frames_exact() throws {
        let config = EdgeProtocol.speechConfigFrame(wordBoundaries: true, now: reference)
        XCTAssertTrue(config.hasPrefix("X-Timestamp:Mon Oct 05 2026 19:30:00 GMT+0000 (Coordinated Universal Time)\r\nContent-Type:application/json; charset=utf-8\r\nPath:speech.config\r\n\r\n"))
        XCTAssertTrue(config.contains(#""wordBoundaryEnabled":"true""#))
        XCTAssertTrue(config.contains(#""sentenceBoundaryEnabled":"false""#))
        let ssml = EdgeProtocol.ssml(text: "Tom & <Jerry> \"say\" 'hi'\n\u{01}", voice: "en-US-GuyNeural", rate: 1.25)
        XCTAssertEqual(ssml, "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'><voice name='en-US-GuyNeural'><prosody pitch='+0Hz' rate='+25%' volume='+0%'>Tom &amp; &lt;Jerry&gt; &quot;say&quot; &apos;hi&apos; </prosody></voice></speak>")
        let frame = try EdgeProtocol.ssmlFrame(requestID: "abc", ssml: ssml, now: reference)
        XCTAssertTrue(frame.hasPrefix("X-RequestId:abc\r\nContent-Type:application/ssml+xml\r\nX-Timestamp:Mon Oct 05 2026 19:30:00 GMT+0000 (Coordinated Universal Time)Z\r\nPath:ssml\r\n\r\n<speak"))
        XCTAssertThrowsError(try EdgeProtocol.ssmlFrame(requestID: "a", ssml: String(repeating: "x", count: 5000), now: reference))
    }

    func test_EdgeProtocol_rateMapping() {
        XCTAssertEqual(EdgeProtocol.rateString(1.0), "+0%")
        XCTAssertEqual(EdgeProtocol.rateString(1.25), "+25%")
        XCTAssertEqual(EdgeProtocol.rateString(0.8), "-20%")
        XCTAssertEqual(EdgeProtocol.rateString(2.0), "+100%")
        XCTAssertEqual(EdgeProtocol.rateString(0.5), "-50%")
    }

    func test_EdgeProtocol_parseTextBinaryAndMetadata() throws {
        let text = EdgeProtocol.parseTextFrame("X-RequestId:1\r\nPath:audio.metadata\r\n\r\n{\"Metadata\":[{\"Type\":\"WordBoundary\",\"Data\":{\"Offset\":12500000,\"Duration\":3750000,\"text\":{\"Text\":\"Hello\",\"Length\":5}}},{\"Type\":\"SessionEnd\",\"Data\":{}}]}")
        XCTAssertEqual(text.path, "audio.metadata")
        let boundaries = EdgeProtocol.parseMetadata(text.body)
        XCTAssertEqual(boundaries.count, 2)
        XCTAssertEqual(boundaries[0].offsetSeconds, 1.25)
        XCTAssertEqual(boundaries[0].durationSeconds, 0.375)
        XCTAssertEqual(boundaries[0].text, "Hello")
        let header = "X-RequestId:1\r\nContent-Type:audio/mpeg\r\nPath:audio\r\n"
        var data = Data([0, UInt8(header.utf8.count)])
        data.append(Data(header.utf8))
        data.append(Data([1, 2, 3]))
        let binary = try EdgeProtocol.parseBinaryFrame(data)
        XCTAssertEqual(binary.path, "audio")
        XCTAssertEqual(binary.contentType, "audio/mpeg")
        XCTAssertEqual(binary.payload, Data([1, 2, 3]))
        XCTAssertThrowsError(try EdgeProtocol.parseBinaryFrame(Data([0, 200, 1])))
        var locator = EdgeProtocol.WordLocator(text: "Hello big world")
        XCTAssertEqual(String("Hello big world"[locator.locate("Hello")]), "Hello")
        XCTAssertEqual(String("Hello big world"[locator.locate("world")]), "world")
        var fallback = EdgeProtocol.WordLocator(text: "one two")
        XCTAssertEqual(String("one two"[fallback.locate("zzz")]), "one")
    }

    func test_EdgeVoiceList_parse_andBuiltIn() throws {
        let json = #"[{"Name":"Microsoft Server Speech Text to Speech Voice (en-US, GuyNeural)","ShortName":"en-US-GuyNeural","Gender":"Male","Locale":"en-US","FriendlyName":"Microsoft Guy Online (Natural) - English (United States)"},{"ShortName":"en-US-AvaMultilingualNeural","Gender":"Female","Locale":"en-US","FriendlyName":"Microsoft AvaMultilingual Online (Natural) - English (United States)"}]"#
        let voices = try EdgeVoiceList.parse(Data(json.utf8))
        XCTAssertEqual(voices[0].displayName, "Guy (en-US)")
        XCTAssertEqual(voices[0].gender, "Male")
        XCTAssertTrue(voices[1].displayName.hasSuffix("· multilingual"))
        XCTAssertFalse(EdgeVoiceList.builtIn.isEmpty)
    }

    func test_MP3StreamDecoder_garbageInput_throwsOrProducesNothing() {
        let decoder = MP3StreamDecoder()
        var produced = 0
        decoder.onPCM = { produced += $0.frameCount }
        do {
            try decoder.feed(Data(repeating: 0xAB, count: 4096))
            try decoder.flush()
        } catch {
            // acceptable: decode error
        }
        XCTAssertEqual(produced, 0)
    }

    func test_EdgeTTSBackend_wrongBackendVoice_rejected_andEmptyTextFinishes() async throws {
        let backend = EdgeTTSBackend()
        var events: [SynthesisEvent] = []
        do {
            for try await e in backend.synthesize(SynthesisRequest(text: "x", voice: Voice(backend: "apple", id: "v", displayName: "v", locale: "en-US"), rate: 1)) { events.append(e) }
            XCTFail("expected invalidVoice")
        } catch {
            XCTAssertEqual(error as? BackendError, .invalidVoice("v"))
        }
        for try await e in backend.synthesize(SynthesisRequest(text: "   ", voice: Voice(backend: "edge", id: "en-US-GuyNeural", displayName: "Guy", locale: "en-US"), rate: 1)) { events.append(e) }
        XCTAssertEqual(events.count, 1)
        if case .finished = events[0] {} else { XCTFail("expected finished") }
    }
}

final class EdgeLiveSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CLAUDIO_LIVE_TESTS"] == "1", "live tests disabled")
    }

    func test_EdgeLive_synthesizeShortSentence_producesAudioAndBoundaries() async throws {
        let backend = EdgeTTSBackend()
        var frames = 0
        var boundaries = 0
        var finished = false
        for try await event in backend.synthesize(SynthesisRequest(text: "Claudio live smoke test.", voice: Voice(backend: "edge", id: "en-US-GuyNeural", displayName: "Guy", locale: "en-US"), rate: 1)) {
            switch event {
            case .audio(let b): frames += b.frameCount
            case .wordBoundary: boundaries += 1
            case .finished: finished = true
            }
        }
        XCTAssertGreaterThan(frames, 12_000)
        XCTAssertGreaterThanOrEqual(boundaries, 3)
        XCTAssertTrue(finished)
        let voiceCount = try await backend.voices().count
        XCTAssertGreaterThan(voiceCount, 300)
    }
}
