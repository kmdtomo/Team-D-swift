import DomainKit
import Foundation

/// The permission state is intentionally distinct from capture availability so
/// the UI can offer an accurate, in-flow recovery action for every outcome.
public enum CapturePermissionState: Equatable, Sendable {
    case notDetermined
    case requesting
    case authorized
    case denied
    case restricted
}

public enum CaptureRecoveryState: Equatable, Sendable {
    case cameraReady
    case permission(CapturePermissionState)
    case interrupted
    case runtimeError
    case inBackground
    case resuming
    case importing(Shot)
    case importCancelled(Shot)
    case importFailed(Shot)
    case staleSession
}

public enum CaptureRecoveryAction: Equatable, Sendable {
    case requestCameraPermission
    case openSettings
    case selectPhoto(Shot)
    case retryCamera
    case resumeCamera
}

/// App-owned Japanese copy. Provider errors and system diagnostic text never
/// escape through this boundary.
public struct CaptureRecoveryPresentation: Equatable, Sendable {
    public let state: CaptureRecoveryState
    /// The UI must render every offered action. In particular, a denied camera
    /// permission has both Settings and the native photo-selection fallback.
    public let actions: [CaptureRecoveryAction]
    public let instruction: String

    public init(state: CaptureRecoveryState, actions: [CaptureRecoveryAction], instruction: String) {
        self.state = state
        self.actions = actions
        self.instruction = instruction
    }
}

public enum CaptureRecoveryCopy {
    public static func presentation(for state: CaptureRecoveryState, shot: Shot) -> CaptureRecoveryPresentation {
        switch state {
        case .cameraReady, .permission(.authorized):
            .init(state: state, actions: [], instruction: "写真を撮影してください")
        case .permission(.notDetermined):
            .init(state: state, actions: [.requestCameraPermission], instruction: "カメラの使用を許可してください")
        case .permission(.requesting):
            .init(state: state, actions: [], instruction: "カメラの許可を確認しています")
        case .permission(.denied):
            .init(state: state, actions: [.openSettings, .selectPhoto(shot)], instruction: "カメラを使うには設定で許可するか、写真から選んでください")
        case .permission(.restricted):
            .init(state: state, actions: [.selectPhoto(shot)], instruction: "カメラを使えません。写真から選んでください")
        case .interrupted:
            .init(state: state, actions: [.retryCamera, .selectPhoto(shot)], instruction: "カメラが中断されました。再開するか、写真から選んでください")
        case .runtimeError:
            .init(state: state, actions: [.retryCamera, .selectPhoto(shot)], instruction: "カメラを再開できません。もう一度試すか、写真から選んでください")
        case .inBackground:
            .init(state: state, actions: [.resumeCamera], instruction: "アプリに戻ったら撮影を再開できます")
        case .resuming:
            .init(state: state, actions: [.selectPhoto(shot)], instruction: "カメラを再開しています。写真から選ぶこともできます")
        case .importing:
            .init(state: state, actions: [], instruction: "写真を確認しています")
        case .importCancelled:
            .init(state: state, actions: [.selectPhoto(shot)], instruction: "写真の選択を取り消しました。もう一度選べます")
        case .importFailed:
            .init(state: state, actions: [.selectPhoto(shot)], instruction: "写真を読み込めませんでした。もう一度選んでください")
        case .staleSession:
            .init(state: state, actions: [], instruction: "この撮影は終了しました。新しい撮影を開始してください")
        }
    }
}

public enum CaptureLifecycleSignal: Equatable, Sendable {
    case interrupted
    case interruptionEnded
    case runtimeError
    case enteredBackground
    case enteredForeground
}

/// Imported data is handed on without resizing, rendering, or re-encoding.
/// `metadata` is read from those same bytes and follows the camera photo path.
public struct ImportedCapture: Equatable, Sendable {
    public let originalFileData: Data
    public let metadata: CapturePhotoMetadata

    public init(originalFileData: Data, metadata: CapturePhotoMetadata) {
        self.originalFileData = originalFileData
        self.metadata = metadata
    }

    public var capturedPhoto: CapturedPhoto {
        .init(originalFileData: originalFileData, metadata: metadata)
    }
}

public protocol CaptureImporting: Sendable {
    func loadOriginal() async throws -> ImportedCapture
}

/// A selected original enters the same finite post-capture route as a camera
/// original. `measurement` can never be submitted to the shot assessor.
public enum CaptureSlotProcessingRoute: Equatable, Sendable {
    case shotAssessment(AssessableShot)
    case measurementValidation

    public init(shot: Shot) {
        switch shot {
        case .front: self = .shotAssessment(.front)
        case .back: self = .shotAssessment(.back)
        case .tag: self = .shotAssessment(.tag)
        case .measurement: self = .measurementValidation
        }
    }
}

/// This deliberately points at the existing capture/assessment owner rather
/// than creating an import-only acceptance path.
public protocol CaptureSlotSubmitting: Sendable {
    func submit(
        _ photo: CapturedPhoto,
        for shot: Shot,
        route: CaptureSlotProcessingRoute,
        sessionID: SessionID
    ) async throws
}

/// Recovery always reconstructs the existing single camera owner; it never
/// creates a second `AVCaptureSession`.
public protocol CaptureCameraRecovering: Sendable {
    func suspendCamera() async
    func recoverCamera() async throws
}

/// An injected read-only boundary makes it explicit that recovery does not
/// replace, retake, or discard any accepted slot.
public protocol CaptureRecoverySessionPreserving: Sendable {
    func activeSessionID() async -> SessionID?
    func acceptedSlots() async -> Set<Shot>
}

public enum CaptureRecoveryError: Error, Equatable, Sendable {
    case noActiveSession
    case staleSession
    case staleImport
}

@available(macOS 10.15, iOS 18.0, *)
public actor CaptureRecoveryController {
    private let authorization: any CaptureAuthorizing
    private let session: any CaptureRecoverySessionPreserving
    private let submitter: any CaptureSlotSubmitting
    private let camera: any CaptureCameraRecovering
    private var stateStorage: CaptureRecoveryState = .permission(.notDetermined)
    private var permissionVersion: UInt64 = 0
    private var recoveryVersion: UInt64 = 0
    private var importVersion: UInt64 = 0

    public init(
        authorization: any CaptureAuthorizing,
        session: any CaptureRecoverySessionPreserving,
        submitter: any CaptureSlotSubmitting,
        camera: any CaptureCameraRecovering
    ) {
        self.authorization = authorization
        self.session = session
        self.submitter = submitter
        self.camera = camera
    }

    public var state: CaptureRecoveryState { stateStorage }
    public func presentation(for shot: Shot) -> CaptureRecoveryPresentation {
        CaptureRecoveryCopy.presentation(for: stateStorage, shot: shot)
    }
    public func preservedAcceptedSlots() async -> Set<Shot> { await session.acceptedSlots() }

    public func refreshPermission() async {
        let version = nextPermissionVersion()
        let status = await authorization.status()
        guard version == permissionVersion else { return }
        apply(status)
    }

    public func requestPermission() async {
        let version = nextPermissionVersion()
        stateStorage = .permission(.requesting)
        let status = await authorization.requestAccess()
        guard version == permissionVersion else { return }
        apply(status)
    }

    @discardableResult
    public func receive(_ signal: CaptureLifecycleSignal) -> Bool {
        switch signal {
        case .interrupted:
            invalidatePermission()
            invalidateRecovery()
            _ = nextImportVersion()
            stateStorage = .interrupted
        case .runtimeError:
            invalidatePermission()
            invalidateRecovery()
            _ = nextImportVersion()
            stateStorage = .runtimeError
        case .enteredBackground:
            invalidatePermission()
            invalidateRecovery()
            _ = nextImportVersion()
            stateStorage = .inBackground
        case .enteredForeground:
            guard stateStorage == .inBackground else { return false }
            stateStorage = .resuming
        case .interruptionEnded:
            guard stateStorage == .interrupted else { return false }
            stateStorage = .resuming
        }
        return true
    }

    public func cameraDidResume() async {
        try? await recoverCamera()
    }

    public func suspendCamera() async {
        await camera.suspendCamera()
    }

    /// Reconfigure and restart the already-owned camera session. Session
    /// identity is checked on both sides of the suspension so a recovery from
    /// an ended flow cannot affect its replacement.
    public func recoverCamera() async throws {
        guard let sessionID = await session.activeSessionID() else {
            stateStorage = .staleSession
            throw CaptureRecoveryError.noActiveSession
        }
        _ = nextImportVersion()
        let version = nextRecoveryVersion()
        stateStorage = .resuming
        do {
            try await camera.recoverCamera()
            try Task.checkCancellation()
            guard version == recoveryVersion else { return }
            guard await session.activeSessionID() == sessionID else {
                stateStorage = .staleSession
                throw CaptureRecoveryError.staleSession
            }
            let status = await authorization.status()
            guard version == recoveryVersion else { return }
            guard await session.activeSessionID() == sessionID else {
                stateStorage = .staleSession
                throw CaptureRecoveryError.staleSession
            }
            apply(status)
        } catch is CancellationError {
            guard version == recoveryVersion else { throw CancellationError() }
            stateStorage = .interrupted
            throw CancellationError()
        } catch let error as CaptureRecoveryError {
            throw error
        } catch {
            guard version == recoveryVersion else { throw error }
            if await session.activeSessionID() != sessionID {
                stateStorage = .staleSession
                throw CaptureRecoveryError.staleSession
            }
            let status = await authorization.status()
            guard version == recoveryVersion else { throw error }
            if status == .authorized {
                stateStorage = .runtimeError
            } else {
                // Returning from Settings without permission must retain the
                // Settings/photo choices instead of masquerading as a runtime
                // camera failure.
                apply(status)
            }
            throw error
        }
    }

    /// The session identity is sampled before and after awaiting external work.
    /// A selection belonging to an ended/replaced session is never submitted.
    public func importPhoto(_ importer: any CaptureImporting, for shot: Shot) async throws {
        guard let sessionID = await session.activeSessionID() else {
            stateStorage = .staleSession
            throw CaptureRecoveryError.noActiveSession
        }
        invalidateRecovery()
        let version = nextImportVersion()
        stateStorage = .importing(shot)
        do {
            let imported = try await importer.loadOriginal()
            try Task.checkCancellation()
            try requireCurrentImport(version)
            guard await session.activeSessionID() == sessionID else {
                stateStorage = .staleSession
                throw CaptureRecoveryError.staleSession
            }
            try await submitter.submit(
                imported.capturedPhoto,
                for: shot,
                route: .init(shot: shot),
                sessionID: sessionID
            )
            try Task.checkCancellation()
            try requireCurrentImport(version)
            guard await session.activeSessionID() == sessionID else {
                stateStorage = .staleSession
                throw CaptureRecoveryError.staleSession
            }
            // Importing a slot does not grant camera access. A denied or
            // restricted flow must continue to expose the selection fallback.
            let status = await authorization.status()
            try requireCurrentImport(version)
            guard await session.activeSessionID() == sessionID else {
                stateStorage = .staleSession
                throw CaptureRecoveryError.staleSession
            }
            apply(status)
        } catch is CancellationError {
            if version == importVersion { stateStorage = .importCancelled(shot) }
            throw CancellationError()
        } catch let error as CaptureRecoveryError {
            throw error
        } catch {
            if version == importVersion { stateStorage = .importFailed(shot) }
            throw error
        }
    }

    /// Invalidates an in-flight loader without waiting for a provider callback.
    /// Its eventual result is discarded before the shared slot submitter.
    public func cancelImport(for shot: Shot) {
        _ = nextImportVersion()
        stateStorage = .importCancelled(shot)
    }

    public func recordImportFailure(for shot: Shot) {
        _ = nextImportVersion()
        stateStorage = .importFailed(shot)
    }

    private func apply(_ authorization: CaptureAuthorization) {
        switch authorization {
        case .notDetermined: stateStorage = .permission(.notDetermined)
        case .authorized: stateStorage = .cameraReady
        case .denied: stateStorage = .permission(.denied)
        case .restricted: stateStorage = .permission(.restricted)
        }
    }

    private func nextPermissionVersion() -> UInt64 {
        permissionVersion &+= 1
        if permissionVersion == 0 { permissionVersion = 1 }
        return permissionVersion
    }

    private func invalidatePermission() { _ = nextPermissionVersion() }

    private func nextRecoveryVersion() -> UInt64 {
        recoveryVersion &+= 1
        if recoveryVersion == 0 { recoveryVersion = 1 }
        return recoveryVersion
    }

    private func invalidateRecovery() { _ = nextRecoveryVersion() }

    private func nextImportVersion() -> UInt64 {
        importVersion &+= 1
        if importVersion == 0 { importVersion = 1 }
        return importVersion
    }

    private func requireCurrentImport(_ version: UInt64) throws {
        guard version == importVersion else { throw CaptureRecoveryError.staleImport }
    }
}

@available(macOS 10.15, iOS 18.0, *)
extension CaptureSessionController: CaptureCameraRecovering {
    public func suspendCamera() async {
        await stop()
    }

    /// `tearDown` and `start` both remain serialized by the one session owner.
    public func recoverCamera() async throws {
        await tearDown()
        try await start()
    }
}

/// A direct adapter for the T04 store. It exposes only session identity and
/// app-accepted slots; all mutation remains owned by the established store.
public actor CaptureSessionStoreRecoveryBoundary: CaptureRecoverySessionPreserving {
    private let store: CaptureSessionStore
    public init(store: CaptureSessionStore) { self.store = store }

    public func activeSessionID() async -> SessionID? { await store.snapshot()?.sessionID }
    public func acceptedSlots() async -> Set<Shot> {
        guard let snapshot = await store.snapshot() else { return [] }
        var accepted = Set(snapshot.assessments.values.filter(\.acceptedByApp).map { Shot(rawValue: $0.shot.rawValue)! })
        if snapshot.measurementDraft != nil {
            accepted.insert(.measurement)
        }
        return accepted
    }
}
