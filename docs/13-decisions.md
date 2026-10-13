# 13 — Decision Log

Every product and technical decision, with the alternatives that were considered and why they lost. Entries are numbered and referenced from other documents as D-nn. Dates are when the decision was made. A decision is changed only by adding a superseding entry, never by editing the original.

---

### D-01 — Scope: macOS only, personal-first, publishable later
**Date:** 2026-10-05
**Decision:** Build for macOS 15+ only. Optimise for one developer's daily use, but keep everything needed to publish (bundle, signing path, uninstall symmetry) in place from the start.
**Alternatives:** Cross-platform (Linux/Windows) via Electron or Tauri.
**Why:** Every quality problem in the predecessor (gaps, no cancel, weak tray UI) lives exactly where native audio and window APIs help. Cross-platform forces a web stack and removes those tools. Signing and notarization are documented but optional until sharing matters.

### D-02 — Stack: Swift/SwiftUI with SwiftPM, no Xcode
**Date:** 2026-10-05
**Decision:** Native Swift 6, SwiftUI `MenuBarExtra`, AppKit `NSPanel` for the HUD, AVFoundation for audio. Built with `swift build` and a bundling script. Xcode is not required.
**Alternatives:** Tauri 2 (Rust + web), Electron, Python rumps/pystray, Go systray.
**Why:** Best HUD/popover story, trivial login item, first-class `AVAudioEngine`, no runtime to bundle, few-MB binary. Tauri was the runner-up but routes audio through Rust or WebAudio and has reported focus regressions for non-activating panels on macOS 26. The developer machine has Swift 6.3 via Command Line Tools and no Xcode; SwiftPM covers everything needed.

### D-03 — Ingestion: transcript tail plus optional hooks
**Date:** 2026-10-05
**Decision:** Tail `~/.claude/projects/**/*.jsonl` for streamed text and discovery. Register hooks in `~/.claude/settings.json` only when the user enables them, for instant cancel, authoritative turn end, and status events. The tail alone is a complete fallback.
**Alternatives:** Hooks only; tail only.
**Why:** The transcript is written asynchronously and its schema is declared unstable, so it cannot be the only source of control signals. Hooks fire per message rather than per block, so they cannot be the only source of streamed text. Hooks require writing to `~/.claude/settings.json`, which the user accepted; the earlier objection was specifically to scripts dumped into `~/.claude/tools`.

### D-04 — Three speech levels, not per-category checkboxes
**Date:** 2026-10-05
**Decision:** `quiet` (events), `answers` (+ final answers), `narrate` (+ narration + tool-call summaries). Thinking and tool errors are global advanced toggles.
**Alternatives:** Independent toggles for each of six categories per session.
**Why:** The user's two real modes are "tell me when it's done" and "let me monitor it". Three levels map to those plus silence, and fit in a segmented control. Independent toggles add UI surface without a described use.

### D-05 — Arbitration: one active session plus event interrupts
**Date:** 2026-10-05
**Decision:** Exactly one session is voiced. Events (turn finished, needs permission, needs input) from any session are announced briefly between segments. Switching is manual.
**Alternatives:** Auto-follow the frontmost terminal; interleave all sessions with name prefixes.
**Why:** One voice cannot serve two narrations. Interleaving drowns the session you care about. Focus-following has no official API; the window-title heuristic breaks inside Orca's embedded terminals and when terminal titles are disabled. Kept as a later addition (D-17).

### D-06 — Catch-up is a digest of final answers, capped at 5 turns
**Date:** 2026-10-05
**Decision:** Switching to a session with unread turns plays the final answer of each of the last five unread turns, oldest first, then a "Live." or "You're caught up." cue. A skip-to-live control abandons the rest.
**Alternatives:** Resume live only; play full backlog; ask every time.
**Why:** Final answers carry the information; narration and tool calls are only useful live. Five turns bounds the worst case. Asking every time adds friction to the most frequent action.

### D-07 — No LLM condensation
**Date:** 2026-10-05
**Decision:** Long answers are read in full. No summarisation by a model.
**Alternatives:** Condense answers over N characters via an API call.
**Why:** User decision. Adds a network dependency, cost and a second voice of truth. Skip-segment and skip-to-live cover impatience.

### D-08 — Cancel semantics
**Date:** 2026-10-05
**Decision:** A human prompt in the active session cancels everything queued for it. Background prompts do nothing audible. Switching cancels. Events never cancel. Every cancel uses a 15 ms fade.
**Why:** Submitting a prompt is an unambiguous "I've read it". Fading avoids clicks from stopping mid-sample.

### D-09 — Hotkeys default to Ctrl+Option+J/K/L, rebindable
**Date:** 2026-10-05
**Decision:** Pause/resume, skip segment, skip to live on Ctrl+Option+J/K/L; cycle session on Ctrl+Option+;; toggle level on Ctrl+Option+'. All rebindable via KeyboardShortcuts.
**Alternatives:** Plain Cmd+J/K/L as the user first suggested.
**Why:** Global hotkeys steal the combo system-wide, and Cmd+K (clear terminal) and Cmd+L (browser address bar) are heavily used. The user agreed not to lock in the exact combination.

### D-10 — Default backend: native Swift port of edge-tts; Apple as fallback; no Python
**Date:** 2026-10-05
**Decision:** Reimplement the edge-tts WebSocket protocol in Swift. Fall back per chunk to `AVSpeechSynthesizer` after a 3 s first-audio timeout or any error. No Python or Node runtime is bundled.
**Alternatives:** Keep edge-tts via a bundled Python; Kokoro via an mlx-audio sidecar; OpenAI as default; Apple Premium voices as default.
**Why:** The user's stated preference is "voices much better than Mac", which edge-tts provided for free. Bundling Python adds hundreds of megabytes and a second runtime to maintain. Kokoro is attractive but the sidecar bundling story (uv venv, model download, health checks) is more work than the whole v1 UI; the backend protocol leaves room for it. edge-tts is unofficial and has broken before, so fallback is mandatory and the constants live in one file.

### D-11 — Backend protocol returns PCM buffers, not files
**Date:** 2026-10-05
**Decision:** `TTSBackend.synthesize` yields `AVAudioPCMBuffer`s (Float32 mono 24 kHz) and word boundaries as an async stream. One `AVAudioPlayerNode` plays all buffers back-to-back.
**Alternatives:** Backends write MP3/WAV files played by a player process or `AVAudioPlayer`.
**Why:** Files reintroduce per-clip startup, gaps and no instant stop, which are the predecessor's defects. Scheduling PCM on one node gives sub-5 ms gaps and immediate `stop()`.

### D-12 — Lookahead of two segments
**Date:** 2026-10-05
**Decision:** Synthesize at most two segments ahead of the one playing.
**Why:** One is not enough to hide a 300–800 ms Edge round trip behind a short sentence; three wastes synthesis on cancel. Configurable in hidden settings.

### D-13 — Tables are read in full; rows are skip units
**Date:** 2026-10-05
**Decision:** Every body row is spoken as "Header: value, Header: value." Each row is its own segment so skip-segment moves to the next row.
**Alternatives:** Header row only plus "table with N rows".
**Why:** User decision. Tables in Claude's answers usually carry the result; the skip control makes long ones tolerable.

### D-14 — Word-level caption highlighting in v1
**Date:** 2026-10-05
**Decision:** Use edge-tts `WordBoundary` metadata and `AVSpeechSynthesizerDelegate` ranges to highlight the spoken word in the HUD captions; approximate proportionally for backends without boundaries.
**Why:** User decision. The data is already in the Edge stream and the HUD exists anyway.

### D-15 — Fallback is not audibly marked
**Date:** 2026-10-05
**Decision:** When a chunk falls back to Apple, no cue plays. One HUD notice per hour.
**Why:** The voice change is itself obvious. A cue per chunk during an outage would be worse than the outage.

### D-16 — Session liveness: 24 hours of silence, process state shown separately
**Date:** 2026-10-05
**Decision:** A session leaves the list 24 h after its last transcript write. A session whose process is gone is shown as "ended" but stays listed so catch-up remains possible.
**Alternatives:** 30 minutes.
**Why:** User decision: a lunch break must not empty the list. The process check comes from `claude agents --json` and marks state rather than removing.

### D-17 — Focus-following deferred
**Date:** 2026-10-05
**Decision:** Not in v1. Manual switching via popover, HUD, hotkey and CLI.
**Why:** No official API. Proxies (Accessibility window title, `claude agents` cwd) are unreliable in Orca and Claude Desktop. Revisit after v1 usage shows whether manual switching is enough.

### D-18 — Config: UserDefaults for app settings, Application Support JSON for per-project and session state; all live
**Date:** 2026-10-05
**Decision:** No config file to edit by hand, no CLI flags that need a restart. Per-session level is ephemeral by session id with a per-project default. Nothing is written under `~/.claude/projects`.
**Alternatives:** Flag files per project under `~/.claude/projects` (the predecessor's approach).
**Why:** The predecessor's rate flag needed a daemon restart and its flag files lived in Claude's tree. UserDefaults is observable and free; JSON in Application Support is ours to version.

### D-19 — Bundled `claudio` CLI doubles as the hook receiver
**Date:** 2026-10-05
**Decision:** One small executable inside the bundle serves both `claudio hook` (stdin → socket) and the user CLI. It links only Foundation and ArgumentParser.
**Alternatives:** No in-session control; a separate hook shell script.
**Why:** The socket is required for hooks anyway, so the CLI is nearly free. One binary means one path to repair when the app moves. A shell script would need `jq` or `nc` and could not meet the 20 ms budget reliably.

### D-20 — Hooks are installed by merging into `~/.claude/settings.json`, identified by command path
**Date:** 2026-10-05
**Decision:** Append entries whose command is `<bundle>/Contents/MacOS/claudio hook`, `async: true`. Back up before every write. Remove only entries whose command contains that path. Refuse to write if the file does not parse.
**Why:** Orca and the user's own hooks live in the same file. Clobbering it would break other tools; refusing on malformed input avoids making a bad file worse.

### D-21 — Package layout: Core / Backends / App / CLI
**Date:** 2026-10-05
**Decision:** Four targets. Core has no UI imports and is fully unit-tested. Backends depend on Core. App and CLI are thin.
**Why:** The pipeline must be testable without audio hardware or a window server; the CLI must start fast and therefore must not link AVFoundation or AppKit.

### D-22 — Bundle identifier `com.jdforsythe.claudio`
**Date:** 2026-10-09
**Decision:** As stated. Also the UserDefaults suite, Keychain service, and `os.Logger` subsystem.

### D-23 — Documentation set in `docs/` rather than one file
**Date:** 2026-10-09
**Decision:** Thirteen numbered documents with an index, written as reverse-engineered documentation of a finished product.
**Alternatives:** One long Markdown file; a published web page.
**Why:** User decision. Navigation beats single-file grep at this length; each implementation milestone maps to a small set of documents.

### D-24 — Minimum macOS 15, Swift 6 strict concurrency, swift-format + SwiftLint, GitHub Actions
**Date:** 2026-10-09
**Decision:** As stated. Ad-hoc signing by default; Developer ID and notarization documented as the release path.
**Why:** macOS 15 keeps `MenuBarExtra(.window)` and modern `@Observable` available while allowing users one release behind the developer's macOS 26. Strict concurrency catches the data races that an audio pipeline with actors would otherwise hide.

### D-25 — Final-answer classification uses `message.stop_reason` first, turn end second, block adjacency third
**Date:** 2026-10-09
**Decision:** A `text` block is a `finalAnswer` when its record's `message.stop_reason == "end_turn"`; otherwise when it belongs to the last assistant message before `system/turn_duration` or a `Stop` hook; otherwise a `text` block in a message that also contains `tool_use` is `narration`. A fixture test records which case the installed Claude Code exercises.
**Why:** Observed records carry `stop_reason` on every per-block line of a message, but it is not verified whether the value is present while the message is still streaming. The layered rule is correct in either case and the test makes the behaviour visible.

### D-26 — `claude agents --json` is the process-liveness source
**Date:** 2026-10-09
**Decision:** Poll `claude agents --json` every 10 s to attach `pid` and status to sessions and to mark sessions `ended`. Treat failure of the command as "unknown", never as "ended".
**Why:** Verified locally to return pid, cwd, sessionId, name and busy/waiting/idle status for interactive sessions. It is the only documented way to know a Claude process is alive without a hook.

### D-27 — Verified: transcript records are written per message, with `stop_reason` always populated
**Date:** 2026-10-09
**Finding:** Tailing a live Claude Code 2.1.290 session with a 20 ms poller showed every per-block `assistant` record of a message arriving in one write after the message completed, each carrying the final `stop_reason`; zero null `stop_reason` values across 2,000 records. Block `timestamp` fields are generation times and can precede the write by up to 12 s.
**Decision:** The primary classifier in D-25 is the production path on current Claude Code; the secondary and tertiary paths remain as guards. The transcript's text latency is bounded by message completion, so the `MessageDisplay` hook is the designated path for earlier text if a future version needs it. The probe fixtures `stop-reason-populated` and `stop-reason-absent` stay in the suite to detect a change.

### D-28 — Core passes PCM as a Sendable value type, not `AVAudioPCMBuffer`
**Date:** 2026-10-09
**Decision:** `SynthesisEvent.audio` and `PlaybackSink.enqueue` carry `PCMBuffer` (a `Sendable` struct of Float32 samples at 24 kHz mono). `PlaybackEngine` converts to `AVAudioPCMBuffer` at the edge; backends convert from their engine's format into `PCMBuffer`.
**Alternatives:** `AVAudioPCMBuffer` in the protocol as document 02 §4 originally wrote.
**Why:** `AVAudioPCMBuffer` is not `Sendable`, so under Swift 6 strict concurrency every actor boundary in the scheduler would need `@unchecked Sendable` wrappers, which document 02 §6 forbids outside `PlaybackEngine`. A value type also makes `RecordingPlaybackSink` and `MockBackend` trivially deterministic. Cost: one copy per buffer (≈ 20 KB per 200 ms), negligible.

### D-29 — KeyboardShortcuts is vendored without its `#Preview` blocks
**Date:** 2026-10-09
**Decision:** `Vendor/KeyboardShortcuts` is a local copy of sindresorhus/KeyboardShortcuts 2.3.0 (MIT) with the three `#Preview` macro invocations removed; `Package.swift` references it by path.
**Alternatives:** Depend on the upstream package; replace it with a hand-written Carbon hotkey layer.
**Why:** `#Preview` expands through the `PreviewsMacros` compiler plugin, which ships only with Xcode. Document 10 promises a Command Line Tools-only build, and the upstream package fails to compile under that toolchain in both debug and release. Vendoring keeps the library's recorder UI and storage; updating is a copy plus the same three-line removal (see `Vendor/KeyboardShortcuts/README.md`).

### D-30 — The CLI product is `claudio-cli`, installed as `Contents/Helpers/claudio`
**Date:** 2026-10-09
**Decision:** The SwiftPM executable product for the CLI is named `claudio-cli`. `scripts/make-app.sh` copies it into the bundle as `Contents/Helpers/claudio`. The hook command written to `~/.claude/settings.json` is `<bundle>/Contents/Helpers/claudio hook`; `HookInstaller` recognises both `Contents/Helpers/claudio hook` and the originally documented `Contents/MacOS/claudio hook` as its own. `/usr/local/bin/claudio` and the `/speak` skill point at the Helpers path. Unbundled runs find the CLI as `claudio-cli` next to the app binary.
**Alternatives:** Products `Claudio` and `claudio` in the same directory as documents 02 and 10 specify.
**Why:** The default APFS volume is case-insensitive. SwiftPM wrote both products to `.build/<config>/Claudio` (same inode), so running the CLI launched a second copy of the app, and the same collision would occur inside `Contents/MacOS`. The user-facing command name and the hook marker (`Claudio.app/.../claudio hook`) are unchanged.

### D-31 — Caption scrolling: the HUD panel sizes itself from SwiftUI's preferred height
**Date:** 2026-10-09
**Decision:** `HUDPanel`'s `NSHostingView` uses `sizingOptions = [.preferredContentSize]`; `HUDController` re-anchors the top-left corner on every content-driven resize and treats a user drag as the new anchor. Caption text wraps without a line limit.
**Why:** Measuring the content with a `GeometryReader` inside the already-sized window could only ever report the window's current height, so captions were clipped at 56 pt instead of wrapping (found in first use).

### D-32 — Tests run through an XCTest-compatible shim when Xcode is absent
**Date:** 2026-10-09
**Decision:** `Package.swift` checks for Xcode's `XCTest.framework` (override with `CLAUDIO_XCTEST=0|1`). With it, the four suites are ordinary `.testTarget`s run by `swift test`. Without it, the same sources compile against `Tests/XCTestShim` (a module named `XCTest` providing `XCTestCase`, the `XCTAssert*` family, `XCTUnwrap`, `XCTSkip`) into the `claudio-tests` executable; `scripts/gen-test-registry.py` generates the method registry (no runtime discovery without XCTest) and `scripts/run-tests.sh` (`make test`) picks the right path. Shared helpers live in the `TestSupport` target so no source file belongs to two targets.
**Alternatives:** Require Xcode for tests; Swift Testing (`import Testing`).
**Why:** The Command Line Tools on the development machine ship neither XCTest nor the Swift Testing module, and document 10 promises a CLT-only workflow. The shim keeps the suite source-compatible with real XCTest, so CI runners with Xcode use the standard runner unchanged. The shim applies a 30 s per-test timeout and prints one line per test.
