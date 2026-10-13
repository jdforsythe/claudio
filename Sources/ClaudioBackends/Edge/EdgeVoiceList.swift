import ClaudioCore
import Foundation

public enum EdgeVoiceList {
    public static func parse(_ data: Data) throws -> [Voice] {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw BackendError.decode("voices list is not an array")
        }
        return array.compactMap { entry in
            guard let short = entry["ShortName"] as? String else { return nil }
            let friendly = entry["FriendlyName"] as? String ?? short
            let locale = entry["Locale"] as? String ?? "en-US"
            var name = friendly
            if let r1 = friendly.range(of: "Microsoft "), let r2 = friendly.range(of: " Online") {
                name = String(friendly[r1.upperBound..<r2.lowerBound])
            }
            var display = "\(name) (\(locale))"
            if short.contains("Multilingual") { display += " · multilingual" }
            return Voice(backend: "edge", id: short, displayName: display, locale: locale, gender: entry["Gender"] as? String)
        }
    }

    public static var builtIn: [Voice] {
        EdgeConstants.builtInVoices.map { Voice(backend: "edge", id: $0.id, displayName: "\($0.name) (\($0.locale))", locale: $0.locale, gender: $0.gender) }
    }
}
