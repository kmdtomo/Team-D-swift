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
        self.zoom = Self.clamp(zoom.isFinite ? zoom : Self.minimumZoom, Self.minimumZoom, Self.maximumZoom)
        self.centerX = Self.clamp(centerX.isFinite ? centerX : 0.5, 0, 1)
        self.centerY = Self.clamp(centerY.isFinite ? centerY : 0.5, 0, 1)
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
    public private(set) var viewport: ComparisonViewport

    public init(
        originalID: String,
        compositeAvailability: CompositeComparisonAvailability = .unavailable,
        viewport: ComparisonViewport = .init()
    ) {
        precondition(!originalID.isEmpty, "An original front image ID is required")
        self.original = .init(id: originalID, choice: .original)
        self.composite = compositeAvailability.candidate
        self.selection = nil
        self.approvedOutputID = nil
        self.viewport = viewport
    }

    public var selectableChoices: [ImageComparisonChoice] {
        composite == nil ? [.original] : [.original, .composite]
    }

    public var selectedCandidate: ImageComparisonCandidate? {
        candidate(for: selection)
    }

    /// The finite, app-owned choice behind an approved output ID. UI must use
    /// this value rather than exposing an internal session image ID.
    public var approvedChoice: ImageComparisonChoice? {
        guard let approvedOutputID else { return nil }
        if approvedOutputID == original.id { return .original }
        if approvedOutputID == composite?.id { return .composite }
        return nil
    }

    public var approvedChoiceLabel: String? {
        approvedChoice?.localizedName
    }

    public mutating func select(_ choice: ImageComparisonChoice) {
        guard candidate(for: choice) != nil else { return }
        guard selection != choice else { return }
        selection = choice
        approvedOutputID = nil
    }

    /// Explicit final confirmation. A selection alone is never approval.
    public mutating func confirmSelection() {
        approvedOutputID = selectedCandidate?.id
    }

    public mutating func setViewport(_ viewport: ComparisonViewport) {
        self.viewport = viewport
    }

    /// Starts a replacement generation without retaining a stale composite as
    /// selectable. An already-approved original remains approved.
    public mutating func beginCompositeRegeneration() {
        let invalidatedCompositeID = composite?.id
        composite = nil
        if selection == .composite {
            selection = nil
        }
        if approvedOutputID == invalidatedCompositeID {
            approvedOutputID = nil
        }
    }

    /// Replaces a generated result. If the old composite was selected or
    /// approved, invalidate both states before the new output can be chosen.
    public mutating func replaceComposite(with availability: CompositeComparisonAvailability) {
        let previousCompositeID = composite?.id
        composite = availability.candidate
        if selection == .composite {
            selection = nil
        }
        if approvedOutputID == previousCompositeID {
            approvedOutputID = nil
        }
    }

    private func candidate(for choice: ImageComparisonChoice?) -> ImageComparisonCandidate? {
        switch choice {
        case .original: original
        case .composite: composite
        case nil: nil
        }
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
            imageContent(candidate, state.viewport)
                .accessibilityHidden(true)

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

    private var approvalText: String {
        if let approvedChoiceLabel = state.approvedChoiceLabel {
            return "選択した画像を確定しました: \(approvedChoiceLabel)"
        }
        return state.selection == nil ? "画像を選択してください" : "画像は未確定です"
    }
}

#endif
