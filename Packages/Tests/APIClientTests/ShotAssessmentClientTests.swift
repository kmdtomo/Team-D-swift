import ContractKit
import DomainKit
import Foundation
import Testing
@testable import APIClient

private final class ShotAssessmentProtocolStub: URLProtocol, @unchecked Sendable {
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
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

private actor RecordingShotAssessmentTransport: ShotAssessmentTransport {
    private var responses: [Result<(Data, URLResponse), Error>]
    private(set) var requests: [URLRequest] = []

    init(_ responses: [Result<(Data, URLResponse), Error>]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        return try responses.removeFirst().get()
    }
}

private actor SuspendingShotAssessmentTransport: ShotAssessmentTransport {
    private(set) var started = false

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        _ = request
        started = true
        try await Task.sleep(for: .seconds(60))
        throw URLError(.unknown)
    }
}

private struct DelayedShotAssessmentTransport: ShotAssessmentTransport {
    let responseBody: Data

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        if request.httpBody?.range(of: Data([1])) != nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        return (responseBody, jsonResponse(for: request))
    }
}

@Suite("T09-01 shot assessment client", .serialized)
struct ShotAssessmentClientTests {
    @Test func sendsFrozenMultipartWithOriginalBytesForEveryAssessableShot() async throws {
        for (index, shot, contentType) in [
            (1, Shot.front, ImageContentType.jpeg),
            (2, .back, .png),
            (3, .tag, .heic),
        ] {
            let operation = try makeOperation(
                suffix: "\(index)",
                shot: shot,
                bytes: Data([UInt8(index), 0, 255]),
                contentType: contentType
            )
            ShotAssessmentProtocolStub.reset { request in
                (response(url: request.url ?? backendURL, status: 200), validAssessment(shot: shot))
            }
            let client = try makeClient(transport: protocolTransport())

            guard case .assessment(let descriptor, _) = await client.assess(operation) else {
                Issue.record("valid assessment was not returned")
                continue
            }
            #expect(descriptor.requestedShot.rawValue == shot.rawValue)
            let requests = ShotAssessmentProtocolStub.snapshot()
            let request = try #require(requests.first)
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/api/analyze-shot")
            #expect(request.timeoutInterval == 20)
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=assessment-boundary-\(index)")
            #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "assessment-operation-\(index)")
            var expected = Data(
                "--assessment-boundary-\(index)\r\nContent-Disposition: form-data; name=\"requestedShot\"\r\nContent-Type: text/plain\r\n\r\n\(shot.rawValue)\r\n--assessment-boundary-\(index)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"image\"\r\nContent-Type: \(contentType.rawValue)\r\n\r\n".utf8
            )
            expected += operation.originalImage
            expected += Data("\r\n--assessment-boundary-\(index)--\r\n".utf8)
            #expect(request.httpBody == expected)
            #expect(operation.normalizationPolicy == .preserveHighResolutionOriginal)
        }
    }

    @Test func retryingAnOperationReusesItsStableIdempotencyKeyAndExactBody() async throws {
        ShotAssessmentProtocolStub.reset { request in
            (response(url: request.url ?? backendURL, status: 200), validAssessment(shot: .front))
        }
        let client = try makeClient(transport: protocolTransport())
        let operation = try makeOperation(suffix: "stable-retry", bytes: Data([0, 17, 255]))

        _ = await client.assess(operation)
        _ = await client.assess(operation)

        let requests = ShotAssessmentProtocolStub.snapshot()
        #expect(requests.count == 2)
        #expect(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Idempotency-Key") == "assessment-operation-stable-retry"
        })
        #expect(requests[0].httpBody == requests[1].httpBody)
    }

    @Test func currentUpstreamWireUsesFilePartAndStrictDetailErrorEnvelope() async throws {
        let providerEnvelope = #"{"detail":{"provider":"shot-assessor","code":"UNAVAILABLE","message":"provider unavailable","retryable":true}}"#
        let invalidEnvelope = #"{"detail":{"provider":"shot-assessor","code":"UNAVAILABLE","message":"provider unavailable","retryable":true},"extra":true}"#
        let transport = RecordingShotAssessmentTransport([
            .success((validAssessment(shot: .front), response(url: backendURL, status: 200))),
            .success((Data(providerEnvelope.utf8), response(url: backendURL, status: 413))),
            .success((Data(invalidEnvelope.utf8), response(url: backendURL, status: 503))),
        ])
        let client = try makeClient(
            transport: transport,
            availability: .liveAvailable,
            wireContract: .upstreamA25A854
        )

        guard case .assessment = await client.assess(
            try makeOperation(suffix: "upstream-success")
        ) else {
            Issue.record("current upstream success was rejected")
            return
        }
        let requests = await transport.requests
        let request = try #require(requests.first)
        #expect(request.httpBody?.range(of: Data("name=\"file\"".utf8)) != nil)
        #expect(request.httpBody?.range(of: Data("name=\"image\"".utf8)) == nil)

        guard case .failed(let failure) = await client.assess(
            try makeOperation(suffix: "upstream-error")
        ), case .provider(let provider) = failure.reason else {
            Issue.record("current upstream provider envelope was not preserved")
            return
        }
        #expect(provider.provider == .shotAssessor)
        #expect(provider.retryable)

        guard case .failed(let invalid) = await client.assess(
            try makeOperation(suffix: "upstream-invalid-error")
        ) else {
            Issue.record("invalid current upstream envelope was accepted")
            return
        }
        #expect(invalid.reason == .invalidResponse)
    }

    @Test func acceptsStrictRetryAssessmentButRejectsContradictoryOKShot() async throws {
        let retry = #"{"shotType":"back","quality":"retry","issues":["WRONG_SHOT"],"missingShots":["front","tag"],"nextAction":"RETAKE"}"#
        let mismatchOK = #"{"shotType":"back","quality":"ok","issues":[],"missingShots":["tag"],"nextAction":"REQUEST_NEXT"}"#
        let requestedStillMissing = #"{"shotType":"front","quality":"ok","issues":[],"missingShots":["front","tag"],"nextAction":"REQUEST_NEXT"}"#
        let transport = RecordingShotAssessmentTransport([
            .success((Data(retry.utf8), response(url: backendURL, status: 200))),
            .success((Data(mismatchOK.utf8), response(url: backendURL, status: 200))),
            .success((Data(requestedStillMissing.utf8), response(url: backendURL, status: 200))),
        ])
        let client = try makeClient(transport: transport)

        guard case .assessment(_, let assessment) = await client.assess(try makeOperation(suffix: "retry")) else {
            Issue.record("strict retry response was rejected")
            return
        }
        #expect(assessment.quality == .retry)
        #expect(assessment.shotType == .back)

        let mismatch = await client.assess(try makeOperation(suffix: "mismatch"))
        guard case .failed(let failure) = mismatch else {
            Issue.record("contradictory ok response was accepted")
            return
        }
        #expect(failure.reason == .requestedShotMismatch)

        guard case .failed(let missingFailure) = await client.assess(try makeOperation(suffix: "missing-requested")) else {
            Issue.record("ok response that still lists requested shot as missing was accepted")
            return
        }
        #expect(missingFailure.reason == .requestedShotMismatch)
    }

    @Test(arguments: [
        #"{"shotType":"unknown","quality":"retry","issues":[],"missingShots":[],"nextAction":"RETAKE"}"#,
        #"{"shotType":"back","quality":"retry","issues":["TOO_DARK","TOO_BRIGHT","TOO_BLURRY","BLURRY","GARMENT_CROPPED","TAG_UNREADABLE","WRONG_SHOT"],"missingShots":["front","back","tag"],"nextAction":"REQUEST_NEXT"}"#,
        #"{"shotType":"tag","quality":"retry","issues":["TAG_UNREADABLE"],"missingShots":["tag"],"nextAction":"COMPLETE"}"#,
    ])
    func decodesEveryFiniteResponseFamilyWhenTheAssessmentIsNotContradictory(_ body: String) async throws {
        let transport = RecordingShotAssessmentTransport([
            .success((Data(body.utf8), response(url: backendURL, status: 200)))
        ])
        let client = try makeClient(transport: transport)
        guard case .assessment = await client.assess(try makeOperation(suffix: "valid-family")) else {
            Issue.record("valid finite response family was rejected")
            return
        }
    }

    @Test(arguments: [
        #"{"shotType":"front","quality":"ok","issues":[],"missingShots":["back","tag"],"nextAction":"REQUEST_NEXT","confidence":0.9}"#,
        #"{"quality":"ok","issues":[],"missingShots":["back","tag"],"nextAction":"REQUEST_NEXT"}"#,
        #"{"shotType":"front","issues":[],"missingShots":["back","tag"],"nextAction":"REQUEST_NEXT"}"#,
        #"{"shotType":"front","quality":"ok","missingShots":["back","tag"],"nextAction":"REQUEST_NEXT"}"#,
        #"{"shotType":"front","quality":"ok","issues":[],"nextAction":"REQUEST_NEXT"}"#,
        #"{"shotType":"front","quality":"ok","issues":[],"missingShots":["back","tag"]}"#,
        #"{"shotType":"measurement","quality":"ok","issues":[],"missingShots":["back","tag"],"nextAction":"REQUEST_NEXT"}"#,
        #"{"shotType":"front","quality":"great","issues":[],"missingShots":["back","tag"],"nextAction":"REQUEST_NEXT"}"#,
        #"{"shotType":"front","quality":"ok","issues":["OPEN_ISSUE"],"missingShots":["back","tag"],"nextAction":"REQUEST_NEXT"}"#,
        #"{"shotType":"front","quality":"ok","issues":[],"missingShots":["measurement"],"nextAction":"REQUEST_NEXT"}"#,
        #"{"shotType":"front","quality":"ok","issues":[],"missingShots":["back","tag"],"nextAction":"ADVANCE"}"#,
        #"{"shotType":"front","quality":"ok","issues":{},"missingShots":["back","tag"],"nextAction":"REQUEST_NEXT"}"#,
        #"[]"#,
        #"not-json"#,
    ])
    func rejectsUnknownMissingWrongTypeAndUnknownFiniteValues(_ body: String) async throws {
        let transport = RecordingShotAssessmentTransport([
            .success((Data(body.utf8), response(url: backendURL, status: 200)))
        ])
        let client = try makeClient(transport: transport)
        guard case .failed(let failure) = await client.assess(try makeOperation(suffix: "invalid")) else {
            Issue.record("invalid strict response was accepted")
            return
        }
        #expect(failure.reason == .invalidResponse)
    }

    @Test func validatesContentTypeStatusAndShotAssessorProviderEnvelope() async throws {
        let provider = #"{"provider":"shot-assessor","code":"UNAVAILABLE","message":"provider unavailable","retryable":true}"#
        let wrongProvider = #"{"provider":"measurement-line","code":"UNAVAILABLE","message":"wrong provider","retryable":true}"#
        let invalidProvider = #"{"provider":"shot-assessor","code":"UNAVAILABLE","message":"provider unavailable","retryable":true,"detail":"not frozen"}"#
        let transport = RecordingShotAssessmentTransport([
            .success((Data(provider.utf8), response(url: backendURL, status: 400))),
            .success((Data(provider.utf8), response(url: backendURL, status: 415))),
            .success((Data(provider.utf8), response(url: backendURL, status: 422))),
            .success((Data(provider.utf8), response(url: backendURL, status: 429))),
            .success((Data(provider.utf8), response(url: backendURL, status: 502))),
            .success((Data(provider.utf8), response(url: backendURL, status: 503))),
            .success((Data(provider.utf8), response(url: backendURL, status: 504))),
            .success((Data(wrongProvider.utf8), response(url: backendURL, status: 503))),
            .success((Data(invalidProvider.utf8), response(url: backendURL, status: 503))),
            .success((Data(provider.utf8), response(url: backendURL, status: 401))),
            .success((validAssessment(shot: .front), response(url: backendURL, status: 200, contentType: "text/plain"))),
        ])
        let client = try makeClient(transport: transport)

        for status in [400, 415, 422, 429, 502, 503, 504] {
            guard case .failed(let providerFailure) = await client.assess(try makeOperation(suffix: "provider-\(status)")),
                  case .provider(let decoded) = providerFailure.reason else {
                Issue.record("strict provider error for \(status) was not preserved")
                return
            }
            #expect(decoded.provider == .shotAssessor)
            #expect(decoded.retryable)
        }

        guard case .failed(let statusFailure) = await client.assess(try makeOperation(suffix: "wrong-provider")) else {
            Issue.record("wrong provider envelope was accepted")
            return
        }
        #expect(statusFailure.reason == .invalidResponse)

        guard case .failed(let invalidProviderFailure) = await client.assess(try makeOperation(suffix: "invalid-provider")) else {
            Issue.record("provider envelope with unknown field was accepted")
            return
        }
        #expect(invalidProviderFailure.reason == .invalidResponse)

        guard case .failed(let uncontractedStatus) = await client.assess(try makeOperation(suffix: "uncontracted-status")) else {
            Issue.record("uncontracted status was accepted as a provider response")
            return
        }
        #expect(uncontractedStatus.reason == .unexpectedStatus(401))

        guard case .failed(let typeFailure) = await client.assess(try makeOperation(suffix: "content-type")) else {
            Issue.record("wrong content type was accepted")
            return
        }
        #expect(typeFailure.reason == .invalidContentType)
    }

    @Test func mapsTimeoutAndExplicitCancellationWithoutRetainingImageBytes() async throws {
        ShotAssessmentProtocolStub.reset { _ in throw URLError(.timedOut) }
        let timeoutClient = try makeClient(transport: protocolTransport())
        let timeoutOperation = try makeOperation(suffix: "timeout", bytes: Data([7, 7, 7]))
        guard case .failed(let timeoutFailure) = await timeoutClient.assess(timeoutOperation) else {
            Issue.record("timeout was not finite")
            return
        }
        #expect(timeoutFailure.reason == .timedOut)
        #expect(!containsDataPayload(await timeoutClient.stateSnapshot()))

        let suspending = SuspendingShotAssessmentTransport()
        let cancellationClient = try makeClient(transport: suspending)
        let operation = try makeOperation(suffix: "cancel")
        let task = Task { await cancellationClient.assess(operation) }
        #expect(await waitUntil { await suspending.started })
        await cancellationClient.cancel(requestID: operation.requestID)
        guard case .failed(let cancellation) = await task.value else {
            Issue.record("cancelled request was not finite")
            return
        }
        #expect(cancellation.reason == .cancelled)
    }

    @Test func measurementAndEmptyOriginalAreRejectedBeforeAnyRequestExists() throws {
        #expect(throws: ShotAssessmentOperationError.measurementIsNotAssessable) {
            try makeOperation(suffix: "measurement", shot: .measurement)
        }
        #expect(throws: ShotAssessmentOperationError.emptyOriginalImage) {
            try makeOperation(suffix: "empty", bytes: Data())
        }
    }

    @Test func supersededCompletionIsStaleAndCannotReplaceCurrentAssessment() async throws {
        let transport = DelayedShotAssessmentTransport(responseBody: validAssessment(shot: .front))
        let client = try makeClient(transport: transport)
        let old = try makeOperation(suffix: "old", bytes: Data([1]))
        let current = try makeOperation(suffix: "current", bytes: Data([2]))

        async let oldOutcome = client.assess(old)
        await Task.yield()
        async let currentOutcome = client.assess(current)
        let results = await (oldOutcome, currentOutcome)

        #expect(results.0 == .discardedAsStale(.init(operation: old)))
        guard case .assessment(let descriptor, _) = results.1 else {
            Issue.record("current assessment was not retained")
            return
        }
        #expect(descriptor.imageID == current.imageID)
        guard case .assessed(_, let stateDescriptor, _) = await client.stateSnapshot() else {
            Issue.record("stale result replaced client state")
            return
        }
        #expect(stateDescriptor.imageID == current.imageID)
    }

    @Test func liveUnavailableMakesNoRequestAndNeverFallsBackToContractFixture() async throws {
        let transport = RecordingShotAssessmentTransport([
            .success((validAssessment(shot: .front), response(url: backendURL, status: 200)))
        ])
        let client = try makeClient(transport: transport, availability: .liveUnavailable)

        guard case .unavailable(let failure) = await client.assess(try makeOperation(suffix: "live")) else {
            Issue.record("live blocker was hidden")
            return
        }
        #expect(failure.reason == .liveEndpointUnavailable)
        #expect(await transport.requests.isEmpty)
    }
}

private let backendURL = URL(string: "http://assessment.example.test/api/analyze-shot")!

private func makeClient(
    transport: any ShotAssessmentTransport,
    availability: ShotAssessmentServiceAvailability = .fixtureContract,
    wireContract: ShotAssessmentWireContract = .frozenSwiftV1
) throws -> ShotAssessmentClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    return ShotAssessmentClient(
        backend: try BackendAPIClient(
            baseURL: URL(string: "http://assessment.example.test")!,
            session: URLSession(configuration: configuration),
            allowsInsecureTestURL: true
        ),
        transport: transport,
        availability: availability,
        wireContract: wireContract
    )
}

private func protocolTransport() -> URLSessionShotAssessmentTransport {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.protocolClasses = [ShotAssessmentProtocolStub.self]
    return URLSessionShotAssessmentTransport(session: URLSession(configuration: configuration))
}

private func makeOperation(
    suffix: String,
    shot: Shot = .front,
    bytes: Data = Data([10, 20, 30]),
    contentType: ImageContentType = .jpeg
) throws -> ShotAssessmentOperation {
    try .init(
        requestID: RequestID("assessment-request-\(suffix)"),
        imageID: ImageID("assessment-image-\(suffix)"),
        idempotencyKey: IdempotencyKey("assessment-operation-\(suffix)"),
        requestedShot: shot,
        originalImage: bytes,
        imageContentType: contentType,
        boundary: MultipartBoundary("assessment-boundary-\(suffix)")
    )
}

private func validAssessment(shot: Shot) -> Data {
    Data(
        "{\"shotType\":\"\(shot.rawValue)\",\"quality\":\"ok\",\"issues\":[],\"missingShots\":[],\"nextAction\":\"REQUEST_NEXT\"}".utf8
    )
}

private func response(
    url: URL,
    status: Int,
    contentType: String = "application/json; charset=utf-8"
) -> HTTPURLResponse {
    HTTPURLResponse(
        url: url,
        statusCode: status,
        httpVersion: nil,
        headerFields: ["Content-Type": contentType]
    )!
}

private func jsonResponse(for request: URLRequest) -> HTTPURLResponse {
    response(url: request.url ?? backendURL, status: 200)
}

private func waitUntil(_ predicate: () async -> Bool) async -> Bool {
    for _ in 0..<10_000 {
        if await predicate() { return true }
        await Task.yield()
    }
    return false
}

private func containsDataPayload(_ value: Any) -> Bool {
    if value is Data { return true }
    return Mirror(reflecting: value).children.contains { containsDataPayload($0.value) }
}
