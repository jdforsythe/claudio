# 11 — Debugging and Operations

Claudio has no remote telemetry and no crash reporter. Everything needed to diagnose a problem is in the unified log, the file log mirror, and the output of `claudio doctor`. This document describes the logging design, the diagnostic commands, a runbook per symptom, how to investigate performance without Instruments, crash symbolication, upgrade behaviour, and the support bundle.

## 1. Logging

### 1.1 Design

All logging goes through `Log` (`Sources/ClaudioCore/Support/Log.swift`), a namespace of `os.Logger` instances under one subsystem:

```swift
public enum Log {
    public static let subsystem = "com.jdforsythe.claudio"
    public static let transcript = Logger(subsystem: subsystem, category: "transcript")
    public static let sessions   = Logger(subsystem: subsystem, category: "sessions")
    public static let arbiter    = Logger(subsystem: subsystem, category: "arbiter")
    public static let speech     = Logger(subsystem: subsystem, category: "speech")
    public static let playback   = Logger(subsystem: subsystem, category: "playback")
    public static let edge       = Logger(subsystem: subsystem, category: "backend.edge")
    public static let apple      = Logger(subsystem: subsystem, category: "backend.apple")
    public static let openai     = Logger(subsystem: subsystem, category: "backend.openai")
    public static let control    = Logger(subsystem: subsystem, category: "control")
    public static let hooks      = Logger(subsystem: subsystem, category: "hooks")
    public static let ui         = Logger(subsystem: subsystem, category: "ui")
    public static let settings   = Logger(subsystem: subsystem, category: "settings")
}
```

`print` is forbidden in library and app code by a SwiftLint custom rule (document 10 §8). The CLI prints to stdout/stderr because that is its output; its internal diagnostics use `Log.control`.

### 1.2 Levels

| Level | Used for | Examples |
|-------|----------|----------|
| `.fault` | Invariant violations that should never happen; the app continues | Scheduler received a buffer for an unknown segment; playback engine failed to start twice |
| `.error` | Operation failed and the user may notice | Backend request failed after retry; settings.json malformed; socket bind failed |
| `.warning` | Degraded but handled | Fallback backend used; probe timed out; unknown record type ratio high; hook path stale |
| `.info` | Every state transition in document 02 §7 | Session created/ended, status change, turn start/end, arbiter mode change, segment lifecycle (synthesizing/ready/playing/finished/cancelled), hook received, setting changed |
| `.debug` | Everything dropped, deduplicated, filtered or ignored, with the reason; per-record parse results; per-buffer playback scheduling | "dropped item (level=answers excludes narration)", "dedup: hook Stop matched transcript finalAnswer turn=…", "ignored record type=queue-operation" |

`logLevel` in settings (default `info`) controls the file mirror only; the unified log always receives everything and macOS applies its own retention (debug is not persisted unless streamed).

### 1.3 Privacy

Spoken text, prompt text, file paths from transcripts and tool inputs are logged with `privacy: .private`:

```swift
Log.speech.info("segment ready session=\(sessionID, privacy: .public) turn=\(turnID, privacy: .public) kind=\(kind, privacy: .public) chars=\(text.count) text=\(text, privacy: .private)")
```

Session ids, turn ids, segment ids, record types, categories, levels, durations and counts are `.public`. In `log show` output, private fields appear as `<private>` unless the system is configured to reveal them (`sudo log config --mode "private_data:on"`), which the developer does on their own machine when a redaction hides the problem.

### 1.4 File mirror

`FileLogSink` subscribes to the same call sites (the `Log` namespace wraps `Logger` in a thin struct that forwards to both) and writes `~/Library/Logs/Claudio/claudio.log` at or above the configured `logLevel`. Format:

```
2026-10-09T14:03:21.482Z INFO  arbiter    mode=live session=562358f2 turn=e89a4f1b
2026-10-09T14:03:21.611Z WARN  backend.edge  first-audio timeout 3.0s segment=9f1c… → fallback
```

Rotation: 5 files × 5 MiB (`claudio.log`, `claudio.log.1` … `.4`). The mirror exists because `log show` loses debug entries after reboot and because the support bundle (§7) needs a plain file.

### 1.5 Reading logs

```
# live, everything
log stream --predicate 'subsystem == "com.jdforsythe.claudio"' --level debug --style compact
make logs                                   # same thing

# one category
log stream --predicate 'subsystem == "com.jdforsythe.claudio" AND category == "backend.edge"' --level debug

# last 30 minutes, including the CLI's log lines
log show --last 30m --predicate 'subsystem == "com.jdforsythe.claudio"' --info --debug --style compact

# file mirror
tail -f ~/Library/Logs/Claudio/claudio.log
```

## 2. Diagnostic commands

All are subcommands of `claudio` (document 04 §7 lists the user-facing commands; these are the diagnostic subset). Every command supports `--json`.

### `claudio status [--json]`

```
Claudio 0.1.0 (412) a1b2c3d — running (pid 48211), uptime 3h12m
Backend     edge (en-US-GuyNeural, rate 1.15) · fallback apple (Ava (Premium))
Active      claudio-a7 "Claude-speak redesign" — live, narrate
Queue       2 segments ready, 1 playing, 0 synthesizing
Sessions    3 live (1 busy, 1 waiting, 1 idle), 0 ended
Hooks       installed (7/7, current path)
Socket      ~/Library/Application Support/Claudio/claudio.sock
Fallbacks   2 in the last hour (last 14:01:07, edge timeout)
Unknown     0.0% unknown record types in the last hour
```

JSON is `StatusReport` from `ClaudioControlProtocol`.

### `claudio sessions [--json] [--all]`

Lists `SessionSummary` rows: id (short), title, cwd, entrypoint, status, level, unread, last activity, pid. `--all` includes ended sessions still within the 24 h window.

### `claudio doctor [--json] [--bundle]`

Runs each check, prints `PASS`/`WARN`/`FAIL` with a one-line explanation and a fix hint, and exits 0 when nothing failed, 1 when any check failed, 2 when the app is not running (only the checks that don't need the app are run).

| Check | PASS when | WARN when | FAIL when |
|-------|-----------|-----------|-----------|
| App running | socket ping succeeds | — | no socket or connect refused |
| App location | bundle in `/Applications` | elsewhere (login item may not persist) | unbundled binary |
| Roots | every configured root exists and is readable, default root has ≥ 1 project dir | a root is empty | a root is missing or unreadable |
| `claude` CLI | `claude agents --json` returns within 3 s | not on PATH (probe disabled, liveness falls back to timeout only) | returns non-JSON |
| Transcript schema | unknown record ratio in last hour < 5 % | 5–20 % | > 20 % (Claude Code likely changed the format) |
| Stop-reason variant | newest live transcript shows `stop_reason` populated on text blocks ("primary heuristic active") | absent ("secondary heuristic active") | — |
| Hooks | disabled, or installed with every command pointing at this bundle | enabled but 1–6 of 7 present, or path stale | enabled but settings.json unparseable |
| settings.json | parses | has no `hooks` key | invalid JSON |
| Edge reachability | voices list fetch 200 within 5 s | 403 after skew retry (constants may need a bump) | network error |
| Apple voices | at least one Premium or Enhanced voice installed | only default-quality voices | no voices (should be impossible) |
| Fallback voice | configured voice exists | configured voice missing, auto-pairing in effect | — |
| Login item | matches the `launchAtLogin` setting | `SMAppService.status == .requiresApproval` | registration error |
| Audio output | a default output device exists | — | none |
| Socket permissions | mode 0600, owned by user | — | otherwise |
| Disk | Application Support writable, logs dir writable | — | not writable |

`--bundle` is described in §7.

### `claudio tail [<session>] [--all-sessions] [--raw]`

Streams `SpeechItem`s as the registry produces them: timestamp, session short id, turn short id, category, filter decision for the current level, and the first 80 characters of text. `--raw` also prints each parsed `TranscriptRecord` type with its `uuid`. This is the fastest way to see how a live session is being classified and why an item was or wasn't spoken. Items are delivered over the control socket as a subscription (`ControlRequest.subscribe(.items)`).

### `claudio render <file.md> [--segments] [--json]`

Runs `SpeechTextRenderer` and `SentenceSegmenter` on a markdown file and prints the resulting segments, one per line, prefixed with the segment kind:

```
sentence   Claudio is a native macOS menu bar application that reads Claude Code sessions aloud.
heading    Reading order
tableRow   Number: 01, Document: Product Requirements, What it covers: Problem, goals, …
cue        swift code block.
```

Rule tuning loop: edit `MarkdownSpeechRules.swift`, `swift build --product claudio`, `claudio render sample.md`. The CLI does not link `ClaudioCore`, so `render` sends the file contents over the socket (`ControlRequest.render(markdown:)`) and the app renders it. When the app is not running, `render` prints "Claudio is not running" and exits 1.

### `claudio bench [--backend edge|apple|openai] [--fixture <name>] [--runs N]`

Feeds the final answers of a fixture (default `single-turn-final-answer`) through the live pipeline with a `RecordingPlaybackSink` and the real backend, N times (default 3), and prints:

```
backend=edge voice=en-US-GuyNeural rate=1.0 fixture=single-turn-final-answer runs=3 segments=27
time-to-first-audio   p50 412 ms   p95 688 ms   max 702 ms
inter-segment gap     p50   3 ms   p95   9 ms   max  14 ms   (>50 ms: 0)
synth per segment     p50 530 ms   p95 910 ms
fallbacks             0
```

No audio is played. Results are pasted into milestone acceptance notes (document 12).

### `claudio debug dump-state` (hidden)

Prints the full in-memory state: every `Session` with its turns and items (text truncated to 60 chars), the arbiter mode and active id, scheduler queue with segment states, playback position, recent `BackendNotice`s, settings snapshot. Hidden from `--help`; used in bug reports and by the support bundle.

### `claudio debug expected <fixture>` (hidden)

Runs the fixture through `TurnAssembler` and prints an `expected.json` candidate (document 09 §2.2).

## 3. Runbooks

Each runbook is symptom → checks → fix. "Check" steps reference the commands above and the log categories in §1.

### 3.1 Nothing is spoken

1. `claudio status`. If "not running": launch the app. If Active is `none`: pick a session in the popover; with two or more sessions nothing auto-activates.
2. Active session's level is `quiet`? Only events speak. Set `answers` or `narrate`.
3. Muted or paused? The menu bar icon shows `speaker.slash` or `pause.circle`. `claudio unmute`, `claudio resume`.
4. `claudio tail` while Claude writes. Items appearing with `filtered=false` but no audio → backend or playback. Items not appearing → ingestion (go to 3.4).
5. `log stream … category == "backend.edge"`. Repeated `error` lines → see 3.7. Fallback lines present but still silent → `category == "playback"`: engine start failure means no output device or a device change loop; `claudio doctor` Audio output check; replug or select a device in System Settings → Sound.
6. Apple fallback silent too, engine running, buffers scheduled (debug log shows `scheduled frames=4800`) → system volume or the output device is a headset with the mic muted on the output path; test with `say hello`.

### 3.2 Speech lags or has gaps

1. `claudio bench` with the configured backend. Time-to-first-audio p50 above 1200 ms or gaps above 50 ms localise the problem to the backend or to Claudio respectively.
2. Gaps with low synth times → playback: `category == "playback"` for `segment underrun` warnings. Lookahead may be too low for a slow machine; raise the hidden `lookahead` setting to 3 (document 08).
3. High synth times on Edge → network. `ping speech.platform.bing.com`; check for a VPN or proxy adding latency; try the Apple backend to confirm.
4. First sentence slow only → connection warm-up. The app opens a warm-up WebSocket at start and after settings changes; if `category == "backend.edge"` shows `warmup failed`, the first real request pays the TLS cost.
5. Everything slow including Apple → CPU contention. `top -o cpu`; see 3.13.

### 3.3 Speech doesn't stop on a new prompt

1. `claudio hooks status`. Not installed → transcript-only mode; expected cancel latency is up to 600 ms (poll of FSEvents latency plus write lag), not instant. Install hooks for < 100 ms.
2. Installed but "stale path" → the app moved; click Repair or `claudio hooks install`.
3. Installed and current → `log stream … category == "hooks"` while submitting a prompt. No `UserPromptSubmit received` line → Claude Code is not running the hook: check `~/.claude/settings.json` for the entry, run the receiver by hand: `echo '{"hook_event_name":"UserPromptSubmit","session_id":"x"}' | /Applications/Claudio.app/Contents/MacOS/claudio hook; echo $?` must print 0.
4. Hook received but no cancel → the prompt belongs to a non-active session (by design) or the `session_id` didn't match a known session (log shows `unknown session`). The session may be under a root that isn't watched (3.4).
5. Transcript-only mode and the prompt record isn't recognised as human → `claudio tail --raw` shows the `user` record; if `origin.kind` and `promptSource` are both absent on this Claude Code version, the fallback rule (string content, no `tool_result`) applies; if it still isn't detected, capture a fixture and file a bug.

### 3.4 Session missing from the list

1. `claudio sessions --all`. Present but `ended` → the process exited or 24 h passed; it's still switchable for catch-up.
2. Which root? Transcripts live under `~/.claude/projects/<encoded cwd>/`. For an Orca secondary account, under `<CLAUDE_CONFIG_DIR>/projects/`; add that path to Settings → Sessions → Extra roots.
3. Orca structured (non-terminal) sessions: confirm where they write with `find ~/.claude -newer /tmp/marker -name '*.jsonl'` after a prompt. If they land outside `~/.claude/projects` (for example a `transcripts/` root), add that root.
4. `claudio doctor` Roots check FAIL → path typo or permissions.
5. Transcript on a network or FUSE volume → FSEvents may not fire; not supported; move the root to local disk.
6. Session appeared and vanished immediately → `category == "sessions"` for `expired` (clock jumped; see 3.17) or `removed: file deleted`.

### 3.5 Wrong session is active

Claudio never auto-switches except when exactly one live session exists at launch. Check `category == "arbiter"` for `activate reason=`: `user` (popover/hotkey/CLI), `single-live-session`, `restore` (from `sessions.json` at launch). A `/speak` skill or script calling `claudio switch` without an argument resolves "this session" from `CLAUDE_CODE_SESSION_ID`, then `ORCA_WORKTREE_PATH`, then `$PWD`; a cwd shared by two sessions is ambiguous and the CLI prints the candidates instead of switching.

### 3.6 Duplicate speech

The same final answer spoken twice means the hook/transcript dedup failed.

1. `log stream … category == "sessions"` at debug: a successful dedup logs `dedup: hook Stop matched transcript finalAnswer turn=…`. Two `finalAnswer emitted` lines for one turn with different `turnID`s means the hook's `prompt_id` and the transcript's `promptId` differ (Claude Code version mismatch) — capture a fixture and the hook payload; the dedup window falls back to text equality (`last_assistant_message` vs rendered text prefix) and should still catch it; if the texts differ (hook message is the raw markdown, transcript text identical) the normalisation function is at fault.
2. Two distinct text blocks in the same final message are two items by design (document 03 §6); they are not duplicates.
3. Both the main transcript and a subagent transcript emitting the same text → `isSidechain` not honoured; check `category == "transcript"` for the file path.

### 3.7 Edge returns 403

1. One 403 followed by `skew adjusted by N s` and success is normal when the Mac's clock drifts; nothing to do. Fix the clock (System Settings → General → Date & Time → automatic) to avoid the retry.
2. 403 twice on every request → Microsoft changed the anti-bot handshake, almost always by requiring a newer Chromium version string. Procedure:
   - Find the current stable Edge version: https://learn.microsoft.com/en-us/deployedge/microsoft-edge-relnote-stable-channel (or `brew info --cask microsoft-edge`).
   - Update `CHROMIUM_FULL_VERSION` in `Sources/ClaudioBackends/Edge/EdgeConstants.swift` (currently `143.0.3650.75`). `SEC_MS_GEC_VERSION` and the `User-Agent` derive from it automatically.
   - `CLAUDIO_LIVE_TESTS=1 swift test --filter EdgeLiveSmokeTests`.
   - If still 403, diff against the current upstream `rany2/edge-tts` `constants.py` and `drm.py`; the token derivation (`Sec-MS-GEC`) or the trusted client token may have changed. Port the change into `EdgeDRM.swift` and add a vector to `test_EdgeDRM_secMsGec_matchesKnownVector`.
   - Release. Until then, users are on the Apple fallback automatically with one notice per hour.
3. `claudio doctor` Edge check reports the same condition.

### 3.8 Edge voices list empty

The voices endpoint failed; the app uses the cached `voices-edge.json` (24 h TTL, document 08) and, failing that, a built-in list of 12 common voices so the picker is never empty. `category == "backend.edge"` shows the HTTP status. 403 here follows the same procedure as 3.7. Delete the cache file to force a refetch.

### 3.9 Apple voice sounds robotic

No Premium or Enhanced voice is installed, so the default-quality voice is used. Settings → Voice shows the hint banner; "Open Spoken Content settings" opens System Settings → Accessibility → Spoken Content. Click System Voice → Manage Voices, download Ava (Premium) or another Premium voice, then reopen Settings → Voice; `claudio doctor` Apple voices check moves to PASS and the fallback voice auto-pairs to the Premium voice unless one is explicitly set.

### 3.10 Claude Code shows hook errors

Claude Code displays "hook error" when a hook exits non-zero or writes to stderr with a non-zero exit.

1. Run the receiver manually (3.3 step 3). Non-zero exit → the binary is missing (app moved/deleted) or not executable. Reinstall the app or Repair hooks.
2. "Operation not permitted" → the bundle lost its ad-hoc signature after being modified; `make install` again.
3. The receiver is designed to exit 0 even when the app is not running; if Claude Code reports a timeout, the socket connect is hanging rather than failing — a stale socket file with a dead listener. Launch the app (it replaces stale sockets) or delete `~/Library/Application Support/Claudio/claudio.sock`.

### 3.11 Orca rewrote settings.json and Claudio's entries vanished

Orca manages its own hook entries and, in some versions, rewrites the `hooks` object wholesale. `claudio hooks status` reports "0/7 installed" while `hooksEnabled` is true; the popover footer shows "Hooks missing — Repair". Click Repair or run `claudio hooks install`. The app also re-checks on every `SessionStart` it observes and repairs automatically when `hooksEnabled` is true and entries are missing, logging `hooks: repaired after external change`. Backups of every version Claudio wrote are in `~/Library/Application Support/Claudio/backups/`.

### 3.12 HUD not visible or off-screen

1. Settings → General → Show HUD is on? The HUD also hides 4 s after the queue drains unless pinned; speak something.
2. Off-screen after a display change: the frame is clamped to the visible screen on every show, so this only happens if the saved frame is on a display that reconnects after launch. `defaults delete com.jdforsythe.claudio hudFrame` then relaunch, or Settings → Advanced → Reset HUD position.
3. Hidden behind a full-screen app: the panel uses `.canJoinAllSpaces` and `.fullScreenAuxiliary`; some full-screen games capture the display and nothing can float above them.

### 3.13 High CPU

1. `top -pid $(pgrep -x Claudio)`; `sample Claudio 5` to get a call-stack sample without Instruments.
2. Hot in `SessionDiscovery`: an FSEvents storm. A very large `~/.claude/projects` (thousands of old sessions) or a tool rewriting files in a watched root. Claudio only opens files matching the transcript path pattern, but FSEvents delivers every event. Add an exclusion or prune old project directories; the 24 h liveness rule means old files are never opened, so pruning is safe.
3. Hot in `TranscriptTailer`: a handle leak (idle handles should close after 60 s) or a transcript being appended at very high rate (a session dumping megabytes of tool output). `claudio debug dump-state` shows open handle count; file a bug if it grows.
4. Hot in `PlaybackEngine` while idle: the engine failed to stop after 30 s idle; `category == "playback"` shows `engine stop skipped: reason`.
5. Hot in `SpeechTextRenderer`: a pathological regex on a huge final answer. `claudio render` on the captured answer reproduces it; the renderer caps input at 200 000 characters and falls back to raw text beyond that.

### 3.14 App doesn't start at login

1. `claudio doctor` Login item check. `requiresApproval` → System Settings → General → Login Items → allow Claudio.
2. The app must be in a stable location; moving it after registering breaks the login item. Toggle Launch at Login off and on after moving.
3. Unbundled builds cannot register (document 10 §13).

### 3.15 Second instance / "Claudio is already running"

Launching the app while it runs pings the socket; on success the second instance tells the first to show its popover and exits. If the first is hung (ping times out at 500 ms), the second instance replaces the socket and starts; the hung instance is left for the user to force-quit, and `category == "control"` logs `replaced stale socket owned by pid N`.

### 3.16 Captions out of sync with speech

1. Highlighting lags consistently by a fixed amount → playback position sampling offset. The HUD maps word boundary offsets (relative to segment audio start) onto `segmentStarted` wall time plus `playerTime`; a constant lag indicates the output device latency (`outputNode.presentationLatency`) isn't being added; it is read at engine start and after configuration changes.
2. Highlighting drifts within a segment on the OpenAI backend → expected; boundaries are approximated by character proportion (document 05 §9).
3. Highlighting jumps backwards → two segments' boundary tables were merged; `category == "speech"` at debug shows `boundaries segment=… count=…`; file a bug with the dump.
4. No highlighting on Edge → `wordBoundaryEnabled` false in the speech.config frame or metadata frames being dropped; `test_EdgeTTSBackend_audioMetadata_emitsWordBoundariesInSeconds` guards this.

### 3.17 Sessions expire or reappear unexpectedly

Liveness uses `lastActivity` from record timestamps and the local clock. A Mac waking from a long sleep, or a clock change, can expire sessions at once (`category == "sessions"`: `expired n=…`). Restarting the app restores sessions from `sessions.json` whose `lastActivity` is within 24 h; new records for an expired session recreate it.

## 4. Performance investigation without Instruments

Xcode's Instruments is unavailable with Command Line Tools only. The equivalents:

- **Signposts.** `OSSignposter(subsystem: Log.subsystem, category: "perf")` marks intervals `synthesize` (request → `.finished`), `firstAudio` (request → first `.audio`), `segmentPlay` (`segmentStarted` → `segmentFinished`), `renderUtterance`, `parseBatch`. Read them with:

  ```
  log stream --predicate 'subsystem == "com.jdforsythe.claudio" AND category == "perf"' --signpost
  log show --last 10m --predicate '… AND category == "perf"' --signpost --style json > perf.json
  ```

  `scripts/perf-summary.swift perf.json` prints p50/p95 per interval name.

- **`claudio bench`** (§2) for end-to-end numbers against the real backend.
- **`sample`** for CPU hot spots: `sample Claudio 10 -file /tmp/claudio.sample.txt`; the output is a call tree with symbol names from the binary's own symbol table (debug builds) or the dSYM (release, §5).
- **`spindump`** for hangs: `sudo spindump Claudio 5 -file /tmp/claudio.spindump.txt`.
- **`heap` / `leaks`** for memory: `leaks Claudio` works on debug and ad-hoc builds; `heap Claudio` shows object counts. The idle memory budget is 80 MB.
- **`fs_usage`** to confirm the tailer reads only what changed: `sudo fs_usage -w -f filesys Claudio | grep jsonl`.
- **`nettop -p $(pgrep -x Claudio)`** for Edge/OpenAI traffic.

## 5. Crashes

- macOS writes crash reports to `~/Library/Logs/DiagnosticReports/Claudio-<date>.ips`. Console.app → Crash Reports shows them symbolicated when the dSYM is on the machine.
- Release builds are produced with `-Xswiftc -g` and `dsymutil` (document 10 §3), and every GitHub release ships `Claudio-<version>-dSYM.zip`. Keep the dSYM for each shipped version; the UUID in the crash report (`Binary Images` section) must match `dwarfdump --uuid Claudio.dSYM`.
- Manual symbolication of a frame:

  ```
  atos -o build/dSYM/Claudio.dSYM/Contents/Resources/DWARF/Claudio -arch arm64 -l <load address> <frame address>
  ```

  Load address and frame addresses come from the `.ips` file's thread backtrace and binary image table.
- There is no third-party crash reporter and no automatic upload. A user attaches the `.ips` file and the support bundle (§7) to an issue.
- Known-safe crash sources to check first: AVAudioEngine throwing on a device change while stopping (handled by `PlaybackEngine`'s configuration-change rebuild; a crash here means the rebuild raced a cancel — `category == "playback"` shows the sequence), and Swift concurrency `fatalError` from an isolation violation in a backend callback (the only `@unchecked Sendable` is `PlaybackEngine`; any other should be treated as a bug).

## 6. Upgrades and compatibility

- **Settings.** `AppSettings` and both JSON stores carry `schemaVersion`; migrations run at launch and are idempotent (document 08 §12). Downgrading to an older app that doesn't know a newer schema version: the stores are left untouched and defaults are used in memory; nothing is overwritten until the user changes a setting.
- **Hook path.** The hook command embeds the bundle path. After moving the app or installing a new version to a different location, `claudio hooks status` reports stale and the app offers Repair on launch. `make install` keeps the path stable at `/Applications/Claudio.app`.
- **Claude Code transcript schema.** The parser counts unknown record types and unknown block types. `claudio doctor` warns above 5 % and fails above 20 % in the last hour. When Claude Code changes the format:
  1. Capture a fixture from a current session (`scripts/capture-fixture.sh`), scrub, and run `claudio debug expected`.
  2. Compare with the existing fixture of the same scenario; adjust `TranscriptRecord` decoding or `TurnAssembler` heuristics; add the fixture under a version-suffixed name (`single-turn-final-answer-cc2.2`).
  3. Keep the old fixtures; the assembler must pass both.
  The `Stop` hook's `last_assistant_message` is independent of the transcript schema, so users with hooks installed keep hearing final answers even while the transcript parser is behind.
- **Claude Code hook payloads.** `HookEvent` keeps the raw payload; unknown event names are logged and ignored. New `notification_type` values are ignored (no announcement) until mapped.
- **macOS.** Minimum 15. On a new major macOS, run the manual QA checklist in document 09 §7 with emphasis on 7.3 (panel behaviour) and 7.5 steps 6–7 (audio device changes, sleep/wake).
- **Edge constants.** Expected to need a bump a few times a year; procedure in 3.7.

## 7. Support bundle

`claudio doctor --bundle` writes `~/Desktop/claudio-support-<yyyyMMdd-HHmmss>.zip` containing:

| File | Content |
|------|---------|
| `doctor.txt` | Full doctor output |
| `status.json` | `StatusReport` |
| `sessions.json` | `claudio sessions --all --json` (titles and cwd included; the user is told this in the command output) |
| `state.txt` | `claudio debug dump-state` with all text fields truncated to 60 characters |
| `settings.json` | App settings with the OpenAI key omitted and `extraTranscriptRoots` included |
| `claude-settings-hooks.json` | Only the `hooks` object from `~/.claude/settings.json` |
| `logs/claudio.log*` | The file mirror and its rotations |
| `logs/unified-last-2h.txt` | `log show --last 2h --predicate 'subsystem == "com.jdforsythe.claudio"' --info --debug --style compact` |
| `transcript-shape.txt` | For the active session's transcript: the last 200 records' `type`, `subtype`, block types, `stop_reason`, `isSidechain`, `entrypoint`, `version` — no text content, no paths, no tool inputs |
| `environment.txt` | macOS version, Swift version, `claude --version`, bundle path, bundle id, signature type (`codesign -dv`), output device name |

The command prints the path and a reminder that `sessions.json` includes project paths and session titles, so the user can remove it before sharing.
