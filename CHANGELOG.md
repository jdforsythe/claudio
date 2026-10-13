# Changelog

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
