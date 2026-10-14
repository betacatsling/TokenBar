import SwiftUI

/// Shared visual constants and small building blocks for the panel.
enum Theme {
    static let panelWidth: CGFloat = 340
    static let inset: CGFloat = 14

    static let hoverFill = Color.primary.opacity(0.06)
    static let pressedFill = Color.primary.opacity(0.11)
    /// Unfilled part of share bars and empty chart days.
    static let track = Color.primary.opacity(0.07)
    /// Background of a group of settings rows.
    static let groupFill = Color.primary.opacity(0.045)
    /// Bars for things that are not CLIs (machines), so they never borrow a CLI's hue.
    static let neutralBar = Color.primary.opacity(0.32)

    /// The one status tone the panel uses: server1 unreachable. Always shown
    /// with an icon and a sentence, never as color alone.
    static let serious = Color(hex: 0xec835a)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255)
    }
}

extension CLIKind {
    /// Series color, stepped separately for light and dark.
    ///
    /// Picked by running a colorblind-safety validator over every 4-hue subset
    /// of an 8-hue reference palette, checking all pairs in both modes. All
    /// pairs, not just neighbors: in the stacked trend any two CLIs end up
    /// touching on a day the ones between them were idle. Only two subsets
    /// pass, and neither contains orange (it collapses into amber or red under
    /// deuteranopia), so Claude gets amber, the nearest warm hue that survives.
    func color(_ scheme: ColorScheme) -> Color {
        let dark = scheme == .dark
        switch self {
        case .claudeCode: return Color(hex: dark ? 0xc98500 : 0xeda100)
        case .codex:      return Color(hex: dark ? 0x3987e5 : 0x2a78d6)
        case .devin:      return Color(hex: 0x008300)
        case .pi:         return Color(hex: dark ? 0xd55181 : 0xe87ba4)
        case .gemini:     return Color(hex: dark ? 0x8c83e6 : 0x7663c4)
        case .opencode:   return Color(hex: dark ? 0x40b6b0 : 0x167b79)
        case .magpie:     return Color(hex: dark ? 0xa8a8a8 : 0x646464)
        }
    }

    /// Canonical stacking / legend order.
    static var ordered: [CLIKind] { allCases.sorted { $0.sortIndex < $1.sortIndex } }

    /// For the chart legend, where four full names do not fit on one line.
    var shortName: String {
        switch self {
        case .claudeCode: return "Claude"
        case .codex: return "Codex"
        case .devin: return "Devin"
        case .pi: return "pi"
        case .gemini: return "Gemini"
        case .opencode: return "OpenCode"
        case .magpie: return "网关"
        }
    }
}

/// The small colored key that ties a row to its series in the trend chart.
struct SeriesDot: View {
    let cli: CLIKind?
    var size: CGFloat = 8
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Circle()
            .fill(cli.map { $0.color(scheme) } ?? Theme.neutralBar)
            .frame(width: size, height: size)
    }
}

/// A rounded wash behind a row while the pointer is over it.
struct HoverHighlight: ViewModifier {
    var enabled = true
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(enabled && hovering ? Theme.hoverFill : .clear)
            )
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverHighlight(_ enabled: Bool = true) -> some View {
        modifier(HoverHighlight(enabled: enabled))
    }
}

/// A borderless glyph button that picks up a wash on hover, for the footer.
struct IconButtonStyle: ButtonStyle {
    @MainActor func makeBody(configuration: Configuration) -> Body {
        Body(configuration: configuration)
    }

    struct Body: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering && isEnabled ? HierarchicalShapeStyle.primary : .secondary)
                .frame(width: 26, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(configuration.isPressed ? Theme.pressedFill
                              : hovering && isEnabled ? Theme.hoverFill : .clear)
                )
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// A quiet segmented control: the selection is a raised pill rather than the
/// system control's saturated accent fill, which competed with the data.
struct PillPicker<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String

    @Namespace private var pill
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                        selection = option
                    }
                } label: {
                    Text(title(option))
                        .font(.system(size: 11, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? HierarchicalShapeStyle.primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(scheme == .dark ? Color.white.opacity(0.16) : Color.white)
                                    .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.12), radius: 1, y: 0.5)
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.track))
    }
}
