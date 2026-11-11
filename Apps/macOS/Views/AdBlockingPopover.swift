import BrowserEngine
import SwiftUI

struct AdBlockingPopover: View {
    @Environment(\.browserTheme) private var theme
    let session: BrowserSession
    private var blocker: AdBlocker { session.adBlocker }
    private var tab: BrowserTab? { session.selectedTab }

    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 16) {
            EditorHeading(title: "Site Privacy", subtitle: "Protection for this profile", symbol: "shield.lefthalf.filled")
            Picker("Blocking mode", selection: Binding(get: { blocker.mode }, set: { blocker.setMode($0) })) {
                ForEach(AdBlockingMode.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            Text(blocker.mode.detail).font(.callout).foregroundStyle(theme.secondaryText).fixedSize(horizontal: false, vertical: true)
            if let tab, AdBlocker.host(for: tab.url) != nil {
                Divider()
                PrivacyShieldControls(session: session, tab: tab)
            }
            if blocker.isPreparing { ProgressView("Preparing protection…").controlSize(.small) }
            if let error = blocker.preparationError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Text("Works in normal and private tabs. Reload to apply changes fully. Filters update with Oriv releases; some ads may remain.")
                .font(.caption).foregroundStyle(theme.secondaryText).fixedSize(horizontal: false, vertical: true)
        }
        .padding(20) }.frame(width: 360, height: 620)
    }
}
