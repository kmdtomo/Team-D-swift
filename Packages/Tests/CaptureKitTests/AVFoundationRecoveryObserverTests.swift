#if os(iOS)
import AVFoundation
import CaptureKit
import Foundation
import UIKit
import XCTest

@available(iOS 18.0, *)
final class AVFoundationRecoveryObserverTests: XCTestCase {
    func testObserverMapsOnlyOwnedSessionAndApplicationLifecycleNotifications() {
        let center = NotificationCenter()
        let ownedSession = AVCaptureSession()
        let unrelatedSession = AVCaptureSession()
        let recorder = LockedLifecycleSignalRecorder()
        let observer = AVFoundationRecoveryObserver(center: center)
        observer.startObserving(session: ownedSession) { recorder.record($0) }

        center.post(name: AVCaptureSession.wasInterruptedNotification, object: unrelatedSession)
        center.post(name: AVCaptureSession.wasInterruptedNotification, object: ownedSession)
        center.post(name: AVCaptureSession.interruptionEndedNotification, object: ownedSession)
        center.post(name: AVCaptureSession.runtimeErrorNotification, object: ownedSession)
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)

        XCTAssertEqual(recorder.values, [
            .interrupted,
            .interruptionEnded,
            .runtimeError,
            .enteredBackground,
            .enteredForeground,
        ])

        observer.stopObserving()
        center.post(name: AVCaptureSession.wasInterruptedNotification, object: ownedSession)
        XCTAssertEqual(recorder.values.count, 5)
    }
}

private final class LockedLifecycleSignalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CaptureLifecycleSignal] = []

    var values: [CaptureLifecycleSignal] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ signal: CaptureLifecycleSignal) {
        lock.lock()
        storage.append(signal)
        lock.unlock()
    }
}
#endif
