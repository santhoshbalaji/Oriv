import BrowserEngine
import SwiftUI

struct AdBlockingPopover: View {
    @Environment(\.browserTheme) private var theme
    @FocusState private var blockingModeFocused: Bool
    let session: BrowserSession
    private var blocker: AdBlocker { session.adBlocker }
    private var tab: BrowserTab? { session.selectedTab }

    var body: some View {
        OrivPopover(title: OrivStrings.sitePrivacy, symbol: "shield.lefthalf.filled") {
            Text("Protection for this profile").font(OrivType.detail).foregroundStyle(theme.textSecondary)
            Picker("Blocking mode", selection: Binding(get: { blocker.mode }, set: { blocker.setMode($0) })) {
                ForEach(AdBlockingMode.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
                .focusable().focused($blockingModeFocused)
            Text(blocker.mode.detail).font(OrivType.body).foregroundStyle(theme.secondaryText).fixedSize(horizontal: false, vertical: true)
            if let tab, AdBlocker.host(for: tab.url) != nil {
                Divider()
                PrivacyShieldControls(session: session, tab: tab)
            }
            if blocker.isPreparing { ProgressView("Preparing protection…").controlSize(.small) }
            if let error = blocker.preparationError {
                Text(error).font(OrivType.caption).foregroundStyle(theme.danger)
            }
            if blocker.mode == .strict {
                if blocker.isPreparingCNAME { ProgressView(OrivStrings.preparingTrackerProtection).controlSize(.small) }
                if let error = blocker.cnamePreparationError { Text(error).font(OrivType.caption).foregroundStyle(theme.danger) }
            }
            Text("Works in normal and private tabs. Reload to apply changes fully. Filters update with Oriv releases; some ads may remain.")
                .font(OrivType.caption).foregroundStyle(theme.secondaryText).fixedSize(horizontal: false, vertical: true)
        }
            .defaultFocus($blockingModeFocused, true)
            .browserGeometryMarker("sitePrivacyPanelGeometry")
    }
}
