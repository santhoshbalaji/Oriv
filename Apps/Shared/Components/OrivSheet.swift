import SwiftUI

struct OrivSheetHeader: View {
    @Environment(\.browserTheme) private var theme
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: OrivSpacing.xs) {
            Text(title).font(OrivType.title).accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle).font(OrivType.body).foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct OrivSheet<Content: View, Actions: View>: View {
    enum Size: CGFloat { case small = 420, medium = 560, large = 760 }

    @Environment(\.browserTheme) private var theme
    let title: String
    var subtitle: String? = nil
    var size: Size = .medium
    var height: CGFloat? = nil
    var busy = false
    var error: String? = nil
    @ViewBuilder let content: () -> Content
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: OrivSpacing.large) {
            OrivSheetHeader(title: title, subtitle: subtitle)
            content()
            if let error {
                Text(error).font(OrivType.caption).foregroundStyle(theme.danger)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: OrivSpacing.small) {
                    Spacer(minLength: 0)
                    if busy { ProgressView().controlSize(.small).accessibilityLabel("In progress") }
                    actions()
                }
                VStack(alignment: .trailing, spacing: OrivSpacing.small) {
                    if busy { ProgressView().accessibilityLabel("In progress") }
                    actions()
                }.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .modifier(OrivMaterial.sheet)
        #if os(macOS)
        .padding(OrivLayout.sheetPadding)
        .frame(width: size.rawValue, height: height)
        #else
        .padding(OrivSpacing.xl)
        #endif
    }
}

struct OrivSheetCancel: View {
    var isDefault = false
    let action: () -> Void

    @ViewBuilder var body: some View {
        let button = Button("Cancel", role: .cancel, action: action)
            .orivButton(.secondary)
            .keyboardShortcut(.cancelAction)
        if isDefault { button.keyboardShortcut(.defaultAction) } else { button }
    }
}
