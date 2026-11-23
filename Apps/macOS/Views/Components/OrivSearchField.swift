import SwiftUI

struct OrivSearchField<Field: View>: View {
    @Environment(\.browserTheme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.chromeContrastOverride) private var captureContrast
    @Binding var text: String
    var shortcut: String? = nil
    var sidebar = false
    var focused = false
    var ink: Color? = nil
    var clearLabel = "Clear search"
    var onClear: () -> Void = {}
    @ViewBuilder let field: () -> Field

    var body: some View {
        let increased = (captureContrast ?? contrast) == .increased
        let shape = RoundedRectangle(cornerRadius: OrivRadius.control)
        HStack(spacing: OrivSpacing.small) {
            Image(systemName: "magnifyingglass").accessibilityHidden(true)
            field().textFieldStyle(.plain)
            if !text.isEmpty {
                Button {
                    text = ""
                    onClear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .frame(width: OrivTarget.macMinimum.width, height: OrivTarget.macMinimum.height)
                }
                .orivButton(.quiet).accessibilityLabel(clearLabel)
            } else if let shortcut {
                Text(shortcut).font(OrivType.caption).fixedSize().accessibilityHidden(true)
            }
        }
        .font(sidebar ? OrivType.detail : OrivType.body)
        .foregroundStyle(ink ?? theme.textSecondary)
        .padding(.horizontal, OrivSpacing.small)
        .frame(height: OrivLayout.controlHeight)
        .background(sidebar ? .clear : theme.fill, in: shape)
        .modifier(SidebarToneSurface(tone: sidebar ? .search : nil))
        .overlay {
            if focused || increased {
                shape.strokeBorder(increased ? theme.separatorStrong : theme.accent)
                    .allowsHitTesting(false)
            }
        }
    }
}
