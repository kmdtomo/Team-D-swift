/// A lifetime-local token for one capture/assessment attempt. Provider results
/// must present the current token before they may mutate the workflow.
public struct CaptureFlowOperation: Hashable, Sendable {
    public let sequence: UInt64
    public let shot: Shot

    init(sequence: UInt64, shot: Shot) {
        self.sequence = sequence
        self.shot = shot
    }
}

public enum CaptureFlowActivity: Equatable, Sendable {
    case idle
    case capturing(CaptureFlowOperation)
    case assessing(CaptureFlowOperation)
}

/// Exactly one recovery control is exposed for a failed attempt. Retake starts
/// a new original; retryAssessment reuses the current session original.
public enum CaptureFlowRecovery: Equatable, Sendable {
    case none
    case retryAssessment(AssessableShot)
    case retake(Shot)
}

public struct CaptureFlowSnapshot: Equatable, Sendable {
    public let workflow: CaptureWorkflowState
    public let activity: CaptureFlowActivity
    public let recovery: CaptureFlowRecovery

    public var currentShot: Shot {
        switch workflow.phase {
        case .capture(let shot): shot
        case .analyzingShot(let shot): shot.captureShot
        case .measurementPrep, .validatingMeasurement, .measurementReview:
            .measurement
        case .readyToEdit, .processingEdit, .preview, .approval, .done:
            .front
        }
    }

    public var isCaptureInFlight: Bool {
        activity != .idle
    }
}

/// Strict assessment fields are retained, but advisoryNextAction is never used
/// by the app-owned acceptance policy or workflow transition.
public struct CaptureAssessmentEvidence: Equatable, Sendable {
    public let requestedShot: AssessableShot
    public let shotType: ShotType
    public let quality: ShotQuality
    public let issues: Set<ShotIssueCode>
    public let missingShots: Set<AssessableShot>
    public let advisoryNextAction: ShotNextAction

    public init(
        requestedShot: AssessableShot,
        shotType: ShotType,
        quality: ShotQuality,
        issues: Set<ShotIssueCode>,
        missingShots: Set<AssessableShot>,
        advisoryNextAction: ShotNextAction
    ) {
        self.requestedShot = requestedShot
        self.shotType = shotType
        self.quality = quality
        self.issues = issues
        self.missingShots = missingShots
        self.advisoryNextAction = advisoryNextAction
    }
}

public enum CaptureAssessmentResolution: Equatable, Sendable {
    case accepted(AssessableShot)
    case rejected(AssessableShot)
    case discardedAsStale
}

public enum CaptureFlowCoordinatorError: Error, Equatable, Sendable {
    case invalidAction
}

/// Value-semantic app coordinator around the existing workflow reducer. It owns
/// operation identity and recovery presentation, not images or provider calls.
public struct CaptureFlowCoordinator: Equatable, Sendable {
    private var workflow: CaptureWorkflowState
    private var activity: CaptureFlowActivity
    private var recovery: CaptureFlowRecovery
    private var nextOperationSequence: UInt64

    public init(workflow: CaptureWorkflowState = CaptureWorkflowState()) {
        self.workflow = workflow
        activity = .idle
        recovery = .none
        nextOperationSequence = 0
    }

    public var snapshot: CaptureFlowSnapshot {
        .init(workflow: workflow, activity: activity, recovery: recovery)
    }

    public mutating func beginCapture(for shot: Shot) throws -> CaptureFlowOperation {
        guard activity == .idle,
              case .capture(let expectedShot) = workflow.phase,
              expectedShot == shot else {
            throw CaptureFlowCoordinatorError.invalidAction
        }
        let operation = makeOperation(for: shot)
        activity = .capturing(operation)
        recovery = .none
        return operation
    }

    /// Called only after the original has been committed to CaptureSessionStore.
    public mutating func originalStored(for operation: CaptureFlowOperation) throws {
        guard activity == .capturing(operation) else {
            throw CaptureFlowCoordinatorError.invalidAction
        }
        try workflow.transition(.captured(operation.shot))
        if operation.shot.assessableShot != nil {
            activity = .assessing(operation)
        } else {
            activity = .idle
        }
    }

    @discardableResult
    public mutating func captureFailed(for operation: CaptureFlowOperation) -> Bool {
        guard activity == .capturing(operation) else { return false }
        activity = .idle
        recovery = .retake(operation.shot)
        return true
    }

    public mutating func resolveAssessment(
        _ evidence: CaptureAssessmentEvidence,
        for operation: CaptureFlowOperation
    ) throws -> CaptureAssessmentResolution {
        guard activity == .assessing(operation),
              let operationShot = operation.shot.assessableShot else {
            return .discardedAsStale
        }

        activity = .idle
        if evidence.requestedShot == operationShot, Self.accepts(evidence) {
            try workflow.transition(.assessmentAccepted(operationShot))
            recovery = .none
            return .accepted(operationShot)
        }

        try workflow.transition(.assessmentRejected)
        recovery = .retake(operation.shot)
        return .rejected(operationShot)
    }

    @discardableResult
    public mutating func assessmentFailed(for operation: CaptureFlowOperation) throws -> Bool {
        guard activity == .assessing(operation),
              let shot = operation.shot.assessableShot else { return false }
        try workflow.transition(.assessmentRejected)
        activity = .idle
        recovery = .retryAssessment(shot)
        return true
    }

    public mutating func beginAssessmentRetry(for shot: AssessableShot) throws -> CaptureFlowOperation {
        guard activity == .idle,
              recovery == .retryAssessment(shot),
              workflow.phase == .capture(shot.captureShot) else {
            throw CaptureFlowCoordinatorError.invalidAction
        }
        let operation = makeOperation(for: shot.captureShot)
        try workflow.transition(.captured(shot.captureShot))
        activity = .assessing(operation)
        recovery = .none
        return operation
    }

    /// Invalidates an in-flight result or removes one accepted marker while the
    /// session store retains unrelated slots. The next action is a fresh capture.
    public mutating func prepareRetake(of shot: Shot) throws {
        switch activity {
        case .assessing(let operation) where operation.shot == shot:
            try workflow.transition(.assessmentRejected)
        case .idle where workflow.acceptedSlots.contains(shot):
            try workflow.transition(.retake(shot))
        case .idle where workflow.phase == .capture(shot):
            break
        default:
            throw CaptureFlowCoordinatorError.invalidAction
        }
        _ = makeOperation(for: shot) // invalidate every older result token
        activity = .idle
        recovery = .retake(shot)
    }

    /// App-owned acceptance requires one internally consistent finite result.
    /// Provider prose, confidence, and advisory nextAction cannot affect it.
    public static func accepts(_ evidence: CaptureAssessmentEvidence) -> Bool {
        evidence.quality == .ok
            && evidence.shotType.rawValue == evidence.requestedShot.rawValue
            && evidence.issues.isEmpty
            && !evidence.missingShots.contains(evidence.requestedShot)
    }

    private mutating func makeOperation(for shot: Shot) -> CaptureFlowOperation {
        nextOperationSequence &+= 1
        if nextOperationSequence == 0 { nextOperationSequence = 1 }
        return .init(sequence: nextOperationSequence, shot: shot)
    }
}

private extension Shot {
    var assessableShot: AssessableShot? {
        AssessableShot(rawValue: rawValue)
    }
}

private extension AssessableShot {
    var captureShot: Shot {
        switch self {
        case .front: .front
        case .back: .back
        case .tag: .tag
        }
    }
}
