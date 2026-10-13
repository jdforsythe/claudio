# Changelog

## 0.1.0 — 2026-10-09

Initial implementation of the design in `docs/`:

- Transcript tailing with FSEvents discovery, tolerant JSONL parsing, turn assembly and final-answer classification.
- Optional Claude Code hooks via the bundled `claudio hook` receiver, merged non-destructively into `~/.claude/settings.json`.
- Speech pipeline: markdown-to-speech renderer, sentence segmenter, two-segment lookahead scheduler, gapless `AVAudioEngine` playback with 15 ms fade on cancel.
- Backends: native edge-tts port (default), Apple speech (fallback), OpenAI; per-chunk fallback with one notice per hour.
- Menu bar popover, floating HUD with word-highlighted captions, settings window, global hotkeys, login item.
- Drag-to-Applications DMG and zip published on GitHub releases (ad-hoc signed; one-time "Open Anyway" on first launch).
- `claudio` CLI: status, sessions, switch, level, pause/resume/toggle, skip, live, mute, say, hooks, link, skill, doctor, tail, render, bench, voices, uninstall.
