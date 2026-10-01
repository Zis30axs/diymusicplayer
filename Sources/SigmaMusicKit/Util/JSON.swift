import Foundation

/// A small JSON value, standing in for Gson's `JsonElement`: loose accessors (a number read as a
/// string field is `nil`, a numeric string reads as a number) so the NetEase/QQ replies, which are
/// inconsistent about types, can be walked without a `Codable` model per endpoint.
public enum JSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    public init(_ value: Int) { self = .int(Int64(value)) }
    public init(_ value: Int64) { self = .int(value) }
    public init(_ value: Bool) { self = .bool(value) }
    public init(_ value: String) { self = .string(value) }

    // MARK: Parsing

    public static func parse(_ data: Data) throws -> JSON {
        try JSONDecoder().decode(JSON.self, from: data)
    }

    public static func parse(_ text: String) throws -> JSON {
        try parse(Data(text.utf8))
    }

    // MARK: Access

    public subscript(key: String) -> JSON? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public subscript(index: Int) -> JSON? {
        if case .array(let array) = self, array.indices.contains(index) { return array[index] }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var int64: Int64? {
        switch self {
        case .int(let value):
            return value
        case .double(let value):
            guard value.isFinite, value == value.rounded(), abs(value) < 9.0e18 else { return nil }
            return Int64(value)
        case .string(let value):
            return Int64(value.trimmingCharacters(in: .whitespaces))
        default:
            return nil
        }
    }

    public var int: Int? {
        guard let value = int64 else { return nil }
        return Int(exactly: value)
    }

    /// A JSON number (not a numeric string).
    public var number: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }

    public var bool: Bool? {
        switch self {
        case .bool(let value):
            return value
        case .string(let value):
            switch value.lowercased() {
            case "true": return true
            case "false": return false
            default: return nil
            }
        default:
            return nil
        }
    }

    public var array: [JSON]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var object: [String: JSON]? {
        if case .object(let value) = self { return value }
        return nil
    }

    // MARK: Serializing

    /// Compact JSON with object keys sorted, so the same value always produces the same text.
    public func serialized() -> String {
        var out = ""
        write(to: &out)
        return out
    }

    private func write(to out: inout String) {
        switch self {
        case .null:
            out += "null"
        case .bool(let value):
            out += value ? "true" : "false"
        case .int(let value):
            out += String(value)
        case .double(let value):
            out += value.isFinite ? "\(value)" : "null"
        case .string(let value):
            JSON.writeString(value, to: &out)
        case .array(let values):
            out += "["
            for (index, value) in values.enumerated() {
                if index > 0 { out += "," }
                value.write(to: &out)
            }
            out += "]"
        case .object(let values):
            out += "{"
            for (index, key) in values.keys.sorted().enumerated() {
                if index > 0 { out += "," }
                JSON.writeString(key, to: &out)
                out += ":"
                values[key]?.write(to: &out)
            }
            out += "}"
        }
    }

    private static func writeString(_ value: String, to out: inout String) {
        out += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16, uppercase: true)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}

// MARK: - Decodable

extension JSON: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSON].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSON].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }
}

// MARK: - Literals

extension JSON: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSON: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) { self = .int(value) }
}

extension JSON: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension JSON: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSON: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
}

extension JSON: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
