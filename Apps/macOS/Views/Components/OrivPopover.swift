import SwiftUI

struct OrivPopover<Content: View>: View {
    @Environment(\.browserTheme) private var theme
    let title: String
    var symbol: String? = nil
    var titleInk: Color? = nil
    var width: CGFloat = 360
    var maximumHeight: CGFloat = 620
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: OrivSpacing.large) {
            HStack(spacing: OrivSpacing.small) {
                if let symbol { Image(systemName: symbol).accessibilityHidden(true) }
                Text(title).accessibilityAddTraits(.isHeader)
            }
            .font(OrivType.title).foregroundStyle(titleInk ?? theme.text)
            ViewThatFits(in: .vertical) {
                popoverContent.fixedSize(horizontal: false, vertical: true)
                ScrollView { popoverContent }
            }
        }
        .padding(OrivLayout.popoverPadding)
        .frame(width: width, alignment: .leading)
        .frame(maxHeight: maximumHeight, alignment: .topLeading)
        .modifier(OrivMaterial.sheet)
    }

    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: OrivSpacing.medium, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
