import Foundation
import ContractKit

/// The shared backend has not implemented this endpoint yet. Fixture callers may
/// exercise the frozen wire contract, while live callers receive a typed blocker
/// and never fall back to fixtures.
public enum MeasurementPointServiceAvailability: Equatable, Sendable {
    case fixtureContract
    case liveUnavailable
}

public enum MeasurementPointFallbackReason: Equatable, Sendable {
    case liveEndpointUnavailable
    case timedOut
    case cancelled
    case invalidResponse
    case invalidContentType
    case invalidCoordinates
    case provider(ProviderError)
    case unexpectedStatus(Int)
    case transport
}

public enum MeasurementPointFallbackPlacement: Equatable, Sendable {
    case contourOrUserPlacement
}

/// This state deliberately contains identity and scale references only. Corrected
/// image bytes remain an input to the request and are never retained by the client.
public struct MeasurementPointFallback: Equatable, Sendable {
    public let imageID: String
    public let scaleID: String
    public let reason: MeasurementPointFallbackReason
    public let placement: MeasurementPointFallbackPlacement

    public init(imageID: String, scaleID: String, reason: MeasurementPointFallbackReason) {
        self.imageID = imageID
        self.scaleID = scaleID
        self.reason = reason
        self.placement = .contourOrUserPlacement
    }
}

public enum MeasurementPointOutcome: Equatable, Sendable {
    case points(imageID: String, scaleID: String, endpoints: MeasurementEndpoints)
    case fallback(MeasurementPointFallback)
    case discardedAsStale(imageID: String)
}

public struct MeasurementPointOperation: Sendable {
    public let imageID: String
    public let correctedImage: Data
    public let imageContentType: ImageContentType
    public let scaleID: String
    public let boundary: MultipartBoundary
    public let idempotencyKey: IdempotencyKey

    public init(
        imageID: String,
        correctedImage: Data,
        imageContentType: ImageContentType,
        scaleID: String,
        boundary: MultipartBoundary,
        idempotencyKey: IdempotencyKey
    ) throws {
        guard !imageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !scaleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !correctedImage.isEmpty else {
            throw APIClientError.invalidResponse
        }
        self.imageID = imageID
        self.correctedImage = correctedImage
        self.imageContentType = imageContentType
        self.scaleID = scaleID
        self.boundary = boundary
        self.idempotencyKey = idempotencyKey
    }
}

public protocol MeasurementPointTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

public struct URLSessionMeasurementPointTransport: MeasurementPointTransport {
    private let session: URLSession

    public init(session: URLSession) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

@available(macOS 12.0, iOS 18.0, *)
public actor MeasurementPointClient {
    private let backend: BackendAPIClient
    private let transport: any MeasurementPointTransport
    private let availability: MeasurementPointServiceAvailability
    private let decoder: JSONDecoder
    private var inFlight: [String: Task<MeasurementPointOutcome, Never>] = [:]
    private var completed: [String: MeasurementPointOutcome] = [:]
    private var currentImageID: String?
    private var currentOutcome: MeasurementPointOutcome?

    public init(
        backend: BackendAPIClient,
        transport: any MeasurementPointTransport,
        availability: MeasurementPointServiceAvailability,
        decoder: JSONDecoder = .init()
    ) {
        self.backend = backend
        self.transport = transport
        self.availability = availability
        self.decoder = decoder
    }

    public func latestOutcome() -> MeasurementPointOutcome? {
        currentOutcome
    }

    public func suggest(for operation: MeasurementPointOperation) async -> MeasurementPointOutcome {
        currentImageID = operation.imageID

        guard availability == .fixtureContract else {
            let outcome = Self.fallback(for: operation, reason: .liveEndpointUnavailable)
            currentOutcome = outcome
            completed[operation.imageID] = outcome
            return outcome
        }

        if let completed = completed[operation.imageID] {
            return apply(completed, for: operation.imageID)
        }

        let task: Task<MeasurementPointOutcome, Never>
        if let existing = inFlight[operation.imageID] {
            task = existing
        } else {
            task = makeTask(for: operation)
            inFlight[operation.imageID] = task
        }

        let result = await withTaskCancellationHandler(operation: {
            let value = await task.value
            if Task.isCancelled {
                return Self.fallback(for: operation, reason: .cancelled)
            }
            return value
        }, onCancel: {
            task.cancel()
        })
        inFlight[operation.imageID] = nil
        completed[operation.imageID] = result
        return apply(result, for: operation.imageID)
    }

    public func cancel(imageID: String) {
        inFlight[imageID]?.cancel()
    }

    private func apply(_ outcome: MeasurementPointOutcome, for imageID: String) -> MeasurementPointOutcome {
        guard currentImageID == imageID else {
            return .discardedAsStale(imageID: imageID)
        }
        currentOutcome = outcome
        return outcome
    }

    private func makeTask(for operation: MeasurementPointOperation) -> Task<MeasurementPointOutcome, Never> {
        let backend = backend
        let transport = transport
        let decoder = decoder
        return Task {
            do {
                let request = try await backend.plannedMeasurementRequest(
                    data: operation.correctedImage,
                    type: operation.imageContentType,
                    boundary: operation.boundary,
                    key: operation.idempotencyKey
                )
                let (data, response) = try await transport.data(for: request)
                return Self.decode(data: data, response: response, operation: operation, decoder: decoder)
            } catch is CancellationError {
                return Self.fallback(for: operation, reason: .cancelled)
            } catch {
                return Self.fallback(for: operation, reason: Self.mapTransportError(error))
            }
        }
    }

    private nonisolated static func decode(
        data: Data,
        response: URLResponse,
        operation: MeasurementPointOperation,
        decoder: JSONDecoder
    ) -> MeasurementPointOutcome {
        guard let http = response as? HTTPURLResponse else {
            return fallback(for: operation, reason: .invalidResponse)
        }
        guard http.statusCode == 200 else {
            guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased().split(separator: ";").first == "application/json" else {
                return fallback(for: operation, reason: .invalidContentType)
            }
            guard let providerError = try? decoder.decode(ProviderError.self, from: data),
                  providerError.provider == .measurementLine else {
                return fallback(for: operation, reason: .unexpectedStatus(http.statusCode))
            }
            return fallback(for: operation, reason: .provider(providerError))
        }
        guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased().split(separator: ";").first == "application/json" else {
            return fallback(for: operation, reason: .invalidContentType)
        }
        do {
            let endpoints = try decoder.decode(MeasurementEndpoints.self, from: data)
            return .points(imageID: operation.imageID, scaleID: operation.scaleID, endpoints: endpoints)
        } catch let error as WireValidationError {
            switch error {
            case .invalidValue:
                return fallback(for: operation, reason: .invalidCoordinates)
            case .unknownKey:
                return fallback(for: operation, reason: .invalidResponse)
            }
        } catch {
            return fallback(for: operation, reason: .invalidResponse)
        }
    }

    private nonisolated static func mapTransportError(_ error: Error) -> MeasurementPointFallbackReason {
        let value = error as NSError
        if value.domain == NSURLErrorDomain && value.code == URLError.timedOut.rawValue { return .timedOut }
        if value.domain == NSURLErrorDomain && value.code == URLError.cancelled.rawValue { return .cancelled }
        return .transport
    }

    private nonisolated static func fallback(for operation: MeasurementPointOperation, reason: MeasurementPointFallbackReason) -> MeasurementPointOutcome {
        .fallback(MeasurementPointFallback(imageID: operation.imageID, scaleID: operation.scaleID, reason: reason))
    }
}
