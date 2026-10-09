# 04 — Hooks, Control Socket and CLI

This document describes the optional Claude Code hook integration, the Unix-socket control protocol that the app exposes, the `claudio` command-line tool that uses it, and the `/speak` skill. It covers `ClaudioCore/Control/` and the `ClaudioCLI` target.

## 1. Why hooks exist alongside the transcript tail

The transcript tail (document 03) is complete on its own: every speakable thing Claude writes ends up in the file. Hooks add three things the file cannot provide:

| Need | Transcript only | With hooks |
|------|-----------------|-----------|
| Cancel latency on a new prompt | 100–600 ms: FSEvents latency (100 ms) plus Claude Code's asynchronous transcript write, which the docs state may lag the in-memory conversation | Under 100 ms: `UserPromptSubmit` fires before Claude starts processing |
| Authoritative final answer | Inferred from `stop_reason` and record order (document 03 §6.3) | `Stop.last_assistant_message` is the exact text Claude displayed |
| Permission / input-needed status | Not recorded in the transcript at all | `Notification` with `notification_type` |
| Session title at start | Only after Claude generates `ai-title` | `SessionStart.session_title` |
| Explicit session end | Inferred from file removal or process exit | `SessionEnd` |
| API failure at turn end | Nothing is written | `StopFailure` with `error_type` |

Hooks are off by default. The user turns them on in Settings → Hooks, or with `claudio hooks install`. Nothing in Claudio depends on hooks being present.

## 2. Hook entries

Claudio writes the following into the `hooks` object of `~/.claude/settings.json`. `<bundle>` is the absolute path of the running app bundle at install time, e.g. `/Applications/Claudio.app`. `matcher` is omitted for events that do not support one and set to `""` (match all) where the schema expects one but Claudio wants everything.

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "<bundle>/Contents/MacOS/claudio hook", "async": true } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "<bundle>/Contents/MacOS/claudio hook", "async": true } ] }
    ],
    "StopFailure": [
      { "matcher": "", "hooks": [ { "type": "command", "command": "<bundle>/Contents/MacOS/claudio hook", "async": true } ] }
    ],
    "SubagentStop": [
      { "matcher": "", "hooks": [ { "type": "command", "command": "<bundle>/Contents/MacOS/claudio hook", "async": true } ] }
    ],
    "Notification": [
      { "matcher": "", "hooks": [ { "type": "command", "command": "<bundle>/Contents/MacOS/claudio hook", "async": true } ] }
    ],
    "SessionStart": [
      { "matcher": "", "hooks": [ { "type": "command", "command": "<bundle>/Contents/MacOS/claudio hook", "async": true } ] }
    ],
    "SessionEnd": [
      { "matcher": "", "hooks": [ { "type": "command", "command": "<bundle>/Contents/MacOS/claudio hook", "async": true } ] }
    ]
  }
}
```

Design points:

- **`async: true` on every entry.** Claude Code runs async hooks in the background and does not enforce a timeout on them; Claude's turn is never delayed by Claudio. `SessionEnd` hooks have a shared 1.5 s budget, which the receiver's 20 ms lifetime fits comfortably.
- **`PreToolUse` / `PostToolUse` are not installed.** The tail already sees every tool block; those hooks would fire for every tool call and add process spawns for nothing.
- **`MessageDisplay` is not installed in v1.** Claude Code writes an assistant message to the transcript only when the whole message completes (measured, document 03 §6.3), so narration that precedes a long tool call reaches the tail late. `MessageDisplay` fires while text streams and would close that gap, but it delivers the same text the tail later delivers, so it needs text-level dedup against transcript records, and the spawn-per-message cost applies. The measured latency is accepted for v1; `MessageDisplay` is the designated path if a later version wants earlier narration, and the receiver already forwards it unchanged (§6 drops it at `.debug`).
- **One command string, no arguments beyond `hook`.** The event name and session come from the JSON on stdin.
- **The command path contains the bundle.** The marker Claudio uses to recognise its own entries is the suffix `/Contents/MacOS/claudio hook` together with a bundle name ending in `Claudio.app`. This survives the user moving the app, because the installer repairs the path (§3.5).

## 3. `HookInstaller`

```swift
// Control/HookInstaller.swift
public struct HookInstaller: Sendable {
    public enum Status: Sendable, Equatable {
        case notInstalled
        case installed(count: Int, bundlePath: String)
        case installedElsewhere(count: Int, bundlePath: String)   // path differs from running bundle
        case partial(installed: Int, expected: Int)
        case settingsUnreadable(String)
    }
    public static let events = ["UserPromptSubmit","Stop","StopFailure","SubagentStop","Notification","SessionStart","SessionEnd"]
    public init(settingsURL: URL, backupsDirectory: URL, bundleURL: URL, fileManager: FileManager, clock: Clock, log: Log)
    public func status() -> Status
    public func install() throws
    public func uninstall() throws
    public func repair() throws          // uninstall + install when installedElsewhere
}
public enum HookInstallerError: Error { case settingsMalformed(String), writeFailed(String), verifyFailed }
```

### 3.1 Read and parse

`install()` reads `~/.claude/settings.json` into `Data`. If the file does not exist, the installer starts from `{}`. The data is parsed with `JSONSerialization.jsonObject(with:options:[.fragmentsAllowed])` into `[String: Any]`. The whole object is preserved and re-serialised; Claudio only touches `hooks.<Event>` arrays. Unknown top-level keys, unknown hook events, Orca's managed entries, the user's own hooks and plugin hooks (`${CLAUDE_PLUGIN_ROOT}/…` commands) pass through byte-for-byte in content, though key order and whitespace are normalised by the serializer (`.prettyPrinted, .sortedKeys` is **not** used; Claudio uses `.prettyPrinted` and `.withoutEscapingSlashes` to keep the file human-readable and preserve the original key order where `JSONSerialization` allows).

If parsing fails, `install()` throws `.settingsMalformed(reason)`. **Claudio never writes to a settings file it could not parse.** Settings shows the error with a "Reveal in Finder" button.

### 3.2 Backup

Before every write the current file is copied to `~/Library/Application Support/Claudio/backups/settings-<yyyyMMdd-HHmmss>.json`. The ten most recent backups are kept; older ones are deleted. The backup path is logged at `.notice`.

### 3.3 Merge

For each event in `HookInstaller.events`:

1. Ensure `hooks[event]` is an array (create if absent; if present but not an array, throw `.settingsMalformed`).
2. Remove any existing group that is **ours** (§3.4), so install is idempotent.
3. Append the group from §2 for that event, with `command` set to the current bundle's `<bundle>/Contents/MacOS/claudio hook`.

Groups that are not ours are never reordered, modified or removed. Orca rewrites its own managed groups on its own schedule; because both parties only touch their own groups and both re-read before writing, concurrent edits lose at worst the other party's most recent change, which the next re-install or Orca sync restores. Claudio additionally re-verifies status on launch and every 10 minutes and shows "Hooks were removed by another program" if its groups disappear.

### 3.4 Recognising our groups

A group is ours when it has exactly one hook, that hook's `type` is `command`, and its `command` matches the regex

```
^(.*/Claudio\.app)/Contents/MacOS/claudio hook$
```

The capture is the installed bundle path. Legacy or hand-edited entries pointing at a bundle named differently are not ours and are left alone.

### 3.5 Write, verify, repair

Writing is atomic: serialise to `settings.json.claudio-tmp` in the same directory, `fsync`, then `rename(2)` over the original. Permissions of the original are preserved (`0600` typical). After the rename the installer re-reads and re-parses the file and confirms every expected group is present with the expected command; otherwise it throws `.verifyFailed` and restores the backup.

`status()` compares the captured bundle path with `Bundle.main.bundleURL`. A mismatch yields `.installedElsewhere`, which the app shows as "Hooks point at a moved copy of Claudio — Repair". `repair()` runs uninstall then install. The app offers repair automatically at launch when the mismatch is detected.

### 3.6 Uninstall

Removes every group that is ours from every event array. An event array left empty is removed; an empty `hooks` object is left in place (removing it could change behaviour for other tools that expect the key). Backup, atomic write and verification apply as for install.

Tests (`HookInstallerTests`, operating on temp files): `testInstallIntoMissingFile`, `testInstallIntoEmptyObject`, `testInstallPreservesForeignGroupsByteForByte` (uses a fixture containing Orca-style and plugin-style groups, compares the foreign groups structurally after a round trip), `testInstallIsIdempotent`, `testUninstallRemovesOnlyOurs`, `testMalformedSettingsRefused`, `testBackupRotationKeepsTen`, `testStatusDetectsMovedBundle`, `testRepairRewritesPath`, `testVerifyFailureRestoresBackup`.

## 4. The `claudio hook` receiver

The receiver is the hot path: Claude Code spawns it on every installed event, for every session, in parallel.

### 4.1 Behaviour

1. Read stdin until EOF or 50 ms, whichever first, into a buffer capped at 1 MiB (`Stop.last_assistant_message` can be long). Use `read(2)` in a loop on fd 0 with `poll(2)` for the deadline.
2. Validate that the buffer is a single JSON object: first non-whitespace byte `{`, last non-whitespace byte `}`. No full parse. Extract `hook_event_name` and `session_id` with a byte scan for the keys (a 20-line hand-written scanner; both keys appear once at the top level in every payload Claude Code produces). If either is missing, exit 0.
3. Build one NDJSON line: `{"v":1,"kind":"hook","event":<hook_event_name>,"session":<session_id>,"payload":<raw stdin bytes>}\n`. The payload is spliced in as raw bytes, not re-encoded.
4. `socket(AF_UNIX, SOCK_STREAM)`, `connect()` to the socket path from `Paths.controlSocket` (resolved from `$HOME`, 20 ms timeout via non-blocking connect plus `poll`). On failure (`ENOENT`, `ECONNREFUSED`, timeout): exit 0.
5. `write()` the line, `shutdown(SHUT_WR)`, exit 0. The receiver does not wait for a response.

Exit code is always 0. Nothing is written to stdout or stderr except when `CLAUDIO_HOOK_DEBUG=1` is set, in which case a one-line diagnostic goes to stderr (Claude Code shows non-zero exits as hook errors; a zero exit with stderr output is silent).

### 4.2 Startup constraints

The `claudio` executable is shared between the receiver and the user-facing CLI, so the whole executable must start fast:

- Links only `Foundation` (for `JSONEncoder` in the CLI commands) and `swift-argument-parser`. **No AVFoundation, AppKit, SwiftUI, or ClaudioBackends.** It imports `ClaudioCore` only for `ControlProtocol.swift` and `Paths.swift`; those files are compiled into a tiny sub-target `ClaudioControlProtocol` that `ClaudioCore` re-exports, so the CLI does not pull in the rest of Core.
- `hook` is dispatched before `ArgumentParser` runs: `main.swift` checks `CommandLine.arguments == [_, "hook"]` and calls `HookReceiver.run()` directly. Argument parsing, help text and the other commands are only touched on other paths.
- No `URLSession`, no `Process`, no `FileManager` enumeration in the receiver path. Socket I/O is POSIX.
- Measured budget: 20 ms wall time from `exec` to exit on Apple Silicon, including dyld. `scripts/measure-hook.sh` runs it 100 times and fails CI if p95 exceeds 20 ms (document 10).

Tests: `HookReceiverTests.testForwardsRawPayload` (spins up a `ControlServer` on a temp socket, runs the receiver via `Process` with a fixture payload, asserts the server received the exact bytes), `testExitsZeroWhenNoSocket`, `testExitsZeroOnMalformedInput`, `testStdinDeadlineHonoured` (stdin held open), `testStartupUnder20ms` (performance test, measured only on CI macOS runner with tolerance 2×).

## 5. `ControlServer` and the wire protocol

### 5.1 Socket

- Path: `~/Library/Application Support/Claudio/claudio.sock` (`Paths.controlSocket`). Unix socket paths are limited to 104 bytes on macOS; the path is 60–70 bytes for typical home directories. If `$HOME` makes it exceed 100 bytes, Claudio falls back to `$TMPDIR/claudio.sock` and writes the chosen path to `~/Library/Application Support/Claudio/socket-path` so the CLI can find it.
- Created with `socket(AF_UNIX, SOCK_STREAM, 0)`, `bind`, `chmod 0600`, `listen(backlog: 64)`. A stale socket file from a crashed instance is removed before bind, but only after a `connect` attempt to it fails with `ECONNREFUSED` (if the connect succeeds, another Claudio instance is running and this one quits with an alert).
- Accept loop runs on a `DispatchSource.makeReadSource` for the listening fd on a dedicated serial queue. Each accepted connection is handled on a concurrent queue with a 2 s read deadline.
- The socket is unlinked on quit (`applicationWillTerminate`) and on `SIGTERM`.

### 5.2 Framing

One request per connection. Client writes one line (`\n`-terminated JSON object, max 1 MiB), then `shutdown(SHUT_WR)`. Server writes one response line and closes. A line exceeding 1 MiB closes the connection without a response. A hook message (`kind: "hook"`) gets no response; the server closes immediately after reading.

### 5.3 Types

```swift
// Control/ControlProtocol.swift
public let controlProtocolVersion = 1

public struct ControlEnvelope: Codable, Sendable {
    public let v: Int
    public let kind: String                  // "hook" | "request"
    // hook fields
    public let event: String?
    public let session: String?
    public let payload: RawJSON?             // kept as raw bytes via a custom Decodable wrapper
    // request fields
    public let request: ControlRequest?
}

public enum ControlRequest: Codable, Sendable {
    case status
    case sessions
    case `switch`(query: String?)            // nil → resolve from caller environment (see §7.3)
    case level(SpeechLevel, session: String?)
    case pause, resume, toggle
    case skip                                // current segment
    case live                                // skip to live
    case mute(Bool)                          // global events toggle off/on
    case say(text: String)
    case hooksStatus, hooksInstall, hooksUninstall
    case link(Bool)                          // create/remove /usr/local/bin symlink
    case skill(install: Bool)
    case version
    case ping                                // single-instance check; answers .none
    // diagnostics (document 11 §2). The CLI cannot link ClaudioCore, so rendering,
    // item tailing and benchmarking run inside the app and stream results back.
    case render(markdown: String)            // → .segments
    case subscribe(SubscriptionKind, session: String?)   // streamed: one ControlResponse per line until the client disconnects
    case bench(backend: String?, fixture: String?, runs: Int)  // → .text (table)
    case doctor                              // → .doctor
    case dumpState                           // hidden; → .text (JSON)
}

public enum SubscriptionKind: String, Codable, Sendable { case items, rawRecords }

public struct ControlResponse: Codable, Sendable {
    public let v: Int
    public let ok: Bool
    public let error: String?
    public let result: ControlResult?
}

public enum ControlResult: Codable, Sendable {
    case status(StatusReport)
    case sessions([SessionSummary])
    case session(SessionSummary)             // after switch / level
    case hooks(HookInstaller.Status)
    case text(String)
    case segments([SegmentSummary])          // render: kind + text per segment
    case item(SpeechItemSummary)             // subscribe(.items): one per emitted SpeechItem, with filtered: Bool
    case record(type: String, uuid: String?, summary: String)  // subscribe(.rawRecords)
    case doctor([DoctorCheck])               // name, state pass|warn|fail, detail
    case none
}

public struct SegmentSummary: Codable, Sendable { public let kind: String; public let text: String }
public struct SpeechItemSummary: Codable, Sendable {
    public let session: String; public let turn: String?; public let category: ContentCategory
    public let text: String; public let filtered: Bool; public let timestamp: Date
}
public struct DoctorCheck: Codable, Sendable { public let name: String; public let state: String; public let detail: String }

public struct SessionSummary: Codable, Sendable {
    public let id, title, cwd: String
    public let entrypoint: SessionEntrypoint
    public let status: SessionStatus
    public let level: SpeechLevel
    public let unread: Int
    public let active: Bool
    public let lastActivity: Date
}

public struct StatusReport: Codable, Sendable {
    public let version: String
    public let playback: String              // idle | speaking | paused | catchingUp
    public let activeSession: SessionSummary?
    public let backend: String, voice: String, rate: Double
    public let eventsMuted: Bool
    public let hooks: HookInstaller.Status
    public let sessionsLive: Int
    public let metrics: [String: Double]     // tailer bytes, records/s, probe latency, synth latency p50/p95
}
```

Encoding uses `JSONEncoder` with `.iso8601` dates and `keyEncodingStrategy = .useDefaultKeys`. Enums with associated values use Swift's synthesized `Codable` (`{"switch":{"query":"yard"}}`), which the CLI and server share by construction.

**Streaming responses.** `subscribe` is the one request that returns more than one line: the server keeps the connection open and writes one `ControlResponse` per event until the client closes the socket or the app quits. All other requests are exactly one request line and one response line.

### 5.4 Versioning

Every message carries `v`. A server receiving `v` greater than it knows responds `ok:false, error:"protocol version 2 not supported; update Claudio.app"`. A CLI receiving an unknown `v` prints the same advice. Because the CLI ships inside the bundle, a mismatch only happens when the user runs a symlinked CLI from an old bundle after upgrading; `claudio link` refreshes the symlink.

### 5.5 Dispatch

`ControlServer` holds references to `SessionRegistry`, `Arbiter`, `SpeechPipeline`, `AppSettings`, `HookInstaller` and a `SkillInstaller`. Requests are dispatched on the server's task and awaited; the response is encoded and written. `say` enqueues an `event` item with `sessionID = "cli"` through the Arbiter so it is spoken immediately between segments. Hook envelopes are decoded into `HookEvent` (§6) and delivered to `SessionRegistry.ingestHook`.

Tests: `ControlServerTests.testRoundTripEveryRequest` (parametrised), `testOversizedLineClosed`, `testHookEnvelopeGetsNoResponse`, `testStaleSocketReplaced`, `testSecondInstanceDetected`, `testSocketMode0600`.

## 6. `HookEvent` → `TurnEvent`

```swift
// Control/HookEvent.swift
public struct HookEvent: Sendable {
    public let name: String                 // hook_event_name
    public let sessionID: SessionID
    public let promptID: TurnID?
    public let transcriptPath: String?
    public let cwd: String?
    public let agentID: String?
    public let agentType: String?
    public let receivedAt: Date
    public let fields: [String: JSONValue]  // event-specific
    public static func decode(envelope: ControlEnvelope, clock: Clock) -> HookEvent?
}
```

The payload JSON is decoded fully here (on the app side, not in the receiver). Unknown events are logged at `.debug` and dropped. The registry locates the session by `session_id`; if unknown, it creates one using `cwd` and `transcript_path` (document 03 §8.1) so that a brand-new session is listed before its first transcript line is tailed.

| Hook | Fields read | `TurnEvent`s emitted (after reconciliation, document 03 §9) |
|------|-------------|------------------------------------------------------------|
| `UserPromptSubmit` | `prompt_id`, `prompt_text`, `is_continuation` | If `is_continuation == true`: nothing. Else: close any open turn as `.interruptedByPrompt`, `.turnStarted(prompt_id, prompt_text)`, `.statusChanged(.busy)`. The Arbiter cancels on `.turnStarted`. |
| `Stop` | `prompt_id`, `last_assistant_message`, `stop_reason` | `.item(finalAnswer from last_assistant_message)` subject to dedup; `.turnEnded(prompt_id, reason: .hookStop)`; `.statusChanged(.idle)`. |
| `StopFailure` | `prompt_id`, `error_type`, `error_message` | `.turnEnded(prompt_id, reason: .hookStopFailure)`; `.statusChanged(.idle)`; `.item(event: "<title> hit an error: <humanised error_type>")`. Humanised: `rate_limit` → "rate limit", `overloaded` → "overloaded API", `authentication_failed` → "authentication failure", `server_error` → "server error", other → the raw value with underscores replaced by spaces. |
| `SubagentStop` | `agent_id`, `agent_type`, `last_assistant_message` | `.subagentFinished(agent_id, description)` and `toolCall` "Agent finished: <description>" keyed by `agent_id`; description from the registry's `subagentDescriptions` else `agent_type`. |
| `Notification` | `notification_type`, `message` | `permission_prompt` → `.statusChanged(.waiting)` + `event` "<title> needs permission"; `idle_prompt` → `.statusChanged(.waiting)` + `event` "<title> is waiting"; `agent_needs_input` → `.statusChanged(.waiting)` + `event` "<title> needs input"; `agent_completed` → `event` "<title> finished" (only when no `turnEnded` was already announced for the current turn); all others (`auth_success`, `elicitation_*`, `quota_*`) → nothing. |
| `SessionStart` | `source`, `session_title`, `model` | create/refresh session; `.titleChanged(session_title)` if non-empty and no `ai-title` seen yet; `lastActivity = now`. `source == "clear"` closes any open turn. |
| `SessionEnd` | `reason` | close any open turn as `.sessionEnded`; `.statusChanged(.ended)`. `reason == "clear"` or `"resume"` is **not** treated as ended (Claude Code emits `SessionEnd` then `SessionStart` for `/clear`): the session is kept and marked `.idle`. |
| `MessageDisplay`, `PreToolUse`, others | — | Dropped at `.debug` (not installed; tolerated if a user adds them by hand). |

Event announcement text uses the session's display title (document 03 §8.2). The Arbiter decides whether to voice an `event` item (global events toggle, active versus background).

Tests: `HookEventTests.testDecodeEachInstalledEvent` (fixture payload per event from `Tests/Fixtures/hooks/*.json`), `testContinuationPromptIgnored`, `testStopFailureHumanised`, `testNotificationTypesMapped`, `testSessionEndClearKeepsSession`, `testUnknownSessionCreatedFromHook`.

## 7. The `claudio` CLI

Installed at `<bundle>/Contents/MacOS/claudio`; optionally symlinked to `/usr/local/bin/claudio` by `claudio link`. Built with `swift-argument-parser`. Every command connects to the control socket, sends one request, prints the response, and exits.

### 7.1 Global options

| Option | Effect |
|--------|--------|
| `--json` | Print the raw `ControlResponse` JSON instead of human text |
| `--socket <path>` | Override socket path (tests, unusual `$HOME`) |
| `-q, --quiet` | Suppress human output; exit code only |

### 7.2 Exit codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Claudio.app is not running (socket missing / refused) |
| 2 | Request rejected (`ok: false`): unknown session, invalid level, hooks error, etc. Error text on stderr |
| 3 | Usage error (bad arguments); `ArgumentParser` help on stderr |
| 4 | Protocol mismatch |

### 7.3 Commands

| Command | Arguments | Request | Human output |
|---------|-----------|---------|--------------|
| `status` | — | `.status` | Multi-line: playback state, active session, backend/voice/rate, hooks status, N live sessions |
| `sessions` | — | `.sessions` | Table: `*` marker for active, title, status, level, unread, cwd (shortened with `~`), id prefix |
| `switch [query]` | optional id / prefix / title / path | `.switch(query)` | "Active: <title>" |
| `level <quiet\|answers\|narrate> [--session <query>]` | level; session defaults to the caller's session (§7.4) else the active session | `.level(l, session)` | "<title>: narrate" |
| `pause` / `resume` / `toggle` | — | respective | "Paused" / "Resumed" |
| `skip` | — | `.skip` | "Skipped" |
| `live` | — | `.live` | "Live" |
| `mute` / `unmute` | — | `.mute(true/false)` | "Events muted" / "Events on" |
| `say <text…>` | remaining args joined by spaces, or stdin if `-` | `.say(text)` | nothing |
| `hook` | — | (receiver, §4) | nothing |
| `hooks status\|install\|uninstall` | — | `.hooksStatus` / `.hooksInstall` / `.hooksUninstall` | "7 hooks installed, pointing at /Applications/Claudio.app" etc. |
| `link [--remove]` | — | `.link(true/false)` | "Linked /usr/local/bin/claudio" (the **app** creates the symlink, prompting for admin rights via `NSWorkspace`/AppleScript `with administrator privileges` only if `/usr/local/bin` is not writable) |
| `skill install\|uninstall` | — | `.skill(install:)` | "Installed ~/.claude/skills/speak" |
| `version` | — | `.version` (falls back to the embedded version string if the app is not running) | "claudio 1.2.0 (app 1.2.0)" |
| `doctor [--json] [--bundle]` | — | `.doctor` plus local checks the CLI can do itself (binary paths, settings.json parse) | PASS/WARN/FAIL per check; exit 0/1/2 (document 11 §2) |
| `tail [<query>] [--all-sessions] [--raw]` | session query | `.subscribe(.items \| .rawRecords, session)` | one line per SpeechItem or record until Ctrl-C |
| `render <file.md> [--segments] [--json]` | path or `-` for stdin | `.render(markdown:)` | the speakable text, or one line per segment with its kind |
| `bench [--backend b] [--fixture f] [--runs N]` | — | `.bench(...)` | time-to-first-audio p50/p95 and inter-segment gap table (document 09 §5) |
| `debug dump-state` (hidden) | — | `.dumpState` | JSON of registry, arbiter and scheduler state |
| `uninstall [--all]` | — | `.hooksUninstall`, `.skill(install: false)`, `.link(false)`; `--all` also removes Application Support and preferences after the app quits (document 08 §10) | list of removed items |

### 7.4 Session resolution

`switch` and `level --session` accept a **query**. The server (`SessionRegistry.resolve`) resolves it in this order; the first rule that yields exactly one live session wins, and ambiguity is an error listing the candidates:

1. Exact session id.
2. Unique prefix of a session id (minimum 4 characters).
3. Case-insensitive exact match on display title.
4. Case-insensitive substring of display title.
5. A path: the session whose `cwd` equals the path, or is the deepest ancestor of it.

When `switch` is called with **no** query, or `level` without `--session`, the CLI identifies "this session" from its own environment and sends it as the query:

1. `$CLAUDE_CODE_SESSION_ID` if set — Claude Code sets it for processes it spawns, including hooks and skill shell commands. The CLI sends `switch(query: "id:<value>")`, which the server matches by exact id only.
2. Else `$ORCA_WORKTREE_PATH` if set — resolved as a path.
3. Else `$PWD` — resolved as a path.

For `level` the fallback when nothing resolves is the active session; for `switch` it is an error.

### 7.5 Human output example

```
$ claudio sessions
   TITLE                                   STATUS   LEVEL    UNREAD  CWD                 ID
 * Claude-speak redesign and architecture  busy     narrate  0       ~/dev/claudio       562358f2
   yard-53                                 idle     answers  2       ~/dev/yard          55d1bb45
```

Tests (`ClaudioCLITests`, running the built CLI against an in-process `ControlServer` with a fake registry): `testEachCommandSendsExpectedRequest`, `testExitCode1WhenNotRunning`, `testJSONFlagPrintsRawResponse`, `testSwitchResolvesFromClaudeSessionEnv`, `testSwitchResolvesFromOrcaWorktreeEnv`, `testSwitchResolvesFromPWD`, `testAmbiguousQueryListsCandidates`, `testSayReadsStdin`.

## 8. The `/speak` skill

The skill is a thin wrapper so the user can control Claudio without leaving a Claude Code prompt. It is installed by `claudio skill install` (or Settings → Install `/speak` skill) to `~/.claude/skills/speak/SKILL.md`, and removed by `claudio skill uninstall`. The installer refuses to overwrite a `SKILL.md` that does not contain the marker comment `<!-- claudio-skill v1 -->`.

Full content of `skills/speak/SKILL.md` as shipped in the repository:

```markdown
---
name: speak
description: Control Claudio voice output for this session — toggle, set level (quiet/answers/narrate), switch the active session, pause, skip, or catch up to live
---
<!-- claudio-skill v1 -->
# Claudio voice control

Claudio is a menu bar app that reads Claude Code sessions aloud. This skill controls it for the current session.

## Usage
/speak                     Make this session the active (spoken) one
/speak on                  Same as above
/speak off                 Set this session to quiet (events only)
/speak quiet|answers|narrate   Set this session's level
/speak pause | resume | toggle
/speak skip                Skip the current sentence
/speak live                Abandon catch-up, jump to live
/speak status
/speak sessions

## Instructions
Run exactly one of the following shell commands based on the argument, then report its output in one line. Do not add commentary. `CLAUDIO` resolves to the bundled CLI; fall back to the symlink.

CLAUDIO="/Applications/Claudio.app/Contents/MacOS/claudio"; [ -x "$CLAUDIO" ] || CLAUDIO="claudio"

- no argument or `on`:     $CLAUDIO switch
- `off`:                   $CLAUDIO level quiet
- `quiet`/`answers`/`narrate`: $CLAUDIO level <arg>
- `pause`/`resume`/`toggle`/`skip`/`live`/`status`/`sessions`: $CLAUDIO <arg>

The CLI identifies this session from $CLAUDE_CODE_SESSION_ID automatically. If the command exits 1, tell the user "Claudio is not running" and stop.
```

Tests: `SkillInstallerTests.testInstallWritesMarkedFile`, `testRefusesToOverwriteForeignSkill`, `testUninstallRemovesOnlyMarked`.

## 9. Security

- The socket is `0600`, in the user's own Application Support directory. Only processes running as the user can connect.
- The server accepts at most 1 MiB per connection and at most 64 concurrent connections; excess connections are closed immediately.
- No request causes shell execution. `link` creates a symlink with `FileManager`; the privileged fallback runs a fixed AppleScript with the two paths passed as escaped string literals.
- Hook payloads are untrusted data: they are decoded with `JSONDecoder`, never evaluated, and their text is only ever spoken or displayed. `prompt_text` is used solely for the popover's "last prompt" line and is truncated to 200 characters.
- The receiver never reads files or environment beyond `$HOME` and `CLAUDIO_HOOK_DEBUG`.
- Claudio makes no network connections except those of the active TTS backend (document 06).
- `HookInstaller` writes only to `~/.claude/settings.json` and its own backup directory, and only when the user has enabled hooks.

## 10. Test inventory

| Suite | Target | Named tests |
|-------|--------|-------------|
| `HookInstallerTests` | ClaudioCoreTests | §3 |
| `HookReceiverTests` | ClaudioIntegrationTests (spawns the built CLI) | §4 |
| `ControlServerTests` | ClaudioCoreTests | §5 |
| `HookEventTests` | ClaudioCoreTests | §6 |
| `ClaudioCLITests` | ClaudioIntegrationTests | §7 |
| `SkillInstallerTests` | ClaudioCoreTests | §8 |
| `ReconciliationTests` | ClaudioCoreTests | document 03 §9 |

Fixtures: `Tests/Fixtures/hooks/<EventName>.json` (one real payload per installed event, captured with `CLAUDIO_HOOK_DEBUG=1`), `Tests/Fixtures/settings/with-orca-and-plugins.json`, `Tests/Fixtures/settings/malformed.json`.
