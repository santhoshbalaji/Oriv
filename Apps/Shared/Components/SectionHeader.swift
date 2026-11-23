import SwiftUI

struct SectionHeader: View {
    enum Kind { case sidebar, content, suggestions }

    @Environment(\.browserTheme) private var theme
    let title: String
    var kind: Kind = .suggestions
    var count: Int? = nil
    var symbol: String? = nil
    #if os(macOS)
    var symbolInk: Color? = nil
    #endif
    var ink: Color? = nil
    var countInk: Color? = nil
    var showAll: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: OrivSpacing.small) {
            if let symbol {
                Image(systemName: symbol).foregroundStyle(iconColor).accessibilityHidden(true)
            }
            Text(title).font(font).foregroundStyle(ink ?? theme.textSecondary)
                .accessibilityAddTraits(.isHeader)
            if kind != .suggestions { Spacer(minLength: 0) }
            if let count, count > 0 {
                Text(count.formatted()).font(OrivType.caption.monospacedDigit())
                    .foregroundStyle(countInk ?? theme.textSecondary)
            }
            if let showAll {
                Button("Show All", action: showAll).font(OrivType.detail)
                    .accessibilityLabel("Show All \(title)")
                    #if os(macOS)
                    .orivButton(.link)
                    #else
                    .frame(minHeight: OrivTarget.touch.height)
                    #endif
            }
        }
    }

    private var iconColor: Color {
        #if os(macOS)
        symbolInk ?? ink ?? theme.textSecondary
        #else
        ink ?? theme.textSecondary
        #endif
    }

    private var font: Font {
        switch kind {
        case .sidebar:
            #if os(macOS)
            OrivType.sectionLabel
            #else
            OrivType.title
            #endif
        case .content: OrivType.headline
        case .suggestions: OrivType.sectionLabel
        }
    }
}
