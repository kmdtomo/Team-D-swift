import Foundation
import DomainKit

/// The two non-secret endpoints that are permitted in an app build. Credentials
/// and LiveKit API secrets are deliberately acquired from the shared backend at
/// runtime and never belong to this value.
public struct LiveServiceEndpoints: Equatable, Sendable {
    public let backendBaseURL: URL
    public let liveKitURL: URL

    public init(backendBaseURL: URL, liveKitURL: URL) throws {
        guard backendBaseURL.scheme?.lowercased() == "https", backendBaseURL.host != nil,
              backendBaseURL.user == nil, backendBaseURL.password == nil,
              backendBaseURL.query == nil, backendBaseURL.fragment == nil else {
            throw RuntimeCompositionError.invalidBackendBaseURL
        }
        guard liveKitURL.scheme?.lowercased() == "wss", liveKitURL.host != nil,
              liveKitURL.user == nil, liveKitURL.password == nil,
              liveKitURL.query == nil, liveKitURL.fragment == nil else {
            throw RuntimeCompositionError.invalidLiveKitURL
        }
        self.backendBaseURL = backendBaseURL
        self.liveKitURL = liveKitURL
    }
}

public enum RuntimeCompositionError: Error, Equatable, Sendable {
    case invalidBackendBaseURL
    case invalidLiveKitURL
    case missingConfiguredEndpoint
}

/// All HTTP clients that carry session data use this factory. It intentionally
/// has no shared cache, cookie storage, or credential storage.
public enum EphemeralSessionFactory {
    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }
}

public protocol RuntimeProvider: Sendable {
    func start() async throws
}

/// Honest placeholder while the shared LiveKit/backend integration remains
/// unavailable. It is intentionally a failure, never fixture success.
public struct UnavailableLiveRuntimeProvider: RuntimeProvider {
    public init() {}
    public func start() async throws { throw RuntimeProviderAvailabilityError.unavailable }
}

public enum RuntimeProviderAvailabilityError: Error, Equatable, Sendable { case unavailable }

/// Presentation-safe startup state. A live provider failure keeps its live
/// identity and gives the camera flow an explicit Japanese recovery message.
public enum RuntimeStartupState: Equatable, Sendable {
    case ready(CameraFlowMode)
    case liveFailure
    case fixtureFailure
    case configurationFailure(CameraFlowMode)

    public var mode: CameraFlowMode {
        switch self {
        case .ready(let mode): mode
        case .liveFailure: .live
        case .fixtureFailure: .fixture
        case .configurationFailure(let mode): mode
        }
    }

    public var message: String? {
        switch self {
        case .ready: nil
        case .liveFailure: "ライブ接続を利用できません。撮影はこのまま続けられます。"
        case .fixtureFailure: "テストデータの準備を開始できません。"
        case .configurationFailure:
            "アプリの実行モード設定を確認できません。撮影を開始できません。"
        }
    }
}

/// The compiler-selected provider and the bundle mode must agree. A command-line
/// build-setting override must never relabel a live provider as fixture mode.
public enum BuildModeValidator {
    public static func startupFailure(
        compiledMode: CameraFlowMode,
        bundleMode: String?
    ) -> RuntimeStartupState? {
        guard bundleMode == expectedBundleMode(for: compiledMode) else {
            return .configurationFailure(compiledMode)
        }
        return nil
    }

    private static func expectedBundleMode(for mode: CameraFlowMode) -> String {
        switch mode {
        case .fixture: "fixture"
        case .live: "live"
        }
    }
}

public struct RuntimeServiceComposition: Sendable {
    public let mode: CameraFlowMode
    public let endpoints: LiveServiceEndpoints?
    public let session: URLSession?
    private let provider: any RuntimeProvider

    private init(mode: CameraFlowMode, endpoints: LiveServiceEndpoints?, session: URLSession?, provider: any RuntimeProvider) {
        self.mode = mode
        self.endpoints = endpoints
        self.session = session
        self.provider = provider
    }

    public static func fixture(provider: any RuntimeProvider) -> RuntimeServiceComposition {
        RuntimeServiceComposition(mode: .fixture, endpoints: nil, session: nil, provider: provider)
    }

    public static func live(endpoints: LiveServiceEndpoints, provider: any RuntimeProvider) -> RuntimeServiceComposition {
        RuntimeServiceComposition(mode: .live, endpoints: endpoints, session: EphemeralSessionFactory.makeSession(), provider: provider)
    }

    /// Provider errors intentionally propagate. This composition has no fallback
    /// branch, so a failed live startup remains a visible live failure.
    public func start() async throws {
        try await provider.start()
    }

    /// Maps only a live provider failure into a visible live failure. It does
    /// not create, call, or substitute a fixture provider.
    public func startupState() async -> RuntimeStartupState {
        do {
            try await start()
            return .ready(mode)
        } catch {
            return mode == .live ? .liveFailure : .fixtureFailure
        }
    }
}
