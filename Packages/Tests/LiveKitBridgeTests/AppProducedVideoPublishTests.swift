import CaptureKit
import Foundation
import LiveKitBridge
import Testing

@Test func newestPendingFrameReplacesOlderFrameWhileOnePublishIsInFlight() async throws {
    let publisher = GatePublisher()
    let coordinator = LatestAppProducedFramePublisher(publisher: publisher)
    let started = await coordinator.start()
    #expect(started)
    await coordinator.offer(try frame(1))
    await publisher.waitUntilFirstPublishStarts()
    await coordinator.offer(try frame(2))
    await coordinator.offer(try frame(3))
    let pending = await coordinator.snapshot()
    #expect(pending.isPublishing)
    #expect(pending.pendingSequence == 3)
    #expect(pending.droppedFrameCount == 1)
    await publisher.releaseFirstPublish()
    await publisher.waitForPublishedSequences([1, 3])
    let completed = await coordinator.snapshot()
    #expect(completed.lastPublishedSequence == 3)
    #expect(completed.pendingSequence == nil)
}

@Test func staleSequenceIsDroppedAndNeverPublished() async throws {
    let publisher = ImmediatePublisher()
    let coordinator = LatestAppProducedFramePublisher(publisher: publisher)
    let started = await coordinator.start()
    #expect(started)
    await coordinator.offer(try frame(8))
    await publisher.waitForPublishedSequences([8])
    await coordinator.offer(try frame(8))
    await coordinator.offer(try frame(7))
    let snapshot = await coordinator.snapshot()
    let sequences = await publisher.sequences
    #expect(snapshot.lastPublishedSequence == 8)
    #expect(snapshot.droppedFrameCount == 2)
    #expect(sequences == [8])
}

@Test func stopCancelsPublisherAndLatePublishCannotRestartTheCoordinator() async throws {
    let publisher = GatePublisher()
    let coordinator = LatestAppProducedFramePublisher(publisher: publisher)
    let started = await coordinator.start()
    #expect(started)
    await coordinator.offer(try frame(1))
    await publisher.waitUntilFirstPublishStarts()
    await coordinator.stop()
    let stopped = await coordinator.snapshot()
    #expect(!stopped.isActive)
    #expect(stopped.isPublishing) // the cancelled publisher is still draining
    #expect(stopped.pendingSequence == nil)
    let cancelCount = await publisher.cancelCount
    #expect(cancelCount == 1)
    await publisher.releaseFirstPublish()
    await publisher.waitForPublisherToBecomeIdle()
    await waitForCoordinatorToBecomeIdle(coordinator)
    let sequences = await publisher.sequences
    let lateSnapshot = await coordinator.snapshot()
    #expect(sequences == [1])
    #expect(!lateSnapshot.isPublishing)
    #expect(lateSnapshot.lastPublishedSequence == nil)
}

@Test func restartIsRejectedUntilCancelledPublishHasActuallyDrained() async throws {
    let publisher = GatePublisher()
    let coordinator = LatestAppProducedFramePublisher(publisher: publisher)
    let started = await coordinator.start()
    #expect(started)
    await coordinator.offer(try frame(1))
    await publisher.waitUntilFirstPublishStarts()
    await coordinator.stop()
    let prematurelyRestarted = await coordinator.start()
    #expect(!prematurelyRestarted)
    await publisher.releaseFirstPublish()
    await publisher.waitForPublisherToBecomeIdle()
    await waitForCoordinatorToBecomeIdle(coordinator)
    let restarted = await coordinator.start()
    #expect(restarted)
}

@Test func unavailablePublisherIsAnExplicitFailureNotFixtureSuccess() async throws {
    let publisher = UnavailableLiveKitFramePublisher()
    await #expect(throws: AppProducedVideoFrameError.unavailableSDK) {
        try await publisher.publish(try frame(1))
    }
}

@Test func failedTransportIsObservableAndNeverAdvancesPublishedWatermark() async throws {
    let publisher = FailOncePublisher()
    let coordinator = LatestAppProducedFramePublisher(publisher: publisher)
    let started = await coordinator.start()
    #expect(started)

    await coordinator.offer(try frame(1))
    await publisher.waitForAttemptedSequences([1])
    await waitForCoordinatorToBecomeIdle(coordinator)

    let failed = await coordinator.snapshot()
    #expect(failed.lastPublishedSequence == nil)
    #expect(failed.lastFailedSequence == 1)
    #expect(failed.publishFailureCount == 1)

    await coordinator.offer(try frame(2))
    await publisher.waitForPublishedSequences([2])
    let recovered = await coordinator.snapshot()
    #expect(recovered.lastPublishedSequence == 2)
    #expect(recovered.lastFailedSequence == 1)
    #expect(recovered.publishFailureCount == 1)
}

private func frame(_ sequence: UInt64) throws -> AppProducedVideoFrame {
    try .init(sequence: sequence, timestampNanoseconds: sequence * 1_000, width: 1920, height: 1080, orientation: .portrait)
}

private func waitForCoordinatorToBecomeIdle(_ coordinator: LatestAppProducedFramePublisher) async {
    while (await coordinator.snapshot()).isPublishing { await Task.yield() }
}

private actor ImmediatePublisher: AppProducedVideoFramePublishing {
    private(set) var sequences: [UInt64] = []
    func publish(_ frame: AppProducedVideoFrame) async throws { sequences.append(frame.sequence) }
    func cancelPublishing() async {}
    func waitForPublishedSequences(_ expected: [UInt64]) async {
        while sequences != expected { await Task.yield() }
    }
}

private actor GatePublisher: AppProducedVideoFramePublishing {
    private(set) var sequences: [UInt64] = []
    private(set) var cancelCount = 0
    private var firstPublishStarted = false
    private var releaseFirst = false
    private var isPublishing = false

    func publish(_ frame: AppProducedVideoFrame) async throws {
        isPublishing = true
        defer { isPublishing = false }
        sequences.append(frame.sequence)
        if frame.sequence == 1 {
            firstPublishStarted = true
            while !releaseFirst { await Task.yield() }
        }
    }
    func cancelPublishing() async { cancelCount += 1 }
    func waitUntilFirstPublishStarts() async { while !firstPublishStarted { await Task.yield() } }
    func releaseFirstPublish() async { releaseFirst = true }
    func waitForPublishedSequences(_ expected: [UInt64]) async { while sequences != expected { await Task.yield() } }
    func waitForPublisherToBecomeIdle() async { while isPublishing { await Task.yield() } }
}

private actor FailOncePublisher: AppProducedVideoFramePublishing {
    private(set) var attemptedSequences: [UInt64] = []
    private(set) var publishedSequences: [UInt64] = []

    func publish(_ frame: AppProducedVideoFrame) async throws {
        attemptedSequences.append(frame.sequence)
        if frame.sequence == 1 { throw AppProducedVideoFrameError.unavailableSDK }
        publishedSequences.append(frame.sequence)
    }

    func cancelPublishing() async {}
    func waitForAttemptedSequences(_ expected: [UInt64]) async { while attemptedSequences != expected { await Task.yield() } }
    func waitForPublishedSequences(_ expected: [UInt64]) async { while publishedSequences != expected { await Task.yield() } }
}
