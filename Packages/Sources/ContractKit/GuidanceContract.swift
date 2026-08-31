import DomainKit

public struct GuidanceEvent: Codable, Equatable, Sendable {
    public let sessionId: String
    public let sequence: Int64
    public let shot: Shot
    public let code: GuidanceCode
    public let message: String
    public let confidence: Double
    public let observedAt: Int64
    public let expiresAt: Int64

    public init(sessionId: String, sequence: Int64, shot: Shot, code: GuidanceCode, message: String, confidence: Double, observedAt: Int64, expiresAt: Int64) throws {
        try requireNonblank(sessionId, "sessionId")
        try requireNonblank(message, "message")
        guard sequence >= 1, observedAt >= 0, expiresAt > observedAt else {
            throw WireValidationError.invalidValue("guidance timing")
        }
        try requireUnit(confidence, "confidence")
        self.sessionId = sessionId
        self.sequence = sequence
        self.shot = shot
        self.code = code
        self.message = message
        self.confidence = confidence
        self.observedAt = observedAt
        self.expiresAt = expiresAt
    }

    public func isExpired(nowEpochMilliseconds: Int64) throws -> Bool {
        guard nowEpochMilliseconds >= 0 else {
            throw WireValidationError.invalidValue("nowEpochMilliseconds")
        }
        return nowEpochMilliseconds >= expiresAt
    }

    public init(from decoder: Decoder) throws {
        try requireOnlyKeys(decoder, allowed: ["sessionId", "sequence", "shot", "code", "message", "confidence", "observedAt", "expiresAt"])
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        try self.init(
            sessionId: container.decode(String.self, forKey: key("sessionId")),
            sequence: container.decode(Int64.self, forKey: key("sequence")),
            shot: decodeEnum(container, key: key("shot"), Shot.self),
            code: decodeEnum(container, key: key("code"), GuidanceCode.self),
            message: container.decode(String.self, forKey: key("message")),
            confidence: container.decode(Double.self, forKey: key("confidence")),
            observedAt: container.decode(Int64.self, forKey: key("observedAt")),
            expiresAt: container.decode(Int64.self, forKey: key("expiresAt"))
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(sessionId, forKey: key("sessionId"))
        try container.encode(sequence, forKey: key("sequence"))
        try container.encode(shot.rawValue, forKey: key("shot"))
        try container.encode(code.rawValue, forKey: key("code"))
        try container.encode(message, forKey: key("message"))
        try container.encode(confidence, forKey: key("confidence"))
        try container.encode(observedAt, forKey: key("observedAt"))
        try container.encode(expiresAt, forKey: key("expiresAt"))
    }
}
