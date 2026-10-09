# 05 — Speech Pipeline

The speech pipeline turns `SpeechItem`s into audio. It lives in `Sources/ClaudioCore/Speech/` and has no dependency on AppKit, SwiftUI or any specific TTS backend. Every stage is a pure function or an actor with an injectable clock, so the whole pipeline runs under test against `RecordingPlaybackSink` and `MockBackend` with no audio device.

```
SpeechItem ─▶ ContentFilter ─▶ SpeechTextRenderer ─▶ SentenceSegmenter ─▶ Utterance
                                                                             │
                                             SynthesisScheduler ◀────────────┘
                                                │        │
                                       TTSBackend     PlaybackSink (PlaybackEngine)
                                                         │
                                                  PlaybackEvent ─▶ captions, HUD, metrics
```

## 1. `SpeechPipeline`

`SpeechPipeline` is the façade the `Arbiter` talks to. It owns one `SynthesisScheduler`, one `PlaybackSink`, one `SpeechTextRenderer`, one `SentenceSegmenter` and a reference to the current `TTSBackend` (always a `FallbackBackend` in production).

```swift
public actor SpeechPipeline {
    public init(backend: any TTSBackend,
                sink: any PlaybackSink,
                settings: AppSettings,
                clock: any Clock = SystemClock())

    // Input
    public func enqueue(_ item: SpeechItem) async          // filter → render → segment → schedule
    public func enqueue(_ utterance: Utterance) async      // pre-rendered (cues, previews)
    public func enqueueChime(_ chime: Chime) async         // bundled sound, see §10

    // Control
    public func cancelAll(reason: CancelReason) async      // drops every segment of every session
    public func cancelSession(_ id: SessionID, reason: CancelReason) async
    public func dropCategories(_ categories: Set<ContentCategory>, in session: SessionID) async
    public func skipSegment() async                        // current segment only
    public func pause() async
    public func resume() async
    public func setRate(_ multiplier: Double) async        // 0.5...2.0, live
    public func setBackend(_ backend: any TTSBackend) async

    // Published state (AsyncStream, consumed on the main actor by view models)
    public nonisolated let state: AsyncStream<PipelineState>
}

public struct PipelineState: Sendable, Equatable {
    public var mode: Mode                     // .idle, .speaking, .paused
    public var currentSegment: Utterance.Segment?
    public var currentItem: SpeechItem?
    public var currentWordRange: Range<String.Index>?   // within currentSegment.text
    public var queuedSegments: Int
    public var queuedSeconds: Double          // synthesized audio waiting, in seconds
    public enum Mode: Sendable { case idle, speaking, paused }
}

public enum CancelReason: String, Sendable {
    case userPrompt, sessionSwitch, levelDowngrade, userCancel, shutdown, skipToLive
}
```

Ordering guarantee: segments play in the order their items were enqueued, within and across sessions. The `Arbiter` enforces that only one session's non-event items are enqueued at a time; the pipeline does not know about "active session", it only knows session ids on items so `cancelSession` and `dropCategories` can target them.

`PipelineState` is emitted on every transition (segment start/finish, word boundary, pause, queue change). Word-boundary updates are coalesced to at most 60 per second.

## 2. `ContentFilter`

`ContentFilter` decides whether a `SpeechItem` is spoken at all for its session's current `SpeechLevel`.

```swift
public struct ContentFilter: Sendable {
    public var speakThinking: Bool      // AppSettings.advanced.speakThinking, default false
    public var speakToolResults: Bool   // AppSettings.advanced.speakToolResults, default false
    public var eventsEnabled: Bool      // AppSettings.events.enabled, default true

    public func includes(_ category: ContentCategory, at level: SpeechLevel) -> Bool
}
```

Truth table (✓ spoken, ✗ dropped, ⚙ spoken only when the matching advanced toggle is on):

| Category      | `quiet` | `answers` | `narrate` |
|---------------|---------|-----------|-----------|
| `event`       | ✓*      | ✓*        | ✓*        |
| `finalAnswer` | ✗       | ✓         | ✓         |
| `narration`   | ✗       | ✗         | ✓         |
| `toolCall`    | ✗       | ✗         | ✓         |
| `toolResult`  | ✗       | ✗         | ⚙ `speakToolResults` |
| `thinking`    | ✗       | ✗         | ⚙ `speakThinking` |

\* `event` items are dropped when `eventsEnabled` is false, except items with `SpeechItem.text` beginning with the catch-up cue marker (see §10), which are always spoken because they are the user's own navigation feedback.

Catch-up items (`isCatchUp == true`) bypass the level: the `CatchUpPlan` only ever emits `finalAnswer` items, and they are spoken regardless of the session's level, including `quiet`. This is deliberate: a user who switches to a quiet session asked to hear it.

**Level downgrade.** When the `Arbiter` lowers a session's level it calls `dropCategories(excluded, in: session)` with the set of categories newly excluded. The scheduler removes every segment of those categories in states `pending`, `synthesizing` or `ready`. The segment currently `playing` is allowed to finish, because cutting a sentence mid-word to honour a settings change is more jarring than hearing one extra sentence. Logged at `.info`: `filter.dropped count=<n> session=<id> categories=<list>`.

Tests: `ContentFilterTests.testTruthTable` (iterates every level × category × toggle combination against a literal expected table), `ContentFilterTests.testCatchUpBypassesLevel`, `SpeechPipelineTests.testLevelDowngradeDropsQueuedButNotPlaying`.

## 3. `ToolCallSummarizer`

`ToolCallSummarizer` turns a `tool_use` block into the short phrase spoken at `narrate` level. It is a pure function of the tool name and input dictionary.

```swift
public struct ToolCallSummarizer: Sendable {
    public func summarize(toolName: String, input: [String: Any]) -> String?   // nil = do not speak
}
```

| Tool name | Input fields read | Output | Example |
|-----------|-------------------|--------|---------|
| `Bash` | `command`, `description` | `description` if present and ≤ 12 words, else "Running: " + first 8 words of `command` with flags (`-x`, `--xx`) removed | `git status --short` → "Running: git status" |
| `Read` | `file_path` | "Reading " + last path component | "Reading Parser.swift" |
| `Edit` | `file_path` | "Editing " + last component | "Editing Parser.swift" |
| `Write` | `file_path` | "Writing " + last component | "Writing README.md" |
| `NotebookEdit` | `notebook_path` | "Editing " + last component | |
| `Grep` | `pattern` | "Searching for " + pattern, with regex metacharacters removed, max 6 words | `func\s+tail` → "Searching for func tail" |
| `Glob` | `pattern` | "Finding " + pattern | "Finding star dot swift" is avoided: the glob is rendered through inline-code cleanup, so `**/*.swift` → "swift files" via the glob rule in §4 |
| `Agent`, `Task` | `description`, `subagent_type` | "Agent started: " + description | "Agent started: analyze source" |
| `Skill` | `skill` | "Using skill " + skill name with hyphens → spaces | "Using skill grill me" |
| `WebFetch` | `url` | "Fetching " + host without `www.` | "Fetching code.claude.com" |
| `WebSearch` | `query` | "Searching the web for " + first 6 words of query | |
| `TodoWrite`, `TaskCreate`, `TaskUpdate` | — | "Updating tasks" | |
| `AskUserQuestion` | — | "Asking a question" (also triggers status `waiting`, see doc 03) | |
| `EnterPlanMode`, `ExitPlanMode` | — | "Entering plan mode" / "Leaving plan mode" | |
| `mcp__<server>__<tool>` | — | "Calling " + server + " " + tool, underscores → spaces, `claude_ai_` prefix dropped | `mcp__claude_ai_Asana__get_task` → "Calling Asana get task" |
| anything else | — | "Using " + tool name, camelCase split | "Using Monitor" |
| `ToolSearch`, `ListAgents`, `Monitor` (polling) | — | nil (never spoken; noise) | |

Post-processing applied to every output:

1. Truncate to 12 words; append nothing (no "and more").
2. Collapse whitespace; strip trailing punctuation; append a period so the segmenter treats it as a sentence.
3. **Consecutive dedupe:** if the previous summary for the same session was identical and emitted less than 5 s ago, return nil. Three `Read` calls on three different files produce three summaries; three `Grep` calls with the same pattern produce one.

Subagent events from doc 03 ("Agent finished: <description>") are produced by `TurnAssembler`, not by this type, but use the same 12-word cap.

Tests: `ToolCallSummarizerTests.testBashUsesDescriptionWhenShort`, `testBashStripsFlags`, `testReadUsesFilename`, `testMCPNaming`, `testUnknownToolSplitsCamelCase`, `testConsecutiveDedupeWithin5s`, `testDedupeExpiresAfter5s`, `testSilentTools`.

## 4. `SpeechTextRenderer` and `MarkdownSpeechRules`

`SpeechTextRenderer` converts the markdown Claude writes into an `Utterance` of pre-typed segments. It does not use a full CommonMark parser; it is a staged line-oriented rewriter, because Claude's markdown is regular, a full AST adds a dependency, and the failure mode of a rewriter (a stray symbol gets spoken) is acceptable while the failure mode of a strict parser (an exception drops the sentence) is not.

```swift
public struct SpeechTextRenderer: Sendable {
    public init(rules: MarkdownSpeechRules = .standard, segmenter: SentenceSegmenter = .init())
    public func render(_ item: SpeechItem) -> Utterance
}
```

`render` never throws. If any stage throws internally (a regex failure on a pathological input), the renderer logs at `.error` with the stage name and falls back to `Utterance(item:, segments: segmenter.segment(item.text, kind: .sentence))` on the raw text. **Fail toward speech.**

### 4.1 Stages

The input is `item.text`. Stages run in this order; each produces a list of `Block`s (`.prose(String)`, `.segment(Segment)`) that later stages refine.

1. **Normalize.** `\r\n` and `\r` → `\n`. Strip ANSI escapes (`\u{1B}\[[0-9;?]*[ -/]*[@-~]`). Remove BOM and zero-width characters (U+200B–U+200D, U+FEFF).
2. **Fenced code.** Lines matching ``^\s*(`{3,}|~{3,})\s*([A-Za-z0-9_+-]*)`` open a fence; the fence closes at the next line whose content is the same fence string. The whole block becomes one `Segment(kind: .cue, text: "<lang> code block.")`, where `<lang>` is the info string mapped through a pronunciation table (`js` → "JavaScript", `ts` → "TypeScript", `py` → "Python", `sh`/`bash`/`zsh` → "shell", `swift` → "Swift", `json` → "JSON", `yaml`/`yml` → "YAML", `md` → "markdown", unknown → spoken as written). No info string → "code block.". An unterminated fence runs to end of text.
3. **Indented code.** Four-or-more-space (or tab) indented lines that are not inside a list item and follow a blank line form an indented code block → `Segment(kind: .cue, text: "code block.")`. Inside lists, indentation is list continuation and is left alone.
4. **Tables.** A GFM pipe table is a header line containing `|`, followed by a separator line matching `^\s*\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)*\|?\s*$`, followed by zero or more body lines containing `|`. Cells are split on unescaped `|` (`\|` is a literal pipe), trimmed, and leading/trailing empty cells from outer pipes are discarded. Each body row becomes one `Segment(kind: .tableRow, text: "<H1>: <v1>, <H2>: <v2>, …")` with every cell passed through the inline rules of stage 8. Empty cells render as "<Hn>: empty". A header is never read on its own. Tables with no body rows produce nothing. Rows with more cells than headers use "column <n>" as the header name; rows with fewer cells omit the missing columns. The table's own period terminates each row segment.
5. **Headings.** `^#{1,6}\s+(.*)$` → `Segment(kind: .heading, text: <title through inline rules>)`. Setext headings (a line followed by `===` or `---`) are also headings. Trailing `#`s are stripped.
6. **Lists.** Lines matching `^\s*([-*+]|\d+[.)])\s+(.*)$` are list items. Continuation lines (indented by at least the marker width, not matching a new item) are appended to the current item with a space. Nested items are flattened in document order; the nesting depth is discarded. Task-list markers `[ ]`/`[x]` → "" / "done:" prefix. Each item → `Segment(kind: .listItem, text: <item through inline rules>)`. An item whose text ends without terminal punctuation gets a period appended.
7. **Block clean-up.** Blockquote markers `^\s*>\s?` stripped (content remains prose). Horizontal rules (`^\s*([-*_])\s*\1\s*\1[\s\1]*$`) dropped. HTML tags `<[^>]{1,80}>` stripped (contents kept). Reference-style link definitions `^\[[^\]]+\]:\s+\S+` dropped.
8. **Inline rules.** Applied to every remaining prose run and to heading, list and table cell text. See the table below. Order matters and is the order of the table.
9. **Whitespace.** Collapse runs of spaces/tabs to one space; collapse three or more newlines to two; trim.
10. **Segment.** Prose runs go to `SentenceSegmenter`; pre-typed segments are kept as units. Output segments preserve document order.

### 4.2 `MarkdownSpeechRules.standard` — inline rules

| # | Rule | Pattern (Swift `Regex`, applied in order) | Replacement | Before → After |
|---|------|--------------------------------------------|-------------|----------------|
| 1 | Images | `!\[[^\]]*\]\([^)]*\)` | removed | `![diagram](a.png)` → "" |
| 2 | Markdown links | `\[([^\]]+)\]\((?:[^)\s]+)(?:\s+"[^"]*")?\)` | `$1` | `[the docs](https://x.y)` → "the docs" |
| 3 | Autolinks and bare URLs | `<?(?:https?|ftp|file)://[^\s<>)\]]+>?` and `www\.[^\s<>)\]]+` | "link" | `see https://a.b/c?d=1` → "see link" |
| 4 | Inline code | `` `([^`\n]+)` `` | `inlineCodeCleanup($1)` (§4.3) | `` `TranscriptTailer.swift` `` → "TranscriptTailer dot swift" |
| 5 | Bold/italic | `(\*\*|__)(.+?)\1`, then `(\*|_)(?=\S)(.+?)(?<=\S)\1` | `$2` | `**done**` → "done" |
| 6 | Strikethrough | `~~(.+?)~~` | `$1` | |
| 7 | Globs | `(?<!\S)\*\*/\*\.([A-Za-z0-9]+)(?!\S)` and `(?<!\S)\*\.([A-Za-z0-9]+)(?!\S)` | "$1 files" | `*.swift` → "swift files" |
| 8 | Paths | `(?<![\w@])(~|\.{1,2})?(/[\w.\-@+%]+){2,}/?` | last non-empty component (through §4.3 filename rule) | `/Users/j/dev/claudio/Sources/App.swift` → "App dot swift" |
| 9 | Long flags | `(?<!\S)--([a-z][\w-]*)` | `$1` with `-` → space | `--dry-run` → "dry run" |
| 10 | Short flags | `(?<!\S)-([a-zA-Z])(?!\w)` | "dash $1" | `-v` → "dash v" |
| 11 | Arrows | `\s*(->|=>|→|⇒)\s*` | " to " | `a -> b` → "a to b" |
| 12 | Ampersand | `\s&\s` | " and " | |
| 13 | Comparison operators in prose | `\s(==|!=|<=|>=)\s` | " equals ", " does not equal ", " at most ", " at least " | |
| 14 | Emoji and symbols | `[\p{Extended_Pictographic}\u{2600}-\u{27BF}\u{2B00}-\u{2BFF}\u{FE0F}\u{200D}]` | removed | "Done ✅" → "Done" |
| 15 | Box drawing and bullets | `[\u{2500}-\u{257F}\u{2022}\u{25A0}-\u{25FF}]` | removed | |
| 16 | Residual markdown | `^\s*[#>*_-]+\s*$` lines, stray `\*`, `\_` escapes | removed / unescaped | |
| 17 | Parenthetical file:line refs | `\(([\w./-]+\.\w{1,5}):(\d+)\)` | " $1 line $2" | `(Parser.swift:42)` → "Parser dot swift line 42" |
| 18 | Multiple punctuation | `([.!?]){2,}` | `$1` | "really?!" → "really?" |

Things deliberately left alone: numbers, currency, percentages, dates, version strings (`2.1.290`), times, units, acronyms. Every evaluated backend reads these correctly, and rewriting them risks mispronunciations.

### 4.3 `inlineCodeCleanup`

Applied to inline code spans and to path components.

1. If the token matches a filename with a known extension (`^[\w.\-]+\.(swift|py|js|ts|tsx|jsx|json|md|yml|yaml|toml|sh|rs|go|rb|java|kt|c|h|cpp|m|mm|html|css|sql|txt|plist|xcconfig|lock)$`), it is spoken as `<stem> dot <ext>` where the stem goes through steps 2–4 and the extension is spoken as its letters for ≤ 3 characters that are not words (`js` → "J S", `ts` → "T S", `md` → "M D", `sh` → "S H") and as a word otherwise (`swift`, `json`, `yaml`, `plist`, `lock`). So `Parser.swift` → "Parser dot swift", `index.ts` → "index dot T S".
2. `snake_case` and `SCREAMING_SNAKE` → words: `_` → space; all-caps runs of ≥ 2 letters are kept as-is (TTS engines spell acronyms).
3. `camelCase` and `PascalCase` → split before each uppercase letter that follows a lowercase letter or digit: `TranscriptTailer` → "Transcript Tailer", `URLSession` → "URL Session".
4. Dotted paths that are not filenames: `.` → space: `message.stop_reason` → "message stop reason".
5. `kebab-case` left as-is (engines read hyphens as pauses, which is right).
6. Brackets, parens and generics are removed: `Array<String>` → "Array String", `foo()` → "foo".
7. Operators `::`, `->`, `=>`, `==` as in the inline table.

Tests: `SpeechTextRendererTests.testFencedCodeBecomesCue`, `testFencedCodeLanguagePronunciation`, `testUnterminatedFence`, `testIndentedCodeOutsideListOnly`, `testTableRowsBecomeSegments`, `testTableEscapedPipe`, `testTableRaggedRows`, `testTableHeaderNotRead`, `testHeadings`, `testNestedListsFlattened`, `testTaskList`, `testLinksKeepText`, `testBareURLToLink`, `testPathLastComponent`, `testFilenamePronunciation`, `testSnakeCamelDotted`, `testFlags`, `testArrows`, `testEmojiRemoved`, `testFileLineRef`, `testRendererNeverThrows` (fuzz: 10 000 random byte strings produce a non-empty utterance or an empty one, never a crash), and the golden corpus `RendererGoldenTests` which renders every fixture under `Tests/Fixtures/markdown/*.md` and compares to `*.expected.txt`.

## 5. `SentenceSegmenter`

```swift
public struct SentenceSegmenter: Sendable {
    public var minimumLength: Int = 60        // characters
    public var maximumBytes: Int = 1200       // UTF-8
    public func segment(_ text: String, kind: Utterance.Segment.Kind) -> [Utterance.Segment]
}
```

Algorithm:

1. Pre-typed kinds (`heading`, `listItem`, `tableRow`, `cue`) are returned as one segment each, subject only to the maximum-length split in step 4. `tableRow` is **never** split; a row longer than `maximumBytes` is sent whole and the backend's own 4096-byte limit (doc 06) is the only ceiling.
2. Prose is tokenized with `NLTokenizer(unit: .sentence)` with language set to `.english` unless `NLLanguageRecognizer` detects another language with confidence ≥ 0.8.
3. **Abbreviation repair.** `NLTokenizer` splits after some abbreviations. Adjacent sentences are re-joined when the first ends with one of `e.g.`, `i.e.`, `vs.`, `etc.`, `Dr.`, `Mr.`, `Mrs.`, `Ms.`, `Prof.`, `Inc.`, `Ltd.`, `No.`, `Fig.`, `approx.`, a single capital letter followed by a period (initials), or a digit followed by a period when the next sentence starts with a digit (decimals and version numbers, e.g. "version 2." + "1.290").
4. **Merge short.** Walking forward, a sentence shorter than `minimumLength` characters is concatenated (with a space) onto the following sentence. The final sentence is never merged forward; if it is short it stays as its own segment. "Done." alone is spoken as "Done.".
5. **Split long.** A sentence longer than `maximumBytes` UTF-8 bytes is split at the last `;`, `:`, `,`, ` — ` or ` - ` before the limit; if none exists in the last 40 % of the window, at the last space before the limit; if no space, at the byte limit adjusted back to a UTF-8 boundary. Each piece becomes a `sentence` segment.
6. Each segment gets a fresh `UUID` and trimmed text. Empty segments are dropped.

Tests: `SentenceSegmenterTests.testBasicSplit`, `testAbbreviations`, `testDecimalsNotSplit`, `testVersionStringsNotSplit`, `testShortMergeForward`, `testLastShortStandsAlone`, `testLongSplitAtClause`, `testLongSplitAtSpace`, `testTableRowNeverSplit`, `testPreTypedKindsPreserved`, `testNonEnglishDetection`.

## 6. `SynthesisScheduler`

`SynthesisScheduler` is the actor that keeps audio flowing. It holds an ordered queue of segments, runs at most `lookahead + 1` synthesis tasks concurrently, and hands PCM to the sink in order.

```swift
public actor SynthesisScheduler {
    public init(backend: any TTSBackend, sink: any PlaybackSink, settings: AppSettings, clock: any Clock)

    public func append(_ utterance: Utterance) async
    public func removeAll(where predicate: @Sendable (ScheduledSegment) -> Bool, fade: TimeInterval) async
    public func skipCurrent() async
    public func setRate(_ multiplier: Double)
    public func setBackend(_ backend: any TTSBackend)
    public func setLookahead(_ n: Int)          // default 2, range 1...4

    public nonisolated let events: AsyncStream<SchedulerEvent>
}

public struct ScheduledSegment: Sendable, Identifiable {
    public let id: UUID                         // == Utterance.Segment.id
    public let segment: Utterance.Segment
    public let item: SpeechItem                 // for session/category/catch-up
    public var state: State                     // pending → synthesizing → ready → playing → finished | cancelled
    public var rate: Double                     // captured when synthesis starts
    public var buffers: [AVAudioPCMBuffer]      // retained until finished (for skip re-enqueue)
    public var wordBoundaries: [WordBoundary]   // offsets relative to segment audio start
    public var metrics: SegmentMetrics          // enqueuedAt, synthStartedAt, firstAudioAt, readyAt, playStartedAt, finishedAt
    public enum State: Sendable { case pending, synthesizing, ready, playing, finished, cancelled }
}

public struct WordBoundary: Sendable, Equatable {
    public let textRange: Range<String.Index>
    public let audioOffset: TimeInterval
    public let duration: TimeInterval
}
```

### 6.1 Lookahead policy

Let *k* be the index of the segment in state `playing` (or the head of the queue when nothing plays). The scheduler guarantees that segments *k+1 … k+lookahead* are in state `synthesizing` or `ready`, and that no segment beyond *k+lookahead* has started synthesizing. Triggers that re-evaluate this invariant: `append`, `segmentStarted`, `segmentFinished`, `removeAll`, `skipCurrent`, a synthesis failure.

When the queue is empty and a segment is appended, it is synthesized immediately and its first buffer is forwarded to the sink as soon as it arrives (streaming within a segment: the sink receives 200 ms buffers while the backend is still producing). Segments *k+1*, *k+2* start synthesizing at the same moment. So for a fresh answer the first audio arrives after one time-to-first-audio, and subsequent segments are already fully synthesized before they are needed.

### 6.2 Per-segment synthesis task

```swift
private func synthesize(_ scheduled: ScheduledSegment) -> Task<Void, Never> {
    Task(priority: .userInitiated) {
        let request = SynthesisRequest(text: scheduled.segment.text,
                                       voice: settings.voice(for: backend.id),
                                       rate: scheduled.rate,
                                       wantsWordBoundaries: true)
        do {
            for try await event in backend.synthesize(request) {
                try Task.checkCancellation()
                switch event {
                case .audio(let buffer):   await self.received(buffer, for: scheduled.id)
                case .wordBoundary(let r, let o, let d): await self.recordBoundary(scheduled.id, r, o, d)
                case .finished:            await self.synthesisFinished(scheduled.id)
                }
            }
        } catch is CancellationError {
            // state already .cancelled; nothing to do
        } catch {
            await self.synthesisFailed(scheduled.id, error)
        }
    }
}
```

`received(buffer, for:)` appends the buffer to `scheduled.buffers`. If the segment is the head of the queue (index *k*) **or** every segment before it is `finished`/`playing`, the buffer is forwarded immediately with `sink.enqueue(buffer, segmentID:)`. Otherwise it is retained and forwarded in a burst when the segment becomes the head. This is the **ordering guarantee**: PCM reaches the sink in queue order even when *k+2* finishes synthesizing before *k+1*. The sink itself never reorders.

`synthesisFinished` marks the segment `ready` and calls `sink.markSegmentEnd(id)` once all its buffers have been forwarded. A segment with zero audio buffers at `finished` (backend produced nothing) is treated as a synthesis failure.

### 6.3 Failure and fallback

In production the backend is always a `FallbackBackend` (doc 06 §5), which performs the Edge→Apple switch internally per request. The scheduler therefore sees a failure only when **both** primary and fallback fail. On `synthesisFailed`:

1. Log `.error` `synth.failed segment=<id> backend=<id> error=<desc>`.
2. If `attempt == 0`, re-run the segment once with the fallback backend directly (`backend.fallbackOnly`) — this covers a transient primary failure that also tripped the fallback race.
3. If that fails too, mark the segment `cancelled`, emit `SchedulerEvent.segmentDropped(id, error)` (the HUD shows a transient "couldn't speak a sentence" notice) and move on. **One lost sentence never stalls the queue.**

### 6.4 Backpressure

Buffered PCM is bounded by `lookahead` segments plus the playing one. With default settings and typical 8–15 s sentences that is at most ~45 s of audio (4.3 MB of Float32 at 24 kHz). The scheduler never synthesizes beyond the lookahead window, so a 200-segment answer does not open 200 WebSockets. `PipelineState.queuedSeconds` reports the sum of synthesized-but-unplayed durations.

### 6.5 Rate changes

`setRate` stores the multiplier. Segments in `pending` pick it up when synthesis starts. Segments already `synthesizing`, `ready` or `playing` keep the rate captured at their synthesis start; they are not re-synthesized (that would waste a round trip and risk a gap). The user hears the new rate within at most `lookahead + 1` segments, typically under 30 s, and immediately for a fresh answer.

### 6.6 Metrics

Per segment, `SegmentMetrics` records wall-clock instants from the injected clock. Derived numbers logged at `.info` on `segmentFinished`:

- `ttfa` = `firstAudioAt − synthStartedAt` (backend latency),
- `wait` = `playStartedAt − enqueuedAt` (what the user experienced),
- `gap` = `playStartedAt − previous.finishedAt` (should be ≤ 50 ms; a gap > 50 ms logs at `.notice` with `starved=true` when the segment was not `ready` in time),
- `backend` actually used (`FallbackBackend` reports it through `SynthesisEvent.finished`'s side channel, see doc 06).

A rolling summary (p50/p95 of `ttfa` and `gap` over the last 100 segments) is readable via `claudio status --json`.

Tests: `SynthesisSchedulerTests.testLookaheadInvariant`, `testOrderingWhenLaterSegmentFinishesFirst`, `testStreamingFirstSegmentBuffersForwardedImmediately`, `testBackpressureNeverExceedsLookahead`, `testRateAppliesToPendingOnly`, `testFailureRetriesFallbackOnce`, `testDoubleFailureDropsSegmentAndContinues`, `testRemoveAllCancelsTasks`, `testSkipCurrentReenqueuesReadySegments`, `testMetricsGapComputation`.

## 7. `PlaybackSink` and `PlaybackEngine`

### 7.1 Protocol

```swift
public protocol PlaybackSink: AnyObject, Sendable {
    func enqueue(_ buffer: AVAudioPCMBuffer, segmentID: UUID) async
    func markSegmentEnd(_ segmentID: UUID) async
    func pause() async
    func resume() async
    func cancelAll(fade: TimeInterval) async
    func skipSegment(_ segmentID: UUID, fade: TimeInterval) async
    var events: AsyncStream<PlaybackEvent> { get }
}

public enum PlaybackEvent: Sendable, Equatable {
    case segmentStarted(UUID, at: Date)
    case segmentFinished(UUID, at: Date)
    case position(UUID, TimeInterval)       // seconds into the segment, 30 Hz while playing
    case paused, resumed
    case drained                            // nothing scheduled, nothing playing
    case deviceChanged
}
```

Buffer contract: `AVAudioPCMBuffer` with `AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)`. A buffer of a different format is converted by the sink with a cached `AVAudioConverter` and logged once at `.notice`; backends are expected to deliver the canonical format and the integration tests assert it.

### 7.2 Graph

```
AVAudioPlayerNode ──▶ AVAudioEngine.mainMixerNode ──▶ AVAudioEngine.outputNode
 (24 kHz mono)          (converts to device rate)        (device)
```

`engine.connect(playerNode, to: engine.mainMixerNode, format: canonicalFormat)`. The mixer performs sample-rate conversion to the output device's rate (44.1 or 48 kHz) so buffers are never resampled in Swift.

### 7.3 Engine lifecycle

- The engine is created at app start but **not started**. `engine.prepare()` is called so the first start is fast.
- `engine.start()` happens on the first `enqueue` after idle. Start latency is 20–60 ms, which is inside the first segment's TTFA.
- After `drained`, a 30 s timer stops the engine (`engine.stop()`), releasing the audio device so other apps' audio ducking and Bluetooth power behaviour return to normal. Any `enqueue` cancels the timer.
- `AVAudioEngineConfigurationChange` (device change, headphones plugged, sample rate change): the handler records the current segment id and position, calls `engine.stop()`, re-connects the player with the canonical format, restarts the engine, and emits `.deviceChanged`. The scheduler reacts by re-enqueueing the current segment's remaining buffers and all `ready` segments from its cache, so the user hears at most a 200 ms repeat, never silence.
- `playerNode.play()` is called once after engine start and stays playing; when there is nothing scheduled the node simply renders silence. This avoids a `play()` call per segment, which on some devices introduces a 2–5 ms discontinuity.

### 7.4 Scheduling and segment boundaries

Every buffer is scheduled with

```swift
playerNode.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { _ in ... }
```

`at: nil` means "immediately after the previously scheduled buffer", which is what makes playback gapless. The completion callback fires when the buffer has actually been rendered to the device (`.dataPlayedBack`), not when it was consumed. The engine keeps a map `bufferID → segmentID`; `markSegmentEnd(id)` records that no more buffers will arrive for that segment, and when the last known buffer of a segment reports played back, `.segmentFinished` is emitted. `.segmentStarted` is emitted when the first buffer of a segment begins rendering, detected by comparing `playerNode.playerTime(forNodeTime: playerNode.lastRenderTime!)` against the cumulative frame count of previously scheduled buffers.

Position is sampled at 30 Hz from a `DispatchSourceTimer` on the engine's serial queue while a segment is playing: `position = (playerTime.sampleTime − segmentStartSample) / 24_000`.

### 7.5 Pause and resume

`pause()` → `playerNode.pause()`. Scheduled buffers remain scheduled; the render clock stops. `resume()` → `playerNode.play()`. The engine stays running during pause (no 30 s stop timer while paused). Position reports pause.

### 7.6 Cancel sequence

`cancelAll(fade: 0.015)`:

1. On the engine queue, capture `v0 = playerNode.volume` (normally 1.0).
2. Ramp: 15 steps, every 1 ms (`usleep(1000)` on the engine queue, which is not the render thread), set `playerNode.volume = v0 * (1 − i/15)`. `AVAudioPlayerNode.volume` is applied by the mixer at the next render quantum (≈ 2.7 ms at 48 kHz / 128 frames), so the audible result is a 15–20 ms linear fade.
3. `playerNode.stop()` — stops rendering and clears all scheduled buffers; pending completion handlers fire with `.dataPlayedBack` not reached and are ignored by checking a generation counter that `cancelAll` increments.
4. `playerNode.reset()` — clears internal state and any residual buffered frames.
5. `playerNode.volume = v0`; `playerNode.play()` — the node is ready for the next buffer with no further latency.
6. Emit `.drained`.

Total time ≈ 18 ms. The 15 ms fade turns the hard cut into a short ramp that is inaudible as a click across all test devices (built-in speakers, wired headphones, AirPods).

`skipSegment(id, fade:)` performs steps 1–5 for the whole queue, then the **scheduler** (which owns the buffer cache) re-enqueues the retained buffers of every `ready` segment after the skipped one, in order. Because those buffers are already in memory the re-enqueue takes under 1 ms and the next segment starts within one render quantum of the fade finishing. The skipped segment is marked `finished` for metrics, with `skipped = true`.

Click test: `PlaybackEngineClickTests.testCancelProducesNoDiscontinuity` renders a 440 Hz sine through the engine into an offline `AVAudioEngine` (`enableManualRenderingMode(.offline, …)`), issues `cancelAll` at a random phase, and asserts the maximum absolute sample-to-sample difference in the rendered output over the fade window is below 0.02 (a hard cut at full amplitude is ~1.0). Runs in CI without an audio device.

### 7.7 `RecordingPlaybackSink`

The test sink. It accepts buffers, records `(segmentID, frameCount, clock.now)` for each, simulates playback by advancing an injected `TestClock` by `frameCount / 24_000` seconds per buffer when `advance()` is called, and emits the same `PlaybackEvent`s the real engine would at the same simulated instants. It records every `cancelAll`/`skipSegment`/`pause`/`resume` call with the clock time. Integration tests assert on its recorded timeline. It also exposes `totalFrames(for segmentID:)` and `playbackOrder: [UUID]`.

Tests: `PlaybackEngineTests.testGaplessSchedulingUsesAtNil`, `testSegmentStartedFinishedOrdering`, `testIdleStopsEngineAfter30s`, `testEnqueueCancelsIdleTimer`, `testPauseResume`, `testConfigurationChangeReenqueues`, `testFormatConversionLoggedOnce`, `PlaybackEngineClickTests.testCancelProducesNoDiscontinuity`, `testSkipProducesNoDiscontinuity`.

## 8. Cancel latency budget

End to end for "user submits a prompt in the active session while Claudio is speaking", with hooks installed:

| Stage | Component | Budget | Typical |
|-------|-----------|--------|---------|
| Claude Code spawns `claudio hook` | Claude Code | — | 5–10 ms |
| Read stdin, connect socket, write line, exit | `claudio hook` | 20 ms | 6 ms |
| Accept, decode, dispatch | `ControlServer` → `SessionRegistry` | 5 ms | 1 ms |
| `Arbiter` decides cancel | `Arbiter` | 2 ms | < 1 ms |
| `removeAll` cancels tasks, calls sink | `SynthesisScheduler` | 5 ms | 1 ms |
| Fade + stop + reset | `PlaybackEngine` | 20 ms | 18 ms |
| **Total** | | **≤ 100 ms** | **≈ 35 ms** |

Without hooks, the first stage is replaced by Claude Code writing the `user` record to the transcript (asynchronous, observed 50–400 ms after the keypress) plus FSEvents latency (configured 100 ms) plus the tailer read (< 5 ms). Budget ≤ 600 ms, typical ≈ 300 ms.

Test: `CancelLatencyTests.testHookCancelUnder100ms` (synthetic hook event through a real `ControlServer` on a temp socket, `RecordingPlaybackSink`, asserts recorded cancel time − send time < 100 ms on CI hardware).

## 9. Word boundaries and captions

A `WordBoundary` from the backend is relative to the start of **that segment's audio**. The HUD needs the word that is playing *now*.

- When `.segmentStarted(id, at: t0)` arrives, the pipeline records `t0` for the segment.
- `.position(id, p)` arrives at 30 Hz. The current word is the last boundary with `audioOffset ≤ p`. `PipelineState.currentWordRange` is updated and emitted only when the word changes.
- Between position samples the HUD interpolates nothing; 30 Hz is finer than word duration (median English word ≈ 300 ms at normal rate).
- Rate: backends that apply rate themselves (Edge via SSML, Apple via `rate`, OpenAI via `speed`) return boundaries in output time, so no correction is needed.

**Approximated boundaries.** For a backend with `supportsWordBoundaries == false` (OpenAI), or when a boundary-capable backend returned none, the scheduler synthesizes boundaries at `synthesisFinished`: it knows the total frame count, splits `segment.text` on whitespace, and assigns each word a duration proportional to `max(1, characterCount + 1)` (the +1 models the space/pause). Approximated boundaries are tagged `approximate: true` and the HUD renders them with a slightly softer highlight so the user is not misled about precision.

Tests: `CaptionTimingTests.testCurrentWordFollowsPosition`, `testApproximatedBoundariesSumToDuration`, `testBoundariesSurviveRateChange`.

## 10. Events, cues and chimes

`event` items (from hooks and transcript signals, see docs 03–04) render to a single `Segment(kind: .cue, text:)`. Cue text is already plain and bypasses the markdown stages, but goes through the whitespace stage.

Fixed wordings (English, in `Cues.swift`; localizable later):

| Situation | Text | Chime |
|-----------|------|-------|
| Background session finished a turn | "<name> finished." | `finished.aiff` before the text |
| Background session needs permission | "<name> needs permission." | `attention.aiff` |
| Background session is waiting for input | "<name> needs input." | `attention.aiff` |
| Background session hit an API error | "<name> hit an error: <short reason>." | `attention.aiff` |
| Switched, unread turns exist | "<name>. Catching up on <n> turn(s)." | `switch.aiff` |
| Switched, no unread turns, session busy | "<name>. Live." | `switch.aiff` |
| Switched, no unread turns, session idle | "<name>." | `switch.aiff` |
| Catch-up finished, session busy | "Live." | — |
| Catch-up finished, session idle | "You're caught up." | — |
| Catch-up skipped by the user | "Live." or "You're caught up." as above | — |
| Backend fell back for the first time this hour | (HUD notice only, no speech) | — |
| Voice preview | "This is <voice name>. Claudio reads your Claude Code sessions aloud." | — |

Catch-up cue items carry the prefix marker `\u{200B}CUE:` in `SpeechItem.text` (stripped before rendering) so `ContentFilter` can recognise them as always-speak. Chimes are 300–600 ms mono AIFF files in `Resources/sounds/`, decoded once with `AVAudioFile` into the canonical format at app start and cached. `enqueueChime` schedules the cached buffer as a one-buffer segment of kind `.cue` through the **same** player node, so chimes queue with speech and can never overlap it. Chime volume is scaled by `AppSettings.events.chimeVolume` (0–1, default 0.6) by multiplying the cached buffer once per volume change.

Announcement insertion: the `Arbiter` enqueues event utterances like any other; because the scheduler is strictly ordered, an announcement plays after the segment that is currently playing and before the next queued segment of the active session. This is the "between segments, never cancels" behaviour of doc 01 §7.

Tests: `CuesTests.testWordings`, `ChimeTests.testChimesDecodedToCanonicalFormat`, `SpeechPipelineTests.testAnnouncementInsertsBetweenSegments`.

## 11. Logging

Subsystem `com.jdforsythe.claudio`, categories `pipeline`, `render`, `scheduler`, `playback`.

| Level | Events |
|-------|--------|
| `.debug` | Every segment state transition; every filter decision with reason; every rule that changed text in the renderer (rule number, before/after lengths); every boundary batch |
| `.info` | Utterance enqueued (session, category, segment count, char count); segment finished with `ttfa`, `wait`, `gap`, backend; cancel with reason and segments dropped; rate/backend changes; engine start/stop |
| `.notice` | Gap > 50 ms with `starved`; format conversion applied; approximated boundaries used; device change |
| `.error` | Renderer stage failure (with stage); synthesis failure; segment dropped; engine start failure |

Privacy: segment text is logged at `.debug` only and marked `privacy: .private` so it is redacted in unified logging unless the user runs `claudio diagnostics --verbose` (doc 11).

## 12. Test index

Unit (`ClaudioCoreTests`):

- `ContentFilterTests`: `testTruthTable`, `testCatchUpBypassesLevel`, `testEventsDisabledDropsEventsButNotCues`
- `ToolCallSummarizerTests`: `testBashUsesDescriptionWhenShort`, `testBashStripsFlags`, `testReadUsesFilename`, `testGrepRemovesRegexMeta`, `testGlobRendersAsFiles`, `testMCPNaming`, `testUnknownToolSplitsCamelCase`, `testTwelveWordCap`, `testConsecutiveDedupeWithin5s`, `testDedupeExpiresAfter5s`, `testSilentTools`
- `SpeechTextRendererTests`: the list in §4.3 plus `testBlockquoteStripped`, `testHorizontalRuleDropped`, `testHTMLStripped`, `testReferenceLinksDropped`, `testStageOrderCodeBeforeInline` (an inline-code span containing `->` is not rewritten to "to" twice)
- `RendererGoldenTests`: `testAllFixtures` over `Tests/Fixtures/markdown/`
- `SentenceSegmenterTests`: the list in §5
- `SynthesisSchedulerTests`: the list in §6.6
- `PlaybackEngineTests`, `PlaybackEngineClickTests`: the list in §7.7
- `CaptionTimingTests`, `CuesTests`, `ChimeTests`

Integration (`ClaudioIntegrationTests`, all using `RecordingPlaybackSink`, `MockBackend` and `TestClock`):

- `SpeechPipelineTests.testNarrateLevelSpeaksAllThreeInOrder` (story 1)
- `SpeechPipelineTests.testGapUnder50ms` (story 1; asserts simulated gaps)
- `SpeechPipelineTests.testLevelDowngradeDropsQueuedButNotPlaying` (story 6)
- `SpeechPipelineTests.testTableRowsAreSkipUnits` (story 7)
- `SpeechPipelineTests.testAnnouncementInsertsBetweenSegments` (story 3)
- `SpeechPipelineTests.testRateChangeLive`
- `CancelLatencyTests.testHookCancelUnder100ms` (story 2)
- `FallbackPipelineTests.testPrimaryAlwaysFailsEveryChunkStillSpoken` (story 8)
