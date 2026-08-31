import CaptureKit
import Foundation

/// Metadata which travels with a frame produced by Team-D's only
/// `AVCaptureSession`. The LiveKit SDK is deliberately not allowed to discover
/// or open a camera itself.
public struct AppProducedVideoFrame: Equatable, Sendable {
    public let sequence: UInt64
    public let timestampNanoseconds: UInt64
    public let width: Int
    public let height: Int
    public let orientation: CaptureVideoOrientation

    public init(
        sequence: UInt64,
        timestampNanoseconds: UInt64,
        width: Int,
        height: Int,
        orientation: CaptureVideoOrientation
    ) throws {
        // `CMSampleBuffer` can validly start at the zero time origin. The
        // monotonic sequence, not a nonzero presentation timestamp, is the
        // freshness boundary.
        guard sequence > 0,
              width > 0,
              height > 0 else {
            throw AppProducedVideoFrameError.invalidMetadata
        }
        self.sequence = sequence
        self.timestampNanoseconds = timestampNanoseconds
        self.width = width
        self.height = height
        self.orientation = orientation
    }
}

public enum AppProducedVideoFrameError: Error, Equatable, Sendable {
    case invalidMetadata
    case unavailableSDK
    case stopped
}

/// A narrow adapter boundary. Its production implementation is allowed to hand
/// a frame to LiveKit, but it never owns `AVCaptureDevice`, `AVCaptureSession`,
/// a preview, local analysis, or photo capture.
public protocol AppProducedVideoFramePublishing: Sendable {
    func publish(_ frame: AppProducedVideoFrame) async throws
    func cancelPublishing() async
}

public struct UnavailableLiveKitFramePublisher: AppProducedVideoFramePublishing {
    public init() {}
    public func publish(_ frame: AppProducedVideoFrame) async throws {
        throw AppProducedVideoFrameError.unavailableSDK
    }
    public func cancelPublishing() async {}
}

public struct AppProducedVideoPublishSnapshot: Equatable, Sendable {
    public let isActive: Bool
    public let isPublishing: Bool
    public let pendingSequence: UInt64?
    public let lastPublishedSequence: UInt64?
    public let droppedFrameCount: UInt64

    init(
        isActive: Bool,
        isPublishing: Bool,
        pendingSequence: UInt64?,
        lastPublishedSequence: UInt64?,
        droppedFrameCount: UInt64
    ) {
        self.isActive = isActive
        self.isPublishing = isPublishing
        self.pendingSequence = pendingSequence
        self.lastPublishedSequence = lastPublishedSequence
        self.droppedFrameCount = droppedFrameCount
    }
}

/// Capacity-one publication coordinator. A slow WebRTC handoff cannot retain
/// camera frames: it publishes at most one frame and replaces its one waiting
/// frame with the newest valid sequence. `stop()` advances the generation, so a
/// late completion cannot revive a stopped capture session.
public actor LatestAppProducedFramePublisher {
    private let publisher: any AppProducedVideoFramePublishing
    private var generation: UInt64 = 0
    private var active = false
    private var publishing = false
    private var pending: AppProducedVideoFrame?
    private var lastPublishedSequence: UInt64?
    private var droppedFrameCount: UInt64 = 0
    private var worker: Task<Void, Never>?

    public init(publisher: any AppProducedVideoFramePublishing) {
        self.publisher = publisher
    }

    /// Starts only after a prior cancellation worker has actually finished. The
    /// false result tells the connection owner to wait for that explicit stop
    /// completion instead of accidentally creating a second concurrent publish.
    @discardableResult
    public func start() -> Bool {
        guard worker == nil else { return false }
        generation = nextGeneration()
        active = true
        publishing = false
        pending = nil
        lastPublishedSequence = nil
        droppedFrameCount = 0
        return true
    }

    public func offer(_ frame: AppProducedVideoFrame) {
        guard active else { return }
        if let lastPublishedSequence, frame.sequence <= lastPublishedSequence {
            droppedFrameCount &+= 1
            return
        }
        if let pending {
            guard frame.sequence > pending.sequence else {
                droppedFrameCount &+= 1
                return
            }
            droppedFrameCount &+= 1
        }
        pending = frame
        startWorkerIfNeeded()
    }

    public func stop() async {
        generation = nextGeneration()
        active = false
        pending = nil
        worker?.cancel()
        await publisher.cancelPublishing()
    }

    public func snapshot() -> AppProducedVideoPublishSnapshot {
        .init(
            isActive: active,
            isPublishing: publishing,
            pendingSequence: pending?.sequence,
            lastPublishedSequence: lastPublishedSequence,
            droppedFrameCount: droppedFrameCount
        )
    }

    private func startWorkerIfNeeded() {
        guard !publishing else { return }
        publishing = true
        let token = generation
        worker = Task { [weak self] in
            await self?.drain(generation: token)
        }
    }

    private func drain(generation token: UInt64) async {
        defer { finishWorker(generation: token) }
        while !Task.isCancelled, active, token == generation, let frame = pending {
            pending = nil
            do {
                try await publisher.publish(frame)
            } catch {
                // T08-02 maps LiveKit transport failures to the explicit
                // connection state. This coordinator only preserves bounded
                // frame ownership and must not fabricate a fixture success.
            }
            guard active, token == generation, !Task.isCancelled else { return }
            if lastPublishedSequence == nil || frame.sequence > lastPublishedSequence! {
                lastPublishedSequence = frame.sequence
            }
        }
    }

    // A stopped generation must still release its worker slot. A subsequent
    // start is refused until this point, preserving the one-publish limit.
    private func finishWorker(generation token: UInt64) {
        _ = token
        publishing = false
        worker = nil
    }

    private func nextGeneration() -> UInt64 {
        generation &+= 1
        if generation == 0 { generation = 1 }
        return generation
    }
}
