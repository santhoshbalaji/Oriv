import BrowserEngine
import SwiftUI

struct AdBlockingPopover: View {
    let session: BrowserSession
    private var blocker: AdBlocker { session.adBlocker }
    private var tab: BrowserTab? { session.selectedTab }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            EditorHeading(title: "A quieter web", subtitle: "Ad & tracker blocking", symbol: "shield.lefthalf.filled")
            Picker("Blocking mode", selection: Binding(get: { blocker.mode }, set: { blocker.setMode($0) })) {
                ForEach(AdBlockingMode.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            Text(blocker.mode.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let tab, let host = AdBlocker.host(for: tab.url) {
                Divider()
                Text(host).font(.subheadline.weight(.medium)).lineLimit(2)
                Toggle("Block on this site", isOn: Binding(
                    get: { !blocker.isException(tab.url, isPrivate: tab.isPrivate) },
                    set: { blocker.setException(!$0, for: tab.url, isPrivate: tab.isPrivate) }
                )).disabled(blocker.mode == .off)
                if tab.isPrivate {
                    Label("This exception lasts only for this private session.", systemImage: "eyeglasses")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Reload page", systemImage: "arrow.clockwise") { tab.reload() }.buttonStyle(.glass).disabled(blocker.isPreparing)
            }
            if blocker.isPreparing { ProgressView("Preparing protection…").controlSize(.small) }
            if let error = blocker.preparationError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Text("Works in normal and private tabs. Reload to apply changes fully. Filters update with Oriv releases; some ads may remain.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(20).frame(width: 320)
    }
}
