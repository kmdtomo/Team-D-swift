import DomainKit
import Foundation
@testable import ContractKit
import Testing

@Test func captureContextEncodesOnlyTheFrozenReliableFields() throws {
    let context = try CaptureContextV1(
        sessionId: "session-123",
        revision: 7,
        shot: .measurement,
        acceptedShots: [.front, .back, .tag],
        lastGuidanceSequence: 42
    )

    let encoded = try JSONEncoder().encode(context)
    let decodedObject = try JSONSerialization.jsonObject(with: encoded)
    let object = try #require(decodedObject as? [String: Any])

    #expect(Set(object.keys) == [
        "type", "sessionId", "revision", "shot", "acceptedShots",
        "lastGuidanceSequence",
    ])
    #expect(object["type"] as? String == "capture_context")
    #expect(object["sessionId"] as? String == "session-123")
    #expect((object["revision"] as? NSNumber)?.uint64Value == 7)
    #expect(object["shot"] as? String == "measurement")
    #expect(object["acceptedShots"] as? [String] == ["front", "back", "tag"])
    #expect((object["lastGuidanceSequence"] as? NSNumber)?.int64Value == 42)
    #expect(CaptureContextContract.version1Topic == "teamd.capture.context.v1")
}

@Test func captureContextRequiresCanonicalUniqueAcceptedShotOrdering() throws {
    #expect(
        CaptureContextV1.canonicalAcceptedShots(from: [.measurement, .front, .tag]) ==
            [.front, .tag, .measurement]
    )

    #expect(throws: Error.self) {
        try CaptureContextV1(
            sessionId: "session-123",
            revision: 1,
            shot: .tag,
            acceptedShots: [.tag, .front],
            lastGuidanceSequence: nil
        )
    }
    #expect(throws: Error.self) {
        try CaptureContextV1(
            sessionId: "session-123",
            revision: 1,
            shot: .tag,
            acceptedShots: [.front, .front],
            lastGuidanceSequence: nil
        )
    }
}

@Test func captureContextStrictDecoderRejectsUnknownOrForbiddenFields() throws {
    let base: [String: Any] = [
        "type": "capture_context",
        "sessionId": "session-123",
        "revision": 1,
        "shot": "front",
        "acceptedShots": [],
        "lastGuidanceSequence": NSNull(),
    ]

    _ = try decode(CaptureContextV1.self, base)
    for forbidden in ["image", "message", "confidence", "nextAction", "acceptSlot"] {
        expectRejected(CaptureContextV1.self, setting(forbidden, to: "forbidden", in: base))
    }
    for required in [
        "type", "sessionId", "revision", "shot", "acceptedShots",
        "lastGuidanceSequence",
    ] {
        expectRejected(CaptureContextV1.self, removing(required, from: base))
    }
}

@Test func captureContextRejectsInvalidTypeRevisionSequenceAndShots() {
    let base: [String: Any] = [
        "type": "capture_context",
        "sessionId": "session-123",
        "revision": 1,
        "shot": "back",
        "acceptedShots": ["front"],
        "lastGuidanceSequence": 9,
    ]

    expectRejected(CaptureContextV1.self, setting("type", to: "resync", in: base))
    expectRejected(CaptureContextV1.self, setting("sessionId", to: " ", in: base))
    expectRejected(CaptureContextV1.self, setting("revision", to: 0, in: base))
    expectRejected(CaptureContextV1.self, setting("shot", to: "unknown", in: base))
    expectRejected(CaptureContextV1.self, setting("acceptedShots", to: ["tag", "front"], in: base))
    expectRejected(CaptureContextV1.self, setting("acceptedShots", to: ["front", "front"], in: base))
    expectRejected(CaptureContextV1.self, setting("lastGuidanceSequence", to: 0, in: base))
}
