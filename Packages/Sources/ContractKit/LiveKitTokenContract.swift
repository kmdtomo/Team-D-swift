import Foundation

public struct LiveKitTokenRequest: Codable, Equatable, Sendable {
    public let sessionId: String

    public init(sessionId: String) throws {
        guard sessionId.range(of: "^[A-Za-z0-9][A-Za-z0-9._:-]{0,95}$", options: .regularExpression) != nil else {
            throw WireValidationError.invalidValue("sessionId")
        }
        self.sessionId = sessionId
    }

    public init(from decoder: Decoder) throws {
        try requireOnlyKeys(decoder, allowed: ["sessionId"])
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        try self.init(sessionId: container.decode(String.self, forKey: key("sessionId")))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(sessionId, forKey: key("sessionId"))
    }
}

public struct LiveKitTokenResponse: Codable, Equatable, Sendable {
    public let token: String
    public let participantIdentity: String
    public let roomName: String
    public let expiresAt: Int64
    public let livekitUrl: String

    public init(token: String, participantIdentity: String, roomName: String, expiresAt: Int64, livekitUrl: String) throws {
        try requireNonblank(token, "token")
        try requireNonblank(participantIdentity, "participantIdentity")
        try requireNonblank(roomName, "roomName")
        guard expiresAt > 0, let url = URL(string: livekitUrl), ["https", "wss"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            throw WireValidationError.invalidValue("token response")
        }
        self.token = token
        self.participantIdentity = participantIdentity
        self.roomName = roomName
        self.expiresAt = expiresAt
        self.livekitUrl = livekitUrl
    }

    public func isExpired(nowUnixSeconds: Int64) throws -> Bool {
        guard nowUnixSeconds >= 0 else { throw WireValidationError.invalidValue("nowUnixSeconds") }
        return nowUnixSeconds >= expiresAt
    }

    public init(from decoder: Decoder) throws {
        try requireOnlyKeys(decoder, allowed: ["token", "participantIdentity", "roomName", "expiresAt", "livekitUrl"])
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        try self.init(token: container.decode(String.self, forKey: key("token")), participantIdentity: container.decode(String.self, forKey: key("participantIdentity")), roomName: container.decode(String.self, forKey: key("roomName")), expiresAt: container.decode(Int64.self, forKey: key("expiresAt")), livekitUrl: container.decode(String.self, forKey: key("livekitUrl")))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(token, forKey: key("token"))
        try container.encode(participantIdentity, forKey: key("participantIdentity"))
        try container.encode(roomName, forKey: key("roomName"))
        try container.encode(expiresAt, forKey: key("expiresAt"))
        try container.encode(livekitUrl, forKey: key("livekitUrl"))
    }
}
