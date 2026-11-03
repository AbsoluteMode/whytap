import Foundation

/// JSON at the application-control boundary. No raw preferences or credentials.
public enum AppControlValue: Codable, Equatable {
    case string(String), bool(Bool), int(Int), object([String: AppControlValue]), array([AppControlValue]), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: Self].self) { self = .object(v) }
        else { self = .array(try c.decode([Self].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var object: [String: Self]? { if case .object(let v) = self { return v }; return nil }
    public var int: Int? { if case .int(let v) = self { return v }; return nil }
    public var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
    public var array: [Self]? { if case .array(let v) = self { return v }; return nil }
}

public struct AppControlRequest: Codable, Equatable {
    public let operation: String
    public let arguments: [String: AppControlValue]
    public init(_ operation: String, arguments: [String: AppControlValue] = [:]) {
        self.operation = operation
        self.arguments = arguments
    }
}

public struct AppControlResponse: Codable, Equatable {
    public let ok: Bool
    public let data: AppControlValue

    public static func success(_ data: AppControlValue) -> Self { Self(ok: true, data: data) }
    public static func failure(_ code: String, _ message: String) -> Self {
        Self(ok: false, data: .object(["code": .string(code), "message": .string(message)]))
    }
}
