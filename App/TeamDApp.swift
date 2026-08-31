import APIClient
import AVFoundation
import CaptureKit
import CompositionKit
import ContractKit
import DomainKit
import LiveKitBridge
import SwiftUI
import UIKit

@main
struct TeamDApp: App {
    private let dependencies: CameraFlowDependencies
    private let captureAuthorization: any CaptureAuthorizing
    private let liveEndpoints: LiveServiceEndpoints?
    private let initialRuntimeStartupState: RuntimeStartupState?

    init() {
        #if TEAM_D_FIXTURE && TEAM_D_LIVE
        #error("TeamD build mode must select exactly one of TEAM_D_FIXTURE or TEAM_D_LIVE")
        #elseif TEAM_D_FIXTURE
        let fixtureAuthorization = Self.fixtureAuthorization()
        dependencies = CameraFlowComposition.fixture(
            cameraAuthorization: FixtureRootCameraAuthorizationProvider(status: fixtureAuthorization)
        )
        captureAuthorization = FixtureCaptureAuthorizationProvider(status: fixtureAuthorization)
        liveEndpoints = nil
        initialRuntimeStartupState = BuildModeValidator.startupFailure(
            compiledMode: .fixture,
            bundleMode: Self.configuredMode()
        )
        #elseif TEAM_D_LIVE
        dependencies = CameraFlowComposition.live(
            cameraAuthorization: AVCameraAuthorizationProvider()
        )
        captureAuthorization = AVCaptureAuthorizationProvider()
        if let failure = BuildModeValidator.startupFailure(
            compiledMode: .live,
            bundleMode: Self.configuredMode()
        ) {
            liveEndpoints = nil
            initialRuntimeStartupState = failure
        } else {
            do {
                liveEndpoints = try LiveServiceEndpoints(
                    backendBaseURL: try Self.configuredURL(named: "TeamDBackendBaseURL"),
                    liveKitURL: try Self.configuredURL(named: "TeamDLiveKitURL")
                )
                initialRuntimeStartupState = nil
            } catch {
                liveEndpoints = nil
                initialRuntimeStartupState = .liveFailure
            }
        }
        #else
        #error("TeamD must be built with TEAM_D_FIXTURE or TEAM_D_LIVE")
        #endif
    }

    var body: some Scene {
        WindowGroup {
            CameraFlowRootView(
                dependencies: dependencies,
                captureAuthorization: captureAuthorization,
                liveEndpoints: liveEndpoints,
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

    private static func configuredMode() -> String? {
        Bundle.main.object(forInfoDictionaryKey: "TeamDMode") as? String
    }

    #if TEAM_D_FIXTURE
    /// Fixture-only launch injection used by XCUITest. Production camera code
    /// never reads process arguments or environment values.
    private static func fixtureAuthorization() -> CaptureAuthorization {
        let arguments = ProcessInfo.processInfo.arguments
        guard let keyIndex = arguments.firstIndex(of: "-TeamDUICameraAuthorization"),
              arguments.indices.contains(keyIndex + 1) else { return .authorized }
        switch arguments[keyIndex + 1] {
        case "notDetermined": return .notDetermined
        case "denied": return .denied
        case "restricted": return .restricted
        default: return .authorized
        }
    }
    #endif
}

@MainActor
private final class CameraFlowRootModel: ObservableObject {
    @Published private(set) var runtimeStartupState: RuntimeStartupState?
    @Published private(set) var captureSurfaceState: CaptureCoachSurfaceState
    @Published private(set) var showsMeasurementPreparation = false

    let mode: CameraFlowMode
    let captureSession: AVCaptureSession?
    let recoveryViewModel: CaptureRecoveryViewModel

    private let sessionID: SessionID
    private let sessionStore: CaptureSessionStore
    private let flowState: AppCaptureFlowState
    private let slotSubmitter: AppCaptureSlotSubmitter
    private let captureController: CaptureSessionController?
    private let recoveryObserver: AVFoundationRecoveryObserver?
    private let liveForwarder: LiveGuidanceCaptureSampleForwarder?
    private let liveConnection: LiveGuidanceConnection?
    private let liveOutputReceiver: AppLiveGuidanceOutputReceiver
    private let orientationState: CaptureOrientationState
    private let coachClock: AppCaptureCoachClock
    private var coachPresentation = CaptureCoachPresentation()
    private var latestAgentGuidance: GuidanceDisplayInput?
    private var lastSyncedContext: AppCaptureContext?
    private var guidanceSettleTask: Task<Void, Never>?
    private var hasStarted = false
    private var hasStartedLiveCapture = false

    init(
        dependencies: CameraFlowDependencies,
        captureAuthorization: any CaptureAuthorizing,
        liveEndpoints: LiveServiceEndpoints?,
        initialRuntimeStartupState: RuntimeStartupState?
    ) {
        mode = dependencies.mode
        runtimeStartupState = initialRuntimeStartupState
        captureSurfaceState = Self.initialCaptureSurface(mode: dependencies.mode)
        let sessionID = try! SessionID(
            dependencies.sessionIdentifiers.makeSessionIdentifier().uuidString
        )
        self.sessionID = sessionID
        let sessionStore = CaptureSessionStore()
        self.sessionStore = sessionStore
        let flowState = AppCaptureFlowState()
        self.flowState = flowState
        let orientationState = CaptureOrientationState()
        self.orientationState = orientationState
        coachClock = AppCaptureCoachClock()
        let liveOutputReceiver = AppLiveGuidanceOutputReceiver()
        self.liveOutputReceiver = liveOutputReceiver

        let assessmentProvider = Self.makeAssessmentProvider(
            mode: dependencies.mode,
            baseURL: liveEndpoints?.backendBaseURL
        )
        let submitter = AppCaptureSlotSubmitter(
            store: sessionStore,
            flow: flowState,
            assessmentProvider: assessmentProvider
        )
        slotSubmitter = submitter
        let sessionBoundary = CaptureSessionStoreRecoveryBoundary(store: sessionStore)

        if dependencies.mode == .live {
            let roomTransport = LiveKitRoomTransport()
            let forwarder = LiveGuidanceCaptureSampleForwarder(
                transport: roomTransport,
                orientation: { orientationState.current() }
            )
            let driver = AVFoundationCaptureDriver()
            let controller = CaptureSessionController(
                authorization: captureAuthorization,
                driver: driver,
                analysisSampleObserver: { forwarder.receive($0) }
            )
            let recoveryController = CaptureRecoveryController(
                authorization: captureAuthorization,
                session: sessionBoundary,
                submitter: submitter,
                camera: controller
            )

            captureSession = driver.session
            captureController = controller
            liveForwarder = forwarder
            recoveryObserver = AVFoundationRecoveryObserver()
            liveConnection = Self.makeLiveConnection(
                endpoints: liveEndpoints,
                sessionID: sessionID,
                roomTransport: roomTransport,
                receiver: liveOutputReceiver
            )
            recoveryViewModel = CaptureRecoveryViewModel(
                controller: recoveryController,
                shot: .front
            )
        } else {
            let recoveryController = CaptureRecoveryController(
                authorization: captureAuthorization,
                session: sessionBoundary,
                submitter: submitter,
                camera: FixtureCaptureCamera()
            )
            captureSession = nil
            captureController = nil
            liveForwarder = nil
            recoveryObserver = nil
            liveConnection = nil
            recoveryViewModel = CaptureRecoveryViewModel(
                controller: recoveryController,
                shot: .front
            )
        }
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        await liveOutputReceiver.install { [weak self] output in
            await self?.receiveLiveGuidance(output)
        }
        await flowState.reset()
        latestAgentGuidance = nil
        lastSyncedContext = nil
        coachPresentation = CaptureCoachPresentation()
        do {
            try await sessionStore.beginSession(sessionID)
        } catch {
            runtimeStartupState = mode == .live ? .liveFailure : .fixtureFailure
            return
        }

        if let captureSession, let recoveryObserver {
            recoveryObserver.startObserving(
                session: captureSession,
                viewModel: recoveryViewModel
            )
        }
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        updateOrientation(UIDevice.current.orientation)
        await recoveryViewModel.activate()
        await startLiveCaptureIfAuthorized()
        await refreshCaptureSurface(syncContext: true)
    }

    func requestCameraPermission() async {
        await recoveryViewModel.requestPermission()
        await startLiveCaptureIfAuthorized()
        await refreshCaptureSurface()
    }

    func recoverCamera() async {
        await recoveryViewModel.recoverCamera()
        await startGuidanceIfCameraIsRunning()
        await refreshCaptureSurface(syncContext: true)
    }

    func importPhoto(_ importer: any CaptureImporting, for shot: Shot) async {
        await recoveryViewModel.importPhoto(importer, for: shot)
        await refreshCaptureSurface(syncContext: true)
    }

    func recordImportFailure(for shot: Shot) async {
        await recoveryViewModel.recordImportFailure(for: shot)
        await refreshCaptureSurface()
    }

    func captureCurrentShot() async {
        let snapshot = await flowState.snapshot()
        guard case .capture(let shot) = snapshot.workflow.phase else { return }

        let operation: CaptureFlowOperation
        do {
            operation = try await flowState.beginCapture(for: shot)
        } catch {
            return
        }
        latestAgentGuidance = nil
        coachPresentation = CaptureCoachPresentation()
        await refreshCaptureSurface()

        do {
            let photo: CapturedPhoto
            if mode == .fixture {
                photo = try Self.fixtureCapturedPhoto()
            } else {
                guard let captureController else {
                    _ = await flowState.captureFailed(for: operation)
                    await refreshCaptureSurface()
                    return
                }
                photo = try await captureController.capturePhoto()
            }
            try await slotSubmitter.submitCapturedPhoto(
                photo,
                for: shot,
                operation: operation,
                sessionID: sessionID
            )
        } catch {
            _ = await flowState.captureFailed(for: operation)
        }
        await refreshCaptureSurface(syncContext: true)
    }

    func retryCurrentAssessment() async {
        let snapshot = await flowState.snapshot()
        guard case .retryAssessment(let shot) = snapshot.recovery else { return }
        latestAgentGuidance = nil
        coachPresentation = CaptureCoachPresentation()
        await slotSubmitter.retryAssessment(for: shot, sessionID: sessionID)
        await refreshCaptureSurface(syncContext: true)
    }

    func retakeAcceptedShot(_ shot: Shot) async {
        let snapshot = await flowState.snapshot()
        guard snapshot.workflow.acceptedSlots.contains(shot),
              let assessableShot = AssessableShot(rawValue: shot.rawValue) else { return }
        let storePrepared: Bool
        do {
            try await sessionStore.retake(shot)
            storePrepared = true
        } catch {
            // CaptureSessionStore switches metadata before derived-byte cleanup.
            // A cleanup error is therefore still a valid retake boundary when
            // the app-owned acceptance record is already gone.
            let storeSnapshot = await sessionStore.snapshot()
            storePrepared = storeSnapshot?.sessionID == sessionID
                && storeSnapshot?.assessments[assessableShot] == nil
        }
        guard storePrepared else { return }
        do {
            try await flowState.prepareRetake(of: shot)
            latestAgentGuidance = nil
            coachPresentation = CaptureCoachPresentation()
            await refreshCaptureSurface(syncContext: true)
        } catch {
            runtimeStartupState = mode == .live ? .liveFailure : .fixtureFailure
        }
    }

    func updateOrientation(_ deviceOrientation: UIDeviceOrientation) {
        let orientation: CaptureVideoOrientation?
        switch deviceOrientation {
        case .portrait: orientation = .portrait
        case .portraitUpsideDown: orientation = .portraitUpsideDown
        case .landscapeLeft: orientation = .landscapeRight
        case .landscapeRight: orientation = .landscapeLeft
        case .faceUp, .faceDown, .unknown: orientation = nil
        @unknown default: orientation = nil
        }
        if let orientation { orientationState.update(orientation) }
    }

    func stop() async {
        guard hasStarted else { return }
        hasStarted = false
        hasStartedLiveCapture = false
        guidanceSettleTask?.cancel()
        guidanceSettleTask = nil
        recoveryObserver?.stopObserving()
        liveForwarder?.stop()
        await liveConnection?.leave()
        await liveOutputReceiver.install(nil)
        await captureController?.tearDown()
        await slotSubmitter.clearSession()
        try? await sessionStore.endSession()
        latestAgentGuidance = nil
        lastSyncedContext = nil
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    private func startLiveCaptureIfAuthorized() async {
        guard mode == .live, !hasStartedLiveCapture else { return }
        guard case .cameraReady = recoveryViewModel.presentation.state else { return }
        guard let captureController else { return }
        do {
            try await captureController.start()
            hasStartedLiveCapture = true
            await startGuidanceIfCameraIsRunning()
        } catch {
            await recoveryViewModel.receive(.runtimeError)
        }
    }

    private func startGuidanceIfCameraIsRunning() async {
        guard mode == .live else { return }
        guard let captureController, await captureController.state == .running else { return }
        await liveConnection?.join()
        await refreshCaptureSurface(syncContext: true)
    }

    private static func makeAssessmentProvider(
        mode: CameraFlowMode,
        baseURL: URL?
    ) -> any ShotAssessmentProviding {
        if mode == .fixture {
            return FixtureShotAssessmentProvider()
        }
        let fallbackURL = URL(string: "https://fixture.invalid")!
        do {
            let backend = try BackendAPIClient(
                baseURL: baseURL ?? fallbackURL,
                session: EphemeralSessionFactory.makeSession()
            )
            let liveAvailability: ShotAssessmentServiceAvailability =
                baseURL == nil ? .liveUnavailable : .liveAvailable
            return ShotAssessmentClient(
                backend: backend,
                availability: liveAvailability,
                wireContract: .upstreamA25A854
            )
        } catch {
            return UnavailableShotAssessmentProvider()
        }
    }

    private static func makeLiveConnection(
        endpoints: LiveServiceEndpoints?,
        sessionID: SessionID,
        roomTransport: LiveKitRoomTransport,
        receiver: any LiveGuidanceConnectionOutputReceiving
    ) -> LiveGuidanceConnection? {
        guard let endpoints else { return nil }
        do {
            return try LiveGuidanceConnection(
                sessionID: sessionID.rawValue,
                currentShot: .front,
                tokenProvider: try URLSessionLiveGuidanceTokenProvider(
                    baseURL: endpoints.backendBaseURL
                ),
                transport: roomTransport,
                clock: SystemGuidanceEpochMillisecondsClock(),
                receiver: receiver
            )
        } catch {
            return nil
        }
    }

    private func receiveLiveGuidance(_ output: LiveGuidanceConnectionOutput) async {
        guard case .guidance(let delivery) = output else { return }
        let flow = await flowState.snapshot()
        guard flow.activity == .idle,
              flow.workflow.phase == .capture(delivery.shot) else { return }
        latestAgentGuidance = delivery.display
        await refreshCaptureSurface()

        guidanceSettleTask?.cancel()
        guidanceSettleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled else { return }
            await self?.refreshCaptureSurface()
        }
    }

    private func refreshCaptureSurface(syncContext: Bool = false) async {
        let flow = await flowState.snapshot()
        if captureSurfaceState.coach.shot != flow.currentShot {
            latestAgentGuidance = nil
            coachPresentation = CaptureCoachPresentation()
        }

        if recoveryViewModel.shot != flow.currentShot {
            await recoveryViewModel.updateShot(flow.currentShot)
        } else {
            await recoveryViewModel.synchronize()
        }

        if flow.recovery != .none {
            latestAgentGuidance = nil
            coachPresentation = CaptureCoachPresentation()
        }

        let connectionSnapshot = await liveConnection?.snapshot()
        let connection = connectionSnapshot?.guidanceConnection ?? .disconnected
        let cameraAvailable: Bool
        if mode == .fixture {
            cameraAvailable = recoveryViewModel.presentation.state.isCameraReady
        } else {
            let controllerIsRunning = await captureController?.state == .running
            cameraAvailable = recoveryViewModel.presentation.state.isCameraReady
                && controllerIsRunning
        }
        let input = CaptureCoachInput(
            shot: flow.currentShot,
            acceptedShots: flow.workflow.acceptedSlots,
            agentGuidance: latestAgentGuidance,
            localQualityHint: nil,
            connection: connection,
            isCameraTechnicallyAvailable: cameraAvailable
                && flow.workflow.phase != .measurementPrep,
            isCaptureInFlight: flow.isCaptureInFlight,
            isRetake: flow.recovery.isRetake
        )
        if let state = try? coachPresentation.reduce(input, clock: coachClock) {
            captureSurfaceState = .init(
                coach: state,
                recoveryControl: flow.recovery.coachControl,
                isFixture: mode == .fixture
            )
        }
        showsMeasurementPreparation = flow.workflow.phase == .measurementPrep

        let context = AppCaptureContext(
            currentShot: flow.currentShot,
            acceptedShots: flow.workflow.acceptedSlots
        )
        if mode == .live, syncContext || context != lastSyncedContext {
            await liveConnection?.updateCaptureContext(
                currentShot: context.currentShot,
                acceptedShots: context.acceptedShots
            )
            lastSyncedContext = context
        }
    }

    private static func initialCaptureSurface(mode: CameraFlowMode) -> CaptureCoachSurfaceState {
        .init(
            coach: .init(
                input: .init(
                    shot: .front,
                    connection: .disconnected,
                    isCameraTechnicallyAvailable: false,
                    isCaptureInFlight: false
                ),
                instruction: nil,
                announcementID: 0
            ),
            isFixture: mode == .fixture
        )
    }

    private static func fixtureCapturedPhoto() throws -> CapturedPhoto {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        let image = renderer.image { context in
            UIColor(white: 0.45, alpha: 1).setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        guard let data = image.jpegData(compressionQuality: 1) else {
            throw AppCaptureSubmissionError.unsupportedImageType
        }
        return .init(
            originalFileData: data,
            metadata: .init(
                contentType: "image/jpeg",
                orientation: 1,
                colorSpaceName: "RGB",
                pixelWidth: 8,
                pixelHeight: 8
            )
        )
    }
}

/// The app's single camera-first root. Recovery is layered on the active shot;
/// no home, tab, tutorial, or import-only destination is introduced.
private struct CameraFlowRootView: View {
    @StateObject private var model: CameraFlowRootModel

    init(
        dependencies: CameraFlowDependencies,
        captureAuthorization: any CaptureAuthorizing,
        liveEndpoints: LiveServiceEndpoints? = nil,
        initialRuntimeStartupState: RuntimeStartupState? = nil
    ) {
        _model = StateObject(wrappedValue: CameraFlowRootModel(
            dependencies: dependencies,
            captureAuthorization: captureAuthorization,
            liveEndpoints: liveEndpoints,
            initialRuntimeStartupState: initialRuntimeStartupState
        ))
    }

    var body: some View {
        ZStack(alignment: .top) {
            GeometryReader { geometry in
                CaptureCoachView(
                    state: model.captureSurfaceState,
                    onShutter: { Task { await model.captureCurrentShot() } },
                    onRetry: { Task { await model.retryCurrentAssessment() } },
                    onRetake: { Task { await model.captureCurrentShot() } }
                ) {
                    CaptureStartPreview(session: model.captureSession)
                } guide: {
                    CaptureGuideSurface(
                        shot: model.captureSurfaceState.coach.shot,
                        size: geometry.size,
                        safeAreaInsets: geometry.safeAreaInsets
                    )
                }
            }

            if model.showsMeasurementPreparation {
                MeasurementPreparationSurface(
                    onRetake: { shot in
                        Task { await model.retakeAcceptedShot(shot) }
                    }
                )
            }

            CaptureRecoverySurface(
                model: model.recoveryViewModel,
                onRequestPermission: { await model.requestCameraPermission() },
                onRecoverCamera: { await model.recoverCamera() },
                onImport: { await model.importPhoto($0, for: $1) },
                onImportFailure: { await model.recordImportFailure(for: $0) }
            )

            if let message = model.runtimeStartupState?.message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(12)
                    .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.top, 12)
                    .accessibilityIdentifier("live-startup-error")
            }
        }
        .background(Color.black.ignoresSafeArea())
        .task { await model.start() }
        .onDisappear { Task { await model.stop() } }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            model.updateOrientation(UIDevice.current.orientation)
        }
    }
}

private struct CaptureRecoverySurface: View {
    @ObservedObject var model: CaptureRecoveryViewModel
    let onRequestPermission: @Sendable () async -> Void
    let onRecoverCamera: @Sendable () async -> Void
    let onImport: @Sendable (any CaptureImporting, Shot) async -> Void
    let onImportFailure: @Sendable (Shot) async -> Void

    var body: some View {
        if model.presentation.state.requiresRecoveryOverlay {
            CaptureRecoveryView(
                presentation: model.presentation,
                onRequestPermission: onRequestPermission,
                onRetryCamera: onRecoverCamera,
                onResumeCamera: onRecoverCamera,
                onImport: onImport,
                onImportFailure: onImportFailure
            )
            .padding(.horizontal, 16)
            .padding(.top, 72)
        }
    }
}

private extension CaptureRecoveryState {
    var requiresRecoveryOverlay: Bool {
        switch self {
        case .cameraReady, .permission(.authorized): false
        default: true
        }
    }
}

private struct CaptureStartPreview: View {
    let session: AVCaptureSession?

    var body: some View {
        if let session {
            CapturePreview(session: session)
        } else {
            Color.black
        }
    }
}

private struct CaptureGuideSurface: View {
    let shot: Shot
    let size: CGSize
    let safeAreaInsets: EdgeInsets

    var body: some View {
        if let layout {
            FixedCaptureGuideOverlay(layout: layout)
        }
    }

    private var layout: FixedGuideLayout? {
        guard let imageSize = try? ImageSize(width: 3, height: 4),
              let previewSize = try? ImageSize(
                width: Double(size.width),
                height: Double(size.height)
              ),
              let geometry = try? PreviewImageGeometry(
                imageSize: imageSize,
                previewSize: previewSize,
                contentMode: .aspectFill
              ),
              let insets = try? GuideSafeAreaInsets(
                top: Double(safeAreaInsets.top),
                leading: Double(safeAreaInsets.leading),
                bottom: Double(safeAreaInsets.bottom),
                trailing: Double(safeAreaInsets.trailing)
              ) else { return nil }
        return try? FixedGuideLayout(
            shot: shot,
            previewGeometry: geometry,
            uprightOrientation: .up,
            safeAreaInsets: insets
        )
    }
}

private struct MeasurementPreparationSurface: View {
    let onRetake: (Shot) -> Void

    private let items = [
        "Tシャツの背面を上にする",
        "襟・袖・裾を広げ、しわと折れを伸ばす",
        "無地でTシャツと見分けやすい床に置く",
        "50mmマーカーを100%で印刷し、定規で確認する",
        "同じ平面の右下へ、衣類から30mm以上離して置く",
        "真上から衣類とマーカー全体を写す",
    ]

    var body: some View {
        VStack {
            Spacer(minLength: 88)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("採寸の準備")
                        .font(.title2.weight(.semibold))
                    Text("4/4 採寸写真の前に確認してください")
                        .font(.headline)
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(index + 1)")
                                .font(.caption.weight(.bold))
                                .frame(width: 24, height: 24)
                                .background(.white.opacity(0.18), in: Circle())
                            Text(item)
                                .font(.body)
                        }
                    }
                    Menu {
                        Button("正面を撮り直す") { onRetake(.front) }
                        Button("背面を撮り直す") { onRetake(.back) }
                        Button("タグを撮り直す") { onRetake(.tag) }
                    } label: {
                        Label("以前の写真を撮り直す", systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityHint("受理済みの写真を1枚選び、ほかの進捗を残して撮り直します")
                }
                .frame(maxWidth: 520, alignment: .leading)
                .padding(20)
                .foregroundStyle(.white)
                .background(.black.opacity(0.84), in: RoundedRectangle(cornerRadius: 20))
                .padding(.horizontal, 16)
            }
            .frame(maxHeight: 520)
            Spacer(minLength: 100)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("measurement-preparation")
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

private struct FixtureRootCameraAuthorizationProvider: CameraAuthorizationProviding {
    let status: CaptureAuthorization

    func authorizationStatus() -> CameraAuthorizationStatus { status.rootStatus }
    func requestAuthorization() async -> CameraAuthorizationStatus { status.rootStatus }
}

private struct FixtureCaptureAuthorizationProvider: CaptureAuthorizing {
    let status: CaptureAuthorization

    func status() async -> CaptureAuthorization { status }
    func requestAccess() async -> CaptureAuthorization { status }
}

private extension CaptureAuthorization {
    var rootStatus: CameraAuthorizationStatus {
        switch self {
        case .notDetermined: .notDetermined
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        }
    }
}

private actor FixtureCaptureCamera: CaptureCameraRecovering {
    func suspendCamera() async {}
    func recoverCamera() async throws {}
}

private final class CaptureOrientationState: @unchecked Sendable {
    private let lock = NSLock()
    private var orientation: CaptureVideoOrientation = .portrait

    func current() -> CaptureVideoOrientation {
        lock.lock()
        defer { lock.unlock() }
        return orientation
    }

    func update(_ value: CaptureVideoOrientation) {
        lock.lock()
        orientation = value
        lock.unlock()
    }
}

private actor AppCaptureFlowState {
    private var coordinator = CaptureFlowCoordinator()

    func snapshot() -> CaptureFlowSnapshot { coordinator.snapshot }

    func reset() { coordinator = CaptureFlowCoordinator() }

    func beginCapture(for shot: Shot) throws -> CaptureFlowOperation {
        try coordinator.beginCapture(for: shot)
    }

    func originalStored(for operation: CaptureFlowOperation) throws {
        try coordinator.originalStored(for: operation)
    }

    func captureFailed(for operation: CaptureFlowOperation) -> Bool {
        coordinator.captureFailed(for: operation)
    }

    func assessmentFailed(for operation: CaptureFlowOperation) throws -> Bool {
        try coordinator.assessmentFailed(for: operation)
    }

    func beginAssessmentRetry(for shot: AssessableShot) throws -> CaptureFlowOperation {
        try coordinator.beginAssessmentRetry(for: shot)
    }

    func prepareRetake(of shot: Shot) throws {
        try coordinator.prepareRetake(of: shot)
    }

    func resolveAssessment(
        _ evidence: CaptureAssessmentEvidence,
        for operation: CaptureFlowOperation
    ) throws -> CaptureAssessmentResolution {
        try coordinator.resolveAssessment(evidence, for: operation)
    }
}

private actor AppLiveGuidanceOutputReceiver: LiveGuidanceConnectionOutputReceiving {
    private var handler: (@Sendable (LiveGuidanceConnectionOutput) async -> Void)?

    func install(
        _ handler: (@Sendable (LiveGuidanceConnectionOutput) async -> Void)?
    ) {
        self.handler = handler
    }

    func receive(_ output: LiveGuidanceConnectionOutput) async {
        await handler?(output)
    }
}

private struct AppCaptureCoachClock: CaptureCoachPresentationClock {
    func nowMilliseconds() -> Int64 {
        Int64(ProcessInfo.processInfo.systemUptime * 1_000)
    }
}

private struct AppCaptureContext: Equatable {
    let currentShot: Shot
    let acceptedShots: Set<Shot>
}

private extension CaptureRecoveryState {
    var isCameraReady: Bool {
        switch self {
        case .cameraReady, .permission(.authorized): true
        default: false
        }
    }
}

private extension CaptureFlowRecovery {
    var coachControl: CaptureCoachRecoveryControl {
        switch self {
        case .none: .none
        case .retryAssessment: .retry
        case .retake: .retake
        }
    }

    var isRetake: Bool {
        if case .retake = self { return true }
        return false
    }
}

private enum AppCaptureSubmissionError: Error {
    case staleSession
    case unsupportedImageType
    case assessmentFailed
}

/// Shared camera/import ingestion. Imported originals cannot bypass the normal
/// session store or assessment/measurement route, and an unavailable assessor
/// never promotes a slot to accepted state.
private actor AppCaptureSlotSubmitter: CaptureSlotSubmitting {
    private let store: CaptureSessionStore
    private let flow: AppCaptureFlowState
    private let assessmentProvider: any ShotAssessmentProviding
    private let makeUUID: @Sendable () -> UUID
    private var retryInputs: [AssessableShot: AssessmentInput] = [:]
    private var activeAssessmentRequestID: RequestID?

    private struct AssessmentInput: Sendable {
        let shot: AssessableShot
        let imageID: ImageID
        let originalImage: Data
        let imageContentType: ImageContentType
    }

    init(
        store: CaptureSessionStore,
        flow: AppCaptureFlowState,
        assessmentProvider: any ShotAssessmentProviding,
        makeUUID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.store = store
        self.flow = flow
        self.assessmentProvider = assessmentProvider
        self.makeUUID = makeUUID
    }

    func submit(
        _ photo: CapturedPhoto,
        for shot: Shot,
        route: CaptureSlotProcessingRoute,
        sessionID: SessionID
    ) async throws {
        let operation = try await flow.beginCapture(for: shot)
        try await submitCapturedPhoto(
            photo,
            for: shot,
            route: route,
            operation: operation,
            sessionID: sessionID
        )
    }

    func submitCapturedPhoto(
        _ photo: CapturedPhoto,
        for shot: Shot,
        operation: CaptureFlowOperation,
        sessionID: SessionID
    ) async throws {
        try await submitCapturedPhoto(
            photo,
            for: shot,
            route: .init(shot: shot),
            operation: operation,
            sessionID: sessionID
        )
    }

    func retryAssessment(for shot: AssessableShot, sessionID: SessionID) async {
        guard let input = retryInputs[shot] else { return }
        var retryOperation: CaptureFlowOperation?
        do {
            try await requireSession(sessionID)
            try await requireCurrentImage(
                input.imageID,
                shot: shot.captureShot,
                sessionID: sessionID
            )
            let operation = try await flow.beginAssessmentRetry(for: shot)
            retryOperation = operation
            try await performAssessment(
                input,
                flowOperation: operation,
                sessionID: sessionID
            )
        } catch {
            if let operation = retryOperation {
                _ = try? await flow.assessmentFailed(for: operation)
            }
        }
    }

    func clearSession() async {
        if let activeAssessmentRequestID {
            await assessmentProvider.cancel(requestID: activeAssessmentRequestID)
        }
        activeAssessmentRequestID = nil
        retryInputs.removeAll(keepingCapacity: false)
    }

    private func submitCapturedPhoto(
        _ photo: CapturedPhoto,
        for shot: Shot,
        route: CaptureSlotProcessingRoute,
        operation: CaptureFlowOperation,
        sessionID: SessionID
    ) async throws {
        do {
            try await requireSession(sessionID)
            let imageID = try ImageID(makeUUID().uuidString)
            let captureToken = try await store.beginOperation(
                requestID: RequestID(makeUUID().uuidString),
                scope: .capture(shot)
            )
            try await store.storeImage(
                photo.originalFileData,
                artifact: .original(shot, imageID),
                for: captureToken
            )
            try await requireCurrentImage(imageID, shot: shot, sessionID: sessionID)
            try await flow.originalStored(for: operation)

            switch route {
            case .measurementValidation:
                // T11/T12 own marker validation and measurement completion.
                return
            case .shotAssessment(let assessableShot):
                guard assessableShot.rawValue == shot.rawValue else {
                    throw AppCaptureSubmissionError.assessmentFailed
                }
                let input = AssessmentInput(
                    shot: assessableShot,
                    imageID: imageID,
                    originalImage: photo.originalFileData,
                    imageContentType: try Self.imageContentType(
                        for: photo.metadata.contentType
                    )
                )
                retryInputs[assessableShot] = input
                try await performAssessment(
                    input,
                    flowOperation: operation,
                    sessionID: sessionID
                )
            }
        } catch {
            let snapshot = await flow.snapshot()
            switch snapshot.activity {
            case .capturing(let current) where current == operation:
                _ = await flow.captureFailed(for: operation)
            case .assessing(let current) where current == operation:
                _ = try? await flow.assessmentFailed(for: operation)
            default:
                break
            }
            throw error
        }
    }

    private func performAssessment(
        _ input: AssessmentInput,
        flowOperation: CaptureFlowOperation,
        sessionID: SessionID
    ) async throws {
        let requestID = try RequestID(makeUUID().uuidString)
        let operation = try ShotAssessmentOperation(
            requestID: requestID,
            imageID: input.imageID,
            idempotencyKey: IdempotencyKey(
                "assessment-\(input.imageID.rawValue)-\(flowOperation.sequence)"
            ),
            requestedShot: input.shot.captureShot,
            originalImage: input.originalImage,
            imageContentType: input.imageContentType,
            boundary: MultipartBoundary("teamd-\(makeUUID().uuidString)")
        )
        activeAssessmentRequestID = requestID
        let outcome = await assessmentProvider.assess(operation)
        if activeAssessmentRequestID == requestID {
            activeAssessmentRequestID = nil
        }
        try await requireCurrentImage(
            input.imageID,
            shot: input.shot.captureShot,
            sessionID: sessionID
        )

        switch outcome {
        case .assessment(let descriptor, let assessment):
            guard descriptor.imageID == input.imageID,
                  await flow.snapshot().activity == .assessing(flowOperation) else {
                return
            }
            let evidence = CaptureAssessmentEvidence(
                requestedShot: input.shot,
                shotType: assessment.shotType,
                quality: assessment.quality,
                issues: Set(assessment.issues),
                missingShots: Set(assessment.missingShots),
                advisoryNextAction: assessment.nextAction
            )
            let acceptedByApp = CaptureFlowCoordinator.accepts(evidence)
            let assessmentToken = try await store.beginOperation(
                requestID: RequestID(makeUUID().uuidString),
                scope: .assessment(input.shot)
            )
            try await store.commit(
                .assessment(.init(
                    shot: input.shot,
                    quality: assessment.quality,
                    issues: Set(assessment.issues),
                    missingShots: Set(assessment.missingShots),
                    acceptedByApp: acceptedByApp
                )),
                for: assessmentToken
            )
            _ = try await flow.resolveAssessment(evidence, for: flowOperation)
            retryInputs[input.shot] = nil

        case .unavailable:
            _ = try await flow.assessmentFailed(for: flowOperation)
        case .failed, .discardedAsStale:
            _ = try await flow.assessmentFailed(for: flowOperation)
        }
    }

    private func requireSession(_ sessionID: SessionID) async throws {
        guard await store.snapshot()?.sessionID == sessionID else {
            throw AppCaptureSubmissionError.staleSession
        }
    }

    private func requireCurrentImage(
        _ imageID: ImageID,
        shot: Shot,
        sessionID: SessionID
    ) async throws {
        guard let snapshot = await store.snapshot(),
              snapshot.sessionID == sessionID,
              snapshot.originals[shot] == imageID else {
            throw AppCaptureSubmissionError.staleSession
        }
    }

    private static func imageContentType(for value: String?) throws -> ImageContentType {
        switch value?.lowercased() {
        case "image/jpeg", "image/jpg", "public.jpeg": .jpeg
        case "image/png", "public.png": .png
        case "image/heic", "image/heif", "public.heic", "public.heif": .heic
        default: throw AppCaptureSubmissionError.unsupportedImageType
        }
    }
}

private actor FixtureShotAssessmentProvider: ShotAssessmentProviding {
    func assess(_ operation: ShotAssessmentOperation) async -> ShotAssessmentOutcome {
        let descriptor = ShotAssessmentRequestDescriptor(operation: operation)
        guard let shotType = ShotType(rawValue: operation.requestedShot.rawValue) else {
            return .failed(.init(descriptor: descriptor, reason: .invalidResponse))
        }
        return .assessment(
            descriptor,
            .init(
                shotType: shotType,
                quality: .ok,
                issues: [],
                missingShots: operation.requestedShot.fixtureFutureShots,
                nextAction: operation.requestedShot == .tag ? .complete : .requestNext
            )
        )
    }

    func cancel(requestID: RequestID) async { _ = requestID }
}

private extension AssessableShot {
    var captureShot: Shot {
        switch self {
        case .front: .front
        case .back: .back
        case .tag: .tag
        }
    }

    var fixtureFutureShots: [AssessableShot] {
        switch self {
        case .front: [.back, .tag]
        case .back: [.tag]
        case .tag: []
        }
    }
}

private actor UnavailableShotAssessmentProvider: ShotAssessmentProviding {
    func assess(_ operation: ShotAssessmentOperation) async -> ShotAssessmentOutcome {
        let descriptor = ShotAssessmentRequestDescriptor(operation: operation)
        return .unavailable(.init(
            descriptor: descriptor,
            reason: .liveEndpointUnavailable
        ))
    }

    func cancel(requestID: RequestID) async { _ = requestID }
}

#Preview("Fixture: front 1/4") {
    CameraFlowRootView(
        dependencies: CameraFlowComposition.fixture(),
        captureAuthorization: FixtureCaptureAuthorizationProvider(status: .authorized)
    )
}
