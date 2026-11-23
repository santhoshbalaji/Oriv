import SwiftUI

struct ToolbarButton: View {
    let label: String
    let symbol: String
    var help: String? = nil
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(OrivIcon.toolbarFont)
                .frame(width: OrivTarget.macToolbar.width, height: OrivTarget.macToolbar.height)
        }
        .buttonStyle(ToolbarButtonStyle(active: active))
        .accessibilityLabel(label)
        .help(help ?? label)
    }
}

/// Works on normal buttons, native menus and system share controls.
struct ToolbarButtonStyle: ButtonStyle {
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, active: active)
    }

    private struct Face: View {
        @Environment(\.isEnabled) private var enabled
        @Environment(\.browserTheme) private var theme
        @Environment(\.colorSchemeContrast) private var contrast
        @Environment(\.chromeContrastOverride) private var captureContrast
        @State private var hovered = false
        let configuration: Configuration
        let active: Bool

        var body: some View {
            let highlighted = enabled && (active || configuration.isPressed || hovered)
            configuration.label.contentShape(Rectangle())
                .background(.primary.opacity(highlighted ? (configuration.isPressed ? 0.12 : active ? 0.16 : 0.07) : 0),
                            in: Capsule())
                .overlay {
                    if highlighted && (captureContrast ?? contrast) == .increased {
                        Capsule().strokeBorder(theme.separatorStrong).allowsHitTesting(false)
                    }
                }
                .opacity(enabled ? 1 : 0.5)
                .onHover { hovered = $0 }
        }
    }
}
