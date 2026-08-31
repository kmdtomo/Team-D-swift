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
}
