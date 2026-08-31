import ContractKit
import DomainKit
import Foundation

/// Availability is explicit per build composition. Contract fixtures and the
/// current live backend never substitute for one another after a failure.
public enum ShotAssessmentServiceAvailability: Equatable, Sendable {
    case fixtureContract
    case liveAvailable
    case liveUnavailable
}

/// Explicit compatibility boundary. The frozen Swift v1 contract remains
/// reproducible, while the current shared backend is consumed without silently
/// rewriting those historical schemas and goldens.
public enum ShotAssessmentWireContract: Equatable, Sendable {
    case frozenSwiftV1
    case upstreamA25A854

    fileprivate var imageField: String {
        switch self {
        case .frozenSwiftV1: "image"
        case .upstreamA25A854: "file"
        }
    }
}

/// Camera and imported originals are sent without rendering, resizing, or
/// re-encoding. Orientation remains in the original file metadata.
public enum ShotAssessmentImageNormalizationPolicy: Equatable, Sendable {
    case preserveHighResolutionOriginal
}

public struct ShotAssessmentOperation: Sendable {
    public let requestID: RequestID
    public let imageID: ImageID
    public let idempotencyKey: IdempotencyKey
    public let requestedShot: AssessableShot
    public let originalImage: Data
    public let imageContentType: ImageContentType
    public let normalizationPolicy: ShotAssessmentImageNormalizationPolicy
    public let boundary: MultipartBoundary

    public init(
        requestID: RequestID,
        imageID: ImageID,
        idempotencyKey: IdempotencyKey,
        requestedShot: Shot,
        originalImage: Data,
        imageContentType: ImageContentType,
        boundary: MultipartBoundary,
        normalizationPolicy: ShotAssessmentImageNormalizationPolicy = .preserveHighResolutionOriginal
    ) throws {
        guard let assessableShot = AssessableShot(rawValue: requestedShot.rawValue) else {
            throw ShotAssessmentOperationError.measurementIsNotAssessable
        }
        guard !originalImage.isEmpty else {
            throw ShotAssessmentOperationError.emptyOriginalImage
        }
        self.requestID = requestID
        self.imageID = imageID
        self.idempotencyKey = idempotencyKey
        self.requestedShot = assessableShot
        self.originalImage = originalImage
        self.imageContentType = imageContentType
        self.normalizationPolicy = normalizationPolicy
        self.boundary = boundary
    }
}

public enum ShotAssessmentOperationError: Error, Equatable, Sendable {
    case measurementIsNotAssessable
    case emptyOriginalImage
}

/// Binary-free identity returned with every result so the session owner can
/// reject a superseded image before applying an assessment to a slot.
public struct ShotAssessmentRequestDescriptor: Equatable, Sendable {
    public let requestID: RequestID
    public let imageID: ImageID
    public let requestedShot: AssessableShot
    public let normalizationPolicy: ShotAssessmentImageNormalizationPolicy

    public init(operation: ShotAssessmentOperation) {
        requestID = operation.requestID
        imageID = operation.imageID
        requestedShot = operation.requestedShot
        normalizationPolicy = operation.normalizationPolicy
    }
}

public enum ShotAssessmentFailureReason: Error, Equatable, Sendable {
    case liveEndpointUnavailable
    case timedOut
    case cancelled
    case transport
    case invalidResponse
    case invalidContentType
    case unexpectedStatus(Int)
    case provider(ProviderError)
    case requestedShotMismatch
}

public struct ShotAssessmentFailure: Equatable, Sendable {
    public let descriptor: ShotAssessmentRequestDescriptor
    public let reason: ShotAssessmentFailureReason

    public init(descriptor: ShotAssessmentRequestDescriptor, reason: ShotAssessmentFailureReason) {
        self.descriptor = descriptor
        self.reason = reason
    }
}

public enum ShotAssessmentOutcome: Equatable, Sendable {
    case assessment(ShotAssessmentRequestDescriptor, ShotAssessment)
    case unavailable(ShotAssessmentFailure)
    case failed(ShotAssessmentFailure)
    case discardedAsStale(ShotAssessmentRequestDescriptor)
}

/// State never retains original image bytes or credentials. Provider failures
/// remain session-only typed values; UI must map them to app-owned copy.
public enum ShotAssessmentClientState: Equatable, Sendable {
    case idle(ShotAssessmentServiceAvailability)
    case requesting(ShotAssessmentServiceAvailability, ShotAssessmentRequestDescriptor)
    case assessed(ShotAssessmentServiceAvailability, ShotAssessmentRequestDescriptor, ShotAssessment)
    case unavailable(ShotAssessmentServiceAvailability, ShotAssessmentFailure)
    case failed(ShotAssessmentServiceAvailability, ShotAssessmentFailure)
}

public protocol ShotAssessmentProviding: Sendable {
    func assess(_ operation: ShotAssessmentOperation) async -> ShotAssessmentOutcome
    func cancel(requestID: RequestID) async
}

public protocol ShotAssessmentTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

public struct URLSessionShotAssessmentTransport: ShotAssessmentTransport {
    private let session: URLSession

    public init(session: URLSession) {
        self.session = session
    }

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration)
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

@available(macOS 12.0, iOS 18.0, *)
public actor ShotAssessmentClient: ShotAssessmentProviding {
    private struct ActiveRequest {
        let generation: UInt64
        let descriptor: ShotAssessmentRequestDescriptor
        let task: Task<ShotAssessmentOutcome, Never>
        var cancellationRequested: Bool
    }

    private let backend: BackendAPIClient
    private let transport: any ShotAssessmentTransport
    private let availability: ShotAssessmentServiceAvailability
    private let wireContract: ShotAssessmentWireContract
    private let decoder: JSONDecoder
    private var generation: UInt64 = 0
    private var active: ActiveRequest?
    private var stateStorage: ShotAssessmentClientState

    public init(
        backend: BackendAPIClient,
        transport: any ShotAssessmentTransport = URLSessionShotAssessmentTransport(),
        availability: ShotAssessmentServiceAvailability,
        wireContract: ShotAssessmentWireContract = .frozenSwiftV1,
        decoder: JSONDecoder = .init()
    ) {
        self.backend = backend
        self.transport = transport
        self.availability = availability
        self.wireContract = wireContract
        self.decoder = decoder
        stateStorage = .idle(availability)
    }

    public func stateSnapshot() -> ShotAssessmentClientState { stateStorage }

    public func assess(_ operation: ShotAssessmentOperation) async -> ShotAssessmentOutcome {
        active?.task.cancel()
        active = nil
        generation = nextGeneration()
        let operationGeneration = generation
        let descriptor = ShotAssessmentRequestDescriptor(operation: operation)

        guard availability != .liveUnavailable else {
            let failure = ShotAssessmentFailure(
                descriptor: descriptor,
                reason: .liveEndpointUnavailable
            )
            stateStorage = .unavailable(availability, failure)
            return .unavailable(failure)
        }

        let task = makeTask(for: operation, descriptor: descriptor)
        active = .init(
            generation: operationGeneration,
            descriptor: descriptor,
            task: task,
            cancellationRequested: false
        )
        stateStorage = .requesting(availability, descriptor)

        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }

        guard let current = active, current.generation == operationGeneration else {
            return .discardedAsStale(descriptor)
        }
        active = nil

        let outcome: ShotAssessmentOutcome
        if current.cancellationRequested || Task.isCancelled {
            outcome = .failed(.init(descriptor: descriptor, reason: .cancelled))
        } else {
            outcome = result
        }
        record(outcome)
        return outcome
    }

    public func cancel(requestID: RequestID) async {
        guard var current = active, current.descriptor.requestID == requestID else { return }
        current.cancellationRequested = true
        active = current
        current.task.cancel()
    }

    private func makeTask(
        for operation: ShotAssessmentOperation,
        descriptor: ShotAssessmentRequestDescriptor
    ) -> Task<ShotAssessmentOutcome, Never> {
        let backend = backend
        let transport = transport
        let decoder = decoder
        let wireContract = wireContract
        return Task {
            do {
                let request = try await backend.plannedAnalyzeRequest(
                    shot: operation.requestedShot,
                    data: operation.originalImage,
                    type: operation.imageContentType,
                    boundary: operation.boundary,
                    key: operation.idempotencyKey,
                    imageField: wireContract.imageField
                )
                try Task.checkCancellation()
                let (data, response) = try await transport.data(for: request)
                try Task.checkCancellation()
                return Self.decode(
                    data: data,
                    response: response,
                    descriptor: descriptor,
                    decoder: decoder,
                    wireContract: wireContract
                )
            } catch is CancellationError {
                return .failed(.init(descriptor: descriptor, reason: .cancelled))
            } catch {
                return .failed(.init(
                    descriptor: descriptor,
                    reason: Self.mapTransportError(error)
                ))
            }
        }
    }

    private nonisolated static func decode(
        data: Data,
        response: URLResponse,
        descriptor: ShotAssessmentRequestDescriptor,
        decoder: JSONDecoder,
        wireContract: ShotAssessmentWireContract
    ) -> ShotAssessmentOutcome {
        guard let http = response as? HTTPURLResponse else {
            return .failed(.init(descriptor: descriptor, reason: .invalidResponse))
        }
        guard isJSON(http.value(forHTTPHeaderField: "Content-Type")) else {
            return .failed(.init(descriptor: descriptor, reason: .invalidContentType))
        }
        guard http.statusCode == 200 else {
            guard providerErrorStatusCodes.contains(http.statusCode) else {
                return .failed(.init(
                    descriptor: descriptor,
                    reason: .unexpectedStatus(http.statusCode)
                ))
            }
            guard let error = decodeProviderError(
                data,
                decoder: decoder,
                wireContract: wireContract
            ),
                  error.provider == .shotAssessor else {
                return .failed(.init(descriptor: descriptor, reason: .invalidResponse))
            }
            return .failed(.init(descriptor: descriptor, reason: .provider(error)))
        }
        guard let assessment = try? decoder.decode(ShotAssessment.self, from: data) else {
            return .failed(.init(descriptor: descriptor, reason: .invalidResponse))
        }
        if assessment.quality == .ok,
           (assessment.shotType.rawValue != descriptor.requestedShot.rawValue
               || assessment.missingShots.contains(descriptor.requestedShot)) {
            return .failed(.init(descriptor: descriptor, reason: .requestedShotMismatch))
        }
        return .assessment(descriptor, assessment)
    }

    private nonisolated static let providerErrorStatusCodes: Set<Int> = [
        400, 413, 415, 422, 429, 502, 503, 504,
    ]

    private struct UpstreamProviderErrorEnvelope: Decodable {
        let detail: ProviderError

        private enum CodingKeys: String, CodingKey { case detail }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard Set(container.allKeys) == [.detail] else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "provider error envelope contains unknown fields"
                ))
            }
            detail = try container.decode(ProviderError.self, forKey: .detail)
        }
    }

    private nonisolated static func decodeProviderError(
        _ data: Data,
        decoder: JSONDecoder,
        wireContract: ShotAssessmentWireContract
    ) -> ProviderError? {
        switch wireContract {
        case .frozenSwiftV1:
            try? decoder.decode(ProviderError.self, from: data)
        case .upstreamA25A854:
            try? decoder.decode(UpstreamProviderErrorEnvelope.self, from: data).detail
        }
    }

    private nonisolated static func isJSON(_ contentType: String?) -> Bool {
        contentType?.lowercased().split(separator: ";").first == "application/json"
    }

    private nonisolated static func mapTransportError(_ error: Error) -> ShotAssessmentFailureReason {
        let value = error as NSError
        if value.domain == NSURLErrorDomain, value.code == URLError.timedOut.rawValue {
            return .timedOut
        }
        if value.domain == NSURLErrorDomain, value.code == URLError.cancelled.rawValue {
            return .cancelled
        }
        return .transport
    }

    private func record(_ outcome: ShotAssessmentOutcome) {
        switch outcome {
        case .assessment(let descriptor, let assessment):
            stateStorage = .assessed(availability, descriptor, assessment)
        case .unavailable(let failure):
            stateStorage = .unavailable(availability, failure)
        case .failed(let failure):
            stateStorage = .failed(availability, failure)
        case .discardedAsStale:
            break
        }
    }

    private func nextGeneration() -> UInt64 {
        generation &+= 1
        if generation == 0 { generation = 1 }
        return generation
    }
}
