import Foundation

/// Identifies one of the two front-image candidates offered for final approval.
public enum ImageComparisonChoice: String, CaseIterable, Sendable, Equatable, Identifiable {
    case original
    case composite

    public var id: String { rawValue }

    public var localizedName: String {
        switch self {
        case .original: "元の画像"
        case .composite: "背景を変更した画像"
        }
    }
}

/// A candidate whose bytes remain owned by the in-memory session. This type
/// deliberately contains only an ID: exporting or persisting an approved
/// candidate belongs to T16-02.
public struct ImageComparisonCandidate: Sendable, Equatable, Identifiable {
    public let id: String
    public let choice: ImageComparisonChoice

    public init(id: String, choice: ImageComparisonChoice) {
        self.id = id
        self.choice = choice
    }
}

/// The validated state of a compositor result. Invalid or incomplete results
/// are intentionally not candidates and cannot enter the selection UI.
public enum CompositeComparisonAvailability: Sendable, Equatable {
    case unavailable
    case available(id: String)

    public init(candidateID: String?, isComplete: Bool, isValid: Bool) {
        guard let candidateID, !candidateID.isEmpty, isComplete, isValid else {
            self = .unavailable
            return
        }
        self = .available(id: candidateID)
    }

    public var candidate: ImageComparisonCandidate? {
        guard case let .available(id) = self else { return nil }
        return .init(id: id, choice: .composite)
    }
}

/// A shared crop and zoom policy for both image renderings. Center values are
/// normalized to the image, while zoom is limited to a finite, practical range.
public struct ComparisonViewport: Sendable, Equatable {
    public static let minimumZoom = 1.0
    public static let maximumZoom = 8.0

    public let zoom: Double
    public let centerX: Double
    public let centerY: Double

    public init(zoom: Double = 1, centerX: Double = 0.5, centerY: Double = 0.5) {
        let resolvedZoom = Self.clamp(zoom.isFinite ? zoom : Self.minimumZoom, Self.minimumZoom, Self.maximumZoom)
        self.zoom = resolvedZoom
        self.centerX = Self.clampCenter(centerX.isFinite ? centerX : 0.5, for: resolvedZoom)
        self.centerY = Self.clampCenter(centerY.isFinite ? centerY : 0.5, for: resolvedZoom)
    }

    /// Returns the same viewport with a finite magnification applied. A zoom of
    /// one keeps the complete image visible; greater zooms constrain the center
    /// so that both comparison candidates retain identical valid crops.
    public func magnified(by factor: Double) -> Self {
        let resolvedFactor = factor.isFinite && factor > 0 ? factor : Self.minimumZoom / zoom
        return .init(zoom: zoom * resolvedFactor, centerX: centerX, centerY: centerY)
    }

    /// Pans the displayed content by a normalized viewport translation. The
    /// sign follows the drag: moving content right moves the crop center left.
    public func panned(byNormalizedTranslationX x: Double, y: Double) -> Self {
        let translationX = x.isFinite ? x : 0
        let translationY = y.isFinite ? y : 0
        return .init(
            zoom: zoom,
            centerX: centerX - translationX / zoom,
            centerY: centerY - translationY / zoom
        )
    }

    public static var initial: Self { .init() }

    private static func clampCenter(_ value: Double, for zoom: Double) -> Double {
        let visibleHalfExtent = 0.5 / zoom
        return clamp(value, visibleHalfExtent, 1 - visibleHalfExtent)
    }

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(value, lower), upper)
    }
}

/// Pure view state for original/composite comparison. Selection and approval
/// are separate transitions: selecting never sets `approvedOutputID`.
public struct ImageComparisonState: Sendable, Equatable {
    public let original: ImageComparisonCandidate
    public private(set) var composite: ImageComparisonCandidate?
    public private(set) var selection: ImageComparisonChoice?
    public private(set) var approvedOutputID: String?
    /// Approval is typed so equal raw IDs can never change the user's choice.
    /// `approvedOutputID` remains available as the downstream export boundary.
    public private(set) var approvedChoice: ImageComparisonChoice?
    public private(set) var viewport: ComparisonViewport

    public init(
        originalID: String,
        compositeAvailability: CompositeComparisonAvailability = .unavailable,
        viewport: ComparisonViewport = .init()
    ) {
        precondition(!originalID.isEmpty, "An original front image ID is required")
        self.original = .init(id: originalID, choice: .original)
        self.composite = Self.validComposite(from: compositeAvailability, originalID: originalID)
        self.selection = nil
        self.approvedOutputID = nil
        self.approvedChoice = nil
        self.viewport = viewport
    }

    public var selectableChoices: [ImageComparisonChoice] {
        composite == nil ? [.original] : [.original, .composite]
    }

    public var selectedCandidate: ImageComparisonCandidate? {
        candidate(for: selection)
    }

    public var approvedChoiceLabel: String? {
        approvedChoice?.localizedName
    }

    public mutating func select(_ choice: ImageComparisonChoice) {
        guard candidate(for: choice) != nil else { return }
        guard selection != choice else { return }
        selection = choice
        approvedOutputID = nil
        approvedChoice = nil
    }

    /// Explicit final confirmation. A selection alone is never approval.
    public mutating func confirmSelection() {
        guard let selectedCandidate else {
            approvedOutputID = nil
            approvedChoice = nil
            return
        }
        approvedOutputID = selectedCandidate.id
        approvedChoice = selectedCandidate.choice
    }

    public mutating func setViewport(_ viewport: ComparisonViewport) {
        self.viewport = viewport
    }

    public mutating func magnifyViewport(by factor: Double) {
        viewport = viewport.magnified(by: factor)
    }

    public mutating func panViewport(byNormalizedTranslationX x: Double, y: Double) {
        viewport = viewport.panned(byNormalizedTranslationX: x, y: y)
    }

    public mutating func resetViewport() {
        viewport = .initial
    }

    /// Starts a replacement generation without retaining a stale composite as
    /// selectable. An already-approved original remains approved.
    public mutating func beginCompositeRegeneration() {
        composite = nil
        if selection == .composite {
            selection = nil
        }
        if approvedChoice == .composite {
            approvedOutputID = nil
            approvedChoice = nil
        }
    }

    /// Replaces a generated result. If the old composite was selected or
    /// approved, invalidate both states before the new output can be chosen.
    public mutating func replaceComposite(with availability: CompositeComparisonAvailability) {
        composite = Self.validComposite(from: availability, originalID: original.id)
        if selection == .composite {
            selection = nil
        }
        if approvedChoice == .composite {
            approvedOutputID = nil
            approvedChoice = nil
        }
    }

    private func candidate(for choice: ImageComparisonChoice?) -> ImageComparisonCandidate? {
        switch choice {
        case .original: original
        case .composite: composite
        case nil: nil
        }
    }

    /// A composite with the original's session ID is ambiguous at the export
    /// boundary. Reject it deterministically instead of making it selectable.
    private static func validComposite(
        from availability: CompositeComparisonAvailability,
        originalID: String
    ) -> ImageComparisonCandidate? {
        guard let candidate = availability.candidate, candidate.id != originalID else { return nil }
        return candidate
    }
}

#if canImport(SwiftUI)
import SwiftUI

/// A vertically adaptive SwiftUI comparison surface. The caller owns image
/// decoding, while this component supplies the same modeled viewport to each
/// rendering and keeps selection separate from explicit approval.
@available(iOS 18, macOS 14, *)
public struct ImageComparisonView<ImageContent: View>: View {
    @Binding private var state: ImageComparisonState
    private let imageContent: (ImageComparisonCandidate, ComparisonViewport) -> ImageContent
    private let onRegenerateComposite: () -> Void
    @State private var magnificationStartViewport: ComparisonViewport?
    @State private var panStartViewport: ComparisonViewport?

    public init(
        state: Binding<ImageComparisonState>,
        onRegenerateComposite: @escaping () -> Void,
        @ViewBuilder imageContent: @escaping (ImageComparisonCandidate, ComparisonViewport) -> ImageContent
    ) {
        _state = state
        self.onRegenerateComposite = onRegenerateComposite
        self.imageContent = imageContent
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("画像を比較")
                    .font(.title2.weight(.semibold))

                candidateSection(state.original)

                if let composite = state.composite {
                    candidateSection(composite)
                }

                viewportControls

                Button("背景を作り直す") {
                    state.beginCompositeRegeneration()
                    onRegenerateComposite()
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityLabel("背景を作り直す")
                .accessibilityHint("合成画像の選択と確定を取り消して、背景を作り直します")

                Button("この画像を使う") {
                    state.confirmSelection()
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity, minHeight: 44)
                .disabled(state.selection == nil)
                .accessibilityHint("選択した画像を確定します")

                Text(approvalText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("承認状態")
                    .accessibilityValue(approvalText)
            }
            .padding()
        }
    }

    @ViewBuilder
    private func candidateSection(_ candidate: ImageComparisonCandidate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            interactiveImage(candidate)

            Button {
                state.select(candidate.choice)
            } label: {
                HStack {
                    Text(candidate.choice.localizedName)
                    Spacer()
                    if state.selection == candidate.choice {
                        Image(systemName: "checkmark.circle.fill")
                            .accessibilityHidden(true)
                    }
                }
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity, minHeight: 44)
            .accessibilityLabel(candidate.choice.localizedName)
            .accessibilityValue(state.selection == candidate.choice ? "選択中" : "未選択")
            .accessibilityHint("この画像を選択します。確定にはこの画像を使うを選びます")
        }
    }

    private func interactiveImage(_ candidate: ImageComparisonCandidate) -> some View {
        imageContent(candidate, state.viewport)
            .overlay {
                GeometryReader { proxy in
                    Color.clear
                        .contentShape(Rectangle())
                        .simultaneousGesture(magnificationGesture)
                        .simultaneousGesture(panGesture(in: proxy.size))
                }
            }
            .accessibilityHidden(true)
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { factor in
                let initial = magnificationStartViewport ?? state.viewport
                magnificationStartViewport = initial
                state.setViewport(initial.magnified(by: factor))
            }
            .onEnded { _ in
                magnificationStartViewport = nil
            }
    }

    private func panGesture(in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let initial = panStartViewport ?? state.viewport
                panStartViewport = initial
                let width = max(size.width, 1)
                let height = max(size.height, 1)
                state.setViewport(initial.panned(
                    byNormalizedTranslationX: value.translation.width / width,
                    y: value.translation.height / height
                ))
            }
            .onEnded { _ in
                panStartViewport = nil
            }
    }

    private var viewportControls: some View {
        HStack(spacing: 12) {
            Button("縮小") {
                state.magnifyViewport(by: 1 / 1.5)
            }
            .buttonStyle(.bordered)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityHint("2枚の画像を同じ表示範囲のまま縮小します")

            Button("拡大") {
                state.magnifyViewport(by: 1.5)
            }
            .buttonStyle(.bordered)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityHint("2枚の画像を同じ表示範囲のまま拡大します")

            Button("表示位置をリセット") {
                state.resetViewport()
            }
            .buttonStyle(.bordered)
            .frame(minHeight: 44)
            .accessibilityHint("拡大率と表示位置を初期状態に戻します")
        }
        .accessibilityElement(children: .contain)
    }

    private var approvalText: String {
        if let approvedChoiceLabel = state.approvedChoiceLabel {
            return "選択した画像を確定しました: \(approvedChoiceLabel)"
        }
        return state.selection == nil ? "画像を選択してください" : "画像は未確定です"
    }
}

#endif
