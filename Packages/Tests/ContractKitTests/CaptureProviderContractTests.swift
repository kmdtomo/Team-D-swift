import Testing
@testable import ContractKit
@testable import DomainKit

@Test func assessmentRejectsEveryMissingRequiredKeyAndUnknownTopKey() throws {
    let object = try jsonObject(golden("shot-assessment"))
    for key in ["shotType", "quality", "issues", "missingShots", "nextAction"] { expectRejected(ShotAssessment.self, removing(key, from: object)) }
    expectRejected(ShotAssessment.self, setting("extra", to: 1, in: object))
}

@Test func assessmentCoversEveryEnumFamily() throws {
    let base = try jsonObject(golden("shot-assessment"))
    for value in ShotType.allCases { _ = try decode(ShotAssessment.self, setting("shotType", to: value.rawValue, in: base)) }
    for value in ShotQuality.allCases { _ = try decode(ShotAssessment.self, setting("quality", to: value.rawValue, in: base)) }
    for value in ShotNextAction.allCases { _ = try decode(ShotAssessment.self, setting("nextAction", to: value.rawValue, in: base)) }
    for value in ShotIssueCode.allCases { _ = try decode(ShotAssessment.self, setting("issues", to: [value.rawValue], in: base)) }
    for value in AssessableShot.allCases { _ = try decode(ShotAssessment.self, setting("missingShots", to: [value.rawValue], in: base)) }
    expectRejected(ShotAssessment.self, setting("issues", to: ["UNKNOWN"], in: base))
    expectRejected(ShotAssessment.self, setting("missingShots", to: ["measurement"], in: base))
}

@Test func providerRejectsEveryMissingRequiredKeyUnknownTopKeyAndBadTypes() throws {
    let object = try jsonObject(golden("provider-error"))
    for key in ["provider", "code", "message", "retryable"] { expectRejected(ProviderError.self, removing(key, from: object)) }
    expectRejected(ProviderError.self, setting("extra", to: true, in: object))
    expectRejected(ProviderError.self, setting("provider", to: "unknown", in: object))
    expectRejected(ProviderError.self, setting("retryable", to: "true", in: object))
    expectRejected(ProviderError.self, setting("message", to: " ", in: object))
}

@Test func everyProviderAndErrorCodeDecodesAndDirectInitMatches() throws {
    let base = try jsonObject(golden("provider-error"))
    for provider in Provider.allCases { _ = try decode(ProviderError.self, setting("provider", to: provider.rawValue, in: base)) }
    for code in ProviderErrorCode.allCases { _ = try decode(ProviderError.self, setting("code", to: code.rawValue, in: base)) }
    #expect(throws: Error.self) { try ProviderError(provider: .visionGuidance, code: .unknown, message: "", retryable: false) }
}
