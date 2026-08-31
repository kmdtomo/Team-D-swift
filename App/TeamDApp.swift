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

    let mode: CameraFlowMode
    let captureSession: AVCaptureSession?
    let recoveryViewModel: CaptureRecoveryViewModel

    private let sessionID: SessionID
    private let sessionStore: CaptureSessionStore
    private let captureController: CaptureSessionController?
    private let recoveryObserver: AVFoundationRecoveryObserver?
    private let liveForwarder: LiveGuidanceCaptureSampleForwarder?
    private let liveConnection: LiveGuidanceConnection?
    private let orientationState: CaptureOrientationState
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
        let sessionID = try! SessionID(
            dependencies.sessionIdentifiers.makeSessionIdentifier().uuidString
        )
        self.sessionID = sessionID
        let sessionStore = CaptureSessionStore()
        self.sessionStore = sessionStore
        let orientationState = CaptureOrientationState()
        self.orientationState = orientationState

        let assessmentProvider = Self.makeAssessmentProvider(
            baseURL: liveEndpoints?.backendBaseURL
        )
        let submitter = AppCaptureSlotSubmitter(
            store: sessionStore,
            assessmentProvider: assessmentProvider
        )
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
                roomTransport: roomTransport
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
    }

    func requestCameraPermission() async {
        await recoveryViewModel.requestPermission()
        await startLiveCaptureIfAuthorized()
    }

    func recoverCamera() async {
        await recoveryViewModel.recoverCamera()
        await startGuidanceIfCameraIsRunning()
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
        recoveryObserver?.stopObserving()
        liveForwarder?.stop()
        await liveConnection?.leave()
        await captureController?.tearDown()
        try? await sessionStore.endSession()
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
    }

    private static func makeAssessmentProvider(
        baseURL: URL?
    ) -> any ShotAssessmentProviding {
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
        roomTransport: LiveKitRoomTransport
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
                clock: SystemGuidanceEpochMillisecondsClock()
            )
        } catch {
            return nil
        }
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
            CaptureStartView(session: model.captureSession)

            CaptureRecoverySurface(
                model: model.recoveryViewModel,
                onRequestPermission: { await model.requestCameraPermission() },
                onRecoverCamera: { await model.recoverCamera() }
            )

            VStack(spacing: 8) {
                ModeBadge(mode: model.mode)
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

    var body: some View {
        if model.presentation.state.requiresRecoveryOverlay {
            CaptureRecoveryView(
                presentation: model.presentation,
                onRequestPermission: onRequestPermission,
                onRetryCamera: onRecoverCamera,
                onResumeCamera: onRecoverCamera,
                onImport: { await model.importPhoto($0, for: $1) },
                onImportFailure: { await model.recordImportFailure(for: $0) }
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

private struct CaptureStartView: View {
    let session: AVCaptureSession?

    var body: some View {
        ZStack {
            if let session {
                CapturePreview(session: session)
                    .ignoresSafeArea()
            } else {
                Color.black
            }

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

private enum AppCaptureSubmissionError: Error {
    case staleSession
    case unsupportedImageType
    case assessmentUnavailable
    case assessmentFailed
}

/// Shared camera/import ingestion. Imported originals cannot bypass the normal
/// session store or assessment/measurement route, and an unavailable assessor
/// never promotes a slot to accepted state.
private actor AppCaptureSlotSubmitter: CaptureSlotSubmitting {
    private let store: CaptureSessionStore
    private let assessmentProvider: any ShotAssessmentProviding
    private let makeUUID: @Sendable () -> UUID

    init(
        store: CaptureSessionStore,
        assessmentProvider: any ShotAssessmentProviding,
        makeUUID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.store = store
        self.assessmentProvider = assessmentProvider
        self.makeUUID = makeUUID
    }

    func submit(
        _ photo: CapturedPhoto,
        for shot: Shot,
        route: CaptureSlotProcessingRoute,
        sessionID: SessionID
    ) async throws {
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

        switch route {
        case .measurementValidation:
            // T11/T12 own marker and measurement validation. This path stores
            // the same measurement original without fabricating an approval.
            return
        case .shotAssessment(let assessableShot):
            guard assessableShot.rawValue == shot.rawValue else {
                throw AppCaptureSubmissionError.assessmentFailed
            }
            let operation = try ShotAssessmentOperation(
                requestID: RequestID(makeUUID().uuidString),
                imageID: imageID,
                idempotencyKey: IdempotencyKey("assessment-\(imageID.rawValue)"),
                requestedShot: shot,
                originalImage: photo.originalFileData,
                imageContentType: try Self.imageContentType(for: photo.metadata.contentType),
                boundary: MultipartBoundary("teamd-\(makeUUID().uuidString)")
            )
            let outcome = await assessmentProvider.assess(operation)
            try await requireCurrentImage(imageID, shot: shot, sessionID: sessionID)
            switch outcome {
            case .assessment(_, let assessment):
                let assessmentToken = try await store.beginOperation(
                    requestID: RequestID(makeUUID().uuidString),
                    scope: .assessment(assessableShot)
                )
                try await store.commit(
                    .assessment(.init(
                        shot: assessableShot,
                        quality: assessment.quality,
                        issues: Set(assessment.issues),
                        missingShots: Set(assessment.missingShots),
                        // T09-02 owns user-visible acceptance/retry behavior.
                        // AI output alone never accepts or navigates a slot.
                        acceptedByApp: false
                    )),
                    for: assessmentToken
                )
            case .unavailable:
                throw AppCaptureSubmissionError.assessmentUnavailable
            case .failed, .discardedAsStale:
                throw AppCaptureSubmissionError.assessmentFailed
            }
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
