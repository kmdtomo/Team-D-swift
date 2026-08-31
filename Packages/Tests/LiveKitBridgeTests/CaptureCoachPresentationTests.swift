import ContractKit
import DomainKit
import LiveKitBridge
import Testing

struct CaptureCoachPresentationTests {
    @Test(arguments: GuidanceCode.allCases)
    func everyGuidanceCodeHasFiniteAppOwnedHandling(_ code: GuidanceCode) {
        let instruction = CaptureCoachPresentation.select(agent: code, local: nil)
        if code == .agentUnavailable { #expect(instruction == nil) }
        else { #expect(instruction != nil) }
    }

    @Test(arguments: LocalQualityHint.allCases)
    func everyLocalHintHasFiniteAppOwnedHandling(_ hint: LocalQualityHint) {
        let instruction = CaptureCoachPresentation.select(agent: nil, local: hint)
        if hint == .analyzerUnavailable { #expect(instruction == nil) }
        else { #expect(instruction != nil) }
    }

    @Test func explicitPriorityWinsAcrossAgentAndLocalInputs() {
        #expect(CaptureCoachPresentation.select(agent: .wrongSide, local: .tooDark) == .wrongSide)
        #expect(CaptureCoachPresentation.select(agent: .showFullGarment, local: .tooBlurry) == .showFullGarment)
        #expect(CaptureCoachPresentation.select(agent: .cameraOverhead, local: .tooBright) == .cameraOverhead)
        #expect(CaptureCoachPresentation.select(agent: .ready, local: .holdSteady) == .holdSteady)
    }

    @Test func enterClearDuplicateAndReadyTimingUseInjectedClock() throws {
        let configuration = try CaptureCoachPresentationConfiguration(enterMilliseconds: 100, clearMilliseconds: 200, readyEnterMilliseconds: 1)
        var presentation = CaptureCoachPresentation(configuration: configuration)
        let input = fixture(local: .ready)
        #expect(try presentation.reduce(input, clock: Clock(0)).instruction == nil)
        #expect(try presentation.reduce(input, clock: Clock(599)).instruction == nil)
        let ready = try presentation.reduce(input, clock: Clock(600))
        #expect(ready.instruction == .ready)
        let announcement = ready.announcementID
        #expect(try presentation.reduce(input, clock: Clock(900)).announcementID == announcement)
        let empty = fixture(local: nil)
        #expect(try presentation.reduce(empty, clock: Clock(901)).instruction == .ready)
        #expect(try presentation.reduce(empty, clock: Clock(1_100)).instruction == .ready)
        #expect(try presentation.reduce(empty, clock: Clock(1_101)).instruction == nil)
    }

    @Test func nonReadyAndDisconnectedStatesKeepManualShutterAvailable() throws {
        var presentation = CaptureCoachPresentation(configuration: try .init(enterMilliseconds: 0, clearMilliseconds: 0))
        let state = try presentation.reduce(fixture(agent: .wrongSide, connection: .disconnected), clock: Clock(0))
        #expect(state.instruction == .wrongSide)
        #expect(state.isShutterEnabled)
        #expect(state.connectionText.contains("続けられます"))
        let busy = try presentation.reduce(fixture(agent: .wrongSide, inFlight: true), clock: Clock(1))
        #expect(!busy.isShutterEnabled && busy.isBusy)
    }

    @Test(arguments: GuidanceConnectionState.allCases)
    func connectionMatrixDoesNotChangeShotProgressOrShutter(_ connection: GuidanceConnectionState) throws {
        var presentation = CaptureCoachPresentation(configuration: try .init(enterMilliseconds: 0, clearMilliseconds: 0))
        let state = try presentation.reduce(fixture(connection: connection), clock: Clock(0))
        #expect(state.progressText == "3/4")
        #expect(state.completedProgressText == "完了 2/4")
        #expect(state.isShutterEnabled)
        #expect(!state.connectionText.isEmpty)
    }

    @Test(arguments: Shot.allCases)
    func viewStateSnapshotsKeepTheFixedShotSequence(_ shot: Shot) throws {
        var presentation = CaptureCoachPresentation(configuration: try .init(enterMilliseconds: 0, clearMilliseconds: 0))
        let input = CaptureCoachInput(
            shot: shot,
            acceptedShots: Set(Shot.allCases.prefix(1)),
            agentGuidance: nil,
            localQualityHint: .holdSteady,
            connection: .connected,
            isCameraTechnicallyAvailable: true,
            isCaptureInFlight: false,
            isRetake: true
        )
        let state = try presentation.reduce(input, clock: Clock(0))
        #expect(state.progressText == "\((Shot.allCases.firstIndex(of: shot) ?? 0) + 1)/4")
        #expect(state.completedProgressText == "完了 1/4")
        #expect(state.isRetake)
        #expect(state.instruction == .holdSteady)
    }

    @Test func backwardsClockIsRejectedWithoutChangingThePresentation() throws {
        var presentation = CaptureCoachPresentation()
        _ = try presentation.reduce(fixture(local: .holdSteady), clock: Clock(10))
        #expect(throws: CaptureCoachPresentationError.clockMovedBackward) {
            try presentation.reduce(fixture(local: .holdSteady), clock: Clock(9))
        }
    }

    private func fixture(
        agent: GuidanceCode? = nil,
        local: LocalQualityHint? = nil,
        connection: GuidanceConnectionState = .connected,
        inFlight: Bool = false
    ) -> CaptureCoachInput {
        .init(shot: .tag, acceptedShots: [.front, .back], agentGuidance: agent.map { GuidanceDisplayInput(code: $0) }, localQualityHint: local, connection: connection, isCameraTechnicallyAvailable: true, isCaptureInFlight: inFlight)
    }
}

private struct Clock: CaptureCoachPresentationClock {
    let value: Int64
    init(_ value: Int64) { self.value = value }
    func nowMilliseconds() -> Int64 { value }
}
