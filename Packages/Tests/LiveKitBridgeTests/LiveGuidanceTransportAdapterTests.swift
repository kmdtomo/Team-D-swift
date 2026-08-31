import ContractKit
import CaptureKit
import Foundation
@testable import LiveKitBridge
import Testing

@Test func systemGuidanceClockConvertsInjectedEpochTimeWithoutRoundingForward() {
    let clock = SystemGuidanceEpochMillisecondsClock(
        now: { Date(timeIntervalSince1970: 1_000.1239) }
    )

    #expect(clock.nowEpochMilliseconds() == 1_000_123)
    #expect(
        SystemGuidanceEpochMillisecondsClock(
            now: { Date(timeIntervalSince1970: -1) }
        ).nowEpochMilliseconds() == -1
    )
    #expect(
        SystemGuidanceEpochMillisecondsClock(
            now: { Date(timeIntervalSince1970: Double(Int64.max) / 1_000) }
        ).nowEpochMilliseconds() == -1
    )
}

@Test func tokenProviderPostsOnlyTheStrictSessionRequestToTheTokenEndpoint() async throws {
    let response = try LiveKitTokenResponse(
        token: "unit-test-value",
        participantIdentity: "ios-session-123",
        roomName: "listing-session-123",
        expiresAt: 90,
        livekitUrl: "wss://livekit.example.invalid"
    )
    let transport = TokenHTTPRecorder(
        result: .success((
            try JSONEncoder().encode(response),
            try httpResponse(status: 200, contentType: "application/json; charset=utf-8")
        ))
    )
    let sut = try URLSessionLiveGuidanceTokenProvider(
        baseURL: URL(string: "http://127.0.0.1:9090/root")!,
        transport: transport,
        allowsInsecureTestURL: true
    )

    let token = try await sut.fetchToken(for: LiveKitTokenRequest(sessionId: "session-123"))

    #expect(token == response)
    let requests = await transport.requests
    let request = try #require(requests.first)
    #expect(requests.count == 1)
    #expect(request.url?.path == "/root/api/livekit-token")
    #expect(request.httpMethod == "POST")
    #expect(request.timeoutInterval == 10)
    #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(
        try JSONDecoder().decode(LiveKitTokenRequest.self, from: #require(request.httpBody)) ==
            LiveKitTokenRequest(sessionId: "session-123")
    )
    #expect(URLSessionLiveGuidanceTokenProvider.usesGuidancePolling == false)
    #expect(requests.allSatisfy { $0.url?.path != "/api/analyze-live" })
}

@Test func tokenProviderRejectsNonJSONAndInvalidStrictResponses() async throws {
    let nonJSON = TokenHTTPRecorder(
        result: .success((Data("{}".utf8), try httpResponse(status: 200, contentType: "text/plain")))
    )
    let wrongContentType = try URLSessionLiveGuidanceTokenProvider(
        baseURL: URL(string: "https://backend.example.invalid")!,
        transport: nonJSON
    )
    await #expect(throws: LiveGuidanceTokenProviderError.invalidContentType) {
        try await wrongContentType.fetchToken(for: LiveKitTokenRequest(sessionId: "session-123"))
    }

    let unknownKey = Data(#"{"token":"x","participantIdentity":"ios","roomName":"room","expiresAt":90,"livekitUrl":"wss://livekit.example.invalid","extra":true}"#.utf8)
    let invalid = TokenHTTPRecorder(
        result: .success((unknownKey, try httpResponse(status: 200, contentType: "application/json")))
    )
    let invalidResponse = try URLSessionLiveGuidanceTokenProvider(
        baseURL: URL(string: "https://backend.example.invalid")!,
        transport: invalid
    )
    await #expect(throws: LiveGuidanceTokenProviderError.invalidResponse) {
        try await invalidResponse.fetchToken(for: LiveKitTokenRequest(sessionId: "session-123"))
    }
}

@Test func roomEventHubRoutesOnlyVersionedLossyAndReliableTopics() async throws {
    let hub = LiveGuidanceRoomEventHub(topics: .version1)
    let streams = await hub.streams()
    let lossyPayload = Data("lossy".utf8)
    let reliablePayload = Data("reliable".utf8)

    await hub.receive(data: Data("ignored".utf8), topic: "unknown.v1", participantIdentity: "agent")
    await hub.receive(
        data: lossyPayload,
        topic: LiveGuidanceDataTopics.version1.lossyGuidance,
        participantIdentity: "agent"
    )
    await hub.receive(
        data: reliablePayload,
        topic: LiveGuidanceDataTopics.version1.reliableState,
        participantIdentity: "agent"
    )

    var lossy = streams.lossy.makeAsyncIterator()
    var reliable = streams.reliable.makeAsyncIterator()
    #expect(await lossy.next() == .init(payload: lossyPayload, participantIdentity: "agent"))
    #expect(await reliable.next() == .init(payload: reliablePayload, participantIdentity: "agent"))
}

@Test func captureForwarderKeepsOnePendingSampleAndDoesNotCreatePerFrameWork() async throws {
    let transport = GatedCaptureSampleTransport()
    let forwarder = LiveGuidanceCaptureSampleForwarder(
        transport: transport,
        orientation: { .portrait }
    )

    forwarder.receive(.init(sequence: 1, timestampNanoseconds: 1))
    await transport.waitForFirstOffer()
    forwarder.receive(.init(sequence: 2, timestampNanoseconds: 2))
    forwarder.receive(.init(sequence: 3, timestampNanoseconds: 3))
    #expect(forwarder.snapshot().pendingSequence == 3)
    #expect(forwarder.snapshot().droppedSampleCount == 1)

    await transport.releaseFirstOffer()
    await transport.waitForSequences([1, 3])

    let snapshot = forwarder.snapshot()
    #expect(snapshot.offeredSampleCount == 2)
    #expect(snapshot.failedOfferCount == 0)
    forwarder.stop()
    forwarder.receive(.init(sequence: 4, timestampNanoseconds: 4))
    #expect(!forwarder.snapshot().isActive)
    #expect(await transport.sequences == [1, 3])
}

private actor TokenHTTPRecorder: LiveGuidanceTokenHTTPTransport {
    private let result: Result<(Data, URLResponse), Error>
    private(set) var requests: [URLRequest] = []

    init(result: Result<(Data, URLResponse), Error>) {
        self.result = result
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        return try result.get()
    }
}

private actor GatedCaptureSampleTransport: LiveGuidanceCaptureSampleOffering {
    private(set) var sequences: [UInt64] = []
    private var firstStarted = false
    private var firstReleased = false

    func offer(
        sample: AnalysisSample,
        orientation: CaptureVideoOrientation
    ) async throws -> Bool {
        #expect(orientation == .portrait)
        sequences.append(sample.sequence)
        if sample.sequence == 1 {
            firstStarted = true
            while !firstReleased { await Task.yield() }
        }
        return true
    }

    func waitForFirstOffer() async {
        while !firstStarted { await Task.yield() }
    }

    func releaseFirstOffer() { firstReleased = true }

    func waitForSequences(_ expected: [UInt64]) async {
        while sequences != expected { await Task.yield() }
    }
}

private func httpResponse(status: Int, contentType: String) throws -> HTTPURLResponse {
    try #require(
        HTTPURLResponse(
            url: URL(string: "https://backend.example.invalid/api/livekit-token")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": contentType]
        )
    )
}
