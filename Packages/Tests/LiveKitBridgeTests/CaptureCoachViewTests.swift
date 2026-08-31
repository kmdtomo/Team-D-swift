import DomainKit
import LiveKitBridge
import Testing

struct CaptureCoachViewTests {
    @Test(arguments: Shot.allCases)
    func everyShotHasOneAppOwnedDefaultInstruction(_ shot: Shot) {
        let surface = CaptureCoachSurfaceState(
            coach: coach(shot: shot, instruction: nil),
            isFixture: false
        )
        #expect(!surface.instructionText.isEmpty)
        #expect(!surface.instructionText.contains("confidence"))
        #expect(!surface.instructionText.contains("provider"))
    }

    @Test(arguments: CaptureCoachInstruction.allCases)
    func finiteInstructionIsTheOnlyPrimaryCopy(_ instruction: CaptureCoachInstruction) {
        let surface = CaptureCoachSurfaceState(
            coach: coach(instruction: instruction),
            isFixture: false
        )
        #expect(surface.instructionText == instruction.localizedText)
    }

    @Test func nonReadyAndDisconnectedCaptureRemainAvailable() {
        let surface = CaptureCoachSurfaceState(
            coach: coach(
                instruction: .wrongSide,
                connection: .disconnected,
                shutterEnabled: true
            ),
            isFixture: false
        )
        #expect(surface.coach.isShutterEnabled)
        #expect(surface.shutterLabel == "撮影する")
        #expect(surface.shutterAccessibilityHint.contains("READYの表示がなくても"))
        #expect(surface.coach.connectionText.contains("続けられます"))
    }

    @Test func technicalUnavailabilityAndBusyStateDisableTheShutter() {
        let unavailable = CaptureCoachSurfaceState(
            coach: coach(shutterEnabled: false),
            isFixture: false
        )
        #expect(!unavailable.coach.isShutterEnabled)

        let busy = CaptureCoachSurfaceState(
            coach: coach(shutterEnabled: false, busy: true),
            isFixture: false
        )
        #expect(busy.shutterLabel == "撮影中")
        #expect(!busy.coach.isShutterEnabled)
    }

    @Test(arguments: GuidanceConnectionState.allCases)
    func connectionStatusCannotChangeProgressGuideOrShutterSemantics(_ connection: GuidanceConnectionState) {
        let surface = CaptureCoachSurfaceState(
            coach: coach(connection: connection, shutterEnabled: true),
            isFixture: false
        )
        #expect(surface.coach.progressText == "2/4")
        #expect(surface.coach.completedProgressText == "完了 1/4")
        #expect(surface.coach.isShutterEnabled)
        #expect(!surface.coach.connectionText.isEmpty)
    }

    @Test func retryRetakeAndFixturePresentationUseStableSemanticValues() {
        let retry = CaptureCoachSurfaceState(
            coach: coach(),
            recoveryControl: .retry,
            isFixture: true
        )
        #expect(retry.isFixture)
        #expect(retry.recoveryControl.localizedLabel == "もう一度試す")
        #expect(retry.recoveryControl.accessibilityIdentifier == CaptureCoachAccessibilityID.retry)

        let retake = CaptureCoachSurfaceState(
            coach: coach(retake: true),
            recoveryControl: .retake,
            isFixture: false
        )
        #expect(retake.shutterLabel == "撮り直す")
        #expect(retake.recoveryControl.accessibilityIdentifier == CaptureCoachAccessibilityID.retake)
        #expect(CaptureCoachAccessibilityID.fixtureBadge == "fixture-mode-badge")
        #expect(CaptureCoachAccessibilityID.shutter == "capture-shutter")
    }

    private func coach(
        shot: Shot = .back,
        instruction: CaptureCoachInstruction? = .holdSteady,
        connection: GuidanceConnectionState = .connected,
        shutterEnabled: Bool = true,
        busy: Bool = false,
        retake: Bool = false
    ) -> CaptureCoachViewState {
        CaptureCoachViewState(
            input: .init(
                shot: shot,
                acceptedShots: [.front],
                connection: connection,
                isCameraTechnicallyAvailable: shutterEnabled,
                isCaptureInFlight: busy,
                isRetake: retake
            ),
            instruction: instruction,
            announcementID: 1
        )
    }
}
