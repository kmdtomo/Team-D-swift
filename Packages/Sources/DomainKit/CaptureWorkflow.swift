/// The app-owned workflow deliberately contains no image, identifier, assessment,
/// or measurement-draft payloads. T04-02 owns those session-scoped values.
public enum CapturePhase: Equatable, Sendable {
    case capture(Shot)
    case analyzingShot(AssessableShot)
    case measurementPrep
    case validatingMeasurement
    case measurementReview
    case readyToEdit
    case processingEdit
    case preview
    case approval
    case done
}

public enum MeasurementApproval: Equatable, Sendable {
    case unapproved
    case approvedCV
    case approvedManual
}

public enum WorkflowEvent: Hashable, Sendable {
    case captured(Shot)
    case assessmentAccepted(AssessableShot)
    case assessmentRejected
    case startMeasurementCapture
    case measurementValidationSucceeded
    case measurementAcceptedForManualInput
    case measurementRejected
    case measurementChanged
    case approveMeasurementCV
    case approveMeasurementManual
    case retake(Shot)
    case beginEdit
    case editSucceeded
    case editFailed
    case beginApproval
    case confirmApproval
}

public enum TransitionError: Error, Equatable, Sendable {
    case invalidEvent(phase: CapturePhase, event: WorkflowEvent)
    case editGateClosed
    case invalidState
}

public struct CaptureWorkflowState: Equatable, Sendable {
    public private(set) var phase: CapturePhase
    /// Slots whose accepted artifacts are retained by the session store in T04-02.
    public private(set) var retainedSlots: Set<Shot>
    /// Only these app-owned acceptance markers can advance the capture workflow.
    public private(set) var acceptedSlots: Set<Shot>
    public private(set) var measurementApproval: MeasurementApproval

    public init() {
        phase = .capture(.front)
        retainedSlots = []
        acceptedSlots = []
        measurementApproval = .unapproved
    }

    init(
        phase: CapturePhase,
        retainedSlots: Set<Shot>,
        acceptedSlots: Set<Shot>,
        measurementApproval: MeasurementApproval = .unapproved
    ) throws {
        guard acceptedSlots.isSubset(of: retainedSlots) else {
            throw TransitionError.invalidState
        }
        self.phase = phase
        self.retainedSlots = retainedSlots
        self.acceptedSlots = acceptedSlots
        self.measurementApproval = measurementApproval
    }

    public var isEditUnlocked: Bool {
        acceptedSlots == Set(Shot.allCases)
            && measurementApproval != .unapproved
    }

    public mutating func transition(_ event: WorkflowEvent) throws {
        switch event {
        case .retake(let shot):
            try beginRetake(shot)

        case .captured(let shot):
            guard case .capture(let expectedShot) = phase, expectedShot == shot else {
                throw invalid(event)
            }
            guard canCapture(shot) else { throw invalid(event) }
            phase = shot.assessableShot.map(CapturePhase.analyzingShot) ?? .validatingMeasurement

        case .assessmentAccepted(let shot):
            guard phase == .analyzingShot(shot) else { throw invalid(event) }
            guard canAccept(shot) else { throw invalid(event) }
            let acceptedShot = shot.shot
            acceptedSlots.insert(acceptedShot)
            retainedSlots.insert(acceptedShot)
            phase = nextCapturePhase(afterAccepting: acceptedShot)

        case .assessmentRejected:
            guard case .analyzingShot(let shot) = phase else { throw invalid(event) }
            phase = .capture(shot.shot)

        case .startMeasurementCapture:
            guard phase == .measurementPrep, hasAccepted([.front, .back, .tag]) else { throw invalid(event) }
            phase = .capture(.measurement)

        case .measurementValidationSucceeded:
            try acceptMeasurement(event)

        case .measurementAcceptedForManualInput:
            try acceptMeasurement(event)

        case .measurementRejected:
            guard phase == .validatingMeasurement, hasAccepted([.front, .back, .tag]) else { throw invalid(event) }
            phase = .measurementPrep

        case .measurementChanged:
            guard phase == .measurementReview else { throw invalid(event) }
            measurementApproval = .unapproved

        case .approveMeasurementCV:
            try approveMeasurement(.approvedCV, event: event)

        case .approveMeasurementManual:
            try approveMeasurement(.approvedManual, event: event)

        case .beginEdit:
            guard phase == .readyToEdit else { throw invalid(event) }
            guard isEditUnlocked else { throw TransitionError.editGateClosed }
            phase = .processingEdit

        case .editSucceeded:
            guard phase == .processingEdit else { throw invalid(event) }
            phase = .preview

        case .editFailed:
            guard phase == .processingEdit else { throw invalid(event) }
            guard isEditUnlocked else { throw TransitionError.editGateClosed }
            phase = .readyToEdit

        case .beginApproval:
            guard phase == .preview else { throw invalid(event) }
            phase = .approval

        case .confirmApproval:
            guard phase == .approval else { throw invalid(event) }
            phase = .done
        }
    }

    private mutating func beginRetake(_ shot: Shot) throws {
        guard phase != .done, retainedSlots.contains(shot) else { throw invalid(.retake(shot)) }
        acceptedSlots.remove(shot)
        if shot == .measurement {
            measurementApproval = .unapproved
        }
        phase = shot == .measurement ? .measurementPrep : .capture(shot)
    }

    private mutating func approveMeasurement(_ approval: MeasurementApproval, event: WorkflowEvent) throws {
        guard phase == .measurementReview else { throw invalid(event) }
        guard acceptedSlots == Set(Shot.allCases) else { throw TransitionError.editGateClosed }
        measurementApproval = approval
        phase = .readyToEdit
    }

    private mutating func acceptMeasurement(_ event: WorkflowEvent) throws {
        guard phase == .validatingMeasurement, hasAccepted([.front, .back, .tag]) else { throw invalid(event) }
        acceptedSlots.insert(.measurement)
        retainedSlots.insert(.measurement)
        measurementApproval = .unapproved
        phase = .measurementReview
    }

    private func nextCapturePhase(afterAccepting _: Shot) -> CapturePhase {
        if acceptedSlots == Set(Shot.allCases) {
            return measurementApproval == .unapproved ? .measurementReview : .readyToEdit
        }
        if hasAccepted([.front, .back, .tag]) {
            return .measurementPrep
        }
        if !acceptedSlots.contains(.front) { return .capture(.front) }
        if !acceptedSlots.contains(.back) { return .capture(.back) }
        return .capture(.tag)
    }

    private func canCapture(_ shot: Shot) -> Bool {
        switch shot {
        case .front: true
        case .back: hasAccepted([.front])
        case .tag: hasAccepted([.front, .back])
        case .measurement: hasAccepted([.front, .back, .tag])
        }
    }

    private func canAccept(_ shot: AssessableShot) -> Bool {
        switch shot {
        case .front: true
        case .back: hasAccepted([.front])
        case .tag: hasAccepted([.front, .back])
        }
    }

    private func hasAccepted(_ shots: Set<Shot>) -> Bool {
        shots.isSubset(of: acceptedSlots)
    }

    private func invalid(_ event: WorkflowEvent) -> TransitionError {
        .invalidEvent(phase: phase, event: event)
    }
}

private extension Shot {
    var assessableShot: AssessableShot? {
        AssessableShot(rawValue: rawValue)
    }
}

private extension AssessableShot {
    var shot: Shot {
        switch self {
        case .front: .front
        case .back: .back
        case .tag: .tag
        }
    }
}
