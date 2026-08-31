import Testing
@testable import ContractKit
@testable import DomainKit

@Test func guidanceRejectsEveryMissingRequiredKeyAndUnknownTopKey() throws {
    let object = try jsonObject(golden("guidance-event"))
    for key in ["sessionId", "sequence", "shot", "code", "message", "confidence", "observedAt", "expiresAt"] {
        expectRejected(GuidanceEvent.self, removing(key, from: object))
    }
    expectRejected(GuidanceEvent.self, setting("extra", to: true, in: object))
}

@Test(arguments: GuidanceCode.allCases) func everyGuidanceCodeDecodes(_ code: GuidanceCode) throws {
    let object = setting("code", to: code.rawValue, in: try jsonObject(golden("guidance-event")))
    _ = try decode(GuidanceEvent.self, object)
}

@Test(arguments: Shot.allCases) func everyGuidanceShotDecodes(_ shot: Shot) throws {
    let object = setting("shot", to: shot.rawValue, in: try jsonObject(golden("guidance-event")))
    _ = try decode(GuidanceEvent.self, object)
}

@Test(arguments: [0.0, 1.0]) func guidanceAcceptsConfidenceBoundaries(_ confidence: Double) throws {
    let object = setting("confidence", to: confidence, in: try jsonObject(golden("guidance-event")))
    _ = try decode(GuidanceEvent.self, object)
}

@Test(arguments: [-0.01, 1.01]) func guidanceRejectsConfidenceOutsideUnitRange(_ confidence: Double) throws {
    let object = setting("confidence", to: confidence, in: try jsonObject(golden("guidance-event")))
    expectRejected(GuidanceEvent.self, object)
}

@Test func guidanceTimingAndDirectFiniteParity() throws {
    let base = try jsonObject(golden("guidance-event"))
    expectRejected(GuidanceEvent.self, setting("sequence", to: 0, in: base))
    expectRejected(GuidanceEvent.self, setting("observedAt", to: -1, in: base))
    expectRejected(GuidanceEvent.self, setting("expiresAt", to: 0, in: base))
    for invalid in [Double.nan, Double.infinity, -Double.infinity] {
        #expect(throws: Error.self) { try GuidanceEvent(sessionId: "s", sequence: 1, shot: .front, code: .ready, message: "m", confidence: invalid, observedAt: 0, expiresAt: 1) }
    }
    let event = try GuidanceEvent(sessionId: "s", sequence: 1, shot: .front, code: .ready, message: "m", confidence: 0, observedAt: 0, expiresAt: 1)
    #expect(!(try event.isExpired(nowEpochMilliseconds: 0)))
    #expect(try event.isExpired(nowEpochMilliseconds: 1))
}
