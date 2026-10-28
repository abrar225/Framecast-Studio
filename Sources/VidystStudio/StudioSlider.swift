import SwiftUI
import CompactSlider

/// One fader implementation for mixer and inspector controls; the upstream component
/// supplies drag, precision control and keyboard interaction without an AppKit slider.
struct StudioValueSlider: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var percent = false
    private var bounded: Binding<Double> {
        Binding(get: { value }, set: { if $0.isFinite { value = min(range.upperBound, max(range.lowerBound, $0)) } })
    }
    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(title).font(.system(size: 12)).foregroundStyle(StudioPalette.muted)
                Spacer()
                if percent { Text("\(Int(value * 100))%").font(.system(size: 11, design: .monospaced)) }
                else {
                    TextField(title, value: bounded, format: .number.precision(.fractionLength(2)))
                        .textFieldStyle(.plain).multilineTextAlignment(.trailing).font(.system(size: 11, design: .monospaced))
                        .padding(.horizontal, 7).padding(.vertical, 4).frame(width: 64)
                        .background(StudioPalette.base).clipShape(RoundedRectangle(cornerRadius: 5))
                }
            }
            CompactSlider(value: bounded, in: range.upperBound > range.lowerBound ? range : 0...1)
                .compactSliderHandleStyle(.roundedRectangle(visibility: .always, color: StudioPalette.gold, width: 3, cornerRadius: 1))
                .compactSliderScale(visibility: .always, lineLength: 8, color: StudioPalette.muted.opacity(0.35))
                .compactSliderProgress { _ in StudioPalette.gold.opacity(0.18) }
                .compactSliderOptionsByAdding(.tapToSlide)
                .accentColor(StudioPalette.gold).frame(height: 30)
                .accessibilityLabel(title).accessibilityValue(percent ? "\(Int(value * 100)) percent" : String(format: "%.2f", value))
                .disabled(range.upperBound <= range.lowerBound)
        }
    }
}
