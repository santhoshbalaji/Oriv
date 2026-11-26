import SwiftUI

struct OrivPopover<Content: View>: View {
    @Environment(\.browserTheme) private var theme
    @Environment(\.snapshotUnscrolled) private var unscrolled
    @State private var contentHeight: CGFloat?
    let title: String
    var symbol: String? = nil
    var titleInk: Color? = nil
    var width: CGFloat = 360
    var maximumHeight: CGFloat? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        Group {
            if let maximumHeight, !unscrolled {
                // Measure the same content that users interact with. A second
                // layout candidate would register another set of focus targets.
                ScrollView {
                    panel.onGeometryChange(for: CGFloat.self) { ceil($0.size.height) } action: { contentHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(contentHeight ?? maximumHeight, maximumHeight))
            } else {
                panel.fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: width, alignment: .leading)
        .modifier(OrivMaterial.sheet)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: OrivSpacing.large) {
            HStack(spacing: OrivSpacing.small) {
                if let symbol { Image(systemName: symbol).accessibilityHidden(true) }
                Text(title).accessibilityAddTraits(.isHeader)
            }
            .font(OrivType.title).foregroundStyle(titleInk ?? theme.text)
            VStack(alignment: .leading, spacing: OrivSpacing.medium, content: content)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(OrivLayout.popoverPadding)
    }
}
