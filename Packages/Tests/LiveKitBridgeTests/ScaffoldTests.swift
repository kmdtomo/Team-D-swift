import Testing
@testable import LiveKitBridge

@Test func liveKitBridgeTestTargetBuilds() {
    #expect(String(reflecting: LiveKitBridgeModule.self).contains("LiveKitBridgeModule"))
}
