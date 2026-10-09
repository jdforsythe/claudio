# 03 — Transcript Ingestion

This document describes how Claudio discovers Claude Code sessions, tails their transcript files, parses records, assembles turns, classifies content into speech items, and maintains the session registry. It covers the `Transcript/` and `Sessions/` modules of `ClaudioCore`.

Hooks (document 04) are a second, optional source of the same `TurnEvent`s. Everything in this document works with hooks disabled. Section 9 describes how the two sources are reconciled.

## 1. Where transcripts live

### 1.1 Roots

A **root** is a Claude configuration directory. The default root is `~/.claude`. Claudio watches `<root>/projects/` under every configured root. Additional roots are configured in Settings → Advanced → Transcript roots (document 08, key `transcriptRoots`). The common reason to add one is Orca: when the user has pinned a non-default Claude account in Orca, Orca launches `claude` with `CLAUDE_CONFIG_DIR=<orca-account-home>`, and that session's transcripts land under `<orca-account-home>/projects/`. For Orca's default account, transcripts land under `~/.claude/projects/` like every other session, and no extra root is needed.

Claudio also reads `$CLAUDE_CONFIG_DIR` from its own environment at launch and adds it as a root if set and different from `~/.claude`.

### 1.2 Project directory encoding

Inside a root, each working directory gets one project directory:

```
<root>/projects/<encoded-cwd>/
```

`<encoded-cwd>` is the absolute cwd with every character that is not ASCII alphanumeric replaced by `-`. `/Users/jforsythe/dev/claudio` becomes `-Users-jforsythe-dev-claudio`. Claude Code truncates encodings longer than 200 characters and appends a hash; Claudio does not need to reproduce that, because it never computes a project directory from a cwd. It always reads `cwd` from the records inside the transcript. `ProjectPathEncoding.swift` exists only for `decodeBestEffort(_:)`, used to label a session before its first record is parsed (it replaces `-` with `/` and checks whether the resulting path exists; if several candidates exist the folder name is used verbatim).

### 1.3 Files inside a project directory

| Path | Meaning | Watched |
|------|---------|---------|
| `<project>/<session-uuid>.jsonl` | Main transcript for one session | Yes |
| `<project>/<session-uuid>/subagents/agent-<id>.jsonl` | One subagent's transcript, `isSidechain: true` | Yes |
| `<project>/<session-uuid>/subagents/agent-<id>.meta.json` | Subagent metadata (description, type) | Read once when the matching `.jsonl` first appears |
| `<project>/<session-uuid>/tool-results/*.txt` | Persisted large tool outputs | No |
| `<project>/<session-uuid>/scratchpad/` | Session scratch files | No |
| `<project>/memory/` | Claude's memory directory for that project | No |

Main transcripts are identified by the regex `^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jsonl$` on the file name. Subagent transcripts are identified by `^agent-[0-9a-z]+\.jsonl$` in a `subagents` directory whose parent directory name is a session UUID. Everything else under `projects/` is ignored.

## 2. Record catalog

A transcript is newline-delimited JSON, one record per line, appended as Claude Code runs. Records are never rewritten in place; a resumed session appends to the same file.

Every record has a `type`. Most records that belong to the conversation also carry the **envelope** fields:

| Field | Type | Claudio reads | Purpose |
|-------|------|---------------|---------|
| `type` | string | yes | Record discriminator |
| `uuid` | string | yes | Record identity; used for dedup and `parentUuid` chains |
| `parentUuid` | string? | no | Previous record in the conversation tree |
| `sessionId` | string | yes | Session identity. Some records also carry `session_id` with the same value |
| `timestamp` | ISO-8601 string | yes | Record time; used for `lastActivity` |
| `cwd` | string | yes | Working directory; used for session cwd and naming |
| `entrypoint` | string | yes | `cli` or `claude-desktop` |
| `version` | string | yes (diagnostics) | Claude Code version that wrote the record |
| `gitBranch` | string? | no | |
| `isSidechain` | bool | yes | `true` in subagent transcripts |
| `agentId` | string? | yes | Subagent id in subagent transcripts |
| `promptId` | string? | yes | The turn this record belongs to |
| `userType` | string | no | `external` |
| `isMeta` | bool? | yes | Marks synthetic user records that are not human prompts |

Records without the envelope (`last-prompt`, `ai-title`, `permission-mode`, `mode`, `atis-latch`, `queue-operation`, `file-history-snapshot`) carry `sessionId` and nothing else from the table.

### 2.1 `user` — human prompt

```json
{"type":"user","uuid":"5b66c808-…","parentUuid":"9044aa9a-…","promptId":"e89a4f1b-…",
 "message":{"role":"user","content":"i've been testing a little project called claude-speak…"},
 "origin":{"kind":"human"},"promptSource":"typed","turnOrigin":"human",
 "turnPosition":{"promptIndex":1,"turnIndex":1},"permissionMode":"auto",
 "timestamp":"2026-10-05T19:38:43.907Z","cwd":"/Users/jforsythe/dev/claudio",
 "sessionId":"562358f2-…","entrypoint":"cli","version":"2.1.289","isSidechain":false}
```

Read: `promptId`, `message.content` (string, or array of `{type:"text",text}` blocks, concatenated), `origin.kind`, `promptSource`, `turnOrigin`, `isMeta`. This record starts a turn (§6.1).

### 2.2 `user` — tool result

```json
{"type":"user","uuid":"d34c8082-…","promptId":"e89a4f1b-…",
 "message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_01R2…","content":"Launching skill: grill-me"}]},
 "toolUseResult":{"success":true,"commandName":"grill-me"},
 "sourceToolAssistantUUID":"cd778447-…","sourceToolUseID":"toolu_01R2…", …}
```

Read: `message.content[].tool_use_id`, `message.content[].is_error` (when present), `toolUseResult` (an object; its shape depends on the tool). This record never starts a turn. It produces a `toolResult` speech item only when it indicates an error (§6.6). It also moves a `waiting` session back to `busy`.

### 2.3 `assistant`

Claude Code writes **one record per content block**. All blocks of one API response share `message.id` and `requestId`; `apiBlockIndex` is the block's position.

```json
{"type":"assistant","uuid":"b412071b-…","parentUuid":"1ad3bd14-…","requestId":"req_011Cfjf1L5BNAxC2AZtbq5YK","apiBlockIndex":1,
 "message":{"id":"msg_011Cfjf1LtXrAquJf23NEW6c","role":"assistant","model":"claude-fable-5-1",
   "content":[{"type":"text","text":"I'll load the grill-me skill, then research…"}],
   "stop_reason":"tool_use","usage":{…}},
 "timestamp":"2026-10-05T19:38:50.318Z","sessionId":"562358f2-…","isSidechain":false, …}
```

Block variants inside `message.content[0]`:

| `content[0].type` | Fields read | Becomes |
|-------------------|-------------|---------|
| `text` | `text` | `finalAnswer` or `narration` (§6.3) |
| `thinking` | `thinking` | `thinking` |
| `tool_use` | `id`, `name`, `input` | `toolCall` (§6.5) |

Also read: `message.id`, `message.stop_reason` (`end_turn`, `tool_use`, `max_tokens`, `stop_sequence`, or `null`), `requestId`, `apiBlockIndex`, `thinkingDurationMs` (diagnostics only). `usage`, `wireToolInputs`, `advisorModel`, `effort`, `serverClassifierRequest` are ignored.

### 2.4 `system`

```json
{"type":"system","subtype":"turn_duration","durationMs":148380,"messageCount":89,"pendingBackgroundAgentCount":2,
 "uuid":"3a208f63-…","timestamp":"2026-10-05T19:41:12.232Z","sessionId":"562358f2-…", …}
```

| `subtype` | Read | Effect |
|-----------|------|--------|
| `turn_duration` | `durationMs`, `messageCount`, `pendingBackgroundAgentCount` | Ends the current turn (§6.4) |
| `stop_hook_summary` | `hookInfos[].command`, `hookErrors` | Diagnostics only; written immediately before `turn_duration` |
| anything else | — | Counted, ignored |

### 2.5 `attachment`

```json
{"type":"attachment","uuid":"9044aa9a-…","attachment":{"type":"hook_success","hookName":"SessionStart:startup",
 "hookEvent":"SessionStart","command":"/Users/jforsythe/.config/iterm2/cc-status","exitCode":0,"durationMs":280},
 "renderedRole":"system","sessionId":"562358f2-…", …}
```

Attachments are system-reminder material injected into the conversation. Claudio ignores all of them except `attachment.type == "hook_success"` or `"hook_failure"` whose `command` contains `claudio hook`, which it logs at `.debug` as confirmation that its own hooks are running (document 11 uses this for the "are my hooks firing" diagnostic).

### 2.6 `ai-title`

```json
{"type":"ai-title","aiTitle":"Claude-speak redesign and architecture","sessionId":"562358f2-…"}
```

Read: `aiTitle`. Sets the session title (§8.2). Claude Code writes this a few seconds after the first turn and may rewrite it later.

### 2.7 `last-prompt`, `permission-mode`, `mode`, `atis-latch`

```json
{"type":"last-prompt","leafUuid":"9044aa9a-…","sessionId":"562358f2-…"}
{"type":"permission-mode","permissionMode":"auto","sessionId":"562358f2-…"}
```

`permission-mode` is read for the session's `permissionMode` shown in the popover. The others are counted and ignored.

### 2.8 `queue-operation`

```json
{"type":"queue-operation","operation":"enqueue","timestamp":"2026-10-05T19:42:05.145Z","sessionId":"562358f2-…","content":"<agent-message from=…"}
```

Queued messages (subagent hand-backs, teammate messages, user messages typed while Claude is busy). Ignored: when a queued message is actually delivered it reappears as a normal `user` record, and that record is what Claudio reacts to.

### 2.9 `file-history-snapshot`

Large; contains file contents. Ignored entirely; the parser short-circuits on the `type` before decoding the rest of the line.

### 2.10 Subagent records

Subagent transcripts contain the same record types with `isSidechain: true` and `agentId` set. The first record is a `user` record whose `message.content` is the prompt the parent passed to the agent. See §7.

### 2.11 Unknown records

Any `type` not listed above is decoded as `.unknown(type)`, counted in `TranscriptParser.metrics.unknownTypes[type]`, logged once per type per session at `.info`, and otherwise ignored. The schema is explicitly unstable across Claude Code releases; new record types must never stop ingestion.

## 3. `TranscriptRecord` and `TranscriptParser`

```swift
// Transcript/TranscriptRecord.swift
public struct TranscriptRecord: Sendable {
    public let envelope: Envelope
    public let payload: Payload
    public let rawLength: Int

    public struct Envelope: Sendable {
        public let type: String
        public let uuid: String?
        public let sessionID: SessionID?
        public let promptID: TurnID?
        public let timestamp: Date?
        public let cwd: String?
        public let entrypoint: String?
        public let version: String?
        public let isSidechain: Bool
        public let agentID: String?
        public let isMeta: Bool
    }

    public enum Payload: Sendable {
        case humanPrompt(text: String, originKind: String?, promptSource: String?, turnOrigin: String?)
        case toolResult(toolUseID: String, isError: Bool, summary: String?)
        case assistantText(messageID: String, requestID: String?, blockIndex: Int?, stopReason: String?, text: String)
        case assistantThinking(messageID: String, stopReason: String?, text: String)
        case assistantToolUse(messageID: String, stopReason: String?, toolUseID: String, name: String, input: [String: JSONValue])
        case turnDuration(durationMs: Int, messageCount: Int?, pendingBackgroundAgents: Int?)
        case stopHookSummary(commands: [String], errorCount: Int)
        case aiTitle(String)
        case permissionMode(String)
        case hookAttachment(hookEvent: String, command: String, exitCode: Int?)
        case ignored            // attachment (other), last-prompt, mode, atis-latch, queue-operation, file-history-snapshot
        case unknown(type: String)
    }
}
```

`JSONValue` is a small recursive enum (`string`, `number`, `bool`, `null`, `array`, `object`) used for `tool_use.input`, because tool inputs are arbitrary.

```swift
// Transcript/TranscriptParser.swift
public struct TranscriptParser: Sendable {
    public struct Metrics: Sendable { public var lines, decoded, malformed, unknownTypes: …; }
    public init()
    public func parse(line: Data) -> Result<TranscriptRecord, ParseError>
    public var metrics: Metrics { get }
}
```

Design rules:

1. **Two-phase decode.** Phase one decodes only `{"type": String}` with a `JSONDecoder` into a one-field struct. If `type` is `file-history-snapshot`, the parser returns `.ignored` without decoding further. Phase two decodes a `RawRecord` with every field optional, then builds the typed payload.
2. **Nothing is required except `type`.** A record with no `sessionId` is still returned; the tailer attributes it to the file's session.
3. **Malformed lines** (`JSONDecoder` throws) return `.failure(.malformed(offset, prefix))` with the first 80 bytes. The tailer logs at `.warning` and continues. A partial line at EOF is never a malformed line, because the tailer only passes complete lines (§5.3).
4. **Dates** are parsed with a fixed `ISO8601DateFormatter` with fractional seconds; a date that fails to parse is `nil` and the tailer substitutes the wall clock.
5. **`message.content` for user records** is a string or an array. A string is a human prompt. An array whose first element is `tool_result` is a tool result. An array of `text` blocks is a human prompt whose text is the concatenation. An array that mixes `text` and `tool_result` (seen when the user types while a tool result is pending) is treated as a tool result and the text is discarded, because Claude Code records the typed text separately as its own `user` record.
6. **Performance.** Parsing is on the tailer's background task. Typical line: 1–5 KiB, under 50 µs. The parser is a value type with no shared state; `metrics` is accumulated by the tailer, not the parser.

Tests: `TranscriptParserTests.testDecodesEveryFixtureRecordType`, `testUnknownTypeIsCountedNotThrown`, `testFileHistorySnapshotShortCircuits`, `testMixedUserContentIsToolResult`, `testMalformedLineReturnsPrefix`.

## 4. `SessionDiscovery`

```swift
// Transcript/SessionDiscovery.swift
public final class SessionDiscovery: Sendable {
    public enum Event: Sendable {
        case mainTranscriptChanged(url: URL, sessionID: SessionID, root: URL)
        case subagentTranscriptChanged(url: URL, sessionID: SessionID, agentID: String, root: URL)
        case rootUnavailable(URL)
    }
    public init(roots: [URL], clock: Clock)
    public var events: AsyncStream<Event> { get }
    public func start()
    public func stop()
    public func updateRoots(_ roots: [URL])     // live; diff and restart only changed streams
}
```

### 4.1 FSEvents configuration

One `FSEventStream` per root, watching `<root>/projects`. Flags: `kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer`. Latency `0.1` seconds. The stream is scheduled on a dedicated `DispatchQueue(label: "com.jdforsythe.claudio.fsevents")`. `sinceWhen` is `kFSEventStreamEventIdSinceNow`: history is never replayed.

If `<root>/projects` does not exist at start, the discovery watches `<root>` instead and switches to `<root>/projects` when it appears (the `kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsDir` event for that path). This covers a fresh Claude install.

### 4.2 Path filtering

For each event path:

1. Reject unless the path has extension `jsonl`.
2. Match against the two regexes in §1.3, anchored to the path components `projects/<project>/<file>` or `projects/<project>/<session>/subagents/<file>`.
3. Extract `sessionID` from the file name (main) or the grandparent directory name (subagent).

Events with `kFSEventStreamEventFlagItemRemoved` or `kFSEventStreamEventFlagItemRenamed` on a watched file are forwarded as the same `…Changed` event; the tailer handles the consequences (§5.4). `kFSEventStreamEventFlagMustScanSubDirs` or `kFSEventStreamEventFlagRootChanged` triggers a one-time scan of the root (§4.4).

### 4.3 Debouncing

Claude Code writes several lines within milliseconds of each other. FSEvents coalesces them within the 0.1 s latency window, and the discovery additionally coalesces by path: a per-path `Task` is scheduled 50 ms out, and further events for that path within the window are dropped. The tailer reads to EOF on every wake anyway, so dropping intermediate events loses nothing.

### 4.4 Initial scan

On `start()`, and after a `MustScanSubDirs`, the discovery enumerates each `<root>/projects` with `FileManager.enumerator(at:includingPropertiesForKeys:[.contentModificationDateKey])`, skipping hidden entries and descending at most three levels. Every matching `.jsonl` whose modification date is within the liveness window (24 h, document 01 §17 story 12) is emitted as a `…Changed` event so the registry creates sessions for them. The tailer attaches at EOF, so no old content is spoken; the sessions simply appear in the list, idle, with the title read from the file's last `ai-title` record by a bounded reverse scan of at most 64 KiB (`TranscriptTailer.peekTitle(url:)`).

### 4.5 Failure handling

`FSEventStreamStart` returning `false`, or a root path that becomes unreadable, emits `.rootUnavailable(root)`, logs at `.error`, and the discovery retries creation of that stream every 30 s. The UI shows a warning badge on the affected root in Settings.

Tests: `SessionDiscoveryTests.testMainTranscriptPathIsRecognised`, `testSubagentPathIsRecognised`, `testToolResultsDirectoryIsIgnored`, `testDebounceCoalescesBurst` (uses a temp directory and real FSEvents with a 2 s assertion budget), `testProjectsDirectoryAppearingLaterIsPickedUp`, `testInitialScanSkipsFilesOlderThanWindow`.

## 5. `TranscriptTailer`

```swift
// Transcript/TranscriptTailer.swift
public final class TranscriptTailer: Sendable {
    public struct Output: Sendable {
        public let record: TranscriptRecord
        public let fileOffset: UInt64
    }
    public init(url: URL, sessionID: SessionID, parser: TranscriptParser, log: Log)
    public var records: AsyncStream<Output> { get }
    public func wake()                      // called by registry on each discovery event
    public func close()
    public static func peekTitle(url: URL) -> String?
}
```

One tailer per transcript file (main or subagent). The registry owns tailers and calls `wake()` when discovery reports a change.

### 5.1 Attach

On first `wake()` the tailer opens the file read-only, reads `st_ino` and `st_size`, sets `offset = st_size`, and emits nothing. **It never reads history.** A session that was discovered by the initial scan therefore starts silent and idle, and speaks only what is written after Claudio attached.

The one exception is the registry's catch-up-after-restart path, which uses `sessions.json` (§8.7), not the file.

### 5.2 Read on wake

Each `wake()` runs on the tailer's serial task:

1. `fstat` the open descriptor. If `st_ino` differs from the saved inode → §5.4 (replaced). If `st_size < offset` → §5.4 (truncated).
2. Read from `offset` to `min(st_size, offset + 1 MiB)` with `pread`. If more remains, re-schedule `wake()` immediately after processing.
3. Append the bytes to the partial-line buffer.
4. Split the buffer on `\n`. Each complete line (minus a trailing `\r`) goes to the parser and is emitted. The remainder stays in the buffer.
5. `offset` advances by the number of bytes consumed into complete lines, so a partial line is re-read from its start on the next wake if the buffer is ever dropped; in practice the buffer is kept and `offset` tracks the end of the last complete line plus one.
6. Empty lines are skipped.

Backpressure: `records` is an `AsyncStream` with `bufferingPolicy: .unbounded`; the consumer (registry) is fast and single-purpose, and a transcript burst is at most tens of lines. The 1 MiB cap per wake bounds memory for the pathological case of a `file-history-snapshot` line, which can be hundreds of KiB.

### 5.3 Partial lines

Claude Code writes a whole line in one `write(2)` in normal operation, but a reader can still observe a partial line if a wake lands mid-write for a line larger than the pipe buffer. The partial-line buffer handles this. A partial line older than 5 s that still has not been completed is logged at `.warning` and kept; it is never parsed.

### 5.4 Replacement and truncation

- **Inode changed** (file deleted and recreated, or atomically replaced): close, reopen, set `offset = 0`, then read to EOF **but** emit only records whose `timestamp` is after the tailer's `attachedAt`. This handles a tool that rewrites the transcript while preserving the lines Claudio has not yet seen.
- **Truncated** (`st_size < offset`): same as replacement without reopening.
- **File removed** and not recreated within 60 s: the tailer emits end-of-stream and the registry marks the session `ended`.

### 5.5 Idle handles

A tailer with no wake for 10 minutes closes its descriptor (`FileHandle.close()`) and reopens on the next wake, re-validating the inode. This keeps the open-file count proportional to active sessions rather than to the 24 h window.

### 5.6 `peekTitle`

Reads the last 64 KiB of the file, splits on `\n`, scans backwards for a line starting with `{"type":"ai-title"` and decodes `aiTitle`. Returns `nil` if none. Used only by the initial scan.

Tests: `TranscriptTailerTests.testAttachesAtEOFAndEmitsNothing`, `testEmitsOnlyCompleteLines`, `testPartialLineCompletedAcrossWakes`, `testTruncationResetsAndSkipsOldTimestamps`, `testInodeReplacementReopens`, `testLargeLineReadAcrossOneMiBCap`, `testPeekTitleFindsLastTitle`.

## 6. `TurnAssembler`

```swift
// Transcript/TurnAssembler.swift
public enum TurnEvent: Sendable, Equatable {
    case turnStarted(TurnID, promptText: String, at: Date)
    case item(SpeechItem)
    case turnEnded(TurnID, at: Date, reason: TurnEndReason)
    case statusChanged(SessionStatus)
    case titleChanged(String)
    case permissionModeChanged(String)
    case cwdObserved(URL)
    case entrypointObserved(SessionEntrypoint)
    case subagentStarted(agentID: String, description: String)
    case subagentFinished(agentID: String, description: String)
}
public enum TurnEndReason: String, Sendable { case completed, interruptedByPrompt, hookStop, hookStopFailure, sessionEnded }

public actor TurnAssembler {
    public init(sessionID: SessionID, clock: Clock, log: Log)
    public func ingest(_ record: TranscriptRecord) -> [TurnEvent]
    public func ingestSubagent(_ record: TranscriptRecord, agentID: String) -> [TurnEvent]
    public func ingestHook(_ event: HookEvent) -> [TurnEvent]       // document 04 §6
    public var openTurn: TurnID? { get }
}
```

One assembler per session. It keeps: `openTurn`, the `pendingTexts` of the current message (keyed by `message.id`), `lastAssistantMessageID`, a bounded set of seen `uuid`s (LRU 4096) for dedup, `toolNamesByUseID` (for result attribution), and `subagentDescriptions` (by `agentId`).

### 6.1 A turn starts

A `humanPrompt` payload starts a turn when all of the following hold:

- `envelope.isSidechain == false`
- `envelope.isMeta != true`
- `originKind == "human"` **or** `promptSource == "typed"` **or** both are absent and the content is a plain string (older Claude Code versions omit `origin`)

Claude-generated user records (skill expansions, `turnOrigin == "system"`, `isMeta: true`, `promptSource` of `command` or `skill`) do **not** start a turn and do **not** cancel speech. The hook equivalent is `UserPromptSubmit` with `is_continuation == false` (document 04 §6).

Effects, in order:

1. If `openTurn != nil` → emit `.turnEnded(openTurn, reason: .interruptedByPrompt)`. This is how an Escape interrupt followed by a new prompt is detected: Claude Code writes no turn-end marker when the user presses Escape, so the next prompt closes the turn.
2. `openTurn = promptId`; emit `.turnStarted(promptId, promptText, at: timestamp)`.
3. Emit `.statusChanged(.busy)`.

The `Arbiter` treats `.turnStarted` on the active session as the cancel trigger (document 01 §9).

### 6.2 Dedup of records

A record whose `uuid` is already in the seen set is dropped with a `.debug` log. This guards against the replacement path in §5.4 and against a hook and the tail reporting the same record.

### 6.3 Classifying assistant text: `finalAnswer` versus `narration`

The question is whether a text block is Claude talking to the user at the end of the turn, or Claude narrating before a tool call. Three signals, in priority order:

**Primary — `message.stop_reason`.** If the record's `message.stop_reason` is `end_turn`, `max_tokens` or `stop_sequence`, the text is a `finalAnswer`. If it is `tool_use`, the text is `narration`.

This is reliable because Claude Code does not stream blocks to the transcript. Measured on Claude Code 2.1.290 by tailing a live session with a 20 ms poller and recording wall-clock arrival per line: all per-block records of one assistant message arrive in the same write, 50–600 ms after the last block finished generating, while each record's `timestamp` field reflects when its block was generated (spans of 1–12 s within one message were observed). Every assistant record therefore carries the message's final `stop_reason`; in a 2,000-record session there were 45 `end_turn` records and zero records with a null `stop_reason`. The `turn_duration` record follows the final message's write by about 0.5 s.

Consequence for latency: the transcript exposes text at **message** granularity, not block granularity. Narration that precedes a tool call becomes visible when the `tool_use` block has finished generating, which for a long `Bash` heredoc was 11 s after the narration text itself was generated. Final answers are visible when the message ends. This is the floor for transcript-only mode; the `MessageDisplay` hook (document 04 §1) fires while text is still streaming and is the only way to beat it.

**Secondary — position.** If `stop_reason` is `null` or absent (not observed on 2.1.290; guards against a future Claude Code that streams blocks to the file), the text is held as **pending** with category undetermined. It is resolved when the next record for the same session arrives:
- another block with the same `message.id` of type `tool_use` → pending texts of that message are `narration`;
- a record with a different `message.id`, a `turnDuration`, a `humanPrompt`, or a `Stop` hook → pending texts are `finalAnswer`.
Pending text is also force-resolved as `finalAnswer` after 1.5 s of silence (clock-driven, so speech is not delayed indefinitely when the primary signal is missing).

**Tertiary — tool_use in the same message.** Independently of the above, a text block that is followed by a `tool_use` block with the same `message.id` is always `narration`, even if `stop_reason` says otherwise. This guards against a mid-message `stop_reason` of `end_turn` on a message that also contains tools (not observed, but cheap).

`Fixtures/transcripts/stop-reason-populated/` holds a 3-block message captured from the installed Claude Code, and `stop-reason-absent/` the same records with `stop_reason` nulled, and `TurnAssemblerTests.testStopReasonIsPresentOnEveryBlockOfCapturedFixture` asserts the primary path applies to it. The test is marked as a **behaviour probe**: when a new Claude Code version changes the file-writing strategy, this test is the one that fails, and the secondary path is what the app then relies on. The suite also has `testSecondaryClassificationWhenStopReasonAbsent` which runs the same fixture with `stop_reason` stripped.

Both categories produce one `SpeechItem` per text block (`sourceUUID = record uuid`, `turnID = openTurn`). Text blocks inside an **open** turn whose `promptId` differs from `openTurn` are attributed to `openTurn` anyway (Claude Code sets `promptId` on assistant records inconsistently across versions); text blocks arriving with **no** open turn (Claudio launched mid-turn) open a synthetic turn `"orphan-<message.id>"` so they are still spoken and so `turnEnded` has something to close.

An empty or whitespace-only text block produces no item.

### 6.4 A turn ends

`.turnEnded(openTurn, reason: .completed)` is emitted when a `turnDuration` record arrives and `openTurn != nil`. `openTurn` becomes `nil`. Status becomes `.idle`. Pending texts (secondary path) are flushed as `finalAnswer` first.

If `turnDuration` arrives with no open turn (Claudio launched during the turn and never saw the prompt, and no assistant block arrived either), nothing is emitted.

`stopHookSummary` is ignored for turn logic; it only feeds diagnostics.

### 6.5 Tool calls

An `assistantToolUse` payload produces a `toolCall` item whose `text` is `ToolCallSummarizer.summarize(name:input:)` (rules in document 05 §3). `toolNamesByUseID[toolUseID] = name` is recorded for result attribution. Two tools are special:

- `Task` / `Agent` (subagent dispatch): `text` is "Agent started: <description>", and `subagentDescriptions[…]` is not yet known because the `agentId` only appears in the subagent file; the description is stored keyed by `toolUseID` and matched when the subagent's first record arrives (its `promptId` and the parent's `promptId` match, and the subagent `.meta.json` carries the description). Emits `.subagentStarted` as well.
- `Skill`: `text` is "Using skill <name>".

### 6.6 Tool results

A `toolResult` payload produces a `toolResult` item only when it indicates an error:

- `message.content[].is_error == true`, or
- `toolUseResult` is an object with `success == false`, or contains a top-level `error` string, or `interrupted == true`, or
- `message.content[].content` is a string beginning with `Error:` or containing `command not found`, `No such file`, `Permission denied`, `exit code` followed by a non-zero number.

The item's `text` is "<ToolName> failed: <first line of the error, at most 120 characters>". Tool name comes from `toolNamesByUseID`, else "Tool". Non-error results produce nothing. Any tool result moves a `waiting` status back to `busy`.

### 6.7 Thinking

`assistantThinking` produces a `thinking` item with the raw text, or nothing if the text is empty (Claude Code frequently writes a thinking block with an empty `thinking` string and a `signature`).

### 6.8 Other records

| Payload | Event |
|---------|-------|
| `aiTitle(t)` | `.titleChanged(t)` |
| `permissionMode(m)` | `.permissionModeChanged(m)` |
| any record with `cwd` | `.cwdObserved(URL)` once per distinct value |
| any record with `entrypoint` | `.entrypointObserved(…)` once |
| `hookAttachment` with `claudio hook` in command | `.debug` log only |
| `ignored`, `unknown` | nothing |

Tests: `TurnAssemblerTests.testHumanPromptStartsTurn`, `testSkillPromptDoesNotStartTurn`, `testMetaUserRecordIgnored`, `testToolResultDoesNotStartTurn`, `testNewPromptClosesOpenTurnAsInterrupted`, `testEndTurnStopReasonIsFinalAnswer`, `testToolUseStopReasonIsNarration`, `testTextFollowedByToolUseIsNarration`, `testStopReasonIsPresentOnEveryBlockOfCapturedFixture`, `testSecondaryClassificationWhenStopReasonAbsent`, `testPendingTextForceResolvedAfterSilence`, `testTurnDurationEndsTurn`, `testOrphanTextOpensSyntheticTurn`, `testToolResultErrorProducesItem`, `testToolResultSuccessProducesNothing`, `testEmptyThinkingProducesNothing`, `testDuplicateUUIDDropped`, `testAITitleEmitsTitleChanged`.

## 7. Subagents

A subagent transcript is tailed like a main transcript, and every record is passed to the **parent** session's assembler via `ingestSubagent(record, agentID:)`. The assembler:

1. On the first record for a new `agentID`: reads `<…>/subagents/agent-<id>.meta.json` (fields `description`, `agentType`, `createdAt`; all optional) and stores the description. If absent, it uses the first 80 characters of the subagent's first `user` record's content. Emits `.subagentStarted(agentID, description)` **only if** no `toolCall` "Agent started" item was already emitted for the matching `Task` tool use (matched by `promptId` and arrival order); otherwise it just binds the description.
2. Ignores `assistantText`, `assistantThinking`, `toolResult` from the subagent entirely. Subagent narration is never spoken.
3. Counts `assistantToolUse` for the popover's activity indicator but emits no item.
4. On the subagent's `turnDuration`, or on a `SubagentStop` hook with the same `agent_id`, emits `.subagentFinished(agentID, description)` and a `toolCall` item "Agent finished: <description>". If both arrive, the second is deduplicated by `agentID`.

Subagent records never start or end the parent's turn and never change the parent's status.

Tests: `TurnAssemblerTests.testSubagentNarrationIgnored`, `testSubagentFinishEmitsToolCall`, `testSubagentDescriptionFromMeta`, `testSubagentDescriptionFallsBackToPrompt`.

## 8. `Session` and `SessionRegistry`

```swift
// Sessions/SessionRegistry.swift
public actor SessionRegistry {
    public init(discovery: SessionDiscovery, probe: LiveAgentsProbe, store: SessionStateStore,
                settings: AppSettings, projectPrefs: ProjectPreferences, clock: Clock, log: Log)
    public var sessions: [Session] { get }
    public var changes: AsyncStream<RegistryChange> { get }      // for UI
    public var speechEvents: AsyncStream<RegistryEvent> { get }  // for Arbiter
    public func setLevel(_ level: SpeechLevel, for id: SessionID)
    public func markTurnRead(_ turn: TurnID, in id: SessionID)
    public func resolve(_ query: String) -> Session?               // for CLI `switch`
    public func ingestHook(_ event: HookEvent)
    public func start()
}
public enum RegistryEvent: Sendable {
    case item(SpeechItem)
    case turnStarted(SessionID, TurnID)
    case turnEnded(SessionID, TurnID, finalAnswerText: String?)
    case statusChanged(SessionID, SessionStatus)
    case sessionAppeared(SessionID), sessionEnded(SessionID), sessionRemoved(SessionID)
}
```

### 8.1 Creation

A session is created when discovery reports a main transcript for an unknown `sessionID`, or when a `SessionStart` hook arrives for an unknown id, or when `LiveAgentsProbe` lists an unknown id (the registry then looks for the transcript at `<root>/projects/<encoded cwd>/<id>.jsonl` across roots). On creation the registry:

- allocates a `TranscriptTailer` (and later, one per subagent file) and a `TurnAssembler`;
- sets `level` from `ProjectPreferences.defaultLevel(forCwd:)` if present, else `.answers`;
- sets `colorIndex = stableHash(sessionID) % 8` (FNV-1a 64 over the UTF-8 bytes);
- sets `title` to the folder name of the project directory until an `ai-title` is seen;
- emits `.sessionAppeared`.

### 8.2 Naming

Priority: `ai-title` record → `session_title` from a `SessionStart` hook → `name` from `claude agents --json` (e.g. `claudio-a7`) → last path component of `cwd` → first 8 characters of the session id.

When two live sessions have the same display title, both are suffixed with ` (<folder>)`; if the folders also match, with ` (<id prefix>)`. The suffix is recomputed on every title change.

### 8.3 Entrypoint

`entrypoint` from the records: `cli` → `.cli`, `claude-desktop` → `.claudeDesktop`. `.orca` is best-effort: the registry marks a `.cli` session as `.orca` when its `cwd` is under a path listed in Settings → Orca worktree roots, or when `claude agents --json` reports the session and `/proc`-style inspection is unavailable on macOS so the registry instead checks whether the process's parent is an `Orca` application (`proc_pidinfo` / `sysctl KERN_PROC_PID` to walk `ppid` up to three levels looking for a process named `Orca` or `Orca Helper`). Entrypoint only affects the icon shown in the popover; no behaviour depends on it.

### 8.4 Status

Applied from `TurnEvent.statusChanged` and from hooks (document 04 §6). The transitions are those of document 02 §7.1. A `.waiting` status is also entered from the transcript when a `Notification` hook is not installed: there is no transcript record for a permission prompt, so without hooks a session blocked on permission looks `busy`. This is documented in the popover as "status precision requires hooks".

### 8.5 Liveness

- `lastActivity` is the latest record `timestamp` (or wall clock if absent), or the latest hook arrival.
- `LiveAgentsProbe` runs `claude agents --json` every 10 s (configurable, `liveAgentsProbeInterval`) with a 3 s timeout using `Process` with `PATH` extended by `/opt/homebrew/bin:/usr/local/bin:~/.local/bin`. It parses the array into `[LiveAgent]` (`pid`, `cwd`, `kind`, `startedAt`, `sessionId`, `name`, `status`). For each known session: fill `pid`, update `title` fallback, and map `status` `busy|waiting|idle` onto the session only when the transcript-derived status is `idle` or `busy` (hooks and transcript win over the probe for `waiting`). A session that was listed on the previous probe and is absent now, and whose transcript has not changed in the last 5 s, is marked `.ended`. If the probe fails three times in a row (command missing, timeout, non-zero exit, invalid JSON) it logs once at `.error`, backs off to 60 s, and the registry falls back to the transcript-only rules.
- A session (in any status) whose `lastActivity` is older than 24 h is removed and `.sessionRemoved` is emitted. The check runs every minute.

### 8.6 Resumed sessions

`claude --resume` appends to the existing file. If Claudio already has the session, nothing special happens: the tailer's offset is at the previous EOF. If the session had been removed (older than 24 h), discovery reports the file change, a new session is created, and the tailer attaches at EOF, so only new records are spoken. A `SessionStart` hook with `source == "resume"` refreshes the title and `lastActivity`.

### 8.7 `sessions.json`

```swift
public struct SessionStateStore { func load() -> [PersistedSession]; func save(_: [PersistedSession]) }
public struct PersistedSession: Codable {
    let id: SessionID, title: String, cwd: String, transcriptPath: String, root: String
    let level: SpeechLevel, colorIndex: Int, lastActivity: Date, entrypoint: SessionEntrypoint
    let unreadTurns: [PersistedUnreadTurn]       // ordered oldest first, max 5
}
public struct PersistedUnreadTurn: Codable { let turnID: TurnID; let endedAt: Date; let finalAnswerText: String }
```

Written atomically (temp + rename) at most once per 2 s when anything changes, and on quit. On launch, sessions younger than 24 h are restored with their level, colour, title and unread turns, so a catch-up on a session that finished while Claudio was not running still works. Not persisted: `status` (recomputed), `pid`, `currentTurn`, in-flight items, tailer offsets (attach at EOF is the rule).

### 8.8 Turn bookkeeping for catch-up

On `.turnEnded(turn, reason: .completed)` for a session, the registry collects the turn's `finalAnswer` items (in order, concatenated with a blank line) and, if the session is not active or the Arbiter reports the answer was not voiced, appends `(turn, text)` to `unreadTurns` (capped at 5, oldest dropped). `markTurnRead` removes entries. Turns ended with `.interruptedByPrompt` and no final answer are not recorded.

Tests: `SessionRegistryTests.testCreatesSessionOnDiscovery`, `testTitlePriority`, `testDuplicateTitlesSuffixed`, `testColorIndexStable`, `testLevelDefaultFromProjectPreferences`, `testProbeFillsPidAndMarksEnded`, `testProbeFailureBacksOff`, `testExpiryAt24Hours`, `testPersistRestoreUnreadTurns`, `testResumeDoesNotReplay`, `testUnreadCappedAtFive`.

## 9. Hook and transcript reconciliation

With hooks installed, most turn boundaries are learned twice. The registry merges them in the assembler using these rules, keyed by `(sessionID, turnID, kind)` where `turnID` is `promptId` (transcript) or `prompt_id` (hook), which are the same UUID:

| Kind | Transcript source | Hook source | Rule |
|------|-------------------|-------------|------|
| turn start | human `user` record | `UserPromptSubmit` | First one wins; second within 10 s is dropped. Cancel fires on the first. |
| turn end | `turnDuration` | `Stop` / `StopFailure` | First one wins; second within 30 s is dropped. |
| final answer text | `finalAnswer` items | `Stop.last_assistant_message` | If the transcript already emitted a `finalAnswer` for this turn whose text, after whitespace normalisation, is a prefix or equal of `last_assistant_message`, the hook text is dropped. Otherwise (transcript lagging), the hook text is emitted as a `finalAnswer` item with `sourceUUID = "hook:<prompt_id>"`, and any transcript `finalAnswer` for the same turn arriving within the next 30 s is dropped. |
| status waiting | — | `Notification` | Hook only. |
| session start/end | first record / file removed / probe | `SessionStart` / `SessionEnd` | Union; `SessionEnd` is authoritative for `.ended`. |
| subagent finished | subagent `turnDuration` | `SubagentStop` | First wins, keyed by `agentID`. |

Hook `prompt_id` is absent on `SessionStart`/`SessionEnd`; those events are keyed by session only. Dedup windows are measured with `Clock` so tests can drive them.

Tests: `ReconciliationTests.testHookStartThenTranscriptStartSpeaksOnce`, `testTranscriptStopThenHookStopEndsOnce`, `testHookFinalAnswerDroppedWhenTranscriptAlreadyEmitted`, `testHookFinalAnswerUsedWhenTranscriptLags`, `testLateTranscriptFinalAnswerDroppedAfterHookText`.

## 10. Failure modes and logging

Logger subsystem `com.jdforsythe.claudio`, category `ingest` (discovery, tailer, parser) and `sessions` (assembler, registry, probe).

| Condition | Level | Message shape | Behaviour |
|-----------|-------|---------------|-----------|
| Root missing at start | `.notice` | `root <path> has no projects dir; watching parent` | Watch parent, switch later |
| FSEvents stream failed | `.error` | `fsevents start failed for <root>` | Retry every 30 s; Settings badge |
| Malformed line | `.warning` | `malformed line at <offset> in <file>: <prefix>` | Skip line |
| Unknown record type | `.info` once per type/session | `unknown record type <t>` | Ignore |
| Partial line > 5 s | `.warning` | `partial line stuck in <file>` | Keep buffering |
| Inode changed | `.notice` | `transcript replaced <file>` | Reopen, skip old timestamps |
| File removed 60 s | `.notice` | `transcript gone <file>` | Session ended |
| Probe failure ×3 | `.error` once | `claude agents probe failing: <reason>` | Back off |
| Orphan assistant text | `.info` | `orphan text, synthetic turn <id>` | Speak it |
| Pending text force-resolved | `.debug` | `stop_reason absent; resolved by timeout` | Final answer |
| Dedup drop | `.debug` | `dropped duplicate <kind> for <turn> from <source>` | — |
| Every `TurnEvent` | `.info` | `<session> <event>` | — |

Metrics (`TranscriptParser.Metrics`, tailer bytes read, records per second, probe latency) are exposed through `claudio status --json` (document 04 §7) for diagnosis.

## 11. Test inventory

All tests live in `Tests/ClaudioCoreTests/` and use fixtures from `Tests/Fixtures/transcripts/`. Fixtures are real transcripts from this machine with prompt text, tool inputs and tool outputs replaced by lorem text of the same length, preserving every structural field. Fixture set:

| Fixture | Contents | Used by |
|---------|----------|---------|
| `single-turn-final-only.jsonl` | prompt → text(end_turn) → turn_duration | assembler basics |
| `single-turn-with-tools.jsonl` | prompt → thinking → text → tool_use → tool_result → text(end_turn) → turn_duration | classification |
| `stop-reason-populated/` | the captured 3-block message, raw and with `stop_reason` nulled | behaviour probe |
| `interrupted-by-escape.jsonl` | prompt → text → tool_use → (no turn_duration) → prompt | interrupt detection |
| `skill-expansion.jsonl` | human prompt → `promptSource: skill` user record → … | non-human prompts |
| `tool-error.jsonl` | tool_use → tool_result with `is_error` and with `toolUseResult.success:false` | tool result errors |
| `with-subagents/` | main transcript plus two `subagents/agent-*.jsonl` and `.meta.json` | subagent folding |
| `resumed.jsonl` | two sessions' worth of turns separated by a `SessionStart:resume` attachment | resume |
| `file-history-snapshot.jsonl` | one 400 KiB snapshot line between normal records | parser short-circuit, 1 MiB cap |
| `unknown-types.jsonl` | records with invented `type` values | tolerance |
| `claude-desktop.jsonl` | `entrypoint: claude-desktop` | entrypoint |
| `agents-json/*.json` | `claude agents --json` outputs: normal, empty, `--all` with completed, malformed | probe |

Named tests are listed at the end of each section above. Document 09 defines how fixtures are refreshed when Claude Code changes.
