import ContractKit
import Foundation

public enum LiveGuidanceTokenProviderError: Error, Equatable, Sendable {
    case invalidBaseURL
    case invalidResponse
    case invalidContentType
    case unexpectedStatus(Int)
    case transport
    case cancelled
}

public protocol LiveGuidanceTokenHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

/// Ephemeral transport: token responses are not cached and credentials/cookies
/// are not written to shared stores.
public struct URLSessionLiveGuidanceTokenTransport: LiveGuidanceTokenHTTPTransport {
    private let session: URLSession

    public init(session: URLSession) {
        self.session = session
    }

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration)
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

/// Production adapter for the one HTTP request used by live guidance. It calls
/// only `POST /api/livekit-token`; camera images and guidance are never uploaded
/// or polled over HTTP.
public struct URLSessionLiveGuidanceTokenProvider: LiveGuidanceTokenProviding {
    public static let endpointPath = "/api/livekit-token"
    public static let usesGuidancePolling = false

    private let endpoint: URL
    private let transport: any LiveGuidanceTokenHTTPTransport

    public init(
        baseURL: URL,
        transport: any LiveGuidanceTokenHTTPTransport = URLSessionLiveGuidanceTokenTransport(),
        allowsInsecureTestURL: Bool = false
    ) throws {
        guard baseURL.host != nil,
              baseURL.scheme?.lowercased() == "https"
                || (allowsInsecureTestURL && baseURL.scheme?.lowercased() == "http")
        else { throw LiveGuidanceTokenProviderError.invalidBaseURL }
        endpoint = baseURL.appendingPathComponent("api/livekit-token")
        self.transport = transport
    }

    public func fetchToken(for request: LiveKitTokenRequest) async throws -> LiveKitTokenResponse {
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 10
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)

        do {
            let (data, response) = try await transport.data(for: urlRequest)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else {
                throw LiveGuidanceTokenProviderError.invalidResponse
            }
            guard response.statusCode == 200 else {
                throw LiveGuidanceTokenProviderError.unexpectedStatus(response.statusCode)
            }
            guard response.value(forHTTPHeaderField: "Content-Type")?
                .lowercased().split(separator: ";").first == "application/json"
            else { throw LiveGuidanceTokenProviderError.invalidContentType }
            do {
                return try JSONDecoder().decode(LiveKitTokenResponse.self, from: data)
            } catch let error as LiveGuidanceTokenProviderError {
                throw error
            } catch {
                throw LiveGuidanceTokenProviderError.invalidResponse
            }
        } catch is CancellationError {
            throw LiveGuidanceTokenProviderError.cancelled
        } catch let error as LiveGuidanceTokenProviderError {
            throw error
        } catch {
            let error = error as NSError
            if error.domain == NSURLErrorDomain,
               error.code == URLError.cancelled.rawValue {
                throw LiveGuidanceTokenProviderError.cancelled
            }
            throw LiveGuidanceTokenProviderError.transport
        }
    }
}
