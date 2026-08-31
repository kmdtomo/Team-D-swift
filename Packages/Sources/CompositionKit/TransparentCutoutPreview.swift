/// Stable, app-owned semantics for the transparent intermediate preview. These
/// values intentionally expose no selection, approval, or export capability.
public enum TransparentCutoutPreviewSemantics {
    public static let title = "背景を透明にした確認画像"
    public static let detail = "市松模様の部分は透明です"
    public static let restriction = "確認用のため、選択・承認・保存はできません"
    public static let accessibilityLabel = "背景を透明にした確認画像。市松模様の部分は透明です"
    public static let accessibilityHint = "確認用です。選択、承認、保存はできません"
    public static let accessibilityIdentifier = "editing.transparent-cutout-preview"

    public static let permitsSelection = false
    public static let permitsApproval = false
    public static let permitsExport = false
}

#if canImport(CoreGraphics) && canImport(SwiftUI)
import CoreGraphics
import SwiftUI

/// Displays a validated straight-alpha cutout over a fixed checkerboard. The
/// pixel surface is decorative to VoiceOver; one stable Japanese description
/// communicates the purpose and the non-approvable intermediate state.
@available(iOS 18, macOS 14, *)
public struct TransparentCutoutPreview: View {
    private let cutout: CGImage

    public init(cutout: CGImage) {
        self.cutout = cutout
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(TransparentCutoutPreviewSemantics.title)
                .font(.headline)

            ZStack {
                Color.white
                CheckerboardTiles(tileSize: 18)
                    .fill(Color(red: 0.38, green: 0.38, blue: 0.40))
                Image(decorative: cutout, scale: 1, orientation: .up)
                    .resizable()
                    .scaledToFit()
            }
            .aspectRatio(
                CGFloat(cutout.width) / CGFloat(cutout.height),
                contentMode: .fit
            )
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.primary.opacity(0.35), lineWidth: 1)
            }
            .accessibilityHidden(true)

            Text(TransparentCutoutPreviewSemantics.detail)
                .font(.subheadline)

            Text(TransparentCutoutPreviewSemantics.restriction)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(TransparentCutoutPreviewSemantics.accessibilityLabel)
        .accessibilityHint(TransparentCutoutPreviewSemantics.accessibilityHint)
        .accessibilityIdentifier(TransparentCutoutPreviewSemantics.accessibilityIdentifier)
        .accessibilityAddTraits(.isImage)
    }
}

private struct CheckerboardTiles: Shape {
    let tileSize: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var row = 0
        var y = rect.minY
        while y < rect.maxY {
            var column = 0
            var x = rect.minX
            while x < rect.maxX {
                if (row + column).isMultiple(of: 2) {
                    path.addRect(CGRect(
                        x: x,
                        y: y,
                        width: min(tileSize, rect.maxX - x),
                        height: min(tileSize, rect.maxY - y)
                    ))
                }
                column += 1
                x += tileSize
            }
            row += 1
            y += tileSize
        }
        return path
    }
}
#endif
