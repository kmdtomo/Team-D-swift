#if os(iOS)
import CoreMedia
import CoreVideo
@testable import CaptureKit
import Testing

@Test func analysisFrameRetainsTheOriginalTimedCameraSampleWithoutCopyingPixels() throws {
    var pixelBuffer: CVPixelBuffer?
    let pixelStatus = CVPixelBufferCreate(
        kCFAllocatorDefault,
        16,
        12,
        kCVPixelFormatType_32BGRA,
        nil,
        &pixelBuffer
    )
    #expect(pixelStatus == kCVReturnSuccess)
    let originalPixelBuffer = try #require(pixelBuffer)

    var format: CMVideoFormatDescription?
    let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: originalPixelBuffer,
        formatDescriptionOut: &format
    )
    #expect(formatStatus == noErr)

    var timing = CMSampleTimingInfo(
        duration: .invalid,
        presentationTimeStamp: CMTime(value: 3, timescale: 30),
        decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: originalPixelBuffer,
        formatDescription: try #require(format),
        sampleTiming: &timing,
        sampleBufferOut: &sampleBuffer
    )
    #expect(sampleStatus == noErr)
    let originalSample = try #require(sampleBuffer)

    let retained = try AnalysisFrame(sampleBuffer: originalSample)

    #expect(retained.sampleBuffer === originalSample)
    #expect(retained.pixelBuffer === originalPixelBuffer)
    #expect(CMSampleBufferGetPresentationTimeStamp(retained.sampleBuffer) == timing.presentationTimeStamp)
}

@Test func captureControllerFansTheSameSampleToObserverAndBoundedLocalSlot() async throws {
    let originalSample = try makeSampleBuffer()
    let sample = AnalysisSample(
        sequence: 4,
        timestampNanoseconds: 100_000_000,
        frame: try AnalysisFrame(sampleBuffer: originalSample)
    )
    let driver = SampleEmittingCaptureDriver()
    let observer = CaptureSampleObserver()
    let controller = CaptureSessionController(
        authorization: AuthorizedCaptureProvider(),
        driver: driver,
        analysisSampleObserver: observer.receive
    )
    try await controller.start()

    await driver.emit(sample)

    for _ in 0..<1_000 {
        if observer.first() != nil { break }
        await Task.yield()
    }
    let observed = try #require(observer.first())
    #expect(observed.frame?.sampleBuffer === originalSample)
    for _ in 0..<1_000 {
        if await controller.latestAnalysisSampleSequence == 4 { break }
        await Task.yield()
    }
    let local = try #require(await controller.takeLatestAnalysisSample())
    #expect(local.frame?.sampleBuffer === originalSample)
}

private struct AuthorizedCaptureProvider: CaptureAuthorizing {
    func status() async -> CaptureAuthorization { .authorized }
    func requestAccess() async -> CaptureAuthorization { .authorized }
}

private actor SampleEmittingCaptureDriver: CaptureSessionDriving {
    private var handler: (@Sendable (AnalysisSample) -> Void)?

    func configure(
        onAnalysisSample: @escaping @Sendable (AnalysisSample) -> Void
    ) async throws {
        handler = onAnalysisSample
    }

    func startRunning() async throws {}
    func stopRunning() async {}
    func capturePhoto(requestID: UInt64) async throws -> CapturedPhoto {
        _ = requestID
        throw CaptureSessionError.photoCaptureFailed("unused")
    }
    func cancelPhotoCapture(requestID: UInt64) async { _ = requestID }
    func tearDown() async {}
    func emit(_ sample: AnalysisSample) { handler?(sample) }
}

private final class CaptureSampleObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [AnalysisSample] = []

    func receive(_ sample: AnalysisSample) {
        lock.lock()
        samples.append(sample)
        lock.unlock()
    }

    func first() -> AnalysisSample? {
        lock.lock()
        defer { lock.unlock() }
        return samples.first
    }
}

private func makeSampleBuffer() throws -> CMSampleBuffer {
    var pixelBuffer: CVPixelBuffer?
    #expect(
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            16,
            12,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        ) == kCVReturnSuccess
    )
    let imageBuffer = try #require(pixelBuffer)
    var format: CMVideoFormatDescription?
    #expect(
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            formatDescriptionOut: &format
        ) == noErr
    )
    var timing = CMSampleTimingInfo(
        duration: .invalid,
        presentationTimeStamp: CMTime(value: 3, timescale: 30),
        decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    #expect(
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            formatDescription: try #require(format),
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr
    )
    return try #require(sampleBuffer)
}
#endif
