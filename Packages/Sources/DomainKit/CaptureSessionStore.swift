import Foundation

public struct SessionID: Hashable, Sendable {
    public let rawValue: String
    public init(_ rawValue: String) throws {
        guard !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DomainValidationError.invalidValue("sessionID") }
        self.rawValue = rawValue
    }
}

public struct RequestID: Hashable, Sendable {
    public let rawValue: String
    public init(_ rawValue: String) throws {
        guard !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DomainValidationError.invalidValue("requestID") }
        self.rawValue = rawValue
    }
}

public struct ImageID: Hashable, Sendable {
    public let rawValue: String
    public init(_ rawValue: String) throws {
        guard !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DomainValidationError.invalidValue("imageID") }
        self.rawValue = rawValue
    }
}

/// A lifetime-unique backing-store partition. Session IDs may be reused, but generations cannot.
public struct SessionStorageNamespace: Hashable, Sendable {
    public let sessionID: SessionID
    public let lifecycleGeneration: UInt64
    public init(sessionID: SessionID, lifecycleGeneration: UInt64) {
        self.sessionID = sessionID
        self.lifecycleGeneration = lifecycleGeneration
    }
}

public enum SessionImageArtifactSlot: Hashable, Sendable {
    case original(Shot)
    case mask
    case background
    case composite
}

/// The exact session image revision consumed by an asynchronous operation.
/// The operation version is lifetime-unique within one `CaptureSessionStore`.
public struct SessionImageRevision: Hashable, Sendable {
    public let slot: SessionImageArtifactSlot
    public let imageID: ImageID
    public let operationVersion: UInt64

    public init(slot: SessionImageArtifactSlot, imageID: ImageID, operationVersion: UInt64) {
        self.slot = slot
        self.imageID = imageID
        self.operationVersion = operationVersion
    }
}

public enum SessionOperationScope: Hashable, Sendable {
    case capture(Shot)
    case assessment(AssessableShot)
    case measurement
    case mask
    case background
    case composite
}
public struct SessionOperationToken: Hashable, Sendable {
    public let namespace: SessionStorageNamespace
    public let requestID: RequestID
    public let scope: SessionOperationScope
    public let version: UInt64
    public let sourceImageRevisions: [SessionImageRevision]
    public var sessionID: SessionID { namespace.sessionID }
    public init(
        namespace: SessionStorageNamespace,
        requestID: RequestID,
        scope: SessionOperationScope,
        version: UInt64,
        sourceImageRevisions: [SessionImageRevision] = []
    ) {
        self.namespace = namespace
        self.requestID = requestID
        self.scope = scope
        self.version = version
        self.sourceImageRevisions = sourceImageRevisions
    }
}
public struct SessionImageHandle: Hashable, Sendable {
    public let imageID: ImageID
    public let token: SessionOperationToken
    public var namespace: SessionStorageNamespace { token.namespace }
    public init(imageID: ImageID, token: SessionOperationToken) {
        self.imageID = imageID
        self.token = token
    }
}

public struct SessionNormalizedPoint: Hashable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) throws {
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
            throw DomainValidationError.invalidValue("normalizedPoint")
        }
        self.x = x
        self.y = y
    }
}

public struct SessionMeasurementLine: Hashable, Sendable {
    public let start: SessionNormalizedPoint
    public let end: SessionNormalizedPoint
    public let centimeters: Double

    public init(start: SessionNormalizedPoint, end: SessionNormalizedPoint, centimeters: Double) throws {
        guard centimeters.isFinite, centimeters > 0 else { throw DomainValidationError.invalidValue("centimeters") }
        self.start = start
        self.end = end
        self.centimeters = centimeters
    }
}

public struct SessionMeasurementMarker: Hashable, Sendable {
    public let corners: [SessionNormalizedPoint]
    public let knownSideCentimeters: Double
    public let pixelsPerCentimeter: Double

    public init(corners: [SessionNormalizedPoint], knownSideCentimeters: Double = 5, pixelsPerCentimeter: Double) throws {
        guard corners.count == 4 else { throw DomainValidationError.invalidValue("marker.corners") }
        guard knownSideCentimeters == 5 else { throw DomainValidationError.invalidValue("marker.knownSideCentimeters") }
        guard pixelsPerCentimeter.isFinite, pixelsPerCentimeter > 0 else { throw DomainValidationError.invalidValue("marker.pixelsPerCentimeter") }
        self.corners = corners
        self.knownSideCentimeters = knownSideCentimeters
        self.pixelsPerCentimeter = pixelsPerCentimeter
    }
}

public struct SessionMeasurementDraft: Hashable, Sendable {
    public let measurementImageID: ImageID
    public let marker: SessionMeasurementMarker?
    public let length: SessionMeasurementLine
    public let width: SessionMeasurementLine
    public let source: MeasurementSource

    public init(measurementImageID: ImageID, marker: SessionMeasurementMarker?, length: SessionMeasurementLine, width: SessionMeasurementLine, source: MeasurementSource) {
        self.measurementImageID = measurementImageID
        self.marker = marker
        self.length = length
        self.width = width
        self.source = source
    }
}

public struct SessionAssessmentRecord: Hashable, Sendable {
    public let shot: AssessableShot
    public let quality: ShotQuality
    public let issues: Set<ShotIssueCode>
    public let missingShots: Set<AssessableShot>
    public let acceptedByApp: Bool

    public init(shot: AssessableShot, quality: ShotQuality, issues: Set<ShotIssueCode>, missingShots: Set<AssessableShot>, acceptedByApp: Bool) {
        self.shot = shot
        self.quality = quality
        self.issues = issues
        self.missingShots = missingShots
        self.acceptedByApp = acceptedByApp
    }
}

public enum SessionArtifact: Hashable, Sendable {
    case original(Shot, ImageID)
    case assessment(SessionAssessmentRecord)
    case measurementDraft(SessionMeasurementDraft)
    case measurementApproval(MeasurementApproval)
    case mask(ImageID)
    case background(ImageID)
    case composite(ImageID)
}

public enum SessionStoreError: Error, Equatable, Sendable {
    case noActiveSession
    case lifecycleTransitionInProgress
    case staleOperation
    case wrongScope
    case invalidArtifact
    case missingSourceArtifact
    case imageIDCollision
}

public enum SessionImageStoragePolicy: Equatable, Sendable {
    case memoryOnly
    case protectedTemporaryFiles
}
public protocol SessionImageBackingStore: Sendable {
    var policy: SessionImageStoragePolicy { get }
    func store(_ bytes: Data, handle: SessionImageHandle) async throws
    /// On failure the backing store must retain enough ownership metadata for retry.
    func discard(handle: SessionImageHandle) async throws
    func load(handle: SessionImageHandle) async -> Data?
    /// On failure mappings for failed or unattempted deletions remain retryable.
    func discardAll(namespace: SessionStorageNamespace) async throws
}

public actor InMemorySessionImageBackingStore: SessionImageBackingStore {
    public let policy: SessionImageStoragePolicy = .memoryOnly
    private var bytes: [SessionStorageNamespace: [SessionImageHandle: Data]] = [:]
    public init() {}

    public func store(_ bytes: Data, handle: SessionImageHandle) {
        self.bytes[handle.namespace, default: [:]][handle] = bytes
    }

    public func discard(handle: SessionImageHandle) {
        bytes[handle.namespace]?[handle] = nil
    }

    public func load(handle: SessionImageHandle) -> Data? {
        bytes[handle.namespace]?[handle]
    }

    public func discardAll(namespace: SessionStorageNamespace) {
        bytes[namespace] = nil
    }

    public func contains(_ handle: SessionImageHandle) -> Bool {
        bytes[handle.namespace]?[handle] != nil
    }
}

public struct CaptureSessionSnapshot: Equatable, Sendable {
    public let sessionID: SessionID
    public let originals: [Shot: ImageID]
    public let assessments: [AssessableShot: SessionAssessmentRecord]
    public let measurementDraft: SessionMeasurementDraft?
    public let measurementApproval: MeasurementApproval
    public let maskID: ImageID?
    public let backgroundID: ImageID?
    public let compositeID: ImageID?
}

public actor CaptureSessionStore {
    private let imageStore: any SessionImageBackingStore
    private var namespace: SessionStorageNamespace?
    private var lifecycleGeneration: UInt64 = 0
    private var nextVersion: UInt64 = 0
    private var isLifecycleTransitioning = false
    private var active: [SessionOperationScope: SessionOperationToken] = [:]
    private var originals: [Shot: ImageID] = [:]
    private var assessments: [AssessableShot: SessionAssessmentRecord] = [:]
    private var draft: SessionMeasurementDraft?
    private var approval: MeasurementApproval = .unapproved
    private var mask: ImageID?
    private var background: ImageID?
    private var composite: ImageID?
    private var handles: [SessionImageArtifactSlot: SessionImageHandle] = [:]

    public init(imageStore: any SessionImageBackingStore = InMemorySessionImageBackingStore()) {
        self.imageStore = imageStore
    }

    public func beginSession(_ id: SessionID) async throws {
        guard !isLifecycleTransitioning else { throw SessionStoreError.lifecycleTransitionInProgress }
        if let oldNamespace = namespace {
            isLifecycleTransitioning = true
            active = [:]
            do {
                try await imageStore.discardAll(namespace: oldNamespace)
            } catch {
                isLifecycleTransitioning = false
                throw error
            }
        }
        lifecycleGeneration &+= 1
        clearMetadata()
        namespace = SessionStorageNamespace(sessionID: id, lifecycleGeneration: lifecycleGeneration)
        isLifecycleTransitioning = false
    }

    public func beginOperation(requestID: RequestID, scope: SessionOperationScope) throws -> SessionOperationToken {
        guard !isLifecycleTransitioning else { throw SessionStoreError.lifecycleTransitionInProgress }
        guard let namespace else { throw SessionStoreError.noActiveSession }
        nextVersion &+= 1
        let token = SessionOperationToken(
            namespace: namespace,
            requestID: requestID,
            scope: scope,
            version: nextVersion,
            sourceImageRevisions: try sourceImageRevisions(for: scope)
        )
        active[scope] = token
        return token
    }

    public func commit(_ artifact: SessionArtifact, for token: SessionOperationToken) throws {
        try validate(token)
        guard !isImageArtifact(artifact) else { throw SessionStoreError.invalidArtifact }
        guard matches(artifact, token.scope) else { throw SessionStoreError.wrongScope }
        try validateArtifactConsistency(artifact)
        apply(artifact); active[token.scope] = nil
    }

    public func storeImage(_ bytes: Data, artifact: SessionArtifact, for token: SessionOperationToken) async throws {
        try validate(token)
        guard matches(artifact, token.scope) else { throw SessionStoreError.wrongScope }
        guard let slot = imageSlot(of: artifact), let imageID = imageID(of: artifact) else { throw SessionStoreError.invalidArtifact }
        guard !hasImageIDCollision(imageID, excluding: slot) else { throw SessionStoreError.imageIDCollision }
        let handle = SessionImageHandle(imageID: imageID, token: token)
        do {
            try await imageStore.store(bytes, handle: handle)
        } catch let storeError {
            do {
                try await imageStore.discard(handle: handle)
            } catch let cleanupError {
                throw cleanupError
            }
            throw storeError
        }
        do {
            try validate(token)
        } catch let validationError {
            do {
                try await imageStore.discard(handle: handle)
            } catch let cleanupError {
                throw cleanupError
            }
            throw validationError
        }
        guard !hasImageIDCollision(imageID, excluding: slot) else {
            try await imageStore.discard(handle: handle)
            throw SessionStoreError.imageIDCollision
        }

        let oldHandle = handles[slot]
        var obsoleteHandles = invalidateDependencies(changedSlot: slot)
        handles[slot] = handle
        apply(artifact)
        active[token.scope] = nil
        if let oldHandle {
            obsoleteHandles.append(oldHandle)
        }

        // Metadata switches to the new revision atomically before backing cleanup.
        // A thrown cleanup error means the new state is authoritative while the
        // backing store retains failed mappings for a later namespace cleanup.
        for obsoleteHandle in Set(obsoleteHandles) {
            try await imageStore.discard(handle: obsoleteHandle)
        }
    }

    public func cancel(_ token: SessionOperationToken) throws {
        try validate(token)
        active[token.scope] = nil
    }

    public func retake(_ shot: Shot) async throws {
        guard !isLifecycleTransitioning else { throw SessionStoreError.lifecycleTransitionInProgress }
        guard namespace != nil else { throw SessionStoreError.noActiveSession }
        // Retakes invalidate in-flight work, then remove only artifacts derived
        // from the retaken source while retaining independent committed state.
        active = [:]
        let obsoleteHandles = invalidateDependencies(changedSlot: .original(shot))
        for obsoleteHandle in Set(obsoleteHandles) {
            try await imageStore.discard(handle: obsoleteHandle)
        }
    }

    public func snapshot() -> CaptureSessionSnapshot? {
        guard !isLifecycleTransitioning, let namespace else { return nil }
        return CaptureSessionSnapshot(
            sessionID: namespace.sessionID,
            originals: originals,
            assessments: assessments,
            measurementDraft: draft,
            measurementApproval: approval,
            maskID: mask,
            backgroundID: background,
            compositeID: composite
        )
    }

    public func loadImage(_ imageID: ImageID) async -> Data? {
        guard !isLifecycleTransitioning,
              let namespace,
              let (slot, handle) = handles.first(where: { $0.value.imageID == imageID })
        else { return nil }
        let bytes = await imageStore.load(handle: handle)
        guard !isLifecycleTransitioning, self.namespace == namespace, handles[slot] == handle else { return nil }
        return bytes
    }

    public func endSession() async throws {
        guard !isLifecycleTransitioning else { throw SessionStoreError.lifecycleTransitionInProgress }
        guard let oldNamespace = namespace else { return }
        isLifecycleTransitioning = true
        active = [:]
        do {
            try await imageStore.discardAll(namespace: oldNamespace)
        } catch {
            isLifecycleTransitioning = false
            throw error
        }
        lifecycleGeneration &+= 1
        clearMetadata()
        isLifecycleTransitioning = false
    }

    private func validate(_ token: SessionOperationToken) throws {
        guard !isLifecycleTransitioning,
              namespace == token.namespace,
              active[token.scope] == token,
              let currentSources = try? sourceImageRevisions(for: token.scope),
              currentSources == token.sourceImageRevisions
        else {
            throw SessionStoreError.staleOperation
        }
    }

    private func matches(_ artifact: SessionArtifact, _ scope: SessionOperationScope) -> Bool {
        switch (artifact, scope) {
        case (.original(let shot, _), .capture(let expected)): shot == expected
        case (.assessment(let value), .assessment(let expected)): value.shot == expected
        case (.measurementDraft, .measurement), (.measurementApproval, .measurement), (.mask, .mask), (.background, .background), (.composite, .composite): true
        default: false
        }
    }

    private func apply(_ artifact: SessionArtifact) {
        switch artifact {
        case .original(let shot, let id): originals[shot] = id
        case .assessment(let value): assessments[value.shot] = value
        case .measurementDraft(let value):
            draft = value
            approval = .unapproved
        case .measurementApproval(let value): approval = value
        case .mask(let id): mask = id
        case .background(let id): background = id
        case .composite(let id): composite = id
        }
    }

    private func isImageArtifact(_ artifact: SessionArtifact) -> Bool {
        imageSlot(of: artifact) != nil
    }

    private func imageID(of artifact: SessionArtifact) -> ImageID? {
        switch artifact {
        case .original(_, let id), .mask(let id), .background(let id), .composite(let id): id
        default: nil
        }
    }

    private func imageSlot(of artifact: SessionArtifact) -> SessionImageArtifactSlot? {
        switch artifact {
        case .original(let shot, _): .original(shot)
        case .mask: .mask
        case .background: .background
        case .composite: .composite
        default: nil
        }
    }

    private func validateArtifactConsistency(_ artifact: SessionArtifact) throws {
        switch artifact {
        case .measurementDraft(let value):
            guard originals[.measurement] == value.measurementImageID else {
                throw SessionStoreError.invalidArtifact
            }
        case .measurementApproval(let value):
            if value != .unapproved {
                guard let draft,
                      originals[.measurement] == draft.measurementImageID
                else { throw SessionStoreError.invalidArtifact }
            }
        default:
            break
        }
    }

    private func hasImageIDCollision(_ imageID: ImageID, excluding slot: SessionImageArtifactSlot) -> Bool {
        handles.contains { existingSlot, handle in
            existingSlot != slot && handle.imageID == imageID
        }
    }

    private func sourceImageRevisions(for scope: SessionOperationScope) throws -> [SessionImageRevision] {
        switch scope {
        case .capture, .background:
            return []
        case .assessment(let shot):
            return [try revision(for: .original(shot.shot))]
        case .measurement:
            return [try revision(for: .original(.measurement))]
        case .mask:
            return [try revision(for: .original(.front))]
        case .composite:
            return [
                try revision(for: .original(.front)),
                try revision(for: .mask),
                try revision(for: .background),
            ]
        }
    }

    private func revision(for slot: SessionImageArtifactSlot) throws -> SessionImageRevision {
        guard let handle = handles[slot] else { throw SessionStoreError.missingSourceArtifact }
        return SessionImageRevision(
            slot: slot,
            imageID: handle.imageID,
            operationVersion: handle.token.version
        )
    }

    private func invalidateDependencies(changedSlot: SessionImageArtifactSlot) -> [SessionImageHandle] {
        var obsoleteHandles: [SessionImageHandle] = []

        switch changedSlot {
        case .original(.front):
            assessments[.front] = nil
            active[.assessment(.front)] = nil
            active[.mask] = nil
            active[.composite] = nil
            if let handle = handles.removeValue(forKey: .mask) { obsoleteHandles.append(handle) }
            if let handle = handles.removeValue(forKey: .composite) { obsoleteHandles.append(handle) }
            mask = nil
            composite = nil

        case .original(.back):
            assessments[.back] = nil
            active[.assessment(.back)] = nil

        case .original(.tag):
            assessments[.tag] = nil
            active[.assessment(.tag)] = nil

        case .original(.measurement):
            active[.measurement] = nil
            draft = nil
            approval = .unapproved

        case .mask, .background:
            active[.composite] = nil
            if let handle = handles.removeValue(forKey: .composite) { obsoleteHandles.append(handle) }
            composite = nil

        case .composite:
            break
        }

        return obsoleteHandles
    }

    private func clearMetadata() {
        namespace = nil
        active = [:]
        originals = [:]
        assessments = [:]
        draft = nil
        approval = .unapproved
        mask = nil
        background = nil
        composite = nil
        handles = [:]
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
