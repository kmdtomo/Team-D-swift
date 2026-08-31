#if os(iOS)
@preconcurrency import AVFoundation
import Foundation
import ImageIO
import SwiftUI

/// Only this default factory reads AVFoundation's global device-discovery API.
public protocol AVFoundationCaptureComponentFactory: AnyObject, Sendable {
    func makeSession() -> AVCaptureSession
    func makeVideoOutput() -> AVCaptureVideoDataOutput
    func makePhotoOutput() -> AVCapturePhotoOutput
    func makeBackCamera() -> AVCaptureDevice?
    func makeInput(device: AVCaptureDevice) throws -> AVCaptureDeviceInput
}

public final class DefaultAVFoundationCaptureComponentFactory: AVFoundationCaptureComponentFactory, @unchecked Sendable {
    public init() {}
    public func makeSession() -> AVCaptureSession { AVCaptureSession() }
    public func makeVideoOutput() -> AVCaptureVideoDataOutput { AVCaptureVideoDataOutput() }
    public func makePhotoOutput() -> AVCapturePhotoOutput { AVCapturePhotoOutput() }
    public func makeBackCamera() -> AVCaptureDevice? { AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) }
    public func makeInput(device: AVCaptureDevice) throws -> AVCaptureDeviceInput { try AVCaptureDeviceInput(device: device) }
}

/// The production authorization adapter is injectable like every other camera dependency.
public struct AVCaptureAuthorizationProvider: CaptureAuthorizing {
    public init() {}
    public func status() async -> CaptureAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .video) { case .notDetermined: .notDetermined; case .authorized: .authorized; case .denied: .denied; case .restricted: .restricted; @unknown default: .restricted }
    }
    public func requestAccess() async -> CaptureAuthorization { _ = await AVCaptureDevice.requestAccess(for: .video); return await status() }
}

/// `sessionQueue` is the sole reader/writer of all mutable AV fields, including
/// continuations. Delegate methods immediately hop to it before touching state.
public final class AVFoundationCaptureDriver: NSObject, CaptureSessionDriving, @unchecked Sendable {
    public let session: AVCaptureSession
    private let factory: any AVFoundationCaptureComponentFactory
    private let sessionQueue = DispatchQueue(label: "com.teamd.capture.session")
    private let videoOutput: AVCaptureVideoDataOutput
    private let photoOutput: AVCapturePhotoOutput
    private var input: AVCaptureDeviceInput?
    private var sampleHandler: (@Sendable (AnalysisSample) -> Void)?
    private var photoContinuation: CheckedContinuation<CapturedPhoto, Error>?
    private var photoRequestID: UInt64?
    private var photoSettingsID: Int64?
    // There can only be one in-flight photo. This single bounded tombstone closes
    // the cancellation-before-registration race without retaining request IDs.
    private var preCancelledPhotoRequestID: UInt64?
    private var sequence: UInt64 = 0
    private var configured = false

    public init(factory: any AVFoundationCaptureComponentFactory = DefaultAVFoundationCaptureComponentFactory()) {
        self.factory = factory; session = factory.makeSession(); videoOutput = factory.makeVideoOutput(); photoOutput = factory.makePhotoOutput(); super.init()
    }

    public func configure(onAnalysisSample: @escaping @Sendable (AnalysisSample) -> Void) async throws {
        try await enqueueThrowing { [self] in
            guard !configured else { return }
            guard let device = factory.makeBackCamera() else { throw CaptureSessionError.backCameraUnavailable }
            let newInput: AVCaptureDeviceInput
            do { newInput = try factory.makeInput(device: device) } catch { throw CaptureSessionError.configurationFailed("camera input unavailable") }
            session.beginConfiguration(); defer { session.commitConfiguration() }
            guard session.canAddInput(newInput) else { throw CaptureSessionError.cannotAddInput }
            guard session.canAddOutput(videoOutput) else { throw CaptureSessionError.cannotAddVideoOutput }
            guard session.canAddOutput(photoOutput) else { throw CaptureSessionError.cannotAddPhotoOutput }
            session.addInput(newInput); session.addOutput(videoOutput); session.addOutput(photoOutput)
            videoOutput.alwaysDiscardsLateVideoFrames = true; videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
            photoOutput.maxPhotoQualityPrioritization = .quality
            input = newInput; sampleHandler = onAnalysisSample; configured = true
        }
    }
    public func startRunning() async throws { try await enqueueThrowing { [self] in guard configured else { throw CaptureSessionError.configurationFailed("session is not configured") }; if !session.isRunning { session.startRunning() } } }
    public func stopRunning() async { await enqueue { [self] in if session.isRunning { session.stopRunning() } } }
    public func capturePhoto(requestID: UInt64) async throws -> CapturedPhoto {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async { [self] in
                guard photoContinuation == nil else { continuation.resume(throwing: CaptureSessionError.captureInProgress); return }
                guard session.isRunning else { continuation.resume(throwing: CaptureSessionError.notRunning); return }
                if preCancelledPhotoRequestID == requestID {
                    preCancelledPhotoRequestID = nil
                    continuation.resume(throwing: CaptureSessionError.cancelled)
                    return
                }
                preCancelledPhotoRequestID = nil
                let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg]); settings.photoQualityPrioritization = .quality
                photoContinuation = continuation; photoRequestID = requestID; photoSettingsID = settings.uniqueID
                photoOutput.capturePhoto(with: settings, delegate: self)
            }
        }
    }
    public func cancelPhotoCapture(requestID: UInt64) async {
        await enqueue { [self] in
            guard photoRequestID == requestID else {
                preCancelledPhotoRequestID = requestID
                return
            }
            resumePhoto(throwing: .cancelled)
        }
    }
    public func tearDown() async {
        await enqueue { [self] in
            if let request = photoRequestID { _ = request; resumePhoto(throwing: .cancelled) }
            if session.isRunning { session.stopRunning() }; videoOutput.setSampleBufferDelegate(nil, queue: nil)
            if let input { session.removeInput(input) }; if session.outputs.contains(videoOutput) { session.removeOutput(videoOutput) }; if session.outputs.contains(photoOutput) { session.removeOutput(photoOutput) }
            input = nil; sampleHandler = nil; preCancelledPhotoRequestID = nil; configured = false; sequence = 0
        }
    }
    private func resumePhoto(returning photo: CapturedPhoto) { let pending = photoContinuation; photoContinuation = nil; photoRequestID = nil; photoSettingsID = nil; pending?.resume(returning: photo) }
    private func resumePhoto(throwing error: CaptureSessionError) { let pending = photoContinuation; photoContinuation = nil; photoRequestID = nil; photoSettingsID = nil; pending?.resume(throwing: error) }
    private func enqueue(_ operation: @escaping @Sendable () -> Void) async { await withCheckedContinuation { continuation in sessionQueue.async { operation(); continuation.resume() } } }
    private func enqueueThrowing(_ operation: @escaping @Sendable () throws -> Void) async throws { try await withCheckedThrowingContinuation { continuation in sessionQueue.async { do { try operation(); continuation.resume() } catch { continuation.resume(throwing: error) } } } }
}

extension AVFoundationCaptureDriver: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Delegate queue is `sessionQueue`; all field access is therefore serialized.
        sequence &+= 1; if sequence == 0 { sequence = 1 }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard time.isNumeric, let nanos = AnalysisTimestamp.nanoseconds(seconds: time.seconds) else { return }
        guard let frame = try? AnalysisFrame(sampleBuffer: sampleBuffer) else { return }
        sampleHandler?(AnalysisSample(sequence: sequence, timestampNanoseconds: nanos, frame: frame))
    }
}

extension AVFoundationCaptureDriver: AVCapturePhotoCaptureDelegate {
    public func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let settingsID = photo.resolvedSettings.uniqueID
        sessionQueue.async { [weak self] in self?.finishPhoto(photo, error: error, settingsID: settingsID) }
    }
    private func finishPhoto(_ photo: AVCapturePhoto, error: Error?, settingsID: Int64) {
        guard photoContinuation != nil, photoSettingsID == settingsID else { return } // cancelled or stale callback
        guard error == nil, let data = photo.fileDataRepresentation() else { resumePhoto(throwing: .photoCaptureFailed("photo processing failed")); return }
        let metadata = photo.metadata; let dimensions = photo.resolvedSettings.photoDimensions
        resumePhoto(returning: .init(originalFileData: data, metadata: .init(contentType: AVFileType.jpg.rawValue, orientation: metadata[kCGImagePropertyOrientation as String] as? Int, colorSpaceName: metadata[kCGImagePropertyColorModel as String] as? String, pixelWidth: Int(dimensions.width), pixelHeight: Int(dimensions.height))))
    }
}

/// Display-only bridge; update only reconnects the supplied session identity.
@available(iOS 18.0, *) public struct CapturePreview: UIViewRepresentable {
    public let session: AVCaptureSession
    public init(session: AVCaptureSession) { self.session = session }
    public func makeUIView(context: Context) -> PreviewView { let view = PreviewView(); view.previewLayer.videoGravity = .resizeAspectFill; view.previewLayer.session = session; return view }
    public func updateUIView(_ uiView: PreviewView, context: Context) { if uiView.previewLayer.session !== session { uiView.previewLayer.session = session } }
}
public final class PreviewView: UIView { override public class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }; var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer } }
#endif
