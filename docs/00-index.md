# Claudio — Documentation Index

Claudio is a native macOS menu bar application that reads Claude Code sessions aloud. It tails Claude Code's transcript files, optionally receives Claude Code hook events, turns assistant output into clean speakable text, synthesizes it with a pluggable text-to-speech backend, and plays it gaplessly with instant cancellation. It manages any number of concurrent Claude Code sessions (terminal, Claude Desktop, Orca), lets exactly one session hold the voice at a time, announces events from the others, and lets you switch and catch up.

This documentation set describes the system as built. It is written so that a developer who has never seen the code can rebuild it from these documents alone, and so that a developer joining the project can understand why every part exists.

## Reading order

| # | Document | What it covers | Read when |
|---|----------|----------------|-----------|
| 01 | [Product Requirements](01-prd.md) | Problem, goals, non-goals, user stories, behaviour contracts (levels, arbitration, catch-up, cancel), success criteria | Always first |
| 02 | [Architecture](02-architecture.md) | Process model, module map, canonical type names, data flow, concurrency model, state machines | Always second |
| 03 | [Transcript Ingestion](03-transcript-ingestion.md) | JSONL format, discovery, tailing, parsing, session model, liveness, dedup, subagents, resumed sessions, Orca and Desktop | Implementing `ClaudioCore/Transcript` |
| 04 | [Hooks, Control Socket and CLI](04-hooks-and-cli.md) | Hook events and payloads, socket protocol, hook install and uninstall, `claudio` CLI, `/speak` skill | Implementing `claudio` CLI, `ControlServer`, `HookInstaller` |
| 05 | [Speech Pipeline](05-speech-pipeline.md) | Content classification, markdown-to-speech rendering, sentence segmentation, synthesis scheduling, playback engine, cancel semantics, rate, word boundaries | Implementing `ClaudioCore/Speech` |
| 06 | [TTS Backends](06-tts-backends.md) | Backend protocol, edge-tts native implementation (wire protocol in full), Apple speech, OpenAI, fallback wrapper, voice catalog | Implementing `ClaudioBackends` |
| 07 | [User Interface](07-ui.md) | Menu bar item, popover, HUD panel, captions, settings window, hotkeys, visual states, accessibility | Implementing `ClaudioApp` |
| 08 | [Configuration and Persistence](08-configuration-and-persistence.md) | UserDefaults keys, Application Support files, per-project defaults, schemas, migration | Any module that reads settings |
| 09 | [Testing Strategy](09-testing.md) | Unit, integration, fixture corpus, audio verification, manual QA scripts, performance budgets | Before writing the first test |
| 10 | [Build, Lint and Release](10-build-lint-release.md) | SwiftPM layout, `Package.swift`, Makefile, app bundling without Xcode, Info.plist, entitlements, signing, notarization, CI, versioning | Setting up the repo |
| 11 | [Debugging and Operations](11-debugging-and-operations.md) | Logging, diagnostics commands, failure runbooks, performance investigation | When something breaks |
| 12 | [Implementation Milestones](12-milestones.md) | Ordered build plan with acceptance criteria per milestone | Planning the work |
| 13 | [Decision Log](13-decisions.md) | Every product and technical decision with the alternatives rejected and why | When tempted to change something |

## Scope summary

**In scope (v1):** macOS 15+, Apple Silicon and Intel; menu bar app plus bundled CLI; transcript tailing with zero footprint in `~/.claude`; optional hooks registered in `~/.claude/settings.json`; three speech levels per session; one active session with event interrupts from the others; catch-up digest on switch; instant cancel on new prompt; edge-tts (native Swift port) as default backend, Apple speech as fallback, OpenAI as paid option; floating HUD with collapsible word-highlighted captions; global hotkeys; settings applied live; login item.

**Out of scope (v1):** Windows and Linux; speech-to-text input; LLM-based condensation of long answers; Kokoro or other local neural models (the backend protocol accommodates them); automatic focus-following of the frontmost terminal; Siri voices (not available to third-party apps).

## Vocabulary

These terms are used consistently across all documents and in code identifiers.

- **Session** — one Claude Code conversation, identified by Claude's `sessionId` (UUID). Backed by one main transcript file and zero or more subagent transcript files.
- **Turn** — the span from one human prompt to the end of Claude's response to it. Identified by Claude's `promptId`.
- **Record** — one JSON line in a transcript file.
- **Block** — one element of an assistant message's `content` array (`text`, `thinking`, `tool_use`). Claude Code writes one record per block.
- **Speech item** — one unit of speakable content produced from the transcript: a final answer, a narration block, a tool-call summary, an event. Carries a category.
- **Category** — the kind of a speech item: `finalAnswer`, `narration`, `toolCall`, `toolResult`, `thinking`, `event`.
- **Level** — the per-session filter: `quiet`, `answers`, `narrate`.
- **Active session** — the single session whose speech items are being voiced right now.
- **Unread turn** — a completed turn in a non-active session whose final answer has not been spoken.
- **Catch-up** — playing the final answers of a session's unread turns after switching to it.
- **Utterance** — rendered, speakable plain text for one speech item, divided into **segments** (sentences, or table rows), each of which is a skip unit.
- **Chunk** — one segment handed to a TTS backend for synthesis.
- **Backend** — an implementation of the `TTSBackend` protocol.
- **Hook receiver** — the `claudio hook` subcommand that Claude Code executes and that forwards the event to the app over the control socket.

## Repository layout

```
claudio/
├── README.md
├── Package.swift
├── Makefile
├── docs/                      # this documentation set
├── Sources/
│   ├── ClaudioControlProtocol/ # Codable wire types shared by app and CLI
│   ├── ClaudioCore/           # platform-neutral logic, no UI, fully tested
│   ├── ClaudioBackends/       # TTSBackend implementations
│   ├── ClaudioApp/            # menu bar application (SwiftUI + AppKit)
│   └── ClaudioCLI/            # `claudio` executable: CLI + hook receiver
├── Tests/
│   ├── ClaudioCoreTests/
│   ├── ClaudioBackendsTests/
│   ├── ClaudioIntegrationTests/
│   └── Fixtures/              # scrubbed real transcripts and expected outputs
├── Resources/
│   ├── Info.plist
│   ├── Claudio.entitlements
│   ├── AppIcon.icns
│   └── sounds/                # event chimes
├── scripts/                   # bundle, sign, notarize, release helpers
├── skills/speak/SKILL.md      # Claude Code skill wrapping the CLI
└── .github/workflows/ci.yml
```
