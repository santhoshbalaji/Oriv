import SwiftUI

extension Theme {
    /// Direction B's window material, independent of a profile's page palette.
    static let sidebar = Theme(isT3Code: false, accent: adaptive("SidebarAccent", light: 0x713C52, dark: 0xE3ADC4),
        canvas: adaptive("SidebarCanvas", light: 0xE6E4EA, dark: 0x302D35),
        surface: adaptive("SidebarPanel", light: 0xEDEBF0, dark: 0x29262F),
        field: adaptive("SidebarField", light: 0xE1DEE6, dark: 0x36323D),
        chrome: adaptive("SidebarChrome", light: 0xE6E4EA, dark: 0x302D35),
        separator: adaptive("SidebarOutline", light: 0xC7C1CE, dark: 0x514B59),
        text: adaptive("SidebarInk", light: 0x252329, dark: 0xF5F3F7),
        secondaryText: adaptive("SidebarSecondary", light: 0x5B5660, dark: 0xB5B0BC),
        selection: adaptive("SidebarSelection", light: 0xD8D0E0, dark: 0x47414E),
        thread: adaptive("SidebarHover", light: 0xE1DDE6, dark: 0x35313C),
        accentText: adaptive("SidebarAccentText", light: 0x713C52, dark: 0xE3ADC4))

    static func editorial(_ size: CGFloat) -> Font {
        .system(size: size, weight: .medium, design: .serif)
    }
}

struct OrivIdentity: View {
    @Environment(\.browserTheme) private var theme
    var subtitle: String? = nil
    var body: some View {
        HStack(spacing: 10) {
            Image("OrivMark").resizable().scaledToFit().frame(width: 30, height: 30)
                .clipShape(.rect(cornerRadius: OrivRadius.small)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(AppIdentity.name).font(.headline.weight(.semibold))
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(theme.secondaryText) }
            }
        }
    }
}

/// A quiet continuation of the app mark, kept away from controls and reading text.
struct OrivThread: View {
    @Environment(\.browserTheme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        Canvas { context, size in
            var path = Path()
            let w = size.width, h = size.height
            path.move(to: CGPoint(x: 0, y: h * 0.7))
            path.addCurve(to: CGPoint(x: w, y: h * 0.3), control1: CGPoint(x: w * 0.6, y: h * 0.7), control2: CGPoint(x: w * 0.4, y: -h * 0.2))
            path.addCurve(to: CGPoint(x: 0, y: h * 0.3), control1: CGPoint(x: w * 1.1, y: h * 1.1), control2: CGPoint(x: w * 0.3, y: h * 1.1))
            path.addCurve(to: CGPoint(x: w, y: h * 0.7), control1: CGPoint(x: -w * 0.1, y: -h * 0.1), control2: CGPoint(x: w * 0.4, y: -h * 0.1))
            context.stroke(path, with: .color(theme.thread), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        }.opacity(contrast == .increased ? 0 : 0.65).accessibilityHidden(true).allowsHitTesting(false)
    }
}

struct EditorHeading: View {
    @Environment(\.browserTheme) private var theme
    let title: String
    let subtitle: String
    let symbol: String
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 21, weight: .light)).foregroundStyle(theme.accent)
                .frame(width: 42, height: 42).background(theme.accent.opacity(0.08), in: .rect(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(Theme.editorial(25)).foregroundStyle(theme.text).accessibilityAddTraits(.isHeader)
                Text(subtitle).font(.callout).foregroundStyle(theme.secondaryText)
            }
        }.padding(.bottom, 6)
    }
}

/// Quiet content affordance. Native chrome observes the system accessibility settings.
struct ContentButtonStyle: ButtonStyle {
    @Environment(\.colorSchemeContrast) private var contrast
    func makeBody(configuration: Configuration) -> some View {
        HoverContent(configuration: configuration, contrast: contrast)
    }

    private struct HoverContent: View {
        @Environment(\.browserTheme) private var theme
        let configuration: Configuration
        let contrast: ColorSchemeContrast
        @Environment(\.isFocused) private var isFocused
        @Environment(\.chromeFocusState) private var input
        private var showsKeyboardFocus: Bool { isFocused && (input?.showsFocus ?? NSApp.isFullKeyboardAccessEnabled) }
        @State private var hovered = false
        var body: some View {
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: OrivRadius.medium)
                        .fill(.primary.opacity(configuration.isPressed ? 0.10 : hovered ? 0.05 : 0))
                }
                .overlay {
                    if hovered && contrast == .increased && !showsKeyboardFocus {
                        RoundedRectangle(cornerRadius: OrivRadius.medium).strokeBorder(theme.separator, lineWidth: 1)
                    }
                }
                .modifier(ChromeFocusIndicator(radius: OrivRadius.medium, marker: "chromeControlFocusIndicator"))
                .contentShape(RoundedRectangle(cornerRadius: OrivRadius.medium))
                .focusEffectDisabled()
                .onHover { hovered = $0 }
        }
    }
}
