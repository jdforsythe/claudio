import Foundation

/// Small recursive JSON representation used for tool inputs and hook payload fields.
public enum JSONValue: Codable, Sendable, Equatable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? container.decode(Double.self) {
            self = .number(n)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? container.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported JSON value")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let n): try container.encode(n)
        case .bool(let b): try container.encode(b)
        case .null: try container.encodeNil()
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var numberValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    /// Builds a JSONValue from a Foundation object produced by `JSONSerialization`.
    public init?(foundation: Any) {
        switch foundation {
        case let s as String: self = .string(s)
        case let b as Bool: self = .bool(b)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else {
                self = .number(n.doubleValue)
            }
        case is NSNull: self = .null
        case let a as [Any]:
            self = .array(a.compactMap { JSONValue(foundation: $0) })
        case let o as [String: Any]:
            var out: [String: JSONValue] = [:]
            for (k, v) in o {
                if let jv = JSONValue(foundation: v) { out[k] = jv }
            }
            self = .object(out)
        default:
            return nil
        }
    }

    /// Converts back to a Foundation object suitable for `JSONSerialization`.
    public var foundationObject: Any {
        switch self {
        case .string(let s): s
        case .number(let n): n
        case .bool(let b): b
        case .null: NSNull()
        case .array(let a): a.map(\.foundationObject)
        case .object(let o): o.mapValues(\.foundationObject)
        }
    }
}
