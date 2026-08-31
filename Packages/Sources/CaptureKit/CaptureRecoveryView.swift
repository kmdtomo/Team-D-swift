import DomainKit
import Foundation

public enum CaptureRecoveryAccessibilityID {
    public static let root = "capture-recovery"
    public static let instruction = "capture-recovery-instruction"
    public static let requestPermission = "capture-recovery-request-permission"
    public static let openSettings = "capture-recovery-open-settings"
    public static let retryCamera = "capture-recovery-retry-camera"
    public static let resumeCamera = "capture-recovery-resume-camera"
    public static let photoPicker = "capture-recovery-photo-picker"
    public static let fileImporter = "capture-recovery-file-importer"
}

public extension CaptureRecoveryAction {
    var localizedLabel: String {
        switch self {
        case .requestCameraPermission: "カメラを許可する"
        case .openSettings: "設定を開く"
        case .selectPhoto(let shot): "\(shot.recoveryLocalizedName)を写真から選ぶ"
        case .retryCamera: "カメラを再開する"
        case .resumeCamera: "撮影を再開する"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .requestCameraPermission: CaptureRecoveryAccessibilityID.requestPermission
        case .openSettings: CaptureRecoveryAccessibilityID.openSettings
        case .selectPhoto: CaptureRecoveryAccessibilityID.photoPicker
        case .retryCamera: CaptureRecoveryAccessibilityID.retryCamera
        case .resumeCamera: CaptureRecoveryAccessibilityID.resumeCamera
        }
    }
}

private extension Shot {
    var recoveryLocalizedName: String {
        switch self {
        case .front: "正面"
        case .back: "背面"
        case .tag: "タグ"
        case .measurement: "採寸"
        }
    }
}

#if os(iOS)
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// Main-actor bridge used by the app composition root. It keeps actor state,
/// current-slot copy, and preserved progress synchronized for SwiftUI without
/// exposing provider diagnostics or image bytes.
@available(iOS 18.0, *)
@MainActor
public final class CaptureRecoveryViewModel: ObservableObject {
    @Published public private(set) var presentation: CaptureRecoveryPresentation
    @Published public private(set) var preservedAcceptedSlots: Set<Shot> = []
    @Published public private(set) var shot: Shot

    public let controller: CaptureRecoveryController

    public init(controller: CaptureRecoveryController, shot: Shot) {
        self.controller = controller
        self.shot = shot
        presentation = CaptureRecoveryCopy.presentation(for: .permission(.notDetermined), shot: shot)
    }

    public func activate() async {
        await controller.refreshPermission()
        await synchronize()
    }

    public func updateShot(_ shot: Shot) async {
        if case .importing(let importingShot) = presentation.state {
            await controller.cancelImport(for: importingShot)
        }
        self.shot = shot
        await synchronize()
    }

    public func requestPermission() async {
        presentation = CaptureRecoveryCopy.presentation(for: .permission(.requesting), shot: shot)
        await controller.requestPermission()
        await synchronize()
    }

    public func recoverCamera() async {
        presentation = CaptureRecoveryCopy.presentation(for: .resuming, shot: shot)
        try? await controller.recoverCamera()
        await synchronize()
    }

    public func importPhoto(_ importer: any CaptureImporting, for shot: Shot) async {
        guard shot == self.shot else { return }
        presentation = CaptureRecoveryCopy.presentation(for: .importing(shot), shot: shot)
        do {
            try await controller.importPhoto(importer, for: shot)
        } catch {
            // The controller maps every expected failure to finite UI state.
        }
        await synchronize()
    }

    public func cancelImport(for shot: Shot) async {
        await controller.cancelImport(for: shot)
        await synchronize()
    }

    public func recordImportFailure(for shot: Shot) async {
        await controller.recordImportFailure(for: shot)
        await synchronize()
    }

    public func receive(_ signal: CaptureLifecycleSignal) async {
        guard await controller.receive(signal) else { return }
        await synchronize()
        switch signal {
        case .interruptionEnded, .enteredForeground:
            presentation = CaptureRecoveryCopy.presentation(for: .resuming, shot: shot)
            try? await controller.recoverCamera()
        case .enteredBackground:
            await controller.suspendCamera()
        case .interrupted, .runtimeError:
            break
        }
        await synchronize()
    }

    public func synchronize() async {
        let expectedShot = shot
        let nextPresentation = await controller.presentation(for: expectedShot)
        let nextAcceptedSlots = await controller.preservedAcceptedSlots()
        guard shot == expectedShot else { return }
        presentation = nextPresentation
        preservedAcceptedSlots = nextAcceptedSlots
    }
}

/// An in-flow recovery panel. It is composed over the current capture step and
/// never introduces a home, tab, tutorial, or import-only navigation path.
@available(iOS 18.0, *)
public struct CaptureRecoveryView: View {
    private let presentation: CaptureRecoveryPresentation
    private let onRequestPermission: @Sendable () async -> Void
    private let onRetryCamera: @Sendable () async -> Void
    private let onResumeCamera: @Sendable () async -> Void
    private let onImport: @Sendable (any CaptureImporting, Shot) async -> Void
    private let onCancelImport: @Sendable (Shot) async -> Void
    private let onImportFailure: @Sendable (Shot) async -> Void

    @Environment(\.openURL) private var openURL
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isFileImporterPresented = false

    public init(
        presentation: CaptureRecoveryPresentation,
        onRequestPermission: @escaping @Sendable () async -> Void,
        onRetryCamera: @escaping @Sendable () async -> Void,
        onResumeCamera: @escaping @Sendable () async -> Void,
        onImport: @escaping @Sendable (any CaptureImporting, Shot) async -> Void,
        onCancelImport: @escaping @Sendable (Shot) async -> Void,
        onImportFailure: @escaping @Sendable (Shot) async -> Void
    ) {
        self.presentation = presentation
        self.onRequestPermission = onRequestPermission
        self.onRetryCamera = onRetryCamera
        self.onResumeCamera = onResumeCamera
        self.onImport = onImport
        self.onCancelImport = onCancelImport
        self.onImportFailure = onImportFailure
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "camera.badge.ellipsis")
                    .font(.system(size: 40))
                    .accessibilityHidden(true)

                Text(presentation.instruction)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier(CaptureRecoveryAccessibilityID.instruction)

                ForEach(Array(presentation.actions.enumerated()), id: \.offset) { _, action in
                    control(for: action)
                }
            }
            .frame(maxWidth: 480)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(.white)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(CaptureRecoveryAccessibilityID.root)
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            selectedPhoto = nil
            guard case .selectPhoto(let shot)? = presentation.actions.first(where: {
                if case .selectPhoto = $0 { return true }
                return false
            }) else { return }
            Task { await onImport(PhotosPickerOriginalImageImporter(item: item), shot) }
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            guard case .selectPhoto(let shot)? = presentation.actions.first(where: {
                if case .selectPhoto = $0 { return true }
                return false
            }) else { return }
            switch result {
            case .success(let urls):
                guard let url = urls.first else {
                    Task { await onCancelImport(shot) }
                    return
                }
                Task { await onImport(FileOriginalImageImporter(fileURL: url), shot) }
            case .failure(let error):
                let cocoaError = error as NSError
                if cocoaError.domain == NSCocoaErrorDomain, cocoaError.code == NSUserCancelledError {
                    Task { await onCancelImport(shot) }
                } else {
                    Task { await onImportFailure(shot) }
                }
            }
        }
    }

    @ViewBuilder
    private func control(for action: CaptureRecoveryAction) -> some View {
        switch action {
        case .requestCameraPermission:
            recoveryButton(label: action.localizedLabel, systemImage: "camera.fill", identifier: action.accessibilityIdentifier) {
                Task { await onRequestPermission() }
            }
        case .openSettings:
            recoveryButton(label: action.localizedLabel, systemImage: "gearshape.fill", identifier: action.accessibilityIdentifier) {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                openURL(url)
            }
        case .retryCamera:
            recoveryButton(label: action.localizedLabel, systemImage: "arrow.clockwise", identifier: action.accessibilityIdentifier) {
                Task { await onRetryCamera() }
            }
        case .resumeCamera:
            recoveryButton(label: action.localizedLabel, systemImage: "play.fill", identifier: action.accessibilityIdentifier) {
                Task { await onResumeCamera() }
            }
        case .selectPhoto(let shot):
            VStack(spacing: 10) {
                PhotosPicker(
                    selection: $selectedPhoto,
                    matching: .images,
                    preferredItemEncoding: .current
                ) {
                    Label(action.localizedLabel, systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier(action.accessibilityIdentifier)
                .accessibilityHint("\(shot.recoveryLocalizedName)の元画像を選び、同じ確認工程へ進みます")

                Button {
                    isFileImporterPresented = true
                } label: {
                    Label("画像ファイルから選ぶ", systemImage: "folder")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier(CaptureRecoveryAccessibilityID.fileImporter)
                .accessibilityHint("\(shot.recoveryLocalizedName)の元画像ファイルを選び、同じ確認工程へ進みます")
            }
        }
    }

    private func recoveryButton(
        label: String,
        systemImage: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier(identifier)
    }
}
#endif
