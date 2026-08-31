import Testing
@testable import CaptureKit

@Test func captureKitTestTargetBuilds() {
    #expect(String(reflecting: CaptureKitModule.self).contains("CaptureKitModule"))
}
