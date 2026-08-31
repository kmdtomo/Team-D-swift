import Foundation
import Testing
@testable import APIClient
@testable import ContractKit
@testable import DomainKit

final class ProtocolStub: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open(); defer { stream.close() }
            var body = Data(), buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(buffer, count: count)
            }
            captured.httpBody = body
        }
        Self.lock.lock(); Self.requests.append(captured); let handler = Self.handler; Self.lock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do { let (response, data) = try handler(request); client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed); client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self) }
        catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    static func reset(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) {
        lock.lock(); requests = []; self.handler = handler; lock.unlock()
    }
    static func requestSnapshot() -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }; return requests
    }
}

private func client() throws -> BackendAPIClient {
    let config = URLSessionConfiguration.ephemeral
    config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData; config.protocolClasses = [ProtocolStub.self]
    return try BackendAPIClient(baseURL: URL(string: "http://example.test")!, session: URLSession(configuration: config), allowsInsecureTestURL: true)
}
private func response(_ request: URLRequest, status: Int = 200, type: String = "application/json", body: Data) -> (HTTPURLResponse, Data) {
    (HTTPURLResponse(url: request.url ?? URL(string: "http://example.test")!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": type])!, body)
}
private func golden(_ name: String) throws -> Data {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try Data(contentsOf: root.appending(path: "Contracts/HTTP/v1/goldens/\(name).json"))
}

@Suite(.serialized)
struct APIClientContractTests {
@Test func rootContractGoldensAndStrictDTOBounds() throws {
    let health = try golden("health.response")
    #expect(try JSONDecoder().decode(HealthResponse.self, from: health).status == "ok")
    let validation = try golden("token.error-422-validation")
    if case .validation(let issues) = try JSONDecoder().decode(HTTPDetailError.self, from: validation) { #expect(issues.count == 1) } else { Issue.record("expected validation union") }
    #expect(throws: Error.self) { try HealthResponse(status: "degraded") }
    #expect(throws: Error.self) { try BackgroundStyleRequest(styleId: String(repeating: "a", count: 129)) }
    _ = try JSONDecoder().decode(LiveKitTokenRequest.self, from: golden("token.request"))
    _ = try JSONDecoder().decode(LiveKitTokenResponse.self, from: golden("token.response"))
    _ = try JSONDecoder().decode(HTTPDetailError.self, from: golden("token.error-422"))
    _ = try JSONDecoder().decode(HTTPDetailError.self, from: golden("token.error-503"))
    _ = try JSONDecoder().decode(BackgroundStyleRequest.self, from: golden("background.request"))
    _ = try JSONDecoder().decode(MeasurementEndpoints.self, from: golden("measurement.response"))
}
@Test func endpointMatrixHasOnlySixFrozenSurfaces() {
    #expect(BackendEndpoint.allCases.count == 6)
    #expect(BackendEndpoint.health.path == "/api/health" && BackendEndpoint.health.method == .get && BackendEndpoint.health.timeout == 5 && BackendEndpoint.health.availability == .available)
    #expect(BackendEndpoint.liveKitToken.path == "/api/livekit-token" && BackendEndpoint.liveKitToken.timeout == 10 && BackendEndpoint.liveKitToken.availability == .available)
    #expect(BackendEndpoint.analyzeShot.path == "/api/analyze-shot" && BackendEndpoint.analyzeShot.timeout == 20 && BackendEndpoint.analyzeShot.availability == .unavailable)
    #expect(BackendEndpoint.measurementPoints.path == "/api/suggest-measurement-points" && BackendEndpoint.measurementPoints.timeout == 20 && BackendEndpoint.measurementPoints.availability == .unavailable)
    #expect(BackendEndpoint.generateBackground.path == "/api/generate-background" && BackendEndpoint.generateBackground.timeout == 60 && BackendEndpoint.generateBackground.availability == .unavailable)
    #expect(BackendEndpoint.removeBackground.path == "/api/remove-background" && BackendEndpoint.removeBackground.timeout == 35 && BackendEndpoint.removeBackground.availability == .unavailable)
}
@Test func rootOpenAPIAndAvailabilityMatchEverySwiftSurface() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let openapi = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appending(path: "Contracts/HTTP/v1/openapi.json"))) as! [String: Any]
    let paths = openapi["paths"] as! [String: Any]
    let availability = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appending(path: "Contracts/HTTP/v1/availability.json"))) as! [String: Any]
    let surfaces = availability["surfaces"] as! [String: Any]
    let expected: [(BackendEndpoint,String,String)] = [
        (.health,"health","get"),(.liveKitToken,"livekit-token","post"),(.analyzeShot,"analyze-shot","post"),
        (.measurementPoints,"suggest-measurement-points","post"),(.generateBackground,"generate-background","post"),(.removeBackground,"remove-background","post")]
    #expect(paths["/api/analyze-live"] == nil)
    for (endpoint,name,method) in expected {
        let operation = (paths[endpoint.path] as! [String: Any])[method] as! [String: Any]
        #expect((operation["x-team-d-availability"] as! String) == (endpoint.availability == .available ? "implemented" : "unavailable"))
        #expect((operation["x-team-d-timeout-seconds"] as! NSNumber).doubleValue == endpoint.timeout)
        #expect((operation["x-team-d-retry"] as! String) == ({ switch endpoint.retryPolicy { case .safeCallerRetry: "safe-caller-retry"; case .explicitOnlyNewIdentity: "explicit-only-new-identity"; case .callerMayRetryDocumentedFailures: "caller-may-retry-documented-failures" } }()))
        #expect((operation["x-team-d-idempotency"] as! String) == (endpoint.requiresIdempotencyKey ? "required-stable-per-operation" : "none"))
        #expect((surfaces[name] as! [String: Any])["available"] as! Bool == (endpoint.availability == .available))
        #expect(endpoint.method.rawValue.lowercased() == method)
    }
    #expect((surfaces["agent-guidance-push"] as! [String: Any])["available"] as! Bool == false)
    #expect(BackendCapability.agentGuidancePush.availability == .unavailable)
}
@available(macOS 12.0, *) @Test func healthAndTokenUseFrozenHTTPContract() async throws {
    let healthBody = try golden("health.response")
    let tokenBody = try golden("token.response")
    let tokenRequestData = try golden("token.request")
    let tokenRequest = try JSONDecoder().decode(LiveKitTokenRequest.self, from: tokenRequestData)
    let expectedToken = try JSONDecoder().decode(LiveKitTokenResponse.self, from: tokenBody)
    ProtocolStub.reset { request in
        switch request.url?.path {
        case "/api/health": return response(request, body: healthBody)
        case "/api/livekit-token": return response(request, body: tokenBody)
        default: throw URLError(.badURL)
        }
    }
    let sut = try client()
    #expect(try await sut.health().status == "ok")
    #expect(try await sut.liveKitToken(tokenRequest) == expectedToken)
    let requests = ProtocolStub.requestSnapshot()
    #expect(requests.count == 2)
    #expect(requests[0].httpMethod == "GET" && requests[0].url?.path == "/api/health" && requests[0].timeoutInterval == 5)
    #expect(requests[1].httpMethod == "POST" && requests[1].url?.path == "/api/livekit-token" && requests[1].timeoutInterval == 10)
    #expect(requests[1].value(forHTTPHeaderField: "Accept") == "application/json")
    #expect(requests[1].value(forHTTPHeaderField: "Content-Type") == "application/json")
    let capturedTokenBody = try #require(requests[1].httpBody)
    #expect((try JSONSerialization.jsonObject(with: capturedTokenBody) as AnyObject).isEqual(try JSONSerialization.jsonObject(with: tokenRequestData)))
}

@available(macOS 12.0, *) @Test func plannedEndpointsDoNotReachNetworkAndBuildersAreExact() async throws {
    ProtocolStub.reset { request in response(request, body: Data()) }
    let sut = try client()
    for endpoint in [BackendEndpoint.analyzeShot, .measurementPoints, .generateBackground, .removeBackground] {
        do { _ = try await sut.unavailableRequest(endpoint); Issue.record("expected unavailable") }
        catch let error as APIClientError { #expect(error == .unavailable(endpoint)) }
    }
    #expect(ProtocolStub.requestSnapshot().isEmpty)
    let key = try IdempotencyKey("stable-key")
    let analyze = try await sut.plannedAnalyzeRequest(shot: .front, data: Data([1, 2]), type: .jpeg, boundary: try MultipartBoundary("fixed"), key: key)
    #expect(analyze.url!.path == "/api/analyze-shot")
    #expect(analyze.timeoutInterval == 20)
    #expect(analyze.value(forHTTPHeaderField: "Accept") == "application/json")
    #expect(analyze.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=fixed")
    #expect(analyze.value(forHTTPHeaderField: "Idempotency-Key") == "stable-key")
    #expect(analyze.httpBody == Data("--fixed\r\nContent-Disposition: form-data; name=\"requestedShot\"\r\nContent-Type: text/plain\r\n\r\nfront\r\nContent-Disposition: form-data; name=\"image\"; filename=\"image\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8) + Data([1,2]) + Data("\r\n--fixed--\r\n".utf8))
    let backgroundInput = try JSONDecoder().decode(BackgroundStyleRequest.self, from: golden("background.request"))
    let background = try await sut.plannedBackgroundRequest(backgroundInput, key: key)
    #expect(background.value(forHTTPHeaderField: "Idempotency-Key") == "stable-key")
    let measurement = try await sut.plannedMeasurementRequest(data: Data([3]), type: .png, boundary: try MultipartBoundary("fixed"), key: key)
    let mask = try await sut.plannedMaskRequest(data: Data([4]), type: .heic, boundary: try MultipartBoundary("fixed"), key: key)
    #expect(measurement.url!.path == "/api/suggest-measurement-points" && measurement.timeoutInterval == 20 && measurement.value(forHTTPHeaderField: "Accept") == "application/json" && measurement.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=fixed" && measurement.value(forHTTPHeaderField: "Idempotency-Key") == "stable-key" && measurement.httpBody!.contains(Data("image/png".utf8)))
    #expect(mask.url!.path == "/api/remove-background" && mask.timeoutInterval == 35 && mask.value(forHTTPHeaderField: "Accept") == "image/png" && mask.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=fixed" && mask.value(forHTTPHeaderField: "Idempotency-Key") == "stable-key" && mask.httpBody!.contains(Data("image/heic".utf8)))
    #expect(background.url!.path == "/api/generate-background" && background.timeoutInterval == 60 && background.value(forHTTPHeaderField: "Accept") == "image/png" && background.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let backgroundGolden = try JSONSerialization.jsonObject(with: golden("background.request"))
    let backgroundBody = try JSONSerialization.jsonObject(with: background.httpBody!) as! [String: Any]
    #expect((backgroundBody as NSDictionary).isEqual(backgroundGolden))
    #expect(backgroundBody.keys.sorted() == ["styleId"])
    let other = try await sut.plannedMaskRequest(data: Data([4]), type: .heic, boundary: try MultipartBoundary("fixed"), key: try IdempotencyKey("other"))
    let same = try await sut.plannedMaskRequest(data: Data([4]), type: .heic, boundary: try MultipartBoundary("fixed"), key: key)
    #expect(mask.value(forHTTPHeaderField: "Idempotency-Key") == "stable-key" && other.value(forHTTPHeaderField: "Idempotency-Key") == "other")
    #expect(mask.value(forHTTPHeaderField: "Idempotency-Key") == same.value(forHTTPHeaderField: "Idempotency-Key"))
    let count = ProtocolStub.requestSnapshot().count
    #expect(count == 0)
}

@available(macOS 12.0, *) @Test func rejectsBadStatusContentTypeAndStrictBodiesWithoutFixtureFallback() async throws {
    let string422 = try golden("token.error-422")
    let validation422 = try golden("token.error-422-validation")
    let string503 = try golden("token.error-503")
    let expected422 = try JSONDecoder().decode(HTTPDetailError.self, from: string422)
    let expected503 = try JSONDecoder().decode(HTTPDetailError.self, from: string503)
    ProtocolStub.reset { request in response(request, status: 422, body: string422) }
    let sut = try client()
    do { _ = try await sut.liveKitToken(LiveKitTokenRequest(sessionId: "session")); Issue.record("expected 422") }
    catch let error as APIClientError { #expect(error == .unexpectedStatus(422, expected422)) }
    ProtocolStub.reset { request in response(request, status: 422, body: validation422) }
    do { _ = try await sut.liveKitToken(LiveKitTokenRequest(sessionId: "session")); Issue.record("expected validation 422") }
    catch let error as APIClientError {
        if case .unexpectedStatus(422, .validation(let issues)) = error { #expect(issues.count == 1) }
        else { Issue.record("validation body was not retained") }
    }
    ProtocolStub.reset { request in response(request, status: 201, body: try! golden("health.response")) }
    do { _ = try await sut.health(); Issue.record("expected 201 rejection") }
    catch let error as APIClientError { #expect(error == .unexpectedStatus(201, nil)) }
    ProtocolStub.reset { request in response(request, body: Data()) }
    do { _ = try await sut.health(); Issue.record("expected empty body error") }
    catch let error as APIClientError { #expect(error == .invalidResponse) }
    ProtocolStub.reset { request in response(request, type: "text/plain", body: try! golden("health.response")) }
    do { _ = try await sut.health(); Issue.record("expected content type error") }
    catch let error as APIClientError { #expect(error == .invalidContentType("text/plain")) }
    ProtocolStub.reset { request in response(request, body: Data(#"{"status":"ok","extra":true}"#.utf8)) }
    do { _ = try await sut.health(); Issue.record("expected strict decode error") }
    catch let error as APIClientError { #expect(error == .invalidResponse) }
    ProtocolStub.reset { request in response(request, status: 503, body: string503) }
    do { _ = try await sut.liveKitToken(LiveKitTokenRequest(sessionId: "session")); Issue.record("expected 503") }
    catch let error as APIClientError { #expect(error == .unexpectedStatus(503, expected503)) }
    ProtocolStub.reset { _ in throw URLError(.timedOut) }
    do { _ = try await sut.health(); Issue.record("expected timeout") }
    catch let error as APIClientError { #expect(error == .timedOut) }
    ProtocolStub.reset { _ in throw URLError(.cancelled) }
    do { _ = try await sut.health(); Issue.record("expected cancellation") }
    catch let error as APIClientError { #expect(error == .cancelled) }
}

@Test func rejectsInvalidHeadersStylesAndHTTPDetailShapes() throws {
    #expect(throws: APIClientError.self) { try IdempotencyKey("") }
    #expect(throws: APIClientError.self) { try IdempotencyKey(String(repeating: "x", count: 129)) }
    #expect(throws: APIClientError.self) { try IdempotencyKey("bad\r\nkey") }
    #expect(throws: APIClientError.self) { try MultipartBoundary("") }
    #expect(throws: APIClientError.self) { try MultipartBoundary(String(repeating: "x", count: 71)) }
    #expect(throws: APIClientError.self) { try MultipartBoundary("bad\r\n") }
    #expect(throws: APIClientError.self) { try MultipartBoundary("bad\"quote") }
    #expect(throws: Error.self) { try BackgroundStyleRequest(styleId: "   ") }
    #expect(throws: Error.self) { try BackgroundStyleRequest(styleId: String(repeating: "x", count: 129)) }
    let decoder = JSONDecoder()
    for invalid in [
        #"{"detail":""}"#, #"{"detail":[]}"#, #"{"detail":[{"type":"missing","loc":[],"msg":"x"}]}"#,
        #"{"detail":[{"type":"missing","loc":[1.5],"msg":"x"}]}"#,
        #"{"detail":[{"type":"missing","loc":["body"],"msg":"x","ctx":"bad"}]}"#,
        #"{"detail":[{"type":"missing","loc":["body"],"msg":"x","extra":true}]}"#,
        #"{"detail":true}"#, #"{}"#, #"{"detail":"x","extra":true}"#
    ] {
        #expect(throws: Error.self) { try decoder.decode(HTTPDetailError.self, from: Data(invalid.utf8)) }
    }
}
}
