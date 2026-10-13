import Foundation

public struct Voice: Codable, Hashable, Sendable {
    public let backend: BackendID
    public let id: String
    public let displayName: String
    public let locale: String
    public let gender: String?
    public let quality: String?

    public init(backend: BackendID, id: String, displayName: String, locale: String, gender: String? = nil,
                quality: String? = nil) {
        self.backend = backend
        self.id = id
        self.displayName = displayName
        self.locale = locale
        self.gender = gender
        self.quality = quality
    }

    public var languageCode: String {
        String(locale.split(separator: "-").first ?? Substring(locale)).lowercased()
    }

    public var summary: VoiceSummary {
        VoiceSummary(backend: backend, id: id, displayName: displayName, locale: locale, gender: gender, quality: quality)
    }
}
