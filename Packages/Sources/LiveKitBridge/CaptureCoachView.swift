#if canImport(SwiftUI)
import SwiftUI

/// A camera-screen fragment: the caller provides the live preview and fixed
/// guide, while this view keeps status, one instruction, and shutter stationary.
public struct CaptureCoachView<Preview: View, Guide: View>: View {
    public let state: CaptureCoachViewState
    private let preview: Preview
    private let guide: Guide
    private let capture: () -> Void

    public init(
        state: CaptureCoachViewState,
        @ViewBuilder preview: () -> Preview,
        @ViewBuilder guide: () -> Guide,
        capture: @escaping () -> Void
    ) {
        self.state = state
        self.preview = preview()
        self.guide = guide()
        self.capture = capture
    }

    public var body: some View {
        ZStack {
            preview
                .accessibilityHidden(true)
                .ignoresSafeArea()
            guide
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(state.shotText) \(state.progressText)")
                            .font(.headline)
                        Text(state.completedProgressText)
                            .font(.subheadline)
                    }
                    Spacer()
                    Text(state.connectionText)
                        .font(.caption)
                        .multilineTextAlignment(.trailing)
                }
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
                Spacer()
            }
            .accessibilityElement(children: .contain)
            .accessibilitySortPriority(4)

            VStack(spacing: 14) {
                if let instruction = state.instruction {
                    Text(instruction.localizedText)
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(.regularMaterial, in: Capsule())
                        .accessibilityIdentifier("capture-coach-instruction-\(state.announcementID)")
                }
                Button(action: capture) {
                    Image(systemName: state.isBusy ? "hourglass" : "camera.circle.fill")
                        .font(.system(size: 64))
                        .frame(width: 72, height: 72)
                }
                .buttonStyle(.plain)
                .disabled(!state.isShutterEnabled)
                .accessibilityLabel(state.isRetake ? "撮り直す" : "撮影する")
                .accessibilityHint(state.isShutterEnabled ? "撮影します" : "カメラの準備中です")
                .accessibilityValue(state.isBusy ? "撮影中" : "")
                .accessibilitySortPriority(1)
            }
            .padding(.bottom, 24)
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .accessibilityElement(children: .contain)
    }
}
#endif
