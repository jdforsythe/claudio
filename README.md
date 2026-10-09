# Claudio

Claudio is a native macOS menu bar app that reads your Claude Code sessions aloud. It tails Claude Code's transcripts, optionally listens to Claude Code hooks, renders assistant output into clean speakable text, synthesizes it with a pluggable text-to-speech backend (edge-tts by default, Apple speech as fallback, OpenAI optional), and plays it gaplessly with instant cancel. It handles any number of concurrent sessions across terminals, Claude Desktop and Orca: one session holds the voice, the others announce when they finish or need you, and switching plays a catch-up digest of what you missed.

## Status

This repository currently contains the complete design and engineering documentation for Claudio. The documents are written as the reference for a finished, production application and are sufficient to implement it end to end. Start at [`docs/00-index.md`](docs/00-index.md).

## Documentation

| Document | Purpose |
|----------|---------|
| [00 Index](docs/00-index.md) | Reading order, vocabulary, repository layout |
| [01 Product Requirements](docs/01-prd.md) | What Claudio does and how it must behave |
| [02 Architecture](docs/02-architecture.md) | Process model, modules, canonical types, data flow |
| [03 Transcript Ingestion](docs/03-transcript-ingestion.md) | Reading Claude Code's JSONL transcripts |
| [04 Hooks, Control Socket and CLI](docs/04-hooks-and-cli.md) | Hook integration and the `claudio` command |
| [05 Speech Pipeline](docs/05-speech-pipeline.md) | Markdown to speech, scheduling, playback, cancel |
| [06 TTS Backends](docs/06-tts-backends.md) | Backend protocol and each implementation |
| [07 User Interface](docs/07-ui.md) | Menu bar, popover, HUD, settings, hotkeys |
| [08 Configuration and Persistence](docs/08-configuration-and-persistence.md) | Settings, state files, Keychain |
| [09 Testing Strategy](docs/09-testing.md) | Fixtures, unit, integration, performance, QA |
| [10 Build, Lint and Release](docs/10-build-lint-release.md) | SwiftPM, bundling without Xcode, CI, signing |
| [11 Debugging and Operations](docs/11-debugging-and-operations.md) | Logging, diagnostics, runbooks |
| [12 Implementation Milestones](docs/12-milestones.md) | Build order and acceptance criteria |
| [13 Decision Log](docs/13-decisions.md) | Every decision and the alternatives rejected |

## Requirements

- macOS 15 or later (Apple Silicon or Intel)
- Claude Code 2.1 or later
- To build: Swift 6.3 toolchain (Xcode Command Line Tools are sufficient), Homebrew for `swiftlint` and `swift-format`

## Quick start (once implemented)

```
make install        # build, bundle Claudio.app, copy to /Applications, launch
```

Then start a Claude Code session in any terminal. Claudio discovers it, lists it in the menu bar popover, and begins speaking when you activate it. Enable hooks in Settings → Integration for instant cancel and turn-end accuracy.

## License

MIT. The edge-tts protocol implementation is a clean-room Swift port informed by the LGPL-licensed Python `edge-tts` project; no code from that project is included.
