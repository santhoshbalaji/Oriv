import BrowserCore
import SwiftUI

/// Content only: callers own buttons, List selection, menus, swipe actions and hit targets.
struct PageRowContent: View {
    enum Layout { case inline, stacked, titleOnly }
    enum Accessory { case none, alreadyOpen, selected }

    let title: String
    let url: URL?
    var context: URLDisplay.Context? = nil
    #if os(macOS)
    var layout: Layout = .inline
    var iconSize: CGFloat = 24
    #else
    var layout: Layout = .stacked
    var iconSize: CGFloat = 28
    #endif
    var spacing: CGFloat = OrivSpacing.medium
    var secondaryFont: Font = OrivType.detail
    var titleWeight: Font.Weight = .regular
    var isPrivate = false
    var isSelected = false
    var isLoading = false
    var showsNewTabSymbol = false
    var accessory: Accessory = .none
    var highlightedTitle: Text? = nil
    var highlightedAddress: Text? = nil
    var identitySymbol: String? = nil
    var compactTitle = false
    @Environment(\.browserTheme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize

    private var displayTitle: String { title.isEmpty ? (url?.host() ?? url?.absoluteString ?? "Page") : title }
    private var address: String? { secondaryLine(title: title, url: url, in: context) }
    private var stacks: Bool { layout == .stacked }

    var body: some View {
        HStack(spacing: spacing) {
            identity
            if stacks {
                VStack(alignment: .leading, spacing: OrivSpacing.xxs) {
                    primary
                    secondary
                    // Keep the badge/checkmark clear of the separate close button at AX sizes.
                    if typeSize.isAccessibilitySize { trailing }
                }
            } else {
                primary
                if layout != .titleOnly { secondary }
            }
            Spacer(minLength: accessory == .alreadyOpen ? OrivSpacing.small : 0)
            if !stacks || !typeSize.isAccessibilitySize { trailing }
        }
        .modifier(FullRowAddress(url: url))
    }

    @ViewBuilder private var primary: some View {
        let title = (highlightedTitle ?? Text(displayTitle)).font(OrivType.body.weight(titleWeight)).foregroundStyle(theme.text)
        if compactTitle && !typeSize.isAccessibilitySize { title.lineLimit(1) }
        else { title.rowTitleLines() }
    }
    @ViewBuilder private var secondary: some View {
        if let address = highlightedAddress ?? address.map({ Text($0) }) {
            // Addresses stay on one line so Dynamic Type never splits a host, port or path token.
            address.font(secondaryFont).foregroundStyle(theme.secondaryText).lineLimit(1).truncationMode(.middle)
        }
    }
    @ViewBuilder private var identity: some View {
        if isLoading { ProgressView().controlSize(.mini).frame(width: iconSize).accessibilityLabel("Loading") }
        else if let identitySymbol {
            Image(systemName: identitySymbol).frame(width: iconSize).accessibilityHidden(true)
        }
        else if showsNewTabSymbol && url == nil {
            Image(systemName: isPrivate ? "eyeglasses" : "plus.square.dashed")
                .foregroundStyle(theme.secondaryText).frame(width: iconSize).accessibilityHidden(true)
        } else { SiteIdentity(url: url, size: iconSize, isPrivate: isPrivate, isSelected: isSelected) }
    }
    @ViewBuilder private var trailing: some View {
        switch accessory {
        case .none: EmptyView()
        case .alreadyOpen: Badge.alreadyOpen
        case .selected:
            Image(systemName: "checkmark").font(OrivType.detail.weight(.semibold))
                .foregroundStyle(theme.secondaryText).accessibilityHidden(true)
        }
    }
}

private struct FullRowAddress: ViewModifier {
    let url: URL?
    @ViewBuilder func body(content: Content) -> some View {
        if let url { content.accessibilityCustomContent(Text("Address"), Text(verbatim: url.absoluteString)) }
        else { content }
    }
}
