#if os(iOS)
import CaptureKit
import DomainKit
import Foundation
import XCTest

@available(iOS 18.0, *)
@MainActor
final class CaptureRecoveryViewModelTests: XCTestCase {
    func testLifecycleBridgeSuspendsOnBackgroundAndRecoversOnlyAfterMatchingForeground() async throws {
        let session = ViewModelRecoverySession(
            id: try SessionID("session-a"),
            accepted: [.front, .back]
        )
        let camera = RecordingRecoveryCamera()
        let controller = CaptureRecoveryController(
            authorization: ViewModelAuthorization(.authorized),
            session: session,
            submitter: ViewModelSubmitter(),
            camera: camera
        )
        let model = CaptureRecoveryViewModel(controller: controller, shot: .tag)
        await model.activate()

        await model.receive(.enteredForeground)
        var calls = await camera.calls
        XCTAssertEqual(calls, [])

        await model.receive(.enteredBackground)
        XCTAssertEqual(model.presentation.state, .inBackground)
        XCTAssertEqual(model.preservedAcceptedSlots, [.front, .back])
        calls = await camera.calls
        XCTAssertEqual(calls, [.suspend])

        await model.receive(.enteredForeground)
        XCTAssertEqual(model.presentation.state, .cameraReady)
        XCTAssertEqual(model.preservedAcceptedSlots, [.front, .back])
        calls = await camera.calls
        XCTAssertEqual(calls, [.suspend, .recover])
    }

    func testRuntimeErrorKeepsAcceptedProgressAndOffersRetryAndCurrentSlotImport() async throws {
        let session = ViewModelRecoverySession(
            id: try SessionID("session-a"),
            accepted: [.front]
        )
        let controller = CaptureRecoveryController(
            authorization: ViewModelAuthorization(.authorized),
            session: session,
            submitter: ViewModelSubmitter(),
            camera: RecordingRecoveryCamera()
        )
        let model = CaptureRecoveryViewModel(controller: controller, shot: .back)
        await model.activate()
        await model.receive(.runtimeError)

        XCTAssertEqual(model.presentation.state, .runtimeError)
        XCTAssertEqual(model.presentation.actions, [.retryCamera, .selectPhoto(.back)])
        XCTAssertEqual(model.preservedAcceptedSlots, [.front])
    }
}

private struct ViewModelAuthorization: CaptureAuthorizing {
    let value: CaptureAuthorization
    init(_ value: CaptureAuthorization) { self.value = value }
    func status() async -> CaptureAuthorization { value }
    func requestAccess() async -> CaptureAuthorization { value }
}

private actor ViewModelRecoverySession: CaptureRecoverySessionPreserving {
    let id: SessionID?
    let accepted: Set<Shot>
    init(id: SessionID?, accepted: Set<Shot>) {
        self.id = id
        self.accepted = accepted
    }
    func activeSessionID() async -> SessionID? { id }
    func acceptedSlots() async -> Set<Shot> { accepted }
}

private actor ViewModelSubmitter: CaptureSlotSubmitting {
    func submit(
        _ photo: CapturedPhoto,
        for shot: Shot,
        route: CaptureSlotProcessingRoute,
        sessionID: SessionID
    ) async throws {}
}

private actor RecordingRecoveryCamera: CaptureCameraRecovering {
    enum Call: Equatable, Sendable { case suspend, recover }
    private(set) var calls: [Call] = []
    func suspendCamera() async { calls.append(.suspend) }
    func recoverCamera() async throws { calls.append(.recover) }
}
#endif
