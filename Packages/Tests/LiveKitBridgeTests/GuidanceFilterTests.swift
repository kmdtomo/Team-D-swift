import ContractKit
import DomainKit
import Foundation
import LiveKitBridge
import Testing

@Test(arguments: [
    (Int64(199), GuidanceFilterResult.accepted(.init(code: .ready))),
    (Int64(200), GuidanceFilterResult.rejected(.expired)),
    (Int64(201), GuidanceFilterResult.rejected(.expired)),
])
func expiryBoundaryUsesExclusiveExpiry(_ fixture: (Int64, GuidanceFilterResult)) throws {
    var state = try connectedState()
    #expect(state.reduce(event(expiresAt: 200), clock: FakeClock(fixture.0)) == fixture.1)
}

@Test func everyRejectionLeavesTheEntireFilterStateUnchanged() throws {
    let cases: [(GuidanceEvent, FakeClock, GuidanceFilterRejectionReason, GuidanceConnectionState?)] = [
        (event(sessionId: "other", sequence: 2), FakeClock(101), .sessionMismatch, nil),
        (event(sequence: 2, shot: .back), FakeClock(101), .shotMismatch, nil),
        (event(sequence: 2), FakeClock(101), .connectionUnavailable, .disconnected),
        (event(sequence: 1), FakeClock(101), .sequenceNotNew, nil),
        (event(sequence: 2, expiresAt: 101), FakeClock(101), .expired, nil),
        (event(sequence: 2), FakeClock(-1), .invalidClock, nil),
        (event(sequence: 2), FakeClock(99), .clockMovedBackward, nil),
    ]
    for (input, clock, reason, connection) in cases {
        var state = try acceptedState()
        if let connection { state.transitionConnection(to: connection) }
        let snapshot = state
        #expect(state.reduce(input, clock: clock) == .rejected(reason))
        #expect(state == snapshot)
    }
}

@Test func mismatchAndDisconnectedPacketsDoNotReadClockOrPoisonReconnect() throws {
    var state = try acceptedState()
    let spy = SpyClock(99)
    let snapshot = state
    #expect(state.reduce(event(sessionId: "other", sequence: 2), clock: spy) == .rejected(.sessionMismatch))
    #expect(spy.callCount == 0)
    #expect(state == snapshot)
    state.transitionConnection(to: .disconnected)
    let disconnectedSnapshot = state
    #expect(state.reduce(event(sequence: 2), clock: spy) == .rejected(.connectionUnavailable))
    #expect(spy.callCount == 0)
    #expect(state == disconnectedSnapshot)
    state.transitionConnection(to: .connected)
    #expect(state.reduce(event(sequence: 2), clock: FakeClock(101)) == .accepted(.init(code: .ready)))
}

@Test func sequenceIsSessionGlobalWhilePerShotWatermarksAreRetained() throws {
    var state = try connectedState()
    #expect(state.reduce(event(sequence: 9), clock: FakeClock(100)) == .accepted(.init(code: .ready)))
    state.setCurrentShot(.back)
    #expect(state.latestGuidance == nil)
    #expect(state.reduce(event(sequence: 1, shot: .back), clock: FakeClock(101)) == .rejected(.sequenceNotNew))
    #expect(state.reduce(event(sequence: 10, shot: .back), clock: FakeClock(102)) == .accepted(.init(code: .ready)))
    state.setCurrentShot(.front)
    #expect(state.reduce(event(sequence: 9), clock: FakeClock(103)) == .rejected(.sequenceNotNew))
    #expect(state.lastAcceptedSequence == 10)
    #expect(state.lastAcceptedSequenceByShot == [.front: 9, .back: 10])
}

@Test func expiredHighSequenceDoesNotPoisonOrderingOrPresentation() throws {
    var state = try connectedState()
    #expect(state.reduce(event(sequence: 9, code: .moveCloser), clock: FakeClock(100)) == .accepted(.init(code: .moveCloser)))
    state.setCurrentShot(.back)
    #expect(state.reduce(event(sequence: 10, shot: .back, code: .ready), clock: FakeClock(101)) == .accepted(.init(code: .ready)))
    let snapshot = state
    #expect(state.reduce(event(sequence: 100, shot: .back, code: .moveFarther, expiresAt: 102), clock: FakeClock(102)) == .rejected(.expired))
    #expect(state == snapshot)
    #expect(state.reduce(event(sequence: 11, shot: .back, code: .holdSteady), clock: FakeClock(103)) == .accepted(.init(code: .holdSteady)))
    #expect(state.lastAcceptedSequence == 11)
    #expect(state.lastAcceptedSequenceByShot == [.front: 9, .back: 11])
    #expect(state.latestGuidance == .init(code: .holdSteady))
}

@Test func reconnectDisconnectAndNewSessionPreserveThenResetOnlyWhenValid() throws {
    var state = try acceptedState()
    state.transitionConnection(to: .reconnecting)
    #expect(state.reduce(event(sequence: 2), clock: FakeClock(101)) == .rejected(.connectionUnavailable))
    state.transitionConnection(to: .disconnected)
    #expect(state.reduce(event(sequence: 2), clock: FakeClock(102)) == .rejected(.connectionUnavailable))
    #expect(state.currentSessionId == "session")
    #expect(state.currentShot == .front)
    #expect(state.lastAcceptedSequence == 1)
    #expect(state.lastAcceptedSequenceByShot == [.front: 1])
    state.transitionConnection(to: .connected)
    #expect(state.reduce(event(sequence: 1), clock: FakeClock(103)) == .rejected(.sequenceNotNew))
    #expect(state.reduce(event(sequence: 2), clock: FakeClock(104)) == .accepted(.init(code: .ready)))
    let snapshot = state
    #expect(throws: GuidanceFilterStateError.sessionAlreadyCurrent) { try state.startNewSession(id: "session", currentShot: .front) }
    #expect(state == snapshot)
    try state.startNewSession(id: "next", currentShot: .front)
    #expect(state.lastAcceptedSequence == nil)
    #expect(state.lastAcceptedSequenceByShot.isEmpty && state.lastAcceptedClockMilliseconds == nil)
    #expect(state.latestGuidance == nil)
    state.transitionConnection(to: .connected)
    #expect(state.reduce(event(sessionId: "next", sequence: 1), clock: FakeClock(1)) == .accepted(.init(code: .ready)))
}

@Test func blankSessionAndClockReversalAreSafeAndDoNotLockOutFutureEvents() throws {
    #expect(throws: GuidanceFilterStateError.invalidSessionIdentifier) { try GuidanceFilterState(sessionId: " \n", currentShot: .front) }
    var state = try acceptedState()
    let snapshot = state
    #expect(throws: GuidanceFilterStateError.invalidSessionIdentifier) { try state.startNewSession(id: "\t", currentShot: .back) }
    #expect(state == snapshot)
    #expect(state.reduce(event(sequence: 2), clock: FakeClock(99)) == .rejected(.clockMovedBackward))
    #expect(state.reduce(event(sequence: 2), clock: FakeClock(101)) == .accepted(.init(code: .ready)))
}

@Test(arguments: GuidanceConnectionState.allCases)
func connectionTransitionsCannotMutateCaptureWorkflow(_ connection: GuidanceConnectionState) throws {
    let workflow = try completedWorkflow()
    let snapshot = workflow
    var guidance = try connectedState()
    guidance.transitionConnection(to: connection)
    #expect(workflow == snapshot)
    #expect(workflow.acceptedSlots == Set(Shot.allCases))
    #expect(workflow.measurementApproval == .approvedCV)
    #expect(workflow.phase == .readyToEdit)
}

@Test(arguments: GuidanceConnectionState.allCases)
func connectionTransitionsCannotMutateRetakeProgress(_ connection: GuidanceConnectionState) throws {
    var workflow = try completedWorkflow()
    try workflow.transition(.retake(.front))
    let snapshot = workflow
    var guidance = try connectedState()
    guidance.transitionConnection(to: connection)
    #expect(workflow == snapshot)
    #expect(workflow.retainedSlots == Set(Shot.allCases))
    #expect(workflow.acceptedSlots == Set(Shot.allCases).subtracting([.front]))
    #expect(workflow.measurementApproval == .approvedCV)
    #expect(workflow.phase == .capture(.front))
}

@Test func acceptedGuidanceHasOnlyFiniteDisplayInputAndNoNavigationPayload() throws {
    var state = try connectedState()
    #expect(state.reduce(event(code: .moveCloser), clock: FakeClock(100)) == .accepted(.init(code: .moveCloser)))
}

private struct FakeClock: GuidanceEpochMillisecondsClock { let value: Int64; init(_ value: Int64) { self.value = value }; func nowEpochMilliseconds() -> Int64 { value } }
/// `NSLock` synchronizes the mutable counter required by this Sendable test spy.
private final class SpyClock: GuidanceEpochMillisecondsClock, @unchecked Sendable {
    private let lock = NSLock()
    private let value: Int64
    private var storedCallCount = 0

    init(_ value: Int64) {
        self.value = value
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCallCount
    }

    func nowEpochMilliseconds() -> Int64 {
        lock.lock()
        storedCallCount += 1
        lock.unlock()
        return value
    }
}
private func connectedState() throws -> GuidanceFilterState { try GuidanceFilterState(sessionId: "session", currentShot: .front, connection: .connected) }
private func acceptedState() throws -> GuidanceFilterState { var state = try connectedState(); #expect(state.reduce(event(sequence: 1), clock: FakeClock(100)) == .accepted(.init(code: .ready))); return state }
private func event(sessionId: String = "session", sequence: Int64 = 1, shot: Shot = .front, code: GuidanceCode = .ready, expiresAt: Int64 = 200) -> GuidanceEvent { try! GuidanceEvent(sessionId: sessionId, sequence: sequence, shot: shot, code: code, message: "unused", confidence: 0.5, observedAt: 0, expiresAt: expiresAt) }
private func completedWorkflow() throws -> CaptureWorkflowState { var state = CaptureWorkflowState(); try state.transition(.captured(.front)); try state.transition(.assessmentAccepted(.front)); try state.transition(.captured(.back)); try state.transition(.assessmentAccepted(.back)); try state.transition(.captured(.tag)); try state.transition(.assessmentAccepted(.tag)); try state.transition(.startMeasurementCapture); try state.transition(.captured(.measurement)); try state.transition(.measurementValidationSucceeded); try state.transition(.approveMeasurementCV); return state }
