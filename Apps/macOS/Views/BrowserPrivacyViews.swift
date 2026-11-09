import BrowserCore
import BrowserEngine
import SwiftUI
import WebKit

struct SiteInformationView: View {
    @Environment(\.browserTheme) private var theme
    let session: BrowserSession
    let tab: BrowserTab
    private var rule: SiteRule { session.settings.rule(for: tab.url, isPrivate: tab.isPrivate) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            let connection = ConnectionCue(tab, includeRecording: false)
            Label(connection.label, systemImage: connection.symbol)
                .font(.headline).foregroundStyle(connection.color(theme))
            Text(tab.url.flatMap(SiteOrigin.init)?.displayName ?? "No website open").font(.callout).textSelection(.enabled)
            Text(tab.isSecure ? "WebKit reports HTTPS with secure page content. This does not verify the site's identity or claims." : "An encrypted connection with fully secure content has not been confirmed. Check the address before sharing sensitive information.")
                .font(.caption).foregroundStyle(theme.secondaryText).fixedSize(horizontal: false, vertical: true)
            if let url = tab.url, SiteOrigin(url) != nil {
                Divider()
                permission("Camera", path: \.camera, url: url)
                permission("Microphone", path: \.microphone, url: url)
                Toggle("Allow automatic pop-ups", isOn: Binding(get: { rule.allowsAutomaticPopups }, set: {
                    var updated = rule; updated.allowsAutomaticPopups = $0; session.settings.setRule(updated, for: url, isPrivate: tab.isPrivate)
                })).tint(theme.accent)
                Text("Ask uses WebKit and macOS permission prompts. Changes apply to this exact site and port. Reload for pop-up changes.")
                    .font(.caption).foregroundStyle(theme.secondaryText)
                if tab.isCapturingCamera || tab.isCapturingMicrophone {
                    Label("This tab is using camera or microphone", systemImage: "record.circle.fill").foregroundStyle(.red)
                    Button("Stop Camera and Microphone") { tab.stopCapture() }
                }
                Button("Reset Site Permissions") { session.settings.setRule(SiteRule(), for: url, isPrivate: tab.isPrivate); tab.stopCapture() }
                if tab.isPrivate { Text("Private site settings are forgotten when the last private tab closes.").font(.caption).foregroundStyle(theme.secondaryText) }
            }
        }.padding(20).frame(width: 330)
    }
    private func permission(_ title: String, path: WritableKeyPath<SiteRule, SitePermission>, url: URL) -> some View {
        Picker(title, selection: Binding(get: { rule[keyPath: path] }, set: {
            var updated = rule; updated[keyPath: path] = $0; session.settings.setRule(updated, for: url, isPrivate: tab.isPrivate)
        })) { ForEach(SitePermission.allCases) { Text($0.rawValue).tag($0) } }
    }
}

struct WebsiteDataView: View {
    @Environment(\.browserTheme) private var theme
    let manager: WebsiteDataManager
    @State private var query = ""
    @State private var pending: [WKWebsiteDataRecord] = []
    @State private var confirm = false
    @Environment(\.dismiss) private var dismiss
    private var records: [WKWebsiteDataRecord] { manager.records.filter { query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Website data").font(Theme.editorial(26)); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text("Cookies, caches and offline storage from regular browsing. Removing data may sign you out and delete a site's offline work. Bookmarks are kept separately.").font(.callout).foregroundStyle(theme.secondaryText)
            TextField("Search websites", text: $query).textFieldStyle(.roundedBorder)
            List(records, id: \.displayName) { record in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.displayName)
                        Text("\(record.dataTypes.count) storage types").font(.caption).foregroundStyle(theme.secondaryText)
                    }
                    Spacer()
                    Button("Remove…", role: .destructive) { pending = [record]; confirm = true }
                        .accessibilityLabel("Remove data for \(record.displayName)")
                }.padding(.vertical, 4)
            }.overlay { if manager.isWorking { ProgressView() } else if records.isEmpty { BrowserEmptyState(manager.records.isEmpty ? "No website data" : "No results for “\(query)”.") } }
            HStack {
                Text("\(manager.records.count) websites").font(.caption).foregroundStyle(theme.secondaryText)
                Spacer()
                Button("Refresh") { Task { await manager.refresh() } }
                Button("Remove All…", role: .destructive) { pending = manager.records; confirm = true }.disabled(manager.records.isEmpty)
            }
        }.padding(24).frame(width: 600, height: 520)
            .disabled(manager.isWorking)
            .task { await manager.refresh() }
            .confirmationDialog("Remove website data?", isPresented: $confirm) {
                Button("Remove Data", role: .destructive) { let selected = pending; pending = []; Task { await manager.remove(selected) } }
            } message: { Text("This removes stored data for \(pending.count) selected websites. This cannot be undone. Open sites may create new data; close their tabs first.") }
    }
}

struct ClearBrowsingDataView: View {
    @Environment(\.browserTheme) private var theme
    let session: BrowserSession
    @State private var hours = 1
    @State private var clearHistory = true
    @State private var clearCache = false
    @State private var clearSites = false
    @State private var clearPermissions = false
    @State private var confirm = false
    @State private var working = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Clear browsing data").font(Theme.editorial(26))
            Picker("Time range", selection: $hours) {
                Text("Last hour").tag(1); Text("Last 24 hours").tag(24); Text("Last 7 days").tag(168); Text("All time").tag(0)
            }
            Toggle("Browsing history", isOn: $clearHistory).tint(theme.accent)
            Toggle("Cached website files", isOn: $clearCache).tint(theme.accent)
            Toggle("Cookies and website data", isOn: $clearSites).tint(theme.accent)
            Toggle("All saved site permissions", isOn: $clearPermissions).tint(theme.accent)
            Text("Website data includes logins and offline work. WebKit applies the time range to stored records, which may contain older content. Open tabs, bookmarks and downloaded files remain.")
                .font(.callout).foregroundStyle(theme.secondaryText).fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); if working { ProgressView().controlSize(.small) }; Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button("Clear Selected Data…", role: .destructive) { confirm = true }.disabled(!clearHistory && !clearCache && !clearSites && !clearPermissions) }
        }.padding(28).frame(width: 520).disabled(working)
            .confirmationDialog("Clear selected browsing data?", isPresented: $confirm) {
                Button("Clear Data", role: .destructive) {
                    working = true
                    Task {
                        let since = hours == 0 ? Date.distantPast : Date.now.addingTimeInterval(-Double(hours) * 3600)
                        if clearHistory { session.clearHistory(since: since) }
                        if clearPermissions { session.settings.clearRules(); session.tabs.forEach { $0.stopCapture() } }
                        if clearCache || clearSites { await session.websiteData.clear(since: since, cacheOnly: !clearSites) }
                        working = false; dismiss()
                    }
                }
            } message: { Text("This cannot be undone. Close website tabs first to prevent them from recreating data.") }
    }
}
