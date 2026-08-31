import CaptureKit
import Foundation
import XCTest

@available(macOS 10.15, iOS 18.0, *)
final class CaptureSessionControllerTests: XCTestCase {
    func testAuthorizationAndFailureMatrix() async throws {
        for (initial, requested, expected) in [(CaptureAuthorization.restricted, CaptureAuthorization.restricted, CaptureSessionError.authorizationRestricted), (.notDetermined, .denied, .authorizationDenied), (.notDetermined, .notDetermined, .authorizationNotDetermined)] {
            let controller = CaptureSessionController(authorization: MatrixAuthorization(initial: initial, requested: requested), driver: FakeDriver())
            do { try await controller.start(); XCTFail("expected authorization failure") } catch { XCTAssertEqual(error as? CaptureSessionError, expected) }
        }
        let configureDriver = FakeDriver(configureError: .cannotAddPhotoOutput)
        let configureController = CaptureSessionController(authorization: FakeAuthorization(.authorized), driver: configureDriver)
        do { try await configureController.start(); XCTFail("expected configure failure") } catch { XCTAssertEqual(error as? CaptureSessionError, .cannotAddPhotoOutput) }
        let calls = await configureDriver.startCount; XCTAssertEqual(calls, 0)
        let startDriver = FakeDriver(startError: .startFailed("fixture"))
        let startController = CaptureSessionController(authorization: FakeAuthorization(.authorized), driver: startDriver)
        do { try await startController.start(); XCTFail("expected start failure") } catch { XCTAssertEqual(error as? CaptureSessionError, .startFailed("fixture")) }
        let photoDriver = FakeDriver(); let photoController = CaptureSessionController(authorization: FakeAuthorization(.authorized), driver: photoDriver)
        try await photoController.start(); await photoDriver.enqueuePhoto(.failure(CaptureSessionError.photoCaptureFailed("provider")))
        do { _ = try await photoController.capturePhoto(); XCTFail("expected provider failure") } catch { XCTAssertEqual(error as? CaptureSessionError, .photoCaptureFailed("provider")) }
    }

    func testSecondCaptureAndTeardownPendingPhoto() async throws {
        let driver = PhotoRaceDriver(); let controller = CaptureSessionController(authorization: FakeAuthorization(.authorized), driver: driver)
        try await controller.start(); let pending = Task { try await controller.capturePhoto() }
        try await eventually { await driver.startedRequestIDs.contains(1) }
        do { _ = try await controller.capturePhoto(); XCTFail("second capture was accepted") } catch { XCTAssertEqual(error as? CaptureSessionError, .captureInProgress) }
        await controller.tearDown()
        do { _ = try await pending.value; XCTFail("pending capture survived teardown") } catch { XCTAssertEqual(error as? CaptureSessionError, .cancelled) }
        let cancelIDs = await driver.cancelledRequestIDs; let teardownCount = await driver.tearDownCount; let state = await controller.state
        XCTAssertEqual(cancelIDs, [1]); XCTAssertEqual(teardownCount, 1); XCTAssertEqual(state, .idle)
    }
    func testTeardownDuringAuthorizationCannotResurrectSession() async throws {
        let authorization = GatedAuthorization()
        let controller = CaptureSessionController(authorization: authorization, driver: FakeDriver())
        let start = Task { try await controller.start() }
        try await eventually { await authorization.wasRequested }
        await controller.tearDown()
        await authorization.release(.authorized)
        do { _ = try await start.value; XCTFail("stale authorization resumed start") } catch { XCTAssertEqual(error as? CaptureSessionError, .cancelled) }
        let state = await controller.state
        XCTAssertEqual(state, .idle)
    }

    func testTeardownAndStopDuringConfigureOrStartCannotRunLater() async throws {
        let configuring = ControlledDriver(gateConfigure: true)
        let first = CaptureSessionController(authorization: FakeAuthorization(.authorized), driver: configuring)
        let configureStart = Task { try await first.start() }
        try await eventually { await configuring.didBeginConfigure }
        await first.tearDown(); await configuring.releaseConfigure()
        do { _ = try await configureStart.value; XCTFail("stale configure resumed start") } catch { XCTAssertEqual(error as? CaptureSessionError, .cancelled) }
        let firstState = await first.state
        XCTAssertEqual(firstState, .idle)

        let starting = ControlledDriver(gateStart: true)
        let second = CaptureSessionController(authorization: FakeAuthorization(.authorized), driver: starting)
        let start = Task { try await second.start() }
        try await eventually { await starting.didBeginStart }
        await second.stop(); await starting.releaseStart()
        do { _ = try await start.value; XCTFail("stop during start resumed session") } catch { XCTAssertEqual(error as? CaptureSessionError, .cancelled) }
        let secondState = await second.state
        XCTAssertEqual(secondState, .idle)
    }
    func testAuthorizationAndLifecycle() async throws {
        let denied = CaptureSessionController(authorization: FakeAuthorization(.denied), driver: FakeDriver())
        do { try await denied.start(); XCTFail("expected denied") } catch { XCTAssertEqual(error as? CaptureSessionError, .authorizationDenied) }
        let driver = FakeDriver(); let controller = CaptureSessionController(authorization: FakeAuthorization(.authorized), driver: driver)
        try await controller.start(); try await controller.start(); await controller.stop(); await controller.stop()
        let configureCount = await driver.configureCount; let startCount = await driver.startCount; let stopCount = await driver.stopCount
        XCTAssertEqual(configureCount, 1); XCTAssertEqual(startCount, 1); XCTAssertEqual(stopCount, 1)
    }

    func testLatestAndOriginalHandoff() async throws {
        let driver = FakeDriver(); let controller = CaptureSessionController(authorization: FakeAuthorization(.authorized), driver: driver)
        try await controller.start()
        await controller.receiveAnalysisSample(.init(sequence: 1, timestampNanoseconds: 1), generation: 1)
        await controller.receiveAnalysisSample(.init(sequence: 2, timestampNanoseconds: 2), generation: 1)
        let latest = await controller.takeLatestAnalysisSample()
        XCTAssertEqual(latest?.sequence, 2)
        await controller.receiveAnalysisSample(.init(sequence: 2, timestampNanoseconds: 3), generation: 1)
        await controller.receiveAnalysisSample(.init(sequence: 1, timestampNanoseconds: 4), generation: 1)
        let rejected = await controller.takeLatestAnalysisSample()
        XCTAssertNil(rejected, "watermark survives consumption and rejects stale delivery")
        let original = CapturedPhoto(originalFileData: Data([9, 8]), metadata: .init(orientation: 6, colorSpaceName: "RGB"))
        await driver.enqueuePhoto(.success(original))
        let captured = try await controller.capturePhoto()
        XCTAssertEqual(captured, original)
        await controller.tearDown()
        try await controller.start()
        await controller.receiveAnalysisSample(.init(sequence: 99, timestampNanoseconds: 5), generation: 1)
        let staleGeneration = await controller.takeLatestAnalysisSample()
        XCTAssertNil(staleGeneration, "old generation samples are discarded")
    }

    func testTimestampConverterRejectsInvalidValues() {
        XCTAssertEqual(AnalysisTimestamp.nanoseconds(seconds: 1.25), 1_250_000_000)
        XCTAssertNil(AnalysisTimestamp.nanoseconds(seconds: -.infinity))
        XCTAssertNil(AnalysisTimestamp.nanoseconds(seconds: .nan))
        XCTAssertNil(AnalysisTimestamp.nanoseconds(seconds: Double(UInt64.max)))
        let boundary = Double(UInt64.max) / 1_000_000_000
        XCTAssertNil(AnalysisTimestamp.nanoseconds(seconds: boundary))
        XCTAssertNotNil(AnalysisTimestamp.nanoseconds(seconds: boundary.nextDown))
    }

    func testCancelledOldPhotoCannotAffectNewRequestAfterLateCallbacks() async throws {
        let driver = PhotoRaceDriver()
        let controller = CaptureSessionController(authorization: FakeAuthorization(.authorized), driver: driver)
        try await controller.start()
        let old = Task { try await controller.capturePhoto() }
        try await eventually { await driver.startedRequestIDs.contains(1) }
        old.cancel()
        try await eventually { await driver.cancelledRequestIDs.contains(1) }
        let new = Task { try await controller.capturePhoto() }
        try await eventually { await driver.startedRequestIDs.contains(2) }
        await driver.deliverLate(requestID: 1, result: .success(.init(originalFileData: Data([1]), metadata: .init())))
        await driver.deliverLate(requestID: 1, result: .failure(CaptureSessionError.photoCaptureFailed("old")))
        let expected = CapturedPhoto(originalFileData: Data([2]), metadata: .init(orientation: 6))
        await driver.completeCurrent(requestID: 2, result: .success(expected))
        do { _ = try await old.value; XCTFail("old request escaped cancellation") } catch { XCTAssertEqual(error as? CaptureSessionError, .cancelled) }
        let newPhoto = try await new.value
        let cancelledIDs = await driver.cancelledRequestIDs
        XCTAssertEqual(newPhoto, expected)
        XCTAssertEqual(cancelledIDs, [1])
    }
}

private enum TestTimeout: Error { case elapsed }
@available(macOS 10.15, iOS 18.0, *)
private func eventually(_ condition: @escaping @Sendable () async -> Bool) async throws {
    for _ in 0..<100 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw TestTimeout.elapsed
}

@available(macOS 10.15, iOS 18.0, *)
private actor Gate {
    private var opened = false; private var signals: [CheckedContinuation<Void, Never>] = []; private var arrivalCount = 0
    func wait() async { if opened { return }; await withCheckedContinuation { signals.append($0) } }
    func arrive() { arrivalCount += 1 }
    var hasArrived: Bool { arrivalCount > 0 }
    func open() { opened = true; let pending = signals; signals = []; pending.forEach { $0.resume() } }
}

@available(macOS 10.15, iOS 18.0, *)
private actor GatedAuthorization: CaptureAuthorizing {
    private let gate = Gate()
    func status() async -> CaptureAuthorization { await gate.arrive(); await gate.wait(); return .authorized }
    func requestAccess() async -> CaptureAuthorization { .authorized }
    var wasRequested: Bool { get async { await gate.hasArrived } }
    func release(_ status: CaptureAuthorization) async { await gate.open() }
}

@available(macOS 10.15, iOS 18.0, *)
private actor ControlledDriver: CaptureSessionDriving {
    private let configureGate = Gate(); private let startGate = Gate(); private let gateConfigure: Bool; private let gateStart: Bool
    init(gateConfigure: Bool = false, gateStart: Bool = false) { self.gateConfigure = gateConfigure; self.gateStart = gateStart }
    func configure(onAnalysisSample: @escaping @Sendable (AnalysisSample) -> Void) async throws { await configureGate.arrive(); if gateConfigure { await configureGate.wait() } }
    func startRunning() async throws { await startGate.arrive(); if gateStart { await startGate.wait() } }
    func stopRunning() async {}
    func capturePhoto(requestID: UInt64) async throws -> CapturedPhoto { throw CaptureSessionError.photoCaptureFailed("unused") }
    func cancelPhotoCapture(requestID: UInt64) async {}
    func tearDown() async {}
    var didBeginConfigure: Bool { get async { await configureGate.hasArrived } }
    var didBeginStart: Bool { get async { await startGate.hasArrived } }
    func releaseConfigure() async { await configureGate.open() }
    func releaseStart() async { await startGate.open() }
}

@available(macOS 10.15, iOS 18.0, *)
private actor PhotoRaceDriver: CaptureSessionDriving {
    var startedRequestIDs: [UInt64] = []; var cancelledRequestIDs: [UInt64] = []
    var tearDownCount = 0
    private var continuations: [UInt64: CheckedContinuation<CapturedPhoto, Error>] = [:]
    func configure(onAnalysisSample: @escaping @Sendable (AnalysisSample) -> Void) async throws {}
    func startRunning() async throws {}
    func stopRunning() async {}
    func capturePhoto(requestID: UInt64) async throws -> CapturedPhoto {
        startedRequestIDs.append(requestID)
        return try await withCheckedThrowingContinuation { continuations[requestID] = $0 }
    }
    func cancelPhotoCapture(requestID: UInt64) async {
        cancelledRequestIDs.append(requestID)
        let continuation = continuations.removeValue(forKey: requestID)
        continuation?.resume(throwing: CaptureSessionError.cancelled)
    }
    func tearDown() async { tearDownCount += 1 }
    func deliverLate(requestID: UInt64, result: Result<CapturedPhoto, Error>) { continuations.removeValue(forKey: requestID)?.resume(with: result) }
    func completeCurrent(requestID: UInt64, result: Result<CapturedPhoto, Error>) { continuations.removeValue(forKey: requestID)?.resume(with: result) }
}

@available(macOS 10.15, iOS 18.0, *)
private struct FakeAuthorization: CaptureAuthorizing { let value: CaptureAuthorization; init(_ value: CaptureAuthorization) { self.value = value }; func status() async -> CaptureAuthorization { value }; func requestAccess() async -> CaptureAuthorization { value } }
@available(macOS 10.15, iOS 18.0, *)
private struct MatrixAuthorization: CaptureAuthorizing { let initial: CaptureAuthorization; let requested: CaptureAuthorization; func status() async -> CaptureAuthorization { initial }; func requestAccess() async -> CaptureAuthorization { requested } }
@available(macOS 10.15, iOS 18.0, *)
private actor FakeDriver: CaptureSessionDriving {
    var configureCount = 0; var startCount = 0; var stopCount = 0; var queued: [Result<CapturedPhoto, Error>] = []; let configureError: CaptureSessionError?; let startError: CaptureSessionError?
    init(configureError: CaptureSessionError? = nil, startError: CaptureSessionError? = nil) { self.configureError = configureError; self.startError = startError }
    func configure(onAnalysisSample: @escaping @Sendable (AnalysisSample) -> Void) async throws { configureCount += 1; if let configureError { throw configureError } }
    func startRunning() async throws { startCount += 1; if let startError { throw startError } }
    func stopRunning() async { stopCount += 1 }
    func capturePhoto(requestID: UInt64) async throws -> CapturedPhoto { try queued.removeFirst().get() }
    func cancelPhotoCapture(requestID: UInt64) async {}
    func tearDown() async {}
    func enqueuePhoto(_ photo: Result<CapturedPhoto, Error>) { queued.append(photo) }
}
