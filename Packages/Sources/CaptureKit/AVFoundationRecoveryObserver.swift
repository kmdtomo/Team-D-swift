#if os(iOS)
@preconcurrency import AVFoundation
import Foundation
import UIKit

/// Notification ownership is explicit and detachable so a dead capture flow
/// cannot resume a newer session after navigation or teardown.
@available(iOS 18.0, *)
public final class AVFoundationRecoveryObserver: @unchecked Sendable {
    private let center: NotificationCenter
    private var tokens: [NSObjectProtocol] = []

    public init(center: NotificationCenter = .default) { self.center = center }

    public func startObserving(session: AVCaptureSession, controller: CaptureRecoveryController) {
        stopObserving()
        let emit: @Sendable (CaptureLifecycleSignal) -> Void = { signal in Task { await controller.receive(signal) } }
        tokens = [
            center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { _ in emit(.interrupted) },
            center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { _ in emit(.interruptionEnded) },
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { _ in emit(.runtimeError) },
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in emit(.enteredBackground) },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { _ in emit(.enteredForeground) },
        ]
    }

    public func stopObserving() { tokens.forEach(center.removeObserver); tokens = [] }
    deinit { stopObserving() }
}
#endif
