import Testing
@testable import MeasurementKit

@Test func measurementKitTestTargetBuilds() {
    #expect(String(reflecting: MeasurementKitModule.self).contains("MeasurementKitModule"))
}
