import ContractKit
import DomainKit
import Foundation

/// The core can request only the frozen `/api/livekit-token` contract. It has
/// no HTTP camera-upload or guidance-polling dependency.
public protocol LiveGuidanceTokenProviding: Sendable {
    func fetchToken(for request: LiveKitTokenRequest) async throws -> LiveKitTokenResponse
}

public enum LiveGuidanceProductionBlocker: Error, Equatable, Sendable {
    case liveKitSDKNotLinked
    case appProducedVideoPublishHandoffUnavailable
    case agentGuidancePushUnavailable
    case reliableDataPublishUnavailable
}

public enum LiveGuidanceTransportError: Error, Equatable, Sendable {
    case unavailable(LiveGuidanceProductionBlocker)
    case connectionFailed
    case appProducedVideoPublishFailed
    case reliableDataPublishFailed
    case cancelled
}

/// Passed directly to the Room transport and never retained by the connection.
/// Textual representations redact the bearer token.
public struct LiveGuidanceRoomJoinRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let sessionID: String
    public let requestID: UUID
    public let generation: UInt64
    public let liveKitURL: URL
    public let roomName: String
    public let participantIdentity: String
    public let token: String

    public init(
        sessionID: String,
        requestID: UUID,
        generation: UInt64,
        liveKitURL: URL,
        roomName: String,
        participantIdentity: String,
        token: String
    ) {
        self.sessionID = sessionID
        self.requestID = requestID
        self.generation = generation
        self.liveKitURL = liveKitURL
        self.roomName = roomName
        self.participantIdentity = participantIdentity
        self.token = token
    }

    public var description: String {
        "LiveGuidanceRoomJoinRequest(sessionID: \(sessionID), requestID: \(requestID), token: <redacted>)"
    }

    public var debugDescription: String { description }
}

public struct LiveGuidanceTransportPacket: Equatable, Sendable {
    public let payload: Data
    public let participantIdentity: String?

    public init(payload: Data, participantIdentity: String? = nil) {
        self.payload = payload
        self.participantIdentity = participantIdentity
    }
}

public struct LiveGuidanceJoinedRoom: Sendable {
    public let handle: UUID
    public let lossyPackets: AsyncStream<LiveGuidanceTransportPacket>
    public let reliablePackets: AsyncStream<LiveGuidanceTransportPacket>
    public let statusChanges: AsyncStream<LiveGuidanceTransportConnectionStatus>

    public init(
        handle: UUID,
        lossyPackets: AsyncStream<LiveGuidanceTransportPacket>,
        reliablePackets: AsyncStream<LiveGuidanceTransportPacket>,
        statusChanges: AsyncStream<LiveGuidanceTransportConnectionStatus>
    ) {
        self.handle = handle
        self.lossyPackets = lossyPackets
        self.reliablePackets = reliablePackets
        self.statusChanges = statusChanges
    }
}

public struct LiveGuidanceVideoPublishRequest: Equatable, Sendable {
    public let sessionID: String
    public let requestID: UUID
    public let generation: UInt64

    public init(sessionID: String, requestID: UUID, generation: UInt64) {
        self.sessionID = sessionID
        self.requestID = requestID
        self.generation = generation
    }
}

public struct LiveGuidanceReliableDataPublishRequest: Equatable, Sendable {
    public let sessionID: String
    public let generation: UInt64
    public let topic: String
    public let payload: Data

    public init(sessionID: String, generation: UInt64, topic: String, payload: Data) {
        self.sessionID = sessionID
        self.generation = generation
        self.topic = topic
        self.payload = payload
    }
}

/// A LiveKit adapter may join one Room and request the app-produced track, but
/// it must not open a camera or start an HTTP polling loop.
public protocol LiveGuidanceRoomTransporting: Sendable {
    func join(_ request: LiveGuidanceRoomJoinRequest) async throws -> LiveGuidanceJoinedRoom
    func leave(_ room: UUID) async
    func requestAppProducedVideoPublish(
        _ request: LiveGuidanceVideoPublishRequest,
        in room: UUID
    ) async throws
    func publishReliableData(
        _ request: LiveGuidanceReliableDataPublishRequest,
        in room: UUID
    ) async throws
}

public extension LiveGuidanceRoomTransporting {
    func publishReliableData(
        _ request: LiveGuidanceReliableDataPublishRequest,
        in room: UUID
    ) async throws {
        _ = request
        _ = room
        throw LiveGuidanceTransportError.unavailable(.reliableDataPublishUnavailable)
    }
}

/// Truthful fallback when a composition has no usable LiveKit transport.
public struct UnavailableLiveGuidanceRoomTransport: LiveGuidanceRoomTransporting {
    public init() {}

    public func join(_ request: LiveGuidanceRoomJoinRequest) async throws -> LiveGuidanceJoinedRoom {
        _ = request
        throw LiveGuidanceTransportError.unavailable(.liveKitSDKNotLinked)
    }

    public func leave(_ room: UUID) async { _ = room }

    public func requestAppProducedVideoPublish(
        _ request: LiveGuidanceVideoPublishRequest,
        in room: UUID
    ) async throws {
        _ = request
        _ = room
        throw LiveGuidanceTransportError.unavailable(.appProducedVideoPublishHandoffUnavailable)
    }
}

public enum LiveGuidanceJoinKind: Equatable, Sendable { case initial, reconnect }
public enum LiveGuidanceConnectionFailure: Error, Equatable, Sendable {
    case invalidClock
    case tokenRequestFailed
    case tokenExpired
    case tokenLifetimeExceedsHardMaximum
    case invalidTokenResponse
    case roomJoinFailed
    case transportDisconnected
    case packetStreamEnded
    case cancelled
}

public enum LiveGuidanceConnectionPhase: Equatable, Sendable {
    case disconnected
    case requestingToken(LiveGuidanceJoinKind, UUID)
    case joiningRoom(LiveGuidanceJoinKind, UUID)
    case connected
    case reconnecting
    case leaving
    case failed(LiveGuidanceConnectionFailure)
    case unavailable(LiveGuidanceProductionBlocker)
}

public enum LiveGuidanceVideoPublishState: Equatable, Sendable {
    case notRequested
    case requesting(UUID)
    case publishing
    case stopped
    case failed
    case unavailable(LiveGuidanceProductionBlocker)
}

public enum LiveGuidanceCaptureContextPublishState: Equatable, Sendable {
    case pending(UInt64)
    case publishing(UInt64)
    case published(UInt64)
    case failed(UInt64)
    case unavailable(UInt64, LiveGuidanceProductionBlocker)
    case stopped(UInt64)
}

public enum LiveGuidancePacketRejection: Equatable, Sendable {
    case invalidGuidanceJSON
    case filtered(GuidanceFilterRejectionReason)
}

/// AI prose, confidence, and action fields are absent, so this output cannot
/// accept a slot or choose a capture phase.
public struct LiveGuidanceDelivery: Equatable, Sendable {
    public let sessionID: String
    public let sequence: Int64
    public let shot: Shot
    public let display: GuidanceDisplayInput
    public let observedAtEpochMilliseconds: Int64
    public let deliveryLatencyMilliseconds: Int64?
}

/// No reliable schema is frozen for T08-02. Bytes remain opaque at this typed,
/// session-bound boundary and are never interpreted as workflow commands.
public struct LiveGuidanceOpaqueReliablePacket: Equatable, Sendable {
    public let sessionID: String
    public let requestID: UUID
    public let generation: UInt64
    public let participantIdentity: String?
    public let payload: Data
}

public enum LiveGuidanceConnectionOutput: Equatable, Sendable {
    case guidance(LiveGuidanceDelivery)
    case opaqueReliablePacket(LiveGuidanceOpaqueReliablePacket)
}

public protocol LiveGuidanceConnectionOutputReceiving: Sendable {
    func receive(_ output: LiveGuidanceConnectionOutput) async
}

public struct DiscardingLiveGuidanceOutputReceiver: LiveGuidanceConnectionOutputReceiving {
    public init() {}
    public func receive(_ output: LiveGuidanceConnectionOutput) async { _ = output }
}

/// Deliberately excludes tokens, packet bytes, AI prose, confidence, and action.
public struct LiveGuidanceConnectionSnapshot: Equatable, Sendable {
    public let phase: LiveGuidanceConnectionPhase
    public let guidanceConnection: GuidanceConnectionState
    public let currentSessionID: String
    public let currentShot: Shot
    public let generation: UInt64
    public let lastAcceptedSequence: Int64?
    public let latestGuidance: GuidanceDisplayInput?
    public let acceptedGuidanceCount: UInt64
    public let rejectedGuidanceCount: UInt64
    public let lastGuidanceRejection: LiveGuidancePacketRejection?
    public let opaqueReliablePacketCount: UInt64
    public let videoPublishState: LiveGuidanceVideoPublishState
    public let captureContextPublishState: LiveGuidanceCaptureContextPublishState
    public let latencySampleCount: UInt64
    public let guidanceDeliveryLatencyP95Milliseconds: Int64?
}

/// Session-scoped Room coordinator. Every async result is checked against its
/// generation, request, session, and strict shot/sequence filter.
public actor LiveGuidanceConnection {
    public static let usesHTTPGuidancePolling = false

    private let tokenProvider: any LiveGuidanceTokenProviding
    private let transport: any LiveGuidanceRoomTransporting
    private let clock: any GuidanceEpochMillisecondsClock
    private let receiver: any LiveGuidanceConnectionOutputReceiving
    private let makeRequestID: @Sendable () -> UUID
    private let decoder = JSONDecoder()
    private let contextEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private var filter: GuidanceFilterState
    private var phase: LiveGuidanceConnectionPhase = .disconnected
    private var generation: UInt64 = 0
    private var requestID: UUID?
    private var room: UUID?
    private var joinTask: Task<Void, Never>?
    private var publishTask: Task<Void, Never>?
    private var packetTasks: [Task<Void, Never>] = []
    private var hasConnected = false
    private var publishState: LiveGuidanceVideoPublishState = .notRequested
    private var acceptedCount: UInt64 = 0
    private var rejectedCount: UInt64 = 0
    private var lastRejection: LiveGuidancePacketRejection?
    private var reliableCount: UInt64 = 0
    private var deliveryLatencies: [Int64] = []
    private var latencySampleCount: UInt64 = 0
    private var latestCaptureContext: CaptureContextV1
    private var pendingCaptureContext: CaptureContextV1?
    private var captureContextPublishTask: Task<Void, Never>?
    private var captureContextPublishAttempt: UInt64 = 0
    private var captureContextPublishState: LiveGuidanceCaptureContextPublishState

    public init(
        sessionID: String,
        currentShot: Shot,
        tokenProvider: any LiveGuidanceTokenProviding,
        transport: any LiveGuidanceRoomTransporting,
        clock: any GuidanceEpochMillisecondsClock,
        receiver: any LiveGuidanceConnectionOutputReceiving = DiscardingLiveGuidanceOutputReceiver(),
        makeRequestID: @escaping @Sendable () -> UUID = { UUID() }
    ) throws {
        self.tokenProvider = tokenProvider
        self.transport = transport
        self.clock = clock
        self.receiver = receiver
        self.makeRequestID = makeRequestID
        let validatedSessionID = try LiveKitTokenRequest(sessionId: sessionID).sessionId
        filter = try GuidanceFilterState(
            sessionId: validatedSessionID,
            currentShot: currentShot,
            connection: .disconnected
        )
        let initialContext = try CaptureContextV1(
            sessionId: validatedSessionID,
            revision: 1,
            shot: currentShot,
            acceptedShots: [],
            lastGuidanceSequence: nil
        )
        latestCaptureContext = initialContext
        pendingCaptureContext = initialContext
        captureContextPublishState = .pending(initialContext.revision)
    }

    /// Idempotent during an active request, connection, or leave.
    public func join() {
        switch phase {
        case .requestingToken, .joiningRoom, .connected, .reconnecting, .leaving: return
        case .disconnected, .failed, .unavailable: break
        }
        generation = nextGeneration()
        let operationGeneration = generation
        let operationRequestID = makeRequestID()
        let sessionID = filter.currentSessionId
        let kind: LiveGuidanceJoinKind = hasConnected ? .reconnect : .initial
        requestID = operationRequestID
        room = nil
        publishState = .notRequested
        phase = .requestingToken(kind, operationRequestID)
        filter.transitionConnection(to: kind == .initial ? .connecting : .reconnecting)
        joinTask = Task { [weak self] in
            await self?.performJoin(
                sessionID: sessionID,
                requestID: operationRequestID,
                generation: operationGeneration,
                kind: kind
            )
        }
    }

    /// Cancels pending work and leaves at most one active Room.
    public func leave() async {
        if case .leaving = phase { return }
        if phase == .disconnected, room == nil, joinTask == nil { return }
        generation = nextGeneration()
        let leaveGeneration = generation
        phase = .leaving
        filter.transitionConnection(to: .disconnected)
        publishState = .stopped
        requestID = nil
        joinTask?.cancel()
        joinTask = nil
        publishTask?.cancel()
        publishTask = nil
        invalidateCaptureContextPublish()
        packetTasks.forEach { $0.cancel() }
        packetTasks.removeAll()
        let joinedRoom = room
        room = nil
        if let joinedRoom { await transport.leave(joinedRoom) }
        if generation == leaveGeneration {
            phase = .disconnected
            captureContextPublishState = .stopped(latestCaptureContext.revision)
        }
    }

    /// Compatibility entry point for callers that only change the shot. New
    /// workflow wiring should provide the complete app-owned accepted-slot set.
    public func setCurrentShot(_ shot: Shot) {
        queueCaptureContext(
            currentShot: shot,
            acceptedShots: Set(latestCaptureContext.acceptedShots),
            forceNewRevision: false
        )
    }

    /// Updates the app-owned workflow context without allowing Agent data to
    /// accept slots or navigate. At most one send is active and one latest
    /// snapshot is pending; intermediate updates are replaced.
    public func updateCaptureContext(
        currentShot: Shot,
        acceptedShots: Set<Shot>
    ) async {
        queueCaptureContext(
            currentShot: currentShot,
            acceptedShots: acceptedShots,
            forceNewRevision: true
        )
    }

    /// Explicit retry after a reliable-send failure. A fresh revision avoids
    /// replay ambiguity if the previous send reached the Room before failing.
    public func retryCaptureContextPublish() async {
        switch captureContextPublishState {
        case .failed, .unavailable:
            queueCaptureContext(
                currentShot: filter.currentShot,
                acceptedShots: Set(latestCaptureContext.acceptedShots),
                forceNewRevision: true
            )
        case .pending, .publishing, .published, .stopped:
            break
        }
    }

    /// Explicit retry entry point. The initial request starts automatically once
    /// Room join succeeds; repeated calls remain idempotent.
    public func requestAppProducedVideoPublish() async {
        guard phase == .connected,
              let joinedRoom = room,
              let connectionRequestID = requestID else { return }
        switch publishState {
        case .requesting, .publishing, .unavailable: return
        case .notRequested, .stopped, .failed: break
        }
        let publishRequestID = makeRequestID()
        let operationGeneration = generation
        let sessionID = filter.currentSessionId
        publishState = .requesting(publishRequestID)
        do {
            try await transport.requestAppProducedVideoPublish(
                .init(
                    sessionID: sessionID,
                    requestID: publishRequestID,
                    generation: operationGeneration
                ),
                in: joinedRoom
            )
            guard isCurrent(generation: operationGeneration,
                            requestID: connectionRequestID,
                            sessionID: sessionID, room: joinedRoom) else { return }
            publishState = .publishing
        } catch {
            guard isCurrent(generation: operationGeneration,
                            requestID: connectionRequestID,
                            sessionID: sessionID, room: joinedRoom) else { return }
            if let unavailable = blocker(from: error) {
                publishState = .unavailable(unavailable)
            } else if isCancellation(error) {
                publishState = .stopped
            } else {
                publishState = .failed
            }
        }
    }

    public func snapshot() -> LiveGuidanceConnectionSnapshot {
        .init(
            phase: phase,
            guidanceConnection: filter.connection,
            currentSessionID: filter.currentSessionId,
            currentShot: filter.currentShot,
            generation: generation,
            lastAcceptedSequence: filter.lastAcceptedSequence,
            latestGuidance: filter.latestGuidance,
            acceptedGuidanceCount: acceptedCount,
            rejectedGuidanceCount: rejectedCount,
            lastGuidanceRejection: lastRejection,
            opaqueReliablePacketCount: reliableCount,
            videoPublishState: publishState,
            captureContextPublishState: captureContextPublishState,
            latencySampleCount: latencySampleCount,
            guidanceDeliveryLatencyP95Milliseconds: latencyP95()
        )
    }

    private func performJoin(
        sessionID: String,
        requestID operationRequestID: UUID,
        generation operationGeneration: UInt64,
        kind: LiveGuidanceJoinKind
    ) async {
        let token: LiveKitTokenResponse
        do {
            token = try await tokenProvider.fetchToken(
                for: LiveKitTokenRequest(sessionId: sessionID)
            )
        } catch {
            finishJoin(error, fallback: .tokenRequestFailed,
                       generation: operationGeneration,
                       requestID: operationRequestID, sessionID: sessionID)
            return
        }
        guard isCurrent(generation: operationGeneration,
                        requestID: operationRequestID,
                        sessionID: sessionID) else { return }
        let now = clock.nowEpochMilliseconds()
        guard now >= 0 else {
            finishJoin(LiveGuidanceConnectionFailure.invalidClock, fallback: .invalidClock,
                       generation: operationGeneration,
                       requestID: operationRequestID, sessionID: sessionID)
            return
        }
        do {
            guard try !token.isExpired(nowUnixSeconds: now / 1_000) else {
                finishJoin(LiveGuidanceConnectionFailure.tokenExpired, fallback: .tokenExpired,
                           generation: operationGeneration,
                           requestID: operationRequestID, sessionID: sessionID)
                return
            }
            let nowSeconds = now / 1_000
            guard token.expiresAt - nowSeconds <= 300 else {
                finishJoin(
                    LiveGuidanceConnectionFailure.tokenLifetimeExceedsHardMaximum,
                    fallback: .tokenLifetimeExceedsHardMaximum,
                    generation: operationGeneration,
                    requestID: operationRequestID,
                    sessionID: sessionID
                )
                return
            }
        } catch {
            finishJoin(error, fallback: .invalidTokenResponse,
                       generation: operationGeneration,
                       requestID: operationRequestID, sessionID: sessionID)
            return
        }
        guard let url = URL(string: token.livekitUrl) else {
            finishJoin(LiveGuidanceConnectionFailure.invalidTokenResponse, fallback: .invalidTokenResponse,
                       generation: operationGeneration,
                       requestID: operationRequestID, sessionID: sessionID)
            return
        }

        phase = .joiningRoom(kind, operationRequestID)
        let joined: LiveGuidanceJoinedRoom
        do {
            joined = try await transport.join(
                .init(
                    sessionID: sessionID,
                    requestID: operationRequestID,
                    generation: operationGeneration,
                    liveKitURL: url,
                    roomName: token.roomName,
                    participantIdentity: token.participantIdentity,
                    token: token.token
                )
            )
        } catch {
            finishJoin(error, fallback: .roomJoinFailed,
                       generation: operationGeneration,
                       requestID: operationRequestID, sessionID: sessionID)
            return
        }
        guard isCurrent(generation: operationGeneration,
                        requestID: operationRequestID,
                        sessionID: sessionID) else {
            await transport.leave(joined.handle)
            return
        }
        room = joined.handle
        joinTask = nil
        phase = .connected
        filter.transitionConnection(to: .connected)
        hasConnected = true
        if kind == .reconnect {
            queueCaptureContext(
                currentShot: filter.currentShot,
                acceptedShots: Set(latestCaptureContext.acceptedShots),
                forceNewRevision: true,
                startPublish: false
            )
        } else if pendingCaptureContext == nil {
            pendingCaptureContext = latestCaptureContext
            captureContextPublishState = .pending(latestCaptureContext.revision)
        }
        startConsumers(joined, sessionID: sessionID,
                       requestID: operationRequestID,
                       generation: operationGeneration)
        beginCaptureContextPublish()
        beginAppProducedVideoPublish()
    }

    private func startConsumers(
        _ joined: LiveGuidanceJoinedRoom,
        sessionID: String,
        requestID operationRequestID: UUID,
        generation operationGeneration: UInt64
    ) {
        packetTasks = [
            Task { [weak self] in
                for await packet in joined.lossyPackets {
                    guard !Task.isCancelled else { return }
                    await self?.receiveLossy(packet, room: joined.handle,
                                            sessionID: sessionID,
                                            requestID: operationRequestID,
                                            generation: operationGeneration)
                }
                await self?.packetStreamEnded(room: joined.handle, sessionID: sessionID,
                                              requestID: operationRequestID,
                                              generation: operationGeneration)
            },
            Task { [weak self] in
                for await packet in joined.reliablePackets {
                    guard !Task.isCancelled else { return }
                    await self?.receiveReliable(packet, room: joined.handle,
                                                sessionID: sessionID,
                                                requestID: operationRequestID,
                                                generation: operationGeneration)
                }
                await self?.packetStreamEnded(room: joined.handle, sessionID: sessionID,
                                              requestID: operationRequestID,
                                              generation: operationGeneration)
            },
            Task { [weak self] in
                for await status in joined.statusChanges {
                    guard !Task.isCancelled else { return }
                    await self?.transportStatusChanged(
                        status,
                        room: joined.handle,
                        sessionID: sessionID,
                        requestID: operationRequestID,
                        generation: operationGeneration
                    )
                }
                await self?.packetStreamEnded(room: joined.handle, sessionID: sessionID,
                                              requestID: operationRequestID,
                                              generation: operationGeneration)
            },
        ]
    }

    private func receiveLossy(
        _ packet: LiveGuidanceTransportPacket,
        room joinedRoom: UUID,
        sessionID: String,
        requestID operationRequestID: UUID,
        generation operationGeneration: UInt64
    ) async {
        guard isCurrent(generation: operationGeneration,
                        requestID: operationRequestID,
                        sessionID: sessionID, room: joinedRoom) else { return }
        let event: GuidanceEvent
        do {
            event = try decoder.decode(GuidanceEvent.self, from: packet.payload)
        } catch {
            reject(.invalidGuidanceJSON)
            return
        }
        let now = clock.nowEpochMilliseconds()
        switch filter.reduce(event, clock: FixedGuidanceClock(now)) {
        case .rejected(let reason):
            reject(.filtered(reason))
        case .accepted(let display):
            acceptedCount &+= 1
            let latency = now >= event.observedAt ? now - event.observedAt : nil
            if let latency { recordLatency(latency) }
            await receiver.receive(
                .guidance(
                    .init(
                        sessionID: event.sessionId,
                        sequence: event.sequence,
                        shot: event.shot,
                        display: display,
                        observedAtEpochMilliseconds: event.observedAt,
                        deliveryLatencyMilliseconds: latency
                    )
                )
            )
        }
    }

    private func receiveReliable(
        _ packet: LiveGuidanceTransportPacket,
        room joinedRoom: UUID,
        sessionID: String,
        requestID operationRequestID: UUID,
        generation operationGeneration: UInt64
    ) async {
        guard isCurrent(generation: operationGeneration,
                        requestID: operationRequestID,
                        sessionID: sessionID, room: joinedRoom) else { return }
        reliableCount &+= 1
        await receiver.receive(
            .opaqueReliablePacket(
                .init(
                    sessionID: sessionID,
                    requestID: operationRequestID,
                    generation: operationGeneration,
                    participantIdentity: packet.participantIdentity,
                    payload: packet.payload
                )
            )
        )
    }

    private func transportStatusChanged(
        _ status: LiveGuidanceTransportConnectionStatus,
        room joinedRoom: UUID,
        sessionID: String,
        requestID operationRequestID: UUID,
        generation operationGeneration: UInt64
    ) async {
        guard isCurrent(generation: operationGeneration,
                        requestID: operationRequestID,
                        sessionID: sessionID, room: joinedRoom) else { return }
        switch status {
        case .connecting:
            break
        case .connected:
            let recoveredFromReconnect = phase == .reconnecting
            phase = .connected
            filter.transitionConnection(to: .connected)
            if recoveredFromReconnect {
                queueCaptureContext(
                    currentShot: filter.currentShot,
                    acceptedShots: Set(latestCaptureContext.acceptedShots),
                    forceNewRevision: true,
                    startPublish: false
                )
            }
            beginCaptureContextPublish()
        case .reconnecting:
            phase = .reconnecting
            filter.transitionConnection(to: .reconnecting)
            invalidateCaptureContextPublish()
            captureContextPublishState = .pending(latestCaptureContext.revision)
        case .disconnected:
            await transportEnded(
                .transportDisconnected,
                room: joinedRoom,
                sessionID: sessionID,
                requestID: operationRequestID,
                generation: operationGeneration
            )
        }
    }

    private func packetStreamEnded(
        room joinedRoom: UUID,
        sessionID: String,
        requestID operationRequestID: UUID,
        generation operationGeneration: UInt64
    ) async {
        await transportEnded(
            .packetStreamEnded,
            room: joinedRoom,
            sessionID: sessionID,
            requestID: operationRequestID,
            generation: operationGeneration
        )
    }

    private func transportEnded(
        _ failure: LiveGuidanceConnectionFailure,
        room joinedRoom: UUID,
        sessionID: String,
        requestID operationRequestID: UUID,
        generation operationGeneration: UInt64
    ) async {
        guard isCurrent(generation: operationGeneration,
                        requestID: operationRequestID,
                        sessionID: sessionID, room: joinedRoom) else { return }
        generation = nextGeneration()
        requestID = nil
        room = nil
        filter.transitionConnection(to: .disconnected)
        publishState = .stopped
        phase = .failed(failure)
        publishTask?.cancel()
        publishTask = nil
        invalidateCaptureContextPublish()
        captureContextPublishState = .pending(latestCaptureContext.revision)
        packetTasks.forEach { $0.cancel() }
        packetTasks.removeAll()
        await transport.leave(joinedRoom)
    }

    private func beginAppProducedVideoPublish() {
        publishTask?.cancel()
        publishTask = Task { [weak self] in
            await self?.requestAppProducedVideoPublish()
        }
    }

    private func queueCaptureContext(
        currentShot: Shot,
        acceptedShots: Set<Shot>,
        forceNewRevision: Bool,
        startPublish: Bool = true
    ) {
        filter.setCurrentShot(currentShot)
        let canonicalAcceptedShots = CaptureContextV1.canonicalAcceptedShots(from: acceptedShots)
        let contentChanged = latestCaptureContext.shot != currentShot ||
            latestCaptureContext.acceptedShots != canonicalAcceptedShots ||
            latestCaptureContext.lastGuidanceSequence != filter.lastAcceptedSequence
        var enqueuedNewRevision = false

        if forceNewRevision || contentChanged {
            guard latestCaptureContext.revision < UInt64.max else {
                captureContextPublishState = .failed(latestCaptureContext.revision)
                return
            }
            do {
                let context = try CaptureContextV1(
                    sessionId: filter.currentSessionId,
                    revision: latestCaptureContext.revision + 1,
                    shot: currentShot,
                    acceptedShots: canonicalAcceptedShots,
                    lastGuidanceSequence: filter.lastAcceptedSequence
                )
                latestCaptureContext = context
                pendingCaptureContext = context
                captureContextPublishState = .pending(context.revision)
                enqueuedNewRevision = true
            } catch {
                captureContextPublishState = .failed(latestCaptureContext.revision)
                return
            }
        }

        guard startPublish else { return }
        switch captureContextPublishState {
        case .failed, .unavailable where !enqueuedNewRevision:
            return
        default:
            beginCaptureContextPublish()
        }
    }

    private func beginCaptureContextPublish() {
        guard captureContextPublishTask == nil,
              phase == .connected,
              let joinedRoom = room,
              let connectionRequestID = requestID,
              let context = pendingCaptureContext
        else { return }

        let payload: Data
        do {
            payload = try contextEncoder.encode(context)
        } catch {
            captureContextPublishState = .failed(context.revision)
            return
        }

        pendingCaptureContext = nil
        captureContextPublishAttempt &+= 1
        if captureContextPublishAttempt == 0 { captureContextPublishAttempt = 1 }
        let attempt = captureContextPublishAttempt
        let operationGeneration = generation
        let sessionID = filter.currentSessionId
        captureContextPublishState = .publishing(context.revision)
        captureContextPublishTask = Task { [weak self] in
            await self?.performCaptureContextPublish(
                context: context,
                payload: payload,
                room: joinedRoom,
                sessionID: sessionID,
                requestID: connectionRequestID,
                generation: operationGeneration,
                attempt: attempt
            )
        }
    }

    private func performCaptureContextPublish(
        context: CaptureContextV1,
        payload: Data,
        room joinedRoom: UUID,
        sessionID: String,
        requestID operationRequestID: UUID,
        generation operationGeneration: UInt64,
        attempt: UInt64
    ) async {
        do {
            try await transport.publishReliableData(
                .init(
                    sessionID: sessionID,
                    generation: operationGeneration,
                    topic: CaptureContextContract.version1Topic,
                    payload: payload
                ),
                in: joinedRoom
            )
            guard isCurrentCaptureContextPublish(
                room: joinedRoom,
                sessionID: sessionID,
                requestID: operationRequestID,
                generation: operationGeneration,
                attempt: attempt
            ) else { return }
            captureContextPublishTask = nil
            if let pendingCaptureContext {
                captureContextPublishState = .pending(pendingCaptureContext.revision)
                beginCaptureContextPublish()
            } else {
                captureContextPublishState = .published(context.revision)
            }
        } catch {
            guard isCurrentCaptureContextPublish(
                room: joinedRoom,
                sessionID: sessionID,
                requestID: operationRequestID,
                generation: operationGeneration,
                attempt: attempt
            ) else { return }
            captureContextPublishTask = nil
            if let pendingCaptureContext {
                captureContextPublishState = .pending(pendingCaptureContext.revision)
                beginCaptureContextPublish()
                return
            }
            self.pendingCaptureContext = context
            if let unavailable = blocker(from: error) {
                captureContextPublishState = .unavailable(context.revision, unavailable)
            } else {
                captureContextPublishState = .failed(context.revision)
            }
        }
    }

    private func invalidateCaptureContextPublish() {
        captureContextPublishAttempt &+= 1
        if captureContextPublishAttempt == 0 { captureContextPublishAttempt = 1 }
        captureContextPublishTask?.cancel()
        captureContextPublishTask = nil
    }

    private func isCurrentCaptureContextPublish(
        room joinedRoom: UUID,
        sessionID: String,
        requestID operationRequestID: UUID,
        generation operationGeneration: UInt64,
        attempt: UInt64
    ) -> Bool {
        captureContextPublishAttempt == attempt &&
            phase == .connected &&
            isCurrent(
                generation: operationGeneration,
                requestID: operationRequestID,
                sessionID: sessionID,
                room: joinedRoom
            )
    }

    private func recordLatency(_ latency: Int64) {
        latencySampleCount &+= 1
        if deliveryLatencies.count == 256 { deliveryLatencies.removeFirst() }
        deliveryLatencies.append(latency)
    }

    private func latencyP95() -> Int64? {
        guard !deliveryLatencies.isEmpty else { return nil }
        let sorted = deliveryLatencies.sorted()
        let rank = max(1, Int((Double(sorted.count) * 0.95).rounded(.up)))
        return sorted[rank - 1]
    }

    private func reject(_ rejection: LiveGuidancePacketRejection) {
        rejectedCount &+= 1
        lastRejection = rejection
    }

    private func finishJoin(
        _ error: any Error,
        fallback: LiveGuidanceConnectionFailure,
        generation operationGeneration: UInt64,
        requestID operationRequestID: UUID,
        sessionID: String
    ) {
        guard isCurrent(generation: operationGeneration,
                        requestID: operationRequestID,
                        sessionID: sessionID) else { return }
        joinTask = nil
        requestID = nil
        filter.transitionConnection(to: .disconnected)
        if let unavailable = blocker(from: error) {
            phase = .unavailable(unavailable)
        } else if isCancellation(error) {
            phase = .failed(.cancelled)
        } else {
            phase = .failed(fallback)
        }
    }

    private func isCurrent(
        generation operationGeneration: UInt64,
        requestID operationRequestID: UUID,
        sessionID: String,
        room joinedRoom: UUID? = nil
    ) -> Bool {
        guard generation == operationGeneration,
              requestID == operationRequestID,
              filter.currentSessionId == sessionID else { return false }
        return joinedRoom.map { room == $0 } ?? true
    }

    private func blocker(from error: any Error) -> LiveGuidanceProductionBlocker? {
        guard let transportError = error as? LiveGuidanceTransportError,
              case .unavailable(let blocker) = transportError else { return nil }
        return blocker
    }

    private func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError ||
            (error as? LiveGuidanceTransportError) == .cancelled ||
            Task.isCancelled
    }

    private func nextGeneration() -> UInt64 {
        generation &+= 1
        if generation == 0 { generation = 1 }
        return generation
    }
}

private struct FixedGuidanceClock: GuidanceEpochMillisecondsClock {
    let value: Int64
    init(_ value: Int64) { self.value = value }
    func nowEpochMilliseconds() -> Int64 { value }
}
