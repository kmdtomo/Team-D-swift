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
}

public enum LiveGuidanceTransportError: Error, Equatable, Sendable {
    case unavailable(LiveGuidanceProductionBlocker)
    case connectionFailed
    case appProducedVideoPublishFailed
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

    public init(
        handle: UUID,
        lossyPackets: AsyncStream<LiveGuidanceTransportPacket>,
        reliablePackets: AsyncStream<LiveGuidanceTransportPacket>
    ) {
        self.handle = handle
        self.lossyPackets = lossyPackets
        self.reliablePackets = reliablePackets
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

/// A LiveKit adapter may join one Room and request the app-produced track, but
/// it must not open a camera or start an HTTP polling loop.
public protocol LiveGuidanceRoomTransporting: Sendable {
    func join(_ request: LiveGuidanceRoomJoinRequest) async throws -> LiveGuidanceJoinedRoom
    func leave(_ room: UUID) async
    func requestAppProducedVideoPublish(
        _ request: LiveGuidanceVideoPublishRequest,
        in room: UUID
    ) async throws
}

/// Truthful production default while the pinned LiveKit Swift SDK is absent.
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
    case invalidTokenResponse
    case roomJoinFailed
    case packetStreamEnded
    case cancelled
}

public enum LiveGuidanceConnectionPhase: Equatable, Sendable {
    case disconnected
    case requestingToken(LiveGuidanceJoinKind, UUID)
    case joiningRoom(LiveGuidanceJoinKind, UUID)
    case connected
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

    private var filter: GuidanceFilterState
    private var phase: LiveGuidanceConnectionPhase = .disconnected
    private var generation: UInt64 = 0
    private var requestID: UUID?
    private var room: UUID?
    private var joinTask: Task<Void, Never>?
    private var packetTasks: [Task<Void, Never>] = []
    private var hasConnected = false
    private var publishState: LiveGuidanceVideoPublishState = .notRequested
    private var acceptedCount: UInt64 = 0
    private var rejectedCount: UInt64 = 0
    private var lastRejection: LiveGuidancePacketRejection?
    private var reliableCount: UInt64 = 0

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
        let sessionID = try LiveKitTokenRequest(sessionId: sessionID).sessionId
        filter = try GuidanceFilterState(
            sessionId: sessionID,
            currentShot: currentShot,
            connection: .disconnected
        )
    }

    /// Idempotent during an active request, connection, or leave.
    public func join() {
        switch phase {
        case .requestingToken, .joiningRoom, .connected, .leaving: return
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
        packetTasks.forEach { $0.cancel() }
        packetTasks.removeAll()
        let joinedRoom = room
        room = nil
        if let joinedRoom { await transport.leave(joinedRoom) }
        if generation == leaveGeneration { phase = .disconnected }
    }

    public func setCurrentShot(_ shot: Shot) { filter.setCurrentShot(shot) }

    /// Remains explicit because T08-01 has no operational pixel handoff yet.
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
            videoPublishState: publishState
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
        startConsumers(joined, sessionID: sessionID,
                       requestID: operationRequestID,
                       generation: operationGeneration)
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
            await receiver.receive(
                .guidance(
                    .init(
                        sessionID: event.sessionId,
                        sequence: event.sequence,
                        shot: event.shot,
                        display: display,
                        observedAtEpochMilliseconds: event.observedAt,
                        deliveryLatencyMilliseconds: now >= event.observedAt ? now - event.observedAt : nil
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

    private func packetStreamEnded(
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
        phase = .failed(.packetStreamEnded)
        packetTasks.forEach { $0.cancel() }
        packetTasks.removeAll()
        await transport.leave(joinedRoom)
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
