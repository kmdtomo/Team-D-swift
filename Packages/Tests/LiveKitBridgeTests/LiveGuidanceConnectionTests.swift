import ContractKit
import DomainKit
import Foundation
@testable import LiveKitBridge
import Testing

@Test func tokenRequestAndRoomJoinUseTheExactSessionWithoutPollingOrTokenLogging() async throws {
    let tokenProvider = RecordingTokenProvider(response: try tokenResponse())
    let transport = FakeRoomTransport()
    let sut = try connection(tokenProvider: tokenProvider, transport: transport)

    await sut.join()
    #expect(await waitUntil { await sut.snapshot().phase == .connected })
    #expect(await tokenProvider.sessionIDs == ["session-123"])
    let joinRecords = await transport.joinRecords
    let join = try #require(joinRecords.first)
    #expect(join.sessionID == "session-123")
    #expect(join.description.contains("token: <redacted>"))
    #expect(!join.description.contains("fixture-bearer"))
    #expect(LiveGuidanceConnection.usesHTTPGuidancePolling == false)
}

@Test func joinLeaveAndAppProducedPublishRequestsAreIdempotent() async throws {
    let tokenProvider = RecordingTokenProvider(response: try tokenResponse())
    let transport = FakeRoomTransport()
    let sut = try connection(tokenProvider: tokenProvider, transport: transport)

    await sut.join()
    await sut.join()
    #expect(await waitUntil { await sut.snapshot().phase == .connected })
    await sut.join()
    #expect(await transport.joinRecords.count == 1)

    #expect(await waitUntil { await sut.snapshot().videoPublishState == .publishing })
    await sut.requestAppProducedVideoPublish()
    await sut.requestAppProducedVideoPublish()
    #expect(await sut.snapshot().videoPublishState == .publishing)
    #expect(await transport.publishRequests.count == 1)

    await sut.leave()
    await sut.leave()
    #expect(await sut.snapshot().phase == .disconnected)
    #expect(await transport.leaveHandles.count == 1)
}

@Test func lossyGuidanceIsStrictDecodedAndFilteredBeforeFiniteDelivery() async throws {
    let tokenProvider = RecordingTokenProvider(response: try tokenResponse())
    let transport = FakeRoomTransport()
    let receiver = OutputRecorder()
    let sut = try connection(
        tokenProvider: tokenProvider,
        transport: transport,
        receiver: receiver
    )
    await sut.join()
    #expect(await waitUntil { await sut.snapshot().phase == .connected })

    await transport.yieldLossy(try guidance(sequence: 1, code: .moveCloser), roomIndex: 0)
    await transport.yieldLossy(try guidance(sequence: 2, extraAction: true), roomIndex: 0)
    await transport.yieldLossy(try guidance(sessionID: "other", sequence: 3), roomIndex: 0)
    await transport.yieldLossy(try guidance(sequence: 4, shot: .back), roomIndex: 0)
    await transport.yieldLossy(try guidance(sequence: 5, observedAt: 800, expiresAt: 1_000), roomIndex: 0)
    await transport.yieldLossy(try guidance(sequence: 1), roomIndex: 0)

    #expect(await waitUntil {
        let snapshot = await sut.snapshot()
        return snapshot.acceptedGuidanceCount == 1 && snapshot.rejectedGuidanceCount == 5
    })
    let snapshot = await sut.snapshot()
    #expect(snapshot.lastAcceptedSequence == 1)
    #expect(snapshot.latestGuidance == .init(code: .moveCloser))
    #expect(snapshot.lastGuidanceRejection == .filtered(.sequenceNotNew))
    let outputs = await receiver.outputs
    #expect(outputs.count == 1)
    guard case .guidance(let delivery) = outputs[0] else {
        Issue.record("expected finite guidance output")
        return
    }
    #expect(delivery.sequence == 1)
    #expect(delivery.display == .init(code: .moveCloser))
    #expect(delivery.deliveryLatencyMilliseconds == 100)
    #expect(snapshot.latencySampleCount == 1)
    #expect(snapshot.guidanceDeliveryLatencyP95Milliseconds == 100)
}

@Test func currentTokenRoomNameIsTheOnlyAcceptedBackendGuidanceSessionAlias() async throws {
    let transport = FakeRoomTransport()
    let receiver = OutputRecorder()
    let sut = try connection(
        tokenProvider: RecordingTokenProvider(
            response: try tokenResponse(roomName: "listing-photo-session-session-123")
        ),
        transport: transport,
        receiver: receiver
    )
    await sut.join()
    #expect(await waitUntil { await sut.snapshot().phase == .connected })

    await transport.yieldLossy(
        try guidance(sessionID: "listing-photo-session-session-123", sequence: 1),
        roomIndex: 0
    )
    await transport.yieldLossy(
        try guidance(sessionID: "listing-photo-session-someone-else", sequence: 2),
        roomIndex: 0
    )

    #expect(await waitUntil {
        let snapshot = await sut.snapshot()
        return snapshot.acceptedGuidanceCount == 1 && snapshot.rejectedGuidanceCount == 1
    })
    let snapshot = await sut.snapshot()
    #expect(snapshot.lastAcceptedSequence == 1)
    #expect(snapshot.lastGuidanceRejection == .filtered(.sessionMismatch))
    let outputs = await receiver.outputs
    let delivery = try #require(outputs.compactMap { output -> LiveGuidanceDelivery? in
        guard case .guidance(let delivery) = output else { return nil }
        return delivery
    }.first)
    #expect(delivery.sessionID == "session-123")
}

@Test func reconnectReplacesTheTokenRoomGuidanceSessionAlias() async throws {
    let tokenProvider = SequencedTokenProvider(
        responses: [
            try tokenResponse(roomName: "listing-session-first"),
            try tokenResponse(roomName: "listing-session-second"),
        ]
    )
    let transport = FakeRoomTransport()
    let receiver = OutputRecorder()
    let sut = try connection(
        tokenProvider: tokenProvider,
        transport: transport,
        receiver: receiver
    )

    await sut.join()
    #expect(await waitUntil { await sut.snapshot().phase == .connected })
    await transport.yieldLossy(
        try guidance(sessionID: "listing-session-first", sequence: 1),
        roomIndex: 0
    )
    #expect(await waitUntil { await sut.snapshot().lastAcceptedSequence == 1 })

    await sut.leave()
    await sut.join()
    #expect(await waitUntil { await transport.joinRecords.count == 2 })
    #expect(await waitUntil { await sut.snapshot().phase == .connected })
    await transport.yieldLossy(
        try guidance(sessionID: "listing-session-first", sequence: 2),
        roomIndex: 1
    )
    await transport.yieldLossy(
        try guidance(sessionID: "listing-session-second", sequence: 2),
        roomIndex: 1
    )

    #expect(await waitUntil {
        let snapshot = await sut.snapshot()
        return snapshot.acceptedGuidanceCount == 2 && snapshot.rejectedGuidanceCount == 1
    })
    #expect(await receiver.guidanceSequences == [1, 2])
    #expect(await sut.snapshot().lastGuidanceRejection == .filtered(.sessionMismatch))
}

@Test func reliablePacketStaysOpaqueAndCannotMutateGuidanceOrWorkflowState() async throws {
    let tokenProvider = RecordingTokenProvider(response: try tokenResponse())
    let transport = FakeRoomTransport()
    let receiver = OutputRecorder()
    let sut = try connection(
        tokenProvider: tokenProvider,
        transport: transport,
        receiver: receiver
    )
    await sut.join()
    #expect(await waitUntil { await sut.snapshot().phase == .connected })

    let uncontracted = Data(#"{"nextAction":"COMPLETE","acceptSlot":true}"#.utf8)
    await transport.yieldReliable(uncontracted, participant: "agent", roomIndex: 0)
    #expect(await waitUntil { await sut.snapshot().opaqueReliablePacketCount == 1 })
    let snapshot = await sut.snapshot()
    #expect(snapshot.lastAcceptedSequence == nil)
    #expect(snapshot.latestGuidance == nil)
    let outputs = await receiver.outputs
    let first = try #require(outputs.first)
    guard case .opaqueReliablePacket(let packet) = first else {
        Issue.record("expected opaque reliable boundary")
        return
    }
    #expect(packet.payload == uncontracted)
    #expect(packet.participantIdentity == "agent")
}

@Test func deliveryLatencySnapshotReportsBoundedNearestRankP95() async throws {
    let transport = FakeRoomTransport()
    let sut = try connection(
        tokenProvider: RecordingTokenProvider(response: try tokenResponse()),
        transport: transport
    )
    await sut.join()
    #expect(await waitUntil { await sut.snapshot().phase == .connected })

    for latency in 1...20 {
        await transport.yieldLossy(
            try guidance(
                sequence: Int64(latency),
                observedAt: Int64(1_000 - latency),
                expiresAt: 2_000
            ),
            roomIndex: 0
        )
    }

    #expect(await waitUntil { await sut.snapshot().acceptedGuidanceCount == 20 })
    let metrics = await sut.snapshot()
    #expect(metrics.latencySampleCount == 20)
    #expect(metrics.guidanceDeliveryLatencyP95Milliseconds == 19)
}

@Test func oldRoomPacketsCannotCrossLeaveOrReconnectGeneration() async throws {
    let tokenProvider = RecordingTokenProvider(response: try tokenResponse())
    let transport = FakeRoomTransport()
    let receiver = OutputRecorder()
    let sut = try connection(
        tokenProvider: tokenProvider,
        transport: transport,
        receiver: receiver
    )
    await sut.join()
    #expect(await waitUntil { await sut.snapshot().phase == .connected })
    await transport.yieldLossy(try guidance(sequence: 5), roomIndex: 0)
    #expect(await waitUntil { await sut.snapshot().lastAcceptedSequence == 5 })

    await sut.leave()
    await transport.yieldLossy(try guidance(sequence: 99), roomIndex: 0)
    await sut.join()
    #expect(await waitUntil { await transport.joinRecords.count == 2 })
    #expect(await waitUntil { await sut.snapshot().phase == .connected })
    await transport.yieldLossy(try guidance(sequence: 4), roomIndex: 1)
    await transport.yieldLossy(try guidance(sequence: 6), roomIndex: 1)
    #expect(await waitUntil { await sut.snapshot().lastAcceptedSequence == 6 })

    let deliveries = await receiver.guidanceSequences
    #expect(deliveries == [5, 6])
    #expect(await sut.snapshot().guidanceConnection == .connected)
}

@Test func transportFailuresAndKnownUnavailablePathsStayExplicit() async throws {
    let tokenProvider = RecordingTokenProvider(response: try tokenResponse())
    let failedTransport = FakeRoomTransport(joinError: .connectionFailed)
    let failed = try connection(tokenProvider: tokenProvider, transport: failedTransport)
    await failed.join()
    #expect(await waitUntil { await failed.snapshot().phase == .failed(.roomJoinFailed) })

    let unavailable = try connection(
        tokenProvider: RecordingTokenProvider(response: try tokenResponse()),
        transport: UnavailableLiveGuidanceRoomTransport()
    )
    await unavailable.join()
    #expect(await waitUntil {
        await unavailable.snapshot().phase == .unavailable(.liveKitSDKNotLinked)
    })

    let publishUnavailableTransport = FakeRoomTransport(
        publishError: .unavailable(.appProducedVideoPublishHandoffUnavailable)
    )
    let publishUnavailable = try connection(
        tokenProvider: RecordingTokenProvider(response: try tokenResponse()),
        transport: publishUnavailableTransport
    )
    await publishUnavailable.join()
    #expect(await waitUntil { await publishUnavailable.snapshot().phase == .connected })
    #expect(await waitUntil {
        await publishUnavailable.snapshot().videoPublishState ==
            .unavailable(.appProducedVideoPublishHandoffUnavailable)
    })
}

@Test func tokenLifetimeBeyondTheFiveMinuteHardMaximumIsRejectedBeforeRoomJoin() async throws {
    let overlong = try LiveKitTokenResponse(
        token: "unit-test-value",
        participantIdentity: "ios-session-123",
        roomName: "listing-session-123",
        expiresAt: 302,
        livekitUrl: "wss://livekit.example.invalid"
    )
    let transport = FakeRoomTransport()
    let sut = try connection(
        tokenProvider: RecordingTokenProvider(response: overlong),
        transport: transport
    )

    await sut.join()

    #expect(await waitUntil {
        await sut.snapshot().phase == .failed(.tokenLifetimeExceedsHardMaximum)
    })
    #expect(await transport.joinRecords.isEmpty)
}

@Test func roomStatusAdapterExposesReconnectWithoutChangingCaptureWorkflowAndFailsOnDisconnect() async throws {
    let tokenProvider = RecordingTokenProvider(response: try tokenResponse())
    let transport = FakeRoomTransport()
    let sut = try connection(tokenProvider: tokenProvider, transport: transport)
    await sut.join()
    #expect(await waitUntil { await sut.snapshot().phase == .connected })

    await transport.yieldStatus(.reconnecting, roomIndex: 0)
    #expect(await waitUntil { await sut.snapshot().phase == .reconnecting })
    let reconnecting = await sut.snapshot()
    #expect(reconnecting.guidanceConnection == .reconnecting)
    #expect(reconnecting.currentShot == .front)

    await transport.yieldStatus(.connected, roomIndex: 0)
    #expect(await waitUntil { await sut.snapshot().phase == .connected })
    await transport.yieldStatus(.disconnected, roomIndex: 0)
    #expect(await waitUntil {
        await sut.snapshot().phase == .failed(.transportDisconnected)
    })
    #expect(await transport.leaveHandles.count == 1)
}

@Test func leaveCancelsAnOutstandingTokenRequestWithoutJoiningARoom() async throws {
    let tokenProvider = SuspendingTokenProvider(response: try tokenResponse())
    let transport = FakeRoomTransport()
    let sut = try connection(tokenProvider: tokenProvider, transport: transport)

    await sut.join()
    #expect(await waitUntil { await tokenProvider.started })
    await sut.leave()
    #expect(await waitUntil { await tokenProvider.cancelled })
    #expect(await sut.snapshot().phase == .disconnected)
    #expect(await transport.joinRecords.isEmpty)
}

@Test func unexpectedPacketStreamEndFailsAndLeavesTheRoomOnce() async throws {
    let tokenProvider = RecordingTokenProvider(response: try tokenResponse())
    let transport = FakeRoomTransport()
    let sut = try connection(tokenProvider: tokenProvider, transport: transport)
    await sut.join()
    #expect(await waitUntil { await sut.snapshot().phase == .connected })

    await transport.finishLossy(roomIndex: 0)
    #expect(await waitUntil { await sut.snapshot().phase == .failed(.packetStreamEnded) })
    #expect(await transport.leaveHandles.count == 1)
}

private struct TestClock: GuidanceEpochMillisecondsClock {
    func nowEpochMilliseconds() -> Int64 { 1_000 }
}

private func connection(
    tokenProvider: any LiveGuidanceTokenProviding,
    transport: any LiveGuidanceRoomTransporting,
    receiver: any LiveGuidanceConnectionOutputReceiving = DiscardingLiveGuidanceOutputReceiver()
) throws -> LiveGuidanceConnection {
    let ids = RequestIDs()
    return try LiveGuidanceConnection(
        sessionID: "session-123",
        currentShot: .front,
        tokenProvider: tokenProvider,
        transport: transport,
        clock: TestClock(),
        receiver: receiver,
        makeRequestID: { ids.next() }
    )
}

private func tokenResponse(
    roomName: String = "listing-session-123"
) throws -> LiveKitTokenResponse {
    try .init(
        token: "fixture-bearer",
        participantIdentity: "ios-session-123",
        roomName: roomName,
        expiresAt: 90,
        livekitUrl: "wss://livekit.example.invalid"
    )
}

private func guidance(
    sessionID: String = "session-123",
    sequence: Int64,
    shot: Shot = .front,
    code: GuidanceCode = .ready,
    observedAt: Int64 = 900,
    expiresAt: Int64 = 2_000,
    extraAction: Bool = false
) throws -> Data {
    let event = try GuidanceEvent(
        sessionId: sessionID,
        sequence: sequence,
        shot: shot,
        code: code,
        message: "backend prose must not escape",
        confidence: 0.99,
        observedAt: observedAt,
        expiresAt: expiresAt
    )
    let encoded = try JSONEncoder().encode(event)
    guard extraAction else { return encoded }
    var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    object["nextAction"] = "COMPLETE"
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func waitUntil(_ predicate: () async -> Bool) async -> Bool {
    for _ in 0..<10_000 {
        if await predicate() { return true }
        await Task.yield()
    }
    return false
}

private final class RequestIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt32 = 1

    func next() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        let suffix = String(format: "%012x", value)
        value &+= 1
        return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
    }
}

private actor RecordingTokenProvider: LiveGuidanceTokenProviding {
    private let response: LiveKitTokenResponse
    private(set) var sessionIDs: [String] = []

    init(response: LiveKitTokenResponse) { self.response = response }

    func fetchToken(for request: LiveKitTokenRequest) async throws -> LiveKitTokenResponse {
        sessionIDs.append(request.sessionId)
        return response
    }
}

private actor SequencedTokenProvider: LiveGuidanceTokenProviding {
    private var responses: [LiveKitTokenResponse]

    init(responses: [LiveKitTokenResponse]) { self.responses = responses }

    func fetchToken(for request: LiveKitTokenRequest) async throws -> LiveKitTokenResponse {
        _ = request
        return responses.removeFirst()
    }
}

private actor SuspendingTokenProvider: LiveGuidanceTokenProviding {
    private let response: LiveKitTokenResponse
    private(set) var started = false
    private(set) var cancelled = false

    init(response: LiveKitTokenResponse) { self.response = response }

    func fetchToken(for request: LiveKitTokenRequest) async throws -> LiveKitTokenResponse {
        _ = request
        started = true
        do {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return response
        } catch {
            cancelled = true
            throw CancellationError()
        }
    }
}

private struct JoinRecord: Sendable {
    let sessionID: String
    let description: String
}

private struct RoomPipe: Sendable {
    let lossy: AsyncStream<LiveGuidanceTransportPacket>
    let lossyContinuation: AsyncStream<LiveGuidanceTransportPacket>.Continuation
    let reliable: AsyncStream<LiveGuidanceTransportPacket>
    let reliableContinuation: AsyncStream<LiveGuidanceTransportPacket>.Continuation
    let statuses: AsyncStream<LiveGuidanceTransportConnectionStatus>
    let statusContinuation: AsyncStream<LiveGuidanceTransportConnectionStatus>.Continuation
}

private actor FakeRoomTransport: LiveGuidanceRoomTransporting {
    private let joinError: LiveGuidanceTransportError?
    private let publishError: LiveGuidanceTransportError?
    private(set) var joinRecords: [JoinRecord] = []
    private(set) var leaveHandles: [UUID] = []
    private(set) var publishRequests: [LiveGuidanceVideoPublishRequest] = []
    private var rooms: [RoomPipe] = []

    init(
        joinError: LiveGuidanceTransportError? = nil,
        publishError: LiveGuidanceTransportError? = nil
    ) {
        self.joinError = joinError
        self.publishError = publishError
    }

    func join(_ request: LiveGuidanceRoomJoinRequest) async throws -> LiveGuidanceJoinedRoom {
        if let joinError { throw joinError }
        joinRecords.append(.init(sessionID: request.sessionID, description: request.description))
        let lossy = AsyncStream<LiveGuidanceTransportPacket>.makeStream()
        let reliable = AsyncStream<LiveGuidanceTransportPacket>.makeStream()
        let statuses = AsyncStream<LiveGuidanceTransportConnectionStatus>.makeStream()
        rooms.append(
            .init(
                lossy: lossy.stream,
                lossyContinuation: lossy.continuation,
                reliable: reliable.stream,
                reliableContinuation: reliable.continuation,
                statuses: statuses.stream,
                statusContinuation: statuses.continuation
            )
        )
        return .init(
            handle: request.requestID,
            lossyPackets: lossy.stream,
            reliablePackets: reliable.stream,
            statusChanges: statuses.stream
        )
    }

    func leave(_ room: UUID) async { leaveHandles.append(room) }

    func requestAppProducedVideoPublish(
        _ request: LiveGuidanceVideoPublishRequest,
        in room: UUID
    ) async throws {
        _ = room
        publishRequests.append(request)
        if let publishError { throw publishError }
    }

    func yieldLossy(_ data: Data, roomIndex: Int) {
        rooms[roomIndex].lossyContinuation.yield(.init(payload: data))
    }

    func yieldReliable(_ data: Data, participant: String, roomIndex: Int) {
        rooms[roomIndex].reliableContinuation.yield(
            .init(payload: data, participantIdentity: participant)
        )
    }

    func finishLossy(roomIndex: Int) { rooms[roomIndex].lossyContinuation.finish() }
    func yieldStatus(_ status: LiveGuidanceTransportConnectionStatus, roomIndex: Int) {
        rooms[roomIndex].statusContinuation.yield(status)
    }
}

private actor OutputRecorder: LiveGuidanceConnectionOutputReceiving {
    private(set) var outputs: [LiveGuidanceConnectionOutput] = []

    var guidanceSequences: [Int64] {
        outputs.compactMap {
            guard case .guidance(let delivery) = $0 else { return nil }
            return delivery.sequence
        }
    }

    func receive(_ output: LiveGuidanceConnectionOutput) async { outputs.append(output) }
}
