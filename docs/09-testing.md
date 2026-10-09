# 09 — Testing Strategy

This document is the index of every automated test in the repository and the manual QA procedure for each milestone. Documents 03–08 name tests using the same convention (the `ClaudioControlProtocol` target's wire types are tested in their own target, §3.13); when they and this document disagree on a name, this document is authoritative and the other is corrected.

## 1. Philosophy

Claudio is testable because of three architectural choices made in document 02:

1. **`ClaudioCore` is pure.** It has no AppKit, no SwiftUI, and touches AVFoundation only for the `AVAudioPCMBuffer` type. Every actor in the core graph is constructed with injected dependencies (`Clock`, `PlaybackSink`, `TTSBackend`, filesystem roots) and can be driven to completion from a test with no real time passing.
2. **Audio is a sink.** `PlaybackSink` is a protocol. Production uses `PlaybackEngine`; every test uses `RecordingPlaybackSink`, which records each buffer, each event and the injected clock's time at which it arrived. Gap, latency and click assertions are made on recorded data, never by listening.
3. **Backends speak to mocks.** `EdgeTTSBackend` is tested against `EdgeMockServer`, a local WebSocket server in the test target that implements the wire protocol in document 06. `OpenAITTSBackend` is tested with a `URLProtocol` subclass that streams PCM. `AppleSpeechBackend` is tested against the real synthesizer because it is local, deterministic enough, and present on every runner.

Rules that follow:

- Unit tests cover every branch of every classification heuristic and every rewrite rule. The fixture corpus (§2) is the source of truth for transcript shapes.
- One **network-gated live smoke test** exists per cloud backend. CI never runs it.
- UI is tested at the view-model layer with XCTest. There is no XCUITest automation; the manual QA checklist (§7) covers the real app.
- Tests run with `swift test`. There is no Xcode project and no scheme.

### Naming convention

```
test_<unit>_<scenario>_<expectation>()
```

Examples: `test_TurnAssembler_textBlockWithEndTurnStopReason_emitsFinalAnswer()`, `test_PlaybackEngine_cancelMidBuffer_noClickAboveThreshold()`. One assertion concept per test. Fixture-driven tests take the fixture name as the scenario: `test_TurnAssembler_fixture_narrationThenToolThenAnswer_matchesExpected()`.

The catalogue in §3 of this document is the canonical list and uses this form; these are the names that appear in code. Documents 03–08 point at the same tests in a shorter camelCase form, `<Unit>Tests.test<Scenario>` (for example `TurnAssemblerTests.testEndTurnStopReasonIsFinalAnswer`), chosen for readability inside prose. When a shorthand in those documents has no exact match here, it names a behaviour this catalogue covers under a longer name; the behaviour is the contract, and the catalogue name is the one to implement.

### Test target layout

```
Tests/
├── ClaudioControlProtocolTests/
│   └── ControlEnvelopeTests, ControlRequestTests, StatusReportTests, HookEventDecodingTests, ControlClientTests
├── ClaudioCoreTests/
│   ├── Transcript/      TranscriptParserTests, TranscriptTailerTests, SessionDiscoveryTests, TurnAssemblerTests, ProjectPathEncodingTests
│   ├── Sessions/        SessionRegistryTests, SessionNamingTests, LiveAgentsProbeTests
│   ├── Arbitration/     ArbiterTests, CatchUpPlanTests
│   ├── Speech/          ContentFilterTests, ToolCallSummarizerTests, SpeechTextRendererTests, SentenceSegmenterTests, SynthesisSchedulerTests, PlaybackEngineTests, SpeechPipelineTests
│   ├── Control/         ControlServerTests, HookEventMappingTests, HookInstallerTests
│   ├── Settings/        AppSettingsTests, ProjectPreferencesTests, PathsTests
│   └── Support/         TestClock, RecordingPlaybackSink, MockBackend, FixtureLoader, SyntheticTranscriptWriter, TempRoot
├── ClaudioBackendsTests/
│   ├── Edge/            EdgeMockServer, EdgeDRMTests, EdgeFramingTests, EdgeTTSBackendTests, EdgeLiveSmokeTests
│   ├── Apple/           AppleSpeechBackendTests
│   ├── OpenAI/          StreamingURLProtocol, OpenAITTSBackendTests
│   ├── FallbackBackendTests
│   └── VoiceCatalogTests
├── ClaudioIntegrationTests/
│   ├── UserStoryTests   (one test per story in doc 01 §17)
│   ├── LatencyTests
│   └── PerformanceTests
└── Fixtures/
    └── transcripts/<fixture-name>/...
```

## 2. Fixture corpus

### 2.1 Layout

```
Tests/Fixtures/transcripts/<name>/
├── session.jsonl              # the main transcript, scrubbed
├── subagents/                 # optional, mirrors <session>/subagents/
│   ├── agent-<id>.jsonl
│   └── agent-<id>.meta.json
├── hooks.jsonl                # optional: hook payloads to inject, one per line, with a `t` offset in ms
├── expected.json              # expected TurnEvent sequence (see 2.3)
└── README.md                  # provenance: Claude Code version, capture date, what it exercises
```

Fixtures are loaded by `FixtureLoader.load(_ name: String) -> Fixture`, which returns the record lines, the optional subagent files, the hook lines, and the decoded `expected.json`.

### 2.2 Scrubbing

Fixtures are captured from real sessions and scrubbed so they contain no prose, code, paths or secrets from the original while preserving every structural property the parser depends on. Scrubbing is done by `scripts/scrub-transcript.swift`, a single-file Swift script run with `swift scripts/scrub-transcript.swift <in.jsonl> <out.jsonl>`. It does not depend on the package.

Rules the scrubber applies to every JSON line:

| Field | Treatment |
|-------|-----------|
| `type`, `subtype`, `uuid`, `parentUuid`, `sessionId`, `session_id`, `promptId`, `requestId`, `apiBlockIndex`, `isSidechain`, `agentId`, `entrypoint`, `version`, `timestamp`, `userType`, `isMeta`, `origin`, `promptSource`, `turnOrigin`, `turnPosition`, `message.id`, `message.role`, `message.model`, `message.stop_reason`, `message.usage`, `durationMs`, `messageCount`, `permissionMode`, `operation`, `hookCount`, `exitCode` | Kept verbatim |
| `cwd`, `gitBranch` | Replaced with `/Users/fixture/project-<n>` and `main`, same `<n>` for the same original value |
| `message.content` when a string | Replaced with lorem ipsum of the same character count, preserving newline positions |
| `content[].type == "text"` → `text` | Lorem of the same length, preserving newlines, fenced code markers (```), pipe characters and leading `#`, `-`, `*`, `1.` so markdown structure survives |
| `content[].type == "thinking"` → `thinking`, `signature` | `thinking` → lorem same length; `signature` → `"REDACTED"` |
| `content[].type == "tool_use"` → `name`, `id` | Kept. `input` → each string value replaced by lorem of the same length; `command` and `file_path` keys get synthetic `echo lorem` / `/Users/fixture/project-1/File<n>.swift` so `ToolCallSummarizer` tests stay meaningful |
| `content[].type == "tool_result"` → `tool_use_id`, `is_error` | Kept. `content` → lorem same length |
| `toolUseResult` | Kept keys; string values → lorem; booleans and numbers kept |
| `aiTitle` | Replaced with `Fixture Title <n>` |
| `attachment`, `rendered`, `snapshot`, `serverClassifierContext`, `wireToolInputs`, `wireIngestContext` | Replaced with `{}` (these are ignored by the parser; keeping keys proves tolerance) |
| `lastPrompt`, `queue-operation.content` | Lorem same length |
| Any unknown key | Kept with string values lorem-ised, non-strings kept |

The scrubber is deterministic (seeded by a hash of the input file name) so re-running it produces identical output. `scripts/capture-fixture.sh <session-id> <fixture-name>` locates `~/.claude/projects/*/<session-id>.jsonl`, copies it and any `subagents/` directory into a temporary folder, runs the scrubber on each `.jsonl`, writes the fixture directory, and prints a skeleton `README.md` with the Claude Code `version` field found in the first record. `expected.json` is written by hand or by running `claudio debug expected <fixture>` (which prints the assembler's current output for review) and then committing after inspection.

Every fixture `README.md` records the Claude Code version it was captured from. When `claude --version` on the development machine is newer than the newest fixture by two or more minor versions, `make fixtures` prints a reminder to re-capture `single-turn-final-answer` and `narration-then-tool-then-answer`.

### 2.3 `expected.json`

```json
{
  "version": 1,
  "events": [
    { "kind": "turnStarted", "turnID": "e89a4f1b-...", "promptLength": 142 },
    { "kind": "item", "category": "narration", "textPrefix": "Lorem ipsum dolor", "sourceUUID": "b412071b-..." },
    { "kind": "item", "category": "toolCall", "text": "Using skill grill-me" },
    { "kind": "statusChanged", "status": "busy" },
    { "kind": "item", "category": "finalAnswer", "textPrefix": "Lorem ipsum", "sourceUUID": "..." },
    { "kind": "turnEnded", "turnID": "e89a4f1b-..." },
    { "kind": "statusChanged", "status": "idle" }
  ],
  "metrics": { "unknownRecordTypes": 0, "recordsParsed": 46 }
}
```

`textPrefix` matches the first 40 characters; `text` matches exactly. The comparison function `XCTAssertTurnEvents(_ actual: [TurnEvent], matches expected: ExpectedEvents)` prints a unified diff of the two sequences on failure.

### 2.4 Required fixtures

| Fixture | Exercises | Key assertions |
|---------|-----------|----------------|
| `single-turn-final-answer` | One human prompt, one assistant text block with `stop_reason: end_turn`, `turn_duration` | Exactly one `finalAnswer`; `turnEnded` after it |
| `narration-then-tool-then-answer` | Text + tool_use in one message, tool_result, second message with final text | `narration`, `toolCall`, `finalAnswer` in order; narration never reclassified |
| `multi-block-same-message` | Three `assistant` lines sharing `message.id` and `requestId`, `apiBlockIndex` 0,1,2 | One item per text block; dedup does not collapse blocks with different `uuid` |
| `tool-result-error` | `tool_result` with `is_error: true` and `toolUseResult` error fields | `toolResult` item emitted with error text; non-error results emit nothing |
| `thinking-blocks` | Thinking blocks with signatures, interleaved with text | `thinking` items only when the toggle is on; signatures never rendered |
| `subagent-spawn-and-finish` | `Agent` tool_use, `subagents/agent-*.jsonl` with `isSidechain: true`, matching tool_result | `toolCall` "Agent started: …" and "Agent finished: …"; zero items from sidechain text |
| `escape-interrupt-mid-turn` | Human prompt while a turn is open (no `turn_duration` between) | First turn gets `turnEnded` synthesised immediately before second `turnStarted`; `cancel` emitted |
| `resume-appends-to-old-file` | 200 historical lines then a marker; tailer attaches at EOF then new lines appended | Zero events from the first 200 lines |
| `concurrent-two-sessions` | Two session files in two project dirs, interleaved by timestamp | Two sessions in the registry; items tagged with the correct `sessionID` |
| `table-in-answer` | Final answer containing a 4-row GFM table with alignment row and an escaped pipe | Renderer emits 4 `tableRow` segments, header not read separately |
| `code-fences-in-answer` | Fenced blocks with and without language, indented code, inline code | "swift code block." / "code block." segments; inline code cleaned |
| `unknown-record-types` | Lines with `type: "future-thing"`, missing `type`, non-object JSON, empty line | Parser returns `.unknown`; metrics counts; zero throws |
| `truncated-partial-line` | Final line has no trailing newline, then is completed by a second write | Buffered until complete; parsed once |
| `inode-rotation` | File replaced by a new inode with smaller size | Tailer detects, reopens, attaches at new EOF |
| `ai-title-arrives-late` | 30 records, then `ai-title` | Session title changes from folder name to the title; `titleChanged` event |
| `permission-notification` | `hooks.jsonl` with `Notification permission_prompt` then `PostToolUse` | Status `waiting` then `busy`; event item "needs permission" |
| `stop-reason-populated` | Per-block lines where `message.stop_reason` is present on the text block | Primary heuristic classifies the final answer |
| `stop-reason-absent` | Identical records with `stop_reason: null` on every line | Secondary heuristic (last text before `turn_duration`) classifies the final answer; same `expected.json` events |
| `orca-worktree-cwd` | `cwd` under `/Users/fixture/.orca/worktrees/...`, `entrypoint: cli` | Entrypoint resolves to `orca` |
| `claude-desktop-entrypoint` | `entrypoint: claude-desktop` | Entrypoint `claudeDesktop`; session labelled |

The pair `stop-reason-populated` / `stop-reason-absent` exists because the ordering of per-block writes relative to `stop_reason` population could not be verified on every Claude Code release. `test_TurnAssembler_stopReasonVariants_produceIdenticalEvents()` runs both and asserts identical `expected.json` output, proving the fallback path is equivalent. `claudio doctor` (document 11) reports which variant the installed Claude Code matches by inspecting the newest live transcript.

## 3. Unit test catalogue

Each subsection lists the tests for one unit. The "asserts" column is the contract the implementation must satisfy.

### 3.1 `TranscriptParser`

| Test | Asserts |
|------|---------|
| `test_TranscriptParser_assistantTextBlock_decodesTextAndStopReason` | `message.content[0].text`, `message.id`, `requestId`, `apiBlockIndex`, `stop_reason` decoded |
| `test_TranscriptParser_userStringContent_decodesAsHumanPrompt` | String `content` plus `origin.kind == "human"` → `.user(.prompt)` |
| `test_TranscriptParser_userToolResult_decodesToolResult` | `tool_use_id`, `is_error`, `toolUseResult` decoded |
| `test_TranscriptParser_systemTurnDuration_decodesDuration` | `subtype`, `durationMs` |
| `test_TranscriptParser_aiTitle_decodes` | `aiTitle` string |
| `test_TranscriptParser_unknownType_returnsUnknownWithTypeName` | `.unknown("future-thing")`, no throw |
| `test_TranscriptParser_missingType_returnsUnknownNil` | `.unknown(nil)` |
| `test_TranscriptParser_malformedJSON_returnsMalformed` | `.malformed(byteCount)` and metrics increment |
| `test_TranscriptParser_emptyLine_isSkipped` | No record emitted |
| `test_TranscriptParser_extraUnknownFields_areIgnored` | Decoding succeeds with 40 extra keys |
| `test_TranscriptParser_fixture_unknownRecordTypes_metricsMatch` | `metrics.unknown == expected` |

### 3.2 `TranscriptTailer`

| Test | Asserts |
|------|---------|
| `test_TranscriptTailer_attach_startsAtEndOfFile` | Existing 200 lines produce zero records |
| `test_TranscriptTailer_append_emitsNewLinesOnly` | Each appended line emitted once, in order |
| `test_TranscriptTailer_partialLine_bufferedUntilNewline` | Half a line then the rest → one record |
| `test_TranscriptTailer_truncation_resetsToNewEnd` | File shrinks → offset reset, no garbage records |
| `test_TranscriptTailer_inodeChange_reopensFile` | Replace file → subsequent appends emitted |
| `test_TranscriptTailer_largeAppend_readsInOneMiBChunks` | 3 MiB append emitted completely; no read exceeds 1 MiB |
| `test_TranscriptTailer_idle_closesHandleAfterTimeout` | Handle closed after `idleCloseInterval` on the test clock; reopened on next change |
| `test_TranscriptTailer_cancel_stopsStream` | Task cancellation finishes the `AsyncStream` |

### 3.3 `SessionDiscovery`

| Test | Asserts |
|------|---------|
| `test_SessionDiscovery_mainTranscriptPath_isAccepted` | `<root>/<proj>/<uuid>.jsonl` → `.fileChanged` |
| `test_SessionDiscovery_subagentPath_isAccepted` | `<root>/<proj>/<uuid>/subagents/agent-x.jsonl` accepted with parent id |
| `test_SessionDiscovery_nonJsonl_isIgnored` | `.meta.json`, `.txt` ignored |
| `test_SessionDiscovery_memoryDirectory_isIgnored` | `<proj>/memory/*.md` ignored |
| `test_SessionDiscovery_burstOfEvents_isDebounced` | 50 events in 50 ms → one `.fileChanged` per path |
| `test_SessionDiscovery_projectDirectoryCreatedLater_isWatched` | New project dir after start is discovered |
| `test_SessionDiscovery_extraRoot_isWatched` | Second root produces events |
| `test_SessionDiscovery_missingRoot_logsAndContinues` | Nonexistent root does not fail the others |

Uses a real temporary directory and real FSEvents; the test clock is not used here. These tests are the only core tests permitted to wait on wall-clock time, capped at 2 s each via `XCTestExpectation`.

### 3.4 `TurnAssembler`

| Test | Asserts |
|------|---------|
| `test_TurnAssembler_humanPrompt_startsTurn` | `turnStarted(promptId)` with `status busy` |
| `test_TurnAssembler_toolResultUserRecord_doesNotStartTurn` | No `turnStarted` |
| `test_TurnAssembler_isMetaUserRecord_doesNotStartTurn` | No `turnStarted` |
| `test_TurnAssembler_textBlockWithEndTurnStopReason_emitsFinalAnswer` | Primary heuristic |
| `test_TurnAssembler_textBlockFollowedByToolUseSameMessage_emitsNarration` | Tertiary heuristic |
| `test_TurnAssembler_lastTextBeforeTurnDuration_emitsFinalAnswerWhenStopReasonAbsent` | Secondary heuristic |
| `test_TurnAssembler_stopReasonVariants_produceIdenticalEvents` | Both fixtures equal |
| `test_TurnAssembler_turnDuration_endsTurnAndSetsIdle` | `turnEnded`, `statusChanged(idle)` |
| `test_TurnAssembler_newPromptWhileTurnOpen_closesPreviousTurn` | Escape-interrupt fixture |
| `test_TurnAssembler_toolUse_emitsToolCallItem` | One `toolCall` per `tool_use` block |
| `test_TurnAssembler_toolResultError_emitsToolResultItem` | Only on `is_error` or error fields |
| `test_TurnAssembler_thinkingBlock_emitsThinkingItem` | Category `thinking` |
| `test_TurnAssembler_aiTitle_emitsTitleChanged` | Title event |
| `test_TurnAssembler_sidechainText_emitsNothing` | Subagent narration dropped |
| `test_TurnAssembler_agentToolUseAndResult_emitStartedAndFinished` | Two `toolCall` items with the Task description |
| `test_TurnAssembler_queueOperationAndAttachment_emitNothing` | Ignored types |
| `test_TurnAssembler_duplicateUUID_emitsOnce` | Same record delivered twice → one item |
| `test_TurnAssembler_fixture_<each fixture>_matchesExpected` | One test per fixture in §2.4 |

### 3.5 `SessionRegistry`

| Test | Asserts |
|------|---------|
| `test_SessionRegistry_firstRecord_createsSessionWithFolderName` | Title = last path component of `cwd` |
| `test_SessionRegistry_aiTitle_overridesFolderName` | |
| `test_SessionRegistry_duplicateTitles_getFolderSuffix` | "Title (yard)" / "Title (vea)" |
| `test_SessionRegistry_colorIndex_isStableAcrossRestarts` | Hash of sessionId mod 8, same after reload |
| `test_SessionRegistry_noActivityFor24Hours_removesSession` | Test clock advanced 24 h + 1 s |
| `test_SessionRegistry_activityAt23Hours_keepsSession` | |
| `test_SessionRegistry_probeReportsPid_setsPid` | `LiveAgentsProbe` merge |
| `test_SessionRegistry_probeMissingKnownSession_marksEnded` | Only after two consecutive probes without it |
| `test_SessionRegistry_probeFailure_doesNotChangeStatus` | Command error ignored |
| `test_SessionRegistry_hookStopAndTranscriptFinal_dedupToOneItem` | Same turn, both sources, one `finalAnswer` |
| `test_SessionRegistry_hookStopWithoutTranscript_emitsFinalFromLastAssistantMessage` | Hook authority within window |
| `test_SessionRegistry_entrypointClaudeDesktop_isDetected` | |
| `test_SessionRegistry_entrypointOrcaWorktree_isDetected` | |
| `test_SessionRegistry_newSession_getsDefaultLevelFromSettings` | `defaultLevelNewSession` |
| `test_SessionRegistry_newSessionUnderProjectWithPreference_getsProjectLevel` | `ProjectPreferences` wins |
| `test_SessionRegistry_persistAndRestore_roundTripsUnreadTurns` | `sessions.json` |

### 3.6 `Arbiter`

| Test | Asserts |
|------|---------|
| `test_Arbiter_singleLiveSession_autoActivates` | |
| `test_Arbiter_twoSessions_noAutoActivation` | |
| `test_Arbiter_activeSessionItems_areForwardedFiltered` | Through `ContentFilter` |
| `test_Arbiter_inactiveSessionItems_areNotForwarded` | |
| `test_Arbiter_inactiveTurnEnded_emitsChimeAndFinishedAnnouncement` | Event utterance with session name; unread += 1 |
| `test_Arbiter_inactivePermissionNotification_emitsNeedsPermission` | |
| `test_Arbiter_announcement_doesNotCancelActiveQueue` | `cancel` never called |
| `test_Arbiter_switch_cancelsAndBuildsCatchUpPlan` | |
| `test_Arbiter_catchUpPlan_includesOnlyFinalAnswersOldestFirst` | |
| `test_Arbiter_catchUpPlan_capsAtLastFiveTurns` | 7 unread → 5 planned, oldest 2 dropped, unread reset |
| `test_Arbiter_catchUpCue_textMatchesSpec` | "Vea. Catching up on 3 turns." |
| `test_Arbiter_catchUpDrainedWhileBusy_saysLive` | "Live." |
| `test_Arbiter_catchUpDrainedWhileIdle_saysCaughtUp` | "You're caught up." |
| `test_Arbiter_skipToLive_abandonsPlanAndGoesLive` | |
| `test_Arbiter_humanPromptOnActive_cancelsEverythingIncludingCatchUp` | |
| `test_Arbiter_humanPromptOnInactive_noEffect` | |
| `test_Arbiter_levelDowngrade_dropsExcludedQueuedItems` | Narration dropped, final kept |
| `test_Arbiter_activeSessionEnded_remainsActive` | No auto switch |
| `test_Arbiter_pause_holdsQueueAndKeepsAccumulating` | |
| `test_Arbiter_cycleHotkey_ordersByListOrder` | Same order as the popover sort |

### 3.7 `ContentFilter`

`test_ContentFilter_truthTable_matchesSpec` iterates every `(level, category, speakThinking, speakToolErrors)` tuple against the table in document 05 §2. Plus `test_ContentFilter_eventCategory_alwaysIncludedWhenEventsEnabled` and `test_ContentFilter_eventsDisabled_excludesEvents`.

### 3.8 `ToolCallSummarizer`

One test per tool rule: `test_ToolCallSummarizer_bash_runningFirstEightWordsFlagsStripped`, `_read_readingFilename`, `_edit_editingFilename`, `_write_writingFilename`, `_grep_searchingForPattern`, `_glob_searchingForPattern`, `_agent_agentStartedDescription`, `_skill_usingSkillName`, `_webFetch_fetchingHost`, `_webSearch_searchingTheWeb`, `_mcpTool_callingServerTool`, `_unknownTool_usingToolName`, `_longSummary_cappedAtTwelveWords`, `_identicalWithinFiveSeconds_deduplicated`, `_identicalAfterFiveSeconds_notDeduplicated`.

### 3.9 `SpeechTextRenderer`

One test per rule in document 05 §4, each with the before/after pair from that table:

`test_SpeechTextRenderer_fencedCodeWithLanguage_becomesLanguageCodeBlock`, `_fencedCodeNoLanguage_becomesCodeBlock`, `_indentedCode_becomesCodeBlock`, `_indentedListContinuation_isNotCode`, `_gfmTable_oneSegmentPerBodyRow`, `_gfmTableHeader_notReadSeparately`, `_gfmTableEscapedPipe_preserved`, `_gfmTableAlignmentRow_ignored`, `_heading_textOnlyHeadingSegment`, `_bulletList_oneListItemSegmentEach`, `_orderedList_markerStripped`, `_nestedList_flattenedInOrder`, `_blockquote_markerStripped`, `_horizontalRule_dropped`, `_boldItalicStrike_markersStripped`, `_inlineCodeSnakeCase_spaced`, `_inlineCodeCamelCase_spaced`, `_inlineCodeDottedPath_spaced`, `_inlineCodeFilename_keepsDotExtension`, `_absolutePath_lastComponentOnly`, `_tildePath_lastComponentOnly`, `_url_becomesLink`, `_markdownLink_textOnly`, `_image_dropped`, `_htmlTag_stripped`, `_arrow_becomesTo`, `_ampersand_becomesAnd`, `_doubleDashFlag_becomesFlag`, `_emoji_removed`, `_ansiEscape_removed`, `_whitespace_collapsed`, `_versionString_untouched`, `_malformedMarkdown_fallsBackToRawText`, `_emptyInput_producesNoSegments`, `test_SpeechTextRenderer_fixture_tableInAnswer_fourRows`, `test_SpeechTextRenderer_fixture_codeFencesInAnswer_segments`.

### 3.10 `SentenceSegmenter`

`test_SentenceSegmenter_shortSentence_mergedIntoFollowing` (< 60 chars), `_lastShortSentence_notMerged`, `_longSentence_splitAtClausePunctuation` (> 1200 bytes), `_longSentenceNoPunctuation_splitAtLastSpace`, `_abbreviationEg_notSplit`, `_abbreviationDr_notSplit`, `_decimalNumber_notSplit`, `_tableRowSegment_neverSplit`, `_headingAndListItemKinds_preserved`, `_multibyteUTF8_neverSplitMidCharacter`.

### 3.11 `SynthesisScheduler`

| Test | Asserts |
|------|---------|
| `test_SynthesisScheduler_lookahead_synthesizesAtMostTwoAhead` | `MockBackend` sees ≤ 3 concurrent requests (playing + 2) |
| `test_SynthesisScheduler_outOfOrderCompletion_playsInOrder` | Segment 3 finishing before 2 does not reorder sink input |
| `test_SynthesisScheduler_cancelAll_cancelsTasksAndClearsSink` | Mock reports cancellation; `sink.cancelAll` called once |
| `test_SynthesisScheduler_backendFailure_usesFallbackForThatSegmentOnly` | |
| `test_SynthesisScheduler_setRate_appliesToUnsynthesizedOnly` | Already synthesized segments keep the old rate |
| `test_SynthesisScheduler_wordBoundaries_publishedWithSegmentID` | |
| `test_SynthesisScheduler_metrics_recordTimeToFirstAudio` | Uses test clock |
| `test_SynthesisScheduler_skipSegment_resumesWithNextReadySegment` | No re-synthesis of cached following segments |

### 3.12 `PlaybackEngine`

These run against the real `AVAudioEngine` with the output rendered offline via `enableManualRenderingMode(.offline, ...)` so they are deterministic and silent.

| Test | Asserts |
|------|---------|
| `test_PlaybackEngine_consecutiveBuffers_renderGapless` | Offline render of two 200 ms buffers produces continuous samples; no zero-run longer than 1 ms at the boundary |
| `test_PlaybackEngine_cancelMidBuffer_noClickAboveThreshold` | After `cancelAll(fade: 0.015)`, in the rendered output the max absolute sample-to-sample delta within the fade window and after it is < 0.05 (full scale 1.0), and the output reaches 0 within 15 ms ± 1 ms |
| `test_PlaybackEngine_cancel_discardsScheduledBuffers` | Buffers enqueued before cancel never render after it |
| `test_PlaybackEngine_segmentFinished_firesPerSegment` | `.segmentFinished(id)` once per `markSegmentEnd` |
| `test_PlaybackEngine_position_reportsMonotonically` | `.position` events increase |
| `test_PlaybackEngine_pauseResume_resumesSameSample` | |
| `test_PlaybackEngine_idle30s_stopsEngine` | Test clock; `engine.isRunning == false` |
| `test_PlaybackEngine_configurationChange_rebuildsAndContinues` | Post `AVAudioEngineConfigurationChange` notification manually |

### 3.13 `ClaudioControlProtocol` (own test target `ClaudioControlProtocolTests`)

This target is Foundation-only and is the single dependency shared by `ClaudioCore` and `ClaudioCLI`. Its tests have no dependency on `ClaudioCore`, which guarantees the CLI's link graph stays minimal (`test_ControlProtocol_targetLinksFoundationOnly` greps `otool -L` of the built `claudio` binary for `AVFoundation`/`AppKit` and fails if present; tagged `requiresBuild`).

| Test | Asserts |
|------|---------|
| `test_ControlEnvelope_everyRequestCase_roundTripsJSON` | Each `ControlRequest` case encodes and decodes identically |
| `test_ControlEnvelope_everyResultCase_roundTripsJSON` | Each `ControlResult` case |
| `test_ControlEnvelope_versionField_isPresentAndCurrent` | `v` equals `ControlProtocolVersion.current` |
| `test_ControlEnvelope_unknownVersion_decodesAsUnsupported` | Newer `v` → `.unsupportedVersion` error, no throw |
| `test_ControlEnvelope_unknownRequestKind_decodesAsUnknown` | Forward compatibility |
| `test_ControlEnvelope_lineOver64KiB_rejected` | |
| `test_StatusReport_roundTrip` and `test_SessionSummary_roundTrip` | Field-for-field |
| `test_HookEvent_<event>_decodes` | One per event: `UserPromptSubmit`, `Stop`, `StopFailure`, `SubagentStop`, `Notification` × each `notification_type`, `SessionStart`, `SessionEnd`, `MessageDisplay` |
| `test_HookEvent_unknownEventName_decodesAsUnknown` | |
| `test_HookEvent_rawPayloadPreserved` | The receiver forwards the original JSON; decoding keeps `raw` |
| `test_ControlClient_noServer_failsFastUnder20ms` | Connect timeout honoured |
| `test_ControlClient_sendAndReceive_oneLineEach` | Against an in-test `NWListener` echo |

### 3.14 `ControlServer` and `HookEvent` mapping (in `ClaudioCoreTests/Control`)

`test_ControlServer_socketCreatedWithMode0600`, `test_ControlServer_concurrentClients_eachGetOwnResponse`, `test_ControlServer_hookEvent_dispatchedToRegistry`, `test_ControlServer_ping_respondsWithVersion`, `test_ControlServer_staleSocketFile_isReplacedOnStart`, `test_ControlServer_unsupportedVersion_respondsWithError`; `test_HookEventMapping_toTurnEvents_matchesSpec` covering the table in document 04 §6.

### 3.15 `HookInstaller`

| Test | Asserts |
|------|---------|
| `test_HookInstaller_install_appendsEntriesPreservingOthers` | Orca and cc-status entries byte-identical after install |
| `test_HookInstaller_install_isIdempotent` | Second install changes nothing |
| `test_HookInstaller_install_preservesUnknownTopLevelKeys` | |
| `test_HookInstaller_install_writesBackupFirst` | Backup file exists, keep last 10 |
| `test_HookInstaller_install_writesAtomically` | Temp + rename; simulated crash leaves original |
| `test_HookInstaller_bundleMoved_statusReportsStale` | |
| `test_HookInstaller_repair_rewritesOnlyOurCommands` | |
| `test_HookInstaller_uninstall_removesExactlyOurs` | Others untouched; empty event arrays removed |
| `test_HookInstaller_malformedSettings_refusesToWrite` | Error surfaced, file untouched |
| `test_HookInstaller_missingSettingsFile_createsMinimal` | |
| `test_HookInstaller_allEntriesAsync` | Every written hook has `"async": true` |

### 3.16 `AppSettings`, `ProjectPreferences`, `Paths`

`test_AppSettings_defaults_matchTable`, `test_AppSettings_write_emitsSnapshot`, `test_AppSettings_snapshot_isSendable` (compile-time), `test_AppSettings_migration_v0ToCurrent`; `test_ProjectPreferences_exactCwd_matches`, `test_ProjectPreferences_ancestorCwd_matches`, `test_ProjectPreferences_nearestAncestorWins`, `test_ProjectPreferences_noMatch_returnsNil`, `test_ProjectPreferences_write_isAtomic`; `test_Paths_defaultRoot_isClaudeProjects`, `test_Paths_claudeConfigDirEnv_overridesRoot`, `test_Paths_socketPath_under104Bytes`, `test_Paths_hookCommand_pointsIntoBundle`.

### 3.17 `EdgeTTSBackend` (against `EdgeMockServer`)

`EdgeMockServer` is a `Network.framework` `NWListener` WebSocket server bound to `127.0.0.1` on an ephemeral port. The backend accepts an injected base URL for tests. The server records every query parameter, header and text frame it receives and replies with scripted frames.

| Test | Asserts |
|------|---------|
| `test_EdgeDRM_secMsGec_matchesKnownVector` | Fixed clock 2026-10-05T19:00:00Z → expected uppercase SHA-256 hex (vector computed from the Python reference and committed) |
| `test_EdgeDRM_secMsGec_roundsDownToFiveMinutes` | Two times 299 s apart in the same window → same token |
| `test_EdgeDRM_clockSkew_appliedToTicks` | |
| `test_EdgeTTSBackend_handshake_includesRequiredQueryParams` | `TrustedClientToken`, `ConnectionId` (32 hex), `Sec-MS-GEC`, `Sec-MS-GEC-Version` |
| `test_EdgeTTSBackend_handshake_includesRequiredHeaders` | Origin, User-Agent, Cookie muid |
| `test_EdgeTTSBackend_firstFrame_isSpeechConfigWithWordBoundary` | Exact body |
| `test_EdgeTTSBackend_secondFrame_isSSMLWithVoiceAndRate` | `rate='+25%'` for 1.25 |
| `test_EdgeTTSBackend_ssml_escapesXML` | `& < > ' "` |
| `test_EdgeTTSBackend_ssml_timestampHasTrailingZ` | |
| `test_EdgeFraming_binaryFrame_parsesHeaderLengthAndPayload` | |
| `test_EdgeFraming_binaryFrameNoContentTypeNoData_accepted` | |
| `test_EdgeFraming_binaryFrameNoContentTypeWithData_rejected` | |
| `test_EdgeFraming_textFrame_splitsHeadersAndBody` | |
| `test_EdgeTTSBackend_audioMetadata_emitsWordBoundariesInSeconds` | ticks ÷ 10⁷ |
| `test_EdgeTTSBackend_sessionEndMetadata_ignored` | |
| `test_EdgeTTSBackend_turnEnd_finishesStream` | `.finished` emitted, socket closed |
| `test_EdgeTTSBackend_mp3Frames_decodeTo24kFloat32Mono` | Server sends a committed 1 s MP3 fixture; buffers have expected format and ~24 000 frames |
| `test_EdgeTTSBackend_403_adjustsSkewAndRetriesOnce` | Server returns 403 with `Date` header then succeeds |
| `test_EdgeTTSBackend_403Twice_throwsAuth` | |
| `test_EdgeTTSBackend_429_throwsRateLimited` | |
| `test_EdgeTTSBackend_noAudioBeforeTurnEnd_throwsDecode` | |
| `test_EdgeTTSBackend_cancel_closesSocketPromptly` | Server sees close within 50 ms |
| `test_EdgeTTSBackend_voicesList_parsesShortNameLocaleGender` | |
| `test_EdgeTTSBackend_segmentOver4096Bytes_rejectedBeforeNetwork` | Guard; scheduler never sends these |

### 3.18 `AppleSpeechBackend`

`test_AppleSpeechBackend_synthesize_emits24kFloat32MonoBuffers`, `test_AppleSpeechBackend_synthesize_emitsFinished`, `test_AppleSpeechBackend_voiceRanking_premiumBeforeEnhancedBeforeDefault`, `test_AppleSpeechBackend_rateMapping_matchesFormula`, `test_AppleSpeechBackend_wordBoundaries_presentOrApproximated` (passes either way; logs which), `test_AppleSpeechBackend_concurrentRequests_serialized`, `test_AppleSpeechBackend_cancel_stopsSynthesizer`.

### 3.19 `OpenAITTSBackend` (against `StreamingURLProtocol`)

`test_OpenAITTSBackend_request_hasModelVoiceInputFormatSpeed`, `test_OpenAITTSBackend_request_bearerFromKeychainStub`, `test_OpenAITTSBackend_streamingPCM16_convertsToFloat32Chunks`, `test_OpenAITTSBackend_401_throwsAuth`, `test_OpenAITTSBackend_429_throwsRateLimited`, `test_OpenAITTSBackend_cancel_abortsRequest`, `test_OpenAITTSBackend_noWordBoundaries_supportsFlagFalse`.

### 3.20 `FallbackBackend`

`test_FallbackBackend_primarySucceeds_fallbackNotCalled`, `test_FallbackBackend_primaryThrows_fallbackUsedForSameText`, `test_FallbackBackend_primaryNoAudioIn3s_switchesToFallback`, `test_FallbackBackend_primaryAudioAt2_9s_notSwitched`, `test_FallbackBackend_notice_emittedOncePerHour`, `test_FallbackBackend_nextRequest_retriesPrimary`, `test_FallbackBackend_bothFail_throwsPrimaryError`, `test_FallbackBackend_cancel_cancelsBoth`.

### 3.21 `VoiceCatalog`

`test_VoiceCatalog_merge_acrossBackends`, `test_VoiceCatalog_cache_within24hNotRefetched`, `test_VoiceCatalog_cache_after24hRefetched`, `test_VoiceCatalog_fallbackPairing_matchesGenderAndLocale`, `test_VoiceCatalog_fallbackPairing_prefersPremium`.

### 3.22 View models (`ClaudioApp`)

`SessionsViewModelTests`: sort order (active, waiting, busy, idle by activity, ended), unread pill text, level change forwards to registry, empty state. `PlaybackViewModelTests`: state glyph mapping, transport actions forward to arbiter/pipeline. `HUDViewModelTests`: show on first audio, hide 4 s after drain on test clock, pin prevents hide, prompt stack max 3 and 20 s dismiss, caption word range updates from boundary + position, frame clamping to screen. `SettingsViewModelTests`: hooks status line text for each `HookInstaller.Status`, Premium hint visibility, rate preview debounce.

## 4. Integration tests

### 4.1 Harness

`SyntheticTranscriptWriter` creates a temporary root (`TempRoot`) shaped like `~/.claude/projects`, creates project directories and session files, and appends records with a scheduled timeline: `writer.schedule(at: .milliseconds(1200), append: .assistantText("…", stopReason: nil))`. It advances only when the test advances the shared `TestClock`; file writes happen synchronously at each step so FSEvents (real) delivers them. Record builders produce JSON identical in shape to the fixtures (same field names, fresh UUIDs).

`IntegrationHarness` builds the full core graph exactly as the composition root does, substituting `RecordingPlaybackSink`, `MockBackend` (returns a 0.5 s buffer per request after a configurable delay on the test clock, with synthetic word boundaries), `TestClock`, the temp root, an in-memory `AppSettings`, and a `ControlServer` on a socket under the temp directory (`CLAUDIO_SOCKET` env override). Hook events are injected either by calling `ControlClient.send(.hook(...))` or by spawning the real `claudio hook` binary with the payload on stdin when the test is tagged `requiresCLI`.

### 4.2 User story tests (`UserStoryTests`)

| Story (doc 01 §17) | Test | Key assertion on the recording sink |
|---|---|---|
| 1 Narrated single session | `test_Story01_narratedSingleSession_speaksAllThreeInOrderWithoutGaps` | Buffers for narration, toolCall, finalAnswer in order; max inter-segment gap on sink timeline ≤ 50 ms |
| 2 Instant cancel | `test_Story02_promptDuringSpeech_stopsWithinBudgetAndNothingOldPlays` | `cancelAll` within 100 ms (hook) / 600 ms (transcript-only variant `test_Story02b_...`) of the prompt record; no buffer with a pre-cancel segment id after |
| 3 Background completion | `test_Story03_backgroundTurnCompletes_chimeAndAnnouncementBetweenSegments` | Chime buffer + "B finished" cue appear at a segment boundary, not mid-segment; B.unread == 1 |
| 4 Catch-up digest | `test_Story04_switchWithThreeUnread_speaksCueThenThreeFinalsThenCaughtUp` | Exactly 1 cue + 3 finalAnswer utterances + 1 closing cue; zero narration |
| 5 Skip to live | `test_Story05_skipToLiveDuringCatchUp_stopsAndContinuesLive` | |
| 6 Level change mid-stream | `test_Story06_downgradeToAnswers_dropsQueuedNarrationKeepsFinal` | |
| 7 Table reading | `test_Story07_fourRowTable_fourSkippableSegments` | `skipSegment` moves to next row |
| 8 Backend fallback | `test_Story08_primaryAlways403_everyChunkSpokenByFallbackOneNotice` | Mock primary throws `.auth`; fallback mock produces every segment; one `BackendNotice` |
| 9 Zero footprint | `test_Story09_hooksDisabled_claudeDirUnchanged` | SHA-256 of a fake `~/.claude` tree identical before/after an hour of simulated use |
| 10 Hook coexistence | `test_Story10_installThenUninstall_otherEntriesByteIdentical` | Uses the Orca-shaped settings fixture `Tests/Fixtures/settings/with-orca-and-ccstatus.json` |
| 11 Resumed session | `test_Story11_resumeAppendsToOldFile_onlyNewRecordsSpoken` | |
| 12 Session liveness | `test_Story12_23hListed_24hRemoved` | |

### 4.3 Latency tests (`LatencyTests`)

Each asserts a budget from document 01 §15 using the test clock and sink timestamps, with `MockBackend` latency set to 0 so only Claudio's own overhead is measured:

- `test_Latency_transcriptWriteToSpeechItem_under300ms`
- `test_Latency_segmentReadyToFirstBufferEnqueued_under50msOverhead`
- `test_Latency_interSegmentGap_under50ms`
- `test_Latency_hookPromptToCancel_under100ms` (tagged `requiresCLI`; measures from spawning `claudio hook` to `cancelAll`)
- `test_Latency_transcriptPromptToCancel_under600ms`

## 5. Performance tests

`PerformanceTests` use `XCTestCase.measure(metrics:)` with `XCTClockMetric`, `XCTCPUMetric`, `XCTMemoryMetric`:

- `test_Perf_parse10kRecords` — baseline ≤ 150 ms.
- `test_Perf_render50kCharMarkdown` — ≤ 40 ms.
- `test_Perf_registryWith200Sessions_idleCPU` — a 200-session registry with no activity consumes < 0.5 % CPU over 10 s (measured with `XCTCPUMetric`; `SessionDiscovery` real).
- `test_Perf_tailer3MiBAppend` — ≤ 100 ms.
- `test_Perf_appLaunchToSocketReady` — spawns the built `Claudio` binary from `.build` with `CLAUDIO_SOCKET` override and measures until `ping` succeeds; ≤ 500 ms. Tagged `requiresBuild`.

Real-backend measurements are not unit tests. `claudio bench [--backend edge|apple|openai] [--fixture <name>]` (document 11 §2) renders a fixture's final answers through the live pipeline with `RecordingPlaybackSink` and prints time-to-first-audio per segment, inter-segment gap, and p50/p95. `make bench` runs it with the default backend. Results are pasted into the milestone acceptance notes in document 12.

## 6. Live smoke tests

`EdgeLiveSmokeTests` and `OpenAILiveSmokeTests` run only when `CLAUDIO_LIVE_TESTS=1` is set; otherwise every test in those classes calls `throw XCTSkip("live tests disabled")` in `setUpWithError()`. CI never sets the variable. `OpenAILiveSmokeTests` additionally requires `OPENAI_API_KEY`.

`test_EdgeLive_synthesizeShortSentence_producesAudioAndBoundaries` connects to the real service with voice `en-US-GuyNeural`, text "Claudio live smoke test.", and asserts: at least 0.5 s of audio, at least 3 word boundaries with increasing offsets, `.finished` within 10 s, and that `Sec-MS-GEC` acceptance did not require a skew retry (logs a warning if it did). `test_EdgeLive_voicesList_hasAtLeast300Voices` fetches the voices list. When these fail while mocks pass, the Edge protocol has changed; see the runbook in document 11 §3.

## 7. Manual QA checklist

Performed on the development machine before each milestone is marked done (document 12). Each step lists the expected result. Record pass/fail in the milestone notes.

### 7.1 Milestone 1 — headless core pipeline

1. `make build && .build/debug/claudio tail` in one terminal; start `claude` in another and ask for a two-paragraph explanation. Expected: items printed as `narration`, `toolCall`, `finalAnswer` within 300 ms of appearing in the terminal.
2. Run the headless speaker (`claudio debug speak-session <id>`) at `narrate`. Expected: speech begins within 1.5 s of the first sentence; no audible gap between sentences.
3. While it speaks, type a new prompt and press Enter. Expected: speech stops before the first token of the new response appears.
4. Disconnect Wi-Fi mid-answer. Expected: the voice switches to the Apple voice within about 3 s; no silence longer than 3 s; no crash. Reconnect: Edge voice returns on a subsequent sentence.
5. Ask Claude for a markdown table. Expected: rows read as "Header: value"; the skip key advances one row.

### 7.2 Milestone 2 — menu bar app

1. `make install`. Expected: waveform icon appears in the menu bar within 0.5 s; no Dock icon.
2. Open two terminals in two different repos, start `claude` in each. Expected: both appear in the popover within 1 s of their first output, with folder names, then AI titles when Claude assigns them.
3. Click one row. Expected: it becomes active; narration starts at `narrate`.
4. Let the other finish a turn. Expected: chime and "<name> finished" between sentences; unread pill shows 1.
5. Press the cycle hotkey. Expected: "<name>. Catching up on 1 turn." then the final answer, then "You're caught up." or "Live.".
6. Change rate in Settings while speaking. Expected: the next sentence is faster; no restart.
7. Change voice while speaking. Expected: next sentence uses the new voice.
8. Set level to Quiet on the active session mid-answer. Expected: remaining queued sentences are dropped; the current sentence finishes.
9. Quit and relaunch the app with an unread turn pending. Expected: the unread pill survives; catch-up still works.
10. Leave both sessions idle for the night. Expected (next morning, < 24 h): both still listed.

### 7.3 Milestone 3 — HUD

1. Start speech. Expected: HUD appears top-right with session colour bar and title.
2. Click the chevron. Expected: captions expand; the spoken word is highlighted in sync (within ~100 ms by eye).
3. Drag the HUD to another position; quit; relaunch; speak. Expected: HUD reappears at the dragged position.
4. Move the HUD half off-screen, quit, change display arrangement, relaunch. Expected: HUD is fully on a visible screen.
5. Background session asks for permission. Expected: "Yard needs permission — Switch (↩)" appears; Return switches; the prompt disappears after 20 s otherwise.
6. Toggle "Show HUD" off in Settings. Expected: HUD hides immediately; audio continues.
7. Enable Reduce Motion in System Settings. Expected: no animated waveform; fades replaced with instant changes.

### 7.4 Milestone 4 — hooks and CLI

1. Settings → Integration → enable hooks. Expected: status "7 hooks installed, all pointing at this app"; `~/.claude/settings.json` shows the entries; pre-existing Orca and cc-status entries unchanged (`diff` against the backup).
2. Start a session. Expected: Claude Code shows no hook errors; `claudio status` shows hooks active.
3. Speak, then submit a prompt. Expected: speech stops in under 100 ms (perceptibly instant).
4. Move `Claudio.app` to `~/Desktop`, launch. Expected: popover footer shows "Hooks point at an old location — Repair"; Repair fixes the paths.
5. In Orca, open Settings → Hooks and let Orca rewrite its managed hooks. Expected: Claudio's entries survive; if not, `claudio hooks status` reports missing and Repair reinstalls.
6. `claudio switch yard`, `claudio level quiet`, `claudio say "hello"`. Expected: each takes effect immediately; `--json` output parses.
7. Install the `/speak` skill; inside a session run `/speak off`, `/speak on`. Expected: that session's level toggles.
8. Quit Claudio; run a Claude Code session. Expected: no hook error shown; `claudio hook` exits 0.

### 7.5 Milestone 5 — polish

1. Enable Launch at Login; log out and in. Expected: icon present after login.
2. Add a per-project default of `narrate` for a repo; start a session there. Expected: it starts at `narrate` even when not active.
3. Enter an OpenAI key; select the OpenAI backend. Expected: speech within 1.5 s; captions show approximated word highlighting.
4. Open three Orca worktrees running agents. Expected: three sessions listed, entrypoint label "Orca", correct titles; arbitration behaves as in 7.2.
5. Add an extra root for a second Orca account (`CLAUDE_CONFIG_DIR`). Expected: those sessions appear.
6. Unplug headphones mid-sentence. Expected: audio continues on speakers within 1 s; no crash.
7. Sleep the Mac mid-sentence; wake. Expected: speech resumes or stops cleanly; next item plays normally.
8. With no Premium voice installed, open Settings → Voice. Expected: hint banner with "Open Spoken Content settings". Install Ava (Premium); reopen. Expected: banner gone; Ava selectable as fallback.
9. First launch of an ad-hoc signed build on another Mac. Expected: Gatekeeper prompt; right-click Open works; app runs.

## 8. Coverage

Targets, measured on `swift test --enable-code-coverage`:

| Target | Line coverage |
|--------|---------------|
| `ClaudioControlProtocol` | ≥ 95 % |
| `ClaudioCore` | ≥ 90 % |
| `ClaudioBackends` | ≥ 80 % (live-only paths excluded via `// coverage:ignore` comments honoured by the report script) |
| `ClaudioApp` view models | ≥ 70 % (views excluded) |
| `ClaudioCLI` | ≥ 60 % (argument parsing; the hook fast path is covered by `requiresCLI` integration tests) |

Measurement:

```
swift test --enable-code-coverage
PROFDATA=$(swift test --show-codecov-path | xargs dirname)/default.profdata
xcrun llvm-cov report .build/debug/ClaudioPackageTests.xctest/Contents/MacOS/ClaudioPackageTests \
  -instr-profile "$PROFDATA" -ignore-filename-regex='Tests/|\.build/' -use-color
```

`make coverage` runs the above and writes `build/coverage.txt`; `scripts/check-coverage.sh` fails CI when any target falls below its threshold.

## 9. Flakiness policy

- No `sleep`, `Task.sleep` or `DispatchQueue.asyncAfter` in tests. Every time-dependent unit takes a `Clock` (document 02 `Support/Clock.swift`), and tests use `TestClock.advance(by:)`.
- The only wall-clock waits permitted are in `SessionDiscoveryTests` (FSEvents is real) and `PlaybackEngineTests` configuration-change test, each bounded by a 2 s `XCTestExpectation`.
- Network is never touched outside `*LiveSmokeTests`.
- No test retries in CI. A flaky test is a bug in the test or the code; it is fixed or deleted, never retried.
- Tests run in parallel (`swift test --parallel`); every test uses its own `TempRoot` and its own socket path, so there is no shared state.
- Tests that need a built binary (`requiresCLI`, `requiresBuild`) are skipped with `XCTSkip` when `CLAUDIO_BUILT_PRODUCTS` is unset; `make test` sets it after `swift build`.
