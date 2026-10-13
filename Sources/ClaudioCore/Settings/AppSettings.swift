import Foundation
import Observation
import Synchronization

/// Sendable value copy of the settings that core actors consume (document 08 §2.4).
public struct AppSettingsSnapshot: Sendable, Equatable {
    public var backendID: BackendID
    public var voiceID: String
    public var fallbackVoiceID: String?
    public var rate: Double
    public var eventsEnabled: Bool
    public var chimesEnabled: Bool
    public var chimeVolume: Double
    public var defaultLevelNewSession: SpeechLevel
    public var defaultLevelActive: SpeechLevel
    public var speakThinking: Bool
    public var speakToolErrors: Bool
    public var extraTranscriptRoots: [URL]
    public var hooksEnabled: Bool
    public var lookahead: Int
    public var fallbackTimeoutSeconds: Double
    public var sessionExpiryHours: Int
    public var openAIModel: String
    public var openAIVoice: String
    public var logLevel: LogLevel
    public var liveAgentsProbeInterval: Double
    public var orcaWorktreeRoots: [URL]

    public init(backendID: BackendID = "edge", voiceID: String = "en-US-GuyNeural", fallbackVoiceID: String? = nil,
                rate: Double = 1.0, eventsEnabled: Bool = true, chimesEnabled: Bool = true, chimeVolume: Double = 0.6,
                defaultLevelNewSession: SpeechLevel = .answers, defaultLevelActive: SpeechLevel = .narrate,
                speakThinking: Bool = false, speakToolErrors: Bool = false, extraTranscriptRoots: [URL] = [],
                hooksEnabled: Bool = false, lookahead: Int = 2, fallbackTimeoutSeconds: Double = 3.0,
                sessionExpiryHours: Int = 24, openAIModel: String = "gpt-4o-mini-tts", openAIVoice: String = "alloy",
                logLevel: LogLevel = .info, liveAgentsProbeInterval: Double = 10, orcaWorktreeRoots: [URL] = []) {
        self.backendID = backendID
        self.voiceID = voiceID
        self.fallbackVoiceID = fallbackVoiceID
        self.rate = rate
        self.eventsEnabled = eventsEnabled
        self.chimesEnabled = chimesEnabled
        self.chimeVolume = chimeVolume
        self.defaultLevelNewSession = defaultLevelNewSession
        self.defaultLevelActive = defaultLevelActive
        self.speakThinking = speakThinking
        self.speakToolErrors = speakToolErrors
        self.extraTranscriptRoots = extraTranscriptRoots
        self.hooksEnabled = hooksEnabled
        self.lookahead = lookahead
        self.fallbackTimeoutSeconds = fallbackTimeoutSeconds
        self.sessionExpiryHours = sessionExpiryHours
        self.openAIModel = openAIModel
        self.openAIVoice = openAIVoice
        self.logLevel = logLevel
        self.liveAgentsProbeInterval = liveAgentsProbeInterval
        self.orcaWorktreeRoots = orcaWorktreeRoots
    }
}

/// UserDefaults-backed, observable, live settings (document 08 §2).
@Observable
public final class AppSettings: @unchecked Sendable {
    public static let suiteName = "com.jdforsythe.claudio"

    public enum Key: String, CaseIterable {
        case backendID, voiceID, fallbackVoiceID, rate, showHUD, hudCaptionsExpanded, hudPinned, hudFrame
        case eventsEnabled, chimesEnabled, chimeVolume, defaultLevelNewSession, defaultLevelActive
        case speakThinking, speakToolErrors, extraTranscriptRoots, hooksEnabled, launchAtLogin, logLevel
        case firstLaunchCompleted, lookahead, fallbackTimeoutSeconds, sessionExpiryHours, openAIModel, openAIVoice
        case settingsSchemaVersion, liveAgentsProbeInterval, orcaWorktreeRoots, fallbackVoiceOverrides
        case autoUpdateCheck, lastUpdateCheck
    }

    public enum Defaults {
        public static let backendID = "edge"
        public static let voiceID = "en-US-GuyNeural"
        public static let rate = 1.0
        public static let chimeVolume = 0.6
        public static let lookahead = 2
        public static let fallbackTimeoutSeconds = 3.0
        public static let sessionExpiryHours = 24
        public static let openAIModel = "gpt-4o-mini-tts"
        public static let openAIVoice = "alloy"
        public static let liveAgentsProbeInterval = 10.0
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let broadcast = Broadcast<AppSettingsSnapshot>(replayLatest: true, bufferingPolicy: .bufferingNewest(1))
    @ObservationIgnored private let warned = Mutex<Set<String>>([])
    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    public static func makeDefaults(environment: [String: String] = ProcessInfo.processInfo.environment) -> UserDefaults {
        let suite = environment["CLAUDIO_DEFAULTS_SUITE"] ?? suiteName
        return UserDefaults(suiteName: suite) ?? .standard
    }

    public init(defaults: UserDefaults = AppSettings.makeDefaults()) {
        self.defaults = defaults
        SchemaMigration.migrateDefaults(defaults)
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults,
                                                          queue: nil) { [weak self] _ in
            self?.publish()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: Observation

    public func changes() -> AsyncStream<AppSettingsSnapshot> { broadcast.subscribe() }

    public var snapshot: AppSettingsSnapshot {
        AppSettingsSnapshot(
            backendID: backendID, voiceID: voiceID, fallbackVoiceID: fallbackVoiceID, rate: rate,
            eventsEnabled: eventsEnabled, chimesEnabled: chimesEnabled, chimeVolume: chimeVolume,
            defaultLevelNewSession: defaultLevelNewSession, defaultLevelActive: defaultLevelActive,
            speakThinking: speakThinking, speakToolErrors: speakToolErrors,
            extraTranscriptRoots: extraTranscriptRoots, hooksEnabled: hooksEnabled, lookahead: lookahead,
            fallbackTimeoutSeconds: fallbackTimeoutSeconds, sessionExpiryHours: sessionExpiryHours,
            openAIModel: openAIModel, openAIVoice: openAIVoice, logLevel: logLevel,
            liveAgentsProbeInterval: liveAgentsProbeInterval, orcaWorktreeRoots: orcaWorktreeRoots)
    }

    private func publish() {
        broadcast.send(snapshot)
    }

    // MARK: Generic accessors

    private func string(_ key: Key, default d: String) -> String {
        defaults.string(forKey: key.rawValue) ?? d
    }

    private func bool(_ key: Key, default d: Bool) -> Bool {
        defaults.object(forKey: key.rawValue) == nil ? d : defaults.bool(forKey: key.rawValue)
    }

    private func double(_ key: Key, default d: Double) -> Double {
        defaults.object(forKey: key.rawValue) == nil ? d : defaults.double(forKey: key.rawValue)
    }

    private func int(_ key: Key, default d: Int) -> Int {
        defaults.object(forKey: key.rawValue) == nil ? d : defaults.integer(forKey: key.rawValue)
    }

    private func set(_ value: Any?, _ key: Key) {
        withMutation(keyPath: \.snapshot) {
            if let value { defaults.set(value, forKey: key.rawValue) } else { defaults.removeObject(forKey: key.rawValue) }
        }
        publish()
    }

    private func warnOnce(_ key: Key, _ raw: String) {
        let first = warned.withLock { $0.insert(key.rawValue).inserted }
        if first { Log.settings.info("invalid value for \(key.rawValue): \(raw); using default") }
    }

    private func enumValue<E: RawRepresentable>(_ key: Key, default d: E) -> E where E.RawValue == String {
        guard let raw = defaults.string(forKey: key.rawValue) else { return d }
        if let v = E(rawValue: raw) { return v }
        warnOnce(key, raw)
        defaults.removeObject(forKey: key.rawValue)
        return d
    }

    // MARK: Keys

    public var backendID: BackendID {
        get { access(keyPath: \.backendID); return string(.backendID, default: Defaults.backendID) }
        set {
            withMutation(keyPath: \.backendID) {
                defaults.set(newValue, forKey: Key.backendID.rawValue)
                // Reset a foreign voice id to the new backend's default (document 08 §2.2).
                let voice = voiceID
                if !Self.voice(voice, belongsTo: newValue) {
                    defaults.set(Self.defaultVoice(for: newValue), forKey: Key.voiceID.rawValue)
                }
            }
            publish()
        }
    }

    public static func defaultVoice(for backend: BackendID) -> String {
        switch backend {
        case "edge": Defaults.voiceID
        case "openai": Defaults.openAIVoice
        case "apple": ""
        default: ""
        }
    }

    public static func voice(_ voiceID: String, belongsTo backend: BackendID) -> Bool {
        switch backend {
        case "edge": voiceID.contains("Neural") || voiceID.contains("-")
        case "apple": voiceID.hasPrefix("com.apple.") || voiceID.isEmpty
        case "openai": !voiceID.contains(".") && !voiceID.contains("-")
        default: true
        }
    }

    public var voiceID: String {
        get { access(keyPath: \.voiceID); return string(.voiceID, default: Self.defaultVoice(for: backendID)) }
        set { set(newValue, .voiceID) }
    }

    public var fallbackVoiceID: String? {
        get { access(keyPath: \.fallbackVoiceID); let v = defaults.string(forKey: Key.fallbackVoiceID.rawValue); return v?.isEmpty == true ? nil : v }
        set { set(newValue, .fallbackVoiceID) }
    }

    public var rate: Double {
        get { access(keyPath: \.rate); return min(2.0, max(0.5, double(.rate, default: Defaults.rate))) }
        set { set(min(2.0, max(0.5, newValue)), .rate) }
    }

    public var showHUD: Bool {
        get { access(keyPath: \.showHUD); return bool(.showHUD, default: true) }
        set { set(newValue, .showHUD) }
    }

    public var hudCaptionsExpanded: Bool {
        get { access(keyPath: \.hudCaptionsExpanded); return bool(.hudCaptionsExpanded, default: false) }
        set { set(newValue, .hudCaptionsExpanded) }
    }

    public var hudPinned: Bool {
        get { access(keyPath: \.hudPinned); return bool(.hudPinned, default: false) }
        set { set(newValue, .hudPinned) }
    }

    /// Stored as "x,y,w,h"; nil when absent or unparsable.
    public var hudFrame: CGRect? {
        get {
            access(keyPath: \.hudFrame)
            guard let raw = defaults.string(forKey: Key.hudFrame.rawValue) else { return nil }
            let parts = raw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 4, parts.allSatisfy(\.isFinite), parts[2] > 0, parts[3] > 0 else {
                warnOnce(.hudFrame, raw)
                defaults.removeObject(forKey: Key.hudFrame.rawValue)
                return nil
            }
            return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
        }
        set {
            if let r = newValue {
                set("\(r.origin.x),\(r.origin.y),\(r.size.width),\(r.size.height)", .hudFrame)
            } else {
                set(nil, .hudFrame)
            }
        }
    }

    public var eventsEnabled: Bool {
        get { access(keyPath: \.eventsEnabled); return bool(.eventsEnabled, default: true) }
        set { set(newValue, .eventsEnabled) }
    }

    public var chimesEnabled: Bool {
        get { access(keyPath: \.chimesEnabled); return bool(.chimesEnabled, default: true) }
        set { set(newValue, .chimesEnabled) }
    }

    public var chimeVolume: Double {
        get { access(keyPath: \.chimeVolume); return min(1, max(0, double(.chimeVolume, default: Defaults.chimeVolume))) }
        set { set(min(1, max(0, newValue)), .chimeVolume) }
    }

    public var defaultLevelNewSession: SpeechLevel {
        get { access(keyPath: \.defaultLevelNewSession); return enumValue(.defaultLevelNewSession, default: .answers) }
        set { set(newValue.rawValue, .defaultLevelNewSession) }
    }

    public var defaultLevelActive: SpeechLevel {
        get { access(keyPath: \.defaultLevelActive); return enumValue(.defaultLevelActive, default: .narrate) }
        set { set(newValue.rawValue, .defaultLevelActive) }
    }

    public var speakThinking: Bool {
        get { access(keyPath: \.speakThinking); return bool(.speakThinking, default: false) }
        set { set(newValue, .speakThinking) }
    }

    public var speakToolErrors: Bool {
        get { access(keyPath: \.speakToolErrors); return bool(.speakToolErrors, default: false) }
        set { set(newValue, .speakToolErrors) }
    }

    private func urlList(_ key: Key) -> [URL] {
        let raw = defaults.stringArray(forKey: key.rawValue) ?? []
        return raw.compactMap { s in
            let expanded = (s as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else {
                warnOnce(key, s)
                return nil
            }
            return URL(fileURLWithPath: expanded)
        }
    }

    public var extraTranscriptRoots: [URL] {
        get { access(keyPath: \.extraTranscriptRoots); return urlList(.extraTranscriptRoots) }
        set { set(newValue.map(\.path), .extraTranscriptRoots) }
    }

    public var orcaWorktreeRoots: [URL] {
        get { access(keyPath: \.orcaWorktreeRoots); return urlList(.orcaWorktreeRoots) }
        set { set(newValue.map(\.path), .orcaWorktreeRoots) }
    }

    public var hooksEnabled: Bool {
        get { access(keyPath: \.hooksEnabled); return bool(.hooksEnabled, default: false) }
        set { set(newValue, .hooksEnabled) }
    }

    public var launchAtLogin: Bool {
        get { access(keyPath: \.launchAtLogin); return bool(.launchAtLogin, default: false) }
        set { set(newValue, .launchAtLogin) }
    }

    public var logLevel: LogLevel {
        get { access(keyPath: \.logLevel); return enumValue(.logLevel, default: .info) }
        set { set(newValue.rawValue, .logLevel) }
    }

    public var firstLaunchCompleted: Bool {
        get { access(keyPath: \.firstLaunchCompleted); return bool(.firstLaunchCompleted, default: false) }
        set { set(newValue, .firstLaunchCompleted) }
    }

    public var lookahead: Int {
        get { access(keyPath: \.lookahead); return min(4, max(1, int(.lookahead, default: Defaults.lookahead))) }
        set { set(min(4, max(1, newValue)), .lookahead) }
    }

    public var fallbackTimeoutSeconds: Double {
        get { access(keyPath: \.fallbackTimeoutSeconds); return max(0.5, double(.fallbackTimeoutSeconds, default: Defaults.fallbackTimeoutSeconds)) }
        set { set(newValue, .fallbackTimeoutSeconds) }
    }

    public var sessionExpiryHours: Int {
        get { access(keyPath: \.sessionExpiryHours); return max(1, int(.sessionExpiryHours, default: Defaults.sessionExpiryHours)) }
        set { set(newValue, .sessionExpiryHours) }
    }

    public var openAIModel: String {
        get { access(keyPath: \.openAIModel); return string(.openAIModel, default: Defaults.openAIModel) }
        set { set(newValue, .openAIModel) }
    }

    public var openAIVoice: String {
        get { access(keyPath: \.openAIVoice); return string(.openAIVoice, default: Defaults.openAIVoice) }
        set { set(newValue, .openAIVoice) }
    }

    public var liveAgentsProbeInterval: Double {
        get { access(keyPath: \.liveAgentsProbeInterval); return max(2, double(.liveAgentsProbeInterval, default: Defaults.liveAgentsProbeInterval)) }
        set { set(newValue, .liveAgentsProbeInterval) }
    }

    /// Per-primary-voice fallback overrides (document 06 §6).
    public var fallbackVoiceOverrides: [String: String] {
        get { access(keyPath: \.fallbackVoiceOverrides); return defaults.dictionary(forKey: Key.fallbackVoiceOverrides.rawValue) as? [String: String] ?? [:] }
        set { set(newValue, .fallbackVoiceOverrides) }
    }

    public var autoUpdateCheck: Bool {
        get { access(keyPath: \.autoUpdateCheck); return bool(.autoUpdateCheck, default: true) }
        set { set(newValue, .autoUpdateCheck) }
    }

    public var lastUpdateCheck: Date {
        get { access(keyPath: \.lastUpdateCheck); return defaults.object(forKey: Key.lastUpdateCheck.rawValue) as? Date ?? .distantPast }
        set { set(newValue, .lastUpdateCheck) }
    }

    public var settingsSchemaVersion: Int {
        int(.settingsSchemaVersion, default: SchemaMigration.currentDefaultsVersion)
    }

    /// Removes every key in the suite (document 08 §10.1).
    public func resetAll() {
        withMutation(keyPath: \.snapshot) {
            for key in Key.allCases { defaults.removeObject(forKey: key.rawValue) }
        }
        publish()
    }

    /// Voice to use for a given backend: the configured one when it belongs to the backend.
    public func voiceID(for backend: BackendID) -> String {
        if backend == backendID { return voiceID }
        if backend == "openai" { return openAIVoice }
        return Self.defaultVoice(for: backend)
    }
}
