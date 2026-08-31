import SwiftUI

/// Corrected-image endpoint editor. It presents measurements as a pending proposal and
/// deliberately contains no approval action; approval is introduced by T13-02.
@available(iOS 18.0, *)
public struct MeasurementEndpointEditorOverlay: View {
    private let correctedImage: Image
    @Binding private var editor: MeasurementEndpointEditor

    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var magnificationBase: CGFloat = 1
    @State private var panBase: CGSize = .zero

    public init(correctedImage: Image, editor: Binding<MeasurementEndpointEditor>) {
        self.correctedImage = correctedImage
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
            .accessibilityHint("端点をドラッグするか、VoiceOverの上下スワイプで微調整できます。採寸は未承認です。")
        }
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
                .onChanged { value in try? editor.update(endpoint, fromViewPoint: value.location, mapper: mapper) }
        )
        .accessibilityLabel(endpoint.accessibilityLabel)
        .accessibilityValue(measurementValue(for: endpoint))
        .accessibilityHint("上下スワイプで0.1cm未満ずつ調整します。採寸は未承認です。")
        .accessibilityAdjustableAction { direction in
            let adjustment: MeasurementEndpointAccessibilityAdjustment = direction == .increment ? .increment : .decrement
            try? editor.adjust(endpoint, by: adjustment)
        }
    }

    private func measurementValue(for endpoint: MeasurementEndpoint) -> String {
        switch endpoint {
        case .lengthStart, .lengthEnd:
            "着丈 \(editor.measurements.length.centimeters, format: .number.precision(.fractionLength(1))) cm、未承認"
        case .widthStart, .widthEnd:
            "身幅 \(editor.measurements.width.centimeters, format: .number.precision(.fractionLength(1))) cm、未承認"
        }
    }

    private func midpoint(_ first: CGPoint, _ second: CGPoint) -> CGPoint {
        CGPoint(x: (first.x + second.x) / 2, y: (first.y + second.y) / 2)
    }
}
