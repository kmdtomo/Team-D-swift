import Foundation
#if os(iOS)
import CoreVideo
#endif

public enum CaptureKitModule {}
public enum CaptureAuthorization: Equatable, Sendable { case notDetermined, authorized, denied, restricted }
public protocol CaptureAuthorizing: Sendable { func status() async -> CaptureAuthorization; func requestAccess() async -> CaptureAuthorization }

public enum CaptureSessionState: Equatable, Sendable {
    case idle, requestingAuthorization, configuring, starting, configured, running, stopping
    case failed(CaptureSessionError)
}
public enum CaptureSessionError: Error, Equatable, Sendable {
    case authorizationDenied, authorizationRestricted, authorizationNotDetermined
    case backCameraUnavailable, cannotAddInput, cannotAddVideoOutput, cannotAddPhotoOutput
    case configurationFailed(String), startFailed(String), notRunning, captureInProgress
    case photoCaptureFailed(String), cancelled
}

/// The original is camera-produced file data. CaptureKit neither changes pixels
/// nor interprets orientation/color: T05-02 owns that work.
public struct CapturedPhoto: Equatable, Sendable {
    public let originalFileData: Data; public let metadata: CapturePhotoMetadata
    public init(originalFileData: Data, metadata: CapturePhotoMetadata) { self.originalFileData = originalFileData; self.metadata = metadata }
}
public struct CapturePhotoMetadata: Equatable, Sendable {
    public let contentType: String?; public let orientation: Int?; public let colorSpaceName: String?; public let pixelWidth: Int?; public let pixelHeight: Int?
    public init(contentType: String? = nil, orientation: Int? = nil, colorSpaceName: String? = nil, pixelWidth: Int? = nil, pixelHeight: Int? = nil) { self.contentType = contentType; self.orientation = orientation; self.colorSpaceName = colorSpaceName; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight }
}

#if os(iOS)
/// A retained, read-only-to-CaptureKit Core Video frame handoff. It is exclusively
/// held by the controller's capacity-one slot; CaptureKit never mutates it.
/// The unchecked conformance is limited to the Core Video buffer handle.
public final class AnalysisFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public init(pixelBuffer: CVPixelBuffer) { self.pixelBuffer = pixelBuffer }
}
#endif

/// This is deliberately not a still-image contract and has no serialized payload.
public struct AnalysisSample: Equatable, Sendable {
    public let sequence: UInt64; public let timestampNanoseconds: UInt64
    #if os(iOS)
    public let frame: AnalysisFrame?
    public init(sequence: UInt64, timestampNanoseconds: UInt64, frame: AnalysisFrame? = nil) { self.sequence = sequence; self.timestampNanoseconds = timestampNanoseconds; self.frame = frame }
    #else
    public init(sequence: UInt64, timestampNanoseconds: UInt64) { self.sequence = sequence; self.timestampNanoseconds = timestampNanoseconds }
    #endif
    public static func == (lhs: AnalysisSample, rhs: AnalysisSample) -> Bool { lhs.sequence == rhs.sequence && lhs.timestampNanoseconds == rhs.timestampNanoseconds }
}

/// Pure timestamp conversion so invalid camera time never becomes a seemingly
/// valid zero-time analysis sample.
public enum AnalysisTimestamp {
    public static func nanoseconds(seconds: Double) -> UInt64? {
        let scale = 1_000_000_000.0
        let ceiling = Double(UInt64.max) / scale
        guard seconds.isFinite, seconds >= 0, seconds < ceiling else { return nil }
        let wholeSeconds = seconds.rounded(.down)
        guard wholeSeconds.isFinite, wholeSeconds >= 0 else { return nil }
        let integral = UInt64(wholeSeconds)
        let fractional = UInt64(((seconds - wholeSeconds) * scale).rounded(.down))
        guard integral <= UInt64.max / 1_000_000_000, fractional < 1_000_000_000 else { return nil }
        let base = integral * 1_000_000_000
        guard base <= UInt64.max - fractional else { return nil }
        return base + fractional
    }
}

public protocol CaptureSessionDriving: AnyObject, Sendable {
    func configure(onAnalysisSample: @escaping @Sendable (AnalysisSample) -> Void) async throws
    func startRunning() async throws
    func stopRunning() async
    func capturePhoto(requestID: UInt64) async throws -> CapturedPhoto
    func cancelPhotoCapture(requestID: UInt64) async
    func tearDown() async
}

/// All public lifecycle transitions carry a monotonically increasing generation.
/// Resuming an old async call can therefore never restore a newer/torn-down state.
@available(macOS 10.15, iOS 18.0, *)
public actor CaptureSessionController {
    private let authorization: any CaptureAuthorizing
    private let driver: any CaptureSessionDriving
    private var stateStorage: CaptureSessionState = .idle
    private var generation: UInt64 = 0
    private var nextPhotoRequestID: UInt64 = 0
    private var currentPhotoRequestID: UInt64?
    private var latestSample: AnalysisSample?
    private var sampleWatermark: UInt64 = 0

    public init(authorization: any CaptureAuthorizing, driver: any CaptureSessionDriving) { self.authorization = authorization; self.driver = driver }
    public var state: CaptureSessionState { stateStorage }
    public var latestAnalysisSampleSequence: UInt64? { latestSample?.sequence }

    public func start() async throws {
        switch stateStorage {
        case .running: return
        case .configured: break
        case .idle: try await authorizeAndConfigure(generation: beginGeneration())
        case .requestingAuthorization, .configuring, .starting, .stopping: throw CaptureSessionError.configurationFailed("camera transition is in progress")
        case .failed: throw CaptureSessionError.configurationFailed("camera must be recreated after failure")
        }
        let token = generation
        stateStorage = .starting
        do {
            try await withTaskCancellationHandler(operation: { try await driver.startRunning() }, onCancel: { Task { await self.invalidateLifecycle(ifCurrent: token) } })
            try requireCurrent(token)
            stateStorage = .running
        } catch {
            guard token == generation else { throw CaptureSessionError.cancelled }
            let mapped = mapStartError(error); stateStorage = .failed(mapped); throw mapped
        }
    }

    public func stop() async {
        switch stateStorage {
        case .requestingAuthorization, .configuring, .starting:
            await invalidateLifecycle(ifCurrent: generation)
            return
        case .running:
            break
        default:
            return
        }
        let token = generation; stateStorage = .stopping
        if let request = currentPhotoRequestID { await cancelPhotoCapture(ifCurrent: request) }
        await driver.stopRunning()
        guard token == generation else { return }
        stateStorage = .configured; latestSample = nil
    }

    public func capturePhoto() async throws -> CapturedPhoto {
        guard case .running = stateStorage else { throw CaptureSessionError.notRunning }
        guard currentPhotoRequestID == nil else { throw CaptureSessionError.captureInProgress }
        let request = nextNonzeroPhotoRequestID(); currentPhotoRequestID = request
        defer { if currentPhotoRequestID == request { currentPhotoRequestID = nil } }
        do {
            let photo = try await withTaskCancellationHandler(operation: { try await driver.capturePhoto(requestID: request) }, onCancel: { Task { await self.cancelPhotoCapture(ifCurrent: request) } })
            try Task.checkCancellation()
            guard currentPhotoRequestID == request else { throw CaptureSessionError.cancelled }
            return photo
        } catch {
            guard currentPhotoRequestID == request else { throw CaptureSessionError.cancelled }
            if error is CancellationError { throw CaptureSessionError.cancelled }
            if let error = error as? CaptureSessionError { throw error }
            throw CaptureSessionError.photoCaptureFailed("photo processing failed")
        }
    }

    public func receiveAnalysisSample(_ sample: AnalysisSample, generation token: UInt64) {
        guard token == generation, stateStorage == .running, sample.sequence > sampleWatermark else { return }
        sampleWatermark = sample.sequence
        latestSample = sample
    }
    public func takeLatestAnalysisSample() -> AnalysisSample? { defer { latestSample = nil }; return latestSample }

    public func tearDown() async {
        let token = beginGeneration(); stateStorage = .stopping; latestSample = nil
        if let request = currentPhotoRequestID { await cancelPhotoCapture(ifCurrent: request) }
        await driver.stopRunning(); await driver.tearDown()
        guard token == generation else { return }
        stateStorage = .idle
    }

    private func authorizeAndConfigure(generation token: UInt64) async throws {
        stateStorage = .requestingAuthorization
        do {
            var status = await authorization.status(); try requireCurrent(token)
            if status == .notDetermined { status = await authorization.requestAccess(); try requireCurrent(token) }
            switch status {
            case .authorized: break
            case .denied: throw CaptureSessionError.authorizationDenied
            case .restricted: throw CaptureSessionError.authorizationRestricted
            case .notDetermined: throw CaptureSessionError.authorizationNotDetermined
            }
            stateStorage = .configuring
            try await withTaskCancellationHandler(
                operation: {
                    try await driver.configure { [weak self] sample in
                        Task { await self?.receiveAnalysisSample(sample, generation: token) }
                    }
                },
                onCancel: {
                    Task { await self.invalidateLifecycle(ifCurrent: token) }
                }
            )
            try requireCurrent(token); stateStorage = .configured
        } catch {
            guard token == generation else { throw CaptureSessionError.cancelled }
            let mapped = error as? CaptureSessionError ?? .configurationFailed("camera configuration failed")
            stateStorage = .failed(mapped); throw mapped
        }
    }

    private func beginGeneration() -> UInt64 { generation &+= 1; if generation == 0 { generation = 1 }; sampleWatermark = 0; return generation }
    private func nextNonzeroPhotoRequestID() -> UInt64 { nextPhotoRequestID &+= 1; if nextPhotoRequestID == 0 { nextPhotoRequestID = 1 }; return nextPhotoRequestID }
    private func requireCurrent(_ token: UInt64) throws { guard token == generation, !Task.isCancelled else { throw CaptureSessionError.cancelled } }
    private func mapStartError(_ error: Error) -> CaptureSessionError { if error is CancellationError { return .cancelled }; if let error = error as? CaptureSessionError { return error }; return .startFailed("camera start failed") }
    private func cancelPhotoCapture(ifCurrent request: UInt64) async { guard currentPhotoRequestID == request else { return }; currentPhotoRequestID = nil; await driver.cancelPhotoCapture(requestID: request) }
    private func invalidateLifecycle(ifCurrent token: UInt64) async { guard generation == token else { return }; _ = beginGeneration(); stateStorage = .stopping; latestSample = nil; if let request = currentPhotoRequestID { await cancelPhotoCapture(ifCurrent: request) }; await driver.stopRunning(); await driver.tearDown(); if case .stopping = stateStorage { stateStorage = .idle } }
}
