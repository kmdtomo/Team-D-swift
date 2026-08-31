import ContractKit
import DomainKit
import Foundation
import Testing
@testable import APIClient

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
        if request.httpBody?.contains(Data([1])) == true {
            try await Task.sleep(for: .milliseconds(100))
        }
        return (responseBody, jsonResponse(for: request))
    }
}

@Suite("T09-01 shot assessment client")
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
            let transport = RecordingShotAssessmentTransport([
                .success((validAssessment(shot: shot), response(url: backendURL, status: 200)))
            ])
            let client = try makeClient(transport: transport)

            guard case .assessment(let descriptor, _) = await client.assess(operation) else {
                Issue.record("valid assessment was not returned")
                continue
            }
            #expect(descriptor.requestedShot.rawValue == shot.rawValue)
            let requests = await transport.requests
            let request = try #require(requests.first)
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/api/analyze-shot")
            #expect(request.timeoutInterval == 20)
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=assessment-boundary-\(index)")
            #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "assessment-request-\(index)")
            let expected = MultipartForm(boundary: try MultipartBoundary("assessment-boundary-\(index)")).analyzeBody(
                shot: try #require(AssessableShot(rawValue: shot.rawValue)),
                data: operation.originalImage,
                contentType: contentType
            )
            #expect(request.httpBody == expected)
            #expect(operation.normalizationPolicy == .preserveHighResolutionOriginal)
        }
    }

    @Test func acceptsStrictRetryAssessmentButRejectsContradictoryOKShot() async throws {
        let retry = #"{"shotType":"back","quality":"retry","issues":["WRONG_SHOT"],"missingShots":["front","tag"],"nextAction":"RETAKE"}"#
        let mismatchOK = #"{"shotType":"back","quality":"ok","issues":[],"missingShots":["tag"],"nextAction":"REQUEST_NEXT"}"#
        let transport = RecordingShotAssessmentTransport([
            .success((Data(retry.utf8), response(url: backendURL, status: 200))),
            .success((Data(mismatchOK.utf8), response(url: backendURL, status: 200))),
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
    }

    @Test(arguments: [
        #"{"shotType":"front","quality":"ok","issues":[],"missingShots":["back","tag"],"nextAction":"REQUEST_NEXT","confidence":0.9}"#,
        #"{"shotType":"front","quality":"ok","issues":[],"missingShots":["back","tag"]}"#,
        #"{"shotType":"front","quality":"great","issues":[],"missingShots":["back","tag"],"nextAction":"REQUEST_NEXT"}"#,
        #"{"shotType":"front","quality":"ok","issues":["OPEN_ISSUE"],"missingShots":["back","tag"],"nextAction":"REQUEST_NEXT"}"#,
        #"{"shotType":"front","quality":"ok","issues":[],"missingShots":["measurement"],"nextAction":"REQUEST_NEXT"}"#,
        #"{"shotType":"front","quality":"ok","issues":{},"missingShots":["back","tag"],"nextAction":"REQUEST_NEXT"}"#,
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
        let transport = RecordingShotAssessmentTransport([
            .success((Data(provider.utf8), response(url: backendURL, status: 503))),
            .success((Data(wrongProvider.utf8), response(url: backendURL, status: 503))),
            .success((validAssessment(shot: .front), response(url: backendURL, status: 200, contentType: "text/plain"))),
        ])
        let client = try makeClient(transport: transport)

        guard case .failed(let providerFailure) = await client.assess(try makeOperation(suffix: "provider")),
              case .provider(let decoded) = providerFailure.reason else {
            Issue.record("strict provider error was not preserved")
            return
        }
        #expect(decoded.provider == .shotAssessor)
        #expect(decoded.retryable)

        guard case .failed(let statusFailure) = await client.assess(try makeOperation(suffix: "wrong-provider")) else {
            Issue.record("wrong provider envelope was accepted")
            return
        }
        #expect(statusFailure.reason == .unexpectedStatus(503))

        guard case .failed(let typeFailure) = await client.assess(try makeOperation(suffix: "content-type")) else {
            Issue.record("wrong content type was accepted")
            return
        }
        #expect(typeFailure.reason == .invalidContentType)
    }

    @Test func mapsTimeoutAndExplicitCancellationWithoutRetainingImageBytes() async throws {
        let timeout = RecordingShotAssessmentTransport([.failure(URLError(.timedOut))])
        let timeoutClient = try makeClient(transport: timeout)
        let timeoutOperation = try makeOperation(suffix: "timeout", bytes: Data([7, 7, 7]))
        guard case .failed(let timeoutFailure) = await timeoutClient.assess(timeoutOperation) else {
            Issue.record("timeout was not finite")
            return
        }
        #expect(timeoutFailure.reason == .timedOut)
        #expect(!String(reflecting: await timeoutClient.stateSnapshot()).contains("BwcH"))

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
    availability: ShotAssessmentServiceAvailability = .fixtureContract
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
        availability: availability
    )
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
