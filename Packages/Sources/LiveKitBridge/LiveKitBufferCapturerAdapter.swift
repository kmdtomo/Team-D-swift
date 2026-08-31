#if os(iOS)
import AVFoundation
import CaptureKit
import CoreMedia
import CoreVideo
import Foundation

/// Converts an already-emitted video-output buffer into the metadata boundary
/// used by the publish coordinator. It neither configures nor creates an
/// `AVCaptureSession`; the caller must use the T05 capture driver's sole output.
public enum AppProducedCaptureSampleAdapter {
    public static func makeFrame(
        sample: AnalysisSample,
        orientation: CaptureVideoOrientation
    ) throws -> AppProducedVideoFrame? {
        guard let originalSample = sample.frame else { return nil }
        let pixelBuffer = originalSample.pixelBuffer
        return try AppProducedVideoFrame(
            sequence: sample.sequence,
            timestampNanoseconds: sample.timestampNanoseconds,
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            orientation: orientation,
            originalSample: originalSample
        )
    }
}

#if canImport(LiveKit)
import LiveKit

/// LiveKit SDK 2.16.0 adapter. This is intentionally created only after the app
/// has joined a Room and obtained an app-owned track. It uses the official
/// `LocalVideoTrack.createBufferTrack`/`BufferCapturer.capture` API and never
/// uses the SDK camera capturer.
public final class LiveKitBufferCapturerAdapter: AppProducedVideoFramePublishing, @unchecked Sendable {
    private let capturer: BufferCapturer
    private let didCaptureFrame: @Sendable () async -> Void

    public init(
        track: LocalVideoTrack,
        didCaptureFrame: @escaping @Sendable () async -> Void = {}
    ) throws {
        guard let capturer = track.capturer as? BufferCapturer else {
            throw AppProducedVideoFrameError.unavailableSDK
        }
        self.capturer = capturer
        self.didCaptureFrame = didCaptureFrame
    }

    public func publish(_ frame: AppProducedVideoFrame) async throws {
        guard let originalSample = frame.originalSample,
              CMSampleBufferGetImageBuffer(originalSample.sampleBuffer) != nil
        else { throw AppProducedVideoFrameError.invalidMetadata }
        // The T05 capture connection owns video rotation before the frame leaves
        // AVFoundation. BufferCapturer accepts that original CMSampleBuffer;
        // `frame.orientation` is retained for an integration assertion rather
        // than being guessed or transformed by a second camera pipeline.
        _ = frame.orientation
        capturer.capture(originalSample.sampleBuffer)
        await didCaptureFrame()
    }

    public func cancelPublishing() async {}
}
#endif
#endif
