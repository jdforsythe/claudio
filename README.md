# Claudio

Claudio is a macOS menu bar app that reads your Claude Code sessions aloud. It watches the transcripts Claude Code writes, turns Claude's answers into clean speech, and plays them with no gaps and instant stop. Run several sessions at once: one holds the voice, the others chime and announce when they finish or need you, and switching plays a short catch-up of what you missed.

- Natural voices for free through Microsoft Edge's read-aloud service, with Apple's built-in voices as an offline fallback and OpenAI as an option.
- Nothing is installed into `~/.claude` unless you turn it on. Hooks for instant stop are opt-in.
- A floating HUD shows what is being spoken, with the current word highlighted.
- Everything is live: change the voice, speed or level and the next sentence uses it.

## Requirements

- macOS 15 or later, Apple Silicon or Intel.
- Claude Code 2.1 or later.
- Internet access for the default Edge voices (the Apple fallback works offline).

## Install

### Option 1: download the DMG

1. Download `Claudio-<version>.dmg` from the [Releases](https://github.com/jdforsythe/claudio/releases) page and open it.
2. Drag `Claudio.app` onto the Applications folder in the window.
3. Open Claudio from Applications.

Claudio is not yet notarized by Apple, so the first launch is blocked with "Apple could not verify Claudio". Click Done, open System Settings → Privacy & Security, scroll down and click **Open Anyway**, then confirm. This happens once. The Terminal alternative is:

```
xattr -dr com.apple.quarantine /Applications/Claudio.app
```

### Option 2: build from source

You need git and the Xcode Command Line Tools (Xcode itself is not required). This takes a few minutes and produces a build that macOS opens without the step above.

```
xcode-select --install          # skip if you already have the Command Line Tools
git clone https://github.com/jdforsythe/claudio.git
cd claudio
make install
```

`make install` builds the app, places `Claudio.app` in `/Applications`, and launches it. A waveform icon appears in the menu bar.

### First launch

Claudio asks for nothing. Start a Claude Code session in any terminal and it appears in the menu bar popover within a second. If it is the only live session it becomes active automatically and starts speaking.

To have it start when you log in: Settings → General → Launch at login.

## Using Claudio

### The popover

Click the menu bar icon. Each row is one Claude Code session with its project folder, status (working, idle, needs you, ended), an unread count, and a three-way level control:

| Level | Speaks |
|---|---|
| Quiet | Only events (a session finished, needs permission, needs input) |
| Answers | Events plus Claude's final answers |
| Narrate | Answers plus Claude's running commentary and short tool-call summaries ("Reading Parser dot swift") |

Click a row to make that session the one you hear. New sessions start at Answers; the session you activate starts at Narrate. The header has mute, pause, skip-sentence and skip-to-live buttons.

### Several sessions at once

Only the active session is voiced. When another session finishes a turn you hear a chime and "<name> finished", and its row shows an unread badge. When one needs permission or input you hear "<name> needs permission" and the HUD offers a one-key switch. Switch to a session with unread turns and Claudio says "<name>. Catching up on 3 turns.", reads those final answers oldest first, then "Live." or "You're caught up." Skip to live abandons the rest.

### Stopping

Submitting a new prompt in the active session stops speech immediately and discards what was queued. Without hooks this takes up to about half a second; with hooks (below) it is instant.

### The HUD

A small floating panel appears while Claudio speaks and hides a few seconds after it goes quiet. It shows the active session, progress through the current answer, transport buttons, and background-session prompts. The chevron opens captions with the spoken word highlighted; the pin keeps the panel visible. Drag it anywhere; it remembers its place.

### Hotkeys

Global, rebindable in Settings → Hotkeys:

| Shortcut | Action |
|---|---|
| ⌃⌥J | Pause / resume |
| ⌃⌥K | Skip the current sentence |
| ⌃⌥L | Skip to live (abandon catch-up) |
| ⌃⌥; | Next session |
| ⌃⌥' | Cycle the active session's level |

Toggle mute and show/hide HUD are available but unbound by default.

### Voices and speed

Settings → Voice. Pick the engine (Edge, Apple, or OpenAI), the voice, and the speed. "Fallback voice" is the Apple voice used when the online engine is slow or unreachable; Claudio switches per sentence and back again automatically, and tells you once an hour when that happens. For better offline voices, download a Premium voice in System Settings → Accessibility → Spoken Content → System Voice → Manage Voices.

OpenAI voices need an API key, entered in Settings → OpenAI; it is stored in your Keychain.

### Instant stop with hooks (optional)

Settings → Integration → Install Claude Code hooks. Claudio adds its own entries to `~/.claude/settings.json` so Claude Code tells it the moment you submit a prompt, when a turn ends, and when a session needs permission. Your existing hooks are left untouched, and turning the option off removes only Claudio's entries. If you later move `Claudio.app`, the popover offers a one-click repair.

### The `claudio` command (optional)

Settings → Integration → Install `claudio` command links `/usr/local/bin/claudio` to the copy inside the app. Then, from any terminal:

```
claudio status                 # what is playing, which session is active
claudio sessions               # list sessions
claudio switch yard            # activate by title, id prefix, or path
claudio level narrate          # set the level of this session (from inside Claude Code) or the active one
claudio pause | resume | skip | live | mute | unmute
claudio say "lunch is ready"   # speak something between sentences
claudio doctor                 # check the installation
```

Installing the `/speak` skill (same tab) lets you type `/speak off`, `/speak narrate` or `/speak live` inside a Claude Code session.

## Troubleshooting

- **Nothing is spoken.** Open the popover: is a session active, is its level above Quiet, is Claudio muted or paused? Run `claudio doctor` for a checklist.
- **Speech sounds like the Apple voice.** The Edge service was slow or unreachable, so Claudio fell back. It retries the Edge voice on every sentence; check your network, or pick Apple as the engine if you prefer it.
- **Speech does not stop when I type a prompt.** Turn on hooks (Settings → Integration) for instant stop; without them the stop follows the transcript with up to half a second of delay.
- **A session is missing.** Claudio watches `~/.claude/projects`. If Claude Code runs with another configuration directory (for example a second account in Orca), add that account's `projects` folder in Settings → Sessions.
- **Logs** are in `~/Library/Logs/Claudio/claudio.log`, and Settings → Advanced can export a diagnostics bundle.

## Uninstall

Settings → Integration turns off hooks, the command and the skill. `claudio uninstall --all` removes everything Claudio created (hooks, command, skill, settings, caches, logs, Keychain item); then drag `Claudio.app` to the Trash.

## For developers

Building, testing and the design documents are covered in [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md). Claudio is MIT licensed; the edge-tts protocol implementation is a clean-room Swift port informed by the LGPL-licensed Python `edge-tts` project and includes no code from it.
