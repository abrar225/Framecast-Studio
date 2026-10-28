import SwiftUI

enum StudioPalette {
    static let base = Color(hex: "#141310")
    static let panel = Color(hex: "#1C1B18")
    static let canvas = base
    static let control = Color(hex: "#28251F")
    static let border = Color(hex: "#3C382F")
    static let text = Color(hex: "#EEECE7")
    static let muted = Color(hex: "#A49D91")
    static let gold = Color(hex: "#F5C849")
    static let coral = Color(hex: "#EF4C4B")
}

struct StudioButtonStyle: ButtonStyle {
    var prominent = false
    var horizontalPadding: CGFloat = 10
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.85)
            .foregroundStyle(prominent ? StudioPalette.base : configuration.role == .destructive ? StudioPalette.coral : StudioPalette.text)
            .padding(.horizontal, horizontalPadding).frame(minHeight: 32)
            .background(prominent ? StudioPalette.gold : configuration.isPressed ? StudioPalette.border : StudioPalette.control)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(prominent ? .clear : StudioPalette.border.opacity(0.8)))
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
    }
}

struct StudioTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<_Label>) -> some View {
        configuration.textFieldStyle(.plain).font(.system(size: 12))
            .padding(.horizontal, 10).padding(.vertical, 8).frame(minHeight: 32)
            .background(StudioPalette.base).clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioPalette.border))
    }
}

struct StudioSegmentedControl<Value: Hashable>: View {
    let options: [(String, Value)]
    @Binding var selection: Value
    var body: some View {
        HStack(spacing: 3) {
            ForEach(options, id: \.1) { title, value in
                Button { selection = value } label: {
                    Text(title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .foregroundStyle(selection == value ? StudioPalette.gold : StudioPalette.muted)
                        .background(selection == value ? StudioPalette.border.opacity(0.8) : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain).accessibilityAddTraits(selection == value ? .isSelected : [])
            }
        }.padding(3).background(StudioPalette.base).clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(StudioPalette.border))
    }
}

struct StudioMenuField: View {
    let title: String
    let options: [(String, String)]
    @Binding var selection: String
    var body: some View {
        Menu {
            ForEach(options, id: \.0) { value, label in
                Button { selection = value } label: {
                    if selection == value { Label(label, systemImage: "checkmark") } else { Text(label) }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(options.first(where: { $0.0 == selection })?.1 ?? "Saved input unavailable").lineLimit(1)
                Spacer(minLength: 5); Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }.font(.system(size: 12)).foregroundStyle(StudioPalette.text)
                .padding(.horizontal, 10).frame(minHeight: 32).background(StudioPalette.base)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioPalette.border))
        }.menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain).accessibilityLabel(title)
    }
}

