@testable import CaptureKit
import Foundation
import Testing

@Suite("Local quality scheduler")
struct LocalQualitySchedulerTests {
    private let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    @Test func defaultsInvalidConfigurationAndP95AreDeterministic() {
        let defaults = LocalQualitySchedulerConfiguration.default
        #expect(defaults.cadenceMilliseconds == 250)
        #expect(defaults.metricWindowSize == 120)
        #expect(defaults.stableFrameDelta == 0.020)
        #expect(defaults.requiredStableDurationMilliseconds == 600)
        #expect(!LocalQualitySchedulerConfiguration(cadenceMilliseconds: 0).isValid)
        #expect(!LocalQualitySchedulerConfiguration(metricWindowSize: 0).isValid)
        #expect(!LocalQualitySchedulerConfiguration(stableFrameDelta: .nan).isValid)
        #expect(LocalQualitySchedulerMetrics.nearestRankP95([]) == nil)
        #expect(LocalQualitySchedulerMetrics.nearestRankP95(Array(1 ... 100)) == 95)
        #expect(LocalQualitySchedulerMetrics.nearestRankP95([9, 1, 5, 3]) == 9)
    }

    @Test func sessionAndSequenceWatermarksRejectStaleInput() async throws {
        let clock = ManualClock(0)
        let scheduler = LocalQualityScheduler(clock: clock, sleeper: AdvancingSleeper(clock: clock))
        let first = LocalQualitySession(value: firstID)
        let second = LocalQualitySession(value: secondID)
        let input = try frame(1)
        #expect(await scheduler.submit(session: first, sequence: 1, frame: input) == .staleSession)
        await scheduler.start(session: first)
        #expect(await scheduler.submit(session: second, sequence: 1, frame: input) == .staleSession)
        #expect(await scheduler.submit(session: first, sequence: 0, frame: input) == .invalidSequence)
        #expect(await scheduler.submit(session: first, sequence: 1, frame: input) == .accepted)
        #expect(await scheduler.submit(session: first, sequence: 1, frame: input) == .invalidSequence)
        await scheduler.cancel()
    }

    @Test func pendingFramesCoalesceLatestAndKeepOneActiveAnalyzer() async throws {
        let clock = ManualClock(0)
        let analyzer = GatedAnalyzer()
        let scheduler = LocalQualityScheduler(analyzer: analyzer, clock: clock, sleeper: AdvancingSleeper(clock: clock), configuration: .init(cadenceMilliseconds: 1))
        let session = LocalQualitySession(value: firstID)
        await scheduler.start(session: session)
        #expect(await scheduler.submit(session: session, sequence: 1, frame: try frame(1)) == .accepted)
        try await analyzer.waitForCall(1)
        for sequence in 2 ... 20 {
            #expect(await scheduler.submit(session: session, sequence: Int64(sequence), frame: try frame(UInt8(sequence))) == .accepted)
        }
        let queued = await scheduler.metrics()
        #expect(queued.replacedPendingFrames == 18)
        #expect(queued.pendingFrameCount == 1)
        #expect(queued.isAnalyzing)
        await analyzer.releaseOne()
        try await analyzer.waitForCall(2)
        #expect((await analyzer.sequences()).last == 20)
        #expect((await analyzer.maximumActive()) == 1)
        await scheduler.cancel()
        await analyzer.releaseAll()
    }

    @Test func cancelRestartSuppressesUncooperativeOldCompletionAndDoesNotOverlap() async throws {
        let clock = ManualClock(0)
        let analyzer = GatedAnalyzer(ignoreCancellation: true)
        let scheduler = LocalQualityScheduler(analyzer: analyzer, clock: clock, sleeper: AdvancingSleeper(clock: clock), configuration: .init(cadenceMilliseconds: 1))
        let first = LocalQualitySession(value: firstID)
        let second = LocalQualitySession(value: secondID)
        await scheduler.start(session: first)
        #expect(await scheduler.submit(session: first, sequence: 1, frame: try frame(1)) == .accepted)
        try await analyzer.waitForCall(1)
        await scheduler.cancel()
        await scheduler.start(session: second)
        #expect(await scheduler.submit(session: second, sequence: 1, frame: try frame(2)) == .accepted)
        #expect((await analyzer.maximumActive()) == 1)
        await analyzer.releaseOne()
        try await analyzer.waitForCall(2)
        #expect((await analyzer.maximumActive()) == 1)
        await scheduler.cancel()
        await analyzer.releaseAll()
    }

    @Test func analysisBoundaryAndReadyGuardUseExactMilliseconds() async throws {
        let clock = ManualClock(0)
        let analyzer = GatedAnalyzer(alwaysReady: true)
        let scheduler = LocalQualityScheduler(
            analyzer: analyzer,
            clock: clock,
            sleeper: AdvancingSleeper(clock: clock),
            configuration: .init(cadenceMilliseconds: 1)
        )
        let session = LocalQualitySession(value: firstID)
        let stream = await scheduler.updates()
        await scheduler.start(session: session)

        #expect(await scheduler.submit(session: session, sequence: 1, frame: try frame(1)) == .accepted)
        try await analyzer.waitForCall(1)
        clock.advance(by: 250)
        await analyzer.releaseOne()
        let exact250 = try await next(stream)
        #expect(exact250?.analysis.hint == .holdSteady)
        #expect(exact250?.latencyMilliseconds == 250)

        clock.advance(by: 349)
        #expect(await scheduler.submit(session: session, sequence: 2, frame: try frame(2)) == .accepted)
        try await analyzer.waitForCall(2)
        await analyzer.releaseOne()
        #expect((try await next(stream))?.analysis.hint == .holdSteady) // 599ms

        clock.advance(by: 1)
        #expect(await scheduler.submit(session: session, sequence: 3, frame: try frame(3)) == .accepted)
        try await analyzer.waitForCall(3)
        await analyzer.releaseOne()
        #expect((try await next(stream))?.analysis.hint == .ready) // 600ms
        #expect(await analyzer.stableDurations().prefix(3).elementsEqual([0, 599, 600]))

        #expect(await scheduler.submit(session: session, sequence: 4, frame: try frame(4)) == .accepted)
        try await analyzer.waitForCall(4)
        clock.advance(by: 251)
        await analyzer.releaseOne()
        let overloaded = try await next(stream)
        #expect(overloaded?.analysis.hint == .analyzerUnavailable)
        #expect(overloaded?.latencyMilliseconds == 251)
    }

    @Test func invalidBackwardClockAndStreamDropFailClosedWithBoundedMetrics() async throws {
        let clock = ManualClock(-1)
        let scheduler = LocalQualityScheduler(clock: clock, sleeper: AdvancingSleeper(clock: clock), configuration: .init(metricWindowSize: 2))
        let session = LocalQualitySession(value: firstID)
        let stream = await scheduler.updates()
        await scheduler.start(session: session)
        #expect(await scheduler.submit(session: session, sequence: 1, frame: try frame(1)) == .accepted)
        #expect((try await next(stream))?.analysis.hint == .analyzerUnavailable)
        #expect((await scheduler.metrics()).publishedLatencySamples == 0)
        clock.set(100)
        #expect(await scheduler.submit(session: session, sequence: 2, frame: try frame(2)) == .accepted)
        clock.set(99)
        #expect(await scheduler.submit(session: session, sequence: 3, frame: try frame(3)) == .accepted)
        #expect((try await next(stream))?.analysis.hint == .analyzerUnavailable)
    }

    @Test func deadlineOverflowFailsClosedAndRetainsNoLatency() async throws {
        let clock = ManualClock(Int64.max - 100)
        let analyzer = GatedAnalyzer()
        let scheduler = LocalQualityScheduler(analyzer: analyzer, clock: clock, sleeper: AdvancingSleeper(clock: clock))
        let session = LocalQualitySession(value: firstID)
        let stream = await scheduler.updates()
        await scheduler.start(session: session)
        _ = await scheduler.submit(session: session, sequence: 1, frame: try frame(1))
        try await analyzer.waitForCall(1)
        await analyzer.releaseOne()
        _ = try await next(stream)
        _ = await scheduler.submit(session: session, sequence: 2, frame: try frame(2))
        let update = try await next(stream)
        #expect(update?.analysis.hint == .analyzerUnavailable)
    }

    @Test func capacityOneStreamDropsOldUpdatesAndKeepsNewest() async throws {
        let clock = ManualClock(-1)
        let scheduler = LocalQualityScheduler(clock: clock, sleeper: AdvancingSleeper(clock: clock))
        let session = LocalQualitySession(value: firstID)
        let stream = await scheduler.updates()
        await scheduler.start(session: session)
        for sequence in 1 ... 3 {
            _ = await scheduler.submit(session: session, sequence: Int64(sequence), frame: try frame(UInt8(sequence)))
        }
        let newest = try await next(stream)
        #expect(newest?.sequence == 3)
        #expect((await scheduler.metrics()).droppedUpdates == 2)
    }

    @Test func boundedWindowP95ResetsForNewSessionAndIsRepeatable() async throws {
        for _ in 0 ..< 2 {
            let clock = ManualClock(0)
            let analyzer = ImmediateAnalyzer(clock: clock, durations: [1, 2, 3])
            let scheduler = LocalQualityScheduler(analyzer: analyzer, clock: clock, sleeper: AdvancingSleeper(clock: clock), configuration: .init(cadenceMilliseconds: 1, metricWindowSize: 2))
            let session = LocalQualitySession(value: firstID)
            let stream = await scheduler.updates()
            await scheduler.start(session: session)
            for sequence in 1 ... 3 {
                _ = await scheduler.submit(session: session, sequence: Int64(sequence), frame: try frame(UInt8(sequence)))
                _ = try await next(stream)
            }
            let metrics = await scheduler.metrics()
            #expect(metrics.publishedLatencySamples == 2)
            #expect(metrics.p95LatencyMilliseconds == 3)
            await scheduler.start(session: LocalQualitySession(value: secondID))
            #expect((await scheduler.metrics()).publishedLatencySamples == 0)
        }
    }

    private func next(_ stream: AsyncStream<LocalQualityUpdate>) async throws -> LocalQualityUpdate? {
        try await withThrowingTaskGroup(of: LocalQualityUpdate?.self) { group in
            group.addTask { var iterator = stream.makeAsyncIterator(); return await iterator.next() }
            group.addTask { try await Task.sleep(for: .seconds(1)); throw SchedulerTestTimeout() }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw SchedulerTestTimeout() }
            return value
        }
    }

    private func frame(_ value: UInt8) throws -> LocalQualityAnalyzer.RGBA8Frame {
        try .init(width: 4, height: 4, bytes: Array(repeating: value, count: 64))
    }
}

private final class ManualClock: LocalQualityMonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64
    init(_ value: Int64) { self.value = value }
    func nowMilliseconds() -> Int64 { lock.withLock { value } }
    func set(_ value: Int64) { lock.withLock { self.value = value } }
    func advance(by milliseconds: Int64) { lock.withLock { value += milliseconds } }
}

private struct AdvancingSleeper: LocalQualitySleeper {
    let clock: ManualClock
    func sleep(milliseconds: Int64) async throws { clock.advance(by: milliseconds) }
}

private actor GatedAnalyzer: LocalQualityAnalyzing {
    private var gates: [CheckedContinuation<Void, Never>] = []
    private var callCount = 0
    private var active = 0
    private var maximum = 0
    private var observedSequences: [Int64] = []
    private var observedStableDurations: [Int] = []
    private let ignoreCancellation: Bool
    private let alwaysReady: Bool

    init(ignoreCancellation: Bool = false, alwaysReady: Bool = false) {
        self.ignoreCancellation = ignoreCancellation
        self.alwaysReady = alwaysReady
    }

    func analyze(frame: LocalQualityAnalyzer.RGBA8Frame, previousFrame: LocalQualityAnalyzer.RGBA8Frame?, stableDurationMilliseconds: Int) async -> LocalQualityAnalyzer.Analysis {
        callCount += 1
        active += 1
        maximum = max(maximum, active)
        observedSequences.append(Int64(frame.bytes[0]))
        observedStableDurations.append(stableDurationMilliseconds)
        await withCheckedContinuation { gates.append($0) }
        active -= 1
        if ignoreCancellation { _ = Task.isCancelled }
        return .init(hint: alwaysReady ? .ready : .holdSteady, metrics: .init(processedWidth: 4, processedHeight: 4, meanLuma: 100, laplacianPopulationVariance: 30, normalizedFrameDifference: 0))
    }

    func waitForCall(_ expected: Int) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { while !Task.isCancelled && await self.currentCallCount() < expected { await Task.yield() } }
            group.addTask { try await Task.sleep(for: .seconds(1)); throw SchedulerTestTimeout() }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }
    func releaseOne() { gates.removeFirst().resume() }
    func releaseAll() { while !gates.isEmpty { gates.removeFirst().resume() } }
    func maximumActive() -> Int { maximum }
    func sequences() -> [Int64] { observedSequences }
    func stableDurations() -> [Int] { observedStableDurations }
    private func currentCallCount() -> Int { callCount }
}

private struct SchedulerTestTimeout: Error {}

private actor ImmediateAnalyzer: LocalQualityAnalyzing {
    private let clock: ManualClock
    private var durations: [Int64]
    init(clock: ManualClock, durations: [Int64]) { self.clock = clock; self.durations = durations }
    func analyze(frame: LocalQualityAnalyzer.RGBA8Frame, previousFrame: LocalQualityAnalyzer.RGBA8Frame?, stableDurationMilliseconds: Int) async -> LocalQualityAnalyzer.Analysis {
        clock.advance(by: durations.isEmpty ? 0 : durations.removeFirst())
        return .init(hint: .holdSteady, metrics: .init(processedWidth: 4, processedHeight: 4, meanLuma: 100, laplacianPopulationVariance: 30, normalizedFrameDifference: 0))
    }
}
