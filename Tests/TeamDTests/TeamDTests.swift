import XCTest
@testable import DomainKit

final class TeamDTests: XCTestCase {
    func testDomainKitIsLinked() {
        XCTAssertNotNil(DomainKitModule.self)
    }

    func testFixtureCompositionIsVisibleAndUsesItsInjectedDependencies() {
        let dependencies = CameraFlowComposition.fixture(
            cameraAuthorization: FixedCameraAuthorizationProvider(status: .notDetermined),
            clock: FixedClock(),
            sessionIdentifiers: FixedSessionIdentifiers(),
            imageStore: RecordingImageStore()
        )

        XCTAssertEqual(dependencies.mode, .fixture)
        XCTAssertEqual(dependencies.cameraAuthorization.authorizationStatus(), .notDetermined)
        XCTAssertEqual(dependencies.clock.now(), Date(timeIntervalSince1970: 1))
        XCTAssertEqual(dependencies.sessionIdentifiers.makeSessionIdentifier(), UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
    }

    func testLiveCompositionRetainsLiveModeWhenAuthorizationIsDenied() {
        let dependencies = CameraFlowComposition.live(
            cameraAuthorization: FixedCameraAuthorizationProvider(status: .denied),
            clock: FixedClock(),
            sessionIdentifiers: FixedSessionIdentifiers(),
            imageStore: RecordingImageStore()
        )

        XCTAssertEqual(dependencies.mode, .live)
        XCTAssertEqual(dependencies.cameraAuthorization.authorizationStatus(), .denied)
    }

    func testPermissionMatrixOnlyRoutesIntoTheCameraFlow() {
        XCTAssertEqual(CameraFlowEntry.route(for: .notDetermined), .requestPermission)
        XCTAssertEqual(CameraFlowEntry.route(for: .authorized), .captureFront)
        XCTAssertEqual(CameraFlowEntry.route(for: .denied), .permissionDenied)
        XCTAssertEqual(CameraFlowEntry.route(for: .restricted), .permissionRestricted)
    }
}

private struct FixedCameraAuthorizationProvider: CameraAuthorizationProviding {
    let status: CameraAuthorizationStatus
    func authorizationStatus() -> CameraAuthorizationStatus { status }
    func requestAuthorization() async -> CameraAuthorizationStatus { status }
}

private struct FixedClock: SessionClock {
    func now() -> Date { Date(timeIntervalSince1970: 1) }
}

private struct FixedSessionIdentifiers: SessionIdentifierProviding {
    func makeSessionIdentifier() -> UUID { UUID(uuidString: "00000000-0000-0000-0000-000000000001")! }
}

private final class RecordingImageStore: SessionImageStoring, @unchecked Sendable {
    func discardSessionContents() {}
}
