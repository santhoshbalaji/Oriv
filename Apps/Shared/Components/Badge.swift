import SwiftUI

struct Badge: View {
    enum Kind { case neutral, privateBrowsing, count }

    @Environment(\.browserTheme) private var theme
    let text: String
    var kind: Kind = .neutral
    var padsLabel = true

    var body: some View {
        let label = Text(text)
            .font(kind == .count ? OrivType.caption.monospacedDigit() : OrivType.badge)
            .foregroundStyle(kind == .privateBrowsing ? theme.private : theme.textSecondary)
            .fixedSize()
        if padsLabel {
            label.padding(.horizontal, OrivSpacing.small).padding(.vertical, OrivSpacing.xxs)
                .background(kind == .privateBrowsing ? theme.privateWash : theme.fill, in: Capsule())
        } else {
            label
        }
    }

    static var alreadyOpen: Badge { Badge(text: OrivStrings.alreadyOpen) }
}
