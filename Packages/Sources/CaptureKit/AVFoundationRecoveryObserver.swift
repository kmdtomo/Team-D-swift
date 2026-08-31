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
        startObserving(session: session) { signal in
            Task {
                guard await controller.receive(signal) else { return }
                switch signal {
                case .interruptionEnded, .enteredForeground:
                    // The controller owns stale-session and failure mapping. A
                    // failed automatic resume remains visible and retryable.
                    try? await controller.recoverCamera()
                case .enteredBackground:
                    await controller.suspendCamera()
                case .interrupted, .runtimeError:
                    break
                }
            }
        }
    }

    @MainActor
    public func startObserving(session: AVCaptureSession, viewModel: CaptureRecoveryViewModel) {
        startObserving(session: session) { signal in
            Task { @MainActor in await viewModel.receive(signal) }
        }
    }

    /// Injectable signal delivery keeps NotificationCenter behavior testable
    /// without creating another capture-session owner.
    public func startObserving(
        session: AVCaptureSession,
        onSignal: @escaping @Sendable (CaptureLifecycleSignal) -> Void
    ) {
        stopObserving()
        tokens = [
            center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { _ in onSignal(.interrupted) },
            center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { _ in onSignal(.interruptionEnded) },
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { _ in onSignal(.runtimeError) },
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in onSignal(.enteredBackground) },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in onSignal(.enteredForeground) },
        ]
    }

    public func stopObserving() { tokens.forEach(center.removeObserver); tokens = [] }
    deinit { stopObserving() }
}
#endif
