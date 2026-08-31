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
    public let action: CaptureRecoveryAction?
    public let instruction: String

    public init(state: CaptureRecoveryState, action: CaptureRecoveryAction?, instruction: String) {
        self.state = state
        self.action = action
        self.instruction = instruction
    }
}

public enum CaptureRecoveryCopy {
    public static func presentation(for state: CaptureRecoveryState, shot: Shot) -> CaptureRecoveryPresentation {
        switch state {
        case .cameraReady:
            .init(state: state, action: nil, instruction: "写真を撮影してください")
        case .permission(.notDetermined), .permission(.requesting):
            .init(state: state, action: .requestCameraPermission, instruction: "カメラの使用を許可してください")
        case .permission(.denied):
            .init(state: state, action: .openSettings, instruction: "カメラを使うには設定で許可するか、写真から選んでください")
        case .permission(.restricted):
            .init(state: state, action: .selectPhoto(shot), instruction: "カメラを使えません。写真から選んでください")
        case .interrupted:
            .init(state: state, action: .retryCamera, instruction: "カメラが中断されました。再開してください")
        case .runtimeError:
            .init(state: state, action: .retryCamera, instruction: "カメラを再開できません。もう一度お試しください")
        case .inBackground:
            .init(state: state, action: .resumeCamera, instruction: "アプリに戻ったら撮影を再開できます")
        case .resuming:
            .init(state: state, action: nil, instruction: "カメラを再開しています")
        case .importing:
            .init(state: state, action: nil, instruction: "写真を確認しています")
        case .importCancelled:
            .init(state: state, action: .selectPhoto(shot), instruction: "写真の選択を取り消しました。もう一度選べます")
        case .importFailed:
            .init(state: state, action: .selectPhoto(shot), instruction: "写真を読み込めませんでした。もう一度選んでください")
        case .staleSession:
            .init(state: state, action: nil, instruction: "この撮影は終了しました。新しい撮影を開始してください")
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

/// This deliberately points at the existing capture/assessment owner rather
/// than creating an import-only acceptance path.
public protocol CaptureSlotSubmitting: Sendable {
    func submit(_ photo: CapturedPhoto, for shot: Shot, sessionID: SessionID) async throws
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
}

@available(macOS 10.15, iOS 18.0, *)
public actor CaptureRecoveryController {
    private let authorization: any CaptureAuthorizing
    private let session: any CaptureRecoverySessionPreserving
    private let submitter: any CaptureSlotSubmitting
    private var stateStorage: CaptureRecoveryState = .permission(.notDetermined)

    public init(
        authorization: any CaptureAuthorizing,
        session: any CaptureRecoverySessionPreserving,
        submitter: any CaptureSlotSubmitting
    ) {
        self.authorization = authorization
        self.session = session
        self.submitter = submitter
    }

    public var state: CaptureRecoveryState { stateStorage }
    public func presentation(for shot: Shot) -> CaptureRecoveryPresentation {
        CaptureRecoveryCopy.presentation(for: stateStorage, shot: shot)
    }
    public func preservedAcceptedSlots() async -> Set<Shot> { await session.acceptedSlots() }

    public func refreshPermission() async {
        apply(await authorization.status())
    }

    public func requestPermission() async {
        stateStorage = .permission(.requesting)
        apply(await authorization.requestAccess())
    }

    public func receive(_ signal: CaptureLifecycleSignal) {
        switch signal {
        case .interrupted: stateStorage = .interrupted
        case .runtimeError: stateStorage = .runtimeError
        case .enteredBackground: stateStorage = .inBackground
        case .enteredForeground:
            guard stateStorage == .inBackground else { return }
            stateStorage = .resuming
        case .interruptionEnded:
            guard stateStorage == .interrupted else { return }
            stateStorage = .resuming
        }
    }

    public func cameraDidResume() async {
        apply(await authorization.status())
    }

    /// The session identity is sampled before and after awaiting external work.
    /// A selection belonging to an ended/replaced session is never submitted.
    public func importPhoto(_ importer: any CaptureImporting, for shot: Shot) async throws {
        guard let sessionID = await session.activeSessionID() else {
            stateStorage = .staleSession
            throw CaptureRecoveryError.noActiveSession
        }
        stateStorage = .importing(shot)
        do {
            let imported = try await importer.loadOriginal()
            try Task.checkCancellation()
            guard await session.activeSessionID() == sessionID else {
                stateStorage = .staleSession
                throw CaptureRecoveryError.staleSession
            }
            try await submitter.submit(imported.capturedPhoto, for: shot, sessionID: sessionID)
            guard await session.activeSessionID() == sessionID else {
                stateStorage = .staleSession
                throw CaptureRecoveryError.staleSession
            }
            stateStorage = .cameraReady
        } catch is CancellationError {
            stateStorage = .importCancelled(shot)
            throw CancellationError()
        } catch let error as CaptureRecoveryError {
            throw error
        } catch {
            stateStorage = .importFailed(shot)
            throw error
        }
    }

    private func apply(_ authorization: CaptureAuthorization) {
        switch authorization {
        case .notDetermined: stateStorage = .permission(.notDetermined)
        case .authorized: stateStorage = .cameraReady
        case .denied: stateStorage = .permission(.denied)
        case .restricted: stateStorage = .permission(.restricted)
        }
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
        if snapshot.measurementDraft != nil, snapshot.measurementApproval != .unapproved {
            accepted.insert(.measurement)
        }
        return accepted
    }
}
