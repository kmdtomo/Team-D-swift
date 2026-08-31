import Foundation
import ContractKit
import DomainKit

public enum APIClientModule {}
public enum EndpointAvailability: Equatable, Sendable { case available, unavailable }
public enum RetryPolicy: Equatable, Sendable { case safeCallerRetry, explicitOnlyNewIdentity, callerMayRetryDocumentedFailures }
public enum HTTPMethod: String, Sendable { case get = "GET", post = "POST" }

public enum BackendEndpoint: CaseIterable, Sendable {
    case health, liveKitToken, analyzeShot, measurementPoints, generateBackground, removeBackground
    public var path: String {
        switch self {
        case .health: "/api/health"; case .liveKitToken: "/api/livekit-token"
        case .analyzeShot: "/api/analyze-shot"; case .measurementPoints: "/api/suggest-measurement-points"
        case .generateBackground: "/api/generate-background"; case .removeBackground: "/api/remove-background"
        }
    }
    public var method: HTTPMethod { self == .health ? .get : .post }
    public var timeout: TimeInterval {
        switch self { case .health: 5; case .liveKitToken: 10; case .analyzeShot, .measurementPoints: 20; case .generateBackground: 60; case .removeBackground: 35 }
    }
    public var availability: EndpointAvailability {
        switch self { case .health, .liveKitToken: .available; default: .unavailable }
    }
    public var retryPolicy: RetryPolicy { switch self { case .health: .safeCallerRetry; case .liveKitToken: .explicitOnlyNewIdentity; default: .callerMayRetryDocumentedFailures } }
    public var requiresIdempotencyKey: Bool { switch self { case .analyzeShot,.measurementPoints,.generateBackground,.removeBackground: true; default: false } }
}

public enum APIClientError: Error, Equatable, Sendable {
    case invalidBaseURL, invalidBoundary, invalidIdempotencyKey
    case unavailable(BackendEndpoint)
    case timedOut, transport(String)
    case cancelled
    case unexpectedStatus(Int, HTTPDetailError?)
    case invalidContentType(String?)
    case invalidResponse
}

public enum ImageContentType: String, Sendable { case jpeg = "image/jpeg", png = "image/png", heic = "image/heic" }
public struct IdempotencyKey: Equatable, Sendable { public let value: String; public init(_ value: String) throws { guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.count <= 128, value.unicodeScalars.allSatisfy({ $0.value != 10 && $0.value != 13 }) else { throw APIClientError.invalidIdempotencyKey }; self.value=value } }
public struct MultipartBoundary: Equatable, Sendable { public let value: String; public init(_ value: String) throws { guard (1...70).contains(value.count), value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "'()+_,-./:=?".contains($0)) }) else { throw APIClientError.invalidBoundary }; self.value=value } }
public enum BackendCapability: Sendable { case agentGuidancePush; public var availability: EndpointAvailability { .unavailable } }

public struct MultipartForm: Sendable {
    public let boundary: MultipartBoundary
    public init(boundary: MultipartBoundary) { self.boundary = boundary }
    public func imageBody(field: String = "image", data: Data, contentType: ImageContentType) -> Data {
        var body = Data("--\(boundary.value)\r\n".utf8)
        body += Data("Content-Disposition: form-data; name=\"\(field)\"; filename=\"image\"\r\n".utf8)
        body += Data("Content-Type: \(contentType.rawValue)\r\n\r\n".utf8)
        body += data
        body += Data("\r\n--\(boundary.value)--\r\n".utf8)
        return body
    }
    public func analyzeBody(
        shot: AssessableShot,
        data: Data,
        contentType: ImageContentType,
        imageField: String = "image"
    ) -> Data {
        var body = Data("--\(boundary.value)\r\nContent-Disposition: form-data; name=\"requestedShot\"\r\nContent-Type: text/plain\r\n\r\n\(shot.rawValue)\r\n".utf8)
        body += imageBody(field: imageField, data: data, contentType: contentType)
            .dropFirst(Data("--\(boundary.value)\r\n".utf8).count)
        return body
    }
}

@available(macOS 12.0, iOS 18.0, *)
public actor BackendAPIClient {
    private let baseURL: URL
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(baseURL: URL, session: URLSession, encoder: JSONEncoder = .init(), decoder: JSONDecoder = .init(), allowsInsecureTestURL: Bool = false) throws {
        guard baseURL.host != nil, baseURL.scheme == "https" || (allowsInsecureTestURL && baseURL.scheme == "http") else { throw APIClientError.invalidBaseURL }
        self.baseURL = baseURL; self.session = session; self.encoder = encoder; self.decoder = decoder
    }
    public func health() async throws -> HealthResponse { try await perform(.health, request: makeRequest(.health)) }
    public func liveKitToken(_ value: LiveKitTokenRequest) async throws -> LiveKitTokenResponse {
        try await perform(.liveKitToken, request: try jsonRequest(.liveKitToken, value))
    }
    public func unavailableRequest(_ endpoint: BackendEndpoint) throws -> URLRequest {
        guard endpoint.availability == .unavailable else { return makeRequest(endpoint) }
        throw APIClientError.unavailable(endpoint)
    }
    private func plannedMultipartRequest(_ endpoint: BackendEndpoint, data: Data, type: ImageContentType, boundary: MultipartBoundary, key: IdempotencyKey) throws -> URLRequest {
        var request = makeRequest(endpoint); let form = MultipartForm(boundary: boundary)
        request.setValue("multipart/form-data; boundary=\(boundary.value)", forHTTPHeaderField: "Content-Type")
        request.setValue(key.value, forHTTPHeaderField: "Idempotency-Key")
        request.httpBody = form.imageBody(data: data, contentType: type)
        return request
    }
    public func plannedAnalyzeRequest(
        shot: AssessableShot,
        data: Data,
        type: ImageContentType,
        boundary: MultipartBoundary,
        key: IdempotencyKey,
        imageField: String = "image"
    ) throws -> URLRequest {
        var request = try plannedMultipartRequest(.analyzeShot, data: data, type: type, boundary: boundary, key: key)
        request.httpBody = MultipartForm(boundary: boundary).analyzeBody(
            shot: shot,
            data: data,
            contentType: type,
            imageField: imageField
        )
        return request
    }
    public func plannedMeasurementRequest(data: Data, type: ImageContentType, boundary: MultipartBoundary, key: IdempotencyKey) throws -> URLRequest { try plannedMultipartRequest(.measurementPoints,data:data,type:type,boundary:boundary,key:key) }
    public func plannedMaskRequest(data: Data, type: ImageContentType, boundary: MultipartBoundary, key: IdempotencyKey) throws -> URLRequest { try plannedMultipartRequest(.removeBackground,data:data,type:type,boundary:boundary,key:key) }
    public func plannedBackgroundRequest(_ value: BackgroundStyleRequest, key: IdempotencyKey) throws -> URLRequest {
        guard BackendEndpoint.generateBackground.availability == .unavailable else { throw APIClientError.invalidResponse }
        var request = try jsonRequest(.generateBackground, value); request.setValue(key.value, forHTTPHeaderField:"Idempotency-Key"); return request
    }
    private func makeRequest(_ endpoint: BackendEndpoint) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(String(endpoint.path.dropFirst())))
        request.httpMethod = endpoint.method.rawValue; request.timeoutInterval = endpoint.timeout
        request.setValue((endpoint == .generateBackground || endpoint == .removeBackground) ? "image/png" : "application/json", forHTTPHeaderField: "Accept")
        return request
    }
    private func jsonRequest<T: Encodable>(_ endpoint: BackendEndpoint, _ value: T) throws -> URLRequest {
        var request = makeRequest(endpoint); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(value); return request
    }
    private func perform<T: Decodable>(_ endpoint: BackendEndpoint, request: URLRequest) async throws -> T {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw APIClientError.invalidResponse }
            guard http.statusCode == 200 else {
                let detail = try? decoder.decode(HTTPDetailError.self, from: data)
                throw APIClientError.unexpectedStatus(http.statusCode, detail)
            }
            guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased().split(separator: ";").first == "application/json" else { throw APIClientError.invalidContentType(http.value(forHTTPHeaderField: "Content-Type")) }
            do { return try decoder.decode(T.self, from: data) } catch { throw APIClientError.invalidResponse }
        } catch let error as APIClientError { throw error
        } catch is CancellationError { throw APIClientError.cancelled
        } catch {
            let value = error as NSError
            if value.domain == NSURLErrorDomain && value.code == URLError.cancelled.rawValue { throw APIClientError.cancelled }
            if value.domain == NSURLErrorDomain && value.code == URLError.timedOut.rawValue { throw APIClientError.timedOut }
            throw APIClientError.transport(value.domain)
        }
    }
}
