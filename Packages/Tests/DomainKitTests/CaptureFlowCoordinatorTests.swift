import Testing
@testable import DomainKit

@Test func acceptedFrontBackTagAdvanceOnlyToMeasurementPreparation() throws {
    var coordinator = CaptureFlowCoordinator()

    for (shot, expectedPhase) in [
        (Shot.front, CapturePhase.capture(.back)),
        (.back, .capture(.tag)),
        (.tag, .measurementPrep),
    ] {
        let assessableShot = try #require(AssessableShot(rawValue: shot.rawValue))
        let operation = try coordinator.beginCapture(for: shot)
        try coordinator.originalStored(for: operation)
        let resolution = try coordinator.resolveAssessment(
            acceptedEvidence(for: assessableShot),
            for: operation
        )
        #expect(resolution == .accepted(assessableShot))
        #expect(coordinator.snapshot.workflow.phase == expectedPhase)
    }

    #expect(coordinator.snapshot.currentShot == .measurement)
    #expect(coordinator.snapshot.workflow.acceptedSlots == [.front, .back, .tag])
    #expect(!coordinator.snapshot.workflow.isEditUnlocked)
}

@Test func rejectedAssessmentStaysOnShotAndOffersOnlyRetake() throws {
    var coordinator = CaptureFlowCoordinator()
    let operation = try coordinator.beginCapture(for: .front)
    try coordinator.originalStored(for: operation)

    let resolution = try coordinator.resolveAssessment(
        .init(
            requestedShot: .front,
            shotType: .front,
            quality: .retry,
            issues: [.tooDark],
            missingShots: [.front],
            advisoryNextAction: .requestNext
        ),
        for: operation
    )

    #expect(resolution == .rejected(.front))
    #expect(coordinator.snapshot.workflow.phase == .capture(.front))
    #expect(coordinator.snapshot.workflow.acceptedSlots.isEmpty)
    #expect(coordinator.snapshot.recovery == .retake(.front))
}

@Test func providerFailureRetriesTheSameAssessmentWithoutAcceptingTheSlot() throws {
    var coordinator = CaptureFlowCoordinator()
    let failed = try coordinator.beginCapture(for: .front)
    try coordinator.originalStored(for: failed)
    #expect(try coordinator.assessmentFailed(for: failed))
    #expect(coordinator.snapshot.recovery == .retryAssessment(.front))
    #expect(coordinator.snapshot.workflow.phase == .capture(.front))

    let retry = try coordinator.beginAssessmentRetry(for: .front)
    #expect(retry != failed)
    #expect(coordinator.snapshot.workflow.phase == .analyzingShot(.front))
    _ = try coordinator.resolveAssessment(acceptedEvidence(for: .front), for: retry)
    #expect(coordinator.snapshot.workflow.phase == .capture(.back))
    #expect(coordinator.snapshot.workflow.acceptedSlots == [.front])
}

@Test func rejectionPreservesPreviouslyAcceptedSlots() throws {
    var coordinator = CaptureFlowCoordinator()
    let front = try coordinator.beginCapture(for: .front)
    try coordinator.originalStored(for: front)
    _ = try coordinator.resolveAssessment(acceptedEvidence(for: .front), for: front)

    let back = try coordinator.beginCapture(for: .back)
    try coordinator.originalStored(for: back)
    _ = try coordinator.resolveAssessment(
        .init(
            requestedShot: .back,
            shotType: .unknown,
            quality: .retry,
            issues: [.wrongShot],
            missingShots: [.back, .tag],
            advisoryNextAction: .complete
        ),
        for: back
    )

    #expect(coordinator.snapshot.workflow.phase == .capture(.back))
    #expect(coordinator.snapshot.workflow.acceptedSlots == [.front])
    #expect(coordinator.snapshot.workflow.retainedSlots == [.front])
}

@Test func staleAssessmentCannotMutateANewerAttempt() throws {
    var coordinator = CaptureFlowCoordinator()
    let old = try coordinator.beginCapture(for: .front)
    try coordinator.originalStored(for: old)
    try coordinator.prepareRetake(of: .front)
    let current = try coordinator.beginCapture(for: .front)
    try coordinator.originalStored(for: current)

    let stale = try coordinator.resolveAssessment(acceptedEvidence(for: .front), for: old)

    #expect(stale == .discardedAsStale)
    #expect(coordinator.snapshot.activity == .assessing(current))
    #expect(coordinator.snapshot.workflow.phase == .analyzingShot(.front))
    #expect(coordinator.snapshot.workflow.acceptedSlots.isEmpty)
}

@Test func retakeRemovesOnlyItsAcceptanceAndRetainsOtherSlots() throws {
    var coordinator = try coordinatorThroughTag()
    try coordinator.prepareRetake(of: .back)

    #expect(coordinator.snapshot.workflow.phase == .capture(.back))
    #expect(coordinator.snapshot.workflow.retainedSlots == [.front, .back, .tag])
    #expect(coordinator.snapshot.workflow.acceptedSlots == [.front, .tag])

    let replacement = try coordinator.beginCapture(for: .back)
    try coordinator.originalStored(for: replacement)
    _ = try coordinator.resolveAssessment(acceptedEvidence(for: .back), for: replacement)
    #expect(coordinator.snapshot.workflow.phase == .measurementPrep)
    #expect(coordinator.snapshot.workflow.acceptedSlots == [.front, .back, .tag])
}

@Test func advisoryNextActionNeverAcceptsRejectsOrNavigates() throws {
    for action in ShotNextAction.allCases {
        var coordinator = CaptureFlowCoordinator()
        let operation = try coordinator.beginCapture(for: .front)
        try coordinator.originalStored(for: operation)
        let evidence = CaptureAssessmentEvidence(
            requestedShot: .front,
            shotType: .front,
            quality: .ok,
            issues: [],
            missingShots: [],
            advisoryNextAction: action
        )

        #expect(try coordinator.resolveAssessment(evidence, for: operation) == .accepted(.front))
        #expect(coordinator.snapshot.workflow.phase == .capture(.back))
    }

    var rejected = CaptureFlowCoordinator()
    let operation = try rejected.beginCapture(for: .front)
    try rejected.originalStored(for: operation)
    let evidence = CaptureAssessmentEvidence(
        requestedShot: .front,
        shotType: .unknown,
        quality: .retry,
        issues: [.wrongShot],
        missingShots: [.front],
        advisoryNextAction: .complete
    )
    #expect(try rejected.resolveAssessment(evidence, for: operation) == .rejected(.front))
    #expect(rejected.snapshot.workflow.phase == .capture(.front))
}

private func acceptedEvidence(for shot: AssessableShot) -> CaptureAssessmentEvidence {
    let futureMissingShots: Set<AssessableShot> = switch shot {
    case .front: [.back, .tag]
    case .back: [.tag]
    case .tag: []
    }
    return .init(
        requestedShot: shot,
        shotType: ShotType(rawValue: shot.rawValue)!,
        quality: .ok,
        issues: [],
        missingShots: futureMissingShots,
        advisoryNextAction: .retake
    )
}

private func coordinatorThroughTag() throws -> CaptureFlowCoordinator {
    var coordinator = CaptureFlowCoordinator()
    for shot in [Shot.front, .back, .tag] {
        let assessableShot = try #require(AssessableShot(rawValue: shot.rawValue))
        let operation = try coordinator.beginCapture(for: shot)
        try coordinator.originalStored(for: operation)
        _ = try coordinator.resolveAssessment(
            acceptedEvidence(for: assessableShot),
            for: operation
        )
    }
    return coordinator
}
