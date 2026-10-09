# 08 — Configuration and Persistence

This document catalogs every piece of state Claudio stores, where it lives, its schema, how it is read and written, and how it is observed by the rest of the system. All types described here live in `Sources/ClaudioCore/Settings/`.

```
Sources/ClaudioCore/Settings/
├── AppSettings.swift          # UserDefaults-backed observable settings
├── AppSettingsSnapshot.swift  # Sendable value copy for actors
├── KeychainStore.swift        # OpenAI key
├── ProjectPreferences.swift   # projects.json
├── SessionStateCache.swift    # sessions.json
├── Paths.swift                # every filesystem location
├── AtomicFile.swift           # temp + rename writes
└── SchemaMigration.swift      # versioned JSON migrations
```

## 1. Principles

1. **Live.** Every setting is read at the moment it is needed or observed through a stream. No component captures a setting at startup. Changing a setting never requires a restart.
2. **Typed.** Settings are accessed through typed properties on `AppSettings`, never by raw key string outside `AppSettings.swift`.
3. **Defaults in code.** Every key has a default in `AppSettings.Defaults`. A missing or corrupt value yields the default, never a crash.
4. **No secrets in plists or JSON.** The only secret, the OpenAI API key, lives in the Keychain.
5. **Atomic writes.** Every JSON file is written to a sibling temporary file and renamed into place with `FileManager.replaceItemAt`, so a crash mid-write never leaves a truncated file.
6. **Versioned schemas.** Every JSON file carries a top-level integer `version`. Readers migrate forward and never write a version they cannot read.
7. **Nothing under `~/.claude` unless the user enabled it.** `AppSettings`, `ProjectPreferences` and `SessionStateCache` live entirely in `~/Library`.

## 2. `AppSettings`

### 2.1 Type

```swift
@Observable
public final class AppSettings: @unchecked Sendable {
    public static let suiteName = "com.jdforsythe.claudio"
    private let defaults: UserDefaults
    private let continuation: AsyncStream<AppSettingsSnapshot>.Continuation
    public let changes: AsyncStream<AppSettingsSnapshot>

    public init(defaults: UserDefaults = UserDefaults(suiteName: AppSettings.suiteName)!)

    public var snapshot: AppSettingsSnapshot { get }
    // one stored property per key, see table
}
```

`AppSettings` is `@unchecked Sendable` because `UserDefaults` is thread-safe and the class holds no other mutable state; every property is a computed accessor over `defaults`. It is observable by SwiftUI through `@Observable`; the `@ObservationIgnored` `defaults` field is the only storage. Each setter writes to `defaults` and then calls `publish()`, which yields a fresh `AppSettingsSnapshot` to `changes`. `UserDefaults.didChangeNotification` is also observed so that changes made by the `claudio` CLI process (which writes the same suite via `defaults write`-equivalent API for `level` defaults) propagate into the running app.

### 2.2 Key table

Keys are the literal strings stored in the `com.jdforsythe.claudio` domain.

| Key | Swift type | Default | Description | UI location |
|---|---|---|---|---|
| `backendID` | `BackendID` (`String` raw) | `"edge"` | Primary TTS backend. | Voice → Engine |
| `voiceID` | `String` | `"en-US-GuyNeural"` | Voice identifier within the primary backend. When `backendID` changes, this is reset to that backend's default voice if it does not belong to the new backend. | Voice → Voice |
| `fallbackVoiceID` | `String?` | `nil` (auto) | Apple voice used by `FallbackBackend`. `nil` means `VoiceCatalog.bestAppleVoice(matching:)` chooses by locale and gender of `voiceID`. | Voice → Fallback voice |
| `rate` | `Double` | `1.0` | Speech speed multiplier, clamped 0.5…2.0 on read. | Voice → Speed |
| `showHUD` | `Bool` | `true` | Whether the HUD may appear. | General |
| `hudCaptionsExpanded` | `Bool` | `false` | Captions disclosure state. Written by the HUD chevron and the General tab. | General, HUD |
| `hudPinned` | `Bool` | `false` | HUD stays visible when idle. | HUD pin |
| `hudFrame` | `String?` | `nil` | Last HUD frame as `"x,y,w,h"` in screen points. `nil` means default position. | written by HUD drag |
| `eventsEnabled` | `Bool` | `true` | Speak announcements from non-active sessions. | General |
| `chimesEnabled` | `Bool` | `true` | Play a chime before announcements. | General |
| `chimeVolume` | `Double` | `0.6` | 0…1 linear gain for chimes. | General |
| `defaultLevelNewSession` | `SpeechLevel` | `.answers` | Level assigned to a newly discovered non-active session. | Levels |
| `defaultLevelActive` | `SpeechLevel` | `.narrate` | Level applied on first activation when no project default exists. | Levels |
| `speakThinking` | `Bool` | `false` | Include `thinking` items at Narrate. | Levels → Advanced |
| `speakToolErrors` | `Bool` | `false` | Include failing `toolResult` items at Narrate. | Levels → Advanced |
| `extraTranscriptRoots` | `[String]` | `[]` | Additional `projects` directories to watch (absolute paths, `~` expanded on read). | Sessions |
| `hooksEnabled` | `Bool` | `false` | User intent to have hooks installed. `HookInstaller` reconciles the file against this on launch. | Integration |
| `launchAtLogin` | `Bool` | `false` | Mirrors `SMAppService.mainApp.status == .enabled`; reconciled on launch. | General |
| `logLevel` | `LogLevel` (`"error"`, `"info"`, `"debug"`) | `"info"` | Minimum level written to the file log. Unified logging is unaffected. | Advanced |
| `firstLaunchCompleted` | `Bool` | `false` | Suppresses the first-launch hint. | — |
| `lookahead` | `Int` | `2` | Segments synthesized ahead of playback. Hidden; `defaults write` only. | — |
| `fallbackTimeoutSeconds` | `Double` | `3.0` | First-audio timeout before falling back. Hidden. | — |
| `sessionExpiryHours` | `Int` | `24` | Hours since `lastActivity` before a session is dropped. Hidden; displayed read-only. | Sessions (read-only) |
| `openAIModel` | `String` | `"gpt-4o-mini-tts"` | | OpenAI |
| `openAIVoice` | `String` | `"alloy"` | | OpenAI |
| `settingsSchemaVersion` | `Int` | `1` | Bumped by `SchemaMigration.migrateDefaults()` when a key's meaning changes. | — |

Hotkeys are stored by the KeyboardShortcuts library under its own keys (`KeyboardShortcuts_<name>`) in the standard defaults domain and are not part of `AppSettings`.

### 2.3 Reading with validation

Each getter validates: enums fall back to the default on unknown raw values; `rate` is clamped; `extraTranscriptRoots` drops entries that are not absolute paths after `~` expansion; `hudFrame` returns `nil` if it does not parse into four finite numbers with positive size. Invalid values are logged once at `.info` with the key name and then overwritten with the default so the warning does not repeat.

### 2.4 Snapshot and observation

```swift
public struct AppSettingsSnapshot: Sendable, Equatable {
    public let backendID: BackendID
    public let voiceID: String
    public let fallbackVoiceID: String?
    public let rate: Double
    public let eventsEnabled: Bool
    public let chimesEnabled: Bool
    public let chimeVolume: Double
    public let defaultLevelNewSession: SpeechLevel
    public let defaultLevelActive: SpeechLevel
    public let speakThinking: Bool
    public let speakToolErrors: Bool
    public let extraTranscriptRoots: [URL]
    public let hooksEnabled: Bool
    public let lookahead: Int
    public let fallbackTimeoutSeconds: Double
    public let sessionExpiryHours: Int
    public let openAIModel: String
    public let openAIVoice: String
    public let logLevel: LogLevel
}
```

UI-only keys (`showHUD`, `hudCaptionsExpanded`, `hudPinned`, `hudFrame`, `launchAtLogin`, `firstLaunchCompleted`) are not in the snapshot; the UI reads them through `@Observable` directly.

Core actors receive `AppSettings.changes` in their initializers and run a `for await snapshot in changes` loop. Each actor applies only the fields it owns:

| Actor / component | Fields consumed | Effect of change |
|---|---|---|
| `SpeechPipeline` | `backendID`, `voiceID`, `fallbackVoiceID`, `rate`, `lookahead`, `fallbackTimeoutSeconds`, `chimesEnabled`, `chimeVolume` | Next segment uses the new values. Nothing already synthesized is redone. |
| `ContentFilter` (inside `Arbiter`) | `speakThinking`, `speakToolErrors`, `eventsEnabled` | Applied to the next item; a downgrade drops queued excluded items. |
| `SessionRegistry` | `defaultLevelNewSession`, `sessionExpiryHours` | New sessions use the new default; expiry re-evaluated on the next sweep. |
| `Arbiter` | `defaultLevelActive` | Next activation. |
| `SessionDiscovery` | `extraTranscriptRoots` | Streams added or removed for the delta. |
| `HookInstaller` | `hooksEnabled` | Reconcile install state. |
| `Log` | `logLevel` | File logger threshold. |

The stream is created with `bufferingPolicy: .bufferingNewest(1)`, so a burst of slider changes delivers only the latest snapshot. Snapshots are `Equatable`; consumers skip no-op updates.

## 3. Keychain

```swift
public struct KeychainStore: Sendable {
    public static let service = "com.jdforsythe.claudio"
    public enum Account: String { case openAI = "openai" }

    public func set(_ secret: String, for account: Account) throws
    public func get(_ account: Account) throws -> String?
    public func delete(_ account: Account) throws
    public func exists(_ account: Account) -> Bool
}
```

Items are `kSecClassGenericPassword` with `kSecAttrService = service`, `kSecAttrAccount = account.rawValue`, `kSecAttrAccessible = kSecAttrAccessibleAfterFirstUnlock`, no access group (the app is not in an app group and may be ad-hoc signed). `set` performs `SecItemCopyMatching` then `SecItemUpdate` or `SecItemAdd`. Errors map to `KeychainError.unexpectedStatus(OSStatus)`; `errSecItemNotFound` on `get` returns `nil`, on `delete` is success. The key is read by `OpenAITTSBackend` on every request (Keychain reads are sub-millisecond and this keeps principle 1).

With ad-hoc signing, the Keychain may show a permission dialog the first time a rebuilt binary reads the item, because the code signature changed. This is expected in development and does not happen with a stable Developer ID signature.

## 4. `ProjectPreferences`

### 4.1 File

`~/Library/Application Support/Claudio/projects.json`

```json
{
  "version": 1,
  "projects": {
    "/Users/jforsythe/dev/yard": {
      "defaultLevel": "narrate",
      "displayName": "Yard",
      "muted": false
    },
    "/Users/jforsythe/dev/vea": {
      "defaultLevel": "quiet"
    }
  }
}
```

Keys are canonical absolute paths: symlinks resolved with `URL.resolvingSymlinksInPath()`, trailing slash removed, no `~`. `displayName` overrides the session title derived from the transcript. `muted` makes every session of that project behave as `quiet` and suppresses its announcements; it is an escape hatch for projects whose Claude output is never wanted aloud. Both are optional.

### 4.2 API

```swift
public actor ProjectPreferences {
    public struct Entry: Codable, Sendable, Equatable {
        public var defaultLevel: SpeechLevel
        public var displayName: String?
        public var muted: Bool?
    }
    public init(fileURL: URL)
    public func entries() -> [URL: Entry]
    public func entry(matching cwd: URL) -> (URL, Entry)?     // exact, then nearest ancestor
    public func set(_ entry: Entry, for cwd: URL) async throws
    public func remove(for cwd: URL) async throws
    public var changes: AsyncStream<[URL: Entry]> { get }
}
```

### 4.3 Matching

`entry(matching:)` canonicalizes `cwd`, looks for an exact key, then walks up parent directories until `/` looking for the nearest ancestor with an entry. An Orca worktree at `~/dev/yard/.orca/worktrees/feature-x` therefore inherits `~/dev/yard`'s default. The walk stops at the user's home directory; an entry keyed at `/Users/jforsythe` or `/` is honoured only as an exact match, so a stray entry cannot silently apply to everything.

`SessionRegistry` consults `entry(matching:)` when a session is first activated (`Arbiter.activate`) to pick the starting level, and when a session is created to apply `displayName` and `muted`.

### 4.4 Writes

The actor holds the decoded dictionary in memory, mutates it, and writes through `AtomicFile.write(data, to:)`. Writes are immediate (not debounced) because they are rare. A failed write throws to the caller (the Settings UI shows an alert) and leaves memory unchanged.

## 5. `SessionStateCache`

### 5.1 File

`~/Library/Application Support/Claudio/sessions.json`

```json
{
  "version": 1,
  "savedAt": "2026-10-09T14:03:21Z",
  "activeSessionID": "562358f2-0209-4cc5-b2be-9157fd4b6a9d",
  "sessions": [
    {
      "id": "562358f2-0209-4cc5-b2be-9157fd4b6a9d",
      "title": "Claude-speak redesign and architecture",
      "cwd": "/Users/jforsythe/dev/claudio",
      "transcriptPath": "/Users/jforsythe/.claude/projects/-Users-jforsythe-dev-claudio/562358f2-0209-4cc5-b2be-9157fd4b6a9d.jsonl",
      "entrypoint": "cli",
      "level": "narrate",
      "colorIndex": 3,
      "lastActivity": "2026-10-09T14:02:58Z",
      "status": "idle",
      "unreadTurns": [
        {
          "turnID": "e89a4f1b-fd12-40ed-835c-be69d1a16fed",
          "endedAt": "2026-10-09T13:58:10Z",
          "finalAnswerText": "The parser attaches at end of file…"
        }
      ]
    }
  ]
}
```

### 5.2 What is persisted and what is not

Persisted: everything needed to show the popover list and to perform catch-up after an app restart. Not persisted: tailer offsets (the tailer always re-attaches at end-of-file), current turn in progress, narration or tool-call items, probe results (`pid`), hook dedup windows.

### 5.3 Write policy

`SessionStateCache.scheduleSave()` is called by `SessionRegistry` on every state change. Saves are debounced: a save runs 2 s after the last call, and immediately on `applicationWillTerminate` (synchronously, with a 500 ms cap). Writes go through `AtomicFile`.

### 5.4 Caps

- `finalAnswerText` is truncated to 20 000 UTF-8 characters at a grapheme boundary with "…" appended.
- At most 5 unread turns per session are stored (the newest 5). The in-memory registry keeps the same cap so catch-up and persistence agree.
- At most 200 sessions are stored, newest `lastActivity` first.

### 5.5 Restore

On launch, `SessionRegistry.restore(from:)`:

1. Drops sessions whose `lastActivity` is older than `sessionExpiryHours`.
2. Drops sessions whose `transcriptPath` no longer exists.
3. Sets every status to `idle` (or `ended` if it was `ended`); `busy` and `waiting` are never restored because a running turn cannot be reconstructed. The first `LiveAgentsProbe` result and the first transcript record correct the status within 10 s.
4. Restores `level`, `colorIndex`, `title`, `unreadTurns`.
5. Restores `activeSessionID` only if that session survived steps 1–2; otherwise no session is active.

### 5.6 API

```swift
public actor SessionStateCache {
    public struct Snapshot: Codable, Sendable {
        public var version: Int
        public var savedAt: Date
        public var activeSessionID: SessionID?
        public var sessions: [PersistedSession]
    }
    public struct PersistedSession: Codable, Sendable { /* fields as in 5.1 */ }
    public init(fileURL: URL, clock: Clock)
    public func load() throws -> Snapshot?
    public func scheduleSave(_ snapshot: Snapshot)
    public func saveNow(_ snapshot: Snapshot) throws
}
```

A corrupt file (decode failure) is renamed to `sessions.json.corrupt-<timestamp>` and treated as absent, logged at `.error`.

## 6. Voice catalog cache

`~/Library/Application Support/Claudio/voices-<backendID>.json`

```json
{ "version": 1, "fetchedAt": "2026-10-09T12:00:00Z", "voices": [ { "backend": "edge", "id": "en-US-GuyNeural", "displayName": "Guy", "locale": "en-US", "gender": "Male", "quality": null } ] }
```

TTL is 24 h from `fetchedAt`. `VoiceCatalog.voices(for:)` returns the cached list when fresh, otherwise asks the backend and rewrites the file; on backend failure it returns the stale cache and logs. The Apple backend's list is not cached (it is instant and reflects installed voices). The "Recheck" button and a backend change bypass the TTL.

## 7. Settings.json backups

`~/Library/Application Support/Claudio/backups/settings-<yyyyMMdd-HHmmss>.json`

`HookInstaller` copies `~/.claude/settings.json` here before every write. After writing it prunes to the 10 newest by filename. Backups are never auto-restored; document 11 describes manual restoration.

## 8. Logs

`~/Library/Logs/Claudio/claudio.log`, rotated at 5 MiB into `claudio.1.log` … `claudio.5.log` (oldest deleted). The file logger duplicates what goes to `os.Logger` at or above `logLevel`. Format: `2026-10-09T14:03:21.123Z INFO  arbiter  session=562358f2 turn=e89a4f1b activate mode=catchingUp plan=3`. Document 11 covers categories and reading them.

## 9. `Paths`

```swift
public struct Paths: Sendable {
    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                home: URL = FileManager.default.homeDirectoryForCurrentUser,
                bundleURL: URL? = Bundle.main.bundleURL)

    // Claude Code
    public var claudeConfigDir: URL          // $CLAUDE_CONFIG_DIR or ~/.claude
    public var claudeSettingsFile: URL       // claudeConfigDir/settings.json
    public var defaultTranscriptRoot: URL    // claudeConfigDir/projects
    public var claudeSkillsDir: URL          // claudeConfigDir/skills
    public var speakSkillDir: URL            // claudeSkillsDir/speak
    public func transcriptRoots(extra: [URL]) -> [URL]   // default + extra, deduplicated, existing only

    // Claudio
    public var applicationSupport: URL       // ~/Library/Application Support/Claudio
    public var controlSocket: URL            // $CLAUDIO_SOCKET or applicationSupport/claudio.sock
    public var projectsFile: URL             // applicationSupport/projects.json
    public var sessionsFile: URL             // applicationSupport/sessions.json
    public func voiceCacheFile(_ backend: BackendID) -> URL
    public var backupsDirectory: URL         // applicationSupport/backups
    public var logsDirectory: URL            // ~/Library/Logs/Claudio
    public var logFile: URL                  // logsDirectory/claudio.log

    // Bundle
    public var cliExecutable: URL?           // bundleURL/Contents/MacOS/claudio
    public var hookCommand: String?          // "\(cliExecutable.path) hook", nil when unbundled
    public var cliSymlink: URL               // /usr/local/bin/claudio

    public func ensureDirectories() throws   // creates applicationSupport, backups, logs with 0700
}
```

`claudeConfigDir` honours `CLAUDE_CONFIG_DIR` exactly as Claude Code does, so a user who runs Claude with a relocated config directory gets hooks and transcripts in the right place without extra configuration. `transcriptRoots(extra:)` expands `~`, resolves symlinks, removes duplicates, and filters to directories that exist at call time; `SessionDiscovery` re-evaluates it when a root appears later.

The socket path must be under 104 bytes (the `sockaddr_un` limit). The default is about 70 bytes for typical usernames; `Paths.init` asserts the limit and, if exceeded, falls back to `/tmp/claudio-<uid>.sock` and logs at `.error`.

## 10. Reset and uninstall

### 10.1 Settings → Advanced → "Reset all settings…"

`SettingsViewModel.resetAll()`:

1. `UserDefaults.removePersistentDomain(forName: suiteName)`.
2. Deletes `projects.json`, `sessions.json`, every `voices-*.json`.
3. Resets hotkeys via `KeyboardShortcuts.reset(...)`.
4. Does **not** touch the Keychain item, `~/.claude/settings.json`, the CLI symlink, or the skill. The confirmation copy says so.
5. Re-applies defaults in memory; the app keeps running.

### 10.2 `claudio uninstall --all`

Removes, in order, each only if present, printing one line per item:

1. Hook entries from `~/.claude/settings.json` (via `HookInstaller.uninstall`, with backup).
2. `~/.claude/skills/speak/`.
3. `/usr/local/bin/claudio` if it points into a Claudio bundle.
4. Login item registration.
5. Keychain item.
6. `~/Library/Application Support/Claudio/` (including the socket, backups, caches).
7. `~/Library/Logs/Claudio/`.
8. The UserDefaults domain.

It does not delete `Claudio.app` itself; the final line says "Drag Claudio.app to the Trash to finish." If the app is running, the command first asks it to quit over the socket and waits up to 3 s.

## 11. Environment variables

| Variable | Effect | Used by |
|---|---|---|
| `CLAUDE_CONFIG_DIR` | Relocates `~/.claude` as Claude Code does. | `Paths` |
| `CLAUDIO_SOCKET` | Overrides the control socket path. Tests use a per-test temp path. | `Paths` |
| `CLAUDIO_LOG_LEVEL` | `error`/`info`/`debug`; overrides the `logLevel` default for this process. | `Log` |
| `CLAUDIO_ROOTS` | Colon-separated extra transcript roots, appended to `extraTranscriptRoots` for this process. Lets a test or a script watch a synthetic transcript tree. | `SessionDiscovery` |
| `CLAUDIO_DEFAULTS_SUITE` | Alternate UserDefaults suite name. Tests use a random suite and remove it on teardown. | `AppSettings` |
| `CLAUDE_CODE_SESSION_ID` | Set by Claude Code in hook and tool subprocesses; the CLI uses it to mean "this session". | `ClaudioCLI` |
| `ORCA_WORKTREE_PATH` | Fallback session hint for the CLI inside Orca terminals. | `ClaudioCLI` |

## 12. Schema versioning and migration

```swift
public enum SchemaMigration {
    public static let currentDefaultsVersion = 1
    public static let currentProjectsVersion = 1
    public static let currentSessionsVersion = 1

    public static func migrateDefaults(_ defaults: UserDefaults)
    public static func migrateProjects(_ json: inout JSONObject) throws
    public static func migrateSessions(_ json: inout JSONObject) throws
}
```

Each `migrate*` function reads `version`, applies step functions `v1→v2`, `v2→v3` … in sequence, and sets `version` to current. A file with a version newer than the running app can read is renamed with a `.newer-<version>` suffix, treated as absent, and logged at `.error` with the message "sessions.json was written by a newer Claudio; starting fresh." Migration functions are pure over an in-memory `JSONObject` (`[String: Any]`) so they are testable without files. Adding a key with a default needs no migration; renaming or changing semantics does and bumps the version.

## 13. Tests

| Test | Pins |
|---|---|
| `AppSettingsTests.testEveryKeyHasDefaultAndRoundTrips` | §2.2: iterate all keys, write a non-default, read back, remove, read default |
| `AppSettingsTests.testInvalidEnumFallsBackToDefaultAndRewrites` | §2.3 |
| `AppSettingsTests.testRateClamped` | §2.3 |
| `AppSettingsTests.testHudFrameParsingRejectsGarbage` | §2.3 |
| `AppSettingsTests.testSnapshotStreamCoalescesBursts` | §2.4 bufferingNewest(1) |
| `AppSettingsTests.testExternalDefaultsChangePropagates` | §2.1 didChangeNotification |
| `AppSettingsTests.testBackendChangeResetsForeignVoiceID` | §2.2 voiceID |
| `KeychainStoreTests.testSetGetUpdateDelete` | §3 (skipped on CI without a login keychain) |
| `ProjectPreferencesTests.testExactMatchBeatsAncestor` | §4.3 |
| `ProjectPreferencesTests.testNearestAncestorInheritanceForWorktree` | §4.3 |
| `ProjectPreferencesTests.testHomeAndRootOnlyMatchExactly` | §4.3 |
| `ProjectPreferencesTests.testCanonicalizationResolvesSymlinksAndTrailingSlash` | §4.1 |
| `ProjectPreferencesTests.testAtomicWriteSurvivesSimulatedCrash` | §4.4 (temp file left behind is ignored) |
| `SessionStateCacheTests.testDebouncedSaveWritesOnceForBurst` | §5.3 |
| `SessionStateCacheTests.testSaveNowOnTerminate` | §5.3 |
| `SessionStateCacheTests.testFinalAnswerTruncatedAtGraphemeBoundary` | §5.4 |
| `SessionStateCacheTests.testMaxFiveUnreadPerSessionNewestKept` | §5.4 |
| `SessionStateCacheTests.testRestoreDropsExpiredAndMissingTranscripts` | §5.5 |
| `SessionStateCacheTests.testRestoreNeverYieldsBusyOrWaiting` | §5.5 |
| `SessionStateCacheTests.testRestoreActiveSessionOnlyIfSurvived` | §5.5 |
| `SessionStateCacheTests.testCorruptFileRenamedAndIgnored` | §5.6 |
| `SessionStateCacheTests.testNewerVersionRenamedAndIgnored` | §12 |
| `VoiceCatalogCacheTests.testTTLHonouredAndStaleReturnedOnFailure` | §6 |
| `PathsTests.testClaudeConfigDirOverride` | §9 |
| `PathsTests.testSocketOverrideAndLengthFallback` | §9 |
| `PathsTests.testTranscriptRootsDedupExpandAndFilterExisting` | §9 |
| `PathsTests.testHookCommandNilWhenUnbundled` | §9 |
| `SchemaMigrationTests.testSequentialStepsApplied` | §12 |
| `ResetTests.testResetAllPreservesKeychainHooksSymlinkSkill` | §10.1 |
| `UninstallTests.testUninstallAllRemovesOnlyOwnedItems` | §10.2 (uses temp HOME and a fixture settings.json containing foreign hooks) |
