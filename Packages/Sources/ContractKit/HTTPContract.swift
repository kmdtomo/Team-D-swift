import Foundation

public struct HealthResponse: Codable, Equatable, Sendable {
    public let status: String
    public init(status: String) throws {
        guard status == "ok" else { throw WireValidationError.invalidValue("status") }
        self.status = status
    }
    public init(from decoder: Decoder) throws {
        try requireOnlyKeys(decoder, allowed: ["status"])
        try self.init(status: decoder.container(keyedBy: AnyCodingKey.self).decode(String.self, forKey: key("status")))
    }
}

/// Source HTTP failures are deliberately not reclassified as ProviderError.
public enum JSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null } else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) } else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) } else { self = .array(try c.decode([JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); switch self { case .string(let v): try c.encode(v); case .number(let v): try c.encode(v); case .bool(let v): try c.encode(v); case .object(let v): try c.encode(v); case .array(let v): try c.encode(v); case .null: try c.encodeNil() } }
}
public struct FastAPIValidationIssue: Codable, Equatable, Sendable {
    public let type: String; public let loc: [JSONValue]; public let msg: String; public let input: JSONValue?; public let ctx: JSONValue?
    public init(from decoder: Decoder) throws { try requireOnlyKeys(decoder, allowed: ["type","loc","msg","input","ctx"]); let c = try decoder.container(keyedBy: AnyCodingKey.self); type = try c.decode(String.self, forKey:key("type")); loc = try c.decode([JSONValue].self, forKey:key("loc")); msg = try c.decode(String.self, forKey:key("msg")); input = try c.decodeIfPresent(JSONValue.self,forKey:key("input")); ctx = try c.decodeIfPresent(JSONValue.self,forKey:key("ctx")); try requireNonblank(type,"type"); try requireNonblank(msg,"msg"); guard !loc.isEmpty, loc.allSatisfy({ if case .string = $0 { return true }; if case .number(let n) = $0 { return n.rounded() == n }; return false }), ctx.map({ if case .object = $0 { return true }; return false }) ?? true else { throw WireValidationError.invalidValue("loc") } }
    public func encode(to encoder: Encoder) throws { var c = encoder.container(keyedBy: AnyCodingKey.self); try c.encode(type,forKey:key("type")); try c.encode(loc,forKey:key("loc")); try c.encode(msg,forKey:key("msg")); try c.encodeIfPresent(input,forKey:key("input")); try c.encodeIfPresent(ctx,forKey:key("ctx")) }
}
public enum HTTPDetailError: Codable, Equatable, Sendable {
    case message(String), validation([FastAPIValidationIssue])
    public init(from decoder: Decoder) throws {
        try requireOnlyKeys(decoder, allowed: ["detail"]); let c = try decoder.container(keyedBy: AnyCodingKey.self)
        if let value = try? c.decode(String.self, forKey:key("detail")) { try requireNonblank(value,"detail"); self = .message(value) }
        else { let issues = try c.decode([FastAPIValidationIssue].self, forKey:key("detail")); guard !issues.isEmpty else { throw WireValidationError.invalidValue("detail") }; self = .validation(issues) }
    }
    public func encode(to encoder: Encoder) throws { var c = encoder.container(keyedBy: AnyCodingKey.self); switch self { case .message(let value): try c.encode(value,forKey:key("detail")); case .validation(let value): try c.encode(value,forKey:key("detail")) } }
}

public struct BackgroundStyleRequest: Codable, Equatable, Sendable {
    public let styleId: String
    public init(styleId: String) throws { try requireNonblank(styleId, "styleId"); guard styleId.count <= 128 else { throw WireValidationError.invalidValue("styleId") }; self.styleId = styleId }
    public init(from decoder: Decoder) throws {
        try requireOnlyKeys(decoder, allowed: ["styleId"])
        try self.init(styleId: decoder.container(keyedBy: AnyCodingKey.self).decode(String.self, forKey: key("styleId")))
    }
}
