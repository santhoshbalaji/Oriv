import SwiftUI

/// One explanatory message, with an optional native action. Wraps rather than truncates at AX sizes.
struct BrowserEmptyState<Action: View>: View {
    let message: String
    @ViewBuilder var action: () -> Action
    @Environment(\.browserTheme) private var theme

    init(_ message: String, @ViewBuilder action: @escaping () -> Action) {
        self.message = message
        self.action = action
    }

    var body: some View {
        VStack(spacing: OrivSpacing.small) {
            Text(message).font(OrivType.body).foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            action()
        }
        .padding(OrivSpacing.xl).frame(maxWidth: .infinity)
    }
}

extension BrowserEmptyState where Action == EmptyView {
    init(_ message: String) { self.init(message) { EmptyView() } }
}
