import CaptureKit
import Foundation

/// Versioned topics are required because LiveKit Swift's Room delegate exposes
/// payload and topic, but not the packet reliability flag. The shared Agent must
/// publish finite `GuidanceEvent` JSON on the lossy topic and leave reliable
/// state bytes on the opaque reliable topic until T08-03 freezes that schema.
public struct LiveGuidanceDataTopics: Equatable, Sendable {
    public static let version1 = LiveGuidanceDataTopics(
        validatedLossyGuidance: "teamd.guidance.lossy.v1",
        validatedReliableState: "teamd.state.reliable.v1"
    )

    public let lossyGuidance: String
    public let reliableState: String

    public init(lossyGuidance: String, reliableState: String) throws {
        let lossy = lossyGuidance.trimmingCharacters(in: .whitespacesAndNewlines)
        let reliable = reliableState.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lossy.isEmpty, !reliable.isEmpty, lossy != reliable,
              lossy.count <= 128, reliable.count <= 128
        else { throw LiveGuidanceTransportError.connectionFailed }
        self.lossyGuidance = lossy
        self.reliableState = reliable
    }

    private init(validatedLossyGuidance: String, validatedReliableState: String) {
        lossyGuidance = validatedLossyGuidance
        reliableState = validatedReliableState
    }
}

public enum LiveGuidanceTransportConnectionStatus: Equatable, Sendable {
    case connecting
    case connected
    case reconnecting
    case disconnected
}

struct LiveGuidanceRoomEventStreams: Sendable {
    let lossy: AsyncStream<LiveGuidanceTransportPacket>
    let reliable: AsyncStream<LiveGuidanceTransportPacket>
    let statuses: AsyncStream<LiveGuidanceTransportConnectionStatus>
}

/// Bounded delegate-to-AsyncStream adapter. Unknown topics are dropped instead
/// of being guessed into either the guidance or workflow boundary.
actor LiveGuidanceRoomEventHub {
    private let topics: LiveGuidanceDataTopics
    private let lossyPipe: AsyncStream<LiveGuidanceTransportPacket>
    private let lossyContinuation: AsyncStream<LiveGuidanceTransportPacket>.Continuation
    private let reliablePipe: AsyncStream<LiveGuidanceTransportPacket>
    private let reliableContinuation: AsyncStream<LiveGuidanceTransportPacket>.Continuation
    private let statusPipe: AsyncStream<LiveGuidanceTransportConnectionStatus>
    private let statusContinuation: AsyncStream<LiveGuidanceTransportConnectionStatus>.Continuation
    private var finished = false

    init(topics: LiveGuidanceDataTopics) {
        self.topics = topics
        let lossy = AsyncStream<LiveGuidanceTransportPacket>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        lossyPipe = lossy.stream
        lossyContinuation = lossy.continuation
        let reliable = AsyncStream<LiveGuidanceTransportPacket>.makeStream(
            bufferingPolicy: .bufferingNewest(32)
        )
        reliablePipe = reliable.stream
        reliableContinuation = reliable.continuation
        let statuses = AsyncStream<LiveGuidanceTransportConnectionStatus>.makeStream(
            bufferingPolicy: .bufferingNewest(8)
        )
        statusPipe = statuses.stream
        statusContinuation = statuses.continuation
    }

    func streams() -> LiveGuidanceRoomEventStreams {
        .init(lossy: lossyPipe, reliable: reliablePipe, statuses: statusPipe)
    }

    func receive(data: Data, topic: String, participantIdentity: String?) {
        guard !finished else { return }
        let packet = LiveGuidanceTransportPacket(
            payload: data,
            participantIdentity: participantIdentity
        )
        if topic == topics.lossyGuidance {
            lossyContinuation.yield(packet)
        } else if topic == topics.reliableState {
            reliableContinuation.yield(packet)
        }
    }

    func transition(to status: LiveGuidanceTransportConnectionStatus) {
        guard !finished else { return }
        statusContinuation.yield(status)
        if status == .disconnected { finish() }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        lossyContinuation.finish()
        reliableContinuation.finish()
        statusContinuation.finish()
    }
}

public protocol LiveGuidanceCaptureSampleOffering: Sendable {
    @discardableResult
    func offer(
        sample: AnalysisSample,
        orientation: CaptureVideoOrientation
    ) async throws -> Bool
}

public struct LiveGuidanceCaptureForwarderSnapshot: Equatable, Sendable {
    public let isActive: Bool
    public let pendingSequence: UInt64?
    public let offeredSampleCount: UInt64
    public let droppedSampleCount: UInt64
    public let failedOfferCount: UInt64
}

/// Synchronous capture-callback boundary with a capacity-one pending slot. The
/// AVFoundation delegate can call `receive` without creating a Task per frame;
/// one worker forwards only the newest sample to the async Room transport.
public final class LiveGuidanceCaptureSampleForwarder: @unchecked Sendable {
    private struct State {
        var active = true
        var generation: UInt64 = 1
        var pending: AnalysisSample?
        var worker: Task<Void, Never>?
        var offeredCount: UInt64 = 0
        var droppedCount: UInt64 = 0
        var failedCount: UInt64 = 0
    }

    private let transport: any LiveGuidanceCaptureSampleOffering
    private let orientation: @Sendable () -> CaptureVideoOrientation?
    private let lock = NSLock()
    private var state = State()

    public init(
        transport: any LiveGuidanceCaptureSampleOffering,
        orientation: @escaping @Sendable () -> CaptureVideoOrientation?
    ) {
        self.transport = transport
        self.orientation = orientation
    }

    public func receive(_ sample: AnalysisSample) {
        lock.lock()
        defer { lock.unlock() }
        guard state.active else { return }
        if let pending = state.pending {
            guard sample.sequence > pending.sequence else {
                state.droppedCount &+= 1
                return
            }
            state.droppedCount &+= 1
        }
        state.pending = sample
        guard state.worker == nil else { return }
        let generation = state.generation
        state.worker = Task { [weak self] in
            await self?.drain(generation: generation)
        }
    }

    public func stop() {
        lock.lock()
        state.active = false
        state.generation &+= 1
        if state.generation == 0 { state.generation = 1 }
        state.pending = nil
        let worker = state.worker
        state.worker = nil
        lock.unlock()
        worker?.cancel()
    }

    public func snapshot() -> LiveGuidanceCaptureForwarderSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return .init(
            isActive: state.active,
            pendingSequence: state.pending?.sequence,
            offeredSampleCount: state.offeredCount,
            droppedSampleCount: state.droppedCount,
            failedOfferCount: state.failedCount
        )
    }

    private func drain(generation: UInt64) async {
        while !Task.isCancelled, let sample = takeNext(generation: generation) {
            guard let orientation = orientation() else {
                recordFailure(generation: generation)
                continue
            }
            do {
                let accepted = try await transport.offer(
                    sample: sample,
                    orientation: orientation
                )
                recordResult(accepted: accepted, generation: generation)
            } catch {
                recordFailure(generation: generation)
            }
        }
    }

    private func takeNext(generation: UInt64) -> AnalysisSample? {
        lock.lock()
        defer { lock.unlock() }
        guard state.active, state.generation == generation else { return nil }
        let sample = state.pending
        state.pending = nil
        if sample == nil { state.worker = nil }
        return sample
    }

    private func recordResult(accepted: Bool, generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard state.active, state.generation == generation else { return }
        if accepted {
            state.offeredCount &+= 1
        } else {
            state.failedCount &+= 1
        }
    }

    private func recordFailure(generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard state.active, state.generation == generation else { return }
        state.failedCount &+= 1
    }
}

#if os(iOS) && canImport(LiveKit)
import LiveKit

private actor FirstCapturedFrameLatch {
    private var captured = false
    private var failure: LiveGuidanceTransportError?
    private var waiter: CheckedContinuation<Void, Error>?

    func wait() async throws {
        if captured { return }
        if let failure { throw failure }
        try await withCheckedThrowingContinuation { continuation in
            waiter = continuation
        }
    }

    func signal() {
        guard !captured, failure == nil else { return }
        captured = true
        let current = waiter
        waiter = nil
        current?.resume()
    }

    func cancel() {
        guard !captured, failure == nil else { return }
        failure = .cancelled
        let current = waiter
        waiter = nil
        current?.resume(throwing: LiveGuidanceTransportError.cancelled)
    }
}

private final class LiveKitRoomDelegateAdapter: NSObject, RoomDelegate, @unchecked Sendable {
    private let hub: LiveGuidanceRoomEventHub

    init(hub: LiveGuidanceRoomEventHub) {
        self.hub = hub
    }

    func room(
        _ room: Room,
        participant: RemoteParticipant?,
        didReceiveData data: Data,
        forTopic topic: String,
        encryptionType: EncryptionType
    ) {
        _ = room
        _ = encryptionType
        let identity = participant?.identity?.stringValue
        Task { await hub.receive(data: data, topic: topic, participantIdentity: identity) }
    }

    func room(
        _ room: Room,
        didUpdateConnectionState connectionState: ConnectionState,
        from oldConnectionState: ConnectionState
    ) {
        _ = room
        _ = oldConnectionState
        let status: LiveGuidanceTransportConnectionStatus
        switch connectionState {
        case .connecting: status = .connecting
        case .connected: status = .connected
        case .reconnecting: status = .reconnecting
        case .disconnecting, .disconnected: status = .disconnected
        }
        Task { await hub.transition(to: status) }
    }

    func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        _ = room
        _ = error
        Task { await hub.transition(to: .disconnected) }
    }
}

private actor LiveKitRoomRuntime {
    private let handle: UUID
    private let sessionID: String
    private let generation: UInt64
    private let room: Room
    private let hub: LiveGuidanceRoomEventHub
    private let delegate: LiveKitRoomDelegateAdapter
    private var frameCoordinator: LatestAppProducedFramePublisher?
    private var firstFrameLatch: FirstCapturedFrameLatch?
    private var publication: LocalTrackPublication?
    private var isClosed = false

    init(
        handle: UUID,
        sessionID: String,
        generation: UInt64,
        topics: LiveGuidanceDataTopics
    ) {
        self.handle = handle
        self.sessionID = sessionID
        self.generation = generation
        let hub = LiveGuidanceRoomEventHub(topics: topics)
        self.hub = hub
        delegate = LiveKitRoomDelegateAdapter(hub: hub)
        room = Room()
        room.add(delegate: delegate)
    }

    func connect(_ request: LiveGuidanceRoomJoinRequest) async throws -> LiveGuidanceJoinedRoom {
        do {
            try Task.checkCancellation()
            try await room.connect(url: request.liveKitURL.absoluteString, token: request.token)
            try Task.checkCancellation()
            guard room.name == request.roomName,
                  room.localParticipant.identity?.stringValue == request.participantIdentity
            else {
                await room.disconnect()
                throw LiveGuidanceTransportError.connectionFailed
            }
            let streams = await hub.streams()
            return .init(
                handle: handle,
                lossyPackets: streams.lossy,
                reliablePackets: streams.reliable,
                statusChanges: streams.statuses
            )
        } catch is CancellationError {
            await room.disconnect()
            throw LiveGuidanceTransportError.cancelled
        } catch let error as LiveGuidanceTransportError {
            throw error
        } catch {
            await room.disconnect()
            throw LiveGuidanceTransportError.connectionFailed
        }
    }

    func requestVideoPublish(_ request: LiveGuidanceVideoPublishRequest) async throws {
        guard !isClosed,
              request.sessionID == sessionID,
              request.generation == generation
        else { throw LiveGuidanceTransportError.cancelled }
        if publication != nil || frameCoordinator != nil { return }

        let track = LocalVideoTrack.createBufferTrack(
            name: "teamd-camera",
            source: .camera,
            options: BufferCaptureOptions(fps: 15),
            reportStatistics: true
        )
        let latch = FirstCapturedFrameLatch()
        let adapter: LiveKitBufferCapturerAdapter
        do {
            adapter = try LiveKitBufferCapturerAdapter(
                track: track,
                didCaptureFrame: { await latch.signal() }
            )
        } catch {
            throw LiveGuidanceTransportError.unavailable(.appProducedVideoPublishHandoffUnavailable)
        }
        let coordinator = LatestAppProducedFramePublisher(publisher: adapter)
        guard await coordinator.start() else {
            throw LiveGuidanceTransportError.appProducedVideoPublishFailed
        }
        frameCoordinator = coordinator
        firstFrameLatch = latch

        do {
            try await withTaskCancellationHandler {
                try await latch.wait()
            } onCancel: {
                Task { await latch.cancel() }
            }
            try Task.checkCancellation()
            guard !isClosed, frameCoordinator === coordinator else {
                throw LiveGuidanceTransportError.cancelled
            }
            let published = try await room.localParticipant.publish(
                videoTrack: track,
                options: VideoPublishOptions(
                    name: "teamd-camera",
                    simulcast: false,
                    degradationPreference: .maintainResolution
                )
            )
            guard !isClosed, frameCoordinator === coordinator else {
                try? await room.localParticipant.unpublish(publication: published)
                throw LiveGuidanceTransportError.cancelled
            }
            publication = published
            firstFrameLatch = nil
        } catch is CancellationError {
            await stopFrames()
            throw LiveGuidanceTransportError.cancelled
        } catch let error as LiveGuidanceTransportError {
            await stopFrames()
            throw error
        } catch {
            await stopFrames()
            throw LiveGuidanceTransportError.appProducedVideoPublishFailed
        }
    }

    func offer(_ frame: AppProducedVideoFrame) async {
        guard !isClosed, let frameCoordinator else { return }
        await frameCoordinator.offer(frame)
    }

    func leave() async {
        guard !isClosed else { return }
        isClosed = true
        await firstFrameLatch?.cancel()
        if let frameCoordinator { await frameCoordinator.stop() }
        if let publication {
            try? await room.localParticipant.unpublish(publication: publication)
        }
        self.publication = nil
        self.frameCoordinator = nil
        firstFrameLatch = nil
        await room.disconnect()
        await hub.finish()
        room.remove(delegate: delegate)
    }

    private func stopFrames() async {
        await firstFrameLatch?.cancel()
        if let frameCoordinator { await frameCoordinator.stop() }
        frameCoordinator = nil
        firstFrameLatch = nil
    }
}

/// LiveKit Swift 2.16.0 Room adapter. It owns no camera. App wiring forwards
/// samples from T05 through `offer(sample:orientation:)` while the connection
/// owns join, publish, packet subscription, and leave.
public actor LiveKitRoomTransport: LiveGuidanceRoomTransporting {
    private let topics: LiveGuidanceDataTopics
    private let makeRoomHandle: @Sendable () -> UUID
    private var rooms: [UUID: LiveKitRoomRuntime] = [:]
    private var activeRoom: UUID?

    public init(
        topics: LiveGuidanceDataTopics = .version1,
        makeRoomHandle: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.topics = topics
        self.makeRoomHandle = makeRoomHandle
    }

    public func join(_ request: LiveGuidanceRoomJoinRequest) async throws -> LiveGuidanceJoinedRoom {
        guard activeRoom == nil else { throw LiveGuidanceTransportError.connectionFailed }
        let handle = makeRoomHandle()
        let runtime = LiveKitRoomRuntime(
            handle: handle,
            sessionID: request.sessionID,
            generation: request.generation,
            topics: topics
        )
        do {
            let joined = try await runtime.connect(request)
            guard activeRoom == nil else {
                await runtime.leave()
                throw LiveGuidanceTransportError.connectionFailed
            }
            rooms[handle] = runtime
            activeRoom = handle
            return joined
        } catch {
            await runtime.leave()
            throw error
        }
    }

    public func leave(_ room: UUID) async {
        guard let runtime = rooms.removeValue(forKey: room) else { return }
        if activeRoom == room { activeRoom = nil }
        await runtime.leave()
    }

    public func requestAppProducedVideoPublish(
        _ request: LiveGuidanceVideoPublishRequest,
        in room: UUID
    ) async throws {
        guard let runtime = rooms[room] else { throw LiveGuidanceTransportError.cancelled }
        try await runtime.requestVideoPublish(request)
    }

    @discardableResult
    public func offer(
        sample: AnalysisSample,
        orientation: CaptureVideoOrientation
    ) async throws -> Bool {
        guard let room = activeRoom, let runtime = rooms[room],
              let frame = try AppProducedCaptureSampleAdapter.makeFrame(
                  sample: sample,
                  orientation: orientation
              )
        else { return false }
        await runtime.offer(frame)
        return true
    }
}

extension LiveKitRoomTransport: LiveGuidanceCaptureSampleOffering {}
#endif
