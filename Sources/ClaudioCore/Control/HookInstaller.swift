import Foundation

public enum HookInstallerError: Error, Equatable {
    case settingsMalformed(String)
    case writeFailed(String)
    case verifyFailed
    case unbundled
}

/// Merges Claudio's hook groups into `~/.claude/settings.json` (document 04 §3).
public struct HookInstaller: Sendable {
    public typealias Status = HookInstallStatus

    public static let events = ["UserPromptSubmit", "Stop", "StopFailure", "SubagentStop", "Notification", "SessionStart", "SessionEnd"]
    public static let eventsWithMatcher: Set<String> = ["StopFailure", "SubagentStop", "Notification", "SessionStart", "SessionEnd"]
    public static let backupsToKeep = 10
    static let ownCommand = Rx(#"^(.*/Claudio\.app)/Contents/(?:Helpers|MacOS)/claudio hook$"#)

    public let settingsURL: URL
    public let backupsDirectory: URL
    public let bundleURL: URL?
    public let clock: any ClaudioClock
    private let log = Log.hooks

    public init(settingsURL: URL, backupsDirectory: URL, bundleURL: URL?, clock: any ClaudioClock = SystemClock()) {
        self.settingsURL = settingsURL
        self.backupsDirectory = backupsDirectory
        self.bundleURL = bundleURL
        self.clock = clock
    }

    public var command: String? {
        guard let bundleURL, bundleURL.pathExtension == "app" else { return nil }
        return bundleURL.standardizedFileURL.path + "/Contents/Helpers/claudio hook"
    }

    // MARK: Status

    public func status() -> Status {
        let root: JSONObject
        do {
            root = try readSettings()
        } catch HookInstallerError.settingsMalformed(let reason) {
            return .settingsUnreadable(reason)
        } catch {
            return .settingsUnreadable(String(describing: error))
        }
        let hooks = root["hooks"] as? JSONObject ?? [:]
        var count = 0
        var paths = Set<String>()
        for event in Self.events {
            guard let groups = hooks[event] as? [Any] else { continue }
            for g in groups {
                if let path = Self.ownBundlePath(group: g) {
                    count += 1
                    paths.insert(path)
                }
            }
        }
        if count == 0 { return .notInstalled }
        let current = bundleURL?.standardizedFileURL.path
        if count < Self.events.count { return .partial(installed: count, expected: Self.events.count) }
        if let current, paths.count == 1, paths.first == current {
            return .installed(count: count, bundlePath: current)
        }
        return .installedElsewhere(count: count, bundlePath: paths.first ?? "")
    }

    public static func ownBundlePath(group: Any) -> String? {
        guard let g = group as? JSONObject, let hooks = g["hooks"] as? [Any], hooks.count == 1,
              let hook = hooks[0] as? JSONObject, hook["type"] as? String == "command",
              let command = hook["command"] as? String, let m = ownCommand.captures(command) else { return nil }
        return m[1]
    }

    // MARK: Install / uninstall

    public func install() throws {
        guard let command else { throw HookInstallerError.unbundled }
        var root = try readSettings()
        var hooks = root["hooks"] as? JSONObject ?? [:]
        for event in Self.events {
            var groups: [Any]
            if let existing = hooks[event] {
                guard let arr = existing as? [Any] else {
                    throw HookInstallerError.settingsMalformed("hooks.\(event) is not an array")
                }
                groups = arr
            } else {
                groups = []
            }
            groups.removeAll { Self.ownBundlePath(group: $0) != nil }
            var group: JSONObject = ["hooks": [["type": "command", "command": command, "async": true]]]
            if Self.eventsWithMatcher.contains(event) { group["matcher"] = "" }
            groups.append(group)
            hooks[event] = groups
        }
        root["hooks"] = hooks
        try backup()
        try writeAndVerify(root, expectInstalled: true)
        log.notice("hooks installed pointing at \(command)")
    }

    public func uninstall() throws {
        var root = try readSettings()
        guard var hooks = root["hooks"] as? JSONObject else { return }
        var changed = false
        for (event, value) in hooks {
            guard var groups = value as? [Any] else { continue }
            let before = groups.count
            groups.removeAll { Self.ownBundlePath(group: $0) != nil }
            if groups.count != before {
                changed = true
                if groups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = groups }
            }
        }
        guard changed else { return }
        root["hooks"] = hooks
        try backup()
        try writeAndVerify(root, expectInstalled: false)
        log.notice("hooks uninstalled")
    }

    public func repair() throws {
        try uninstall()
        try install()
    }

    // MARK: Files

    func readSettings() throws -> JSONObject {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        let data = try Data(contentsOf: settingsURL)
        if data.isEmpty { return [:] }
        do {
            guard let obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? JSONObject else {
                throw HookInstallerError.settingsMalformed("top level is not an object")
            }
            return obj
        } catch let e as HookInstallerError {
            throw e
        } catch {
            throw HookInstallerError.settingsMalformed(String(describing: error))
        }
    }

    func backup() throws {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: backupsDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stamp = SessionStateCache.stamp(clock.now)
        var target = backupsDirectory.appendingPathComponent("settings-\(stamp).json")
        var n = 1
        while fm.fileExists(atPath: target.path) {
            target = backupsDirectory.appendingPathComponent("settings-\(stamp)-\(n).json")
            n += 1
        }
        try fm.copyItem(at: settingsURL, to: target)
        log.notice("settings.json backed up to \(target.path)")
        let backups = ((try? fm.contentsOfDirectory(atPath: backupsDirectory.path)) ?? [])
            .filter { $0.hasPrefix("settings-") && $0.hasSuffix(".json") }.sorted()
        if backups.count > Self.backupsToKeep {
            for old in backups.prefix(backups.count - Self.backupsToKeep) {
                try? fm.removeItem(at: backupsDirectory.appendingPathComponent(old))
            }
        }
    }

    func writeAndVerify(_ root: JSONObject, expectInstalled: Bool) throws {
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
        } catch {
            throw HookInstallerError.writeFailed(String(describing: error))
        }
        let previous = try? Data(contentsOf: settingsURL)
        do {
            try AtomicFile.write(data, to: settingsURL, permissions: previous == nil ? 0o600 : nil)
        } catch {
            throw HookInstallerError.writeFailed(String(describing: error))
        }
        let after = status()
        let ok: Bool
        switch after {
        case .installed: ok = expectInstalled
        case .notInstalled: ok = !expectInstalled
        default: ok = false
        }
        if !ok {
            if let previous { try? previous.write(to: settingsURL) }
            throw HookInstallerError.verifyFailed
        }
    }
}
