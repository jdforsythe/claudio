# Changelog

## 0.1.4 — 2026-10-13

- Built-in updates: Settings → General checks GitHub releases (daily by default), downloads the new build, verifies its checksum, replaces the app and relaunches. Updates installed this way skip the Gatekeeper approval step. Dragging a new copy from a DMG over the running app also relaunches it.
- HUD: wider, session title on its own line with a session switcher, voice and speed controls, one clearly labelled skip button (skip-to-live appears only during catch-up), readable sentence counter, longer transcript area.
- Long numbers (5+ digits), hex identifiers and UUIDs are read digit by digit.

## 0.1.3 — 2026-10-13

- Fix a background session being announced as finished twice when the `agent_completed` notification arrived before the `Stop` hook; turn end is now the single announcer and `agent_completed` simply ends the turn.
- Hook `Stop`/`StopFailure` refer to the open turn even when their prompt id differs from the transcript's; a hook and transcript start within 3 s of each other are one turn.
- A final answer arriving from the transcript after the `Stop` hook joins that turn and is deduplicated instead of being spoken again.
- The single-instance check treats any accepted socket connection as a running instance; `claudio doctor` reports the number of Claudio processes.

## 0.1.2 — 2026-10-13

- Fix a crash when opening Settings → Hotkeys (and thereafter any Settings open) on machines other than the build machine: the vendored KeyboardShortcuts library resolved its localized strings through the same generated `Bundle.module` accessor. The library now finds its resource bundle in the app and the bundle ships inside `Claudio.app`.
- `CLAUDIO_SELFTEST=1 /Applications/Claudio.app/Contents/MacOS/Claudio` checks bundled resources and exits.

## 0.1.1 — 2026-10-13

- Fix a crash on launch on any machine other than the one that built the app: the SwiftPM `Bundle.module` accessor fell back to an absolute path inside the build checkout and called `fatalError` when it was missing. The resource bundle is now located explicitly, and a missing bundle only means synthesized chimes.

## 0.1.0 — 2026-10-09

Initial implementation of the design in `docs/`:

- Transcript tailing with FSEvents discovery, tolerant JSONL parsing, turn assembly and final-answer classification.
- Optional Claude Code hooks via the bundled `claudio hook` receiver, merged non-destructively into `~/.claude/settings.json`.
- Speech pipeline: markdown-to-speech renderer, sentence segmenter, two-segment lookahead scheduler, gapless `AVAudioEngine` playback with 15 ms fade on cancel.
- Backends: native edge-tts port (default), Apple speech (fallback), OpenAI; per-chunk fallback with one notice per hour.
- Menu bar popover, floating HUD with word-highlighted captions, settings window, global hotkeys, login item.
- Drag-to-Applications DMG and zip published on GitHub releases (ad-hoc signed; one-time "Open Anyway" on first launch).
- `claudio` CLI: status, sessions, switch, level, pause/resume/toggle, skip, live, mute, say, hooks, link, skill, doctor, tail, render, bench, voices, uninstall.
