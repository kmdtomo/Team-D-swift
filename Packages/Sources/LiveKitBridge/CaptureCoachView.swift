import DomainKit
import Foundation

public enum CaptureCoachRecoveryControl: Equatable, Sendable {
    case none
    case retry
    case retake

    public var localizedLabel: String? {
        switch self {
        case .none: nil
        case .retry: "もう一度試す"
        case .retake: "撮り直す"
        }
    }

    public var accessibilityIdentifier: String? {
        switch self {
        case .none: nil
        case .retry: CaptureCoachAccessibilityID.retry
        case .retake: CaptureCoachAccessibilityID.retake
        }
    }
}

public enum CaptureCoachAccessibilityID {
    public static let root = "capture-coach"
    public static let shot = "capture-current-shot"
    public static let progress = "capture-progress"
    public static let completedProgress = "capture-completed-progress"
    public static let instruction = "capture-primary-instruction"
    public static let connection = "capture-connection-state"
    public static let fixtureBadge = "fixture-mode-badge"
    public static let shutter = "capture-shutter"
    public static let retry = "capture-retry"
    public static let retake = "capture-retake"
}

/// Binary-free, app-owned input for the native capture surface. The type has no
/// field for backend prose, confidence, next action, navigation, or image data.
public struct CaptureCoachSurfaceState: Equatable, Sendable {
    public let coach: CaptureCoachViewState
    public let recoveryControl: CaptureCoachRecoveryControl
    public let isFixture: Bool

    public init(
        coach: CaptureCoachViewState,
        recoveryControl: CaptureCoachRecoveryControl = .none,
        isFixture: Bool
    ) {
        self.coach = coach
        self.recoveryControl = recoveryControl
        self.isFixture = isFixture
    }

    public var instructionText: String {
        coach.instruction?.localizedText ?? Self.defaultInstruction(for: coach.shot)
    }

    public var shutterLabel: String {
        if coach.isBusy { return "撮影中" }
        return coach.isRetake ? "撮り直す" : "撮影する"
    }

    public var shutterAccessibilityHint: String {
        coach.isShutterEnabled
            ? "現在の写真を撮影します。READYの表示がなくても撮影できます"
            : "カメラが利用可能になり、撮影処理が終わるまで待ってください"
    }

    private static func defaultInstruction(for shot: Shot) -> String {
        switch shot {
        case .front, .back: "衣類全体をガイドに合わせてください"
        case .tag: "タグをガイドに合わせてください"
        case .measurement: "衣類と50mmマーカーをガイドに合わせてください"
        }
    }
}

#if canImport(SwiftUI)
import SwiftUI

/// A camera-first five-layer surface. Preview and guide pixels are supplied by
/// the camera owner and remain accessibility-hidden; this view never renders
/// either layer into a captured image.
@available(iOS 18.0, macOS 14.0, *)
public struct CaptureCoachView<Preview: View, Guide: View>: View {
    private let state: CaptureCoachSurfaceState
    private let preview: () -> Preview
    private let guide: () -> Guide
    private let onShutter: () -> Void
    private let onRetry: () -> Void
    private let onRetake: () -> Void

    public init(
        state: CaptureCoachSurfaceState,
        onShutter: @escaping () -> Void,
        onRetry: @escaping () -> Void = {},
        onRetake: @escaping () -> Void = {},
        @ViewBuilder preview: @escaping () -> Preview,
        @ViewBuilder guide: @escaping () -> Guide
    ) {
        self.state = state
        self.onShutter = onShutter
        self.onRetry = onRetry
        self.onRetake = onRetake
        self.preview = preview
        self.guide = guide
    }

    public var body: some View {
        ZStack {
            preview()
                .ignoresSafeArea()
                .accessibilityHidden(true)

            guide()
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            VStack(spacing: 12) {
                header
                Spacer(minLength: 12)
                guidancePanel
                shutter
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color.black)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(CaptureCoachAccessibilityID.root)
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                shotAndProgress
                Spacer(minLength: 8)
                modeBadge
            }
            VStack(alignment: .leading, spacing: 8) {
                shotAndProgress
                modeBadge
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var shotAndProgress: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(state.coach.shotText)
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier(CaptureCoachAccessibilityID.shot)
                .accessibilitySortPriority(50)
            HStack(spacing: 8) {
                Text(state.coach.progressText)
                    .accessibilityIdentifier(CaptureCoachAccessibilityID.progress)
                Text(state.coach.completedProgressText)
                    .accessibilityIdentifier(CaptureCoachAccessibilityID.completedProgress)
            }
            .font(.subheadline.weight(.medium))
            .accessibilitySortPriority(49)
        }
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private var modeBadge: some View {
        if state.isFixture {
            Text("テストデータ")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(.regularMaterial, in: Capsule())
                .accessibilityIdentifier(CaptureCoachAccessibilityID.fixtureBadge)
                .accessibilitySortPriority(45)
        }
    }

    private var guidancePanel: some View {
        ScrollView(.vertical) {
            VStack(spacing: 10) {
                Text(state.instructionText)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier(CaptureCoachAccessibilityID.instruction)
                    .accessibilitySortPriority(40)

                Text(state.coach.connectionText)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier(CaptureCoachAccessibilityID.connection)
                    .accessibilitySortPriority(30)

                recoveryButton
            }
            .padding(14)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: 240)
        .foregroundStyle(.white)
        .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder
    private var recoveryButton: some View {
        if let label = state.recoveryControl.localizedLabel,
           let identifier = state.recoveryControl.accessibilityIdentifier {
            Button(label) {
                switch state.recoveryControl {
                case .retry: onRetry()
                case .retake: onRetake()
                case .none: break
                }
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity, minHeight: 44)
            .accessibilityIdentifier(identifier)
            .accessibilitySortPriority(20)
        }
    }

    private var shutter: some View {
        Button(action: onShutter) {
            Label(state.shutterLabel, systemImage: "camera.circle.fill")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(.borderedProminent)
        .tint(.white)
        .foregroundStyle(.black)
        .disabled(!state.coach.isShutterEnabled)
        .accessibilityIdentifier(CaptureCoachAccessibilityID.shutter)
        .accessibilityHint(state.shutterAccessibilityHint)
        .accessibilitySortPriority(10)
    }
}
#endif
