import SwiftUI

enum OrivButtonRole {
    case primary, secondary, quiet, destructive, link
    #if os(iOS)
    case accentFill
    #endif
}

extension View {
    @ViewBuilder
    func orivButton(_ role: OrivButtonRole, busy: Bool = false) -> some View {
        if busy {
            HStack(spacing: OrivSpacing.xs) {
                modifier(OrivButtonAppearance(role: role))
                    .disabled(true)
                    .accessibilityValue("In progress")
                ProgressView().controlSize(.small).accessibilityHidden(true)
            }
        } else {
            modifier(OrivButtonAppearance(role: role))
        }
    }
}

private struct OrivButtonAppearance: ViewModifier {
    @Environment(\.browserTheme) private var theme
    let role: OrivButtonRole

    @ViewBuilder func body(content: Content) -> some View {
        switch role {
        case .primary: content.buttonStyle(.borderedProminent).tint(theme.accent)
        case .secondary: content.buttonStyle(.bordered)
        case .quiet: content.buttonStyle(OrivQuietButtonStyle())
        case .destructive: content.buttonStyle(.bordered).tint(theme.danger).foregroundStyle(theme.danger)
        case .link: content.buttonStyle(.borderless).tint(theme.accent).foregroundStyle(theme.accent)
        #if os(iOS)
        case .accentFill: content.buttonStyle(OrivAccentFillStyle())
        #endif
        }
    }
}

struct OrivQuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration)
    }

    private struct Face: View {
        @Environment(\.browserTheme) private var theme
        @Environment(\.colorSchemeContrast) private var contrast
        @Environment(\.chromeContrastOverride) private var captureContrast
        @Environment(\.isEnabled) private var enabled
        @State private var hovered = false
        let configuration: Configuration

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: OrivRadius.tile)
            configuration.label
                .background {
                    if enabled && (configuration.isPressed || hovered) {
                        shape.fill(configuration.isPressed ? theme.fillSelected : theme.fillHover)
                    }
                }
                .overlay {
                    if enabled && hovered && (captureContrast ?? contrast) == .increased {
                        shape.strokeBorder(theme.separatorStrong)
                    }
                }
                .contentShape(shape)
                .onHover { hovered = $0 }
        }
    }
}

#if os(iOS)
private struct OrivAccentFillStyle: ButtonStyle {
    @Environment(\.browserTheme) private var theme
    @Environment(\.self) private var environment
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(theme.onAccent(for: theme.accent.resolve(in: environment)))
            .background(theme.accent, in: .rect(cornerRadius: OrivRadius.control))
            .brightness(configuration.isPressed ? -0.08 : 0)
            .opacity(enabled ? 1 : 0.5)
    }
}
#endif
