import Foundation
import Testing
@testable import APIClient
@testable import ContractKit

final class MeasurementPointProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static let lock = NSLock()
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let handler = Self.handler
        Self.lock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func reset(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) {
        lock.lock()
        requests = []
        self.handler = handler
        lock.unlock()
    }

    static func snapshot() -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }
}

private struct ThrowingMeasurementTransport: MeasurementPointTransport {
    let error: URLError
    func data(for request: URLRequest) async throws -> (Data, URLResponse) { throw error }
}

private struct DelayedMeasurementTransport: MeasurementPointTransport {
    let firstResponse: Data
    let secondResponse: Data

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let body = request.httpBody ?? Data()
        let data: Data
        if body.contains(Data([1])) {
            try await Task.sleep(for: .milliseconds(50))
            data = firstResponse
        } else {
            data = secondResponse
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (data, response)
    }
}

private func measurementBackend() throws -> BackendAPIClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.protocolClasses = [MeasurementPointProtocolStub.self]
    return try BackendAPIClient(
        baseURL: URL(string: "http://example.test")!,
        session: URLSession(configuration: configuration),
        allowsInsecureTestURL: true
    )
}

private func protocolTransport() throws -> URLSessionMeasurementPointTransport {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.protocolClasses = [MeasurementPointProtocolStub.self]
    return URLSessionMeasurementPointTransport(session: URLSession(configuration: configuration))
}

private func measurementOperation(
    imageID: String = "corrected-image-1",
    bytes: Data = Data([1, 2, 3]),
    scaleID: String = "scale-1"
) throws -> MeasurementPointOperation {
    try MeasurementPointOperation(
        imageID: imageID,
        correctedImage: bytes,
        imageContentType: .jpeg,
        scaleID: scaleID,
        boundary: try MultipartBoundary("measurement-boundary"),
        idempotencyKey: try IdempotencyKey("measurement-operation-\(imageID)")
    )
}

private func measurementResponse(_ request: URLRequest, status: Int = 200, type: String = "application/json", body: String) -> (HTTPURLResponse, Data) {
    (
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": type])!,
        Data(body.utf8)
    )
}

private let validPoints = #"{"lengthStart":{"x":0.5,"y":0.1},"lengthEnd":{"x":0.5,"y":0.9},"widthStart":{"x":0.2,"y":0.5},"widthEnd":{"x":0.8,"y":0.5}}"#

@Suite(.serialized)
struct MeasurementPointClientTests {
    @available(macOS 12.0, *)
    @Test func sendsOneExactCorrectedImageMultipartRequestAndDecodesFrozenGolden() async throws {
        MeasurementPointProtocolStub.reset { request in measurementResponse(request, body: validPoints) }
        let client = MeasurementPointClient(
            backend: try measurementBackend(),
            transport: try protocolTransport(),
            availability: .fixtureContract
        )

        let operation = try measurementOperation()
        let outcome = await client.suggest(for: operation)
        let expected = try JSONDecoder().decode(MeasurementEndpoints.self, from: Data(validPoints.utf8))
        #expect(outcome == .points(imageID: "corrected-image-1", scaleID: "scale-1", endpoints: expected))

        let requests = MeasurementPointProtocolStub.snapshot()
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/suggest-measurement-points")
        #expect(request.timeoutInterval == 20)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=measurement-boundary")
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "measurement-operation-corrected-image-1")
        let expectedBody = Data("--measurement-boundary\r\nContent-Disposition: form-data; name=\"image\"; filename=\"image\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8) + Data([1, 2, 3]) + Data("\r\n--measurement-boundary--\r\n".utf8)
        #expect(request.httpBody == expectedBody)
    }

    @available(macOS 12.0, *)
    @Test(arguments: [
        #"{"lengthStart":{"x":0.5,"y":0.1},"lengthEnd":{"x":0.5,"y":0.9},"widthStart":{"x":0.2,"y":0.5},"widthEnd":{"x":0.8,"y":0.5},"confidence":0.9}"#,
        #"{"lengthStart":{"x":0.5,"y":0.1},"lengthEnd":{"x":0.5,"y":0.9},"widthStart":{"x":0.2,"y":0.5}}"#,
        #"{"lengthStart":{"x":0.5,"y":0.1,"cm":42},"lengthEnd":{"x":0.5,"y":0.9},"widthStart":{"x":0.2,"y":0.5},"widthEnd":{"x":0.8,"y":0.5}}"#,
        #"{"lengthStart":{"x":-0.01,"y":0.1},"lengthEnd":{"x":0.5,"y":0.9},"widthStart":{"x":0.2,"y":0.5},"widthEnd":{"x":0.8,"y":0.5}}"#,
        #"{"lengthStart":{"x":1e999,"y":0.1},"lengthEnd":{"x":0.5,"y":0.9},"widthStart":{"x":0.2,"y":0.5},"widthEnd":{"x":0.8,"y":0.5}}"#
    ])
    func rejectsUnknownMissingConfidenceCentimeterAndInvalidCoordinates(_ body: String) async throws {
        MeasurementPointProtocolStub.reset { request in measurementResponse(request, body: body) }
        let client = MeasurementPointClient(backend: try measurementBackend(), transport: try protocolTransport(), availability: .fixtureContract)
        let outcome = await client.suggest(for: try measurementOperation())
        guard case let .fallback(fallback) = outcome else {
            Issue.record("invalid measurement response was accepted")
            return
        }
        #expect(fallback.imageID == "corrected-image-1")
        #expect(fallback.scaleID == "scale-1")
        #expect(fallback.placement == .contourOrUserPlacement)
    }

    @available(macOS 12.0, *)
    @Test func mapsStrictContentTypeStatusAndProviderErrors() async throws {
        let provider = #"{"provider":"measurement-line","code":"INVALID_RESPONSE","message":"Points unavailable","retryable":false}"#
        MeasurementPointProtocolStub.reset { request in measurementResponse(request, status: 503, body: provider) }
        let client = MeasurementPointClient(backend: try measurementBackend(), transport: try protocolTransport(), availability: .fixtureContract)
        let expectedError = try JSONDecoder().decode(ProviderError.self, from: Data(provider.utf8))
        #expect(await client.suggest(for: try measurementOperation()) == .fallback(MeasurementPointFallback(imageID: "corrected-image-1", scaleID: "scale-1", reason: .provider(expectedError))))

        MeasurementPointProtocolStub.reset { request in measurementResponse(request, type: "text/plain", body: validPoints) }
        let contentTypeClient = MeasurementPointClient(backend: try measurementBackend(), transport: try protocolTransport(), availability: .fixtureContract)
        #expect(await contentTypeClient.suggest(for: try measurementOperation()) == .fallback(MeasurementPointFallback(imageID: "corrected-image-1", scaleID: "scale-1", reason: .invalidContentType)))

        MeasurementPointProtocolStub.reset { request in measurementResponse(request, status: 422, body: "{}") }
        let statusClient = MeasurementPointClient(backend: try measurementBackend(), transport: try protocolTransport(), availability: .fixtureContract)
        #expect(await statusClient.suggest(for: try measurementOperation()) == .fallback(MeasurementPointFallback(imageID: "corrected-image-1", scaleID: "scale-1", reason: .unexpectedStatus(422))))
    }

    @available(macOS 12.0, *)
    @Test func timeoutAndCancellationRetainOnlyIdentityAndScaleForFallback() async throws {
        let timeoutClient = MeasurementPointClient(
            backend: try measurementBackend(),
            transport: ThrowingMeasurementTransport(error: URLError(.timedOut)),
            availability: .fixtureContract
        )
        let operation = try measurementOperation(bytes: Data([9, 9, 9]))
        #expect(await timeoutClient.suggest(for: operation) == .fallback(MeasurementPointFallback(imageID: "corrected-image-1", scaleID: "scale-1", reason: .timedOut)))

        let cancellationClient = MeasurementPointClient(
            backend: try measurementBackend(),
            transport: ThrowingMeasurementTransport(error: URLError(.cancelled)),
            availability: .fixtureContract
        )
        #expect(await cancellationClient.suggest(for: operation) == .fallback(MeasurementPointFallback(imageID: "corrected-image-1", scaleID: "scale-1", reason: .cancelled)))
        let latest = await cancellationClient.latestOutcome()
        #expect(latest == .fallback(MeasurementPointFallback(imageID: "corrected-image-1", scaleID: "scale-1", reason: .cancelled)))
    }

    @available(macOS 12.0, *)
    @Test func cancellingCallerCancelsTheInFlightTransportAndReturnsFallback() async throws {
        let client = MeasurementPointClient(
            backend: try measurementBackend(),
            transport: DelayedMeasurementTransport(firstResponse: Data(validPoints.utf8), secondResponse: Data(validPoints.utf8)),
            availability: .fixtureContract
        )
        let operation = try measurementOperation(bytes: Data([1]))
        let task = Task { await client.suggest(for: operation) }
        await Task.yield()
        task.cancel()
        let outcome = await task.value
        #expect(outcome == .fallback(MeasurementPointFallback(imageID: "corrected-image-1", scaleID: "scale-1", reason: .cancelled)))
    }

    @available(macOS 12.0, *)
    @Test func duplicateImageCallsAreSingleFlightAndMemoized() async throws {
        MeasurementPointProtocolStub.reset { request in measurementResponse(request, body: validPoints) }
        let client = MeasurementPointClient(backend: try measurementBackend(), transport: try protocolTransport(), availability: .fixtureContract)
        let operation = try measurementOperation()
        async let first = client.suggest(for: operation)
        async let second = client.suggest(for: operation)
        _ = await (first, second)
        _ = await client.suggest(for: operation)
        #expect(MeasurementPointProtocolStub.snapshot().count == 1)
    }

    @available(macOS 12.0, *)
    @Test func staleImageResponseCannotReplaceCurrentResult() async throws {
        let client = MeasurementPointClient(
            backend: try measurementBackend(),
            transport: DelayedMeasurementTransport(firstResponse: validPoints.data(using: .utf8)!, secondResponse: validPoints.data(using: .utf8)!),
            availability: .fixtureContract
        )
        let old = try measurementOperation(imageID: "old", bytes: Data([1]), scaleID: "old-scale")
        let current = try measurementOperation(imageID: "current", bytes: Data([2]), scaleID: "current-scale")
        async let staleResult = client.suggest(for: old)
        await Task.yield()
        async let currentResult = client.suggest(for: current)
        let results = await (staleResult, currentResult)
        #expect(results.0 == .discardedAsStale(imageID: "old"))
        guard case let .points(imageID, scaleID, _) = results.1 else { Issue.record("current response was not applied"); return }
        #expect(imageID == "current" && scaleID == "current-scale")
        guard case let .points(latestID, latestScale, _) = await client.latestOutcome() else { Issue.record("stale response replaced current state"); return }
        #expect(latestID == "current" && latestScale == "current-scale")
    }

    @available(macOS 12.0, *)
    @Test func liveAvailabilityIsAnExplicitBlockerAndNeverCallsFixtureTransport() async throws {
        MeasurementPointProtocolStub.reset { request in measurementResponse(request, body: validPoints) }
        let client = MeasurementPointClient(backend: try measurementBackend(), transport: try protocolTransport(), availability: .liveUnavailable)
        let outcome = await client.suggest(for: try measurementOperation())
        #expect(outcome == .fallback(MeasurementPointFallback(imageID: "corrected-image-1", scaleID: "scale-1", reason: .liveEndpointUnavailable)))
        #expect(MeasurementPointProtocolStub.snapshot().isEmpty)
    }
}
