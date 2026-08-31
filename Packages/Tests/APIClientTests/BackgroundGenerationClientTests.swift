import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import APIClient
@testable import DomainKit

private enum BackgroundTransportScript: Sendable {
    case response(BackgroundGenerationHTTPResponse)
    case urlError(URLError.Code)
}

private actor RecordingBackgroundTransport: BackgroundGenerationHTTPTransport {
    private var scripts: [BackgroundTransportScript]
    private var requests: [URLRequest] = []

    init(_ scripts: [BackgroundTransportScript] = []) {
        self.scripts = scripts
    }

    func send(_ request: URLRequest) async throws -> BackgroundGenerationHTTPResponse {
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

private actor ControlledBackgroundTransport: BackgroundGenerationHTTPTransport {
    private var requests: [URLRequest] = []
    private var responseWaiters: [Int: CheckedContinuation<BackgroundGenerationHTTPResponse, Error>] = [:]
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func send(_ request: URLRequest) async throws -> BackgroundGenerationHTTPResponse {
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

    func complete(_ index: Int, with response: BackgroundGenerationHTTPResponse) {
        responseWaiters.removeValue(forKey: index)?.resume(returning: response)
    }
}

@Suite(.serialized)
struct BackgroundStylePolicyTests {
    @Test func onlyFrozenStyleIsAllowedAndWireRequestContainsNoPromptOrBinaryFields() throws {
        let policy = BackgroundStylePolicy()
        #expect(BackgroundStyleID.allCases == [.cleanWhite])
        #expect(try policy.resolve("clean-white") == .cleanWhite)
        #expect(throws: BackgroundStylePolicyError.unknownStyleID) {
            try policy.resolve("custom")
        }
        #expect(throws: BackgroundStylePolicyError.unknownStyleID) {
            try policy.resolve(" clean-white ")
        }

        let body = try JSONEncoder().encode(policy.wireRequest(for: .cleanWhite))
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object.keys.sorted() == ["styleId"])
        #expect(object["styleId"] as? String == "clean-white")
        for forbidden in ["prompt", "image", "product", "mask", "tag", "measurement"] {
            #expect(object[forbidden] == nil)
        }
    }

    @Test func fixedPromptContractExcludesEveryForbiddenSubjectAndNoUnlicensedAssetIsSelectable() {
        let policy = BackgroundStylePolicy()
        #expect(policy.fixedPrompt.version == "empty-product-photography-background-v1")
        #expect(policy.fixedPrompt.purpose == "empty-product-photography-background")
        #expect(policy.fixedPrompt.excludedSubjects == Set(BackgroundPromptExcludedSubject.allCases))
        #expect(
            policy.fixedPrompt.excludedSubjects
                == [.product, .person, .garment, .hanger, .text, .logo]
        )
        #expect(
            policy.fixedBackground
                == .unavailable(.noLicenseConfirmedRepositoryAsset)
        )
        #expect(!policy.fixedBackground.isSelectable)
        #expect(policy.fixedBackground.descriptor == nil)
    }

    @Test func licenseConfirmedSelectionRequiresStableAssetAndEvidenceMetadata() throws {
        let descriptor = try verifiedFixedBackgroundDescriptor()
        let selection = BackgroundFixedAssetSelection.licenseConfirmed(descriptor)
        #expect(selection.isSelectable)
        #expect(selection.descriptor == descriptor)
        #expect(throws: BackgroundFixedAssetDescriptorError.invalidAssetID) {
            try BackgroundFixedAssetDescriptor(
                assetID: "not stable",
                repositoryRelativePath: descriptor.repositoryRelativePath,
                sha256: descriptor.sha256,
                licenseEvidenceID: descriptor.licenseEvidenceID,
                inventoryEvidenceID: descriptor.inventoryEvidenceID
            )
        }
        #expect(throws: BackgroundFixedAssetDescriptorError.invalidRepositoryRelativePath) {
            try BackgroundFixedAssetDescriptor(
                assetID: descriptor.assetID,
                repositoryRelativePath: "../untracked.png",
                sha256: descriptor.sha256,
                licenseEvidenceID: descriptor.licenseEvidenceID,
                inventoryEvidenceID: descriptor.inventoryEvidenceID
            )
        }
        #expect(throws: BackgroundFixedAssetDescriptorError.invalidSHA256) {
            try BackgroundFixedAssetDescriptor(
                assetID: descriptor.assetID,
                repositoryRelativePath: descriptor.repositoryRelativePath,
                sha256: "not-a-sha256",
                licenseEvidenceID: descriptor.licenseEvidenceID,
                inventoryEvidenceID: descriptor.inventoryEvidenceID
            )
        }
        #expect(throws: BackgroundFixedAssetDescriptorError.invalidLicenseEvidenceID) {
            try BackgroundFixedAssetDescriptor(
                assetID: descriptor.assetID,
                repositoryRelativePath: descriptor.repositoryRelativePath,
                sha256: descriptor.sha256,
                licenseEvidenceID: "",
                inventoryEvidenceID: descriptor.inventoryEvidenceID
            )
        }
        #expect(throws: BackgroundFixedAssetDescriptorError.invalidInventoryEvidenceID) {
            try BackgroundFixedAssetDescriptor(
                assetID: descriptor.assetID,
                repositoryRelativePath: descriptor.repositoryRelativePath,
                sha256: descriptor.sha256,
                licenseEvidenceID: descriptor.licenseEvidenceID,
                inventoryEvidenceID: ""
            )
        }
    }
}

@Suite(.serialized)
struct BackgroundGenerationClientTests {
    @Test func gateRequiresFourOriginalsAndApprovedMeasurementAndMakesNoRequest() async throws {
        let transport = RecordingBackgroundTransport()
        let sut = try makeBackgroundClient(mode: .contractFixture, transport: transport)

        for missing in Shot.allCases {
            let outcome = await sut.generate(
                context: try backgroundContext(missing: missing),
                rawStyleID: "clean-white",
                requestID: try RequestID("missing-\(missing.rawValue)")
            )
            #expect(outcome == .gateClosed(.missingOriginal(missing)))
        }

        let unapproved = await sut.generate(
            context: try backgroundContext(approval: .unapproved),
            rawStyleID: "clean-white",
            requestID: try RequestID("unapproved")
        )
        #expect(unapproved == .gateClosed(.measurementNotApproved))

        let unknown = await sut.generate(
            context: try backgroundContext(),
            rawStyleID: "user-free-form-prompt",
            requestID: try RequestID("unknown-style")
        )
        #expect(unknown == .gateClosed(.unknownStyleID))
        #expect((await transport.requestSnapshot()).isEmpty)
    }

    @Test func requestIsTextOnlyExactAndExplicitRetryKeepsStableIdempotency() async throws {
        let image = try backgroundPNG(
            width: 2,
            height: 2,
            pixels: [
                (242, 242, 242, 255), (244, 244, 244, 255),
                (246, 246, 246, 255), (248, 248, 248, 255),
            ]
        )
        let transport = RecordingBackgroundTransport([
            .urlError(.timedOut),
            .response(.init(statusCode: 200, contentType: "image/png; charset=binary", body: image)),
        ])
        let sut = try makeBackgroundClient(mode: .contractFixture, transport: transport)
        let context = try backgroundContext(imageIDPrefix: "PRIVATE-SLOT")
        let requestID = try RequestID("stable-background-operation")

        let first = await sut.generate(
            context: context,
            rawStyleID: "clean-white",
            requestID: requestID
        )
        guard case .failed(let descriptor, let firstFailure) = first else {
            Issue.record("expected timeout failure")
            return
        }
        #expect(descriptor.session == context)
        #expect(firstFailure.reason == .timedOut)
        #expect(firstFailure.recovery.retry == .sameRequestIdentity)
        #expect(
            firstFailure.recovery.fixedBackground
                == .unavailable(.noLicenseConfirmedRepositoryAsset)
        )

        let second = await sut.generate(
            context: context,
            rawStyleID: "clean-white",
            requestID: requestID
        )
        guard case .validated(let payload) = second else {
            Issue.record("expected explicit retry success")
            return
        }
        #expect(payload.pngBytes == image)
        #expect(payload.pixelSize == .init(width: 2, height: 2))

        let requests = await transport.requestSnapshot()
        #expect(requests.count == 2)
        for request in requests {
            #expect(request.url?.path == "/api/generate-background")
            #expect(request.httpMethod == "POST")
            #expect(request.timeoutInterval == 60)
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
            #expect(request.value(forHTTPHeaderField: "Accept") == "image/png")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect(
                request.value(forHTTPHeaderField: "Idempotency-Key")
                    == "stable-background-operation"
            )
            let body = try #require(request.httpBody)
            #expect(body == Data(#"{"styleId":"clean-white"}"#.utf8))
            let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(object.keys.sorted() == ["styleId"])
            for forbidden in [
                "PRIVATE-SLOT-front", "PRIVATE-SLOT-back", "PRIVATE-SLOT-tag",
                "PRIVATE-SLOT-measurement", "image", "binary", "mask", "tag",
                "measurement", "product", "prompt", "fixedPromptVersion",
            ] {
                #expect(!body.contains(Data(forbidden.utf8)))
            }
        }
    }

    @Test func rejectsWrongContentTypeNonPNGMalformedAndTransparentImages() async throws {
        let transparent = try backgroundPNG(
            width: 1,
            height: 1,
            pixels: [(1, 2, 3, 0)]
        )
        let cases: [(BackgroundGenerationHTTPResponse, BackgroundGenerationFailureReason, BackgroundRetryDisposition)] =
            [
                (
                    .init(statusCode: 200, contentType: "application/octet-stream", body: Data()),
                    .invalidContentType,
                    .disallowed
                ),
                (
                    .init(statusCode: 200, contentType: "image/png", body: Data("not-png".utf8)),
                    .nonPNG,
                    .sameRequestIdentity
                ),
                (
                    .init(
                        statusCode: 200,
                        contentType: "image/png",
                        body: Data([137, 80, 78, 71, 13, 10, 26, 10, 0])
                    ),
                    .invalidImage,
                    .sameRequestIdentity
                ),
                (
                    .init(statusCode: 200, contentType: "image/png", body: transparent),
                    .transparentImage,
                    .sameRequestIdentity
                ),
            ]

        for (index, entry) in cases.enumerated() {
            let transport = RecordingBackgroundTransport([.response(entry.0)])
            let sut = try makeBackgroundClient(mode: .contractFixture, transport: transport)
            let outcome = await sut.generate(
                context: try backgroundContext(),
                rawStyleID: "clean-white",
                requestID: try RequestID("invalid-\(index)")
            )
            guard case .failed(_, let failure) = outcome else {
                Issue.record("expected invalid image failure at index \(index)")
                continue
            }
            #expect(failure.reason == entry.1)
            #expect(failure.recovery.retry == entry.2)
        }
    }

    @Test func providerStatusAndEnvelopeAreStrictAndProviderMessageIsNotRetained() async throws {
        let validRetryable = Data(
            #"{"provider":"background-generator","code":"UNAVAILABLE","message":"PRIVATE PROVIDER DETAIL","retryable":true}"#
                .utf8
        )
        let validNonretryable = Data(
            #"{"provider":"background-generator","code":"INVALID_INPUT","message":"Style is not allowed","retryable":false}"#
                .utf8
        )
        let wrongProvider = Data(
            #"{"provider":"garment-masker","code":"UNAVAILABLE","message":"wrong","retryable":true}"#.utf8
        )
        let invalidEnvelope = Data(
            #"{"provider":"background-generator","code":"UNAVAILABLE","message":"bad","retryable":true,"extra":1}"#.utf8
        )
        let cases: [(BackgroundGenerationHTTPResponse, BackgroundGenerationFailureReason, BackgroundRetryDisposition)] =
            [
                (
                    .init(statusCode: 503, contentType: "application/json; charset=utf-8", body: validRetryable),
                    .provider(.unavailable), .sameRequestIdentity
                ),
                (
                    .init(statusCode: 400, contentType: "application/json", body: validNonretryable),
                    .provider(.invalidInput), .disallowed
                ),
                (
                    .init(statusCode: 503, contentType: "application/json", body: wrongProvider),
                    .invalidProviderError(503), .disallowed
                ),
                (
                    .init(statusCode: 502, contentType: "application/json", body: invalidEnvelope),
                    .invalidProviderError(502), .disallowed
                ),
                (
                    .init(statusCode: 429, contentType: "text/plain", body: Data()), .invalidContentType,
                    .disallowed
                ),
                (
                    .init(statusCode: 418, contentType: "application/json", body: validRetryable),
                    .unexpectedStatus(418), .disallowed
                ),
            ]

        for (index, entry) in cases.enumerated() {
            let transport = RecordingBackgroundTransport([.response(entry.0)])
            let sut = try makeBackgroundClient(mode: .contractFixture, transport: transport)
            let outcome = await sut.generate(
                context: try backgroundContext(),
                rawStyleID: "clean-white",
                requestID: try RequestID("provider-\(index)")
            )
            guard case .failed(_, let failure) = outcome else {
                Issue.record("expected strict provider failure at index \(index)")
                continue
            }
            #expect(failure.reason == entry.1)
            #expect(failure.recovery.retry == entry.2)
            let state = await sut.stateSnapshot()
            #expect(!String(reflecting: state).contains("PRIVATE PROVIDER DETAIL"))
        }
    }

    @Test func transportFailureIsFiniteAndPreservesRecoverySelection() async throws {
        let transport = RecordingBackgroundTransport([.urlError(.cannotConnectToHost)])
        let sut = try makeBackgroundClient(mode: .contractFixture, transport: transport)
        let outcome = await sut.generate(
            context: try backgroundContext(),
            rawStyleID: "clean-white",
            requestID: try RequestID("transport")
        )
        guard case .failed(_, let failure) = outcome else {
            Issue.record("expected transport failure")
            return
        }
        #expect(failure.reason == .transport)
        #expect(failure.recovery.retry == .sameRequestIdentity)
        #expect(
            failure.recovery.fixedBackground
                == .unavailable(.noLicenseConfirmedRepositoryAsset)
        )
    }

    @Test func injectedVerifiedFixedBackgroundAppearsInFailureRecovery() async throws {
        let descriptor = try verifiedFixedBackgroundDescriptor()
        let policy = BackgroundStylePolicy(
            fixedBackground: .licenseConfirmed(descriptor)
        )
        let transport = RecordingBackgroundTransport([.urlError(.cannotConnectToHost)])
        let sut = try makeBackgroundClient(
            mode: .contractFixture,
            transport: transport,
            policy: policy
        )
        let outcome = await sut.generate(
            context: try backgroundContext(),
            rawStyleID: "clean-white",
            requestID: try RequestID("verified-fixed-recovery")
        )
        guard case .failed(_, let failure) = outcome else {
            Issue.record("expected transport failure")
            return
        }
        #expect(failure.reason == .transport)
        #expect(failure.recovery.fixedBackground == .licenseConfirmed(descriptor))
        #expect(failure.recovery.fixedBackground.isSelectable)
        #expect(failure.recovery.fixedBackground.descriptor == descriptor)
    }

    @Test func cancellationIsBoundedAndCannotCommitLateResponseBytes() async throws {
        let image = try opaqueBackgroundPNG()
        let transport = ControlledBackgroundTransport()
        let sut = try makeBackgroundClient(mode: .contractFixture, transport: transport)
        let requestID = try RequestID("cancel-background")
        let context = try backgroundContext()
        let task = Task {
            await sut.generate(
                context: context,
                rawStyleID: "clean-white",
                requestID: requestID
            )
        }
        await transport.waitForRequestCount(1)
        await sut.cancel(requestID: requestID)
        await transport.complete(
            0,
            with: .init(statusCode: 200, contentType: "image/png", body: image)
        )

        guard case .failed(_, let failure) = await task.value else {
            Issue.record("expected cancellation")
            return
        }
        #expect(failure.reason == .cancelled)
        #expect(failure.recovery.retry == .sameRequestIdentity)
        let state = await sut.stateSnapshot()
        #expect(!containsBackgroundData(state))
    }

    @Test func supersededCompletionIsStaleAndCannotReplaceCurrentMetadataState() async throws {
        let image = try opaqueBackgroundPNG()
        let transport = ControlledBackgroundTransport()
        let sut = try makeBackgroundClient(mode: .contractFixture, transport: transport)
        let context = try backgroundContext()
        let firstID = try RequestID("old-background")
        let secondID = try RequestID("new-background")
        let first = Task {
            await sut.generate(
                context: context,
                rawStyleID: "clean-white",
                requestID: firstID
            )
        }
        await transport.waitForRequestCount(1)
        let second = Task {
            await sut.generate(
                context: context,
                rawStyleID: "clean-white",
                requestID: secondID
            )
        }
        await transport.waitForRequestCount(2)
        await transport.complete(
            1,
            with: .init(statusCode: 200, contentType: "image/png", body: image)
        )
        guard case .validated(let currentPayload) = await second.value else {
            Issue.record("expected current completion")
            return
        }
        await transport.complete(
            0,
            with: .init(statusCode: 200, contentType: "image/png", body: image)
        )
        guard case .stale(let staleDescriptor) = await first.value else {
            Issue.record("expected stale completion")
            return
        }
        #expect(staleDescriptor.requestID == firstID)
        #expect(
            await sut.stateSnapshot()
                == .validated(
                    .contractFixture,
                    currentPayload.descriptor,
                    currentPayload.pixelSize
                )
        )
    }

    @Test func injectedLiveAvailabilityExercisesLiveRequestPath() async throws {
        let image = try opaqueBackgroundPNG()
        let transport = RecordingBackgroundTransport([
            .response(.init(statusCode: 200, contentType: "image/png", body: image))
        ])
        let sut = try makeBackgroundClient(
            mode: .live,
            transport: transport,
            endpointAvailability: .available
        )
        let outcome = await sut.generate(
            context: try backgroundContext(),
            rawStyleID: "clean-white",
            requestID: try RequestID("live-available")
        )
        guard case .validated(let payload) = outcome else {
            Issue.record("expected injected live request success")
            return
        }
        #expect(payload.pngBytes == image)
        let requests = await transport.requestSnapshot()
        #expect(requests.count == 1)
        #expect(requests.first?.url?.path == "/api/generate-background")
        #expect(requests.first?.value(forHTTPHeaderField: "Idempotency-Key") == "live-available")
    }

    @Test func defaultLiveUnavailableMakesZeroRequestAndNeverFallsBackToFixture() async throws {
        let transport = RecordingBackgroundTransport([
            .response(
                .init(
                    statusCode: 200,
                    contentType: "image/png",
                    body: try opaqueBackgroundPNG()
                ))
        ])
        let sut = try makeBackgroundClient(mode: .live, transport: transport)
        let outcome = await sut.generate(
            context: try backgroundContext(),
            rawStyleID: "clean-white",
            requestID: try RequestID("live-unavailable")
        )
        guard case .unavailable(let descriptor, let failure) = outcome else {
            Issue.record("expected explicit live unavailability")
            return
        }
        #expect(descriptor.style == .cleanWhite)
        #expect(failure.reason == .liveEndpointUnavailable)
        #expect(failure.recovery.retry == .awaitLiveEndpointAvailability)
        #expect(
            failure.recovery.fixedBackground
                == .unavailable(.noLicenseConfirmedRepositoryAsset)
        )
        let requests = await transport.requestSnapshot()
        #expect(requests.isEmpty)
    }

    @Test func failureStateRetainsOnlySessionMetadataAndDoesNotEraseFourSlots() async throws {
        let context = try backgroundContext(imageIDPrefix: "retained")
        let transport = RecordingBackgroundTransport([.urlError(.cannotConnectToHost)])
        let sut = try makeBackgroundClient(mode: .contractFixture, transport: transport)
        let outcome = await sut.generate(
            context: context,
            rawStyleID: "clean-white",
            requestID: try RequestID("metadata-state")
        )
        guard case .failed(let descriptor, let failure) = outcome else {
            Issue.record("expected transport failure")
            return
        }
        #expect(failure.reason == .transport)
        #expect(descriptor.session == context)
        #expect(descriptor.session.originals.count == 4)
        for shot in Shot.allCases {
            #expect(descriptor.session.originals[shot] == context.originals[shot])
        }

        let state = await sut.stateSnapshot()
        #expect(
            state == .failed(.contractFixture, descriptor, failure)
        )
        #expect(!containsBackgroundData(state))
    }
}

private func makeBackgroundClient(
    mode: BackgroundGenerationExecutionMode,
    transport: any BackgroundGenerationHTTPTransport,
    policy: BackgroundStylePolicy = .init(),
    endpointAvailability: EndpointAvailability = BackendEndpoint.generateBackground.availability
) throws -> BackgroundGenerationClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    let backend = try BackendAPIClient(
        baseURL: URL(string: "http://background.example.test")!,
        session: URLSession(configuration: configuration),
        allowsInsecureTestURL: true
    )
    return BackgroundGenerationClient(
        backend: backend,
        mode: mode,
        transport: transport,
        policy: policy,
        endpointAvailability: endpointAvailability
    )
}

private func verifiedFixedBackgroundDescriptor() throws -> BackgroundFixedAssetDescriptor {
    try BackgroundFixedAssetDescriptor(
        assetID: "fixed-background-clean-white-v1",
        repositoryRelativePath: "Fixtures/Approved/fixed-background-clean-white-v1.png",
        sha256: String(repeating: "a", count: 64),
        licenseEvidenceID: "licenses/fixed-background-clean-white-v1",
        inventoryEvidenceID: "asset-inventory/fixed-background-clean-white-v1"
    )
}

private func backgroundContext(
    approval: MeasurementApproval = .approvedCV,
    missing: Shot? = nil,
    imageIDPrefix: String = "original"
) throws -> BackgroundGenerationSessionContext {
    var originals: [Shot: ImageID] = [:]
    for shot in Shot.allCases {
        originals[shot] = try ImageID("\(imageIDPrefix)-\(shot.rawValue)")
    }
    if let missing { originals[missing] = nil }
    return BackgroundGenerationSessionContext(
        sessionID: try SessionID("background-session"),
        originals: originals,
        measurementApproval: approval
    )
}

private func opaqueBackgroundPNG() throws -> Data {
    try backgroundPNG(
        width: 2,
        height: 1,
        pixels: [(240, 240, 240, 255), (250, 250, 250, 255)]
    )
}

private func backgroundPNG(
    width: Int,
    height: Int,
    pixels: [(UInt8, UInt8, UInt8, UInt8)]
) throws -> Data {
    guard pixels.count == width * height else { throw URLError(.cannotDecodeContentData) }
    var bytes = pixels.flatMap { [$0.0, $0.1, $0.2, $0.3] }
    guard
        let image = bytes.withUnsafeMutableBytes({ buffer -> CGImage? in
            guard
                let context = CGContext(
                    data: buffer.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue
                )
            else {
                return nil
            }
            return context.makeImage()
        })
    else {
        throw URLError(.cannotDecodeContentData)
    }

    guard let output = CFDataCreateMutable(nil, 0),
        let destination = CGImageDestinationCreateWithData(
            output,
            "public.png" as CFString,
            1,
            nil
        )
    else {
        throw URLError(.cannotEncodeContentData)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw URLError(.cannotEncodeContentData)
    }
    return output as Data
}

private func containsBackgroundData(_ value: Any) -> Bool {
    if value is Data { return true }
    return Mirror(reflecting: value).children.contains { containsBackgroundData($0.value) }
}
