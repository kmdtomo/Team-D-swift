import DomainKit
import SwiftUI

/// Corrected-image endpoint editor and explicit CV-measurement approval surface.
@available(iOS 18.0, *)
public struct MeasurementEndpointEditorOverlay: View {
    private let correctedImage: Image
    private let garmentPolygon: CorrectedMeasurementGarmentPolygon
    private let onWorkflowEvent: (WorkflowEvent) -> Void
    @Binding private var editor: MeasurementEndpointEditor

    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var magnificationBase: CGFloat = 1
    @State private var panBase: CGSize = .zero
    @State private var rangeConfirmation: MeasurementRangeConfirmation?
    @State private var isRangeWarningPresented = false
    @State private var approvalFeedback: ApprovalFeedback?

    public init(
        correctedImage: Image,
        editor: Binding<MeasurementEndpointEditor>,
        garmentPolygon: CorrectedMeasurementGarmentPolygon,
        onWorkflowEvent: @escaping (WorkflowEvent) -> Void
    ) {
        self.correctedImage = correctedImage
        self.garmentPolygon = garmentPolygon
        self.onWorkflowEvent = onWorkflowEvent
        _editor = editor
    }

    public var body: some View {
        GeometryReader { proxy in
            let mapper = try? MeasurementImageCoordinateMapper(
                imageSize: editor.imageSize,
                viewportSize: proxy.size,
                zoom: zoom,
                pan: pan
            )

            ZStack {
                Color.black
                correctedImage
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(zoom)
                    .offset(pan)
                    .accessibilityHidden(true)

                if let mapper {
                    measurementLine(
                        from: mapper.viewPoint(for: editor.point(for: .lengthStart)),
                        to: mapper.viewPoint(for: editor.point(for: .lengthEnd)),
                        color: .cyan
                    )
                    measurementLine(
                        from: mapper.viewPoint(for: editor.point(for: .widthStart)),
                        to: mapper.viewPoint(for: editor.point(for: .widthEnd)),
                        color: .orange
                    )
                    label("着丈 \(editor.measurements.length.centimeters, format: .number.precision(.fractionLength(1))) cm", at: midpoint(
                        mapper.viewPoint(for: editor.point(for: .lengthStart)),
                        mapper.viewPoint(for: editor.point(for: .lengthEnd))
                    ))
                    label("身幅 \(editor.measurements.width.centimeters, format: .number.precision(.fractionLength(1))) cm", at: midpoint(
                        mapper.viewPoint(for: editor.point(for: .widthStart)),
                        mapper.viewPoint(for: editor.point(for: .widthEnd))
                    ))

                    ForEach(MeasurementEndpoint.allCases, id: \.self) { endpoint in
                        handle(endpoint, mapper: mapper)
                    }
                }
            }
            .clipped()
            .gesture(panGesture)
            .simultaneousGesture(magnificationGesture)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("採寸端点エディタ")
            .accessibilityValue(editorAccessibilityValue)
            .accessibilityHint("各端点をドラッグするか、VoiceOverの上下スワイプで測定線に沿って微調整できます。線と数値を確認してから承認してください。")
            .safeAreaInset(edge: .bottom) {
                approvalPanel
            }
            .alert(
                "測定値が目安の範囲外です",
                isPresented: $isRangeWarningPresented,
                presenting: rangeConfirmation
            ) { confirmation in
                Button("修正する", role: .cancel) {
                    cancelRangeConfirmation(confirmation)
                }
                Button("範囲外の値で承認") {
                    confirmRangeWarning(confirmation)
                }
            } message: { confirmation in
                Text(rangeWarningMessage(confirmation.warning))
            }
        }
    }

    private var approvalPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let approvalFeedback {
                feedbackView(approvalFeedback)
            } else {
                Text("2本の測定線と数値を確認してください。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Button(action: requestApproval) {
                Label(
                    editor.status == .approvedCV ? "採寸を承認済み" : "この測定線と数値を承認",
                    systemImage: editor.status == .approvedCV
                        ? "checkmark.circle.fill"
                        : "checkmark.circle"
                )
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(editor.status == .approvedCV)
            .accessibilityLabel("着丈と身幅を承認")
            .accessibilityValue(editor.status == .approvedCV ? "承認済み" : "承認待ち")
            .accessibilityHint("表示中の2本の測定線と数値を明示承認します。範囲外の場合は、続けて再確認が必要です。")
        }
        .padding()
        .background(.regularMaterial)
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                pan = CGSize(width: panBase.width + value.translation.width, height: panBase.height + value.translation.height)
            }
            .onEnded { _ in panBase = pan }
    }

    private var magnificationGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in zoom = max(1, magnificationBase * value.magnification) }
            .onEnded { _ in magnificationBase = zoom }
    }

    @ViewBuilder
    private func measurementLine(from start: CGPoint, to end: CGPoint, color: Color) -> some View {
        Path { path in
            path.move(to: start)
            path.addLine(to: end)
        }
        .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func label(_ text: String, at point: CGPoint) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(6)
            .background(.regularMaterial, in: Capsule())
            .position(point)
            .accessibilityHidden(true)
    }

    private func handle(_ endpoint: MeasurementEndpoint, mapper: MeasurementImageCoordinateMapper) -> some View {
        let point = mapper.viewPoint(for: editor.point(for: endpoint))
        return Button {} label: {
            Circle()
                .fill(.white)
                .overlay(Circle().stroke(.blue, lineWidth: 3))
                .frame(width: 24, height: 24)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .position(point)
        .highPriorityGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if let result = try? editor.updateForWorkflow(
                        endpoint,
                        fromViewPoint: value.location,
                        mapper: mapper
                    ) {
                        endpointWasEdited(result)
                    }
                }
        )
        .accessibilityLabel(endpoint.accessibilityLabel)
        .accessibilityValue(measurementValue(for: endpoint))
        .accessibilityHint("\(endpoint.accessibilityAdjustmentHint) 変更後は承認待ちです。")
        .accessibilityAdjustableAction { direction in
            let adjustment: MeasurementEndpointAccessibilityAdjustment = direction == .increment ? .increment : .decrement
            if let result = try? editor.adjustForWorkflow(endpoint, by: adjustment) {
                endpointWasEdited(result)
            }
        }
    }

    private func requestApproval() {
        approvalFeedback = nil
        switch editor.requestCVApproval(garmentPolygon: garmentPolygon) {
        case let .blocked(_, invalidEndpoints):
            approvalFeedback = .invalidEndpoints(invalidEndpoints.count)
        case let .requiresRangeConfirmation(confirmation):
            rangeConfirmation = confirmation
            isRangeWarningPresented = true
        case let .approved(event):
            approvalFeedback = .approved
            onWorkflowEvent(event)
        case .alreadyApproved:
            approvalFeedback = .approved
        case .staleConfirmation:
            approvalFeedback = .staleConfirmation
        }
    }

    private func confirmRangeWarning(_ confirmation: MeasurementRangeConfirmation) {
        rangeConfirmation = nil
        isRangeWarningPresented = false
        switch editor.confirmCVApproval(
            confirmation,
            garmentPolygon: garmentPolygon
        ) {
        case let .approved(event):
            approvalFeedback = .approved
            onWorkflowEvent(event)
        case let .blocked(_, invalidEndpoints):
            approvalFeedback = .invalidEndpoints(invalidEndpoints.count)
        case .staleConfirmation, .requiresRangeConfirmation(_):
            approvalFeedback = .staleConfirmation
        case .alreadyApproved:
            approvalFeedback = .approved
        }
    }

    private func cancelRangeConfirmation(_ confirmation: MeasurementRangeConfirmation) {
        _ = editor.cancelCVApproval(confirmation)
        rangeConfirmation = nil
        isRangeWarningPresented = false
        approvalFeedback = .cancelled
    }

    private func endpointWasEdited(_ result: MeasurementEndpointEditResult) {
        if let rangeConfirmation {
            _ = editor.cancelCVApproval(rangeConfirmation)
        }
        rangeConfirmation = nil
        isRangeWarningPresented = false
        approvalFeedback = nil
        if let event = result.workflowEvent {
            onWorkflowEvent(event)
        }
    }

    private var editorAccessibilityValue: String {
        let approval = editor.status == .approvedCV ? "承認済み" : "承認待ち"
        return "着丈 \(formatted(editor.measurements.length.centimeters)) cm、身幅 \(formatted(editor.measurements.width.centimeters)) cm、\(approval)"
    }

    private func rangeWarningMessage(_ warning: MeasurementRangeWarning) -> String {
        var messages: [String] = []
        if warning.outOfRangeMeasurements.contains(.length) {
            messages.append("着丈 \(formatted(warning.lengthCentimeters)) cmは20〜100 cmの範囲外です。")
        }
        if warning.outOfRangeMeasurements.contains(.width) {
            messages.append("身幅 \(formatted(warning.widthCentimeters)) cmは20〜80 cmの範囲外です。")
        }
        messages.append("この線と数値でよい場合だけ、もう一度承認してください。")
        return messages.joined(separator: " ")
    }

    private func formatted(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }

    @ViewBuilder
    private func feedbackView(_ feedback: ApprovalFeedback) -> some View {
        switch feedback {
        case let .invalidEndpoints(count):
            Label(
                "衣類から外れている端点が\(count)個あります。衣類の上へ移動してください。",
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.red)
        case .staleConfirmation:
            Label(
                "測定線または数値が変わりました。もう一度確認してください。",
                systemImage: "arrow.clockwise"
            )
            .foregroundStyle(.orange)
        case .cancelled:
            Label("承認せず、修正を続けます。", systemImage: "pencil")
                .foregroundStyle(.secondary)
        case .approved:
            Label("採寸を承認しました。", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }

    private func measurementValue(for endpoint: MeasurementEndpoint) -> String {
        editor.accessibilityValue(for: endpoint)
    }

    private func midpoint(_ first: CGPoint, _ second: CGPoint) -> CGPoint {
        CGPoint(x: (first.x + second.x) / 2, y: (first.y + second.y) / 2)
    }
}

private enum ApprovalFeedback {
    case invalidEndpoints(Int)
    case staleConfirmation
    case cancelled
    case approved
}
