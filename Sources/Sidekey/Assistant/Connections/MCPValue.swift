import CryptoKit
import Foundation

/// A JSON value that can cross actors. MCP messages, tool schemas and tool
/// results travel as this type inside the connections module; the agent loop
/// converts to `[String: Any]` only at its own boundary.
enum MCPValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([MCPValue])
    case object([String: MCPValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: MCPValue].self) { self = .object(value) }
        else { self = .array(try container.decode([MCPValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            if value.rounded() == value, abs(value) < 1e15 { try container.encode(Int64(value)) }
            else { try container.encode(value) }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// From `JSONSerialization` output (or a model's tool arguments).
    init(any value: Any?) {
        switch value {
        case nil, is NSNull: self = .null
        case let number as NSNumber:
            // NSNumber booleans are CFBoolean; check the type, not the value.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { self = .bool(number.boolValue) }
            else { self = .number(number.doubleValue) }
        case let string as String: self = .string(string)
        case let array as [Any]: self = .array(array.map { MCPValue(any: $0) })
        case let object as [String: Any]: self = .object(object.mapValues { MCPValue(any: $0) })
        default: self = .null
        }
    }

    /// For `JSONSerialization` and the agent's `[String: Any]` world.
    var any: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value): return value.rounded() == value && abs(value) < 1e15 ? Int(value) as Any : value
        case .string(let value): return value
        case .array(let value): return value.map(\.any)
        case .object(let value): return value.mapValues(\.any)
        }
    }

    var string: String? { if case .string(let value) = self { return value }; return nil }
    var object: [String: MCPValue]? { if case .object(let value) = self { return value }; return nil }
    var array: [MCPValue]? { if case .array(let value) = self { return value }; return nil }
    var bool: Bool? { if case .bool(let value) = self { return value }; return nil }
    var int: Int? { if case .number(let value) = self, value.rounded() == value { return Int(value) }; return nil }
    subscript(key: String) -> MCPValue? { object?[key] }

    /// Byte-stable JSON (sorted keys), for hashing and compact display.
    var canonicalJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    static func decode(_ data: Data) throws -> MCPValue { try JSONDecoder().decode(MCPValue.self, from: data) }
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

enum MCPHash {
    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
