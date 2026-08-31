import SwiftUI
import DomainKit

@main
struct TeamDApp: App {
    var body: some Scene {
        WindowGroup {
            CameraFlowScaffoldView()
        }
    }
}

/// A deliberately non-navigational scaffold. T02-02 replaces this with the
/// injected, camera-first session composition root; it is not a home screen.
private struct CameraFlowScaffoldView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("撮影フローを準備しています")
                .font(.headline)
                .accessibilityIdentifier("camera-flow-scaffold")
            Text("カメラセッションは次の実装タスクで有効になります。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}
