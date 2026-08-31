import Testing
@testable import ContractKit

@Test func tokenRequestRejectsMissingUnknownAndInvalidSessions() throws {
    let object = try jsonObject(golden("livekit-token-request"))
    expectRejected(LiveKitTokenRequest.self, removing("sessionId", from: object))
    expectRejected(LiveKitTokenRequest.self, setting("extra", to: true, in: object))
    for invalid in ["", "-bad", " a", String(repeating: "a", count: 97), "a/"] {
        #expect(throws: Error.self) { try LiveKitTokenRequest(sessionId: invalid) }
    }
    _ = try LiveKitTokenRequest(sessionId: String(repeating: "a", count: 96))
}

@Test func tokenResponseRejectsEveryMissingFieldUnknownAndInvalidValues() throws {
    let object = try jsonObject(golden("livekit-token-response"))
    for key in ["token", "participantIdentity", "roomName", "expiresAt", "livekitUrl"] { expectRejected(LiveKitTokenResponse.self, removing(key, from: object)) }
    expectRejected(LiveKitTokenResponse.self, setting("extra", to: true, in: object))
    expectRejected(LiveKitTokenResponse.self, setting("token", to: " ", in: object))
    expectRejected(LiveKitTokenResponse.self, setting("expiresAt", to: 0, in: object))
    expectRejected(LiveKitTokenResponse.self, setting("livekitUrl", to: "http://example.invalid", in: object))
}

@Test func tokenResponseExpiryBoundaryAndDirectInitParity() throws {
    let response = try LiveKitTokenResponse(token: "token", participantIdentity: "identity", roomName: "room", expiresAt: 90, livekitUrl: "wss://example.invalid")
    #expect(!(try response.isExpired(nowUnixSeconds: 89)))
    #expect(try response.isExpired(nowUnixSeconds: 90))
    #expect(throws: Error.self) { try response.isExpired(nowUnixSeconds: -1) }
    #expect(throws: Error.self) { try LiveKitTokenResponse(token: "t", participantIdentity: "p", roomName: "r", expiresAt: 1, livekitUrl: "ftp://example.invalid") }
}
