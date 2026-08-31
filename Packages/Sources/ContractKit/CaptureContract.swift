import DomainKit

public struct ShotAssessment: Codable, Equatable, Sendable {
    public let shotType: ShotType
    public let quality: ShotQuality
    public let issues: [ShotIssueCode]
    public let missingShots: [AssessableShot]
    public let nextAction: ShotNextAction

    public init(shotType: ShotType, quality: ShotQuality, issues: [ShotIssueCode], missingShots: [AssessableShot], nextAction: ShotNextAction) {
        self.shotType = shotType
        self.quality = quality
        self.issues = issues
        self.missingShots = missingShots
        self.nextAction = nextAction
    }

    public init(from decoder: Decoder) throws {
        try requireOnlyKeys(decoder, allowed: ["shotType", "quality", "issues", "missingShots", "nextAction"])
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        try self.init(
            shotType: decodeEnum(container, key: key("shotType"), ShotType.self),
            quality: decodeEnum(container, key: key("quality"), ShotQuality.self),
            issues: try container.decode([String].self, forKey: key("issues")).map { rawValue in
                guard let issue = ShotIssueCode(rawValue: rawValue) else { throw WireValidationError.invalidValue("issues") }
                return issue
            },
            missingShots: try container.decode([String].self, forKey: key("missingShots")).map { rawValue in
                guard let shot = AssessableShot(rawValue: rawValue) else { throw WireValidationError.invalidValue("missingShots") }
                return shot
            },
            nextAction: decodeEnum(container, key: key("nextAction"), ShotNextAction.self)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(shotType.rawValue, forKey: key("shotType"))
        try container.encode(quality.rawValue, forKey: key("quality"))
        try container.encode(issues.map(\.rawValue), forKey: key("issues"))
        try container.encode(missingShots.map(\.rawValue), forKey: key("missingShots"))
        try container.encode(nextAction.rawValue, forKey: key("nextAction"))
    }
}

public struct ProviderError: Codable, Equatable, Sendable {
    public let provider: Provider
    public let code: ProviderErrorCode
    public let message: String
    public let retryable: Bool

    public init(provider: Provider, code: ProviderErrorCode, message: String, retryable: Bool) throws {
        try requireNonblank(message, "message")
        self.provider = provider
        self.code = code
        self.message = message
        self.retryable = retryable
    }

    public init(from decoder: Decoder) throws {
        try requireOnlyKeys(decoder, allowed: ["provider", "code", "message", "retryable"])
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        try self.init(
            provider: decodeEnum(container, key: key("provider"), Provider.self),
            code: decodeEnum(container, key: key("code"), ProviderErrorCode.self),
            message: container.decode(String.self, forKey: key("message")),
            retryable: container.decode(Bool.self, forKey: key("retryable"))
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(provider.rawValue, forKey: key("provider"))
        try container.encode(code.rawValue, forKey: key("code"))
        try container.encode(message, forKey: key("message"))
        try container.encode(retryable, forKey: key("retryable"))
    }
}
