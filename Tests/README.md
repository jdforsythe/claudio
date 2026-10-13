# Test layout

| Target | Files | Covers (docs/09 catalogue) |
|---|---|---|
| `ClaudioControlProtocolTests` | `ControlProtocolTests.swift` | §3.13 envelope/result round trips, hook fixtures, version mismatch, socket path, client fail-fast |
| `ClaudioCoreTests/Transcript` | `TranscriptParserTests`, `TranscriptTailerTests`, `TurnAssemblerTests` | §3.1, §3.2, §3.4 including the stop-reason behaviour probe and the stop-reason-stripped variant |
| `ClaudioCoreTests/Speech` | `SpeechTextRendererTests` (+ golden corpus), `SentenceSegmenterTests`, `ToolCallSummarizerTests`, `ContentFilterTests`, `SynthesisSchedulerTests` | §3.7–§3.11, pipeline-level stories 6 and 7, announcement insertion |
| `ClaudioCoreTests/Control` | `HookInstallerTests`, `ControlServerTests` | §3.14, §3.15, skill installer |
| `ClaudioCoreTests/Settings` | `SettingsTests` | §3.16, session cache, schema migration, paths |
| `ClaudioCoreTests/Sessions` | `SessionRegistryTests` | §3.5, §3.6 (stories 1, 2b, 3, 4, 6 through registry → arbiter → pipeline), discovery path classification, probe parsing |
| `ClaudioBackendsTests` | `EdgeTests` (incl. gated live smoke), `AppleAndFallbackTests` | §3.17–§3.21 |
| `ClaudioIntegrationTests` | `IntegrationTests.swift` | Stories 1, 2b, 9, 10, 11 over real FSEvents + tailer; hook receiver via the built CLI (`CLAUDIO_BUILT_PRODUCTS`) |

Not automated: `PlaybackEngine` offline-render tests (the engine is exercised manually and by `claudio bench`), view-model tests, and the Edge mock WebSocket server (the frame builders/parsers are unit-tested and the live smoke test is the canary).
