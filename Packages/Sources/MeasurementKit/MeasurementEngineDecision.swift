import CoreGraphics
import Foundation

/// The engine-neutral surface exercised by the T11-03 shared contract suite.
///
/// An OpenCV implementation may conform through `OpenCVMeasurementEngineWrapping`
/// only after the decision gate selects it. This file intentionally imports no
/// OpenCV module and does not make an OpenCV implementation available.
public protocol MeasurementEngineAnalyzing {
    var engineIdentifier: MeasurementEngineIdentifier { get }

    func analyze(
        image: CGImage,
        orientation: MeasurementImageOrientation,
        proposedEndpoints: [MeasurementPixelPoint]?
    ) -> MeasurementPoCOutcome
}

public protocol OpenCVMeasurementEngineWrapping: MeasurementEngineAnalyzing {}

@available(macOS 11.0, *)
extension AppleMeasurementPoCPipeline: MeasurementEngineAnalyzing {
    public var engineIdentifier: MeasurementEngineIdentifier { .appleFrameworks }
}

public enum MeasurementEngineIdentifier: String, CaseIterable, Equatable, Sendable {
    case appleFrameworks = "apple-frameworks"
    case openCVIOS = "opencv-ios"
}

public struct MeasurementEngineDecisionThresholds: Equatable, Sendable {
    public let minimumPhysicalCaptureCount: Int
    public let markerSideMillimeters: Double
    public let minimumValidDetectionRate: Double
    public let maximumInvalidScaleAcceptances: Int
    public let maximumRelativeScaleError: Double
    public let maximumP95LatencyMilliseconds: Double

    /// T11-02 acceptance thresholds are product requirements, not runtime tuning.
    public init() {
        minimumPhysicalCaptureCount = 30
        markerSideMillimeters = 50
        minimumValidDetectionRate = 0.95
        maximumInvalidScaleAcceptances = 0
        maximumRelativeScaleError = 0.01
        maximumP95LatencyMilliseconds = 1_000
    }
}

public struct MeasurementPhysicalCorpusEvidence: Equatable, Sendable {
    public let corpusFingerprint: String?
    public let captureCount: Int
    public let rightsClearedCount: Int
    public let piiClearedCount: Int
    public let rulerConfirmedMarkerSideMillimeters: Double?
    public let annotationsComplete: Bool

    public init(
        corpusFingerprint: String?,
        captureCount: Int,
        rightsClearedCount: Int,
        piiClearedCount: Int,
        rulerConfirmedMarkerSideMillimeters: Double?,
        annotationsComplete: Bool
    ) {
        self.corpusFingerprint = corpusFingerprint
        self.captureCount = captureCount
        self.rightsClearedCount = rightsClearedCount
        self.piiClearedCount = piiClearedCount
        self.rulerConfirmedMarkerSideMillimeters = rulerConfirmedMarkerSideMillimeters
        self.annotationsComplete = annotationsComplete
    }
}

public struct MeasurementEngineBenchmarkEvidence: Equatable, Sendable {
    public let engine: MeasurementEngineIdentifier
    public let corpusFingerprint: String
    public let totalCaseCount: Int
    public let validMarkerCaseCount: Int
    public let validMarkerDetectionCount: Int
    public let invalidMarkerCaseCount: Int
    public let invalidScaleAcceptanceCount: Int
    public let maximumRelativeScaleError: Double
    public let p95LatencyMilliseconds: Double
    public let rawMeasurementsComplete: Bool
    public let memoryEvidenceReviewed: Bool
    public let sharedContractSuitePassed: Bool

    public init(
        engine: MeasurementEngineIdentifier,
        corpusFingerprint: String,
        totalCaseCount: Int,
        validMarkerCaseCount: Int,
        validMarkerDetectionCount: Int,
        invalidMarkerCaseCount: Int,
        invalidScaleAcceptanceCount: Int,
        maximumRelativeScaleError: Double,
        p95LatencyMilliseconds: Double,
        rawMeasurementsComplete: Bool,
        memoryEvidenceReviewed: Bool,
        sharedContractSuitePassed: Bool
    ) {
        self.engine = engine
        self.corpusFingerprint = corpusFingerprint
        self.totalCaseCount = totalCaseCount
        self.validMarkerCaseCount = validMarkerCaseCount
        self.validMarkerDetectionCount = validMarkerDetectionCount
        self.invalidMarkerCaseCount = invalidMarkerCaseCount
        self.invalidScaleAcceptanceCount = invalidScaleAcceptanceCount
        self.maximumRelativeScaleError = maximumRelativeScaleError
        self.p95LatencyMilliseconds = p95LatencyMilliseconds
        self.rawMeasurementsComplete = rawMeasurementsComplete
        self.memoryEvidenceReviewed = memoryEvidenceReviewed
        self.sharedContractSuitePassed = sharedContractSuitePassed
    }

    public var validDetectionRate: Double {
        guard validMarkerCaseCount > 0 else { return 0 }
        return Double(validMarkerDetectionCount) / Double(validMarkerCaseCount)
    }
}

public enum OpenCVLicenseReview: String, Equatable, Sendable {
    case pending
    case compatible
    case incompatible
}

public enum OpenCVNoticeReview: String, Equatable, Sendable {
    case pending
    case notRequired
    case planRecorded
}

public enum OpenCVPrivacyReview: String, Equatable, Sendable {
    case pending
    case passed
    case failed
}

public struct OpenCVAdoptionImpact: Equatable, Sendable {
    public let binarySizeDeltaBytes: Int?
    public let cleanBuildTimeDeltaSeconds: Double?
    public let licenseIdentifier: String?
    public let licenseReview: OpenCVLicenseReview
    public let noticeReview: OpenCVNoticeReview
    public let privacyReview: OpenCVPrivacyReview
    public let artifactSource: String?
    public let artifactSHA256: String?

    public init(
        binarySizeDeltaBytes: Int?,
        cleanBuildTimeDeltaSeconds: Double?,
        licenseIdentifier: String?,
        licenseReview: OpenCVLicenseReview,
        noticeReview: OpenCVNoticeReview,
        privacyReview: OpenCVPrivacyReview,
        artifactSource: String?,
        artifactSHA256: String?
    ) {
        self.binarySizeDeltaBytes = binarySizeDeltaBytes
        self.cleanBuildTimeDeltaSeconds = cleanBuildTimeDeltaSeconds
        self.licenseIdentifier = licenseIdentifier
        self.licenseReview = licenseReview
        self.noticeReview = noticeReview
        self.privacyReview = privacyReview
        self.artifactSource = artifactSource
        self.artifactSHA256 = artifactSHA256
    }

    public var isComplete: Bool {
        guard let binarySizeDeltaBytes,
              binarySizeDeltaBytes >= 0,
              let cleanBuildTimeDeltaSeconds,
              cleanBuildTimeDeltaSeconds.isFinite,
              cleanBuildTimeDeltaSeconds >= 0,
              let licenseIdentifier,
              !licenseIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              licenseReview != .pending,
              noticeReview != .pending,
              privacyReview != .pending,
              let artifactSource,
              !artifactSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let artifactSHA256,
              artifactSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            return false
        }
        return true
    }

    public var permitsDistribution: Bool {
        isComplete && licenseReview == .compatible && privacyReview == .passed
    }
}

public enum MeasurementEngineCriterion: String, CaseIterable, Equatable, Sendable {
    case sharedContractSuite = "shared-contract-suite"
    case validMarkerDetectionRate = "valid-marker-detection-rate"
    case invalidScaleAcceptance = "invalid-scale-acceptance"
    case relativeScaleError = "relative-scale-error"
    case p95Latency = "p95-latency"
    case distributionReview = "distribution-review"
}

public enum MeasurementEngineDecisionBlocker: Equatable, Sendable {
    case physicalCaptureShortfall(required: Int, actual: Int)
    case rightsClearanceIncomplete(required: Int, actual: Int)
    case piiClearanceIncomplete(required: Int, actual: Int)
    case rulerEvidenceMissing(requiredMillimeters: Double)
    case corpusAnnotationIncomplete
    case corpusFingerprintMissing
    case engineEvidenceMissing(MeasurementEngineIdentifier)
    case engineEvidenceIncomplete(MeasurementEngineIdentifier)
    case corpusMismatch(engine: MeasurementEngineIdentifier)
    case openCVImpactIncomplete
    case openCVAdoptionApprovalMissing
}

public enum MeasurementEngineDecisionOutcome: Equatable, Sendable {
    case selected(MeasurementEngineIdentifier)
    case productFallbacksRequired(
        appleFailures: [MeasurementEngineCriterion],
        openCVFailures: [MeasurementEngineCriterion]
    )
    case blocked([MeasurementEngineDecisionBlocker])
}

public struct MeasurementEngineDecisionInput: Equatable, Sendable {
    public let physicalCorpus: MeasurementPhysicalCorpusEvidence
    public let appleEvidence: MeasurementEngineBenchmarkEvidence?
    public let openCVEvidence: MeasurementEngineBenchmarkEvidence?
    public let openCVImpact: OpenCVAdoptionImpact?
    public let openCVAdoptionApproved: Bool

    public init(
        physicalCorpus: MeasurementPhysicalCorpusEvidence,
        appleEvidence: MeasurementEngineBenchmarkEvidence?,
        openCVEvidence: MeasurementEngineBenchmarkEvidence?,
        openCVImpact: OpenCVAdoptionImpact?,
        openCVAdoptionApproved: Bool
    ) {
        self.physicalCorpus = physicalCorpus
        self.appleEvidence = appleEvidence
        self.openCVEvidence = openCVEvidence
        self.openCVImpact = openCVImpact
        self.openCVAdoptionApproved = openCVAdoptionApproved
    }
}

public struct MeasurementEngineDecisionEvaluator: Sendable {
    public let thresholds: MeasurementEngineDecisionThresholds

    public init() {
        thresholds = .init()
    }

    public func evaluate(_ input: MeasurementEngineDecisionInput) -> MeasurementEngineDecisionOutcome {
        let corpusBlockers = validatePhysicalCorpus(input.physicalCorpus)
        guard corpusBlockers.isEmpty else { return .blocked(corpusBlockers) }

        guard let appleEvidence = input.appleEvidence else {
            return .blocked([.engineEvidenceMissing(.appleFrameworks)])
        }
        if let blocker = validateCompleteness(
            appleEvidence,
            for: .appleFrameworks,
            physicalCorpus: input.physicalCorpus
        ) {
            return .blocked([blocker])
        }

        let appleFailures = criterionFailures(in: appleEvidence)
        guard !appleFailures.isEmpty else { return .selected(.appleFrameworks) }

        guard let openCVEvidence = input.openCVEvidence else {
            return .blocked([.engineEvidenceMissing(.openCVIOS)])
        }
        if let blocker = validateCompleteness(
            openCVEvidence,
            for: .openCVIOS,
            physicalCorpus: input.physicalCorpus
        ) {
            return .blocked([blocker])
        }
        guard let openCVImpact = input.openCVImpact, openCVImpact.isComplete else {
            return .blocked([.openCVImpactIncomplete])
        }

        var openCVFailures = criterionFailures(in: openCVEvidence)
        if !openCVImpact.permitsDistribution {
            openCVFailures.append(.distributionReview)
        }
        guard openCVFailures.isEmpty else {
            return .productFallbacksRequired(
                appleFailures: appleFailures,
                openCVFailures: openCVFailures
            )
        }
        guard input.openCVAdoptionApproved else {
            return .blocked([.openCVAdoptionApprovalMissing])
        }
        return .selected(.openCVIOS)
    }

    private func validatePhysicalCorpus(
        _ corpus: MeasurementPhysicalCorpusEvidence
    ) -> [MeasurementEngineDecisionBlocker] {
        var blockers: [MeasurementEngineDecisionBlocker] = []
        if corpus.captureCount < thresholds.minimumPhysicalCaptureCount {
            blockers.append(.physicalCaptureShortfall(
                required: thresholds.minimumPhysicalCaptureCount,
                actual: corpus.captureCount
            ))
        }
        if corpus.rightsClearedCount != corpus.captureCount
            || corpus.rightsClearedCount < thresholds.minimumPhysicalCaptureCount {
            blockers.append(.rightsClearanceIncomplete(
                required: max(corpus.captureCount, thresholds.minimumPhysicalCaptureCount),
                actual: corpus.rightsClearedCount
            ))
        }
        if corpus.piiClearedCount != corpus.captureCount
            || corpus.piiClearedCount < thresholds.minimumPhysicalCaptureCount {
            blockers.append(.piiClearanceIncomplete(
                required: max(corpus.captureCount, thresholds.minimumPhysicalCaptureCount),
                actual: corpus.piiClearedCount
            ))
        }
        if corpus.rulerConfirmedMarkerSideMillimeters.map({
            abs($0 - thresholds.markerSideMillimeters) <= 0.000_001
        }) != true {
            blockers.append(.rulerEvidenceMissing(
                requiredMillimeters: thresholds.markerSideMillimeters
            ))
        }
        if !corpus.annotationsComplete { blockers.append(.corpusAnnotationIncomplete) }
        if corpus.corpusFingerprint?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            blockers.append(.corpusFingerprintMissing)
        }
        return blockers
    }

    private func validateCompleteness(
        _ evidence: MeasurementEngineBenchmarkEvidence,
        for engine: MeasurementEngineIdentifier,
        physicalCorpus: MeasurementPhysicalCorpusEvidence
    ) -> MeasurementEngineDecisionBlocker? {
        guard evidence.engine == engine else { return .engineEvidenceIncomplete(engine) }
        guard evidence.corpusFingerprint == physicalCorpus.corpusFingerprint else {
            return .corpusMismatch(engine: engine)
        }
        guard evidence.totalCaseCount == physicalCorpus.captureCount,
              evidence.validMarkerCaseCount > 0,
              evidence.invalidMarkerCaseCount > 0,
              evidence.validMarkerCaseCount + evidence.invalidMarkerCaseCount == evidence.totalCaseCount,
              (0...evidence.validMarkerCaseCount).contains(evidence.validMarkerDetectionCount),
              (0...evidence.invalidMarkerCaseCount).contains(evidence.invalidScaleAcceptanceCount),
              evidence.maximumRelativeScaleError.isFinite,
              evidence.maximumRelativeScaleError >= 0,
              evidence.p95LatencyMilliseconds.isFinite,
              evidence.p95LatencyMilliseconds >= 0,
              evidence.rawMeasurementsComplete,
              evidence.memoryEvidenceReviewed else {
            return .engineEvidenceIncomplete(engine)
        }
        return nil
    }

    private func criterionFailures(
        in evidence: MeasurementEngineBenchmarkEvidence
    ) -> [MeasurementEngineCriterion] {
        var failures: [MeasurementEngineCriterion] = []
        if !evidence.sharedContractSuitePassed { failures.append(.sharedContractSuite) }
        if evidence.validDetectionRate < thresholds.minimumValidDetectionRate {
            failures.append(.validMarkerDetectionRate)
        }
        if evidence.invalidScaleAcceptanceCount > thresholds.maximumInvalidScaleAcceptances {
            failures.append(.invalidScaleAcceptance)
        }
        if evidence.maximumRelativeScaleError > thresholds.maximumRelativeScaleError {
            failures.append(.relativeScaleError)
        }
        if evidence.p95LatencyMilliseconds > thresholds.maximumP95LatencyMilliseconds {
            failures.append(.p95Latency)
        }
        return failures
    }
}
