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

    // Semantic tokens
    static let success = Color(hex: "#34C759")
    static let card = Color(hex: "#22201B")
    static let cardBorder = Color(hex: "#38342B")
    static let surfaceHover = Color(hex: "#302C24")
    static let glow = gold.opacity(0.18)
}

enum StudioBadgeStyle {
    case `default`, accent, success, danger, outline
}

struct StudioBadge: View {
    let text: String
    var icon: String? = nil
    var style: StudioBadgeStyle = .default

    var body: some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon).font(.system(size: 8, weight: .bold))
            }
            Text(text).font(.system(size: 9, weight: .bold)).lineLimit(1)
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .foregroundStyle(foregroundColor)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(borderColor, lineWidth: 1))
    }

    private var foregroundColor: Color {
        switch style {
        case .accent: return StudioPalette.base
        case .success: return .white
        case .danger: return .white
        case .outline: return StudioPalette.gold
        case .default: return StudioPalette.text.opacity(0.9)
        }
    }

    private var backgroundColor: Color {
        switch style {
        case .accent: return StudioPalette.gold
        case .success: return StudioPalette.success
        case .danger: return StudioPalette.coral
        case .outline: return .clear
        case .default: return StudioPalette.control
        }
    }

    private var borderColor: Color {
        switch style {
        case .outline: return StudioPalette.gold.opacity(0.6)
        case .default: return StudioPalette.border.opacity(0.6)
        default: return .clear
        }
    }
}

struct StudioCard<Content: View>: View {
    var cornerRadius: CGFloat = 10
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(StudioPalette.card)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(StudioPalette.cardBorder, lineWidth: 1))
    }
}

struct StudioSectionHeader<Trailing: View>: View {
    let title: String
    var icon: String? = nil
    var badge: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, icon: String? = nil, badge: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.icon = icon
        self.badge = badge
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold)).foregroundStyle(StudioPalette.muted)
            }
            Text(title.uppercased()).font(.system(size: 10, weight: .bold)).tracking(0.8).foregroundStyle(StudioPalette.muted)
            if let badge {
                Text(badge).font(.system(size: 9, weight: .bold)).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(StudioPalette.control).clipShape(Capsule()).foregroundStyle(StudioPalette.muted)
            }
            Spacer()
            trailing()
        }
    }
}

struct StudioIconButton: View {
    let icon: String
    var title: String? = nil
    var active: Bool = false
    var size: CGFloat = 30
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: max(10, size * 0.42), weight: .semibold))
                .frame(width: size, height: size)
                .foregroundStyle(active ? StudioPalette.gold : StudioPalette.text.opacity(0.85))
                .background(active ? StudioPalette.gold.opacity(0.15) : StudioPalette.control.opacity(0.7))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(active ? StudioPalette.gold.opacity(0.5) : StudioPalette.border.opacity(0.6), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(title ?? "")
        .accessibilityLabel(title ?? icon)
    }
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

