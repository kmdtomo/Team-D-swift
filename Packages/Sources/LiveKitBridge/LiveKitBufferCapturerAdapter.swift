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
        guard let pixelBuffer = sample.frame?.pixelBuffer else { return nil }
        return try AppProducedVideoFrame(
            sequence: sample.sequence,
            timestampNanoseconds: sample.timestampNanoseconds,
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            orientation: orientation
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

    public init(track: LocalVideoTrack) throws {
        guard let capturer = track.capturer as? BufferCapturer else {
            throw AppProducedVideoFrameError.unavailableSDK
        }
        self.capturer = capturer
    }

    public func publish(_ frame: AppProducedVideoFrame) async throws {
        // Metadata alone is intentionally insufficient to publish pixels. This
        // makes an incorrectly wired integration fail explicitly instead of
        // looking like a successful fixture camera.
        _ = frame
        throw AppProducedVideoFrameError.unavailableSDK
    }

    /// The only production pixel handoff. The sample must originate in T05's
    /// already-configured video output; this adapter never creates an AVCapture
    /// input, output, or session. `metadata` is kept explicit so T08-02 can
    /// assert the source sequence and rotation before publishing.
    public func publish(
        sampleBuffer: CMSampleBuffer,
        metadata: AppProducedVideoFrame
    ) throws {
        guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil else {
            throw AppProducedVideoFrameError.invalidMetadata
        }
        // The T05 capture connection owns video rotation before the frame leaves
        // AVFoundation. BufferCapturer accepts that original CMSampleBuffer;
        // `metadata.orientation` is retained for an integration assertion rather
        // than being guessed or transformed by a second camera pipeline.
        _ = metadata.orientation
        capturer.capture(sampleBuffer)
    }

    public func cancelPublishing() async {}
}
#endif
#endif
