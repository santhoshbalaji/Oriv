import SwiftUI

struct PageErrorState: View {
    @Environment(\.browserTheme) private var theme
    let message: String
    let host: String?
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(OrivStrings.pageError, systemImage: "network.slash").foregroundStyle(theme.text)
        } description: {
            if let host { Text(host).font(OrivType.caption).foregroundStyle(theme.textSecondary) }
            Text(message).foregroundStyle(theme.textSecondary)
            Text(OrivStrings.pageErrorRecovery).foregroundStyle(theme.textSecondary)
        } actions: {
            Button(OrivStrings.tryAgain, action: retry).buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.canvas)
        .accessibilityIdentifier("pageErrorState")
    }
}
