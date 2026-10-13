import ClaudioCore
import Foundation

/// Single source of voices for the UI, CLI and fallback pairing, with a 24 h disk cache (document 06 §6).
public actor VoiceCatalog {
    public static let ttl: TimeInterval = 24 * 3600

    private struct CacheFile: Codable {
        var version: Int
        var fetchedAt: Date
        var voices: [Voice]
    }

    private let backends: [BackendID: any TTSBackend]
    private let cacheDirectory: URL
    private let clock: any ClaudioClock
    private var memory: [BackendID: (fetchedAt: Date, voices: [Voice])] = [:]
    private var overrides: @Sendable () -> [String: String]
    private var preferredFallbackID: @Sendable () -> String?
    private let log = Log.speech

    public init(backends: [any TTSBackend], cacheDirectory: URL, clock: any ClaudioClock = SystemClock(),
                overrides: @escaping @Sendable () -> [String: String] = { [:] },
                preferredFallbackID: @escaping @Sendable () -> String? = { nil }) {
        self.backends = Dictionary(uniqueKeysWithValues: backends.map { ($0.id, $0) })
        self.cacheDirectory = cacheDirectory
        self.clock = clock
        self.overrides = overrides
        self.preferredFallbackID = preferredFallbackID
    }

    public func voices(for backend: BackendID, forceRefresh: Bool = false) async throws -> [Voice] {
        guard let b = backends[backend] else { throw BackendError.unavailable("no backend \(backend)") }
        if backend == "apple" { return try await b.voices() }
        let now = clock.now
        if !forceRefresh, let m = memory[backend], now.timeIntervalSince(m.fetchedAt) < Self.ttl { return m.voices }
        if !forceRefresh, let disk = loadDisk(backend), now.timeIntervalSince(disk.fetchedAt) < Self.ttl {
            memory[backend] = (disk.fetchedAt, disk.voices)
            return disk.voices
        }
        do {
            let fresh = try await b.voices()
            memory[backend] = (now, fresh)
            saveDisk(backend, fresh, at: now)
            return fresh
        } catch {
            log.notice("voice refresh failed for \(backend): \(error); using stale list")
            if let m = memory[backend] { return m.voices }
            if let disk = loadDisk(backend) { return disk.voices }
            if backend == "edge" { return EdgeVoiceList.builtIn }
            throw error
        }
    }

    public func allVoices() async -> [BackendID: Result<[Voice], BackendError>] {
        var out: [BackendID: Result<[Voice], BackendError>] = [:]
        for id in backends.keys {
            do {
                out[id] = .success(try await voices(for: id))
            } catch let e as BackendError {
                out[id] = .failure(e)
            } catch {
                out[id] = .failure(.unavailable(String(describing: error)))
            }
        }
        return out
    }

    public func voice(id: String, backend: BackendID) async -> Voice? {
        (try? await voices(for: backend))?.first { $0.id == id }
    }

    /// Resolves a voice id into a `Voice`, synthesizing a placeholder if the list is unavailable.
    public func resolve(id: String, backend: BackendID) async -> Voice {
        if let v = await voice(id: id, backend: backend) { return v }
        if backend == "apple" {
            return AppleSpeechBackend.defaultVoice() ?? Voice(backend: "apple", id: id, displayName: id, locale: "en-US")
        }
        let locale = backend == "edge" ? String(id.split(separator: "-").prefix(2).joined(separator: "-")) : "en-US"
        return Voice(backend: backend, id: id, displayName: id, locale: locale.isEmpty ? "en-US" : locale)
    }

    /// Apple voice paired with a primary voice: same language, same gender where known, highest quality (document 06 §6).
    public func fallbackVoice(for primary: Voice) async -> Voice {
        let apple = (try? await voices(for: "apple")) ?? []
        if let override = overrides()[primary.id], let v = apple.first(where: { $0.id == override }) { return v }
        if let preferred = preferredFallbackID(), let v = apple.first(where: { $0.id == preferred }) { return v }
        let ranked = AppleSpeechBackend.ranked(apple)
        let lang = primary.languageCode
        let sameLang = ranked.filter { $0.languageCode == lang }
        let pool = sameLang.isEmpty ? ranked.filter { $0.languageCode == "en" } : sameLang
        if let g = primary.gender, let match = pool.first(where: { $0.gender == g }) { return match }
        if let first = pool.first { return first }
        return ranked.first ?? Voice(backend: "apple", id: "", displayName: "System voice", locale: "en-US")
    }

    private func cacheURL(_ backend: BackendID) -> URL {
        cacheDirectory.appendingPathComponent("voices-\(backend).json")
    }

    private func loadDisk(_ backend: BackendID) -> CacheFile? {
        guard let data = try? Data(contentsOf: cacheURL(backend)) else { return nil }
        return try? ControlCoding.decoder().decode(CacheFile.self, from: data)
    }

    private func saveDisk(_ backend: BackendID, _ voices: [Voice], at: Date) {
        let file = CacheFile(version: 1, fetchedAt: at, voices: voices)
        if let data = try? ControlCoding.encoder().encode(file) {
            try? AtomicFile.write(data, to: cacheURL(backend))
        }
    }

    public func clearDiskCache() {
        for id in backends.keys { try? FileManager.default.removeItem(at: cacheURL(id)) }
        memory.removeAll()
    }
}
