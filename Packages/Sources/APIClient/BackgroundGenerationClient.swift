import ContractKit
import CoreGraphics
import DomainKit
import Foundation
import ImageIO

/// Contract fixtures may exercise the frozen route without turning an
/// unavailable live endpoint into fixture success.
public enum BackgroundGenerationExecutionMode: Equatable, Sendable {
    case contractFixture
    case live
}

public struct BackgroundGenerationPixelSize: Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// Metadata-only snapshot of the caller-owned capture progress. The client
/// never accepts or retains original, mask, tag, or measurement bytes.
public struct BackgroundGenerationSessionContext: Equatable, Sendable {
    public let sessionID: SessionID
    public let originals: [Shot: ImageID]
    public let measurementApproval: MeasurementApproval

    public init(
        sessionID: SessionID,
        originals: [Shot: ImageID],
        measurementApproval: MeasurementApproval
    ) {
        self.sessionID = sessionID
        self.originals = originals
        self.measurementApproval = measurementApproval
    }

    public init(snapshot: CaptureSessionSnapshot) {
        self.init(
            sessionID: snapshot.sessionID,
            originals: snapshot.originals,
            measurementApproval: snapshot.measurementApproval
        )
    }
}

public enum BackgroundGenerationGateFailure: Equatable, Sendable {
    case missingOriginal(Shot)
    case measurementNotApproved
    case unknownStyleID
    case invalidRequestID
}

public struct BackgroundGenerationRequestDescriptor: Equatable, Sendable {
    public let requestID: RequestID
    public let session: BackgroundGenerationSessionContext
    public let style: BackgroundStyleID
    public let fixedPromptVersion: String

    public init(
        requestID: RequestID,
        session: BackgroundGenerationSessionContext,
        style: BackgroundStyleID,
        fixedPromptVersion: String
    ) {
        self.requestID = requestID
        self.session = session
        self.style = style
        self.fixedPromptVersion = fixedPromptVersion
    }
}

public enum BackgroundGenerationFailureReason: Error, Equatable, Sendable {
    case liveEndpointUnavailable
    case timedOut
    case cancelled
    case transport
    case requestConstruction
    case invalidContentType
    case unexpectedStatus(Int)
    case invalidProviderError(Int)
    case provider(ProviderErrorCode)
    case nonPNG
    case invalidImage
    case transparentImage
    case imageTooLarge
}

public enum BackgroundRetryDisposition: Equatable, Sendable {
    case sameRequestIdentity
    case disallowed
    case awaitLiveEndpointAvailability
}

public struct BackgroundGenerationRecovery: Equatable, Sendable {
    public let retry: BackgroundRetryDisposition
    public let fixedBackground: BackgroundFixedAssetSelection

    public init(
        retry: BackgroundRetryDisposition,
        fixedBackground: BackgroundFixedAssetSelection
    ) {
        self.retry = retry
        self.fixedBackground = fixedBackground
    }
}

/// Provider prose and response bytes are intentionally excluded from failures.
public struct BackgroundGenerationFailure: Equatable, Sendable {
    public let reason: BackgroundGenerationFailureReason
    public let recovery: BackgroundGenerationRecovery

    public init(
        reason: BackgroundGenerationFailureReason,
        retry: BackgroundRetryDisposition,
        fixedBackground: BackgroundFixedAssetSelection
    ) {
        self.reason = reason
        recovery = BackgroundGenerationRecovery(
            retry: retry,
            fixedBackground: fixedBackground
        )
    }
}

/// Validated response bytes are handed to the session owner and are never kept
/// in the actor's state.
public struct BackgroundGenerationPayload: Equatable, Sendable {
    public let descriptor: BackgroundGenerationRequestDescriptor
    public let pixelSize: BackgroundGenerationPixelSize
    public let pngBytes: Data

    public init(
        descriptor: BackgroundGenerationRequestDescriptor,
        pixelSize: BackgroundGenerationPixelSize,
        pngBytes: Data
    ) {
        self.descriptor = descriptor
        self.pixelSize = pixelSize
        self.pngBytes = pngBytes
    }
}

public enum BackgroundGenerationOutcome: Equatable, Sendable {
    case gateClosed(BackgroundGenerationGateFailure)
    case unavailable(BackgroundGenerationRequestDescriptor, BackgroundGenerationFailure)
    case validated(BackgroundGenerationPayload)
    case failed(BackgroundGenerationRequestDescriptor, BackgroundGenerationFailure)
    case stale(BackgroundGenerationRequestDescriptor)
}

/// Actor state is metadata-only and cannot retain generated or source pixels.
public enum BackgroundGenerationClientState: Equatable, Sendable {
    case idle(BackgroundGenerationExecutionMode)
    case gateClosed(BackgroundGenerationExecutionMode, BackgroundGenerationGateFailure)
    case unavailable(
        BackgroundGenerationExecutionMode,
        BackgroundGenerationRequestDescriptor,
        BackgroundGenerationFailure
    )
    case requesting(BackgroundGenerationExecutionMode, BackgroundGenerationRequestDescriptor)
    case validated(
        BackgroundGenerationExecutionMode,
        BackgroundGenerationRequestDescriptor,
        BackgroundGenerationPixelSize
    )
    case failed(
        BackgroundGenerationExecutionMode,
        BackgroundGenerationRequestDescriptor,
        BackgroundGenerationFailure
    )
}

public struct BackgroundGenerationHTTPResponse: Sendable {
    public let statusCode: Int
    public let contentType: String?
    public let body: Data

    public init(statusCode: Int, contentType: String?, body: Data) {
        self.statusCode = statusCode
        self.contentType = contentType
        self.body = body
    }
}

public protocol BackgroundGenerationHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> BackgroundGenerationHTTPResponse
}

/// Production transport keeps generated intermediates out of shared caches,
/// cookies, and credential storage.
public struct URLSessionBackgroundGenerationTransport: BackgroundGenerationHTTPTransport {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> BackgroundGenerationHTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return BackgroundGenerationHTTPResponse(
            statusCode: response.statusCode,
            contentType: response.value(forHTTPHeaderField: "Content-Type"),
            body: data
        )
    }
}

@available(macOS 12.0, iOS 18.0, *)
public actor BackgroundGenerationClient {
    private struct ActiveRequest {
        let generation: UInt64
        let descriptor: BackgroundGenerationRequestDescriptor
        let task: Task<BackgroundGenerationHTTPResponse, Error>
        var cancellationRequested: Bool
    }

    private let backend: BackendAPIClient
    private let mode: BackgroundGenerationExecutionMode
    private let transport: any BackgroundGenerationHTTPTransport
    private let policy: BackgroundStylePolicy
    private let endpointAvailability: EndpointAvailability
    private let decoder: JSONDecoder
    private var generation: UInt64 = 0
    private var active: ActiveRequest?
    private var state: BackgroundGenerationClientState

    public init(
        backend: BackendAPIClient,
        mode: BackgroundGenerationExecutionMode,
        transport: any BackgroundGenerationHTTPTransport = URLSessionBackgroundGenerationTransport(),
        policy: BackgroundStylePolicy = .init(),
        endpointAvailability: EndpointAvailability = BackendEndpoint.generateBackground.availability,
        decoder: JSONDecoder = .init()
    ) {
        self.backend = backend
        self.mode = mode
        self.transport = transport
        self.policy = policy
        self.endpointAvailability = endpointAvailability
        self.decoder = decoder
        state = .idle(mode)
    }

    public func stateSnapshot() -> BackgroundGenerationClientState {
        state
    }

    public static func gateFailure(
        context: BackgroundGenerationSessionContext
    ) -> BackgroundGenerationGateFailure? {
        for shot in Shot.allCases where context.originals[shot] == nil {
            return .missingOriginal(shot)
        }
        guard
            context.measurementApproval == .approvedCV
                || context.measurementApproval == .approvedManual
        else {
            return .measurementNotApproved
        }
        return nil
    }

    public func generate(
        context: BackgroundGenerationSessionContext,
        rawStyleID: String,
        requestID: RequestID
    ) async -> BackgroundGenerationOutcome {
        active?.task.cancel()
        active = nil
        generation &+= 1
        let currentGeneration = generation

        if let failure = Self.gateFailure(context: context) {
            state = .gateClosed(mode, failure)
            return .gateClosed(failure)
        }

        let style: BackgroundStyleID
        do {
            style = try policy.resolve(rawStyleID)
        } catch {
            let failure = BackgroundGenerationGateFailure.unknownStyleID
            state = .gateClosed(mode, failure)
            return .gateClosed(failure)
        }

        guard let idempotencyKey = try? IdempotencyKey(requestID.rawValue) else {
            state = .gateClosed(mode, .invalidRequestID)
            return .gateClosed(.invalidRequestID)
        }

        let descriptor = BackgroundGenerationRequestDescriptor(
            requestID: requestID,
            session: context,
            style: style,
            fixedPromptVersion: policy.fixedPrompt.version
        )

        guard
            mode == .contractFixture
                || endpointAvailability == .available
        else {
            let failure = BackgroundGenerationFailure(
                reason: .liveEndpointUnavailable,
                retry: .awaitLiveEndpointAvailability,
                fixedBackground: policy.fixedBackground
            )
            state = .unavailable(mode, descriptor, failure)
            return .unavailable(descriptor, failure)
        }

        let request: URLRequest
        do {
            let wire = try policy.wireRequest(for: style)
            var planned = try await backend.plannedBackgroundRequest(wire, key: idempotencyKey)
            planned.cachePolicy = .reloadIgnoringLocalCacheData
            request = planned
        } catch {
            return recordFailure(
                .requestConstruction,
                retry: .disallowed,
                descriptor: descriptor
            )
        }

        let transport = transport
        let task = Task {
            try Task.checkCancellation()
            let response = try await transport.send(request)
            try Task.checkCancellation()
            return response
        }
        active = ActiveRequest(
            generation: currentGeneration,
            descriptor: descriptor,
            task: task,
            cancellationRequested: false
        )
        state = .requesting(mode, descriptor)

        let result = await withTaskCancellationHandler {
            await task.result
        } onCancel: {
            task.cancel()
        }

        guard let current = active, current.generation == currentGeneration else {
            return .stale(descriptor)
        }
        active = nil

        if current.cancellationRequested || Task.isCancelled {
            return recordFailure(
                .cancelled,
                retry: .sameRequestIdentity,
                descriptor: descriptor
            )
        }

        switch result {
        case .success(let response):
            return handle(response, descriptor: descriptor)
        case .failure(let error):
            if error is CancellationError {
                return recordFailure(
                    .cancelled,
                    retry: .sameRequestIdentity,
                    descriptor: descriptor
                )
            }
            let value = error as NSError
            if value.domain == NSURLErrorDomain && value.code == URLError.cancelled.rawValue {
                return recordFailure(
                    .cancelled,
                    retry: .sameRequestIdentity,
                    descriptor: descriptor
                )
            }
            if value.domain == NSURLErrorDomain && value.code == URLError.timedOut.rawValue {
                return recordFailure(
                    .timedOut,
                    retry: .sameRequestIdentity,
                    descriptor: descriptor
                )
            }
            return recordFailure(
                .transport,
                retry: .sameRequestIdentity,
                descriptor: descriptor
            )
        }
    }

    public func cancel(requestID: RequestID) {
        guard var current = active, current.descriptor.requestID == requestID else { return }
        current.cancellationRequested = true
        current.task.cancel()
        active = current
    }

    private func handle(
        _ response: BackgroundGenerationHTTPResponse,
        descriptor: BackgroundGenerationRequestDescriptor
    ) -> BackgroundGenerationOutcome {
        if response.statusCode != 200 {
            let documentedErrorStatuses: Set<Int> = [400, 415, 422, 429, 502, 503, 504]
            guard documentedErrorStatuses.contains(response.statusCode) else {
                return recordFailure(
                    .unexpectedStatus(response.statusCode),
                    retry: .disallowed,
                    descriptor: descriptor
                )
            }
            guard Self.normalizedContentType(response.contentType) == "application/json" else {
                return recordFailure(
                    .invalidContentType,
                    retry: .disallowed,
                    descriptor: descriptor
                )
            }
            guard let providerError = try? decoder.decode(ProviderError.self, from: response.body),
                providerError.provider == .backgroundGenerator
            else {
                return recordFailure(
                    .invalidProviderError(response.statusCode),
                    retry: .disallowed,
                    descriptor: descriptor
                )
            }
            return recordFailure(
                .provider(providerError.code),
                retry: providerError.retryable ? .sameRequestIdentity : .disallowed,
                descriptor: descriptor
            )
        }

        guard Self.normalizedContentType(response.contentType) == "image/png" else {
            return recordFailure(
                .invalidContentType,
                retry: .disallowed,
                descriptor: descriptor
            )
        }

        do {
            let size = try Self.validateBackgroundPNG(response.body)
            let payload = BackgroundGenerationPayload(
                descriptor: descriptor,
                pixelSize: size,
                pngBytes: response.body
            )
            state = .validated(mode, descriptor, size)
            return .validated(payload)
        } catch let reason as BackgroundGenerationFailureReason {
            return recordFailure(
                reason,
                retry: .sameRequestIdentity,
                descriptor: descriptor
            )
        } catch {
            return recordFailure(
                .invalidImage,
                retry: .sameRequestIdentity,
                descriptor: descriptor
            )
        }
    }

    private func recordFailure(
        _ reason: BackgroundGenerationFailureReason,
        retry: BackgroundRetryDisposition,
        descriptor: BackgroundGenerationRequestDescriptor
    ) -> BackgroundGenerationOutcome {
        let failure = BackgroundGenerationFailure(
            reason: reason,
            retry: retry,
            fixedBackground: policy.fixedBackground
        )
        state = .failed(mode, descriptor, failure)
        return .failed(descriptor, failure)
    }

    private nonisolated static func normalizedContentType(_ value: String?) -> String? {
        value?
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private nonisolated static func validateBackgroundPNG(
        _ data: Data
    ) throws -> BackgroundGenerationPixelSize {
        let pngSignature = Data([137, 80, 78, 71, 13, 10, 26, 10])
        guard data.starts(with: pngSignature) else {
            throw BackgroundGenerationFailureReason.nonPNG
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) == 1,
            let sourceType = CGImageSourceGetType(source),
            (sourceType as String) == "public.png",
            CGImageSourceGetStatus(source) == .statusComplete,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0,
            height > 0
        else {
            throw BackgroundGenerationFailureReason.invalidImage
        }

        let maximumDimension = 4_096
        guard width <= maximumDimension, height <= maximumDimension else {
            throw BackgroundGenerationFailureReason.imageTooLarge
        }
        let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (byteCount, byteOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        guard !pixelOverflow,
            !byteOverflow,
            (1...16_777_216).contains(pixelCount),
            byteCount > 0
        else {
            throw BackgroundGenerationFailureReason.imageTooLarge
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
            CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
            image.width == width,
            image.height == height
        else {
            throw BackgroundGenerationFailureReason.invalidImage
        }

        var pixels = [UInt8](repeating: 0, count: byteCount)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress,
                    width: image.width,
                    height: image.height,
                    bitsPerComponent: 8,
                    bytesPerRow: image.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue
                )
            else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard rendered else {
            throw BackgroundGenerationFailureReason.invalidImage
        }
        guard stride(from: 3, to: pixels.count, by: 4).allSatisfy({ pixels[$0] == 255 }) else {
            throw BackgroundGenerationFailureReason.transparentImage
        }

        return BackgroundGenerationPixelSize(width: image.width, height: image.height)
    }
}
