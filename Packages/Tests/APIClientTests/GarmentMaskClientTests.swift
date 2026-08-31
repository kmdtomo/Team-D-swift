import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import APIClient
@testable import DomainKit

private enum MaskTransportScript: Sendable {
    case response(GarmentMaskHTTPResponse)
    case urlError(URLError.Code)
}

private actor RecordingMaskTransport: GarmentMaskHTTPTransport {
    private var scripts: [MaskTransportScript]
    private var requests: [URLRequest] = []

    init(_ scripts: [MaskTransportScript] = []) {
        self.scripts = scripts
    }

    func send(_ request: URLRequest) async throws -> GarmentMaskHTTPResponse {
        requests.append(request)
        guard !scripts.isEmpty else { throw URLError(.badServerResponse) }
        switch scripts.removeFirst() {
        case .response(let response): return response
        case .urlError(let code): throw URLError(code)
        }
    }

    func requestSnapshot() -> [URLRequest] {
        requests
    }
}

private actor ControlledMaskTransport: GarmentMaskHTTPTransport {
    private var requests: [URLRequest] = []
    private var responseWaiters: [Int: CheckedContinuation<GarmentMaskHTTPResponse, Error>] = [:]
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func send(_ request: URLRequest) async throws -> GarmentMaskHTTPResponse {
        let index = requests.count
        requests.append(request)
        let ready = countWaiters.filter { requests.count >= $0.0 }
        countWaiters.removeAll { requests.count >= $0.0 }
        ready.forEach { $0.1.resume() }
        return try await withCheckedThrowingContinuation { responseWaiters[index] = $0 }
    }

    func waitForRequestCount(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { countWaiters.append((count, $0)) }
    }

    func complete(_ index: Int, with response: GarmentMaskHTTPResponse) {
        responseWaiters.removeValue(forKey: index)?.resume(returning: response)
    }
}

@Suite(.serialized)
struct GarmentMaskClientTests {
    @Test func gateRequiresEveryOriginalAndAnExplicitMeasurementApproval() async throws {
        let transport = RecordingMaskTransport()
        let sut = try makeClient(mode: .contractFixture, transport: transport)
        let front = try frontOriginal()

        for missing in Shot.allCases {
            let context = try sessionContext(missing: missing)
            #expect(
                await sut.requestMask(
                    context: context,
                    front: front,
                    requestID: try RequestID("missing-\(missing.rawValue)"),
                    boundary: try MultipartBoundary("fixed")
                ) == .gateClosed(.missingOriginal(missing))
            )
        }

        let unapproved = try sessionContext(approval: .unapproved)
        #expect(
            await sut.requestMask(
                context: unapproved,
                front: front,
                requestID: try RequestID("unapproved"),
                boundary: try MultipartBoundary("fixed")
            ) == .gateClosed(.measurementNotApproved)
        )
        #expect(
            GarmentMaskClient.gateFailure(
                context: try sessionContext(approval: .approvedCV),
                front: front
            ) == nil
        )
        #expect(
            GarmentMaskClient.gateFailure(
                context: try sessionContext(approval: .approvedManual),
                front: front
            ) == nil
        )

        let wrongFront = GarmentMaskFrontOriginal(
            imageID: try ImageID("different-front"),
            contentType: .png,
            bytes: front.bytes
        )
        #expect(
            await sut.requestMask(
                context: try sessionContext(),
                front: wrongFront,
                requestID: try RequestID("wrong-front"),
                boundary: try MultipartBoundary("fixed")
            ) == .gateClosed(.frontIdentityMismatch)
        )
        let requests = await transport.requestSnapshot()
        #expect(requests.isEmpty)
    }

    @Test func requestContainsOnlyOriginalFrontBytesAndFrozenMultipartMetadata() async throws {
        let original = try frontOriginal()
        let mask = try png(width: 2, height: 1, pixels: [gray(0), gray(255)])
        let transport = RecordingMaskTransport([
            .response(.init(statusCode: 200, contentType: "image/png; charset=binary", body: mask))
        ])
        let sut = try makeClient(mode: .contractFixture, transport: transport)
        let context = try sessionContext(
            imageIDs: [
                .front: original.imageID,
                .back: try ImageID("BACK-ID-SENTINEL"),
                .tag: try ImageID("TAG-ID-SENTINEL"),
                .measurement: try ImageID("MEASUREMENT-ID-SENTINEL"),
            ]
        )

        let outcome = await sut.requestMask(
            context: context,
            front: original,
            requestID: try RequestID("mask-request"),
            boundary: try MultipartBoundary("fixed")
        )
        guard case .validated(let payload) = outcome else {
            Issue.record("expected a validated mask")
            return
        }
        #expect(payload.pngBytes == mask)
        #expect(payload.descriptor.sourceFrontID == original.imageID)

        let requests = await transport.requestSnapshot()
        let request = try #require(requests.first)
        let body = try #require(request.httpBody)
        #expect(request.url?.path == "/api/remove-background")
        #expect(request.httpMethod == "POST")
        #expect(request.timeoutInterval == 35)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(request.value(forHTTPHeaderField: "Accept") == "image/png")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=fixed")
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "mask-request")
        let expectedBody = MultipartForm(boundary: try MultipartBoundary("fixed")).imageBody(
            data: original.bytes,
            contentType: original.contentType
        )
        #expect(body == expectedBody)
        #expect(occurrences(of: Data("name=\"image\"".utf8), in: body) == 1)
        for forbidden in [
            "BACK-ID-SENTINEL", "TAG-ID-SENTINEL", "MEASUREMENT-ID-SENTINEL",
            "requestedShot", "measurement", "mask", "model", "provider", "confidence"
        ] {
            #expect(!body.contains(Data(forbidden.utf8)))
        }
    }

    @Test func validatesPNGDimensionsCoverageAndMaskOnlyPixels() async throws {
        let original = try frontOriginal()
        let invalids: [(GarmentMaskHTTPResponse, GarmentMaskFailureReason)] = [
            (.init(statusCode: 200, contentType: "image/png", body: try png(width: 2, height: 1, pixels: [gray(0), gray(0)])), .emptyMask),
            (.init(statusCode: 200, contentType: "image/png", body: try png(width: 2, height: 1, pixels: [gray(255), gray(255)])), .fullMask),
            (.init(statusCode: 200, contentType: "image/png", body: try png(width: 1, height: 1, pixels: [gray(0)])), .dimensionMismatch),
            (.init(statusCode: 200, contentType: "image/jpeg", body: Data("not-png".utf8)), .nonPNG),
            (.init(statusCode: 200, contentType: "image/png", body: Data("not-png".utf8)), .nonPNG),
            (.init(statusCode: 200, contentType: "image/png", body: try png(width: 2, height: 1, pixels: [(255, 0, 0, 255), gray(0)])), .notMaskOnly),
        ]

        for (index, item) in invalids.enumerated() {
            let transport = RecordingMaskTransport([.response(item.0)])
            let sut = try makeClient(mode: .contractFixture, transport: transport)
            let outcome = await sut.requestMask(
                context: try sessionContext(),
                front: original,
                requestID: try RequestID("invalid-\(index)"),
                boundary: try MultipartBoundary("fixed")
            )
            guard case .failed(_, let failure) = outcome else {
                Issue.record("expected finite invalid-mask failure at index \(index)")
                continue
            }
            #expect(failure.reason == item.1)
            #expect(failure.recoveryActions == [.retry, .useOriginal])
        }
    }

    @Test func timeoutExposesRetryAndOriginalFallbackThenExplicitRetryCanSucceed() async throws {
        let validMask = try png(width: 2, height: 1, pixels: [gray(0), gray(255)])
        let transport = RecordingMaskTransport([
            .urlError(.timedOut),
            .response(.init(statusCode: 200, contentType: "image/png", body: validMask)),
        ])
        let sut = try makeClient(mode: .contractFixture, transport: transport)
        let context = try sessionContext()
        let original = try frontOriginal()
        let requestID = try RequestID("stable-retry")

        let first = await sut.requestMask(
            context: context,
            front: original,
            requestID: requestID,
            boundary: try MultipartBoundary("fixed")
        )
        guard case .failed(_, let failure) = first else {
            Issue.record("expected timeout")
            return
        }
        #expect(failure.reason == .timedOut)
        #expect(failure.recoveryActions == [.retry, .useOriginal])

        let second = await sut.requestMask(
            context: context,
            front: original,
            requestID: requestID,
            boundary: try MultipartBoundary("fixed")
        )
        guard case .validated = second else { Issue.record("expected explicit retry success"); return }
        let requests = await transport.requestSnapshot()
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Idempotency-Key") == "stable-retry" })
    }

    @Test func cancellationReturnsFiniteFailureWithoutCommittingResponseBytes() async throws {
        let validMask = try png(width: 2, height: 1, pixels: [gray(0), gray(255)])
        let transport = ControlledMaskTransport()
        let sut = try makeClient(mode: .contractFixture, transport: transport)
        let requestID = try RequestID("cancel-me")
        let context = try sessionContext()
        let original = try frontOriginal()
        let boundary = try MultipartBoundary("fixed")
        let task = Task {
            await sut.requestMask(
                context: context,
                front: original,
                requestID: requestID,
                boundary: boundary
            )
        }
        await transport.waitForRequestCount(1)
        await sut.cancel(requestID: requestID)
        await transport.complete(0, with: .init(statusCode: 200, contentType: "image/png", body: validMask))

        guard case .failed(_, let failure) = await task.value else {
            Issue.record("expected cancellation")
            return
        }
        #expect(failure.reason == .cancelled)
        #expect(failure.recoveryActions == [.retry, .useOriginal])
    }

    @Test func supersededCompletionIsStaleAndCannotReplaceCurrentState() async throws {
        let validMask = try png(width: 2, height: 1, pixels: [gray(0), gray(255)])
        let transport = ControlledMaskTransport()
        let sut = try makeClient(mode: .contractFixture, transport: transport)
        let context = try sessionContext()
        let original = try frontOriginal()
        let oldRequestID = try RequestID("old")
        let newRequestID = try RequestID("new")
        let oldBoundary = try MultipartBoundary("old-boundary")
        let newBoundary = try MultipartBoundary("new-boundary")
        let first = Task {
            await sut.requestMask(
                context: context,
                front: original,
                requestID: oldRequestID,
                boundary: oldBoundary
            )
        }
        await transport.waitForRequestCount(1)
        let second = Task {
            await sut.requestMask(
                context: context,
                front: original,
                requestID: newRequestID,
                boundary: newBoundary
            )
        }
        await transport.waitForRequestCount(2)
        await transport.complete(1, with: .init(statusCode: 200, contentType: "image/png", body: validMask))
        guard case .validated(let newPayload) = await second.value else {
            Issue.record("expected current request success")
            return
        }
        await transport.complete(0, with: .init(statusCode: 200, contentType: "image/png", body: validMask))
        guard case .stale(let oldDescriptor) = await first.value else {
            Issue.record("expected stale old completion")
            return
        }
        #expect(oldDescriptor.requestID == oldRequestID)
        #expect(
            await sut.stateSnapshot()
                == .validated(.contractFixture, newPayload.descriptor, newPayload.pixelSize)
        )
    }

    @Test func liveUnavailableIsVisibleMakesNoRequestAndNeverFallsBackToFixture() async throws {
        let transport = RecordingMaskTransport([
            .response(.init(
                statusCode: 200,
                contentType: "image/png",
                body: try png(width: 2, height: 1, pixels: [gray(0), gray(255)])
            ))
        ])
        let sut = try makeClient(mode: .live, transport: transport)
        let outcome = await sut.requestMask(
            context: try sessionContext(),
            front: try frontOriginal(),
            requestID: try RequestID("live-unavailable"),
            boundary: try MultipartBoundary("fixed")
        )
        guard case .unavailable(_, let failure) = outcome else {
            Issue.record("expected explicit unavailable result")
            return
        }
        #expect(failure.reason == .unavailable)
        #expect(failure.recoveryActions == [.retry, .useOriginal])
        let requests = await transport.requestSnapshot()
        #expect(requests.isEmpty)
    }

    @Test func failuresRetainCallerSessionMetadataAndClientStateContainsNoImageBytes() async throws {
        let context = try sessionContext()
        let original = try frontOriginal()
        let transport = RecordingMaskTransport([.urlError(.cannotConnectToHost)])
        let sut = try makeClient(mode: .contractFixture, transport: transport)

        let outcome = await sut.requestMask(
            context: context,
            front: original,
            requestID: try RequestID("state-privacy"),
            boundary: try MultipartBoundary("fixed")
        )
        guard case .failed(_, let failure) = outcome else {
            Issue.record("expected transport failure")
            return
        }
        #expect(failure.reason == .transport)
        let expectedContext = try sessionContext()
        #expect(context == expectedContext)
        let state = await sut.stateSnapshot()
        #expect(!containsData(state))
        #expect(!String(reflecting: state).contains(original.bytes.base64EncodedString()))
    }
}

private func makeClient(
    mode: GarmentMaskExecutionMode,
    transport: any GarmentMaskHTTPTransport
) throws -> GarmentMaskClient {
    try GarmentMaskClient(
        baseURL: URL(string: "http://mask.example.test")!,
        mode: mode,
        transport: transport,
        allowsInsecureTestURL: true
    )
}

private func sessionContext(
    approval: MeasurementApproval = .approvedCV,
    missing: Shot? = nil,
    imageIDs: [Shot: ImageID]? = nil
) throws -> GarmentMaskSessionContext {
    var originals = imageIDs ?? [
        .front: try ImageID("front-original"),
        .back: try ImageID("back-original"),
        .tag: try ImageID("tag-original"),
        .measurement: try ImageID("measurement-original"),
    ]
    if let missing { originals[missing] = nil }
    return GarmentMaskSessionContext(
        sessionID: try SessionID("session"),
        originals: originals,
        measurementApproval: approval
    )
}

private func frontOriginal() throws -> GarmentMaskFrontOriginal {
    GarmentMaskFrontOriginal(
        imageID: try ImageID("front-original"),
        contentType: .png,
        bytes: try png(
            width: 2,
            height: 1,
            pixels: [(24, 48, 72, 255), (96, 120, 144, 255)]
        )
    )
}

private func gray(_ value: UInt8) -> (UInt8, UInt8, UInt8, UInt8) {
    (value, value, value, 255)
}

private func png(
    width: Int,
    height: Int,
    pixels: [(UInt8, UInt8, UInt8, UInt8)]
) throws -> Data {
    guard pixels.count == width * height else { throw URLError(.cannotDecodeContentData) }
    var bytes = pixels.flatMap { [$0.0, $0.1, $0.2, $0.3] }
    guard let image = bytes.withUnsafeMutableBytes({ buffer -> CGImage? in
        guard let context = CGContext(
            data: buffer.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            return nil
        }
        return context.makeImage()
    }) else {
        throw URLError(.cannotDecodeContentData)
    }

    guard let output = CFDataCreateMutable(nil, 0),
          let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil)
    else {
        throw URLError(.cannotEncodeContentData)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw URLError(.cannotEncodeContentData)
    }
    return output as Data
}

private func occurrences(of needle: Data, in haystack: Data) -> Int {
    guard !needle.isEmpty else { return 0 }
    var count = 0
    var searchRange = haystack.startIndex ..< haystack.endIndex
    while let range = haystack.range(of: needle, options: [], in: searchRange) {
        count += 1
        searchRange = range.upperBound ..< haystack.endIndex
    }
    return count
}

private func containsData(_ value: Any) -> Bool {
    if value is Data { return true }
    return Mirror(reflecting: value).children.contains { containsData($0.value) }
}
