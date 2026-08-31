import AVFoundation
import SwiftUI
import CompositionKit
import DomainKit

@main
struct TeamDApp: App {
    private let dependencies: CameraFlowDependencies
    private let runtimeComposition: RuntimeServiceComposition?
    private let initialRuntimeStartupState: RuntimeStartupState?

    init() {
        #if TEAM_D_FIXTURE && TEAM_D_LIVE
        #error("TeamD build mode must select exactly one of TEAM_D_FIXTURE or TEAM_D_LIVE")
        #elseif TEAM_D_FIXTURE
        dependencies = CameraFlowComposition.fixture()
        runtimeComposition = nil
        initialRuntimeStartupState = nil
        #elseif TEAM_D_LIVE
        dependencies = CameraFlowComposition.live(
            cameraAuthorization: AVCameraAuthorizationProvider()
        )
        do {
            let endpoints = try LiveServiceEndpoints(
                backendBaseURL: try Self.configuredURL(named: "TeamDBackendBaseURL"),
                liveKitURL: try Self.configuredURL(named: "TeamDLiveKitURL")
            )
            runtimeComposition = .live(endpoints: endpoints, provider: UnavailableLiveRuntimeProvider())
            initialRuntimeStartupState = nil
        } catch {
            runtimeComposition = nil
            initialRuntimeStartupState = .liveFailure
        }
        #else
        #error("TeamD must be built with TEAM_D_FIXTURE or TEAM_D_LIVE")
        #endif
    }

    var body: some Scene {
        WindowGroup {
            CameraFlowRootView(
                dependencies: dependencies,
                runtimeComposition: runtimeComposition,
                initialRuntimeStartupState: initialRuntimeStartupState
            )
        }
    }

    private static func configuredURL(named key: String) throws -> URL {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              let url = URL(string: value) else {
            throw RuntimeCompositionError.missingConfiguredEndpoint
        }
        return url
    }
}

@MainActor
private final class CameraFlowRootModel: ObservableObject {
    @Published private(set) var authorizationStatus: CameraAuthorizationStatus
    @Published private(set) var runtimeStartupState: RuntimeStartupState?

    private let cameraAuthorization: any CameraAuthorizationProviding
    private let runtimeComposition: RuntimeServiceComposition?

    init(cameraAuthorization: any CameraAuthorizationProviding, runtimeComposition: RuntimeServiceComposition?, initialRuntimeStartupState: RuntimeStartupState?) {
        self.cameraAuthorization = cameraAuthorization
        self.runtimeComposition = runtimeComposition
        self.runtimeStartupState = initialRuntimeStartupState
        authorizationStatus = cameraAuthorization.authorizationStatus()
    }

    func requestCameraAccess() async {
        authorizationStatus = await cameraAuthorization.requestAuthorization()
    }

    func startRuntimeIfNeeded() async {
        guard let runtimeComposition, runtimeStartupState == nil else { return }
        runtimeStartupState = await runtimeComposition.startupState()
    }
}

/// The app's single camera-first root. Later tasks add capture-session ownership
/// and fixed guides without introducing another application-level destination.
private struct CameraFlowRootView: View {
    private let mode: CameraFlowMode
    @StateObject private var model: CameraFlowRootModel

    init(dependencies: CameraFlowDependencies, runtimeComposition: RuntimeServiceComposition? = nil, initialRuntimeStartupState: RuntimeStartupState? = nil) {
        mode = dependencies.mode
        _model = StateObject(wrappedValue: CameraFlowRootModel(
            cameraAuthorization: dependencies.cameraAuthorization,
            runtimeComposition: runtimeComposition,
            initialRuntimeStartupState: initialRuntimeStartupState
        ))
    }

    var body: some View {
        ZStack(alignment: .top) {
            Group {
                switch CameraFlowEntry.route(for: model.authorizationStatus) {
                case .captureFront:
                    CaptureStartView()
                case .requestPermission:
                    CameraPermissionView(
                        title: "カメラを使って撮影を始めます",
                        message: "正面・背面・タグ・採寸を、この撮影フローで順に撮影します。",
                        actionTitle: "カメラを許可する",
                        action: { await model.requestCameraAccess() }
                    )
                case .permissionDenied:
                    CameraPermissionView(
                        title: "カメラの許可が必要です",
                        message: "カメラが許可されていないため、撮影を開始できません。許可が利用可能になるまで、この撮影フローを表示します。",
                        actionTitle: nil,
                        action: nil
                    )
                case .permissionRestricted:
                    CameraPermissionView(
                        title: "この端末ではカメラを使えません",
                        message: "カメラの利用が制限されているため、撮影を開始できません。この撮影フローは開いたままです。",
                        actionTitle: nil,
                        action: nil
                    )
                }
            }
            VStack(spacing: 8) {
                ModeBadge(mode: mode)
                if let message = model.runtimeStartupState?.message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("live-startup-error")
                }
            }
            .padding(.top, 12)
        }
        .background(Color.black.ignoresSafeArea())
        .task { await model.startRuntimeIfNeeded() }
    }
}

private struct CaptureStartView: View {
    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 20) {
                Spacer()

                Text("正面 1/4")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("capture-front-1-of-4")

                Text("Tシャツ全体が入るように置いてください")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .accessibilityLabel("撮影の案内。Tシャツ全体が入るように置いてください")

                Spacer()

            }
            .padding(.top)
            .padding(.bottom, 28)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct ModeBadge: View {
    let mode: CameraFlowMode

    var body: some View {
        Text(mode == .fixture ? "テストデータ" : "Live モード")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: Capsule())
            .accessibilityIdentifier(mode == .fixture ? "fixture-mode-badge" : "live-mode-badge")
    }
}

private struct CameraPermissionView: View {
    let title: String
    let message: String
    let actionTitle: String?
    let action: (() async -> Void)?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Spacer(minLength: 72)
                Image(systemName: "camera")
                    .font(.system(size: 42))
                    .foregroundStyle(.white)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("camera-permission-state")
                Text(message)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.86))
                    .multilineTextAlignment(.center)
                if let actionTitle, let action {
                    Button(actionTitle) {
                        Task { await action() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("request-camera-permission")
                }
                Spacer(minLength: 72)
            }
            .frame(maxWidth: 480)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct AVCameraAuthorizationProvider: CameraAuthorizationProviding {
    func authorizationStatus() -> CameraAuthorizationStatus {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined: .notDetermined
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .restricted
        }
    }

    func requestAuthorization() async -> CameraAuthorizationStatus {
        _ = await AVCaptureDevice.requestAccess(for: .video)
        return authorizationStatus()
    }
}

#Preview("Fixture: front 1/4") {
    CameraFlowRootView(dependencies: CameraFlowComposition.fixture())
}
