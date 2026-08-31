import ContractKit
import DomainKit
import Foundation
@testable import LiveKitBridge
import Testing

@Test func initialJoinPublishesTheFrozenContextReliablyOnTheExactTopic() async throws {
    let transport = CaptureContextRoomTransport()
    let sut = try captureContextConnection(transport: transport)

    await sut.join()

    #expect(await captureContextWaitUntil { await transport.publishRecords.count == 1 })
    let record = try #require(await transport.publishRecords.first)
    let context = try JSONDecoder().decode(CaptureContextV1.self, from: record.request.payload)
    #expect(record.request.topic == "teamd.capture.context.v1")
    #expect(context.type == "capture_context")
    #expect(context.sessionId == "session-123")
    #expect(context.revision == 1)
    #expect(context.shot == .front)
    #expect(context.acceptedShots.isEmpty)
    #expect(context.lastGuidanceSequence == nil)
    #expect(await captureContextWaitUntil {
        await sut.snapshot().captureContextPublishState == .published(1)
    })
}

@Test func captureUpdateUsesCanonicalSlotsAndTheLastAcceptedGuidanceSequence() async throws {
    let transport = CaptureContextRoomTransport()
    let sut = try captureContextConnection(transport: transport)
    await sut.join()
    #expect(await captureContextWaitUntil { await transport.publishRecords.count == 1 })

    await transport.yieldLossy(
        try captureContextGuidance(sequence: 8, shot: .front),
        roomIndex: 0
    )
    #expect(await captureContextWaitUntil { await sut.snapshot().lastAcceptedSequence == 8 })

    await sut.updateCaptureContext(
        currentShot: .measurement,
        acceptedShots: [.tag, .front, .back]
    )

    #expect(await captureContextWaitUntil { await transport.publishRecords.count == 2 })
    let record = try #require(await transport.publishRecords.last)
    let context = try JSONDecoder().decode(CaptureContextV1.self, from: record.request.payload)
    #expect(context.revision == 2)
    #expect(context.shot == .measurement)
    #expect(context.acceptedShots == [.front, .back, .tag])
    #expect(context.lastGuidanceSequence == 8)
    #expect(await sut.snapshot().currentShot == .measurement)

    // An explicit same-state update represents a retake/resync event and must
    // still advance the monotonic revision.
    await sut.updateCaptureContext(
        currentShot: .measurement,
        acceptedShots: [.front, .back, .tag]
    )
    #expect(await captureContextWaitUntil { await transport.publishRecords.count == 3 })
    let retakeRecord = try #require(await transport.publishRecords.last)
    let retake = try JSONDecoder().decode(
        CaptureContextV1.self,
        from: retakeRecord.request.payload
    )
    #expect(retake.revision == 3)
    #expect(retake.lastGuidanceSequence == 8)
}

@Test func reconnectRecoveryRehydratesWithANewMonotonicRevision() async throws {
    let transport = CaptureContextRoomTransport()
    let sut = try captureContextConnection(transport: transport)
    await sut.join()
    #expect(await captureContextWaitUntil { await transport.publishRecords.count == 1 })
    await sut.updateCaptureContext(currentShot: .back, acceptedShots: [.front])
    #expect(await captureContextWaitUntil { await transport.publishRecords.count == 2 })

    await transport.yieldStatus(.reconnecting, roomIndex: 0)
    #expect(await captureContextWaitUntil { await sut.snapshot().phase == .reconnecting })
    await transport.yieldStatus(.connected, roomIndex: 0)

    #expect(await captureContextWaitUntil { await transport.publishRecords.count == 3 })
    let context = try JSONDecoder().decode(
        CaptureContextV1.self,
        from: #require(await transport.publishRecords.last).request.payload
    )
    #expect(context.revision == 3)
    #expect(context.shot == .back)
    #expect(context.acceptedShots == [.front])
    #expect(await captureContextWaitUntil {
        await sut.snapshot().captureContextPublishState == .published(3)
    })
}

@Test func reliableSendFailureRemainsVisibleAndManualRetryUsesANewRevision() async throws {
    let transport = CaptureContextRoomTransport(failingPublishOrdinals: [0])
    let sut = try captureContextConnection(transport: transport)

    await sut.join()

    #expect(await captureContextWaitUntil {
        await sut.snapshot().captureContextPublishState == .failed(1)
    })
    #expect(await sut.snapshot().phase == .connected)
    #expect(await transport.publishRecords.count == 1)

    await sut.retryCaptureContextPublish()

    #expect(await captureContextWaitUntil { await transport.publishRecords.count == 2 })
    let retried = try JSONDecoder().decode(
        CaptureContextV1.self,
        from: #require(await transport.publishRecords.last).request.payload
    )
    #expect(retried.revision == 2)
    #expect(await captureContextWaitUntil {
        await sut.snapshot().captureContextPublishState == .published(2)
    })
}

@Test func staleRoomSendCompletionCannotRegressReconnectedContextState() async throws {
    let transport = CaptureContextRoomTransport(blockedPublishOrdinals: [0])
    let sut = try captureContextConnection(transport: transport)
    await sut.join()
    #expect(await captureContextWaitUntil { await transport.publishRecords.count == 1 })

    await sut.leave()
    await sut.join()
    #expect(await captureContextWaitUntil { await transport.publishRecords.count == 2 })
    #expect(await captureContextWaitUntil {
        await sut.snapshot().captureContextPublishState == .published(2)
    })

    await transport.releasePublish(ordinal: 0)
    for _ in 0..<100 { await Task.yield() }

    #expect(await sut.snapshot().captureContextPublishState == .published(2))
    let staleCompletionRecords = await transport.publishRecords
    let contexts = try staleCompletionRecords.map {
        try JSONDecoder().decode(CaptureContextV1.self, from: $0.request.payload)
    }
    #expect(contexts.map(\.revision) == [1, 2])
}

@Test func contextPublisherKeepsOnlyTheLatestPendingUpdate() async throws {
    let transport = CaptureContextRoomTransport(blockedPublishOrdinals: [0])
    let sut = try captureContextConnection(transport: transport)
    await sut.join()
    #expect(await captureContextWaitUntil { await transport.publishRecords.count == 1 })

    await sut.updateCaptureContext(currentShot: .back, acceptedShots: [.front])
    await sut.updateCaptureContext(currentShot: .tag, acceptedShots: [.back, .front])
    await sut.updateCaptureContext(
        currentShot: .measurement,
        acceptedShots: [.tag, .front, .back]
    )

    #expect(await transport.publishRecords.count == 1)
    #expect(await sut.snapshot().captureContextPublishState == .pending(4))
    await transport.releasePublish(ordinal: 0)

    #expect(await captureContextWaitUntil { await transport.publishRecords.count == 2 })
    let latestOnlyRecords = await transport.publishRecords
    let contexts = try latestOnlyRecords.map {
        try JSONDecoder().decode(CaptureContextV1.self, from: $0.request.payload)
    }
    #expect(contexts.map(\.revision) == [1, 4])
    #expect(contexts.last?.shot == .measurement)
    #expect(contexts.last?.acceptedShots == [.front, .back, .tag])
    #expect(await captureContextWaitUntil {
        await sut.snapshot().captureContextPublishState == .published(4)
    })
}

private struct CaptureContextTestClock: GuidanceEpochMillisecondsClock {
    func nowEpochMilliseconds() -> Int64 { 1_000 }
}

private func captureContextConnection(
    transport: any LiveGuidanceRoomTransporting
) throws -> LiveGuidanceConnection {
    try LiveGuidanceConnection(
        sessionID: "session-123",
        currentShot: .front,
        tokenProvider: CaptureContextTokenProvider(),
        transport: transport,
        clock: CaptureContextTestClock()
    )
}

private struct CaptureContextTokenProvider: LiveGuidanceTokenProviding {
    func fetchToken(for request: LiveKitTokenRequest) async throws -> LiveKitTokenResponse {
        try LiveKitTokenResponse(
            token: "unit-test-token",
            participantIdentity: "ios-\(request.sessionId)",
            roomName: "listing-\(request.sessionId)",
            expiresAt: 90,
            livekitUrl: "wss://livekit.example.invalid"
        )
    }
}

private struct CaptureContextPublishRecord: Sendable {
    let request: LiveGuidanceReliableDataPublishRequest
    let room: UUID
}

private struct CaptureContextRoomPipe: Sendable {
    let lossyContinuation: AsyncStream<LiveGuidanceTransportPacket>.Continuation
    let reliableContinuation: AsyncStream<LiveGuidanceTransportPacket>.Continuation
    let statusContinuation: AsyncStream<LiveGuidanceTransportConnectionStatus>.Continuation
}

private actor CaptureContextRoomTransport: LiveGuidanceRoomTransporting {
    private let failingPublishOrdinals: Set<Int>
    private let blockedPublishOrdinals: Set<Int>
    private var rooms: [CaptureContextRoomPipe] = []
    private var blockedContinuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private(set) var publishRecords: [CaptureContextPublishRecord] = []

    init(
        failingPublishOrdinals: Set<Int> = [],
        blockedPublishOrdinals: Set<Int> = []
    ) {
        self.failingPublishOrdinals = failingPublishOrdinals
        self.blockedPublishOrdinals = blockedPublishOrdinals
    }

    func join(_ request: LiveGuidanceRoomJoinRequest) async throws -> LiveGuidanceJoinedRoom {
        let lossy = AsyncStream<LiveGuidanceTransportPacket>.makeStream()
        let reliable = AsyncStream<LiveGuidanceTransportPacket>.makeStream()
        let statuses = AsyncStream<LiveGuidanceTransportConnectionStatus>.makeStream()
        rooms.append(
            .init(
                lossyContinuation: lossy.continuation,
                reliableContinuation: reliable.continuation,
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

    func leave(_ room: UUID) async { _ = room }

    func requestAppProducedVideoPublish(
        _ request: LiveGuidanceVideoPublishRequest,
        in room: UUID
    ) async throws {
        _ = request
        _ = room
    }

    func publishReliableData(
        _ request: LiveGuidanceReliableDataPublishRequest,
        in room: UUID
    ) async throws {
        let ordinal = publishRecords.count
        publishRecords.append(.init(request: request, room: room))
        if failingPublishOrdinals.contains(ordinal) {
            throw LiveGuidanceTransportError.reliableDataPublishFailed
        }
        if blockedPublishOrdinals.contains(ordinal) {
            await withCheckedContinuation { continuation in
                blockedContinuations[ordinal] = continuation
            }
        }
    }

    func releasePublish(ordinal: Int) {
        blockedContinuations.removeValue(forKey: ordinal)?.resume()
    }

    func yieldLossy(_ data: Data, roomIndex: Int) {
        rooms[roomIndex].lossyContinuation.yield(.init(payload: data))
    }

    func yieldStatus(_ status: LiveGuidanceTransportConnectionStatus, roomIndex: Int) {
        rooms[roomIndex].statusContinuation.yield(status)
    }
}

private func captureContextGuidance(sequence: Int64, shot: Shot) throws -> Data {
    try JSONEncoder().encode(
        GuidanceEvent(
            sessionId: "session-123",
            sequence: sequence,
            shot: shot,
            code: .ready,
            message: "not forwarded in capture context",
            confidence: 0.9,
            observedAt: 900,
            expiresAt: 2_000
        )
    )
}

private func captureContextWaitUntil(_ predicate: () async -> Bool) async -> Bool {
    for _ in 0..<10_000 {
        if await predicate() { return true }
        await Task.yield()
    }
    return false
}
