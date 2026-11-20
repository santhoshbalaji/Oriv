import SwiftUI

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
                Text(title).font(OrivType.title).foregroundStyle(theme.text).accessibilityAddTraits(.isHeader)
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
        @State private var hovered = false
        var body: some View {
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: OrivRadius.medium)
                        .fill(configuration.isPressed ? theme.sidebar.selection : hovered ? theme.sidebar.hover : .clear)
                }
                .overlay {
                    if hovered && contrast == .increased {
                        RoundedRectangle(cornerRadius: OrivRadius.medium).strokeBorder(theme.separator, lineWidth: 1)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: OrivRadius.medium))
                .onHover { hovered = $0 }
        }
    }
}
