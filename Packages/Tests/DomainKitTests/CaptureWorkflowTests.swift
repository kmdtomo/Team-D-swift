import Testing
@testable import DomainKit

@Test func canonicalPathReachesEveryWorkflowPhase() throws {
    var state = CaptureWorkflowState()
    #expect(state.phase == .capture(.front))
    try state.transition(.captured(.front)); #expect(state.phase == .analyzingShot(.front))
    try state.transition(.assessmentAccepted(.front)); #expect(state.phase == .capture(.back))
    try state.transition(.captured(.back)); #expect(state.phase == .analyzingShot(.back))
    try state.transition(.assessmentAccepted(.back)); #expect(state.phase == .capture(.tag))
    try state.transition(.captured(.tag)); #expect(state.phase == .analyzingShot(.tag))
    try state.transition(.assessmentAccepted(.tag)); #expect(state.phase == .measurementPrep)
    try state.transition(.startMeasurementCapture); #expect(state.phase == .capture(.measurement))
    try state.transition(.captured(.measurement)); #expect(state.phase == .validatingMeasurement)
    try state.transition(.measurementValidationSucceeded); #expect(state.phase == .measurementReview)
    try state.transition(.approveMeasurementCV); #expect(state.phase == .readyToEdit)
    try state.transition(.beginEdit); #expect(state.phase == .processingEdit)
    try state.transition(.editSucceeded); #expect(state.phase == .preview)
    try state.transition(.beginApproval); #expect(state.phase == .approval)
    try state.transition(.confirmApproval); #expect(state.phase == .done)
}

@Test func everyContextualPhaseEventCombinationRejectsUnlistedEvents() throws {
    for fixture in try phaseFixtures() {
        for event in WorkflowEvent.representativeCases {
            var state = fixture.state
            if fixture.acceptedEvents.contains(event) {
                #expect(throws: Never.self) { try state.transition(event) }
            } else {
                #expect(throws: TransitionError.self) { try state.transition(event) }
            }
        }
    }
}

@Test func stateConstructionOnlyExposesInitialStateAndValidatesMembership() throws {
    #expect(CaptureWorkflowState().phase == .capture(.front))
    #expect(throws: TransitionError.invalidState) {
        try CaptureWorkflowState(phase: .capture(.front), retainedSlots: [], acceptedSlots: [.front])
    }
}

@Test func fixedOrderingAndPrerequisitesRejectInvalidProgress() throws {
    var initial = CaptureWorkflowState()
    try expectInvalid(&initial, .captured(.back))
    try expectInvalid(&initial, .assessmentAccepted(.back))

    var captureBack = try state(phase: .capture(.back))
    try expectInvalid(&captureBack, .captured(.back))
    var analyzeTag = try state(phase: .analyzingShot(.tag), retained: [.front], accepted: [.front])
    try expectInvalid(&analyzeTag, .assessmentAccepted(.tag))
    var prep = try state(phase: .measurementPrep)
    try expectInvalid(&prep, .startMeasurementCapture)
    var validating = try state(phase: .validatingMeasurement)
    try expectInvalid(&validating, .measurementValidationSucceeded)
    try expectInvalid(&validating, .measurementAcceptedForManualInput)
    try expectInvalid(&validating, .measurementRejected)
}

@Test func assessableRetakesKeepMeasurementApprovalAndUnrelatedProgress() throws {
    for shot in [Shot.front, .back, .tag] {
        var state = try stateReadyToEdit(approval: .approvedCV)
        try state.transition(.retake(shot))
        #expect(state.phase == .capture(shot))
        #expect(state.retainedSlots == Set(Shot.allCases))
        #expect(state.acceptedSlots == Set(Shot.allCases).subtracting([shot]))
        #expect(state.measurementApproval == .approvedCV)
        try state.transition(.captured(shot))
        try state.transition(.assessmentAccepted(try assessable(shot)))
        #expect(state.phase == .readyToEdit)
        #expect(state.isEditUnlocked)
        #expect(state.acceptedSlots == Set(Shot.allCases))
    }
}

@Test func measurementRetakeAndChangesResetApprovalUntilRevalidated() throws {
    var state = try stateReadyToEdit(approval: .approvedCV)
    try state.transition(.retake(.measurement))
    #expect(state.phase == .measurementPrep)
    #expect(state.measurementApproval == .unapproved)
    #expect(!state.isEditUnlocked)
    try state.transition(.startMeasurementCapture)
    try state.transition(.captured(.measurement))
    try state.transition(.measurementValidationSucceeded)
    try state.transition(.measurementChanged)
    #expect(state.measurementApproval == .unapproved)
    #expect(state.phase == .measurementReview)
    try expectError(&state, .beginEdit, expected: .invalidEvent(phase: .measurementReview, event: .beginEdit))
    try state.transition(.approveMeasurementManual)
    #expect(state.isEditUnlocked)
}

@Test func manualInputPathRequiresAValidatedFourthImage() throws {
    var manual = try stateThroughTagAcceptance()
    try manual.transition(.startMeasurementCapture)
    try manual.transition(.captured(.measurement))
    try manual.transition(.measurementAcceptedForManualInput)
    #expect(manual.phase == .measurementReview)
    #expect(manual.acceptedSlots == Set(Shot.allCases))
    try manual.transition(.approveMeasurementManual)
    #expect(manual.phase == .readyToEdit)
    #expect(manual.measurementApproval == .approvedManual)

    var rejected = try stateThroughTagAcceptance()
    try rejected.transition(.startMeasurementCapture)
    try rejected.transition(.captured(.measurement))
    try rejected.transition(.measurementRejected)
    #expect(rejected.phase == .measurementPrep)
    #expect(!rejected.acceptedSlots.contains(.measurement))

    var missingMeasurement = try state(phase: .measurementReview, retained: [.front, .back, .tag], accepted: [.front, .back, .tag])
    try expectError(&missingMeasurement, .approveMeasurementManual, expected: .editGateClosed)
}

@Test func bothExplicitApprovalPathsOpenTheEditGateAndEditFailurePreservesProgress() throws {
    for approval in [MeasurementApproval.approvedCV, .approvedManual] {
        var state = try stateReadyToEdit(approval: approval)
        #expect(state.isEditUnlocked)
        try state.transition(.beginEdit)
        try state.transition(.editFailed)
        #expect(state.phase == .readyToEdit)
        #expect(state.isEditUnlocked)
    }
}

@Test func assessmentAcceptanceHasNoAIActionOrConnectionInput() throws {
    var state = CaptureWorkflowState()
    try state.transition(.captured(.front))
    try state.transition(.assessmentAccepted(.front))
    #expect(state.phase == .capture(.back))
}

private struct PhaseFixture {
    let state: CaptureWorkflowState
    let acceptedEvents: Set<WorkflowEvent>
}

private func phaseFixtures() throws -> [PhaseFixture] {
    [
        .init(state: CaptureWorkflowState(), acceptedEvents: [.captured(.front)]),
        .init(state: try state(phase: .capture(.back), retained: [.front], accepted: [.front]), acceptedEvents: [.captured(.back), .retake(.front)]),
        .init(state: try state(phase: .capture(.tag), retained: [.front, .back], accepted: [.front, .back]), acceptedEvents: [.captured(.tag), .retake(.front), .retake(.back)]),
        .init(state: try state(phase: .capture(.measurement), retained: [.front, .back, .tag], accepted: [.front, .back, .tag]), acceptedEvents: [.captured(.measurement), .retake(.front), .retake(.back), .retake(.tag)]),
        .init(state: try state(phase: .analyzingShot(.front)), acceptedEvents: [.assessmentAccepted(.front), .assessmentRejected]),
        .init(state: try state(phase: .analyzingShot(.back), retained: [.front], accepted: [.front]), acceptedEvents: [.assessmentAccepted(.back), .assessmentRejected, .retake(.front)]),
        .init(state: try state(phase: .analyzingShot(.tag), retained: [.front, .back], accepted: [.front, .back]), acceptedEvents: [.assessmentAccepted(.tag), .assessmentRejected, .retake(.front), .retake(.back)]),
        .init(state: try state(phase: .measurementPrep, retained: [.front, .back, .tag], accepted: [.front, .back, .tag]), acceptedEvents: [.startMeasurementCapture, .retake(.front), .retake(.back), .retake(.tag)]),
        .init(state: try state(phase: .validatingMeasurement, retained: [.front, .back, .tag], accepted: [.front, .back, .tag]), acceptedEvents: [.measurementValidationSucceeded, .measurementAcceptedForManualInput, .measurementRejected, .retake(.front), .retake(.back), .retake(.tag)]),
        .init(state: try state(phase: .measurementReview, retained: Set(Shot.allCases), accepted: Set(Shot.allCases)), acceptedEvents: [.measurementChanged, .approveMeasurementCV, .approveMeasurementManual, .retake(.front), .retake(.back), .retake(.tag), .retake(.measurement)]),
        .init(state: try state(phase: .readyToEdit, retained: Set(Shot.allCases), accepted: Set(Shot.allCases), approval: .approvedCV), acceptedEvents: [.beginEdit, .retake(.front), .retake(.back), .retake(.tag), .retake(.measurement)]),
        .init(state: try state(phase: .processingEdit, retained: Set(Shot.allCases), accepted: Set(Shot.allCases), approval: .approvedCV), acceptedEvents: [.editSucceeded, .editFailed, .retake(.front), .retake(.back), .retake(.tag), .retake(.measurement)]),
        .init(state: try state(phase: .preview, retained: Set(Shot.allCases), accepted: Set(Shot.allCases), approval: .approvedCV), acceptedEvents: [.beginApproval, .retake(.front), .retake(.back), .retake(.tag), .retake(.measurement)]),
        .init(state: try state(phase: .approval, retained: Set(Shot.allCases), accepted: Set(Shot.allCases), approval: .approvedCV), acceptedEvents: [.confirmApproval, .retake(.front), .retake(.back), .retake(.tag), .retake(.measurement)]),
        .init(state: try state(phase: .done, retained: Set(Shot.allCases), accepted: Set(Shot.allCases), approval: .approvedCV), acceptedEvents: []),
    ]
}

private func state(phase: CapturePhase, retained: Set<Shot> = [], accepted: Set<Shot> = [], approval: MeasurementApproval = .unapproved) throws -> CaptureWorkflowState {
    try CaptureWorkflowState(phase: phase, retainedSlots: retained, acceptedSlots: accepted, measurementApproval: approval)
}

private func stateThroughTagAcceptance() throws -> CaptureWorkflowState {
    var state = CaptureWorkflowState()
    for event in [WorkflowEvent.captured(.front), .assessmentAccepted(.front), .captured(.back), .assessmentAccepted(.back), .captured(.tag), .assessmentAccepted(.tag)] {
        try state.transition(event)
    }
    return state
}

private func stateReadyToEdit(approval: MeasurementApproval) throws -> CaptureWorkflowState {
    var state = try stateThroughTagAcceptance()
    try state.transition(.startMeasurementCapture)
    try state.transition(.captured(.measurement))
    try state.transition(.measurementValidationSucceeded)
    switch approval {
    case .approvedCV: try state.transition(.approveMeasurementCV)
    case .approvedManual: try state.transition(.approveMeasurementManual)
    case .unapproved: break
    }
    return state
}

private func assessable(_ shot: Shot) throws -> AssessableShot {
    guard let shot = AssessableShot(rawValue: shot.rawValue) else { throw TransitionError.invalidState }
    return shot
}

private func expectInvalid(_ state: inout CaptureWorkflowState, _ event: WorkflowEvent) throws {
    try expectError(&state, event, expected: .invalidEvent(phase: state.phase, event: event))
}

private func expectError(_ state: inout CaptureWorkflowState, _ event: WorkflowEvent, expected: TransitionError) throws {
    do {
        try state.transition(event)
        Issue.record("Expected \(expected) for \(event)")
    } catch let error as TransitionError {
        #expect(error == expected)
    }
}

private extension WorkflowEvent {
    static let representativeCases: [WorkflowEvent] = [
        .captured(.front), .captured(.back), .captured(.tag), .captured(.measurement),
        .assessmentAccepted(.front), .assessmentAccepted(.back), .assessmentAccepted(.tag),
        .assessmentRejected, .startMeasurementCapture, .measurementValidationSucceeded,
        .measurementAcceptedForManualInput, .measurementRejected, .measurementChanged,
        .approveMeasurementCV, .approveMeasurementManual, .retake(.front), .retake(.back),
        .retake(.tag), .retake(.measurement), .beginEdit, .editSucceeded, .editFailed,
        .beginApproval, .confirmApproval,
    ]
}
