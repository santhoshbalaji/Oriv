import SwiftUI

struct OrivSearchField<Field: View>: View {
    @Environment(\.browserTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.chromeContrastOverride) private var captureContrast
    @Environment(\.sidebarContrast) private var sidebarContrast
    @Environment(\.v3AppearanceMode) private var v3Mode
    @Binding var text: String
    var shortcut: String? = nil
    var sidebar = false
    var focused = false
    var ink: Color? = nil
    var clearLabel = "Clear search"
    var onClear: () -> Void = {}
    @ViewBuilder let field: () -> Field

    var body: some View {
        let increased = (sidebar ? sidebarContrast : (captureContrast ?? contrast)) == .increased
        let mode = OrivMacV3.AppearanceMode.resolve(theme: theme, colorScheme: scheme,
                                                    isPrivateWindow: v3Mode == .private)
        let shape = RoundedRectangle(cornerRadius: sidebar ? OrivMacV3.Radius.sidebarSearch : OrivRadius.control,
                                     style: .continuous)
        HStack(spacing: sidebar ? OrivMacV3.SidebarLayout.searchInnerGap : OrivSpacing.small) {
            Image(systemName: "magnifyingglass").accessibilityHidden(true)
            field().textFieldStyle(.plain)
                .foregroundStyle(sidebar ? OrivMacV3.Ink.primary(mode) : theme.text)
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
                Text(shortcut)
                    .font(sidebar ? OrivMacV3.Typography.shortcutHint : OrivType.caption)
                    .tracking(sidebar ? OrivMacV3.Typography.labelTracking : .zero)
                    .foregroundStyle(sidebar
                                     ? OrivMacV3.Ink.tertiary(mode, onSidebar: true, increasedContrast: increased)
                                     : (ink ?? theme.textSecondary))
                    .fixedSize().accessibilityHidden(true)
            }
        }
        .font(sidebar ? OrivMacV3.Typography.detail : OrivType.body)
        .foregroundStyle(ink ?? (sidebar ? OrivMacV3.Ink.secondary(mode, increasedContrast: increased) : theme.textSecondary))
        .padding(.horizontal, sidebar ? OrivMacV3.SidebarLayout.searchPaddingHorizontal : OrivSpacing.small)
        .frame(height: sidebar ? OrivMacV3.SidebarLayout.searchHeight : OrivLayout.controlHeight)
        .background(sidebar ? .clear : theme.fill, in: shape)
        .modifier(SidebarToneSurface(tone: sidebar ? .search : nil))
        .overlay {
            if focused || increased {
                shape.strokeBorder(
                    increased
                        ? (sidebar ? OrivMacV3.Card.rimIncreasedContrast(mode) : theme.separatorStrong)
                        : (sidebar ? OrivMacV3.Focus.addressRing(mode) : theme.accent),
                    lineWidth: focused && sidebar
                        ? OrivMacV3.Focus.addressRingWidth(increasedContrast: increased)
                        : (increased ? OrivOutline.enhanced : OrivOutline.hairline)
                )
                .allowsHitTesting(false)
            }
        }
    }
}
