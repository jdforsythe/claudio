# 12 — Implementation Milestones

The build order is chosen so that the riskiest unknowns are validated first and every milestone leaves something usable. Each milestone lists what is built, the acceptance criteria that must pass before moving on, and the documents to read first. Estimated effort assumes one developer who knows Swift but not this codebase.

## Milestone 0 — Repository scaffold (½ day)

**Build**
- `Package.swift`, `Makefile`, `.swiftlint.yml`, `.swift-format`, `.github/workflows/ci.yml`, `VERSION` as specified in document 10.
- Empty targets that compile: `ClaudioCore`, `ClaudioBackends`, `ClaudioApp` (prints version and exits), `ClaudioCLI` (`claudio version`), three test targets with one passing test each.
- `scripts/make-app.sh`, `scripts/make-icon.sh`, a placeholder 1024 px icon.
- `Tests/Fixtures/README.md` and `scripts/capture-fixture.sh`.

**Accept**
- `make lint test app` succeeds on the developer machine with Command Line Tools only.
- CI is green on the first push.
- `open build/Claudio.app` shows nothing (LSUIElement) and `claudio version` prints the version.

**Read first:** 00, 02, 10.

## Milestone 1 — Headless core pipeline (3–4 days)

**Build**
- `Transcript/`: `TranscriptRecord`, `TranscriptParser`, `TranscriptTailer`, `ProjectPathEncoding`, `TurnAssembler` (document 03 §2–§7).
- `Sessions/`: models, `SessionRegistry` without the probe, `SessionNaming`.
- `Speech/`: `ContentFilter`, `ToolCallSummarizer`, `SpeechTextRenderer` with the full rule table, `SentenceSegmenter`, `Utterance`, `SynthesisScheduler`, `PlaybackEngine`, `RecordingPlaybackSink`, `SpeechPipeline` (document 05).
- `ClaudioBackends`: `EdgeTTSBackend` complete with MP3 decoding and word boundaries, `AppleSpeechBackend`, `FallbackBackend` (document 06 §2–§3, §5).
- A hidden `claudio debug tail-and-speak <transcript.jsonl> --level narrate` subcommand that runs the whole pipeline in-process against one file. This is the only UI for this milestone.
- Fixture corpus captured and scrubbed (document 09 §2), at least the first twelve fixtures.

**Accept**
- All unit tests in document 09 §3 for the modules above pass.
- The `stop-reason-populated` and `stop-reason-absent` fixture tests report which behaviour the installed Claude Code exhibits, and the classifier passes against both.
- Running the debug subcommand against a live Claude Code session speaks narration, tool-call summaries and the final answer with no audible gap; stopwatch-measured inter-segment gap under 50 ms; first audio under 1.5 s.
- Typing a new prompt in that session stops speech within 600 ms (transcript-only path).
- Pulling the network cable mid-session switches to the Apple voice without silence longer than 3 s and without a crash.
- `PlaybackEngine` click test passes.

**Read first:** 03, 05, 06, 09.

## Milestone 2 — Menu bar app with multi-session arbitration (4–5 days)

**Build**
- `SessionDiscovery` (FSEvents), `LiveAgentsProbe`, liveness and expiry, `sessions.json` cache (document 03 §4, §8; document 08 §5).
- `Arbiter` with activation, event interrupts, `CatchUpPlan`, skip-to-live, level changes (document 02 §7.2, document 01 §7–§9).
- `AppSettings`, `ProjectPreferences`, `Paths`, Keychain store (document 08).
- `ClaudioApp`: composition root, `MenuBarExtra`, popover with session list and transport, settings window (all tabs except Integration), hotkeys, single-instance guard, launch at login (document 07 §1–§3, §5–§6).
- Event chimes.

**Accept**
- User stories 1, 3, 4, 5, 6, 11, 12 from document 01 §17 pass as integration tests.
- With three live sessions (two terminals, one Claude Desktop), the popover lists all three with correct titles and statuses within 1 s of activity.
- Switching sessions by popover click and by hotkey plays the catch-up digest, then "Live." or "You're caught up."
- Changing voice, rate, level and backend in Settings takes effect on the next segment with no restart.
- Quit and relaunch restores the session list and unread turns; catch-up still works.
- Idle CPU under 0.5 % and memory under 80 MB with five sessions discovered.

**Read first:** 07, 08, 03 §8.

## Milestone 3 — HUD and captions (2–3 days)

**Build**
- `HUDPanel`, `HUDView`, `HUDViewModel`; show/hide policy; drag and position persistence; background-session prompts with one-key switch; captions disclosure with word highlighting from `SynthesisEvent.wordBoundary`; approximated boundaries for backends without them (document 07 §4, document 05 §9).

**Accept**
- HUD appears on first audio and hides 4 s after drain; position survives relaunch and display changes.
- Caption highlight tracks the spoken word within 100 ms on Edge; approximated highlight on Apple when the delegate does not fire during `write`.
- "Yard needs permission — Switch" appears when a background session triggers a permission notification and Return switches.
- HUD never steals focus from the terminal (typing continues uninterrupted while it appears).

**Read first:** 07 §4, 05 §9.

## Milestone 4 — Hooks, control socket and CLI (2–3 days)

**Build**
- `ControlProtocol`, `ControlServer`, `ControlClient`; `HookEvent` mapping; hook/transcript dedup (document 04 §5–§6, document 03 §9).
- `claudio hook` receiver meeting the 20 ms budget; full CLI command set; `claudio doctor`, `claudio render`, `claudio tail`, `claudio bench` (document 04 §4, §7; document 11 §2).
- `HookInstaller` with backup, merge, verify, repair, uninstall; Settings → Integration tab; `/speak` skill installer; `/usr/local/bin/claudio` symlink (document 04 §3, §8).

**Accept**
- User stories 2 (hooks path, under 100 ms), 8, 9 and 10 pass.
- `~/.claude/settings.json` containing Orca's managed hooks and the user's existing hooks is byte-identical outside our entries after install → uninstall.
- Moving `Claudio.app` to a new folder and relaunching repairs the hook paths with one click.
- `time claudio hook < sample.json` reports under 20 ms wall time with the app running and with it stopped.
- `/speak off` inside a Claude Code session sets that session to quiet within one segment.

**Read first:** 04, 11 §2.

## Milestone 5 — OpenAI backend, polish and release (2 days)

**Build**
- `OpenAITTSBackend`, Settings → OpenAI tab, `VoiceCatalog` previews and fallback pairing (document 06 §4, §6).
- App icon, release build with dSYM, GitHub release workflow, DMG, optional Developer ID signing and notarization (document 10 §9–§11).
- Orca verification pass: extra transcript roots per account, structured-mode session discovery, hook coexistence (manual QA checklist in document 09 §7).

**Accept**
- All twelve user stories pass; coverage targets met (document 09 §8).
- A tagged push produces a GitHub release with `Claudio.app.zip`, sha256, dSYM.
- Fresh-machine test: download the zip, drag to Applications, right-click Open, speech within 30 s.
- Full manual QA checklist signed off.

**Read first:** 06 §4, 10, 09 §7.

## What to do when a milestone's acceptance fails

Do not proceed. The milestones are ordered so that each later one depends on the invariants of the earlier ones (gapless playback, correct classification, correct session identity). Fix the failure, add the test that would have caught it, and record any resulting design change in document 13.

## Deferred work (explicitly not in v1)

Tracked here so nobody rebuilds the argument. Rationale is in document 13.

- Focus-following of the frontmost terminal window.
- Kokoro or any local neural backend via a sidecar process.
- LLM condensation of long answers.
- Speech-to-text input.
- Per-agent distinct voices for subagents.
- Linux or Windows.
- Siri voices (impossible: not exposed to third-party apps).
