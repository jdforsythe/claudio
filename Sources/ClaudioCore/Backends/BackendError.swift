import Foundation

public enum BackendError: Error, Sendable, Equatable {
    case network(String)
    case auth(String)
    case rateLimited(retryAfter: TimeInterval?)
    case invalidVoice(String)
    case timeout(stage: String)
    case decode(String)
    case unavailable(String)

    public var shortDescription: String {
        switch self {
        case .network(let s): "network: \(s)"
        case .auth(let s): "auth: \(s)"
        case .rateLimited(let r): "rate limited\(r.map { " retry after \($0)s" } ?? "")"
        case .invalidVoice(let v): "invalid voice \(v)"
        case .timeout(let stage): "timeout (\(stage))"
        case .decode(let s): "decode: \(s)"
        case .unavailable(let s): "unavailable: \(s)"
        }
    }
}
