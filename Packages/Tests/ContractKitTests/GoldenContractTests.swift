import Testing
@testable import ContractKit

@Test func allVersionedGoldensPreserveStructureAndValue() throws {
    try assertGoldenRoundTrip(GuidanceEvent.self, named: "guidance-event")
    try assertGoldenRoundTrip(ShotAssessment.self, named: "shot-assessment")
    try assertGoldenRoundTrip(ProviderError.self, named: "provider-error")
    try assertGoldenRoundTrip(MeasurementDraft.self, named: "measurement-draft-marker-null")
    try assertGoldenRoundTrip(MeasurementEndpoints.self, named: "measurement-endpoints")
    try assertGoldenRoundTrip(LiveKitTokenRequest.self, named: "livekit-token-request")
    try assertGoldenRoundTrip(LiveKitTokenResponse.self, named: "livekit-token-response")
}
