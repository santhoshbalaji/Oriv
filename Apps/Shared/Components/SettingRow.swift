import SwiftUI

/// Keeps an explanation in the native form row with its control.
struct SettingRow<Control: View>: View {
    @Environment(\.browserTheme) private var theme
    let detail: String?
    @ViewBuilder let control: () -> Control

    var body: some View {
        VStack(alignment: .leading, spacing: OrivSpacing.xs) {
            control().frame(maxWidth: .infinity, alignment: .leading)
            if let detail {
                Text(detail).font(OrivType.caption)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
