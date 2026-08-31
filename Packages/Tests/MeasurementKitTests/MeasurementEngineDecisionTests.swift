import CoreGraphics
import DomainKit
import Foundation
import MeasurementKit
import Testing

@Test func missingPhysicalEvidenceBlocksAnyEngineSelection() {
    let outcome = MeasurementEngineDecisionEvaluator().evaluate(.init(
        physicalCorpus: .init(
            corpusFingerprint: nil,
            captureCount: 0,
            rightsClearedCount: 0,
            piiClearedCount: 0,
            rulerConfirmedMarkerSideMillimeters: nil,
            annotationsComplete: false
        ),
        appleEvidence: nil,
        openCVEvidence: nil,
        openCVImpact: nil,
        openCVAdoptionApproved: false
    ))

    guard case let .blocked(blockers) = outcome else {
        Issue.record("Missing physical evidence must not select an engine")
        return
    }
    #expect(blockers.contains(.physicalCaptureShortfall(required: 30, actual: 0)))
    #expect(blockers.contains(.rulerEvidenceMissing(requiredMillimeters: 50)))
    #expect(blockers.contains(.corpusFingerprintMissing))
}

@Test func appleIsSelectedWithoutOpenCVWhenEveryAppleCriterionPasses() {
    let outcome = evaluate(apple: passingEvidence(engine: .appleFrameworks))
    #expect(outcome == .selected(.appleFrameworks))
}

@Test func exactDetectionAndAccuracyBoundariesPassAppleGate() {
    let apple = evidence(
        engine: .appleFrameworks,
        validMarkerDetectionCount: 19,
        maximumRelativeScaleError: 0.01,
        p95LatencyMilliseconds: 1_000
    )
    #expect(evaluate(apple: apple) == .selected(.appleFrameworks))
}

@Test func appleFailureRequiresSameCorpusOpenCVEvidence() {
    let apple = evidence(engine: .appleFrameworks, validMarkerDetectionCount: 18)
    #expect(evaluate(apple: apple) == .blocked([.engineEvidenceMissing(.openCVIOS)]))

    let mismatched = MeasurementEngineBenchmarkEvidence(
        engine: .openCVIOS,
        corpusFingerprint: "different-corpus",
        totalCaseCount: 30,
        validMarkerCaseCount: 20,
        validMarkerDetectionCount: 20,
        invalidMarkerCaseCount: 10,
        invalidScaleAcceptanceCount: 0,
        maximumRelativeScaleError: 0.005,
        p95LatencyMilliseconds: 500,
        rawMeasurementsComplete: true,
        memoryEvidenceReviewed: true,
        sharedContractSuitePassed: true
    )
    #expect(evaluate(apple: apple, openCV: mismatched, impact: passingImpact())
        == .blocked([.corpusMismatch(engine: .openCVIOS)]))
}

@Test func openCVCannotBeSelectedWithoutMeasuredDistributionImpactAndApproval() {
    let apple = evidence(engine: .appleFrameworks, validMarkerDetectionCount: 18)
    let openCV = passingEvidence(engine: .openCVIOS)

    #expect(evaluate(apple: apple, openCV: openCV)
        == .blocked([.openCVImpactIncomplete]))
    #expect(evaluate(apple: apple, openCV: openCV, impact: passingImpact())
        == .blocked([.openCVAdoptionApprovalMissing]))
}

@Test func openCVIsSelectedOnlyAfterItPassesAndAdoptionIsApproved() {
    let apple = evidence(
        engine: .appleFrameworks,
        validMarkerDetectionCount: 18,
        invalidScaleAcceptanceCount: 1,
        maximumRelativeScaleError: 0.02,
        p95LatencyMilliseconds: 1_100
    )
    let openCV = passingEvidence(engine: .openCVIOS)

    #expect(evaluate(
        apple: apple,
        openCV: openCV,
        impact: passingImpact(),
        approved: true
    ) == .selected(.openCVIOS))
}

@Test func failingOrNonDistributableOpenCVRequiresProductFallbacks() {
    let apple = evidence(engine: .appleFrameworks, validMarkerDetectionCount: 18)
    let openCV = evidence(engine: .openCVIOS, maximumRelativeScaleError: 0.02)
    let outcome = evaluate(
        apple: apple,
        openCV: openCV,
        impact: passingImpact(),
        approved: true
    )
    #expect(outcome == .productFallbacksRequired(
        appleFailures: [.validMarkerDetectionRate],
        openCVFailures: [.relativeScaleError]
    ))

    let incompatible = OpenCVAdoptionImpact(
        binarySizeDeltaBytes: 10_000_000,
        cleanBuildTimeDeltaSeconds: 12,
        licenseIdentifier: "recorded-license",
        licenseReview: .incompatible,
        noticeReview: .planRecorded,
        privacyReview: .passed,
        artifactSource: "https://example.invalid/pinned-artifact",
        artifactSHA256: String(repeating: "a", count: 64)
    )
    #expect(evaluate(
        apple: apple,
        openCV: passingEvidence(engine: .openCVIOS),
        impact: incompatible,
        approved: true
    ) == .productFallbacksRequired(
        appleFailures: [.validMarkerDetectionRate],
        openCVFailures: [.distributionReview]
    ))
}

@Test func bothEngineKindsUseTheSameFiniteAnalysisContract() throws {
    let image = try #require(CGImage(
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: try #require(CGDataProvider(data: Data([0, 0, 0, 255]) as CFData)),
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    ))
    let success = MeasurementPoCSuccess(
        markerCorners: .init(
            topLeft: .init(x: 0, y: 0),
            topRight: .init(x: 1, y: 0),
            bottomRight: .init(x: 1, y: 1),
            bottomLeft: .init(x: 0, y: 1)
        ),
        pixelsPerCentimeter: 20,
        rectifiedWidth: 1,
        rectifiedHeight: 1
    )
    let apple = StubEngine(identifier: .appleFrameworks, outcome: .success(success))
    let openCV = StubOpenCVWrapper(outcome: .failure(.markerMissing))

    #expect(sharedContractSummary(apple, image: image) == "apple-frameworks:success")
    #expect(sharedContractSummary(openCV, image: image) == "opencv-ios:MARKER_MISSING")
}

private let physicalCorpus = MeasurementPhysicalCorpusEvidence(
    corpusFingerprint: "rights-cleared-corpus-v1",
    captureCount: 30,
    rightsClearedCount: 30,
    piiClearedCount: 30,
    rulerConfirmedMarkerSideMillimeters: 50,
    annotationsComplete: true
)

private func evaluate(
    apple: MeasurementEngineBenchmarkEvidence,
    openCV: MeasurementEngineBenchmarkEvidence? = nil,
    impact: OpenCVAdoptionImpact? = nil,
    approved: Bool = false
) -> MeasurementEngineDecisionOutcome {
    MeasurementEngineDecisionEvaluator().evaluate(.init(
        physicalCorpus: physicalCorpus,
        appleEvidence: apple,
        openCVEvidence: openCV,
        openCVImpact: impact,
        openCVAdoptionApproved: approved
    ))
}

private func passingEvidence(
    engine: MeasurementEngineIdentifier
) -> MeasurementEngineBenchmarkEvidence {
    evidence(engine: engine)
}

private func evidence(
    engine: MeasurementEngineIdentifier,
    validMarkerDetectionCount: Int = 20,
    invalidScaleAcceptanceCount: Int = 0,
    maximumRelativeScaleError: Double = 0.005,
    p95LatencyMilliseconds: Double = 500
) -> MeasurementEngineBenchmarkEvidence {
    MeasurementEngineBenchmarkEvidence(
        engine: engine,
        corpusFingerprint: "rights-cleared-corpus-v1",
        totalCaseCount: 30,
        validMarkerCaseCount: 20,
        validMarkerDetectionCount: validMarkerDetectionCount,
        invalidMarkerCaseCount: 10,
        invalidScaleAcceptanceCount: invalidScaleAcceptanceCount,
        maximumRelativeScaleError: maximumRelativeScaleError,
        p95LatencyMilliseconds: p95LatencyMilliseconds,
        rawMeasurementsComplete: true,
        memoryEvidenceReviewed: true,
        sharedContractSuitePassed: true
    )
}

private func passingImpact() -> OpenCVAdoptionImpact {
    OpenCVAdoptionImpact(
        binarySizeDeltaBytes: 10_000_000,
        cleanBuildTimeDeltaSeconds: 12,
        licenseIdentifier: "recorded-license",
        licenseReview: .compatible,
        noticeReview: .planRecorded,
        privacyReview: .passed,
        artifactSource: "https://example.invalid/pinned-artifact",
        artifactSHA256: String(repeating: "a", count: 64)
    )
}

private struct StubEngine: MeasurementEngineAnalyzing {
    let engineIdentifier: MeasurementEngineIdentifier
    let outcome: MeasurementPoCOutcome

    init(identifier: MeasurementEngineIdentifier, outcome: MeasurementPoCOutcome) {
        engineIdentifier = identifier
        self.outcome = outcome
    }

    func analyze(
        image _: CGImage,
        orientation _: MeasurementImageOrientation,
        proposedEndpoints _: [MeasurementPixelPoint]?
    ) -> MeasurementPoCOutcome {
        outcome
    }
}

private struct StubOpenCVWrapper: OpenCVMeasurementEngineWrapping {
    let engineIdentifier = MeasurementEngineIdentifier.openCVIOS
    let outcome: MeasurementPoCOutcome

    func analyze(
        image _: CGImage,
        orientation _: MeasurementImageOrientation,
        proposedEndpoints _: [MeasurementPixelPoint]?
    ) -> MeasurementPoCOutcome {
        outcome
    }
}

private func sharedContractSummary(
    _ engine: some MeasurementEngineAnalyzing,
    image: CGImage
) -> String {
    let outcome = engine.analyze(image: image, orientation: .up, proposedEndpoints: nil)
    switch outcome {
    case .success:
        return "\(engine.engineIdentifier.rawValue):success"
    case let .failure(failure):
        return "\(engine.engineIdentifier.rawValue):\(failure.rawValue)"
    case let .qualityRejected(hint):
        return "\(engine.engineIdentifier.rawValue):\(hint.rawValue)"
    }
}
