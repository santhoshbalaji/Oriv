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
            Image(systemName: symbol).font(.system(size: 21, weight: .light)).foregroundStyle(theme.secondaryText)
                .frame(width: 42, height: 42).background(theme.field, in: .rect(cornerRadius: OrivRadius.popover))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(OrivType.title).foregroundStyle(theme.text).accessibilityAddTraits(.isHeader)
                Text(subtitle).font(.callout).foregroundStyle(theme.secondaryText)
            }
        }.padding(.bottom, 6)
    }
}
