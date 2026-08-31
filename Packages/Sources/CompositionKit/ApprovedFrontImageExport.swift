import CryptoKit
import DomainKit
import Foundation

/// The two finite encodings permitted for a user-approved front-image export.
/// The bytes provider owns encoding and must never write its input to disk.
public enum ApprovedImageExportFormat: String, Sendable, Equatable, CaseIterable {
    case png
    case jpeg

    public var contentType: String {
        switch self {
        case .png: "image/png"
        case .jpeg: "image/jpeg"
        }
    }

    public var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        }
    }

    public var uniformTypeIdentifier: String {
        switch self {
        case .png: "public.png"
        case .jpeg: "public.jpeg"
        }
    }
}

/// Already-encoded in-memory bytes for one approved comparison candidate.
/// Its provider must strip location, camera, and other capture metadata before
/// creating this value. No URL, file path, cache location, or metadata escape
/// hatch is represented here.
public struct ApprovedImageBytes: Sendable, Equatable {
    public let data: Data
    public let format: ApprovedImageExportFormat

    public init(data: Data, format: ApprovedImageExportFormat) {
        self.data = data
        self.format = format
    }
}

/// The exact final output sent to a user-selected sink.
@available(macOS 10.15, iOS 13, *)
public struct ApprovedImageExportPayload: Sendable, Equatable {
    public let data: Data
    public let format: ApprovedImageExportFormat

    public init(bytes: ApprovedImageBytes) {
        self.data = bytes.data
        self.format = bytes.format
    }

    public var contentType: String { format.contentType }
    public var fileExtension: String { format.fileExtension }
    public var sha256Hex: String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

/// Supplies bytes only for an ID originating in the current in-memory session.
public protocol ApprovedImageBytesProviding: Sendable {
    func approvedImageBytes(for candidateID: String) async throws -> ApprovedImageBytes
}

/// A sink is add-only: it receives final encoded bytes and cannot enumerate,
/// read, modify, or delete a user's library.
@available(macOS 10.15, iOS 13, *)
public protocol ApprovedImageExportSink: Sendable {
    func addApprovedImage(_ payload: ApprovedImageExportPayload) async throws -> ApprovedImageExportSinkResult
}

public enum ApprovedImageExportSinkResult: Sendable, Equatable {
    case completed
    case cancelled
    /// Photos add-only access was denied or restricted. No write was attempted.
    case notAuthorized
}

/// Finite status from the add-only Photos permission boundary. The `limited`
/// case is accepted for compatibility with authorization adapters that expose
/// a limited-equivalent write grant; unknown statuses must fail closed.
public enum PhotosAddOnlyAuthorizationStatus: Sendable, Equatable {
    case authorized
    case limited
    case denied
    case restricted
    case notDetermined
}

/// Isolates Photos authorization so the exporter can prove no write is made
/// for denied, restricted, or declined authorization.
public protocol PhotosAddOnlyAuthorizing: Sendable {
    func authorizationStatus() async -> PhotosAddOnlyAuthorizationStatus
    func requestAddOnlyAuthorization() async -> PhotosAddOnlyAuthorizationStatus
}

/// Isolates the single add-only PhotoKit mutation from authorization policy.
public protocol PhotosAddOnlyWriting: Sendable {
    func addApprovedImageToPhotoLibrary(_ payload: ApprovedImageExportPayload) async throws
}

/// T04-02's concrete session store will adapt this boundary to `endSession`.
/// Cleanup is intentionally invoked only after a sink has completed.
public protocol ApprovedImageExportSessionCleaning: Sendable {
    func cleanupAfterApprovedExport() async throws
}

/// Concrete bridge to the session-scoped artifact owner. `endSession()` keeps
/// its cleanup failure observable, allowing the exporter to retry cleanup
/// without ever issuing a second add-only PhotoKit write.
public struct CaptureSessionStoreApprovedImageExportCleaner: ApprovedImageExportSessionCleaning {
    private let sessionStore: CaptureSessionStore

    public init(sessionStore: CaptureSessionStore) {
        self.sessionStore = sessionStore
    }

    public func cleanupAfterApprovedExport() async throws {
        try await sessionStore.endSession()
    }
}

public enum ApprovedImageExportFailure: Error, Sendable, Equatable {
    case notExplicitlyApproved
    case emptyBytes
    case invalidImageBytes
    case imageFormatMismatch
    case bytesProviderFailed
    case sinkFailed
    case photoLibraryAuthorizationDenied
    case sessionCleanupFailed
}

public enum ApprovedImageExportStatus: Sendable, Equatable {
    case ready
    /// Bytes are being obtained; this is the only cancellable phase.
    case exporting(requestID: UUID)
    /// The add-only sink has been invoked. Its outcome now owns the request.
    case saving(requestID: UUID)
    /// The sink has committed the user's image. Cleanup is now mandatory and
    /// non-cancellable; no further sink write may start from this state.
    case cleanupPending(requestID: UUID)
    /// The image is already saved, but session-only data remains until a
    /// cleanup-only retry succeeds. This is deliberately distinct from a
    /// pre-save retryable failure.
    case cleanupRetryableFailure(requestID: UUID, failure: ApprovedImageExportFailure)
    case retryableFailure(ApprovedImageExportFailure)
    case completed(requestID: UUID)
}

public enum ApprovedImageExportStartResult: Sendable, Equatable {
    case started(requestID: UUID)
    case alreadyInFlight(requestID: UUID)
    case saving(requestID: UUID)
    case cleanupPending(requestID: UUID)
    case cleanupRetryStarted(requestID: UUID)
    case alreadyCompleted(requestID: UUID)
    case rejected(ApprovedImageExportFailure)
}

public enum ApprovedFrontImageOutputCatalogError: Error, Sendable, Equatable {
    case emptyFrontOriginalID
    case emptyValidatedCompositeID
}

/// Session-derived allowlist for the only two IDs that may leave a session.
/// T04-02's adapter constructs this from its front-original artifact and its
/// validated composite artifact; all slot, mask, draft, and cache IDs are
/// therefore structurally absent from this export boundary.
public struct ApprovedFrontImageOutputCatalog: Sendable, Equatable {
    public let frontOriginalID: String
    public let validatedCompositeID: String?

    public init(frontOriginalID: String, validatedCompositeID: String? = nil) throws {
        guard !frontOriginalID.isEmpty else {
            throw ApprovedFrontImageOutputCatalogError.emptyFrontOriginalID
        }
        if let validatedCompositeID, validatedCompositeID.isEmpty {
            throw ApprovedFrontImageOutputCatalogError.emptyValidatedCompositeID
        }
        self.frontOriginalID = frontOriginalID
        self.validatedCompositeID = validatedCompositeID
    }

    public func permits(_ candidate: ImageComparisonCandidate) -> Bool {
        switch candidate.choice {
        case .original: candidate.id == frontOriginalID
        case .composite: candidate.id == validatedCompositeID
        }
    }
}

/// Single-flight exporter for the T16 approval contract. Its only export
/// input is `ImageComparisonState`; callers cannot provide an arbitrary asset
/// ID, so back/tag/measurement/mask/draft IDs never reach a bytes provider.
@available(macOS 10.15, iOS 13, *)
public actor ApprovedFrontImageExporter {
    private let bytesProvider: any ApprovedImageBytesProviding
    private let sink: any ApprovedImageExportSink
    private let sessionCleaner: any ApprovedImageExportSessionCleaning
    private let outputCatalog: ApprovedFrontImageOutputCatalog
    private let makeRequestID: @Sendable () -> UUID
    private var exportTask: Task<Void, Never>?
    private var statusValue: ApprovedImageExportStatus = .ready
    private var terminalWaiters: [UUID: [CheckedContinuation<ApprovedImageExportStatus, Never>]] = [:]

    public init(
        bytesProvider: any ApprovedImageBytesProviding,
        sink: any ApprovedImageExportSink,
        sessionCleaner: any ApprovedImageExportSessionCleaning,
        outputCatalog: ApprovedFrontImageOutputCatalog,
        makeRequestID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.bytesProvider = bytesProvider
        self.sink = sink
        self.sessionCleaner = sessionCleaner
        self.outputCatalog = outputCatalog
        self.makeRequestID = makeRequestID
    }

    public var status: ApprovedImageExportStatus { statusValue }

    @discardableResult
    public func requestExport(approvedComparison: ImageComparisonState) -> ApprovedImageExportStartResult {
        if case let .exporting(requestID) = statusValue {
            return .alreadyInFlight(requestID: requestID)
        }
        if case let .saving(requestID) = statusValue {
            return .saving(requestID: requestID)
        }
        if case let .cleanupPending(requestID) = statusValue {
            return .cleanupPending(requestID: requestID)
        }
        if case let .cleanupRetryableFailure(requestID, _) = statusValue {
            return retryCleanup(requestID: requestID)
        }
        if case let .completed(requestID) = statusValue {
            return .alreadyCompleted(requestID: requestID)
        }
        guard let candidate = approvedCandidate(from: approvedComparison), outputCatalog.permits(candidate) else {
            statusValue = .retryableFailure(.notExplicitlyApproved)
            return .rejected(.notExplicitlyApproved)
        }

        let requestID = makeRequestID()
        statusValue = .exporting(requestID: requestID)
        exportTask = Task { [bytesProvider, sink, sessionCleaner] in
            let bytes: ApprovedImageBytes
            do {
                bytes = try await bytesProvider.approvedImageBytes(for: candidate.id)
            } catch is CancellationError {
                self.finishCancellation(requestID: requestID)
                return
            } catch {
                self.finish(requestID: requestID, result: .failure(.bytesProviderFailed))
                return
            }
            guard !bytes.data.isEmpty else {
                self.finish(requestID: requestID, result: .failure(.emptyBytes))
                return
            }
            guard bytes.format.matches(data: bytes.data) else {
                let failure: ApprovedImageExportFailure = bytes.format.conflicts(with: bytes.data)
                    ? .imageFormatMismatch
                    : .invalidImageBytes
                self.finish(requestID: requestID, result: .failure(failure))
                return
            }
            do {
                try Task.checkCancellation()
            } catch is CancellationError {
                self.finishCancellation(requestID: requestID)
                return
            } catch {
                self.finish(requestID: requestID, result: .failure(.sinkFailed))
                return
            }
            guard self.beginSaving(requestID: requestID) else { return }
            do {
                let sinkResult = try await sink.addApprovedImage(.init(bytes: bytes))
                switch sinkResult {
                case .completed:
                    guard self.beginCleanup(requestID: requestID) else { return }
                    do {
                        try await sessionCleaner.cleanupAfterApprovedExport()
                        self.finishCleanup(requestID: requestID)
                    } catch {
                        self.finishCleanupFailure(requestID: requestID)
                    }
                case .cancelled:
                    self.finishSavingCancellation(requestID: requestID)
                case .notAuthorized:
                    self.finishSavingFailure(requestID: requestID, failure: .photoLibraryAuthorizationDenied)
                }
            } catch is CancellationError {
                self.finishSavingCancellation(requestID: requestID)
            } catch {
                self.finishSavingFailure(requestID: requestID, failure: .sinkFailed)
            }
        }
        return .started(requestID: requestID)
    }

    /// Cancelling is allowed only before the add-only sink commits. Once
    /// cleanup begins, it is non-cancellable to prevent a second
    /// save from racing a completed export.
    public func cancelExport() {
        guard case let .exporting(requestID) = statusValue else { return }
        exportTask?.cancel()
        exportTask = nil
        statusValue = .ready
        resumeWaiters(for: requestID, with: .ready)
    }

    /// Test and integration hook: waits without polling or sleeps until this
    /// request is terminal, cancelled, or superseded by its own completion.
    public func waitForTerminalStatus(of requestID: UUID) async -> ApprovedImageExportStatus {
        switch statusValue {
        case let .exporting(activeID) where activeID == requestID,
             let .saving(activeID) where activeID == requestID,
             let .cleanupPending(activeID) where activeID == requestID:
            return await withCheckedContinuation { continuation in
                terminalWaiters[requestID, default: []].append(continuation)
            }
        default:
            return statusValue
        }
    }

    private func approvedCandidate(from comparison: ImageComparisonState) -> ImageComparisonCandidate? {
        guard let approvedID = comparison.approvedOutputID,
              let approvedChoice = comparison.approvedChoice,
              let candidate = comparison.selectedCandidate,
              candidate.choice == approvedChoice,
              candidate.id == approvedID else {
            return nil
        }
        return candidate
    }

    private func finish(requestID: UUID, result: Result<Void, ApprovedImageExportFailure>) {
        guard case let .exporting(activeID) = statusValue, activeID == requestID else { return }
        exportTask = nil
        switch result {
        case .success:
            statusValue = .completed(requestID: requestID)
        case let .failure(failure):
            statusValue = .retryableFailure(failure)
        }
        resumeWaiters(for: requestID, with: statusValue)
    }

    private func finishCancellation(requestID: UUID) {
        guard case let .exporting(activeID) = statusValue, activeID == requestID else { return }
        exportTask = nil
        statusValue = .ready
        resumeWaiters(for: requestID, with: .ready)
    }

    private func beginCleanup(requestID: UUID) -> Bool {
        guard case let .saving(activeID) = statusValue, activeID == requestID else { return false }
        exportTask = nil
        statusValue = .cleanupPending(requestID: requestID)
        return true
    }

    private func beginSaving(requestID: UUID) -> Bool {
        guard case let .exporting(activeID) = statusValue, activeID == requestID else { return false }
        statusValue = .saving(requestID: requestID)
        return true
    }

    private func finishSavingCancellation(requestID: UUID) {
        guard case let .saving(activeID) = statusValue, activeID == requestID else { return }
        exportTask = nil
        statusValue = .ready
        resumeWaiters(for: requestID, with: .ready)
    }

    private func finishSavingFailure(requestID: UUID, failure: ApprovedImageExportFailure) {
        guard case let .saving(activeID) = statusValue, activeID == requestID else { return }
        exportTask = nil
        statusValue = .retryableFailure(failure)
        resumeWaiters(for: requestID, with: statusValue)
    }

    private func finishCleanup(requestID: UUID) {
        guard case let .cleanupPending(activeID) = statusValue, activeID == requestID else { return }
        exportTask = nil
        statusValue = .completed(requestID: requestID)
        resumeWaiters(for: requestID, with: statusValue)
    }

    private func finishCleanupFailure(requestID: UUID) {
        guard case let .cleanupPending(activeID) = statusValue, activeID == requestID else { return }
        exportTask = nil
        statusValue = .cleanupRetryableFailure(requestID: requestID, failure: .sessionCleanupFailed)
        resumeWaiters(for: requestID, with: statusValue)
    }

    private func retryCleanup(requestID: UUID) -> ApprovedImageExportStartResult {
        statusValue = .cleanupPending(requestID: requestID)
        let sessionCleaner = sessionCleaner
        exportTask = Task {
            do {
                try await sessionCleaner.cleanupAfterApprovedExport()
                self.finishCleanup(requestID: requestID)
            } catch {
                self.finishCleanupFailure(requestID: requestID)
            }
        }
        return .cleanupRetryStarted(requestID: requestID)
    }

    private func resumeWaiters(for requestID: UUID, with status: ApprovedImageExportStatus) {
        let waiters = terminalWaiters.removeValue(forKey: requestID) ?? []
        for waiter in waiters { waiter.resume(returning: status) }
    }
}

private extension ApprovedImageExportFormat {
    func matches(data: Data) -> Bool {
        switch self {
        case .png:
            data.starts(with: Self.pngSignature) && data.hasSuffix(Self.pngTerminator)
        case .jpeg:
            data.starts(with: Self.jpegStart) && data.hasSuffix(Self.jpegEnd)
        }
    }

    func conflicts(with data: Data) -> Bool {
        switch self {
        case .png: data.starts(with: Self.jpegStart)
        case .jpeg: data.starts(with: Self.pngSignature)
        }
    }

    static let pngSignature = Data([137, 80, 78, 71, 13, 10, 26, 10])
    static let pngTerminator = Data([0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130])
    static let jpegStart = Data([255, 216])
    static let jpegEnd = Data([255, 217])
}

private extension Data {
    func hasSuffix(_ suffix: Data) -> Bool {
        count >= suffix.count && self.suffix(suffix.count).elementsEqual(suffix)
    }
}

#if canImport(Photos) && os(iOS)
import Photos

/// Production Photos adapter. It uses `forAsset` plus `addResource` only;
/// it never fetches, enumerates, edits, or deletes Photos assets. Permission
/// prompting and Japanese recovery copy remain with the owning UI slice.
@available(iOS 18, *)
public struct PhotosAddOnlyApprovedImageSink: ApprovedImageExportSink {
    private let authorization: any PhotosAddOnlyAuthorizing
    private let writer: any PhotosAddOnlyWriting

    public init() {
        self.init(
            authorization: PhotoKitAddOnlyAuthorizer(),
            writer: PhotoKitAddOnlyWriter()
        )
    }

    public init(authorization: any PhotosAddOnlyAuthorizing, writer: any PhotosAddOnlyWriting) {
        self.authorization = authorization
        self.writer = writer
    }

    public func addApprovedImage(_ payload: ApprovedImageExportPayload) async throws -> ApprovedImageExportSinkResult {
        let status = await authorization.authorizationStatus()
        let resolvedStatus: PhotosAddOnlyAuthorizationStatus
        switch status {
        case .authorized, .limited:
            resolvedStatus = status
        case .notDetermined:
            resolvedStatus = await authorization.requestAddOnlyAuthorization()
        case .denied, .restricted:
            return .notAuthorized
        }

        guard resolvedStatus == .authorized || resolvedStatus == .limited else {
            return .notAuthorized
        }
        try await writer.addApprovedImageToPhotoLibrary(payload)
        return .completed
    }
}

@available(iOS 18, *)
private struct PhotoKitAddOnlyAuthorizer: PhotosAddOnlyAuthorizing {
    func authorizationStatus() async -> PhotosAddOnlyAuthorizationStatus {
        map(PHPhotoLibrary.authorizationStatus(for: .addOnly))
    }

    func requestAddOnlyAuthorization() async -> PhotosAddOnlyAuthorizationStatus {
        map(await PHPhotoLibrary.requestAuthorization(for: .addOnly))
    }

    private func map(_ status: PHAuthorizationStatus) -> PhotosAddOnlyAuthorizationStatus {
        switch status {
        case .authorized: .authorized
        case .limited: .limited
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .restricted
        }
    }
}

@available(iOS 18, *)
private struct PhotoKitAddOnlyWriter: PhotosAddOnlyWriting {
    func addApprovedImageToPhotoLibrary(_ payload: ApprovedImageExportPayload) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.uniformTypeIdentifier = payload.format.uniformTypeIdentifier
            request.addResource(with: .photo, data: payload.data, options: options)
        }
    }
}
#endif
