import CoreGraphics
import Foundation
import ImageIO
import ContractKit
import DomainKit

/// The contract-fixture path is explicit so an unavailable live backend can
/// never be replaced by a successful fixture response at runtime.
public enum GarmentMaskExecutionMode: Equatable, Sendable {
    case contractFixture
    case live
}

public struct GarmentMaskPixelSize: Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// Binary-free session metadata used to enforce the product edit gate.
public struct GarmentMaskSessionContext: Equatable, Sendable {
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

/// The only binary input accepted by the client is the original front image.
public struct GarmentMaskFrontOriginal: Sendable {
    public let imageID: ImageID
    public let contentType: ImageContentType
    public let bytes: Data

    public init(imageID: ImageID, contentType: ImageContentType, bytes: Data) {
        self.imageID = imageID
        self.contentType = contentType
        self.bytes = bytes
    }
}

public enum GarmentMaskGateFailure: Equatable, Sendable {
    case missingOriginal(Shot)
    case measurementNotApproved
    case frontIdentityMismatch
    case invalidFrontImage
    case invalidRequestID
}

public enum GarmentMaskFailureReason: Error, Equatable, Sendable {
    case timedOut
    case cancelled
    case transport
    case unavailable
    case invalidInput
    case invalidResponse
    case nonPNG
    case dimensionMismatch
    case emptyMask
    case fullMask
    case notMaskOnly
}

public enum GarmentMaskRecoveryAction: Hashable, Sendable {
    case retry
    case useOriginal
}

/// Contains only finite UI decisions. Provider prose and user bytes are never retained.
public struct GarmentMaskFailure: Equatable, Sendable {
    public let reason: GarmentMaskFailureReason
    public let recoveryActions: Set<GarmentMaskRecoveryAction>

    public init(reason: GarmentMaskFailureReason, retryable: Bool) {
        self.reason = reason
        recoveryActions = retryable ? [.retry, .useOriginal] : [.useOriginal]
    }
}

public struct GarmentMaskRequestDescriptor: Equatable, Sendable {
    public let requestID: RequestID
    public let sessionID: SessionID
    public let sourceFrontID: ImageID
    public let sourcePixelSize: GarmentMaskPixelSize

    public init(
        requestID: RequestID,
        sessionID: SessionID,
        sourceFrontID: ImageID,
        sourcePixelSize: GarmentMaskPixelSize
    ) {
        self.requestID = requestID
        self.sessionID = sessionID
        self.sourceFrontID = sourceFrontID
        self.sourcePixelSize = sourcePixelSize
    }
}

/// Validated response bytes are returned to the session owner, not retained by this client.
public struct GarmentMaskPayload: Equatable, Sendable {
    public let descriptor: GarmentMaskRequestDescriptor
    public let pixelSize: GarmentMaskPixelSize
    public let pngBytes: Data

    public init(
        descriptor: GarmentMaskRequestDescriptor,
        pixelSize: GarmentMaskPixelSize,
        pngBytes: Data
    ) {
        self.descriptor = descriptor
        self.pixelSize = pixelSize
        self.pngBytes = pngBytes
    }
}

public enum GarmentMaskOutcome: Equatable, Sendable {
    case gateClosed(GarmentMaskGateFailure)
    case unavailable(GarmentMaskRequestDescriptor, GarmentMaskFailure)
    case validated(GarmentMaskPayload)
    case failed(GarmentMaskRequestDescriptor, GarmentMaskFailure)
    /// A superseded completion is observable to its caller but cannot mutate client state.
    case stale(GarmentMaskRequestDescriptor)
}

/// This state is intentionally metadata-only. In particular, it cannot hold image or mask bytes.
public enum GarmentMaskClientState: Equatable, Sendable {
    case idle(GarmentMaskExecutionMode)
    case gateClosed(GarmentMaskExecutionMode, GarmentMaskGateFailure)
    case unavailable(GarmentMaskExecutionMode, GarmentMaskRequestDescriptor, GarmentMaskFailure)
    case requesting(GarmentMaskExecutionMode, GarmentMaskRequestDescriptor)
    case validated(GarmentMaskExecutionMode, GarmentMaskRequestDescriptor, GarmentMaskPixelSize)
    case failed(GarmentMaskExecutionMode, GarmentMaskRequestDescriptor, GarmentMaskFailure)
}

public struct GarmentMaskHTTPResponse: Sendable {
    public let statusCode: Int
    public let contentType: String?
    public let body: Data

    public init(statusCode: Int, contentType: String?, body: Data) {
        self.statusCode = statusCode
        self.contentType = contentType
        self.body = body
    }
}

public protocol GarmentMaskHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> GarmentMaskHTTPResponse
}

/// Production transport with no shared URL cache and no persistent cookie or credential store.
public struct URLSessionGarmentMaskTransport: GarmentMaskHTTPTransport {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> GarmentMaskHTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return GarmentMaskHTTPResponse(
            statusCode: response.statusCode,
            contentType: response.value(forHTTPHeaderField: "Content-Type"),
            body: data
        )
    }
}

@available(macOS 12.0, iOS 18.0, *)
public actor GarmentMaskClient {
    private struct ActiveRequest {
        let generation: UInt64
        let descriptor: GarmentMaskRequestDescriptor
        let task: Task<GarmentMaskHTTPResponse, Error>
        var cancellationRequested: Bool
    }

    private let baseURL: URL
    private let mode: GarmentMaskExecutionMode
    private let transport: any GarmentMaskHTTPTransport
    private var generation: UInt64 = 0
    private var active: ActiveRequest?
    private var state: GarmentMaskClientState

    public init(
        baseURL: URL,
        mode: GarmentMaskExecutionMode,
        transport: any GarmentMaskHTTPTransport = URLSessionGarmentMaskTransport(),
        allowsInsecureTestURL: Bool = false
    ) throws {
        guard baseURL.host != nil,
              baseURL.scheme == "https" || (allowsInsecureTestURL && baseURL.scheme == "http")
        else {
            throw APIClientError.invalidBaseURL
        }
        self.baseURL = baseURL
        self.mode = mode
        self.transport = transport
        state = .idle(mode)
    }

    public func stateSnapshot() -> GarmentMaskClientState {
        state
    }

    public static func gateFailure(
        context: GarmentMaskSessionContext,
        front: GarmentMaskFrontOriginal
    ) -> GarmentMaskGateFailure? {
        for shot in Shot.allCases where context.originals[shot] == nil {
            return .missingOriginal(shot)
        }
        guard context.measurementApproval == .approvedCV
                || context.measurementApproval == .approvedManual
        else {
            return .measurementNotApproved
        }
        guard context.originals[.front] == front.imageID else {
            return .frontIdentityMismatch
        }
        return nil
    }

    public func requestMask(
        context: GarmentMaskSessionContext,
        front: GarmentMaskFrontOriginal,
        requestID: RequestID,
        boundary: MultipartBoundary
    ) async -> GarmentMaskOutcome {
        active?.task.cancel()
        active = nil
        generation &+= 1
        let currentGeneration = generation

        if let failure = Self.gateFailure(context: context, front: front) {
            state = .gateClosed(mode, failure)
            return .gateClosed(failure)
        }

        guard let originalSize = Self.imageSize(front.bytes) else {
            state = .gateClosed(mode, .invalidFrontImage)
            return .gateClosed(.invalidFrontImage)
        }
        guard let idempotencyKey = try? IdempotencyKey(requestID.rawValue) else {
            state = .gateClosed(mode, .invalidRequestID)
            return .gateClosed(.invalidRequestID)
        }

        let descriptor = GarmentMaskRequestDescriptor(
            requestID: requestID,
            sessionID: context.sessionID,
            sourceFrontID: front.imageID,
            sourcePixelSize: originalSize
        )

        guard mode == .contractFixture || BackendEndpoint.removeBackground.availability == .available else {
            let failure = GarmentMaskFailure(reason: .unavailable, retryable: true)
            state = .unavailable(mode, descriptor, failure)
            return .unavailable(descriptor, failure)
        }

        let request = makeRequest(
            front: front,
            boundary: boundary,
            idempotencyKey: idempotencyKey
        )

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
            return recordFailure(.cancelled, retryable: true, descriptor: descriptor)
        }

        switch result {
        case .success(let response):
            return handle(response, descriptor: descriptor, originalSize: originalSize)
        case .failure(let error):
            if error is CancellationError {
                return recordFailure(.cancelled, retryable: true, descriptor: descriptor)
            }
            let value = error as NSError
            if value.domain == NSURLErrorDomain && value.code == URLError.cancelled.rawValue {
                return recordFailure(.cancelled, retryable: true, descriptor: descriptor)
            }
            if value.domain == NSURLErrorDomain && value.code == URLError.timedOut.rawValue {
                return recordFailure(.timedOut, retryable: true, descriptor: descriptor)
            }
            return recordFailure(.transport, retryable: true, descriptor: descriptor)
        }
    }

    public func cancel(requestID: RequestID) {
        guard var current = active, current.descriptor.requestID == requestID else { return }
        current.cancellationRequested = true
        current.task.cancel()
        active = current
    }

    private func makeRequest(
        front: GarmentMaskFrontOriginal,
        boundary: MultipartBoundary,
        idempotencyKey: IdempotencyKey
    ) -> URLRequest {
        let url = baseURL.appendingPathComponent(String(BackendEndpoint.removeBackground.path.dropFirst()))
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: BackendEndpoint.removeBackground.timeout
        )
        request.httpMethod = HTTPMethod.post.rawValue
        request.setValue("image/png", forHTTPHeaderField: "Accept")
        request.setValue(
            "multipart/form-data; boundary=\(boundary.value)",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(idempotencyKey.value, forHTTPHeaderField: "Idempotency-Key")
        request.httpBody = MultipartForm(boundary: boundary).imageBody(
            data: front.bytes,
            contentType: front.contentType
        )
        return request
    }

    private func handle(
        _ response: GarmentMaskHTTPResponse,
        descriptor: GarmentMaskRequestDescriptor,
        originalSize: GarmentMaskPixelSize
    ) -> GarmentMaskOutcome {
        guard response.statusCode == 200 else {
            guard let providerError = try? JSONDecoder().decode(ProviderError.self, from: response.body),
                  providerError.provider == .garmentMasker
            else {
                return recordFailure(.invalidResponse, retryable: true, descriptor: descriptor)
            }
            let reason = Self.failureReason(for: providerError.code)
            if reason == .unavailable {
                let failure = GarmentMaskFailure(reason: reason, retryable: providerError.retryable)
                state = .unavailable(mode, descriptor, failure)
                return .unavailable(descriptor, failure)
            }
            return recordFailure(reason, retryable: providerError.retryable, descriptor: descriptor)
        }

        guard Self.normalizedContentType(response.contentType) == "image/png" else {
            return recordFailure(.nonPNG, retryable: true, descriptor: descriptor)
        }

        do {
            let size = try Self.validateMask(response.body, expectedSize: originalSize)
            let payload = GarmentMaskPayload(
                descriptor: descriptor,
                pixelSize: size,
                pngBytes: response.body
            )
            state = .validated(mode, descriptor, size)
            return .validated(payload)
        } catch let failure as GarmentMaskFailureReason {
            return recordFailure(failure, retryable: true, descriptor: descriptor)
        } catch {
            return recordFailure(.invalidResponse, retryable: true, descriptor: descriptor)
        }
    }

    private func recordFailure(
        _ reason: GarmentMaskFailureReason,
        retryable: Bool,
        descriptor: GarmentMaskRequestDescriptor
    ) -> GarmentMaskOutcome {
        let failure = GarmentMaskFailure(reason: reason, retryable: retryable)
        state = .failed(mode, descriptor, failure)
        return .failed(descriptor, failure)
    }

    private static func failureReason(for code: ProviderErrorCode) -> GarmentMaskFailureReason {
        switch code {
        case .timeout: .timedOut
        case .unavailable: .unavailable
        case .invalidInput: .invalidInput
        case .invalidResponse, .unknown: .invalidResponse
        }
    }

    private static func normalizedContentType(_ value: String?) -> String? {
        value?
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func imageSize(_ data: Data) -> GarmentMaskPixelSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0,
              image.height > 0
        else {
            return nil
        }
        return GarmentMaskPixelSize(width: image.width, height: image.height)
    }

    private static func validateMask(
        _ data: Data,
        expectedSize: GarmentMaskPixelSize
    ) throws -> GarmentMaskPixelSize {
        let pngSignature = Data([137, 80, 78, 71, 13, 10, 26, 10])
        guard data.starts(with: pngSignature),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let sourceType = CGImageSourceGetType(source),
              (sourceType as String) == "public.png",
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw GarmentMaskFailureReason.nonPNG
        }

        let actualSize = GarmentMaskPixelSize(width: image.width, height: image.height)
        guard actualSize == expectedSize else {
            throw GarmentMaskFailureReason.dimensionMismatch
        }

        let (pixelCount, pixelOverflow) = image.width.multipliedReportingOverflow(by: image.height)
        let (byteCount, byteOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        guard !pixelOverflow, !byteOverflow, pixelCount > 0, byteCount > 0 else {
            throw GarmentMaskFailureReason.invalidResponse
        }

        var pixels = [UInt8](repeating: 0, count: byteCount)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard rendered else {
            throw GarmentMaskFailureReason.invalidResponse
        }

        var alphaMinimum = UInt8.max
        var alphaMaximum = UInt8.min

        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let red = pixels[offset]
            let green = pixels[offset + 1]
            let blue = pixels[offset + 2]
            let alpha = pixels[offset + 3]
            guard red == green, green == blue else {
                throw GarmentMaskFailureReason.notMaskOnly
            }
            alphaMinimum = min(alphaMinimum, alpha)
            alphaMaximum = max(alphaMaximum, alpha)
        }

        if alphaMaximum == 0 {
            throw GarmentMaskFailureReason.emptyMask
        }

        let useAlphaChannel = alphaMinimum != alphaMaximum
        var hasForeground = false
        var hasBackground = false
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let value = useAlphaChannel ? pixels[offset + 3] : pixels[offset]
            hasForeground = hasForeground || value > 0
            hasBackground = hasBackground || value == 0
            if hasForeground && hasBackground { break }
        }

        guard hasForeground else {
            throw GarmentMaskFailureReason.emptyMask
        }
        guard hasBackground else {
            throw GarmentMaskFailureReason.fullMask
        }
        return actualSize
    }
}
