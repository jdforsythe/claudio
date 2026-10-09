# 01 — Product Requirements

## 1. Problem

Claude Code is a terminal agent that works for minutes at a time, producing a stream of narration, tool calls and a final answer. Reading that stream ties your eyes to the terminal. Existing read-aloud tools (claude-speak and similar) prove that hearing the stream is valuable, and that the naive implementation fails in specific ways:

- Speech is produced one chunk at a time with a full synthesis round trip and a player process spawn between chunks, so sentences arrive with audible gaps.
- Speech cannot be interrupted. Submitting a new prompt does not stop the voice from finishing the previous answer.
- Only one transcript is tracked at a time, chosen by heuristics, so a second concurrent session is silently dropped or the tracker flip-flops.
- Configuration is command-line flags that need a restart, plus a partially working web page.
- Installation drops scripts into `~/.claude/tools`, and the service runs as a background terminal process with no UI.
- Everything Claude writes is spoken at equal weight, including "Let me read that file."

Claudio exists to keep the thing that works (hearing Claude as it works, in normal terminal mode, with voices better than the built-in Mac voices) and to fix every item above.

## 2. Users

One primary user: a developer running several Claude Code sessions at once across terminal tabs, Claude Desktop, and Orca worktrees, who wants to listen rather than read, and who switches attention between sessions during the day. The product is personal-first but must be installable by someone else from a release artifact without reading source.

## 3. Goals

1. **Hear Claude with no visible lag between sentences.** Time from a sentence appearing in the transcript to its first audio under 1.5 s on a warm backend; inter-sentence gap under 50 ms.
2. **Stop instantly when the user moves on.** New prompt in the active session cancels all pending speech for that session within 100 ms when hooks are installed, within 600 ms from the transcript alone.
3. **Handle N sessions.** All live sessions are discovered automatically and listed. Exactly one is voiced. Others announce events and accumulate unread turns.
4. **Switch and catch up.** Switching to a session plays a digest of what was missed and then goes live.
5. **Control what is spoken per session, at will.** Three levels, switchable while running, from the popover, the HUD, hotkeys, or the CLI.
6. **Zero footprint by default.** Works with no changes to `~/.claude`. Hooks are opt-in and point into the app bundle.
7. **Pluggable voices.** Backends implement one protocol. Default backend is a native port of edge-tts. Apple's speech synthesizer is always present as fallback. OpenAI is available with an API key.
8. **Everything configurable live.** No restarts for any setting.
9. **A real Mac app.** Menu bar item, popover, floating HUD with captions, settings window, login item, global hotkeys.

## 4. Non-goals

- Not a screen reader. Claudio speaks only what Claude writes plus a few status events.
- No voice input.
- No LLM summarization of long answers.
- No bundled Python or Node runtime.
- No cross-platform support.
- No cloud account or telemetry.

## 5. Definitions of the speech categories

Every speakable thing is a **speech item** with exactly one category.

| Category | Source | Example spoken text |
|----------|--------|---------------------|
| `finalAnswer` | Assistant `text` blocks in the last message of a turn | The answer itself, rendered to speech |
| `narration` | Assistant `text` blocks in a message that also contains a `tool_use` block, or that is followed by another assistant message in the same turn | "I'll read the parser first." |
| `toolCall` | Synthesized by Claudio from `tool_use` blocks | "Running: git status." / "Editing Parser.swift." / "Agent started: analyze source." |
| `toolResult` | `tool_result` blocks; only errors are ever rendered | "Bash failed: command not found." |
| `thinking` | `thinking` blocks | Raw thinking text |
| `event` | Hooks and transcript signals | "Yard needs permission." / "Vea finished." / chime |

Subagent output is not its own category. Subagent start and completion appear as `toolCall` items on the parent session ("Agent finished: research TTS engines"). Subagent narration is never spoken.

## 6. Speech levels

Each session has a level. Levels are cumulative.

| Level | Speaks | Default for |
|-------|--------|-------------|
| `quiet` | `event` only | Nothing by default; user choice |
| `answers` | `event` + `finalAnswer` | Newly discovered sessions that are not active |
| `narrate` | `answers` + `narration` + `toolCall` | The active session when first activated, unless a per-project default says otherwise |

`thinking` and `toolResult` are controlled by two global advanced toggles, both off by default, and are spoken only when the toggle is on and the session level is `narrate`.

Level changes take effect at the next speech item. Changing the active session's level to a lower one discards queued items of categories no longer included.

## 7. Arbitration: who gets the voice

- Exactly one session is **active** at any time, or none.
- Only the active session's `finalAnswer`, `narration`, `toolCall`, `toolResult` and `thinking` items are voiced.
- `event` items from **any** session are voiced, subject to the global events toggle, as short announcements inserted between segments of whatever is playing. They never cancel the active queue.
- When a non-active session completes a turn, Claudio plays a chime, speaks "<session name> finished", and increments that session's unread count. The HUD shows a badge.
- When a non-active session requests permission or needs input, Claudio speaks "<session name> needs permission" / "<session name> needs input" and shows a one-key switch prompt in the HUD.
- The user switches the active session from the popover, the HUD, the cycle hotkey, or the CLI. Focus-following is not in v1.
- On launch, no session is active until the user picks one, except: if exactly one live session exists, it becomes active automatically.
- If the active session ends (SessionEnd or process gone), it stays active in an "ended" state so catch-up remains possible; no automatic switch.

## 8. Catch-up

When the user switches to a session with unread turns:

1. The current queue is cancelled.
2. Claudio speaks a short cue: "<session name>. Catching up on N turns."
3. For each unread turn, oldest first, up to the last 5 (older ones are dropped from catch-up but still visible in the popover), the `finalAnswer` is rendered and spoken. Narration and tool calls are never part of catch-up, regardless of level.
4. If the session is mid-turn when catch-up finishes, Claudio speaks "Live." and continues at the session's level with the current turn's items from that point forward. If the session is idle, Claudio speaks "You're caught up."
5. A **Skip to live** control (HUD button, hotkey, CLI) abandons the remaining catch-up and goes straight to step 4.
6. Unread count resets to zero when catch-up completes or is skipped.

## 9. Cancel and queue semantics

| Trigger | Active session | Non-active session |
|---------|---------------|-------------------|
| Human prompt submitted | Cancel all queued items for that session, including catch-up. Stop audio within one fade. | No audible effect. Unread turns remain. |
| Assistant block arrives mid-speech | Append to queue, gapless. | Accumulate. |
| Turn completes | Nothing special; the final answer is already queued. | Chime + "<name> finished"; unread += 1. |
| Permission / input needed | Speak the announcement. | Speak the announcement; HUD shows switch prompt. |
| Turn interrupted by the user (Escape in Claude Code) | Treat as prompt: cancel. | Nothing. |
| User switches session | Cancel, then catch-up on the new session. | — |
| User pauses | Pause playback at the current buffer; queue intact; new items keep queuing. | — |
| User skips segment | Stop current segment, start next segment immediately. | — |
| User changes level downward | Drop queued items no longer included. | — |
| Backend failure | Fall back per chunk to Apple speech; continue. | — |

Every cancel applies a 15 ms linear fade-out so there is no click.

## 10. Text rendering rules (summary; full rules in document 05)

- Fenced code blocks → "code block" or "<language> code block", never read.
- Tables → every row read as "Header: value, Header: value." Each row is its own segment and skip unit.
- Inline code → read with cleanup: `snake_case` → "snake case", `camelCase` → "camel case", `a.b.c` → "a b c", `->` → "to".
- File paths → last path component only.
- URLs → "link".
- Headers → text only, followed by a pause.
- Bullets and numbered lists → marker stripped, each item its own segment.
- Bold, italics, strikethrough → plain text.
- Emoji → removed.
- No length cap on any answer.

## 11. User interface (summary; full spec in document 07)

- **Menu bar item.** Icon reflects state: idle, speaking, paused, muted, N unread.
- **Popover.** Session list (name, project, status, unread, level), transport controls, global events toggle, hooks status, link to settings.
- **HUD.** Floating non-activating panel, draggable, remembers position. Shows active session name and colour, playback state, segment progress, and background-session prompts. A collapsible caption area, closed by default, shows the current segment with the word being spoken highlighted.
- **Settings window.** Backend and voice, rate, fallback voice, hotkeys, hooks install toggle, events and chimes, advanced toggles (thinking, tool results), extra transcript roots, per-project defaults, launch at login.
- **Hotkeys** (defaults, all rebindable): Ctrl+Option+J pause/resume, Ctrl+Option+K skip segment, Ctrl+Option+L skip to live, Ctrl+Option+; cycle active session, Ctrl+Option+' toggle level of active session. Two further actions, toggle mute and toggle HUD, are available but unbound by default.

## 12. Control surfaces

- Popover and HUD (mouse).
- Global hotkeys.
- `claudio` CLI over a local Unix socket: `status`, `sessions`, `switch`, `level`, `pause`, `resume`, `skip`, `live`, `mute`, `say`, `hook`.
- `/speak` Claude Code skill that wraps the CLI.

## 13. Backends

| Backend | Default role | Requirements | Notes |
|---------|--------------|--------------|-------|
| Edge | Default | Network | Native Swift port of edge-tts. Rate via SSML prosody. Word boundaries supported. |
| Apple | Fallback, always available | None; Premium voices improve quality after a one-time download in System Settings | Word boundaries via delegate. |
| OpenAI | Optional | API key | `gpt-4o-mini-tts`, streaming PCM. No word boundaries (approximated). |

Fallback is automatic and per chunk: if the primary backend fails or exceeds 3 s to first audio, that chunk is synthesized by Apple with the configured fallback voice. A one-time HUD notice appears the first time this happens per hour. The primary backend is retried for the next chunk.

## 14. Installation and footprint

- Distributed as `Claudio.app`. Install by dragging to `/Applications` or via `make install`.
- Default footprint outside the bundle: `~/Library/Application Support/Claudio/` (state, socket, per-project prefs, logs) and `~/Library/Preferences/com.jdforsythe.claudio.plist`.
- Optional footprint, only when the user enables each: hook entries in `~/.claude/settings.json`; a symlink `/usr/local/bin/claudio`; the `/speak` skill in `~/.claude/skills/speak/`.
- Uninstall removes exactly what it created and nothing else.

## 15. Performance budgets

| Metric | Budget |
|--------|--------|
| Transcript write → speech item emitted | ≤ 300 ms |
| Segment ready → first audio (Edge, warm) | ≤ 1200 ms |
| Segment ready → first audio (Apple) | ≤ 150 ms |
| Inter-segment gap | ≤ 50 ms |
| Prompt submitted → audio stopped (hooks) | ≤ 100 ms |
| Prompt submitted → audio stopped (transcript only) | ≤ 600 ms |
| Hook receiver process lifetime | ≤ 20 ms |
| App idle CPU | < 0.5 % |
| App idle memory | < 80 MB |
| App launch to menu bar icon | < 500 ms |

## 16. Success criteria

- Listening to a 10-minute narrate-level session, the user never hears a gap long enough to wonder whether it stopped.
- Submitting a prompt while Claudio is speaking stops it before the user has typed the second word of the next prompt.
- Running three sessions in Orca, the user can tell which one finished without looking, switch with one hotkey, and hear what they missed.
- Changing voice, rate or level takes effect on the next sentence with no restart.
- A fresh Mac with the app dragged into `/Applications` speaks within 30 seconds of launch with no other setup.
- edge-tts going down degrades to the Apple voice without silence or a crash.

## 17. User stories with acceptance tests

Each story maps to at least one integration test in document 09.

1. **Narrated single session.** Given one live session at `narrate`, when Claude writes narration, a tool call and a final answer, then Claudio speaks all three in order with gaps under 50 ms.
2. **Instant cancel.** Given Claudio is mid-sentence on the active session, when a human prompt record appears (or UserPromptSubmit fires), then audio stops within budget and nothing from the old queue plays afterwards.
3. **Background completion.** Given sessions A (active) and B, when B's turn completes, then Claudio plays the chime and "B finished" between A's segments, and B's unread count is 1.
4. **Catch-up digest.** Given B has 3 unread turns, when the user switches to B, then Claudio speaks the cue and the three final answers in order, nothing else, then "You're caught up" or "Live.".
5. **Skip to live.** Given catch-up is playing, when the user presses skip-to-live, then catch-up stops within one fade and live items follow.
6. **Level change mid-stream.** Given the active session is at `narrate` with narration queued, when the user sets `answers`, then queued narration is dropped and the final answer still plays.
7. **Table reading.** Given a final answer containing a 4-row table, then Claudio speaks 4 row segments, each skippable.
8. **Backend fallback.** Given Edge returns 403 on every attempt, then each chunk is spoken by the Apple fallback voice, one notice appears, and no chunk is lost.
9. **Zero footprint.** Given a fresh install with hooks disabled, then `~/.claude` is byte-identical before and after an hour of use.
10. **Hook coexistence.** Given `~/.claude/settings.json` contains Orca's and other hooks, when Claudio installs and later uninstalls its hooks, then every pre-existing entry is unchanged.
11. **Resumed session.** Given `claude --resume` appends to an old transcript, then Claudio speaks only new records.
12. **Session liveness.** Given a session with no writes for 23 hours, then it is still listed; at 24 hours it is removed.
