import Foundation

public typealias JSONObject = [String: Any]

/// Versioned migrations for UserDefaults and the JSON stores (document 08 §12).
public enum SchemaMigration {
    public static let currentDefaultsVersion = 1
    public static let currentProjectsVersion = 1
    public static let currentSessionsVersion = 1

    public enum MigrationError: Error, Equatable {
        case newerVersion(Int)
    }

    public static func migrateDefaults(_ defaults: UserDefaults) {
        let key = AppSettings.Key.settingsSchemaVersion.rawValue
        let version = defaults.object(forKey: key) == nil ? 0 : defaults.integer(forKey: key)
        if version < currentDefaultsVersion {
            // v0 → v1: no key changes; just stamp the version.
            defaults.set(currentDefaultsVersion, forKey: key)
        }
    }

    public static func migrateProjects(_ json: inout JSONObject) throws {
        try migrate(&json, to: currentProjectsVersion, steps: [:])
    }

    public static func migrateSessions(_ json: inout JSONObject) throws {
        try migrate(&json, to: currentSessionsVersion, steps: [:])
    }

    /// Applies step functions `from → from+1` in sequence until `target`.
    public static func migrate(_ json: inout JSONObject, to target: Int,
                               steps: [Int: (inout JSONObject) -> Void]) throws {
        var version = (json["version"] as? Int) ?? 1
        if version > target { throw MigrationError.newerVersion(version) }
        while version < target {
            steps[version]?(&json)
            version += 1
        }
        json["version"] = target
    }
}
