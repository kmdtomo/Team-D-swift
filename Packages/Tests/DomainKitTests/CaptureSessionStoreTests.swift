import Foundation
import Testing
@testable import DomainKit

private enum ControlledStoreError: Error { case storeFailed, discardFailed }

private actor ControlledBackingStore: SessionImageBackingStore {
    let policy: SessionImageStoragePolicy = .memoryOnly
    private var bytes: [SessionStorageNamespace: [SessionImageHandle: Data]] = [:]
    private var discarded: Set<SessionImageHandle> = []
    private var suspendStore = false
    private var suspendLoad = false
    private var suspendDiscardAll = false
    private var failNextStore = false
    private var writeThenFailNextStore = false
    private var failNextDiscardAll = false
    private var storeStarted = false
    private var loadStarted = false
    private var discardAllStarted = false
    private var storeStartWaiter: CheckedContinuation<Void, Never>?
    private var loadStartWaiter: CheckedContinuation<Void, Never>?
    private var discardAllStartWaiter: CheckedContinuation<Void, Never>?
    private var storeResume: CheckedContinuation<Void, Never>?
    private var loadResume: CheckedContinuation<Void, Never>?
    private var discardAllResume: CheckedContinuation<Void, Never>?

    func suspendNextStore() { suspendStore = true }
    func suspendNextLoad() { suspendLoad = true }
    func suspendNextDiscardAll() { suspendDiscardAll = true }
    func failStoreOnce() { failNextStore = true }
    func writeThenFailOnce() { writeThenFailNextStore = true }
    func failDiscardAllOnce() { failNextDiscardAll = true }
    func waitForStoreStart() async { if storeStarted { return }; await withCheckedContinuation { storeStartWaiter = $0 } }
    func waitForLoadStart() async { if loadStarted { return }; await withCheckedContinuation { loadStartWaiter = $0 } }
    func waitForDiscardAllStart() async { if discardAllStarted { return }; await withCheckedContinuation { discardAllStartWaiter = $0 } }
    func resumeStore() { storeResume?.resume(); storeResume = nil }
    func resumeLoad() { loadResume?.resume(); loadResume = nil }
    func resumeDiscardAll() { discardAllResume?.resume(); discardAllResume = nil }

    func store(_ data: Data, handle: SessionImageHandle) async throws {
        if failNextStore { failNextStore = false; throw ControlledStoreError.storeFailed }
        if writeThenFailNextStore {
            writeThenFailNextStore = false
            bytes[handle.namespace, default: [:]][handle] = data
            throw ControlledStoreError.storeFailed
        }
        if suspendStore {
            suspendStore = false; storeStarted = true; storeStartWaiter?.resume(); storeStartWaiter = nil
            await withCheckedContinuation { storeResume = $0 }
        }
        bytes[handle.namespace, default: [:]][handle] = data
    }
    func discard(handle: SessionImageHandle) async { bytes[handle.namespace]?[handle] = nil; discarded.insert(handle) }
    func load(handle: SessionImageHandle) async -> Data? {
        let value = bytes[handle.namespace]?[handle]
        if suspendLoad {
            suspendLoad = false; loadStarted = true; loadStartWaiter?.resume(); loadStartWaiter = nil
            await withCheckedContinuation { loadResume = $0 }
        }
        return value
    }
    func discardAll(namespace: SessionStorageNamespace) async throws {
        if suspendDiscardAll {
            suspendDiscardAll = false; discardAllStarted = true; discardAllStartWaiter?.resume(); discardAllStartWaiter = nil
            await withCheckedContinuation { discardAllResume = $0 }
        }
        if failNextDiscardAll {
            failNextDiscardAll = false
            throw ControlledStoreError.discardFailed
        }
        bytes[namespace] = nil
    }
    func contains(_ handle: SessionImageHandle) -> Bool { bytes[handle.namespace]?[handle] != nil }
    func wasDiscarded(_ handle: SessionImageHandle) -> Bool { discarded.contains(handle) }
}

@Test func identifiersRejectEmptyAndWhitespaceOnlyValues() {
    for value in ["", " ", "\n\t"] {
        #expect(throws: DomainValidationError.invalidValue("sessionID")) { _ = try SessionID(value) }
        #expect(throws: DomainValidationError.invalidValue("requestID")) { _ = try RequestID(value) }
        #expect(throws: DomainValidationError.invalidValue("imageID")) { _ = try ImageID(value) }
    }
}

private func exposesBytesURLOrSentinel(_ value: Any, sentinel: String) -> Bool {
    if value is Data || value is URL || String(describing: value).contains(sentinel) { return true }
    return Mirror(reflecting: value).children.contains { exposesBytesURLOrSentinel($0.value, sentinel: sentinel) }
}

private func expectStale(_ task: Task<Void, Error>) async {
    await #expect(throws: SessionStoreError.staleOperation) { try await task.value }
}

private func measurementDraft(imageID: ImageID, source: MeasurementSource = .user) throws -> SessionMeasurementDraft {
    let start = try SessionNormalizedPoint(x: 0.2, y: 0.2)
    let end = try SessionNormalizedPoint(x: 0.8, y: 0.8)
    let widthStart = try SessionNormalizedPoint(x: 0.1, y: 0.5)
    let widthEnd = try SessionNormalizedPoint(x: 0.9, y: 0.5)
    let marker = try SessionMeasurementMarker(
        corners: [
            try SessionNormalizedPoint(x: 0.7, y: 0.7),
            try SessionNormalizedPoint(x: 0.8, y: 0.7),
            try SessionNormalizedPoint(x: 0.8, y: 0.8),
            try SessionNormalizedPoint(x: 0.7, y: 0.8)
        ],
        pixelsPerCentimeter: 42
    )
    return try SessionMeasurementDraft(
        measurementImageID: imageID,
        marker: marker,
        length: SessionMeasurementLine(start: start, end: end, centimeters: 63.4),
        width: SessionMeasurementLine(start: widthStart, end: widthEnd, centimeters: 51.2),
        source: source
    )
}

private func storeImage(
    _ store: CaptureSessionStore,
    artifact: SessionArtifact,
    scope: SessionOperationScope,
    request: String,
    bytes: Data = Data([1])
) async throws {
    let token = try await store.beginOperation(requestID: try RequestID(request), scope: scope)
    try await store.storeImage(bytes, artifact: artifact, for: token)
}

private func commitArtifact(
    _ store: CaptureSessionStore,
    artifact: SessionArtifact,
    scope: SessionOperationScope,
    request: String
) async throws {
    let token = try await store.beginOperation(requestID: try RequestID(request), scope: scope)
    try await store.commit(artifact, for: token)
}

@Test func measurementDraftRejectsNonFiniteOutOfRangeAndInvalidMarkerValues() throws {
    let valid = try SessionNormalizedPoint(x: 0.5, y: 0.5)
    let line = try SessionMeasurementLine(start: valid, end: valid, centimeters: 1)

    for point in [(Double.nan, 0.5), (Double.infinity, 0.5), (-0.01, 0.5), (0.5, 1.01)] {
        #expect(throws: DomainValidationError.invalidValue("normalizedPoint")) {
            try SessionNormalizedPoint(x: point.0, y: point.1)
        }
    }
    for centimeters in [0, -1, Double.nan, Double.infinity] {
        #expect(throws: DomainValidationError.invalidValue("centimeters")) {
            try SessionMeasurementLine(start: valid, end: valid, centimeters: centimeters)
        }
    }
    for invalidMarker in [
        { try SessionMeasurementMarker(corners: Array(repeating: valid, count: 3), pixelsPerCentimeter: 1) },
        { try SessionMeasurementMarker(corners: Array(repeating: valid, count: 4), knownSideCentimeters: 4.9, pixelsPerCentimeter: 1) },
        { try SessionMeasurementMarker(corners: Array(repeating: valid, count: 4), pixelsPerCentimeter: 0) },
        { try SessionMeasurementMarker(corners: Array(repeating: valid, count: 4), pixelsPerCentimeter: Double.nan) }
    ] {
        #expect(throws: DomainValidationError.self) { _ = try invalidMarker() }
    }
    #expect(throws: DomainValidationError.invalidValue("centimeters")) {
        try SessionMeasurementLine(start: valid, end: valid, centimeters: -Double.infinity)
    }
    #expect(try SessionMeasurementDraft(measurementImageID: ImageID("measurement"), marker: nil, length: line, width: line, source: .contour).marker == nil)
}

@Test func sessionOwnsEveryFiniteReferenceAndNeverExposesBytes() async throws {
    let backing = InMemorySessionImageBackingStore(); let store = CaptureSessionStore(imageStore: backing); let session = try SessionID("s")
    try await store.beginSession(session)
    let front = try ImageID("front"), back = try ImageID("back"), tag = try ImageID("tag"), measurement = try ImageID("measurement"), mask = try ImageID("mask"), background = try ImageID("background"), composite = try ImageID("composite")
    let sentinel = "binary-secret-sentinel-must-not-reach-snapshot"
    let assessment = SessionAssessmentRecord(shot: .front, quality: .ok, issues: [], missingShots: [], acceptedByApp: true)
    let draft = try measurementDraft(imageID: measurement, source: .ai)
    for (index, entry) in [(SessionOperationScope.capture(.front), SessionArtifact.original(.front, front)), (.capture(.back), .original(.back, back)), (.capture(.tag), .original(.tag, tag)), (.capture(.measurement), .original(.measurement, measurement)), (.assessment(.front), .assessment(assessment)), (.measurement, .measurementDraft(draft)), (.measurement, .measurementApproval(.approvedCV))].enumerated() {
        let token = try await store.beginOperation(requestID: try RequestID("r\(index)"), scope: entry.0)
        if case .original = entry.1 { try await store.storeImage(index == 0 ? Data(sentinel.utf8) : Data([0]), artifact: entry.1, for: token) } else { try await store.commit(entry.1, for: token) }
    }
    for (index, artifact) in [SessionArtifact.mask(mask), .background(background), .composite(composite)].enumerated() {
        let scope: SessionOperationScope = index == 0 ? .mask : index == 1 ? .background : .composite
        let token = try await store.beginOperation(requestID: try RequestID("image\(index)"), scope: scope)
        try await store.storeImage(Data([UInt8(index)]), artifact: artifact, for: token)
    }
    let snapshot = try #require(await store.snapshot())
    #expect(snapshot.originals == [.front: front, .back: back, .tag: tag, .measurement: measurement])
    #expect(snapshot.assessments == [.front: assessment]); #expect(snapshot.measurementDraft == draft); #expect(snapshot.measurementApproval == .approvedCV)
    #expect(snapshot.measurementDraft?.length.centimeters == 63.4); #expect(snapshot.measurementDraft?.width.centimeters == 51.2); #expect(snapshot.measurementDraft?.source == .ai)
    #expect(snapshot.maskID == mask); #expect(snapshot.backgroundID == background); #expect(snapshot.compositeID == composite)
    #expect(!exposesBytesURLOrSentinel(snapshot, sentinel: sentinel)); #expect(await store.loadImage(front) == Data(sentinel.utf8)); #expect(await backing.policy == .memoryOnly)
}

@Test func backingStoreFailureDoesNotCommitAnImageArtifact() async throws {
    let backing = ControlledBackingStore(); let store = CaptureSessionStore(imageStore: backing); try await store.beginSession(try SessionID("s"))
    await backing.failStoreOnce()
    let failed = try await store.beginOperation(requestID: try RequestID("failed"), scope: .capture(.front))
    await #expect(throws: ControlledStoreError.storeFailed) { try await store.storeImage(Data([1]), artifact: .original(.front, try ImageID("front")), for: failed) }
    #expect(await store.snapshot()?.originals.isEmpty == true)
    let retry = try await store.beginOperation(requestID: try RequestID("retry"), scope: .capture(.front))
    try await store.storeImage(Data([2]), artifact: .original(.front, try ImageID("front")), for: retry)
    #expect(await store.loadImage(try ImageID("front")) == Data([2]))
}

@Test func writeThenFailBackingStoreIsDiscardedBeforeRetry() async throws {
    let backing = ControlledBackingStore()
    let store = CaptureSessionStore(imageStore: backing)
    let image = try ImageID("front")
    try await store.beginSession(try SessionID("s"))
    await backing.writeThenFailOnce()
    let failed = try await store.beginOperation(requestID: try RequestID("failed"), scope: .capture(.front))
    let failedHandle = SessionImageHandle(imageID: image, token: failed)

    await #expect(throws: ControlledStoreError.storeFailed) {
        try await store.storeImage(Data([1]), artifact: .original(.front, image), for: failed)
    }
    #expect(!(await backing.contains(failedHandle)))
    #expect(await store.snapshot()?.originals.isEmpty == true)

    let retry = try await store.beginOperation(requestID: try RequestID("retry"), scope: .capture(.front))
    try await store.storeImage(Data([2]), artifact: .original(.front, image), for: retry)
    #expect(await store.loadImage(image) == Data([2]))
}

@Test func imageArtifactsRequireAsyncStoreAndScopeIsDistinct() async throws {
    let store = CaptureSessionStore(); try await store.beginSession(try SessionID("s"))
    let capture = try await store.beginOperation(requestID: try RequestID("capture"), scope: .capture(.front))
    await #expect(throws: SessionStoreError.invalidArtifact) { try await store.commit(.original(.front, try ImageID("front")), for: capture) }
    await #expect(throws: SessionStoreError.wrongScope) { try await store.storeImage(Data(), artifact: .mask(try ImageID("mask")), for: capture) }
}

@Test(arguments: [SessionOperationScope.capture(.front), .mask, .background])
func suspendedStoreCancellationRetakeAndReplacementDiscardOnlyOwnHandle(_ scope: SessionOperationScope) async throws {
    let backing = ControlledBackingStore(); let store = CaptureSessionStore(imageStore: backing); try await store.beginSession(try SessionID("s"))
    if scope == .mask {
        let source = try await store.beginOperation(requestID: try RequestID("source"), scope: .capture(.front))
        try await store.storeImage(Data([9]), artifact: .original(.front, try ImageID("front-source")), for: source)
    }
    await backing.suspendNextStore()
    let token = try await store.beginOperation(requestID: try RequestID("old"), scope: scope)
    let artifact: SessionArtifact = switch scope { case .capture(let shot): .original(shot, try ImageID("old")); case .mask: .mask(try ImageID("old")); case .background: .background(try ImageID("old")); default: fatalError("test scope") }
    let task = Task { try await store.storeImage(Data([1]), artifact: artifact, for: token) }
    await backing.waitForStoreStart()
    if scope == .capture(.front) { try await store.cancel(token) } else { try await store.retake(.front) }
    await backing.resumeStore()
    await expectStale(task)
    let handle = SessionImageHandle(imageID: try ImageID("old"), token: token)
    #expect(await backing.wasDiscarded(handle))
    #expect(await store.snapshot()?.maskID == nil)
}

@Test func suspendedStoreBecomesStaleAcrossNewSessionAndSameImageIDCannotDeleteNewBytes() async throws {
    let backing = ControlledBackingStore(); let store = CaptureSessionStore(imageStore: backing); let session = try SessionID("same"); let image = try ImageID("collision")
    try await store.beginSession(session); await backing.suspendNextStore()
    let old = try await store.beginOperation(requestID: try RequestID("old"), scope: .capture(.front))
    let oldTask = Task { try await store.storeImage(Data([1]), artifact: .original(.front, image), for: old) }
    await backing.waitForStoreStart()
    let replacement = try await store.beginOperation(requestID: try RequestID("new"), scope: .capture(.front))
    try await store.storeImage(Data([2]), artifact: .original(.front, image), for: replacement)
    await backing.resumeStore(); await expectStale(oldTask)
    #expect(await store.loadImage(image) == Data([2]))
    #expect(await backing.wasDiscarded(SessionImageHandle(imageID: image, token: old)))
    #expect(!(await backing.wasDiscarded(SessionImageHandle(imageID: image, token: replacement))))
    let before = try #require(await store.snapshot())
    try await store.beginSession(session)
    #expect((try #require(await store.snapshot())).sessionID == session)
    #expect(before.sessionID == session)
}

@Test func suspendedStoreBecomesStaleAfterBeginSessionAndDiscardsOnlyItsHandle() async throws {
    let backing = ControlledBackingStore(); let store = CaptureSessionStore(imageStore: backing); let oldID = try SessionID("old"); let newID = try SessionID("new"); let image = try ImageID("front")
    try await store.beginSession(oldID); await backing.suspendNextStore()
    let old = try await store.beginOperation(requestID: try RequestID("old-request"), scope: .capture(.front))
    let oldTask = Task { try await store.storeImage(Data([1]), artifact: .original(.front, image), for: old) }
    await backing.waitForStoreStart()
    try await store.beginSession(newID)
    let snapshotBeforeResume = try #require(await store.snapshot())
    await backing.resumeStore(); await expectStale(oldTask)
    #expect(await backing.wasDiscarded(SessionImageHandle(imageID: image, token: old)))
    #expect(await store.snapshot() == snapshotBeforeResume)
    #expect(snapshotBeforeResume.sessionID == newID); #expect(snapshotBeforeResume.originals.isEmpty)
}

@Test func delayedDiscardAllCannotEraseSameIDNewGeneration() async throws {
    let backing = ControlledBackingStore(); let store = CaptureSessionStore(imageStore: backing); let id = try SessionID("same"); let image = try ImageID("front")
    try await store.beginSession(id)
    let first = try await store.beginOperation(requestID: try RequestID("first"), scope: .capture(.front)); try await store.storeImage(Data([1]), artifact: .original(.front, image), for: first)
    await backing.suspendNextDiscardAll()
    let ending = Task { try await store.endSession() }
    await backing.waitForDiscardAllStart()
    await #expect(throws: SessionStoreError.lifecycleTransitionInProgress) {
        try await store.beginSession(id)
    }
    #expect(await store.snapshot() == nil)
    await backing.resumeDiscardAll(); try await ending.value
    try await store.beginSession(id)
    let second = try await store.beginOperation(requestID: try RequestID("second"), scope: .capture(.front)); try await store.storeImage(Data([2]), artifact: .original(.front, image), for: second)
    #expect(await store.snapshot()?.sessionID == id); #expect(await store.loadImage(image) == Data([2]))
}

@Test func delayedLoadCannotReturnBytesAfterEndSession() async throws {
    let backing = ControlledBackingStore(); let store = CaptureSessionStore(imageStore: backing); let image = try ImageID("front")
    try await store.beginSession(try SessionID("s"))
    let token = try await store.beginOperation(requestID: try RequestID("r"), scope: .capture(.front)); try await store.storeImage(Data([1]), artifact: .original(.front, image), for: token)
    await backing.suspendNextLoad()
    let loading = Task { await store.loadImage(image) }
    await backing.waitForLoadStart()
    try await store.endSession()
    await backing.resumeLoad()
    #expect(await loading.value == nil)
}

@Test func sourceRevisionRejectsAssessmentCompletionAfterOriginalReplacement() async throws {
    let store = CaptureSessionStore()
    let first = try ImageID("front-1")
    let second = try ImageID("front-2")
    let mask = try ImageID("mask")
    let background = try ImageID("background")
    let composite = try ImageID("composite")
    try await store.beginSession(try SessionID("s"))
    try await storeImage(store, artifact: .original(.front, first), scope: .capture(.front), request: "front-1")
    try await storeImage(store, artifact: .mask(mask), scope: .mask, request: "mask")
    try await storeImage(store, artifact: .background(background), scope: .background, request: "background")
    try await storeImage(store, artifact: .composite(composite), scope: .composite, request: "composite")

    let assessment = try await store.beginOperation(
        requestID: try RequestID("assessment"),
        scope: .assessment(.front)
    )
    #expect(assessment.sourceImageRevisions.map(\.imageID) == [first])

    try await storeImage(store, artifact: .original(.front, second), scope: .capture(.front), request: "front-2")
    let record = SessionAssessmentRecord(
        shot: .front,
        quality: .ok,
        issues: [],
        missingShots: [],
        acceptedByApp: true
    )
    await #expect(throws: SessionStoreError.staleOperation) {
        try await store.commit(.assessment(record), for: assessment)
    }
    let snapshot = try #require(await store.snapshot())
    #expect(snapshot.assessments[.front] == nil)
    #expect(snapshot.maskID == nil)
    #expect(snapshot.compositeID == nil)
    #expect(snapshot.backgroundID == background)
    #expect(await store.loadImage(mask) == nil)
    #expect(await store.loadImage(composite) == nil)
}

@Test func frontRetakeInvalidatesFrontDerivedArtifactsButPreservesIndependentState() async throws {
    let store = CaptureSessionStore()
    let front = try ImageID("front")
    let measurement = try ImageID("measurement")
    let mask = try ImageID("mask")
    let background = try ImageID("background")
    let composite = try ImageID("composite")
    let draft = try measurementDraft(imageID: measurement)
    try await store.beginSession(try SessionID("s"))
    try await storeImage(store, artifact: .original(.front, front), scope: .capture(.front), request: "front")
    try await storeImage(store, artifact: .original(.measurement, measurement), scope: .capture(.measurement), request: "measurement")
    try await commitArtifact(
        store,
        artifact: .assessment(SessionAssessmentRecord(shot: .front, quality: .ok, issues: [], missingShots: [], acceptedByApp: true)),
        scope: .assessment(.front),
        request: "assessment"
    )
    try await commitArtifact(store, artifact: .measurementDraft(draft), scope: .measurement, request: "draft")
    try await commitArtifact(store, artifact: .measurementApproval(.approvedManual), scope: .measurement, request: "approval")
    try await storeImage(store, artifact: .mask(mask), scope: .mask, request: "mask", bytes: Data([2]))
    try await storeImage(store, artifact: .background(background), scope: .background, request: "background", bytes: Data([3]))
    try await storeImage(store, artifact: .composite(composite), scope: .composite, request: "composite", bytes: Data([4]))

    try await store.retake(.front)

    let snapshot = try #require(await store.snapshot())
    #expect(snapshot.originals[.front] == front)
    #expect(snapshot.originals[.measurement] == measurement)
    #expect(snapshot.assessments[.front] == nil)
    #expect(snapshot.maskID == nil)
    #expect(snapshot.compositeID == nil)
    #expect(snapshot.backgroundID == background)
    #expect(snapshot.measurementDraft == draft)
    #expect(snapshot.measurementApproval == .approvedManual)
    #expect(await store.loadImage(mask) == nil)
    #expect(await store.loadImage(composite) == nil)
    #expect(await store.loadImage(background) == Data([3]))
}

@Test func measurementRetakeAndOriginalReplacementClearDraftAndApproval() async throws {
    let store = CaptureSessionStore()
    let first = try ImageID("measurement-1")
    let second = try ImageID("measurement-2")
    let draft = try measurementDraft(imageID: first)
    try await store.beginSession(try SessionID("s"))
    try await storeImage(store, artifact: .original(.measurement, first), scope: .capture(.measurement), request: "measurement-1")
    try await commitArtifact(store, artifact: .measurementDraft(draft), scope: .measurement, request: "draft-1")
    try await commitArtifact(store, artifact: .measurementApproval(.approvedCV), scope: .measurement, request: "approval-1")

    try await store.retake(.measurement)
    var snapshot = try #require(await store.snapshot())
    #expect(snapshot.originals[.measurement] == first)
    #expect(snapshot.measurementDraft == nil)
    #expect(snapshot.measurementApproval == .unapproved)

    try await commitArtifact(store, artifact: .measurementDraft(draft), scope: .measurement, request: "draft-2")
    try await commitArtifact(store, artifact: .measurementApproval(.approvedManual), scope: .measurement, request: "approval-2")
    try await storeImage(store, artifact: .original(.measurement, second), scope: .capture(.measurement), request: "measurement-2")
    snapshot = try #require(await store.snapshot())
    #expect(snapshot.originals[.measurement] == second)
    #expect(snapshot.measurementDraft == nil)
    #expect(snapshot.measurementApproval == .unapproved)
}

@Test func duplicateImageIDAcrossArtifactSlotsIsRejectedDeterministically() async throws {
    let store = CaptureSessionStore()
    let shared = try ImageID("shared")
    try await store.beginSession(try SessionID("s"))
    try await storeImage(store, artifact: .original(.front, shared), scope: .capture(.front), request: "front", bytes: Data([1]))
    let mask = try await store.beginOperation(requestID: try RequestID("mask"), scope: .mask)

    await #expect(throws: SessionStoreError.imageIDCollision) {
        try await store.storeImage(Data([2]), artifact: .mask(shared), for: mask)
    }
    #expect(await store.snapshot()?.maskID == nil)
    #expect(await store.loadImage(shared) == Data([1]))
}

@Test func endSessionCleanupFailureIsReportedAndRetryable() async throws {
    let backing = ControlledBackingStore()
    let store = CaptureSessionStore(imageStore: backing)
    let image = try ImageID("front")
    try await store.beginSession(try SessionID("s"))
    try await storeImage(store, artifact: .original(.front, image), scope: .capture(.front), request: "front", bytes: Data([7]))
    await backing.failDiscardAllOnce()

    await #expect(throws: ControlledStoreError.discardFailed) {
        try await store.endSession()
    }
    #expect(await store.snapshot()?.originals[.front] == image)
    #expect(await store.loadImage(image) == Data([7]))

    try await store.endSession()
    #expect(await store.snapshot() == nil)
    #expect(await store.loadImage(image) == nil)
}

@Test func newSessionCleanupFailureRetainsOldStateUntilRetrySucceeds() async throws {
    let backing = ControlledBackingStore()
    let store = CaptureSessionStore(imageStore: backing)
    let oldSession = try SessionID("old")
    let newSession = try SessionID("new")
    let image = try ImageID("front")
    try await store.beginSession(oldSession)
    try await storeImage(store, artifact: .original(.front, image), scope: .capture(.front), request: "front", bytes: Data([8]))
    await backing.failDiscardAllOnce()

    await #expect(throws: ControlledStoreError.discardFailed) {
        try await store.beginSession(newSession)
    }
    #expect(await store.snapshot()?.sessionID == oldSession)
    #expect(await store.loadImage(image) == Data([8]))

    try await store.beginSession(newSession)
    let snapshot = try #require(await store.snapshot())
    #expect(snapshot.sessionID == newSession)
    #expect(snapshot.originals.isEmpty)
    #expect(await store.loadImage(image) == nil)
}

@Test func retakePreservesExistingArtifactsAndMeasurementEdits() async throws {
    let store = CaptureSessionStore(); try await store.beginSession(try SessionID("s")); let front = try ImageID("front"); let measurement = try ImageID("measurement")
    let draft = try measurementDraft(imageID: measurement)
    for (index, entry) in [(SessionOperationScope.capture(.front), SessionArtifact.original(.front, front)), (.capture(.measurement), .original(.measurement, measurement)), (.measurement, .measurementDraft(draft)), (.measurement, .measurementApproval(.approvedManual))].enumerated() {
        let token = try await store.beginOperation(requestID: try RequestID("r\(index)"), scope: entry.0); if case .original = entry.1 { try await store.storeImage(Data([0]), artifact: entry.1, for: token) } else { try await store.commit(entry.1, for: token) }
    }
    try await store.retake(.front); let snapshot = try #require(await store.snapshot())
    #expect(snapshot.originals[.front] == front); #expect(snapshot.originals[.measurement] == measurement); #expect(snapshot.measurementDraft == draft); #expect(snapshot.measurementApproval == .approvedManual)
}
