public enum DomainValidationError: Error, Equatable, Sendable {
    case invalidValue(String)
}

public enum Shot: String, CaseIterable, Sendable {
    case front
    case back
    case tag
    case measurement
}

public enum AssessableShot: String, CaseIterable, Sendable {
    case front
    case back
    case tag
}

public enum GuidanceCode: String, CaseIterable, Sendable {
    case moveCloser = "MOVE_CLOSER"
    case moveFarther = "MOVE_FARTHER"
    case centerGarment = "CENTER_GARMENT"
    case showFullGarment = "SHOW_FULL_GARMENT"
    case wrongSide = "WRONG_SIDE"
    case moveToTag = "MOVE_TO_TAG"
    case placeMarker = "PLACE_MARKER"
    case markerNotVisible = "MARKER_NOT_VISIBLE"
    case flattenGarment = "FLATTEN_GARMENT"
    case cameraOverhead = "CAMERA_OVERHEAD"
    case holdSteady = "HOLD_STEADY"
    case ready = "READY"
    case agentUnavailable = "AGENT_UNAVAILABLE"
}

public enum LocalQualityHint: String, CaseIterable, Sendable {
    case tooDark = "TOO_DARK"
    case tooBright = "TOO_BRIGHT"
    case tooBlurry = "TOO_BLURRY"
    case holdSteady = "HOLD_STEADY"
    case ready = "READY"
    case analyzerUnavailable = "ANALYZER_UNAVAILABLE"
}

public enum ShotQuality: String, CaseIterable, Sendable {
    case ok
    case retry
}

public enum ShotType: String, CaseIterable, Sendable {
    case front
    case back
    case tag
    case unknown
}

public enum ShotIssueCode: String, CaseIterable, Sendable {
    case tooDark = "TOO_DARK"
    case tooBright = "TOO_BRIGHT"
    case tooBlurry = "TOO_BLURRY"
    case blurry = "BLURRY"
    case garmentCropped = "GARMENT_CROPPED"
    case tagUnreadable = "TAG_UNREADABLE"
    case wrongShot = "WRONG_SHOT"
}

public enum ShotNextAction: String, CaseIterable, Sendable {
    case retake = "RETAKE"
    case requestNext = "REQUEST_NEXT"
    case complete = "COMPLETE"
}

public enum Provider: String, CaseIterable, Sendable {
    case shotAssessor = "shot-assessor"
    case visionGuidance = "vision-guidance"
    case measurementLine = "measurement-line"
    case backgroundGenerator = "background-generator"
    case garmentMasker = "garment-masker"
}

public enum ProviderErrorCode: String, CaseIterable, Sendable {
    case timeout = "TIMEOUT"
    case unavailable = "UNAVAILABLE"
    case invalidResponse = "INVALID_RESPONSE"
    case invalidInput = "INVALID_INPUT"
    case unknown = "UNKNOWN"
}

public enum MeasurementSource: String, CaseIterable, Sendable {
    case ai
    case contour
    case user
}

public enum MeasurementStatus: String, CaseIterable, Sendable {
    case needsReview = "needs_review"
    case approvedCV = "approved_cv"
    case approvedManual = "approved_manual"
}

public enum MeasurementFailure: String, CaseIterable, Sendable {
    case markerMissing = "MARKER_MISSING"
    case markerMultiple = "MARKER_MULTIPLE"
    case markerTooSmall = "MARKER_TOO_SMALL"
    case markerOccluded = "MARKER_OCCLUDED"
    case garmentOutOfFrame = "GARMENT_OUT_OF_FRAME"
    case garmentMarkerOverlap = "GARMENT_MARKER_OVERLAP"
    case segmentationFailed = "SEGMENTATION_FAILED"
    case endpointsInvalid = "ENDPOINTS_INVALID"
}
