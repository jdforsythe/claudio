# 06 — TTS Backends

`ClaudioBackends` contains every implementation of the `TTSBackend` protocol defined in `ClaudioCore/Backends/TTSBackend.swift`. The pipeline (doc 05) never knows which backend it is talking to. In production the pipeline holds a single `FallbackBackend` that wraps the user's primary choice (Edge by default) and `AppleSpeechBackend`.

```
Sources/ClaudioBackends/
├── Edge/
│   ├── EdgeTTSBackend.swift
│   ├── EdgeConstants.swift          # token, URLs, Chromium version, headers
│   ├── EdgeDRM.swift                # Sec-MS-GEC + clock skew
│   ├── EdgeProtocol.swift           # frame builders and parsers
│   ├── EdgeVoiceList.swift
│   └── MP3StreamDecoder.swift       # AudioFileStream + AudioConverter
├── Apple/
│   └── AppleSpeechBackend.swift
├── OpenAI/
│   ├── OpenAITTSBackend.swift
│   └── KeychainStore.swift
├── FallbackBackend.swift
├── VoiceCatalog.swift
└── PCMFormat.swift                  # canonical format + converters
```

## 1. The `TTSBackend` protocol contract

```swift
public typealias BackendID = String   // "edge", "apple", "openai"; lowercase, stable, used in settings and voice ids

public protocol TTSBackend: Sendable {
    var id: BackendID { get }
    var displayName: String { get }
    var supportsWordBoundaries: Bool { get }
    func voices() async throws -> [Voice]
    func synthesize(_ request: SynthesisRequest) -> AsyncThrowingStream<SynthesisEvent, Error>
}
```

Normative semantics every implementation satisfies, and `BackendConformanceTests` verifies against each:

1. **Buffer format.** Every `.audio` buffer is `PCMFormat.canonical`: Float32, 24 000 Hz, 1 channel, non-interleaved, `frameLength > 0`. Backends whose engine produces something else convert before yielding (`PCMFormat.converter(from:)` returns a cached `AVAudioConverter`).
2. **Granularity.** Buffers are 50–400 ms (1 200–9 600 frames). Smaller buffers waste scheduling calls; larger ones delay first audio.
3. **Ordering.** `.audio` events are in playback order. `.wordBoundary` events may arrive before, between or after audio events but always before `.finished`; their `audioOffset` is relative to the first sample of the request's audio.
4. **Termination.** Exactly one `.finished` is yielded on success, after the last `.audio`, and then the stream finishes. On failure the stream throws a `BackendError` and yields no `.finished`. A request that produces zero audio frames throws `.decode("no audio")`.
5. **Cancellation.** Cancelling the consuming `Task` stops network I/O, synthesis and conversion within 50 ms and finishes the stream (with `CancellationError`, which the scheduler treats as silence). Implementations use `AsyncThrowingStream`'s `onTermination` to tear down.
6. **Concurrency.** `synthesize` may be called concurrently up to `lookahead + 1` times. Backends that cannot synthesize in parallel (Apple) serialize internally and still honour cancellation of queued requests.
7. **Text.** `request.text` is plain speakable text ≤ 2 000 UTF-8 bytes with no markdown. Backends escape as their protocol needs. Empty or whitespace-only text yields `.finished` immediately with no audio and no error.
8. **Rate.** `request.rate` is a multiplier in 0.5…2.0, 1.0 = the voice's natural pace. Backends map it to their own parameter; mapping is monotonic and 1.0 maps to the engine default.
9. **Voices.** `voices()` is idempotent, cached by the backend for the process lifetime after the first success, and throws `.network` or `.auth` rather than returning an empty array on failure. A `Voice` whose `backend != id` is rejected by `synthesize` with `.invalidVoice`.
10. **No side effects on the audio device.** Backends never play audio themselves.

```swift
public enum BackendError: Error, Sendable, Equatable {
    case network(String)        // DNS, TCP, TLS, WebSocket transport failures
    case auth(String)           // 401/403 after any skew retry, missing API key
    case rateLimited(retryAfter: TimeInterval?)   // 429
    case invalidVoice(String)
    case timeout(stage: String) // "connect", "firstAudio", "idle"
    case decode(String)         // malformed frames, no audio, converter failure
    case unavailable(String)    // engine missing, no voices installed, feature disabled
}
```

`FinishedInfo` side channel: `.finished` carries no payload in the protocol, but `FallbackBackend` needs to tell the scheduler which backend actually spoke. It does so through `SynthesisEvent.finished` being followed by the stream ending, and by `FallbackBackend` exposing `lastUsedBackend(for requestID:)`. To keep the protocol minimal, `SynthesisRequest` carries an `id: UUID` the scheduler assigns, and `FallbackBackend.usage: AsyncStream<(requestID: UUID, backend: BackendID, fellBack: Bool)>` publishes the outcome. The scheduler joins on `requestID` for metrics.

Tests: `BackendConformanceTests` is a parameterized suite run against `MockBackend`, `AppleSpeechBackend` and `EdgeTTSBackend` (the latter against `EdgeMockServer`): `testCanonicalFormat`, `testBufferGranularity`, `testSingleFinishedAfterLastAudio`, `testEmptyTextFinishesWithoutAudio`, `testCancellationStopsWithin50ms`, `testWrongBackendVoiceRejected`, `testVoicesCached`, `testConcurrentRequestsIndependent`.

## 2. `EdgeTTSBackend`

A native Swift implementation of the protocol used by Microsoft Edge's "Read Aloud" feature, matching the behaviour of the Python `edge-tts` package version 7.2.8. It uses `URLSessionWebSocketTask` for transport, `AudioFileStream` + `AudioConverter` for MP3 decoding, and no third-party code.

### 2.1 Constants (`EdgeConstants.swift`)

```swift
enum EdgeConstants {
    static let trustedClientToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    static let baseHost = "speech.platform.bing.com"
    static let basePath = "/consumer/speech/synthesize/readaloud"
    static let wssURL   = "wss://\(baseHost)\(basePath)/edge/v1?TrustedClientToken=\(trustedClientToken)"
    static let voiceListURL = "https://\(baseHost)\(basePath)/voices/list?trustedclienttoken=\(trustedClientToken)"

    static let chromiumFullVersion = "143.0.3650.75"          // bump when Microsoft rejects it
    static var chromiumMajor: String { chromiumFullVersion.split(separator: ".").first.map(String.init)! }
    static var secMSGECVersion: String { "1-\(chromiumFullVersion)" }

    static var userAgent: String {
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) " +
        "Chrome/\(chromiumMajor).0.0.0 Safari/537.36 Edg/\(chromiumMajor).0.0.0"
    }
    static let origin = "chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold"
    static let outputFormat = "audio-24khz-48kbitrate-mono-mp3"   // 48 kbps CBR
    static let ticksPerSecond: Double = 10_000_000
    static let mp3BitrateBps: Double = 48_000
    static let maxRequestBytes = 4_096
}
```

WebSocket request headers, in this order:

| Header | Value |
|--------|-------|
| `Pragma` | `no-cache` |
| `Cache-Control` | `no-cache` |
| `Origin` | `chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold` |
| `User-Agent` | `EdgeConstants.userAgent` |
| `Accept-Encoding` | `gzip, deflate, br, zstd` |
| `Accept-Language` | `en-US,en;q=0.9` |
| `Cookie` | `muid=<32 uppercase hex chars, random per connection>;` |

`Sec-WebSocket-Version: 13` is added by `URLSession` itself. Voice-list request headers add `Authority: speech.platform.bing.com`, `Sec-CH-UA: " Not;A Brand";v="99", "Microsoft Edge";v="<major>", "Chromium";v="<major>"`, `Sec-CH-UA-Mobile: ?0`, `Accept: */*`, `Sec-Fetch-Site: none`, `Sec-Fetch-Mode: cors`, `Sec-Fetch-Dest: empty`.

### 2.2 `EdgeDRM` — the `Sec-MS-GEC` token

Microsoft rejects connections that lack a time-based proof. The value is a SHA-256 over the current time rounded to a 5-minute window plus the client token.

```swift
enum EdgeDRM {
    static let windowsEpochOffset: Double = 11_644_473_600   // seconds between 1601-01-01 and 1970-01-01
    static var clockSkewSeconds: Double = 0                   // adjusted on 403, see below

    static func secMSGEC(now: Date = Date()) -> String {
        var ticks = now.timeIntervalSince1970 + clockSkewSeconds   // unix seconds, skew-corrected
        ticks += windowsEpochOffset                                // Windows file time epoch
        ticks -= ticks.truncatingRemainder(dividingBy: 300)        // floor to 5-minute window
        ticks *= 10_000_000                                        // 100-ns intervals
        let s = String(format: "%.0f", ticks) + EdgeConstants.trustedClientToken
        return SHA256.hash(data: Data(s.utf8)).map { String(format: "%02X", $0) }.joined()
    }

    static func connectionID() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }  // 32 lowercase hex
    static func muid() -> String { (0..<16).map { _ in String(format: "%02X", UInt8.random(in: 0...255)) }.joined() }
}
```

**Clock skew correction.** If the WebSocket handshake fails with HTTP 403, the backend reads the response's `Date` header (RFC 2616, `EEE, dd MMM yyyy HH:mm:ss zzz`, parsed in UTC), sets `clockSkewSeconds = serverDate − clientNow`, regenerates the token and retries the connection **once**. A second 403 throws `.auth("Sec-MS-GEC rejected")`. The skew persists for the process lifetime. The `Date` header is read from `URLSessionWebSocketTask`'s failed handshake via the task's `response as? HTTPURLResponse` in the completion error path; if the header is missing, no retry is attempted and `.auth` is thrown immediately.

The full WebSocket URL for a connection:

```
wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1
  ?TrustedClientToken=6A5AA1D4EAFF4E9FB37E23D68491D6F4
  &ConnectionId=<EdgeDRM.connectionID()>
  &Sec-MS-GEC=<EdgeDRM.secMSGEC()>
  &Sec-MS-GEC-Version=1-143.0.3650.75
```

Tests: `EdgeDRMTests.testSecMSGECMatchesReference` (fixed date `2026-10-05T19:30:00Z`, skew 0, compares to the value produced by the Python reference and stored in the test), `testFiveMinuteWindowFloor` (two dates 4 minutes apart in the same window produce the same token; across the boundary they differ), `testSkewAppliedBeforeFloor`, `testDateHeaderParsing`.

### 2.3 Wire protocol (`EdgeProtocol.swift`)

All text frames are UTF-8 with `\r\n` line endings, a header block, a blank line, and a body.

**Timestamp format.** `X-Timestamp` values use a JavaScript `Date.toString()` style string in UTC, produced by a `DateFormatter` with `locale = en_US_POSIX`, `timeZone = UTC`, format `"EEE MMM dd yyyy HH:mm:ss 'GMT+0000 (Coordinated Universal Time)'"`. Example: `Mon Oct 05 2026 19:30:00 GMT+0000 (Coordinated Universal Time)`. On the SSML frame a literal `Z` is appended after the closing parenthesis; this reproduces a quirk of the Edge client and the server expects it.

**Frame 1 — `speech.config`** (sent once per connection, immediately after the handshake):

```
X-Timestamp:<timestamp>\r\n
Content-Type:application/json; charset=utf-8\r\n
Path:speech.config\r\n
\r\n
{"context":{"synthesis":{"audio":{"metadataoptions":{"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"true"},"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}\r\n
```

`wordBoundaryEnabled` is `"true"` when `request.wantsWordBoundaries` and `"false"` otherwise; `sentenceBoundaryEnabled` is always its inverse (the service accepts only one of the two).

**Frame 2 — `ssml`:**

```
X-RequestId:<32 hex, fresh per request>\r\n
Content-Type:application/ssml+xml\r\n
X-Timestamp:<timestamp>Z\r\n
Path:ssml\r\n
\r\n
<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'><voice name='<voice.id>'><prosody pitch='+0Hz' rate='<rate>' volume='+0%'><escaped text></prosody></voice></speak>
```

Text preparation before embedding: remove C0/C1 control characters except `\n` and `\t` (which become spaces), remove U+FFFE/U+FFFF, then XML-escape `&` `<` `>` `"` `'` as `&amp;` `&lt;` `&gt;` `&quot;` `&apos;`. The SSML body after escaping must be ≤ 4 096 bytes; Claudio's segments are ≤ 2 000 bytes of text, so one request always fits and the backend never splits. If a caller violates that (defensive path), the backend throws `.decode("text too long")` rather than silently truncating.

**Rate mapping.** `request.rate` (multiplier) → prosody `rate` string: `let pct = Int((rate − 1.0) * 100).rounded()`; string is `"+\(pct)%"` for `pct ≥ 0` and `"\(pct)%"` for negative (`"-20%"`). 1.0 → `+0%`, 1.25 → `+25%`, 0.8 → `-20%`. Pitch and volume are fixed at `+0Hz` / `+0%`.

**Received text frames.** Split at the first `\r\n\r\n`. Headers are `Key:Value` lines (no space after the colon). `Path` is one of:

| Path | Meaning | Handling |
|------|---------|----------|
| `turn.start` | Request accepted | Record `turnStartedAt` for metrics |
| `response` | Session metadata | Ignored |
| `audio.metadata` | Word boundary batch | Parse JSON body (below), yield `.wordBoundary` |
| `turn.end` | Request complete | Flush decoder, yield `.finished`, close socket |
| anything else | | Throw `.decode("unknown path <p>")` |

`audio.metadata` body:

```json
{"Metadata":[{"Type":"WordBoundary","Data":{"Offset":12500000,"Duration":3750000,"text":{"Text":"Hello","Length":5,"BoundaryType":"WordBoundary"}}}]}
```

`Offset` and `Duration` are in 100-nanosecond ticks; seconds = ticks / 10 000 000. `Type` may also be `SentenceBoundary` (yielded as a word boundary spanning the sentence when sentence mode is on) or `SessionEnd` (ignored). The text range is located by searching `request.text` for `Text` starting at the end of the previous boundary's range (the service returns words in order; HTML-unescape `Text` first). If the word cannot be found (service normalized it), the boundary is yielded with the range of the next whitespace-delimited token, which keeps highlighting roughly aligned.

**Received binary frames.** Layout: 2 bytes big-endian `headerLength`, then `headerLength` bytes of `\r\n`-separated headers, then the payload.

| Condition | Handling |
|-----------|----------|
| `count < 2` or `headerLength > count − 2` | throw `.decode("malformed binary frame")` |
| `Path` ≠ `audio` | throw `.decode("binary frame with path <p>")` |
| `Content-Type` = `audio/mpeg` and payload non-empty | feed payload to `MP3StreamDecoder` |
| no `Content-Type`, payload empty | expected trailer; ignore |
| no `Content-Type`, payload non-empty | throw `.decode("audio without content type")` |

If `turn.end` arrives and the decoder has produced zero PCM frames, throw `.decode("no audio received")`.

### 2.4 `MP3StreamDecoder`

The service sends a 48 kbps CBR MP3 stream in arbitrary-sized pieces. Decoding is incremental so the first PCM buffer is yielded before the stream has finished.

1. `AudioFileStreamOpen(…, kAudioFileMP3Type, &streamID)` with a property-listener and a packets callback.
2. Each payload goes to `AudioFileStreamParseBytes(streamID, count, bytes, [])`. The first call(s) parse the header; when `kAudioFileStreamProperty_ReadyToProducePackets` fires, the decoder reads `kAudioFileStreamProperty_DataFormat` (expect MPEG Layer 3, 24 000 Hz, 1 channel) and creates `AudioConverterNew(&inFormat, &PCMFormat.canonicalASBD, &converter)`.
3. The packets callback receives `(numBytes, numPackets, data, packetDescriptions)`. Packets are appended to a small FIFO; the decoder calls `AudioConverterFillComplexBuffer` with an input proc that drains the FIFO, requesting 4 800 frames (200 ms) at a time, and yields an `AVAudioPCMBuffer` for each filled block. The MP3 decoder's priming (576 frames) is handled by the converter via `kAudioConverterPrimeInfo`.
4. On `turn.end`, `flush()` calls `AudioConverterFillComplexBuffer` until it returns fewer frames than requested, yields the remainder (possibly < 4 800 frames), then `AudioConverterDispose` and `AudioFileStreamClose`.
5. Any non-zero `OSStatus` → `.decode("AudioFileStream/AudioConverter <status>")`.

Tests: `MP3StreamDecoderTests.testDecodesFixtureToExpectedFrameCount` (a 2 s fixture MP3 at 48 kbps decodes to 48 000 ± 1 152 frames), `testIncrementalFeedingYieldsEarly` (first buffer yielded after < 6 KB of input), `testGarbageInputThrowsDecode`.

### 2.5 Connection policy and timeouts

- **One WebSocket per request.** The service closes the socket after `turn.end` in practice, and reusing a connection across requests is not reliable. Handshake cost (TCP + TLS + WS upgrade) is 150–300 ms warm; the scheduler's lookahead hides it for every segment except the first of an answer.
- **Warm-up.** `EdgeTTSBackend.warmUp()` is called at app start, when the backend becomes primary, and after 10 minutes of inactivity. It opens a connection, sends `speech.config`, and closes. This primes DNS and the TLS session cache so the first real request saves ~100 ms.
- **Timeouts.** Connect (handshake) 5 s → `.timeout(stage: "connect")`. First audio frame 3 s after the SSML frame is sent → `.timeout(stage: "firstAudio")` (this is the trigger `FallbackBackend` acts on). Idle 10 s between frames → `.timeout(stage: "idle")`.
- **Error mapping.** Handshake HTTP 403 → skew retry once → `.auth`. 429 → `.rateLimited(retryAfter: Retry-After header or nil)`. Other non-101 statuses → `.network("HTTP <code>")`. WebSocket close with code ≠ 1000 before `turn.end` → `.network("ws close <code>")`. `URLError` → `.network(desc)`. Malformed frames → `.decode`.
- **Cancellation.** `onTermination` calls `task.cancel(with: .goingAway, reason: nil)` and `decoder.abort()`.
- **Proxy.** `URLSession` honours system proxy settings; nothing custom.

### 2.6 Voice list (`EdgeVoiceList.swift`)

`GET EdgeConstants.voiceListURL` with the voice headers. Response is a JSON array:

```json
[{"Name":"Microsoft Server Speech Text to Speech Voice (en-US, GuyNeural)","ShortName":"en-US-GuyNeural","Gender":"Male","Locale":"en-US","SuggestedCodec":"audio-24khz-48kbitrate-mono-mp3","FriendlyName":"Microsoft Guy Online (Natural) - English (United States)","Status":"GA","VoiceTag":{"ContentCategories":["News","Novel"],"VoicePersonalities":["Passion"]}}, …]
```

Mapping to `Voice`: `id = ShortName`, `displayName` = the name between `Microsoft ` and ` Online` in `FriendlyName` plus the locale in parentheses ("Guy (en-US)"), `locale = Locale`, `gender = Gender`, `quality = nil`. Multilingual voices (`ShortName` containing `Multilingual`) are tagged in `displayName` with " · multilingual". The list is cached by `VoiceCatalog` for 24 h; the default voice when nothing is configured is `en-US-GuyNeural`, the voice the user already chose with claude-speak.

### 2.7 Maintenance

This is a reimplementation of an unofficial protocol. Breakage history: Microsoft began enforcing `Sec-MS-GEC` in late 2024 and tightened it in December 2025; both times the fix was in the token computation or the Chromium version string. Everything that has ever changed lives in `EdgeConstants.swift` and `EdgeDRM.swift`. When the live smoke test (`EdgeLiveTests.testSynthesizeHello`, run only when `CLAUDIO_LIVE_TESTS=1`) fails with `.auth`, the first thing to try is updating `chromiumFullVersion` to the current stable Edge version; the second is comparing `EdgeDRM.secMSGEC` against the latest `edge-tts` `drm.py`. The app itself surfaces the condition as "Edge voices unavailable, using Apple voice" and continues working.

Tests: `EdgeProtocolTests.testSpeechConfigFrame`, `testSSMLFrameExactBytes` (golden bytes for a fixed timestamp, request id, voice and text), `testXMLEscaping`, `testControlCharactersRemoved`, `testRateMapping` (1.0→`+0%`, 1.25→`+25%`, 0.8→`-20%`, 2.0→`+100%`, 0.5→`-50%`), `testTimestampFormat`, `testParseTextFrame`, `testParseMetadata`, `testParseBinaryFrame`, `testBinaryTrailerIgnored`, `testUnknownPathThrows`. `EdgeTTSBackendTests` against `EdgeMockServer` (an in-process WebSocket server built on `Network.framework` that speaks the protocol above and serves a fixture MP3): `testHappyPathYieldsAudioThenFinished`, `testWordBoundariesConvertedToSeconds`, `testWordBoundaryRangesLocated`, `testNoAudioThrowsDecode`, `test403ThenSuccessAfterSkewRetry`, `test403TwiceThrowsAuth`, `test429ThrowsRateLimited`, `testFirstAudioTimeout`, `testCancellationClosesSocket`, `testHeadersAndQuerySentExactly`.

## 3. `AppleSpeechBackend`

Wraps `AVSpeechSynthesizer` in write-to-buffer mode. Always available, offline, instant. Quality depends on which voices the user has downloaded.

### 3.1 Synthesis

```swift
let utterance = AVSpeechUtterance(string: request.text)
utterance.voice = AVSpeechSynthesisVoice(identifier: request.voice.id)
utterance.rate  = appleRate(from: request.rate)
utterance.prefersAssistiveTechnologySettings = false
synthesizer.write(utterance) { buffer in … }
```

`write(_:toBufferCallback:)` delivers `AVAudioBuffer`s on an internal queue. Each is cast to `AVAudioPCMBuffer`; a buffer with `frameLength == 0` marks the end of the utterance. The synthesizer's native format varies by voice (22 050 Hz or 24 000 Hz, Int16 or Float32, mono); every buffer is converted with the cached `AVAudioConverter` to the canonical format and yielded. Buffers smaller than 1 200 frames are coalesced before yielding to respect the granularity contract.

**One synthesizer, one utterance at a time.** `AVSpeechSynthesizer` cannot write two utterances concurrently. The backend keeps a single synthesizer and an internal `AsyncSerialQueue`; concurrent `synthesize` calls are queued and each waits for the previous to finish or be cancelled. Cancellation of a queued request removes it from the queue; cancellation of the active request calls `synthesizer.stopSpeaking(at: .immediate)`, which ends the buffer callbacks with the zero-length buffer.

**Rate mapping.** `AVSpeechUtterance.rate` is 0.0…1.0 with `AVSpeechUtteranceDefaultSpeechRate = 0.5`, `Minimum = 0.0`, `Maximum = 1.0`; the perceived speed is roughly linear in rate around the default. Mapping: `appleRate(m) = clamp(0.5 * m, 0.1, 0.9)` for `m ≤ 1.0`, and `appleRate(m) = clamp(0.5 + (m − 1.0) * 0.2, 0.5, 0.9)` for `m > 1.0`. So 1.0 → 0.5, 1.25 → 0.55, 1.5 → 0.6, 2.0 → 0.7, 0.8 → 0.4. The compression above 1.0 matches the engine's non-linear response measured on Premium voices (rate 0.7 is already ≈ 2× words per minute).

### 3.2 Word boundaries

`AVSpeechSynthesizerDelegate.speechSynthesizer(_:willSpeakRangeOfSpeechString:utterance:)` is implemented and fires during `write` on macOS 15 and later for Premium, Enhanced and default voices, with ranges in `utterance.speechString`. The delegate callback carries no audio offset, so the backend timestamps each callback against the number of frames written so far: `audioOffset = framesYieldedSoFar / 24_000`. Because the synthesizer produces audio slightly ahead of the callback for the corresponding words, the offset is biased late by up to ~100 ms; the HUD's highlight is therefore within a word of the truth, which is acceptable. `supportsWordBoundaries` is `true`. If, for a given voice, no delegate callback arrives before the end buffer, the backend yields no boundaries and the scheduler's approximation (doc 05 §9) takes over; this is logged once per voice at `.notice`.

Test `AppleSpeechBackendTests.testWordBoundariesFireDuringWrite` records whether the installed system delivers boundaries for the default voice; it asserts only that **either** boundaries arrive **or** none do and the stream still finishes, and prints which, so the behaviour of the current OS is visible in CI output.

### 3.3 Voice selection and quality

`voices()` maps `AVSpeechSynthesisVoice.speechVoices()` to `Voice(backend: "apple", id: voice.identifier, displayName: voice.name + qualitySuffix, locale: voice.language, gender: gender(from: voice.gender), quality: "premium" | "enhanced" | nil)`. Quality comes from `voice.quality` (`.premium`, `.enhanced`, `.default`). Voices whose identifier contains `com.apple.eloquence` or `com.apple.speech.synthesis.voice` (the legacy robotic voices) are listed but sorted last. Siri voices are not returned by the API and therefore cannot appear.

Default voice (when the user has not chosen one, or as the fallback for Edge): the highest-quality installed voice for the user's locale, ranked premium > enhanced > default, ties broken alphabetically; if nothing matches the user's locale, the same ranking over `en-US`. `AppleSpeechBackend.hasHighQualityVoice: Bool` is `true` when any installed voice has quality premium or enhanced. When it is `false`, the settings window shows the hint "For better Apple voices, download a Premium voice in System Settings → Accessibility → Spoken Content → System Voice → Manage Voices, then relaunch Claudio" (relaunch because `speechVoices()` caches the list for the process). The CLI equivalent is `claudio voices --apple`, which prints the same hint.

### 3.4 Errors

`AVSpeechSynthesizer` reports almost nothing. The backend throws `.invalidVoice` if `AVSpeechSynthesisVoice(identifier:)` returns nil, `.decode("converter")` on conversion failure, `.decode("no audio")` if the end buffer arrives with zero frames yielded, and `.timeout(stage: "firstAudio")` if no buffer arrives within 3 s (observed only when the system speech daemon is restarting). On any error the synthesizer is recreated for the next request.

Tests: `AppleSpeechBackendTests.testSynthesizesDefaultVoice`, `testConvertsToCanonicalFormat`, `testRateMapping`, `testSerializesConcurrentRequests`, `testCancellationStopsSpeaking`, `testQualityRanking`, `testHasHighQualityVoiceReflectsInstalledVoices`, `testWordBoundariesFireDuringWrite`.

## 4. `OpenAITTSBackend`

```
POST https://api.openai.com/v1/audio/speech
Authorization: Bearer <key>
Content-Type: application/json

{"model":"gpt-4o-mini-tts","voice":"<voice.id>","input":"<text>","response_format":"pcm","speed":<rate>}
```

- `response_format: pcm` returns raw 24 000 Hz, 16-bit signed little-endian, mono PCM with no header. The body is streamed with `URLSession.shared.bytes(for:)`; bytes are accumulated into 9 600-byte blocks (4 800 frames, 200 ms), converted Int16 → Float32 (`/ 32768`) directly into a canonical `AVAudioPCMBuffer`, and yielded. An odd trailing byte at the end of the body is dropped.
- `speed` accepts 0.25…4.0 and maps 1:1 from `request.rate`.
- `voice.id` is one of the OpenAI voice names (`alloy`, `ash`, `ballad`, `coral`, `echo`, `fable`, `nova`, `onyx`, `sage`, `shimmer`, `verse`); `voices()` returns this fixed list with `locale: "en-US"` (the voices are multilingual) and `quality: nil`. The model name is a setting (`AppSettings.openAI.model`) so a newer model can be used without a code change.
- `supportsWordBoundaries` is `false`; the scheduler approximates.
- The API key is read from the Keychain (`KeychainStore.read(service: "com.jdforsythe.claudio", account: "openai")`) at request time, never cached in memory longer than the request. A missing key throws `.auth("no API key")` and the settings UI shows the backend as "not configured".
- Error mapping: 401/403 → `.auth`, 429 → `.rateLimited(retryAfter:)`, 400 with `invalid_value` on `voice` → `.invalidVoice`, other 4xx/5xx → `.network("HTTP <code>: <error.message>")`, `URLError.timedOut` → `.timeout("connect")`, body shorter than 2 bytes → `.decode("no audio")`.
- Timeouts: `URLRequest.timeoutInterval = 15` for the whole request; first audio 3 s is enforced by the backend's own timer for the fallback race.

Tests (against a local `URLProtocol` stub): `OpenAITTSBackendTests.testRequestBodyExact`, `testPCMConversion`, `testStreamingYieldsBeforeBodyEnds`, `testOddTrailingByteDropped`, `testMissingKeyThrowsAuth`, `test429ParsesRetryAfter`, `testCancellationCancelsTask`.

## 5. `FallbackBackend`

```swift
public final class FallbackBackend: TTSBackend, Sendable {
    public init(primary: any TTSBackend, fallback: AppleSpeechBackend,
                firstAudioTimeout: TimeInterval = 3.0, clock: any Clock = SystemClock())
    public var id: BackendID { primary.id }          // reports as the primary for settings purposes
    public var supportsWordBoundaries: Bool { true } // both wrapped backends support them
    public let usage: AsyncStream<FallbackUsage>
    public let notices: AsyncStream<BackendNotice>
    public var fallbackOnly: any TTSBackend { fallback }
}
public struct FallbackUsage: Sendable { let requestID: UUID; let backend: BackendID; let fellBack: Bool; let reason: BackendError? }
public struct BackendNotice: Sendable, Equatable { let text: String; let at: Date }   // "Edge voices unavailable, using Apple voice"
```

Algorithm for `synthesize(request)`:

1. Start the primary's stream in a child task. Start a `firstAudioTimeout` timer.
2. Buffer primary events until the first `.audio` arrives. When it does: cancel the timer, replay buffered events to the consumer, then pass through everything else live. Emit `FallbackUsage(fellBack: false)` on `.finished`.
3. If the primary throws **before** the first audio, or the timer fires first: cancel the primary task, log `.notice` `fallback request=<id> reason=<error|timeout>`, and run `fallback.synthesize(request')` where `request'` is the same request with `voice` replaced by the paired Apple voice (`VoiceCatalog.fallbackVoice(for: request.voice)`). Pass its events through. Emit `FallbackUsage(fellBack: true, reason:)`.
4. If the primary throws **after** audio has started (mid-stream network drop), the request fails with that error; the scheduler's retry (doc 05 §6.3) then uses `fallbackOnly` for the segment. Restarting the fallback mid-segment would repeat already-played words.
5. If the fallback also throws, rethrow the fallback's error with the primary's error attached as `underlying` in the log line.

**Notice policy.** The first `fellBack: true` after at least 60 minutes without one emits a `BackendNotice`. The HUD shows it for 6 s. Subsequent fallbacks within the hour are silent: the user hears the Apple voice and knows what it means.

**Retry policy.** Every request tries the primary first. There is no circuit breaker: when Edge is down, each segment costs one failed handshake (≤ 3 s, overlapped by lookahead so playback does not starve after the first segment) and then succeeds on Apple. This keeps the recovery automatic: the moment Edge works again, the next segment uses it. The cost of a permanent outage is ~3 s of extra latency on the first segment of each answer, which the one-time notice explains.

Tests: `FallbackBackendTests.testPrimarySucceedsNoFallback`, `testPrimaryErrorBeforeAudioFallsBack`, `testFirstAudioTimeoutFallsBack`, `testPrimaryErrorAfterAudioRethrows`, `testFallbackVoicePairing`, `testNoticeOncePerHour`, `testUsageStreamReportsBackend`, `testBothFailRethrowsFallbackError`.

## 6. `VoiceCatalog`

`VoiceCatalog` is the single place the UI, CLI and `FallbackBackend` ask about voices.

```swift
public actor VoiceCatalog {
    public init(backends: [any TTSBackend], cacheDirectory: URL, clock: any Clock)
    public func voices(for backend: BackendID, forceRefresh: Bool = false) async throws -> [Voice]
    public func allVoices() async -> [BackendID: Result<[Voice], BackendError>]
    public func voice(id: String, backend: BackendID) async -> Voice?
    public func fallbackVoice(for primary: Voice) async -> Voice
    public func previewVoice(_ voice: Voice) async       // enqueues the preview cue through SpeechPipeline
}
```

- **Caching.** Each backend's list is written to `~/Library/Application Support/Claudio/voices-<backend>.json` with a `fetchedAt`. Lists younger than 24 h are served from disk without a network call; stale lists are served immediately and refreshed in the background; a failed refresh keeps the stale list and logs `.notice`. Apple's list is never cached to disk (it is instant and changes when the user installs voices).
- **Fallback pairing.** `fallbackVoice(for:)` picks the Apple voice with the same language code, same gender where known, highest quality; ties → the voice named in `AppSettings.fallbackVoiceID` if set, else alphabetical. The user may override the pairing in settings; the override is stored per primary voice id. For `en-US-GuyNeural` on a machine with "Evan (Premium)" installed, the pair is Evan; with no Premium voices it is "Tom" or whichever default male en-US voice exists.
- **Preview.** `previewVoice` builds a temporary `FallbackBackend`-free request directly against the voice's backend and plays the preview cue text (doc 05 §10) through the pipeline as an `event` item, so it respects pause and can be cancelled. A preview never changes the configured voice.

Tests: `VoiceCatalogTests.testDiskCacheHonoursTTL`, `testStaleServedThenRefreshed`, `testRefreshFailureKeepsStale`, `testFallbackPairingPrefersSameLanguageGenderQuality`, `testFallbackOverrideRespected`.

## 7. Adding a backend

Worked example: a local Kokoro model served by an `mlx-audio` sidecar exposing an OpenAI-compatible `/v1/audio/speech`.

1. Create `Sources/ClaudioBackends/Kokoro/KokoroSidecarBackend.swift` conforming to `TTSBackend` with `id = "kokoro"`.
2. Transport: reuse `OpenAITTSBackend`'s request/streaming code by extracting it into `OpenAICompatibleSpeechClient(baseURL:apiKey:)`; Kokoro's base URL is `http://127.0.0.1:<port>`, key nil.
3. Format: the sidecar returns 24 kHz PCM when asked with `response_format: pcm`; if a sidecar returns WAV, strip the 44-byte header, and if it returns another rate, run `PCMFormat.converter`.
4. Voices: `GET /v1/audio/voices` (mlx-audio) or a static list; `locale` from the voice id prefix (`af_heart` → `en-US`).
5. Lifecycle: a backend that needs a process implements the optional `BackendLifecycle` protocol (`start()`, `stop()`, `health() async -> Bool`); the composition root calls `start()` when the backend becomes primary and `stop()` when it is deselected or the app quits. The sidecar is launched with `Process` from a user-configured path; Claudio does not bundle it.
6. Register in `BackendRegistry.all` in `ClaudioApp.swift`, add a settings pane case, and add the backend to the `BackendConformanceTests` parameter list.
7. Word boundaries: return `supportsWordBoundaries = false` unless the sidecar provides timestamps; the scheduler approximates.

Nothing in `ClaudioCore` changes.

## 8. Test index

`ClaudioBackendsTests`:

- `BackendConformanceTests` (parameterized over `MockBackend`, `AppleSpeechBackend`, `EdgeTTSBackend`+`EdgeMockServer`, `OpenAITTSBackend`+stub): the eight tests in §1.
- `EdgeDRMTests`: `testSecMSGECMatchesReference`, `testFiveMinuteWindowFloor`, `testSkewAppliedBeforeFloor`, `testDateHeaderParsing`, `testConnectionIDFormat`, `testMUIDFormat`.
- `EdgeProtocolTests`: `testSpeechConfigFrame`, `testSSMLFrameExactBytes`, `testXMLEscaping`, `testControlCharactersRemoved`, `testTextTooLongThrows`, `testRateMapping`, `testTimestampFormat`, `testParseTextFrame`, `testParseMetadata`, `testMetadataSessionEndIgnored`, `testParseBinaryFrame`, `testBinaryTrailerIgnored`, `testUnknownPathThrows`, `testMalformedBinaryThrows`.
- `MP3StreamDecoderTests`: `testDecodesFixtureToExpectedFrameCount`, `testIncrementalFeedingYieldsEarly`, `testGarbageInputThrowsDecode`, `testFlushYieldsRemainder`.
- `EdgeTTSBackendTests` (mock server): `testHappyPathYieldsAudioThenFinished`, `testWordBoundariesConvertedToSeconds`, `testWordBoundaryRangesLocated`, `testNoAudioThrowsDecode`, `test403ThenSuccessAfterSkewRetry`, `test403TwiceThrowsAuth`, `test429ThrowsRateLimited`, `testFirstAudioTimeout`, `testIdleTimeout`, `testCancellationClosesSocket`, `testHeadersAndQuerySentExactly`, `testWarmUpOpensAndCloses`.
- `EdgeVoiceListTests`: `testParsesFixtureList`, `testDisplayNameDerivation`, `testMultilingualTag`.
- `EdgeLiveTests` (skipped unless `CLAUDIO_LIVE_TESTS=1`): `testSynthesizeHello`, `testVoiceListReachable`. These are the canary for protocol breakage.
- `AppleSpeechBackendTests`: the list in §3.4.
- `OpenAITTSBackendTests`: the list in §4.
- `FallbackBackendTests`: the list in §5.
- `VoiceCatalogTests`: the list in §6.
- `PCMFormatTests`: `testCanonicalFormat`, `testInt16ToFloat32`, `testConverterCachedPerSourceFormat`.

Fixtures under `Tests/Fixtures/backends/`: `edge-voices.json` (captured voice list), `edge-session.frames` (a recorded sequence of text and binary frames for "Hello world." with word boundaries, replayed by `EdgeMockServer`), `hello-48k.mp3` (2 s CBR MP3), `openai-pcm-hello.raw`.
