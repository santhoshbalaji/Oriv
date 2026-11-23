import SwiftUI

enum OrivBannerTone {
    case info, success, warning, privateBrowsing

    var symbol: String {
        switch self {
        case .info: "info.circle"
        case .success: "checkmark.circle"
        case .warning: "exclamationmark.triangle"
        case .privateBrowsing: "eyeglasses"
        }
    }

    func ink(in theme: Theme) -> Color {
        switch self {
        case .info: theme.textSecondary
        case .success: theme.success
        case .warning: theme.warning
        case .privateBrowsing: theme.private
        }
    }
}

struct OrivBanner<Actions: View>: View {
    @Environment(\.browserTheme) private var theme
    @Environment(\.dynamicTypeSize) private var textSize
    let message: String
    var tone: OrivBannerTone = .info
    var symbol: String? = nil
    var dismiss: (() -> Void)? = nil
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        let stacked = textSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: OrivSpacing.xs))
                             : AnyLayout(HStackLayout(spacing: OrivSpacing.small))
        layout {
            OrivBannerLabel(message: message, tone: tone, symbol: symbol ?? tone.symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: OrivSpacing.small) {
                actions()
                if let dismiss {
                    Button(action: dismiss) {
                        Image(systemName: "xmark").accessibilityHidden(true)
                            .frame(minWidth: actionTarget, minHeight: actionTarget)
                            .contentShape(Rectangle())
                    }
                    .orivButton(.quiet).foregroundStyle(theme.textSecondary).accessibilityLabel("Dismiss")
                }
            }
        }
        .font(OrivType.detail)
        .padding(.horizontal, OrivSpacing.large)
        .frame(minHeight: height)
        .background(tone == .privateBrowsing ? theme.privateWash : theme.surface)
    }

    private var height: CGFloat {
        #if os(macOS)
        OrivLayout.controlHeight
        #else
        OrivTarget.touch.height
        #endif
    }

    private var actionTarget: CGFloat {
        #if os(macOS)
        OrivTarget.macMinimum.height
        #else
        OrivTarget.touch.height
        #endif
    }
}

extension OrivBanner where Actions == EmptyView {
    init(_ message: String, tone: OrivBannerTone = .info, symbol: String? = nil, dismiss: (() -> Void)? = nil) {
        self.init(message: message, tone: tone, symbol: symbol, dismiss: dismiss) { EmptyView() }
    }
}

struct OrivBannerLabel: View {
    @Environment(\.browserTheme) private var theme
    let message: String
    let tone: OrivBannerTone
    let symbol: String

    var body: some View {
        Label {
            Text(message).foregroundStyle(tone == .privateBrowsing ? theme.private : theme.text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tone.ink(in: theme)).accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }
}
