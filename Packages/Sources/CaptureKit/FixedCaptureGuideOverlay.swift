#if os(iOS)
import SwiftUI

/// Decorative, preview-only rendering; it has no image data API and cannot affect originals.
@available(iOS 18.0, *)
public struct FixedCaptureGuideOverlay: View {
    public let layout: FixedGuideLayout
    @Environment(\.accessibilityContrast) private var accessibilityContrast
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    public init(layout: FixedGuideLayout) { self.layout = layout }
    public var body: some View {
        Canvas { context, _ in
            stroke(layout.primary.previewRect, kind: layout.primary.kind, context: &context)
            if let markerPlacement = layout.markerPlacement { stroke(markerPlacement.previewRect, kind: markerPlacement.kind, context: &context) }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
    private func stroke(_ rect: PreviewGuideRect, kind: FixedGuideKind, context: inout GraphicsContext) {
        let path = Path(CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height))
        let lineWidth: CGFloat = accessibilityContrast == .high ? 3 : 2
        let color: Color = differentiateWithoutColor ? .white : .yellow
        context.stroke(path, with: .color(color.opacity(accessibilityContrast == .high ? 1 : 0.9)), lineWidth: lineWidth)
        if kind == .markerPlacement50mm { context.stroke(path, with: .color(.black.opacity(0.75)), style: .init(lineWidth: lineWidth + 2, dash: [5, 4])) }
    }
}

@available(iOS 18.0, *)
#Preview("Measurement guide") {
    let geometry = try! PreviewImageGeometry(imageSize: .init(width: 3, height: 4), previewSize: .init(width: 393, height: 852), contentMode: .aspectFill)
    let layout = try! FixedGuideLayout(shot: .measurement, previewGeometry: geometry, uprightOrientation: .up, safeAreaInsets: .init(top: 59, bottom: 34))
    ZStack { Color.gray; FixedCaptureGuideOverlay(layout: layout) }
}
#endif
