import CompositionKit
import Foundation
import Testing

struct ApprovedFrontImageExportTests {
    @Test func exportsExplicitlyApprovedOriginalPNGAndCleansExactlyOnce() async {
        let bytes = StaticBytesProvider(values: ["front": .success(.init(data: tinyPNG, format: .png))])
        let sink = RecordingSink(result: .completed)
        let cleaner = RecordingCleaner()
        let exporter = makeExporter(bytes: bytes, sink: sink, cleaner: cleaner, originalID: "front")

        let request = await exporter.requestExport(approvedComparison: approvedState(originalID: "front", choice: .original))
        let requestID = try! #require(request.requestID)
        let terminal = await exporter.waitForTerminalStatus(of: requestID)
        let payloads = await sink.payloads

        #expect(terminal == .completed(requestID: requestID))
        #expect(payloads.count == 1)
        #expect(payloads[0].format == .png)
        #expect(payloads[0].contentType == "image/png")
        #expect(payloads[0].fileExtension == "png")
        #expect(payloads[0].format.uniformTypeIdentifier == "public.png")
        #expect(payloads[0].sha256Hex == tinyPNGHash)
        #expect(await cleaner.count == 1)
    }

    @Test func exportsExplicitlyApprovedCompositeJPEG() async {
        let bytes = StaticBytesProvider(values: ["composite": .success(.init(data: tinyJPEG, format: .jpeg))])
        let sink = RecordingSink(result: .completed)
        let cleaner = RecordingCleaner()
        let exporter = makeExporter(bytes: bytes, sink: sink, cleaner: cleaner, originalID: "front", compositeID: "composite")

        let request = await exporter.requestExport(approvedComparison: approvedState(originalID: "front", compositeID: "composite", choice: .composite))
        let terminal = await exporter.waitForTerminalStatus(of: try! #require(request.requestID))
        let payloads = await sink.payloads

        #expect(terminal == .completed(requestID: try! #require(request.requestID)))
        #expect(payloads[0].format == .jpeg)
        #expect(payloads[0].contentType == "image/jpeg")
        #expect(payloads[0].fileExtension == "jpg")
        #expect(payloads[0].format.uniformTypeIdentifier == "public.jpeg")
        #expect(await cleaner.count == 1)
    }

    @Test func rejectsUnapprovedChangedAndNonFrontIntermediateIDsBeforeBytesLookup() async {
        let bytes = StaticBytesProvider(values: [:])
        let sink = RecordingSink(result: .completed)
        let cleaner = RecordingCleaner()
        let exporter = makeExporter(bytes: bytes, sink: sink, cleaner: cleaner, originalID: "front", compositeID: "composite")

        var changedSelection = approvedState(originalID: "front", compositeID: "composite", choice: .original)
        changedSelection.select(.composite)
        let states = [
            ImageComparisonState(originalID: "front"),
            changedSelection,
            approvedState(originalID: "back", choice: .original),
            approvedState(originalID: "tag", choice: .original),
            approvedState(originalID: "measurement", choice: .original),
            approvedState(originalID: "mask", choice: .original),
            approvedState(originalID: "draft", choice: .original),
        ]
        for state in states {
            let result = await exporter.requestExport(approvedComparison: state)
            #expect(result == .rejected(.notExplicitlyApproved))
        }
        #expect(await bytes.requestedIDs.isEmpty)
        #expect(await sink.payloads.isEmpty)
        #expect(await cleaner.count == 0)
    }

    @Test func rejectsEmptyBytesWithoutCleanup() async {
        let bytes = StaticBytesProvider(values: ["front": .success(.init(data: Data(), format: .png))])
        let sink = RecordingSink(result: .completed)
        let cleaner = RecordingCleaner()
        let exporter = makeExporter(bytes: bytes, sink: sink, cleaner: cleaner, originalID: "front")

        let result = await exporter.requestExport(approvedComparison: approvedState(originalID: "front", choice: .original))
        let terminal = await exporter.waitForTerminalStatus(of: try! #require(result.requestID))

        #expect(terminal == .retryableFailure(.emptyBytes))
        #expect(await sink.payloads.isEmpty)
        #expect(await cleaner.count == 0)
    }

    @Test func rejectsInvalidAndMismatchedEncodedBytesBeforeSink() async {
        let sink = RecordingSink(result: .completed)
        let cleaner = RecordingCleaner()
        let invalid = StaticBytesProvider(values: ["front": .success(.init(data: Data([0, 1, 2]), format: .png))])
        let invalidExporter = makeExporter(bytes: invalid, sink: sink, cleaner: cleaner, originalID: "front")
        let state = approvedState(originalID: "front", choice: .original)
        let invalidRequest = await invalidExporter.requestExport(approvedComparison: state)
        #expect(await invalidExporter.waitForTerminalStatus(of: try! #require(invalidRequest.requestID)) == .retryableFailure(.invalidImageBytes))

        let mismatch = StaticBytesProvider(values: ["front": .success(.init(data: tinyJPEG, format: .png))])
        let mismatchExporter = makeExporter(bytes: mismatch, sink: sink, cleaner: cleaner, originalID: "front")
        let mismatchRequest = await mismatchExporter.requestExport(approvedComparison: state)
        #expect(await mismatchExporter.waitForTerminalStatus(of: try! #require(mismatchRequest.requestID)) == .retryableFailure(.imageFormatMismatch))
        #expect(await sink.payloads.isEmpty)
        #expect(await cleaner.count == 0)
    }

    @Test func doubleTapIsSingleFlightAndErrorRequiresExplicitRetry() async {
        let bytes = SequencedBytesProvider(results: [.success(.init(data: tinyPNG, format: .png)), .success(.init(data: tinyPNG, format: .png))])
        let sink = SequencedSink(results: [.failure(.sink), .success(.completed)])
        let cleaner = RecordingCleaner()
        let exporter = makeExporter(bytes: bytes, sink: sink, cleaner: cleaner, originalID: "front")
        let state = approvedState(originalID: "front", choice: .original)

        let first = await exporter.requestExport(approvedComparison: state)
        let firstID = try! #require(first.requestID)
        let duplicate = await exporter.requestExport(approvedComparison: state)
        #expect(duplicate == .alreadyInFlight(requestID: firstID))
        #expect(await exporter.waitForTerminalStatus(of: firstID) == .retryableFailure(.sinkFailed))
        #expect(await cleaner.count == 0)

        let retry = await exporter.requestExport(approvedComparison: state)
        #expect(await exporter.waitForTerminalStatus(of: try! #require(retry.requestID)) == .completed(requestID: try! #require(retry.requestID)))
        #expect(await sink.payloads.count == 2)
        #expect(await cleaner.count == 1)
    }

    @Test func cancelledAndOldCompletionCannotCleanOrReplaceNewRequest() async {
        let bytes = ControlledBytesProvider()
        let sink = RecordingSink(result: .completed)
        let cleaner = RecordingCleaner()
        let exporter = makeExporter(bytes: bytes, sink: sink, cleaner: cleaner, originalID: "front")
        let state = approvedState(originalID: "front", choice: .original)

        let old = await exporter.requestExport(approvedComparison: state)
        let oldID = try! #require(old.requestID)
        await bytes.waitForCallCount(1)
        await exporter.cancelExport()
        #expect(await exporter.waitForTerminalStatus(of: oldID) == .ready)
        #expect(await cleaner.count == 0)

        let current = await exporter.requestExport(approvedComparison: state)
        let currentID = try! #require(current.requestID)
        await bytes.waitForCallCount(2)
        await bytes.resumeNext(with: .success(.init(data: tinyPNG, format: .png)))
        #expect(await exporter.status == .exporting(requestID: currentID))
        #expect(await cleaner.count == 0)

        await bytes.resumeNext(with: .success(.init(data: tinyPNG, format: .png)))
        #expect(await exporter.waitForTerminalStatus(of: currentID) == .completed(requestID: currentID))
        #expect(await cleaner.count == 1)
    }

    @Test func sinkCancellationLeavesSessionForRetry() async {
        let bytes = StaticBytesProvider(values: ["front": .success(.init(data: tinyPNG, format: .png))])
        let sink = RecordingSink(result: .cancelled)
        let cleaner = RecordingCleaner()
        let exporter = makeExporter(bytes: bytes, sink: sink, cleaner: cleaner, originalID: "front")
        let result = await exporter.requestExport(approvedComparison: approvedState(originalID: "front", choice: .original))

        #expect(await exporter.waitForTerminalStatus(of: try! #require(result.requestID)) == .ready)
        #expect(await cleaner.count == 0)
    }

    @Test func photoLibraryAuthorizationDenialIsRecoverableAndDoesNotCleanSession() async {
        let bytes = StaticBytesProvider(values: ["front": .success(.init(data: tinyPNG, format: .png))])
        let sink = RecordingSink(result: .notAuthorized)
        let cleaner = RecordingCleaner()
        let exporter = makeExporter(bytes: bytes, sink: sink, cleaner: cleaner, originalID: "front")

        let result = await exporter.requestExport(approvedComparison: approvedState(originalID: "front", choice: .original))
        #expect(await exporter.waitForTerminalStatus(of: try! #require(result.requestID)) == .retryableFailure(.photoLibraryAuthorizationDenied))
        #expect(await sink.payloads.count == 1)
        #expect(await cleaner.count == 0)
    }

    @Test func savingPhaseRejectsCancelAndSecondRequestUntilCommittedSinkCompletes() async {
        let bytes = StaticBytesProvider(values: ["front": .success(.init(data: tinyPNG, format: .png))])
        let sink = ControlledSink()
        let cleaner = RecordingCleaner()
        let exporter = makeExporter(bytes: bytes, sink: sink, cleaner: cleaner, originalID: "front")
        let state = approvedState(originalID: "front", choice: .original)

        let request = await exporter.requestExport(approvedComparison: state)
        let requestID = try! #require(request.requestID)
        await sink.waitUntilStarted()
        #expect(await exporter.status == .saving(requestID: requestID))
        await exporter.cancelExport()
        #expect(await exporter.status == .saving(requestID: requestID))
        #expect(await exporter.requestExport(approvedComparison: state) == .saving(requestID: requestID))
        await sink.complete()
        #expect(await exporter.waitForTerminalStatus(of: requestID) == .completed(requestID: requestID))
        #expect(await sink.payloads.count == 1)
        #expect(await cleaner.count == 1)
    }

    @Test func providerFailureIsRetryableAndCleanupPendingBlocksCancelAndSecondSave() async {
        let failingBytes = SequencedBytesProvider(results: [.failure(.bytes), .success(.init(data: tinyPNG, format: .png))])
        let sink = RecordingSink(result: .completed)
        let retryCleaner = RecordingCleaner()
        let failingExporter = makeExporter(bytes: failingBytes, sink: sink, cleaner: retryCleaner, originalID: "front")
        let state = approvedState(originalID: "front", choice: .original)
        let failed = await failingExporter.requestExport(approvedComparison: state)
        #expect(await failingExporter.waitForTerminalStatus(of: try! #require(failed.requestID)) == .retryableFailure(.bytesProviderFailed))
        let retried = await failingExporter.requestExport(approvedComparison: state)
        let retriedID = try! #require(retried.requestID)
        #expect(await failingExporter.waitForTerminalStatus(of: retriedID) == .completed(requestID: retriedID))
        #expect(await retryCleaner.count == 1)

        let bytes = StaticBytesProvider(values: ["front": .success(.init(data: tinyPNG, format: .png))])
        let pendingCleaner = ControlledCleaner()
        let exporter = makeExporter(bytes: bytes, sink: sink, cleaner: pendingCleaner, originalID: "front")
        let request = await exporter.requestExport(approvedComparison: state)
        let requestID = try! #require(request.requestID)
        await pendingCleaner.waitUntilStarted()
        #expect(await exporter.status == .cleanupPending(requestID: requestID))
        await exporter.cancelExport()
        #expect(await exporter.status == .cleanupPending(requestID: requestID))
        #expect(await exporter.requestExport(approvedComparison: state) == .cleanupPending(requestID: requestID))
        await pendingCleaner.finish()
        #expect(await exporter.waitForTerminalStatus(of: requestID) == .completed(requestID: requestID))
        #expect(await exporter.requestExport(approvedComparison: state) == .alreadyCompleted(requestID: requestID))
        #expect(await pendingCleaner.count == 1)
    }

    @Test func cleanupFailureRetriesCleanupWithoutWritingApprovedImageAgain() async {
        let bytes = StaticBytesProvider(values: ["front": .success(.init(data: tinyPNG, format: .png))])
        let sink = RecordingSink(result: .completed)
        let cleaner = SequencedCleaner(results: [.failure(.cleanup), .success(())])
        let exporter = makeExporter(bytes: bytes, sink: sink, cleaner: cleaner, originalID: "front")
        let state = approvedState(originalID: "front", choice: .original)

        let first = await exporter.requestExport(approvedComparison: state)
        let requestID = try! #require(first.requestID)
        #expect(await exporter.waitForTerminalStatus(of: requestID) == .cleanupRetryableFailure(requestID: requestID, failure: .sessionCleanupFailed))
        let savedPayloads = await sink.payloads
        #expect(savedPayloads.count == 1)
        #expect(savedPayloads[0].format == .png)
        #expect(savedPayloads[0].sha256Hex == tinyPNGHash)
        #expect(await cleaner.count == 1)

        #expect(await exporter.requestExport(approvedComparison: state) == .cleanupRetryStarted(requestID: requestID))
        #expect(await exporter.waitForTerminalStatus(of: requestID) == .completed(requestID: requestID))
        #expect(await sink.payloads.count == 1)
        #expect(await cleaner.count == 2)
    }

    @Test func permanentCleanupFailureRemainsObservableWithoutAnotherSinkWrite() async {
        let bytes = StaticBytesProvider(values: ["front": .success(.init(data: tinyPNG, format: .png))])
        let sink = RecordingSink(result: .completed)
        let cleaner = SequencedCleaner(results: [.failure(.cleanup), .failure(.cleanup)])
        let exporter = makeExporter(bytes: bytes, sink: sink, cleaner: cleaner, originalID: "front")
        let state = approvedState(originalID: "front", choice: .original)

        let first = await exporter.requestExport(approvedComparison: state)
        let requestID = try! #require(first.requestID)
        #expect(await exporter.waitForTerminalStatus(of: requestID) == .cleanupRetryableFailure(requestID: requestID, failure: .sessionCleanupFailed))

        #expect(await exporter.requestExport(approvedComparison: state) == .cleanupRetryStarted(requestID: requestID))
        #expect(await exporter.waitForTerminalStatus(of: requestID) == .cleanupRetryableFailure(requestID: requestID, failure: .sessionCleanupFailed))
        #expect(await exporter.status == .cleanupRetryableFailure(requestID: requestID, failure: .sessionCleanupFailed))
        #expect(await sink.payloads.count == 1)
        #expect(await cleaner.count == 2)
    }

    @Test func preSaveCancellationAndFailureCanRetryWithOnlyOneSuccessfulWrite() async {
        let controlledBytes = ControlledBytesProvider()
        let cancelledSink = RecordingSink(result: .completed)
        let cancelledExporter = makeExporter(bytes: controlledBytes, sink: cancelledSink, cleaner: RecordingCleaner(), originalID: "front")
        let state = approvedState(originalID: "front", choice: .original)

        let cancelled = await cancelledExporter.requestExport(approvedComparison: state)
        let cancelledID = try! #require(cancelled.requestID)
        await controlledBytes.waitForCallCount(1)
        await cancelledExporter.cancelExport()
        #expect(await cancelledExporter.waitForTerminalStatus(of: cancelledID) == .ready)
        let afterCancel = await cancelledExporter.requestExport(approvedComparison: state)
        await controlledBytes.waitForCallCount(2)
        await controlledBytes.resumeNext(with: .success(.init(data: tinyPNG, format: .png)))
        await controlledBytes.resumeNext(with: .success(.init(data: tinyPNG, format: .png)))
        #expect(await cancelledExporter.waitForTerminalStatus(of: try! #require(afterCancel.requestID)) == .completed(requestID: try! #require(afterCancel.requestID)))
        #expect(await cancelledSink.payloads.count == 1)

        let failedSink = SequencedSink(results: [.failure(.sink), .success(.completed)])
        let failedExporter = makeExporter(
            bytes: SequencedBytesProvider(results: [.success(.init(data: tinyPNG, format: .png)), .success(.init(data: tinyPNG, format: .png))]),
            sink: failedSink,
            cleaner: RecordingCleaner(),
            originalID: "front"
        )
        let failed = await failedExporter.requestExport(approvedComparison: state)
        #expect(await failedExporter.waitForTerminalStatus(of: try! #require(failed.requestID)) == .retryableFailure(.sinkFailed))
        let afterFailure = await failedExporter.requestExport(approvedComparison: state)
        #expect(await failedExporter.waitForTerminalStatus(of: try! #require(afterFailure.requestID)) == .completed(requestID: try! #require(afterFailure.requestID)))
        #expect(await failedSink.payloads.count == 2)
    }

    @Test func catalogRejectsEmptyIDsWithoutCrashing() {
        #expect(throws: ApprovedFrontImageOutputCatalogError.emptyFrontOriginalID) {
            try ApprovedFrontImageOutputCatalog(frontOriginalID: "")
        }
        #expect(throws: ApprovedFrontImageOutputCatalogError.emptyValidatedCompositeID) {
            try ApprovedFrontImageOutputCatalog(frontOriginalID: "front", validatedCompositeID: "")
        }
    }

    #if canImport(Photos) && os(iOS)
    @available(iOS 18, *)
    @Test func photoLibraryDeniedOrRestrictedNeverWritesAndIsRecoverable() async throws {
        for status in [PhotosAddOnlyAuthorizationStatus.denied, .restricted] {
            let authorization = RecordingPhotoAuthorization(status: status, requestedStatus: .authorized)
            let writer = RecordingPhotoWriter()
            let sink = PhotosAddOnlyApprovedImageSink(authorization: authorization, writer: writer)

            #expect(try await sink.addApprovedImage(.init(bytes: .init(data: tinyPNG, format: .png))) == .notAuthorized)
            #expect(await authorization.requestCount == 0)
            #expect(await writer.writeCount == 0)
        }
    }

    @available(iOS 18, *)
    @Test func photoLibraryRequestWritesOnlyAfterAuthorizedOrLimitedGrant() async throws {
        for granted in [PhotosAddOnlyAuthorizationStatus.authorized, .limited] {
            let authorization = RecordingPhotoAuthorization(status: .notDetermined, requestedStatus: granted)
            let writer = RecordingPhotoWriter()
            let sink = PhotosAddOnlyApprovedImageSink(authorization: authorization, writer: writer)

            #expect(try await sink.addApprovedImage(.init(bytes: .init(data: tinyPNG, format: .png))) == .completed)
            #expect(await authorization.requestCount == 1)
            #expect(await writer.writeCount == 1)
        }
    }

    @available(iOS 18, *)
    @Test func photoLibraryDeclinedRequestNeverWrites() async throws {
        let authorization = RecordingPhotoAuthorization(status: .notDetermined, requestedStatus: .denied)
        let writer = RecordingPhotoWriter()
        let sink = PhotosAddOnlyApprovedImageSink(authorization: authorization, writer: writer)

        #expect(try await sink.addApprovedImage(.init(bytes: .init(data: tinyPNG, format: .png))) == .notAuthorized)
        #expect(await authorization.requestCount == 1)
        #expect(await writer.writeCount == 0)
    }
    #endif

    private func makeExporter(
        bytes: any ApprovedImageBytesProviding,
        sink: any ApprovedImageExportSink,
        cleaner: any ApprovedImageExportSessionCleaning,
        originalID: String,
        compositeID: String? = nil
    ) -> ApprovedFrontImageExporter {
        ApprovedFrontImageExporter(
            bytesProvider: bytes,
            sink: sink,
            sessionCleaner: cleaner,
            outputCatalog: try! .init(frontOriginalID: originalID, validatedCompositeID: compositeID)
        )
    }

    private func approvedState(originalID: String, compositeID: String? = nil, choice: ImageComparisonChoice) -> ImageComparisonState {
        var state = ImageComparisonState(
            originalID: originalID,
            compositeAvailability: .init(candidateID: compositeID, isComplete: compositeID != nil, isValid: compositeID != nil)
        )
        state.select(choice)
        state.confirmSelection()
        return state
    }
}

private enum TestError: Error, Sendable { case bytes, sink, cleanup }

private let tinyPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScL9aQAAAABJRU5ErkJggg==")!
private let tinyPNGHash = "a0dac8a179d6b83d77b15b5b055f45096854bc321d8fba8256f56b09973948bf"
private let tinyJPEG = Data(base64Encoded: "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////2wBDAf//////////////////////////////////////////////////////////////////////////////////////wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAX/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIQAxAAAAH/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oACAEBAAEFAqf/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oACAEDAQE/AR//xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oACAECAQE/AR//2Q==")!

private actor StaticBytesProvider: ApprovedImageBytesProviding {
    let values: [String: Result<ApprovedImageBytes, TestError>]
    private(set) var requestedIDs: [String] = []
    init(values: [String: Result<ApprovedImageBytes, TestError>]) { self.values = values }
    func approvedImageBytes(for candidateID: String) async throws -> ApprovedImageBytes {
        requestedIDs.append(candidateID)
        return try values[candidateID, default: .failure(.bytes)].get()
    }
}

private actor SequencedBytesProvider: ApprovedImageBytesProviding {
    private var results: [Result<ApprovedImageBytes, TestError>]
    init(results: [Result<ApprovedImageBytes, TestError>]) { self.results = results }
    func approvedImageBytes(for candidateID: String) async throws -> ApprovedImageBytes { try results.removeFirst().get() }
}

private actor ControlledBytesProvider: ApprovedImageBytesProviding {
    private var callCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var pending: [CheckedContinuation<Result<ApprovedImageBytes, TestError>, Never>] = []

    func approvedImageBytes(for candidateID: String) async throws -> ApprovedImageBytes {
        callCount += 1
        let currentWaiters = waiters; waiters = []
        for waiter in currentWaiters { waiter.resume() }
        return try await withCheckedContinuation { pending.append($0) }.get()
    }

    func waitForCallCount(_ expected: Int) async {
        guard callCount < expected else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func resumeNext(with result: Result<ApprovedImageBytes, TestError>) {
        pending.removeFirst().resume(returning: result)
    }
}

private actor RecordingSink: ApprovedImageExportSink {
    let result: ApprovedImageExportSinkResult
    private(set) var payloads: [ApprovedImageExportPayload] = []
    init(result: ApprovedImageExportSinkResult) { self.result = result }
    func addApprovedImage(_ payload: ApprovedImageExportPayload) async throws -> ApprovedImageExportSinkResult { payloads.append(payload); return result }
}

private actor SequencedSink: ApprovedImageExportSink {
    private var results: [Result<ApprovedImageExportSinkResult, TestError>]
    private(set) var payloads: [ApprovedImageExportPayload] = []
    init(results: [Result<ApprovedImageExportSinkResult, TestError>]) { self.results = results }
    func addApprovedImage(_ payload: ApprovedImageExportPayload) async throws -> ApprovedImageExportSinkResult { payloads.append(payload); return try results.removeFirst().get() }
}

private actor ControlledSink: ApprovedImageExportSink {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var completion: CheckedContinuation<ApprovedImageExportSinkResult, Never>?
    private(set) var payloads: [ApprovedImageExportPayload] = []

    func addApprovedImage(_ payload: ApprovedImageExportPayload) async throws -> ApprovedImageExportSinkResult {
        payloads.append(payload)
        started = true
        let waiters = startWaiters; startWaiters = []
        for waiter in waiters { waiter.resume() }
        return await withCheckedContinuation { completion = $0 }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func complete() { completion?.resume(returning: .completed); completion = nil }
}

private actor RecordingCleaner: ApprovedImageExportSessionCleaning {
    private(set) var count = 0
    func cleanupAfterApprovedExport() async { count += 1 }
}

private actor ControlledCleaner: ApprovedImageExportSessionCleaning {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private(set) var count = 0

    func cleanupAfterApprovedExport() async {
        count += 1
        started = true
        let waiters = startWaiters; startWaiters = []
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { finishContinuation = $0 }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func finish() { finishContinuation?.resume(); finishContinuation = nil }
}

private actor SequencedCleaner: ApprovedImageExportSessionCleaning {
    private var results: [Result<Void, TestError>]
    private(set) var count = 0

    init(results: [Result<Void, TestError>]) {
        self.results = results
    }

    func cleanupAfterApprovedExport() async throws {
        count += 1
        try results.removeFirst().get()
    }
}

#if canImport(Photos) && os(iOS)
private actor RecordingPhotoAuthorization: PhotosAddOnlyAuthorizing {
    let status: PhotosAddOnlyAuthorizationStatus
    let requestedStatus: PhotosAddOnlyAuthorizationStatus
    private(set) var requestCount = 0

    init(status: PhotosAddOnlyAuthorizationStatus, requestedStatus: PhotosAddOnlyAuthorizationStatus) {
        self.status = status
        self.requestedStatus = requestedStatus
    }

    func authorizationStatus() async -> PhotosAddOnlyAuthorizationStatus { status }

    func requestAddOnlyAuthorization() async -> PhotosAddOnlyAuthorizationStatus {
        requestCount += 1
        return requestedStatus
    }
}

private actor RecordingPhotoWriter: PhotosAddOnlyWriting {
    private(set) var writeCount = 0

    func addApprovedImageToPhotoLibrary(_ payload: ApprovedImageExportPayload) async throws {
        writeCount += 1
    }
}
#endif

private extension ApprovedImageExportStartResult {
    var requestID: UUID? {
        if case let .started(requestID) = self { return requestID }
        return nil
    }
}
