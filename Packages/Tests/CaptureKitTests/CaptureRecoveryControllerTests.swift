import CaptureKit
import DomainKit
import Foundation
import XCTest

@available(macOS 10.15, iOS 18.0, *)
final class CaptureRecoveryControllerTests: XCTestCase {
    func testPermissionMatrixAndJapaneseRecoveryActions() async {
        for (authorization, expected) in [
            (CaptureAuthorization.notDetermined, CaptureRecoveryState.permission(.notDetermined)),
            (.authorized, .cameraReady),
            (.denied, .permission(.denied)),
            (.restricted, .permission(.restricted)),
        ] {
            let controller = makeController(authorization: authorization)
            await controller.refreshPermission()
            let state = await controller.state
            XCTAssertEqual(state, expected)
        }

        let denied = makeController(authorization: .denied)
        await denied.refreshPermission()
        let deniedPresentation = await denied.presentation(for: .front)
        XCTAssertEqual(deniedPresentation.actions, [.openSettings, .selectPhoto(.front)])
        XCTAssertEqual(deniedPresentation.instruction, "カメラを使うには設定で許可するか、写真から選んでください")

        let restricted = makeController(authorization: .restricted)
        await restricted.refreshPermission()
        let restrictedPresentation = await restricted.presentation(for: .tag)
        XCTAssertEqual(restrictedPresentation.actions, [.selectPhoto(.tag)])

        let requesting = CaptureRecoveryCopy.presentation(for: .permission(.requesting), shot: .front)
        XCTAssertEqual(requesting.actions, [])

        let runtimeError = CaptureRecoveryCopy.presentation(for: .runtimeError, shot: .measurement)
        XCTAssertEqual(runtimeError.actions, [.retryCamera, .selectPhoto(.measurement)])
    }

    func testInterruptionRuntimeErrorAndForegroundRetainAcceptedSlots() async {
        let session = RecoverySession(sessionID: try! SessionID("session-a"), accepted: [.front, .back])
        let controller = CaptureRecoveryController(
            authorization: StaticAuthorization(.authorized),
            session: session,
            submitter: RecordingSubmitter(),
            camera: StaticCameraRecoverer()
        )
        await controller.refreshPermission()
        await controller.receive(.interrupted)
        let interruptedState = await controller.state
        let interruptedPresentation = await controller.presentation(for: .tag)
        let interruptedSlots = await controller.preservedAcceptedSlots()
        XCTAssertEqual(interruptedState, .interrupted)
        XCTAssertEqual(interruptedPresentation.actions, [.retryCamera, .selectPhoto(.tag)])
        XCTAssertEqual(interruptedSlots, [.front, .back])

        await controller.receive(.interruptionEnded)
        let resumingState = await controller.state
        XCTAssertEqual(resumingState, .resuming)
        await controller.cameraDidResume()
        let readyState = await controller.state
        XCTAssertEqual(readyState, .cameraReady)

        await controller.receive(.enteredBackground)
        await controller.receive(.enteredForeground)
        let foregroundState = await controller.state
        XCTAssertEqual(foregroundState, .resuming)
        await controller.receive(.runtimeError)
        let runtimeErrorState = await controller.state
        let runtimeErrorSlots = await controller.preservedAcceptedSlots()
        XCTAssertEqual(runtimeErrorState, .runtimeError)
        XCTAssertEqual(runtimeErrorSlots, [.front, .back])
    }

    func testImportForwardsOriginalBytesAndMetadataToSameSlotSubmitter() async throws {
        let sessionID = try SessionID("session-a")
        let session = RecoverySession(sessionID: sessionID, accepted: [.front])
        let submitter = RecordingSubmitter()
        let controller = CaptureRecoveryController(
            authorization: StaticAuthorization(.denied),
            session: session,
            submitter: submitter,
            camera: StaticCameraRecoverer()
        )
        let original = ImportedCapture(
            originalFileData: Data([1, 2, 3]),
            metadata: .init(contentType: "public.jpeg", orientation: 6, colorSpaceName: "RGB", pixelWidth: 640, pixelHeight: 480)
        )

        try await controller.importPhoto(ImmediateImporter(result: .success(original)), for: .back)
        let submissions = await submitter.submissions
        let state = await controller.state
        let slots = await controller.preservedAcceptedSlots()
        XCTAssertEqual(submissions, [
            .init(
                photo: original.capturedPhoto,
                shot: .back,
                route: .shotAssessment(.back),
                sessionID: sessionID
            ),
        ])
        XCTAssertEqual(state, .permission(.denied))
        XCTAssertEqual(slots, [.front])
    }

    func testImportCancellationAndFailureOfferRetryWithoutFixtureFallback() async {
        let session = RecoverySession(sessionID: try! SessionID("session-a"), accepted: [.front])
        let controller = CaptureRecoveryController(
            authorization: StaticAuthorization(.denied),
            session: session,
            submitter: RecordingSubmitter(),
            camera: StaticCameraRecoverer()
        )
        do {
            try await controller.importPhoto(ImmediateImporter(result: .failure(CancellationError())), for: .back)
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        let cancelledState = await controller.state
        let cancelledPresentation = await controller.presentation(for: .back)
        XCTAssertEqual(cancelledState, .importCancelled(.back))
        XCTAssertEqual(cancelledPresentation.actions, [.openSettings, .selectPhoto(.back)])

        do {
            try await controller.importPhoto(ImmediateImporter(result: .failure(CocoaError(.fileReadCorruptFile))), for: .back)
            XCTFail("expected import failure")
        } catch {}
        let failedState = await controller.state
        let failedPresentation = await controller.presentation(for: .back)
        let slots = await controller.preservedAcceptedSlots()
        XCTAssertEqual(failedState, .importFailed(.back))
        XCTAssertEqual(failedPresentation.actions, [.openSettings, .selectPhoto(.back)])
        XCTAssertEqual(slots, [.front])
    }

    func testStaleSessionImportCannotSubmitOrMutateReplacementSession() async throws {
        let session = RecoverySession(sessionID: try SessionID("session-a"), accepted: [.front])
        let submitter = RecordingSubmitter()
        let controller = CaptureRecoveryController(
            authorization: StaticAuthorization(.denied),
            session: session,
            submitter: submitter,
            camera: StaticCameraRecoverer()
        )
        let importer = GatedImporter()
        let task = Task { try await controller.importPhoto(importer, for: .back) }
        try await waitUntil { await importer.didStart }
        await session.replace(with: try SessionID("session-b"), accepted: [.front, .tag])
        await importer.release(.init(originalFileData: Data([9]), metadata: .init(orientation: 1)))
        do {
            try await task.value
            XCTFail("stale import must not submit")
        } catch {
            XCTAssertEqual(error as? CaptureRecoveryError, .staleSession)
        }
        let state = await controller.state
        let submissions = await submitter.submissions
        let slots = await controller.preservedAcceptedSlots()
        XCTAssertEqual(state, .staleSession)
        XCTAssertEqual(submissions, [])
        XCTAssertEqual(slots, [.front, .tag])
    }

    func testEverySelectedSlotUsesItsExistingPostCaptureRoute() async throws {
        let sessionID = try SessionID("session-a")
        let session = RecoverySession(sessionID: sessionID, accepted: [])
        let submitter = RecordingSubmitter()
        let controller = CaptureRecoveryController(
            authorization: StaticAuthorization(.restricted),
            session: session,
            submitter: submitter,
            camera: StaticCameraRecoverer()
        )

        for shot in Shot.allCases {
            try await controller.importPhoto(
                ImmediateImporter(result: .success(.init(originalFileData: Data([UInt8(shot.rawValue.count)]), metadata: .init()))),
                for: shot
            )
        }

        let routes = await submitter.submissions.map { ($0.shot, $0.route) }
        XCTAssertEqual(routes.map { $0.0 }, [.front, .back, .tag, .measurement])
        XCTAssertEqual(routes.map { $0.1 }, [
            .shotAssessment(.front),
            .shotAssessment(.back),
            .shotAssessment(.tag),
            .measurementValidation,
        ])
    }

    func testExplicitImportCancellationDiscardsLateSameSessionResult() async throws {
        let session = RecoverySession(sessionID: try SessionID("session-a"), accepted: [.front])
        let submitter = RecordingSubmitter()
        let controller = CaptureRecoveryController(
            authorization: StaticAuthorization(.denied),
            session: session,
            submitter: submitter,
            camera: StaticCameraRecoverer()
        )
        let importer = GatedImporter()
        let task = Task { try await controller.importPhoto(importer, for: .back) }
        try await waitUntil { await importer.didStart }

        await controller.cancelImport(for: .back)
        await importer.release(.init(originalFileData: Data([7]), metadata: .init()))

        do {
            try await task.value
            XCTFail("cancelled import must not submit")
        } catch {
            XCTAssertEqual(error as? CaptureRecoveryError, .staleImport)
        }
        let state = await controller.state
        let submissions = await submitter.submissions
        XCTAssertEqual(state, .importCancelled(.back))
        XCTAssertEqual(submissions, [])
    }

    func testNewSelectionSupersedesOlderSameSessionSelection() async throws {
        let sessionID = try SessionID("session-a")
        let session = RecoverySession(sessionID: sessionID, accepted: [.front])
        let submitter = RecordingSubmitter()
        let controller = CaptureRecoveryController(
            authorization: StaticAuthorization(.denied),
            session: session,
            submitter: submitter,
            camera: StaticCameraRecoverer()
        )
        let older = GatedImporter()
        let olderTask = Task { try await controller.importPhoto(older, for: .back) }
        try await waitUntil { await older.didStart }

        let newest = ImportedCapture(originalFileData: Data([2]), metadata: .init())
        try await controller.importPhoto(ImmediateImporter(result: .success(newest)), for: .back)
        await older.release(.init(originalFileData: Data([1]), metadata: .init()))

        do {
            try await olderTask.value
            XCTFail("older selection must be stale")
        } catch {
            XCTAssertEqual(error as? CaptureRecoveryError, .staleImport)
        }
        let submissions = await submitter.submissions
        XCTAssertEqual(submissions.count, 1)
        XCTAssertEqual(submissions.first?.photo, newest.capturedPhoto)
        XCTAssertEqual(submissions.first?.sessionID, sessionID)
    }

    func testRecoveryReconfiguresSingleOwnerAndMapsFailureToRetryableState() async throws {
        let session = RecoverySession(sessionID: try SessionID("session-a"), accepted: [.front, .back])
        let camera = SequencedCameraRecoverer(results: [.succeed, .fail(.camera)])
        let controller = CaptureRecoveryController(
            authorization: StaticAuthorization(.authorized),
            session: session,
            submitter: RecordingSubmitter(),
            camera: camera
        )

        await controller.receive(.interrupted)
        try await controller.recoverCamera()
        let readyState = await controller.state
        let firstCallCount = await camera.callCount
        XCTAssertEqual(readyState, .cameraReady)
        XCTAssertEqual(firstCallCount, 1)

        await controller.receive(.runtimeError)
        do {
            try await controller.recoverCamera()
            XCTFail("camera failure should remain visible")
        } catch {
            XCTAssertEqual(error as? RecoveryTestError, .camera)
        }
        let failureState = await controller.state
        let slots = await controller.preservedAcceptedSlots()
        let finalCallCount = await camera.callCount
        XCTAssertEqual(failureState, .runtimeError)
        XCTAssertEqual(slots, [.front, .back])
        XCTAssertEqual(finalCallCount, 2)
    }

    func testRecoveryCompletionFromReplacedSessionIsStale() async throws {
        let session = RecoverySession(sessionID: try SessionID("session-a"), accepted: [.front])
        let camera = GatedCameraRecoverer()
        let controller = CaptureRecoveryController(
            authorization: StaticAuthorization(.authorized),
            session: session,
            submitter: RecordingSubmitter(),
            camera: camera
        )
        await controller.receive(.enteredBackground)
        await controller.receive(.enteredForeground)
        let task = Task { try await controller.recoverCamera() }
        try await waitUntil { await camera.didStart }
        await session.replace(with: try SessionID("session-b"), accepted: [.front, .back])
        await camera.release()

        do {
            try await task.value
            XCTFail("old recovery must not mark the replacement ready")
        } catch {
            XCTAssertEqual(error as? CaptureRecoveryError, .staleSession)
        }
        let state = await controller.state
        XCTAssertEqual(state, .staleSession)
    }

    func testFailedSettingsReturnWithDeniedPermissionKeepsSettingsAndPhotoFallback() async throws {
        let controller = CaptureRecoveryController(
            authorization: StaticAuthorization(.denied),
            session: RecoverySession(sessionID: try SessionID("session-a"), accepted: [.front]),
            submitter: RecordingSubmitter(),
            camera: SequencedCameraRecoverer(results: [.fail(.camera)])
        )

        await controller.receive(.enteredBackground)
        await controller.receive(.enteredForeground)
        do {
            try await controller.recoverCamera()
            XCTFail("denied camera cannot resume")
        } catch {}

        let state = await controller.state
        let presentation = await controller.presentation(for: .back)
        XCTAssertEqual(state, .permission(.denied))
        XCTAssertEqual(presentation.actions, [.openSettings, .selectPhoto(.back)])
    }

    func testRecoveryActionLabelsAndIdentifiersAreStableForXCUITest() {
        XCTAssertEqual(CaptureRecoveryAction.requestCameraPermission.localizedLabel, "カメラを許可する")
        XCTAssertEqual(CaptureRecoveryAction.openSettings.accessibilityIdentifier, CaptureRecoveryAccessibilityID.openSettings)
        XCTAssertEqual(CaptureRecoveryAction.selectPhoto(.measurement).localizedLabel, "採寸を写真から選ぶ")
        XCTAssertEqual(CaptureRecoveryAction.retryCamera.accessibilityIdentifier, CaptureRecoveryAccessibilityID.retryCamera)
    }
}

@available(macOS 10.15, iOS 18.0, *)
private func makeController(authorization: CaptureAuthorization) -> CaptureRecoveryController {
    CaptureRecoveryController(
        authorization: StaticAuthorization(authorization),
        session: RecoverySession(sessionID: try! SessionID("session-a"), accepted: []),
        submitter: RecordingSubmitter(),
        camera: StaticCameraRecoverer()
    )
}

@available(macOS 10.15, iOS 18.0, *)
private struct StaticAuthorization: CaptureAuthorizing {
    let value: CaptureAuthorization
    init(_ value: CaptureAuthorization) { self.value = value }
    func status() async -> CaptureAuthorization { value }
    func requestAccess() async -> CaptureAuthorization { value }
}

@available(macOS 10.15, iOS 18.0, *)
private actor RecoverySession: CaptureRecoverySessionPreserving {
    private var id: SessionID?
    private var accepted: Set<Shot>
    init(sessionID: SessionID?, accepted: Set<Shot>) { id = sessionID; self.accepted = accepted }
    func activeSessionID() async -> SessionID? { id }
    func acceptedSlots() async -> Set<Shot> { accepted }
    func replace(with id: SessionID?, accepted: Set<Shot>) { self.id = id; self.accepted = accepted }
}

@available(macOS 10.15, iOS 18.0, *)
private actor RecordingSubmitter: CaptureSlotSubmitting {
    struct Submission: Equatable, Sendable {
        let photo: CapturedPhoto
        let shot: Shot
        let route: CaptureSlotProcessingRoute
        let sessionID: SessionID
    }
    private(set) var submissions: [Submission] = []
    func submit(
        _ photo: CapturedPhoto,
        for shot: Shot,
        route: CaptureSlotProcessingRoute,
        sessionID: SessionID
    ) async throws {
        submissions.append(.init(photo: photo, shot: shot, route: route, sessionID: sessionID))
    }
}

@available(macOS 10.15, iOS 18.0, *)
private struct StaticCameraRecoverer: CaptureCameraRecovering {
    func suspendCamera() async {}
    func recoverCamera() async throws {}
}

@available(macOS 10.15, iOS 18.0, *)
private actor SequencedCameraRecoverer: CaptureCameraRecovering {
    private var results: [RecoveryCameraResult]
    private(set) var callCount = 0
    init(results: [RecoveryCameraResult]) { self.results = results }
    func suspendCamera() async {}
    func recoverCamera() async throws {
        callCount += 1
        guard !results.isEmpty else { return }
        switch results.removeFirst() {
        case .succeed: return
        case .fail(let error): throw error
        }
    }
}

@available(macOS 10.15, iOS 18.0, *)
private actor GatedCameraRecoverer: CaptureCameraRecovering {
    private var continuation: CheckedContinuation<Void, Never>?
    private var started = false
    var didStart: Bool { started }
    func suspendCamera() async {}
    func recoverCamera() async throws {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@available(macOS 10.15, iOS 18.0, *)
private struct ImmediateImporter: CaptureImporting {
    let result: Result<ImportedCapture, Error>
    func loadOriginal() async throws -> ImportedCapture { try result.get() }
}

@available(macOS 10.15, iOS 18.0, *)
private actor GatedImporter: CaptureImporting {
    private var continuation: CheckedContinuation<ImportedCapture, Error>?
    private var started = false
    var didStart: Bool { started }
    func loadOriginal() async throws -> ImportedCapture {
        started = true
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func release(_ imported: ImportedCapture) { continuation?.resume(returning: imported); continuation = nil }
}

private enum RecoveryTestError: Error, Equatable, Sendable { case camera }
private enum RecoveryCameraResult: Sendable { case succeed, fail(RecoveryTestError) }

@available(macOS 10.15, iOS 18.0, *)
private enum RecoveryTestTimeout: Error { case elapsed }

@available(macOS 10.15, iOS 18.0, *)
private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async throws {
    for _ in 0..<100 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw RecoveryTestTimeout.elapsed
}
