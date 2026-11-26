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
        @Environment(\.v3AppearanceMode) private var v3Mode
        @Environment(\.colorSchemeContrast) private var contrast
        @Environment(\.chromeContrastOverride) private var captureContrast
        @Environment(\.browserReduceMotion) private var reduceMotion
        @State private var hovered = false
        let configuration: Configuration
        let active: Bool

        var body: some View {
            let increased = (captureContrast ?? contrast) == .increased
            let highlighted = enabled && (active || configuration.isPressed || hovered)
            configuration.label.contentShape(Rectangle())
                .background(.primary.opacity(highlighted ? (configuration.isPressed ? 0.12 : active ? 0.16 : 0.07) : 0),
                            in: Capsule())
                .overlay {
                    if highlighted && increased {
                        OrivMacV3.CapsuleBorder(color: OrivMacV3.Card.rimIncreasedContrast(v3Mode), lineWidth: OrivOutline.hairline)
                    }
                }
                .opacity(enabled ? 1 : OrivMacV3.Toolbar.disabledOpacity(v3Mode, increasedContrast: increased))
                .animation(OrivMacV3.Motion.quick(reduceMotion: reduceMotion), value: highlighted)
                .onHover { hovered = $0 }
        }
    }
}
