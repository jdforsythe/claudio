# Claudio — developer guide

The end-user README is at the repository root. This file covers building, testing and the repository layout; the full design is in the numbered documents in this directory.

Claudio is a native macOS menu bar app that reads your Claude Code sessions aloud. It tails Claude Code's transcripts, optionally listens to Claude Code hooks, renders assistant output into clean speakable text, synthesizes it with a pluggable text-to-speech backend (edge-tts by default, Apple speech as fallback, OpenAI optional), and plays it gaplessly with instant cancel. It handles any number of concurrent sessions across terminals, Claude Desktop and Orca: one session holds the voice, the others announce when they finish or need you, and switching plays a catch-up digest of what you missed.

## Status

Implemented end to end from the design in `docs/`: menu bar app, HUD, settings, hotkeys, `claudio` CLI, hook receiver, native edge-tts port, Apple and OpenAI backends, and the test suite. Start at [`docs/00-index.md`](docs/00-index.md) for the design; see [`docs/13-decisions.md`](docs/13-decisions.md) D-28 to D-31 for the deviations made during implementation (a Sendable PCM type, a vendored KeyboardShortcuts, the CLI living at `Contents/Helpers/claudio`, HUD sizing).

## Documentation

Read [`00-index.md`](00-index.md) first; [`13-decisions.md`](13-decisions.md) D-28 to D-32 record where the implementation deviates from the original design and why.

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
- Swift 6.3 toolchain: the Xcode Command Line Tools are sufficient (`xcode-select --install`); Xcode is optional
- Optional: Homebrew for `swiftlint`, `swift-format`, `create-dmg` (`make bootstrap` installs them from the `Brewfile`)

## Build, run, test

```
make build          # debug build of the app and the CLI (.build/debug/Claudio, .build/debug/claudio-cli)
make run            # run the debug app unbundled (hooks and login item unavailable; see docs/10 §13)
make test           # unit + integration tests; no network and no audio device required
make app            # release build, bundle build/Claudio.app, ad-hoc sign
make install        # make app, then copy to /Applications and launch
make logs           # stream the unified log for the app
```

`make test` runs `swift test` when Xcode's XCTest is present and otherwise runs the same sources through an XCTest-compatible shim (`swift run claudio-tests`, decision D-32). `CLAUDIO_LIVE_TESTS=1` enables the network smoke test against the real Edge service.

Fast iteration on core logic: `.build/debug/claudio-tests TurnAssembler` runs one suite by substring.

The CLI product is named `claudio-cli` in SwiftPM and is bundled as `Contents/Helpers/claudio` (decision D-30: `claudio` and `Claudio` collide in one directory on case-insensitive APFS).

## Repository layout

```
Package.swift, Makefile, VERSION, Brewfile
Sources/ClaudioControlProtocol   wire types shared by app and CLI
Sources/ClaudioCore              transcript ingestion, sessions, arbiter, speech pipeline, control server, settings
Sources/ClaudioBackends          edge-tts port, Apple speech, OpenAI, fallback wrapper, voice catalog
Sources/ClaudioApp               menu bar app (SwiftUI + AppKit), HUD, settings, hotkeys
Sources/ClaudioCLI               `claudio` CLI and the hook receiver
Tests/                           suites, shared TestSupport, fixtures, XCTest shim and runner
Vendor/KeyboardShortcuts         vendored dependency (D-29)
Resources/                       Info.plist, entitlements, app icon
scripts/                         bundling, signing, notarization, fixture capture, test registry
skills/speak                     the /speak Claude Code skill
docs/                            this design set
```

## Releasing

`VERSION` is the single source of truth. Update it and `CHANGELOG.md` in one commit, then either push a `vX.Y.Z` tag (the GitHub Actions workflow builds, tests, bundles and attaches the DMG, zip, dSYMs and a sha256 file to a release) or publish from a Mac:

```
make release-assets
gh release create vX.Y.Z --title "Claudio X.Y.Z" --notes-file CHANGELOG.md build/Claudio-X.Y.Z.dmg build/Claudio-X.Y.Z.zip build/Claudio-X.Y.Z.sha256
```

Releases are ad-hoc signed until a Developer ID is configured (`make app SIGN_IDENTITY=... && make notarize`), so end users go through the one-time "Open Anyway" step described in the README. Developer ID signing and notarization are documented in [`10-build-lint-release.md`](10-build-lint-release.md) §11.

Then start a Claude Code session in any terminal. Claudio discovers it, lists it in the menu bar popover, and begins speaking when you activate it. Enable hooks in Settings → Integration for instant cancel and turn-end accuracy.

## License

MIT. The edge-tts protocol implementation is a clean-room Swift port informed by the LGPL-licensed Python `edge-tts` project; no code from that project is included.
