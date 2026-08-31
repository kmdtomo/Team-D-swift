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
        XCTAssertEqual(deniedPresentation.action, .openSettings)
        XCTAssertEqual(deniedPresentation.instruction, "カメラを使うには設定で許可するか、写真から選んでください")

        let restricted = makeController(authorization: .restricted)
        await restricted.refreshPermission()
        let restrictedPresentation = await restricted.presentation(for: .tag)
        XCTAssertEqual(restrictedPresentation.action, .selectPhoto(.tag))
    }

    func testInterruptionRuntimeErrorAndForegroundRetainAcceptedSlots() async {
        let session = RecoverySession(sessionID: try! SessionID("session-a"), accepted: [.front, .back])
        let controller = CaptureRecoveryController(
            authorization: StaticAuthorization(.authorized),
            session: session,
            submitter: RecordingSubmitter()
        )
        await controller.refreshPermission()
        await controller.receive(.interrupted)
        let interruptedState = await controller.state
        let interruptedPresentation = await controller.presentation(for: .tag)
        let interruptedSlots = await controller.preservedAcceptedSlots()
        XCTAssertEqual(interruptedState, .interrupted)
        XCTAssertEqual(interruptedPresentation.action, .retryCamera)
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
            authorization: StaticAuthorization(.denied), session: session, submitter: submitter
        )
        let original = ImportedCapture(
            originalFileData: Data([1, 2, 3]),
            metadata: .init(contentType: "public.jpeg", orientation: 6, colorSpaceName: "RGB", pixelWidth: 640, pixelHeight: 480)
        )

        try await controller.importPhoto(ImmediateImporter(result: .success(original)), for: .back)
        let submissions = await submitter.submissions
        let state = await controller.state
        let slots = await controller.preservedAcceptedSlots()
        XCTAssertEqual(submissions, [.init(photo: original.capturedPhoto, shot: .back, sessionID: sessionID)])
        XCTAssertEqual(state, .cameraReady)
        XCTAssertEqual(slots, [.front])
    }

    func testImportCancellationAndFailureOfferRetryWithoutFixtureFallback() async {
        let session = RecoverySession(sessionID: try! SessionID("session-a"), accepted: [.front])
        let controller = CaptureRecoveryController(
            authorization: StaticAuthorization(.denied), session: session, submitter: RecordingSubmitter()
        )
        do {
            try await controller.importPhoto(ImmediateImporter(result: .failure(CancellationError())), for: .back)
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        let cancelledState = await controller.state
        let cancelledPresentation = await controller.presentation(for: .back)
        XCTAssertEqual(cancelledState, .importCancelled(.back))
        XCTAssertEqual(cancelledPresentation.action, .selectPhoto(.back))

        do {
            try await controller.importPhoto(ImmediateImporter(result: .failure(CocoaError(.fileReadCorruptFile))), for: .back)
            XCTFail("expected import failure")
        } catch {}
        let failedState = await controller.state
        let failedPresentation = await controller.presentation(for: .back)
        let slots = await controller.preservedAcceptedSlots()
        XCTAssertEqual(failedState, .importFailed(.back))
        XCTAssertEqual(failedPresentation.action, .selectPhoto(.back))
        XCTAssertEqual(slots, [.front])
    }

    func testStaleSessionImportCannotSubmitOrMutateReplacementSession() async throws {
        let session = RecoverySession(sessionID: try SessionID("session-a"), accepted: [.front])
        let submitter = RecordingSubmitter()
        let controller = CaptureRecoveryController(
            authorization: StaticAuthorization(.denied), session: session, submitter: submitter
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
}

@available(macOS 10.15, iOS 18.0, *)
private func makeController(authorization: CaptureAuthorization) -> CaptureRecoveryController {
    CaptureRecoveryController(
        authorization: StaticAuthorization(authorization),
        session: RecoverySession(sessionID: try! SessionID("session-a"), accepted: []),
        submitter: RecordingSubmitter()
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
        let sessionID: SessionID
    }
    private(set) var submissions: [Submission] = []
    func submit(_ photo: CapturedPhoto, for shot: Shot, sessionID: SessionID) async throws {
        submissions.append(.init(photo: photo, shot: shot, sessionID: sessionID))
    }
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
