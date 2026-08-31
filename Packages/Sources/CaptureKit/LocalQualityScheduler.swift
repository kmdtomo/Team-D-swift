import Foundation
import os
import DomainKit

public protocol LocalQualityMonotonicClock: Sendable {
    func nowMilliseconds() -> Int64
}

public protocol LocalQualitySleeper: Sendable {
    func sleep(milliseconds: Int64) async throws
}

public struct SystemLocalQualityClock: LocalQualityMonotonicClock {
    public init() {}
    public func nowMilliseconds() -> Int64 {
        let milliseconds = DispatchTime.now().uptimeNanoseconds / 1_000_000
        return milliseconds > UInt64(Int64.max) ? Int64.max : Int64(milliseconds)
    }
}

public struct SystemLocalQualitySleeper: LocalQualitySleeper {
    public init() {}
    public func sleep(milliseconds: Int64) async throws {
        guard milliseconds >= 0 else { throw CancellationError() }
        try await Task.sleep(for: .milliseconds(milliseconds))
    }
}

public protocol LocalQualityAnalyzing: Sendable {
    func analyze(
        frame: LocalQualityAnalyzer.RGBA8Frame,
        previousFrame: LocalQualityAnalyzer.RGBA8Frame?,
        stableDurationMilliseconds: Int
    ) async -> LocalQualityAnalyzer.Analysis
}

public struct LocalQualityAnalyzerAdapter: LocalQualityAnalyzing {
    public let analyzer: LocalQualityAnalyzer
    public init(analyzer: LocalQualityAnalyzer = LocalQualityAnalyzer()) { self.analyzer = analyzer }
    public func analyze(frame: LocalQualityAnalyzer.RGBA8Frame, previousFrame: LocalQualityAnalyzer.RGBA8Frame?, stableDurationMilliseconds: Int) async -> LocalQualityAnalyzer.Analysis {
        analyzer.analyze(frame: frame, previousFrame: previousFrame, stableDurationMilliseconds: stableDurationMilliseconds)
    }
}

public struct LocalQualitySession: Hashable, Sendable {
    public let value: UUID
    /// Identity belongs to the caller; this scheduler never creates a UUID.
    public init(value: UUID) { self.value = value }
}

public enum LocalQualitySubmission: Sendable, Equatable {
    case accepted
    case staleSession
    case invalidSequence
}

public struct LocalQualitySchedulerConfiguration: Sendable, Equatable {
    public let cadenceMilliseconds: Int64
    public let metricWindowSize: Int
    public let stableFrameDelta: Double
    public let requiredStableDurationMilliseconds: Int64
    public let maximumAnalysisMilliseconds: Int64
    public static let `default` = LocalQualitySchedulerConfiguration()

    public init(
        cadenceMilliseconds: Int64 = 250,
        metricWindowSize: Int = 120,
        stableFrameDelta: Double = 0.020,
        requiredStableDurationMilliseconds: Int64 = 600,
        maximumAnalysisMilliseconds: Int64 = 250
    ) {
        self.cadenceMilliseconds = cadenceMilliseconds
        self.metricWindowSize = metricWindowSize
        self.stableFrameDelta = stableFrameDelta
        self.requiredStableDurationMilliseconds = requiredStableDurationMilliseconds
        self.maximumAnalysisMilliseconds = maximumAnalysisMilliseconds
    }

    public var isValid: Bool {
        cadenceMilliseconds > 0
            && (1 ... 1_024).contains(metricWindowSize)
            && stableFrameDelta.isFinite
            && (0 ... 1).contains(stableFrameDelta)
            && requiredStableDurationMilliseconds >= 0
            && maximumAnalysisMilliseconds >= 0
    }
}

public struct LocalQualitySchedulerMetrics: Sendable, Equatable {
    public let publishedLatencySamples: Int
    public let p95LatencyMilliseconds: Int64?
    public let replacedPendingFrames: Int
    public let droppedUpdates: Int
    public let pendingFrameCount: Int
    public let isAnalyzing: Bool

    public static func nearestRankP95(_ samples: [Int64]) -> Int64? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        return sorted[((95 * sorted.count + 99) / 100) - 1]
    }
}

public struct LocalQualityUpdate: Sendable, Equatable {
    public let session: LocalQualitySession
    public let sequence: Int64
    public let analysis: LocalQualityAnalyzer.Analysis
    /// Nil means time was invalid, reversed, or overflowed and is not a metric sample.
    public let latencyMilliseconds: Int64?
}

/// Single-consumer stream. `updates()` returns the stream created once at init;
/// competing consumers are unsupported. Buffered updates retain their session
/// identity, so consumers filter for their active session after a restart; an
/// already-buffered valid old update cannot be retracted. Its capacity is one
/// and dropped yields are counted as bounded metrics.
public actor LocalQualityScheduler {
    private struct Pending: Sendable {
        let session: LocalQualitySession
        let generation: Int64
        let sequence: Int64
        let submittedAt: Int64
        let frame: LocalQualityAnalyzer.RGBA8Frame
    }

    private let analyzer: any LocalQualityAnalyzing
    private let clock: any LocalQualityMonotonicClock
    private let sleeper: any LocalQualitySleeper
    private let configuration: LocalQualitySchedulerConfiguration
    private let stream: AsyncStream<LocalQualityUpdate>
    private let continuation: AsyncStream<LocalQualityUpdate>.Continuation
    private let signpostLog = OSLog(subsystem: "com.teamd.capture", category: "local-quality")
    private var currentSession: LocalQualitySession?
    private var generation: Int64 = 0
    private var lastSequence: Int64 = 0
    private var lastClock: Int64?
    private var pending: Pending?
    private var worker: Task<Void, Never>?
    private var workerID: Int64?
    private var nextWorkerID: Int64 = 0
    private var previousFrame: LocalQualityAnalyzer.RGBA8Frame?
    private var stableSince: Int64?
    private var lastStarted: Int64?
    private var latencies: [Int64] = []
    private var replacedPendingFrames = 0
    private var droppedUpdates = 0

    public init(analyzer: any LocalQualityAnalyzing = LocalQualityAnalyzerAdapter(), clock: any LocalQualityMonotonicClock = SystemLocalQualityClock(), sleeper: any LocalQualitySleeper = SystemLocalQualitySleeper(), configuration: LocalQualitySchedulerConfiguration = .default) {
        self.analyzer = analyzer
        self.clock = clock
        self.sleeper = sleeper
        self.configuration = configuration
        let pair = AsyncStream<LocalQualityUpdate>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.stream = pair.stream
        self.continuation = pair.continuation
    }

    public func updates() -> AsyncStream<LocalQualityUpdate> { stream }

    public func start(session: LocalQualitySession) {
        invalidate()
        currentSession = session
        lastSequence = 0
        lastClock = nil
        latencies.removeAll(keepingCapacity: true)
        replacedPendingFrames = 0
        droppedUpdates = 0
    }

    public func cancel() {
        invalidate()
        currentSession = nil
        lastSequence = 0
        lastClock = nil
    }

    @discardableResult
    public func submit(session: LocalQualitySession, sequence: Int64, frame: LocalQualityAnalyzer.RGBA8Frame) -> LocalQualitySubmission {
        guard session == currentSession else { return .staleSession }
        guard sequence > 0, sequence > lastSequence else { return .invalidSequence }
        lastSequence = sequence
        let submittedAt = clock.nowMilliseconds()
        guard submittedAt >= 0, lastClock.map({ submittedAt >= $0 }) ?? true else {
            pending = nil
            resetStability()
            publishUnavailable(session: session, generation: generation, sequence: sequence, latency: nil)
            return .accepted
        }
        lastClock = submittedAt
        let item = Pending(session: session, generation: generation, sequence: sequence, submittedAt: submittedAt, frame: frame)
        if pending != nil { increment(&replacedPendingFrames) }
        pending = item
        startWorkerIfNeeded()
        return .accepted
    }

    public func metrics() -> LocalQualitySchedulerMetrics {
        .init(
            publishedLatencySamples: latencies.count,
            p95LatencyMilliseconds: .nearestRankP95(latencies),
            replacedPendingFrames: replacedPendingFrames,
            droppedUpdates: droppedUpdates,
            pendingFrameCount: pending == nil ? 0 : 1,
            isAnalyzing: worker != nil
        )
    }

    private func invalidate() {
        generation &+= 1
        worker?.cancel()
        // Keep handle/identity until its matching finish path. An analyzer can ignore
        // cancellation, but it must never overlap the restarted session's analysis.
        pending = nil
        lastStarted = nil
        resetStability()
    }

    private func resetStability() { previousFrame = nil; stableSince = nil }

    private func startWorkerIfNeeded() {
        guard worker == nil, pending != nil else { return }
        nextWorkerID &+= 1
        let identity = nextWorkerID
        workerID = identity
        worker = Task { [weak self] in
            guard let self else { return }
            await self.runWorker(identity: identity)
            await self.finishWorker(identity: identity)
        }
    }

    private func finishWorker(identity: Int64) {
        guard workerID == identity else { return }
        worker = nil
        workerID = nil
        startWorkerIfNeeded()
    }

    private func runWorker(identity: Int64) async {
        while workerID == identity, !Task.isCancelled {
            guard let item = pending else { return }
            pending = nil
            guard isCurrent(item) else { continue }
            guard configuration.isValid else { resetStability(); publishUnavailable(item, latency: nil); continue }
            guard let started = await waitForCadence(item, identity: identity) else {
                if isCurrent(item), !Task.isCancelled { resetStability(); publishUnavailable(item, latency: nil) }
                continue
            }
            guard workerID == identity, isCurrent(item), !Task.isCancelled else { return }
            if let newest = pending, newest.sequence > item.sequence {
                increment(&replacedPendingFrames)
                continue
            }
            guard let stability = stableDuration(at: started) else { resetStability(); publishUnavailable(item, latency: nil); continue }
            guard stability <= Int64(Int.max) else { resetStability(); publishUnavailable(item, latency: nil); continue }
            lastStarted = started

            os_signpost(.begin, log: signpostLog, name: "LocalQualityAnalysis")
            let analysis = await analyzer.analyze(
                frame: item.frame,
                previousFrame: previousFrame,
                stableDurationMilliseconds: Int(stability)
            )
            os_signpost(.end, log: signpostLog, name: "LocalQualityAnalysis")
            // An old, cancelled, uncooperative analyzer cannot mutate the new lifecycle.
            guard workerID == identity, isCurrent(item), !Task.isCancelled else { return }

            let finished = clock.nowMilliseconds()
            guard finished >= started, let duration = difference(finished, started), let latency = difference(finished, item.submittedAt) else {
                resetStability(); publishUnavailable(item, latency: nil); continue
            }
            lastClock = finished
            guard duration <= configuration.maximumAnalysisMilliseconds else { resetStability(); publishUnavailable(item, latency: latency); continue }
            let guarded = guardReady(analysis, stability: stability)
            updateStability(guarded, item: item, started: started)
            publish(item, analysis: guarded, latency: latency)
        }
    }

    private func waitForCadence(_ item: Pending, identity: Int64) async -> Int64? {
        let before = clock.nowMilliseconds()
        guard before >= 0, lastClock.map({ before >= $0 }) ?? true else { return nil }
        lastClock = before
        if let lastStarted {
            let deadline = lastStarted.addingReportingOverflow(configuration.cadenceMilliseconds)
            guard !deadline.overflow else { return nil }
            if before < deadline.partialValue {
                do { try await sleeper.sleep(milliseconds: deadline.partialValue - before) } catch { return nil }
            }
        }
        guard workerID == identity, isCurrent(item), !Task.isCancelled else { return nil }
        let started = clock.nowMilliseconds()
        guard started >= before, started >= 0, lastClock.map({ started >= $0 }) ?? true else { return nil }
        lastClock = started
        return started
    }

    private func stableDuration(at now: Int64) -> Int64? {
        guard let stableSince else { return 0 }
        return difference(now, stableSince)
    }

    private func difference(_ later: Int64, _ earlier: Int64) -> Int64? {
        guard later >= earlier else { return nil }
        let result = later.subtractingReportingOverflow(earlier)
        return result.overflow ? nil : result.partialValue
    }

    private func guardReady(_ analysis: LocalQualityAnalyzer.Analysis, stability: Int64) -> LocalQualityAnalyzer.Analysis {
        guard analysis.hint == .ready else { return analysis }
        guard stability >= configuration.requiredStableDurationMilliseconds,
              analysis.metrics?.normalizedFrameDifference.map({ $0 < configuration.stableFrameDelta }) ?? false
        else { return .init(hint: .holdSteady, metrics: analysis.metrics) }
        return analysis
    }

    private func updateStability(_ analysis: LocalQualityAnalyzer.Analysis, item: Pending, started: Int64) {
        switch analysis.hint {
        case .holdSteady:
            if analysis.metrics?.normalizedFrameDifference.map({ $0 >= configuration.stableFrameDelta }) == true { resetStability() }
            else { previousFrame = item.frame; stableSince = stableSince ?? started }
        case .ready:
            previousFrame = item.frame; stableSince = stableSince ?? started
        case .tooDark, .tooBright, .tooBlurry, .analyzerUnavailable:
            resetStability()
        }
    }

    private func isCurrent(_ item: Pending) -> Bool { item.generation == generation && item.session == currentSession && item.sequence == lastSequence }
    private func publishUnavailable(_ item: Pending, latency: Int64?) { publish(item, analysis: .init(hint: .analyzerUnavailable, metrics: nil), latency: latency) }
    private func publishUnavailable(session: LocalQualitySession, generation: Int64, sequence: Int64, latency: Int64?) {
        guard generation == self.generation, session == currentSession, sequence == lastSequence else { return }
        publish(.init(session: session, sequence: sequence, analysis: .init(hint: .analyzerUnavailable, metrics: nil), latencyMilliseconds: latency))
    }
    private func publish(_ item: Pending, analysis: LocalQualityAnalyzer.Analysis, latency: Int64?) {
        guard isCurrent(item) else { return }
        publish(.init(session: item.session, sequence: item.sequence, analysis: analysis, latencyMilliseconds: latency))
    }
    private func publish(_ update: LocalQualityUpdate) {
        if let latency = update.latencyMilliseconds { record(latency) }
        if case .dropped = continuation.yield(update) {
            increment(&droppedUpdates)
        }
    }
    private func record(_ latency: Int64) {
        guard latency >= 0 else { return }
        latencies.append(latency)
        if latencies.count > configuration.metricWindowSize { latencies.removeFirst(latencies.count - configuration.metricWindowSize) }
    }

    private func increment(_ value: inout Int) {
        if value < Int.max { value += 1 }
    }
}
