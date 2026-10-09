# 02 — Architecture

This document is the contract between all other documents. Type, module and file names used here are the canonical names in code. If a later document conflicts with this one, this one wins and the other is wrong.

## 1. Process model

Claudio is two executables sharing one Swift package.

```
┌──────────────────────────────────────────────────────────────────┐
│ Claudio.app (ClaudioApp executable, LSUIElement, runs at login)  │
│                                                                  │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────────────────┐  │
│  │ SessionDisc. │→ │ SessionReg.  │→ │ Arbiter                │  │
│  │ (FSEvents)   │  │ (actor)      │  │ (actor)                │  │
│  └──────────────┘  └──────────────┘  └───────────┬────────────┘  │
│         ↑                 ↑                      ↓               │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────────────────┐  │
│  │ Transcript   │  │ ControlServer│  │ SpeechPipeline         │  │
│  │ Tailer ×N    │  │ (unix sock)  │  │ render→segment→synth   │  │
│  └──────────────┘  └──────┬───────┘  │ →PlaybackEngine        │  │
│                           │          └───────────┬────────────┘  │
│  ┌────────────────────────┴───────┐  ┌───────────┴────────────┐  │
│  │ UI: MenuBar, Popover, HUD,     │  │ TTSBackend: Edge,      │  │
│  │ Settings, Hotkeys              │  │ Apple, OpenAI, Fallback│  │
│  └────────────────────────────────┘  └────────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘
          ▲ NDJSON over ~/Library/Application Support/Claudio/claudio.sock
          │
┌─────────┴──────────────────────────────────────────────────────┐
│ claudio (ClaudioCLI executable, inside Claudio.app/Contents/MacOS)│
│   claudio hook      ← executed by Claude Code for each hook event│
│   claudio <command> ← user / skill / scripts                     │
└────────────────────────────────────────────────────────────────┘
```

- **ClaudioApp** owns all state. It is the only process that touches audio.
- **ClaudioCLI** is stateless. `claudio hook` reads one JSON object from stdin, connects to the socket, writes one line, exits. Every other subcommand sends a request and prints the response. If the socket does not exist or the connection is refused, `claudio hook` exits 0 silently (Claude Code must never see a hook error because Claudio is not running); other subcommands exit 1 with "Claudio is not running".

There is no daemon separate from the app. Quitting the app stops everything. "Launch at login" is a `SMAppService` login item.

## 2. Package targets

| Target | Kind | Depends on | Purpose |
|--------|------|------------|---------|
| `ClaudioControlProtocol` | library | Foundation only | The `ControlEnvelope`, `ControlRequest`, `ControlResult`, `StatusReport`, `SessionSummary` and `HookEvent` Codable types shared by the app and the CLI. Deliberately tiny so the CLI never links AVFoundation. |
| `ClaudioCore` | library | ClaudioControlProtocol, Foundation, AVFoundation (for `AVAudioPCMBuffer` only), os | Transcript model and parsing, session registry, arbiter, speech text rendering, segmentation, scheduling, playback engine, control server, settings model. No AppKit, no SwiftUI. |
| `ClaudioBackends` | library | ClaudioCore, AVFoundation, AudioToolbox | `TTSBackend` implementations: `EdgeTTSBackend`, `AppleSpeechBackend`, `OpenAITTSBackend`, `FallbackBackend`, plus `VoiceCatalog`. |
| `ClaudioApp` | executable | ClaudioCore, ClaudioBackends, AppKit, SwiftUI, ServiceManagement, [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) | The menu bar app. Composition root in `ClaudioApp.swift`. |
| `ClaudioCLI` | executable (product name `claudio`) | ClaudioControlProtocol, [swift-argument-parser](https://github.com/apple/swift-argument-parser) | CLI and hook receiver. Must start in under 20 ms; it must not link ClaudioCore, AVFoundation or AppKit. |
| `ClaudioCoreTests` | test | ClaudioCore | Unit tests with fixtures. |
| `ClaudioBackendsTests` | test | ClaudioBackends | Protocol conformance tests, Edge wire-protocol tests against a local mock WebSocket server, Apple backend smoke tests. |
| `ClaudioIntegrationTests` | test | all | End-to-end: synthetic transcript writer → pipeline → `RecordingPlaybackSink`. |

External dependencies are limited to the two above. Everything else is Apple frameworks.

## 3. Module map inside `ClaudioCore`

```
Sources/ClaudioCore/
├── Transcript/
│   ├── TranscriptRecord.swift        # Decodable envelope + typed payloads
│   ├── TranscriptParser.swift        # line → TranscriptRecord, tolerant
│   ├── TranscriptTailer.swift        # one file → AsyncStream<TranscriptRecord>
│   ├── SessionDiscovery.swift        # FSEvents on roots → file appeared/changed
│   ├── ProjectPathEncoding.swift     # cwd ⇄ ~/.claude/projects/<encoded>
│   └── TurnAssembler.swift           # records → Turn + SpeechItem events
├── Sessions/
│   ├── Session.swift                 # model
│   ├── Turn.swift
│   ├── SpeechItem.swift              # + ContentCategory
│   ├── SpeechLevel.swift
│   ├── SessionRegistry.swift         # actor: all sessions, liveness, names
│   ├── LiveAgentsProbe.swift         # `claude agents --json` poller
│   └── SessionNaming.swift           # title, colour assignment
├── Arbitration/
│   ├── Arbiter.swift                 # actor: active session, interrupts, catch-up
│   ├── CatchUpPlan.swift
│   └── ArbiterEvent.swift
├── Speech/
│   ├── ContentFilter.swift           # level + toggles → include?
│   ├── SpeechTextRenderer.swift      # markdown → Utterance (segments)
│   ├── MarkdownSpeechRules.swift     # the table of rewrite rules
│   ├── SentenceSegmenter.swift
│   ├── ToolCallSummarizer.swift      # tool_use → short phrase
│   ├── Utterance.swift               # segments, skip units, source refs
│   ├── SynthesisScheduler.swift      # lookahead synthesis, cancel tokens
│   ├── PlaybackEngine.swift          # AVAudioEngine wrapper, gapless, fade
│   ├── PlaybackSink.swift            # protocol; real engine + recording sink
│   └── SpeechPipeline.swift          # wires filter→render→segment→schedule→play
├── Backends/
│   ├── TTSBackend.swift              # protocol + SynthesisRequest/Event
│   ├── Voice.swift
│   └── BackendError.swift
├── Control/
│   ├── ControlServer.swift           # unix socket listener (app side)
│   ├── HookEventMapper.swift         # HookEvent → TurnEvent
│   └── HookInstaller.swift           # settings.json merge/remove
│   (Codable wire types live in Sources/ClaudioControlProtocol/:
│    ControlEnvelope.swift, ControlRequest.swift, ControlResult.swift,
│    StatusReport.swift, SessionSummary.swift, HookEvent.swift, ControlClient.swift,
    and the generated BuildInfo.swift with version and git sha, written by the Makefile)
├── Settings/
│   ├── AppSettings.swift             # UserDefaults-backed, observable
│   ├── ProjectPreferences.swift      # per-project defaults JSON store
│   └── Paths.swift                   # all filesystem locations
└── Support/
    ├── Log.swift                     # os.Logger categories
    ├── Clock.swift                   # injectable time
    └── AsyncExtras.swift
```

## 4. Canonical types

These signatures are normative. Fields may be added; names and semantics here may not change without updating this document and the decision log.

```swift
// Sessions/SpeechLevel.swift
public enum SpeechLevel: String, Codable, CaseIterable, Sendable {
    case quiet, answers, narrate
}

// Sessions/SpeechItem.swift
public enum ContentCategory: String, Codable, Sendable {
    case finalAnswer, narration, toolCall, toolResult, thinking, event
}

public struct SpeechItem: Identifiable, Sendable, Equatable {
    public let id: UUID                 // Claudio-assigned
    public let sessionID: SessionID
    public let turnID: TurnID?          // nil for session-level events
    public let category: ContentCategory
    public let text: String             // raw text (markdown for answers/narration; phrase for toolCall/event)
    public let sourceUUID: String?      // transcript record uuid, for dedup with hooks
    public let timestamp: Date
    public let isCatchUp: Bool          // true when emitted by a CatchUpPlan
}

public typealias SessionID = String     // Claude's sessionId
public typealias TurnID = String        // Claude's promptId

// Sessions/Session.swift
public enum SessionStatus: String, Codable, Sendable {
    case busy        // a turn is in progress
    case waiting     // Claude asked for permission or input
    case idle        // no turn in progress
    case ended       // SessionEnd seen or process gone; still listed until expiry
}

public enum SessionEntrypoint: String, Codable, Sendable {
    case cli, claudeDesktop, orca, unknown
}

public struct Session: Identifiable, Sendable, Equatable {
    public let id: SessionID
    public var title: String            // from ai-title record, else folder name
    public var cwd: URL
    public var transcriptURL: URL
    public var entrypoint: SessionEntrypoint
    public var status: SessionStatus
    public var level: SpeechLevel
    public var colorIndex: Int          // stable per session, 0..<8
    public var lastActivity: Date
    public var unreadTurns: [TurnID]    // completed, final answer unspoken
    public var currentTurn: TurnID?
    public var pid: Int32?              // from LiveAgentsProbe when available
    public var permissionMode: String?  // from permission-mode records; display only
}

// Backends/TTSBackend.swift
public struct SynthesisRequest: Sendable {
    public let id: UUID                 // correlates metrics and fallback decisions per request
    public let text: String             // one chunk, plain text, ≤ 2000 UTF-8 bytes
    public let voice: Voice
    public let rate: Double             // 1.0 = normal; 0.5...2.0
    public let wantsWordBoundaries: Bool
}

public enum SynthesisEvent: Sendable {
    case audio(AVAudioPCMBuffer)        // Float32, mono, 24_000 Hz, non-interleaved
    case wordBoundary(textRange: Range<String.Index>, audioOffset: TimeInterval, duration: TimeInterval)
    case finished
}

public protocol TTSBackend: Sendable {
    var id: BackendID { get }           // "edge", "apple", "openai"
    var displayName: String { get }
    var supportsWordBoundaries: Bool { get }
    func voices() async throws -> [Voice]
    func synthesize(_ request: SynthesisRequest) -> AsyncThrowingStream<SynthesisEvent, Error>
    // Cancellation is cooperative: cancelling the Task consuming the stream must abort network/engine work promptly.
}

public struct Voice: Codable, Hashable, Sendable {
    public let backend: BackendID
    public let id: String               // backend-native identifier
    public let displayName: String
    public let locale: String           // BCP-47
    public let gender: String?
    public let quality: String?         // "premium" / "enhanced" / nil
}

// Speech/Utterance.swift
public struct Utterance: Sendable {
    public let item: SpeechItem
    public var segments: [Segment]
    public struct Segment: Sendable, Identifiable {
        public let id: UUID
        public let text: String          // speakable plain text
        public let kind: Kind            // .sentence, .tableRow, .listItem, .heading, .cue
        public enum Kind: Sendable { case sentence, tableRow, listItem, heading, cue }
    }
}

// Speech/PlaybackSink.swift
public protocol PlaybackSink: AnyObject, Sendable {
    func enqueue(_ buffer: AVAudioPCMBuffer, segmentID: UUID) async
    func markSegmentEnd(_ segmentID: UUID) async
    func pause() async
    func resume() async
    func cancelAll(fade: TimeInterval) async      // drops everything queued and playing
    func skipSegment(_ segmentID: UUID, fade: TimeInterval) async
    var events: AsyncStream<PlaybackEvent> { get }  // .segmentStarted(id), .segmentFinished(id), .position(id, TimeInterval), .drained
}
```

## 5. Data flow, end to end

1. **Discovery.** `SessionDiscovery` watches each configured root (`~/.claude/projects` by default) with FSEvents (`kFSEventStreamCreateFlagFileEvents`, latency 0.1 s). It emits `.fileChanged(URL)` for `*.jsonl` files whose path matches `<root>/<project>/<uuid>.jsonl` or `<root>/<project>/<uuid>/subagents/agent-<id>.jsonl`.
2. **Tailing.** `SessionRegistry` creates one `TranscriptTailer` per main transcript on first sight. A tailer opens the file, seeks to end-of-file on first attach (never replays history), and on each change event reads from its saved offset to the new end, splitting on `\n`. Partial trailing lines are buffered until completed. Inode change or truncation resets the offset to 0 then to the current end, as appropriate (see document 03). Each complete line goes through `TranscriptParser`.
   Claude Code writes all per-block records of one assistant message in a single append when the message completes (measured on 2.1.290, document 03 §6.3), so a wake typically delivers a whole message's blocks at once, each already carrying the final `stop_reason`.
3. **Parsing.** `TranscriptParser` decodes the line into a `TranscriptRecord`. Unknown `type` values become `.unknown(type)` and are counted, not dropped as errors. Decoding is deliberately tolerant: every field is optional except `type`.
4. **Turn assembly.** `TurnAssembler` (one per session) consumes records and emits `TurnEvent`s: `.turnStarted(TurnID, promptText)`, `.item(SpeechItem)`, `.turnEnded(TurnID, TurnEndReason)`, `.statusChanged(SessionStatus)`, `.titleChanged(String)`, `.subagentStarted(agentID, description)`, `.subagentFinished(agentID)`, `.cwdObserved(URL)`, `.entrypointObserved(SessionEntrypoint)`, `.permissionModeChanged(String)`. `TurnEndReason` is `.completed`, `.interruptedByPrompt`, `.hookStop`, `.hookStopFailure`, `.sessionEnded`. Document 03 defines each. Classification of `text` blocks into `finalAnswer` versus `narration` is described in document 03 §6.
5. **Registry.** `SessionRegistry` applies `TurnEvent`s to `Session` state, maintains liveness (24 h expiry, `LiveAgentsProbe` for `pid` and `ended`), and forwards `SpeechItem`s and status changes to the `Arbiter`. It also receives `HookEvent`s from `ControlServer` and converts them into the same `TurnEvent`s, deduplicating against transcript-derived events by `(sessionID, turnID, kind)` (see document 03 §9).
6. **Arbitration.** `Arbiter` holds `activeSessionID`, applies the policies of document 01 §7–9, and produces an ordered stream of `Utterance` requests to the `SpeechPipeline`: live items of the active session filtered by `ContentFilter`, event announcements from any session, and `CatchUpPlan` output when switching. It issues `cancelSession(id)`, `cancelAll`, `skipSegment`, `skipToLive`.
7. **Rendering.** `SpeechPipeline` runs `SpeechTextRenderer` on each `SpeechItem` to produce an `Utterance` of `Segment`s.
8. **Scheduling.** `SynthesisScheduler` keeps at most `lookahead` (default 2) segments synthesized ahead of the segment currently playing. For each segment it creates a `Task` calling `backend.synthesize`, forwards `.audio` buffers to the `PlaybackSink` tagged with the segment id, and records word boundaries for the captions. Cancellation cancels the tasks and calls `sink.cancelAll`.
9. **Playback.** `PlaybackEngine` (the production `PlaybackSink`) owns one `AVAudioEngine` with one `AVAudioPlayerNode` → `mainMixerNode` → output. Buffers are scheduled back-to-back with `scheduleBuffer(_:completionCallbackType: .dataPlayedBack)`. A segment boundary is just a marker; there is no stop/start between segments, so there is no gap. Cancel sequence: ramp `playerNode.volume` from its current value to 0 over 15 ms in 1 ms steps on the engine's serial queue, then `playerNode.stop()`, `playerNode.reset()`, restore `volume`, `playerNode.play()`. Already-scheduled buffers are discarded by `reset()`. See document 05 §7 for the exact sequence and the click test that verifies it.
10. **UI.** The app observes `SessionRegistry`, `Arbiter` and `SpeechPipeline` published state through `@Observable` view models on the main actor. The HUD receives `PlaybackEvent.position` and word boundaries to highlight the current word.
11. **Control.** `ControlServer` accepts `ControlRequest`s (from `claudio` CLI, hooks, the skill) and dispatches them to the registry, arbiter or pipeline. Responses are `ControlResponse`.

## 6. Concurrency model

- Swift 6 language mode, strict concurrency, no `@unchecked Sendable` outside `PlaybackEngine` (which wraps non-Sendable AVFoundation objects and documents its invariants).
- `SessionRegistry`, `Arbiter`, `SynthesisScheduler` are `actor`s. `PlaybackEngine` is a `final class` with an internal serial `DispatchQueue` because AVAudioEngine callbacks arrive on its own threads.
- One `TranscriptTailer` per transcript file, each an `AsyncStream` producer running on a background task; file reads are synchronous `FileHandle` reads of at most 1 MiB per wake.
- The UI layer is `@MainActor`. Core actors publish state changes through `AsyncStream`s that view models consume on the main actor.
- Cancellation is structured: every synthesis is a child `Task` of the scheduler's segment task; `Task.cancel()` propagates to `URLSessionWebSocketTask.cancel()` or `AVSpeechSynthesizer.stopSpeaking`.
- No global mutable state. The composition root constructs everything and injects dependencies. Tests construct the same graph with `RecordingPlaybackSink` and `MockBackend`.

## 7. State machines

### 7.1 Session status

```
          first record / SessionStart
                   │
                   ▼
   ┌────────────── idle ◀───────────────────────────────┐
   │               │ human user record / UserPromptSubmit│
   │               ▼                                     │
   │             busy ──── Notification(permission_prompt│idle_prompt│agent_needs_input)
   │               │              │                      │
   │               │              ▼                      │
   │               │           waiting ── next assistant record / PostToolUse ──▶ busy
   │               │ system turn_duration / Stop / StopFailure
   │               └─────────────────────────────────────┘
   │
   │ SessionEnd / pid gone (probe) 
   ▼
 ended ── 24 h since lastActivity ──▶ (removed)
 (any state) ── 24 h since lastActivity ──▶ (removed)
```

### 7.2 Arbiter playback mode

```
 idle ──activate(session)──▶ catchingUp(session, plan) ──plan drained | skipToLive──▶ live(session)
   ▲                                  │                                              │
   └──────────── deactivate ──────────┴──────────────────────────────────────────────┘
 live(session) ──switch(other)──▶ catchingUp(other, plan)
 any ── pause ──▶ paused(previous) ── resume ──▶ previous
```

Announcements (`event` items from any session) are injected in any mode except `paused`; they do not change mode.

### 7.3 Segment lifecycle

```
 pending → synthesizing → ready → playing → finished
     │          │           │        │
     └──────────┴───────────┴────────┴──── cancelled (by cancelAll, skipSegment, level drop, or prompt)
```

## 8. Filesystem locations (`Paths.swift`)

| Purpose | Path |
|---------|------|
| App bundle | `/Applications/Claudio.app` (or wherever the user puts it) |
| CLI binary | `<bundle>/Contents/MacOS/claudio` |
| Hook command written to settings.json | `<bundle>/Contents/MacOS/claudio hook` |
| Application Support | `~/Library/Application Support/Claudio/` |
| Control socket | `~/Library/Application Support/Claudio/claudio.sock` (if the absolute path exceeds the 104-byte `sockaddr_un` limit, `Paths` falls back to `/tmp/claudio-<uid>.sock` and both app and CLI apply the same rule; `CLAUDIO_SOCKET` overrides) |
| Per-project preferences | `~/Library/Application Support/Claudio/projects.json` (default level, optional display name and mute per project; document 08 §4) |
| Session state cache | `~/Library/Application Support/Claudio/sessions.json` |
| Log files (in addition to unified logging) | `~/Library/Logs/Claudio/claudio.log` (rotated, 5 × 5 MiB) |
| Settings | UserDefaults domain `com.jdforsythe.claudio` |
| Transcript roots (default) | `~/.claude/projects` |
| Claude settings (hooks, opt-in) | `~/.claude/settings.json` |
| Optional CLI symlink | `/usr/local/bin/claudio` |
| Optional skill | `~/.claude/skills/speak/SKILL.md` |

## 9. Cross-cutting rules

1. **Never block Claude Code.** The hook receiver must exit in under 20 ms regardless of app state. Hooks are installed with `"async": true`.
2. **Never replay history.** A tailer attaches at end-of-file. Catch-up uses in-memory `Turn`s accumulated since Claudio started, never re-reads old lines.
3. **Never write under `~/.claude` without the user enabling it.** Only `HookInstaller` and the skill installer touch it, and both are behind explicit toggles.
4. **Tolerate schema drift.** The parser never throws on unknown fields or types. Every classification heuristic has a fallback described in document 03, and the `Stop` hook's `last_assistant_message` is the authority for final answers when hooks are installed.
5. **Dedup at the item level.** The same final answer may be learned from the transcript and from the `Stop` hook; it is spoken once.
6. **All settings live.** Every setting is read at point of use or observed; nothing is captured at startup.
7. **Fail toward speech.** Backend errors degrade to the Apple backend; parser oddities degrade to speaking the raw text; UI errors never stop audio.
8. **Logs are the debugger.** Every state transition in §7 logs at `.info` with session id and turn id. Every dropped or deduplicated item logs at `.debug` with the reason.
