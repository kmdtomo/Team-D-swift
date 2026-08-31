import DomainKit

public enum CaptureContextContract {
    public static let version1Topic = "teamd.capture.context.v1"
    public static let version1Type = "capture_context"
}

/// App-owned workflow context sent to the Agent over reliable LiveKit data.
/// The closed payload deliberately has no image, prose, confidence, acceptance,
/// or navigation-command field.
public struct CaptureContextV1: Codable, Equatable, Sendable {
    public let type: String
    public let sessionId: String
    public let revision: UInt64
    public let shot: Shot
    public let acceptedShots: [Shot]
    public let lastGuidanceSequence: Int64?

    public init(
        sessionId: String,
        revision: UInt64,
        shot: Shot,
        acceptedShots: [Shot],
        lastGuidanceSequence: Int64?
    ) throws {
        try requireNonblank(sessionId, "sessionId")
        guard revision >= 1 else {
            throw WireValidationError.invalidValue("revision")
        }
        if let lastGuidanceSequence, lastGuidanceSequence < 1 {
            throw WireValidationError.invalidValue("lastGuidanceSequence")
        }
        guard acceptedShots == Self.canonicalAcceptedShots(from: Set(acceptedShots)),
              acceptedShots.count == Set(acceptedShots).count
        else {
            throw WireValidationError.invalidValue("acceptedShots")
        }

        type = CaptureContextContract.version1Type
        self.sessionId = sessionId
        self.revision = revision
        self.shot = shot
        self.acceptedShots = acceptedShots
        self.lastGuidanceSequence = lastGuidanceSequence
    }

    public static func canonicalAcceptedShots(from shots: Set<Shot>) -> [Shot] {
        Shot.allCases.filter(shots.contains)
    }

    public init(from decoder: Decoder) throws {
        try requireOnlyKeys(
            decoder,
            allowed: [
                "type", "sessionId", "revision", "shot", "acceptedShots",
                "lastGuidanceSequence",
            ]
        )
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        let type = try container.decode(String.self, forKey: key("type"))
        guard type == CaptureContextContract.version1Type,
              container.contains(key("lastGuidanceSequence"))
        else {
            throw WireValidationError.invalidValue("capture context type or fields")
        }
        let acceptedRawValues = try container.decode([String].self, forKey: key("acceptedShots"))
        let acceptedShots = try acceptedRawValues.map { rawValue in
            guard let shot = Shot(rawValue: rawValue) else {
                throw WireValidationError.invalidValue("acceptedShots")
            }
            return shot
        }
        try self.init(
            sessionId: container.decode(String.self, forKey: key("sessionId")),
            revision: container.decode(UInt64.self, forKey: key("revision")),
            shot: decodeEnum(container, key: key("shot"), Shot.self),
            acceptedShots: acceptedShots,
            lastGuidanceSequence: container.decodeIfPresent(
                Int64.self,
                forKey: key("lastGuidanceSequence")
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(type, forKey: key("type"))
        try container.encode(sessionId, forKey: key("sessionId"))
        try container.encode(revision, forKey: key("revision"))
        try container.encode(shot.rawValue, forKey: key("shot"))
        try container.encode(acceptedShots.map(\.rawValue), forKey: key("acceptedShots"))
        try container.encode(lastGuidanceSequence, forKey: key("lastGuidanceSequence"))
    }
}
