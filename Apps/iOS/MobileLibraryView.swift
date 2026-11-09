import SwiftUI
import BrowserCore
import BrowserEngine

struct MobileLibraryView: View {
    @Environment(\.browserTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let controller: MobileController
    let profiles: MobileProfiles
    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { MobileSavedPages(controller: controller, history: false) } label: { rowLabel("Bookmarks", "bookmark", theme) }
                    NavigationLink { MobileSavedPages(controller: controller, history: true) } label: { rowLabel("History", "clock", theme) }
                    NavigationLink { OtherDeviceTabsView(continuity: profiles.continuity) { page in
                        controller.sheet = nil
                        // Dismiss before replacing the sheet's profile owner.
                        Task { @MainActor in try? await Task.sleep(for: .milliseconds(350)); profiles.openContinuityPage(page) }
                    } } label: { rowLabel("Other Devices", "laptopcomputer.and.iphone", theme) }
                    NavigationLink { MobileDownloadsView(downloads: controller.downloads) } label: {
                        HStack { rowLabel("Downloads", "arrow.down.circle", theme); Spacer(); if controller.downloads.activeCount > 0 { Text("\(controller.downloads.activeCount) active").font(.footnote).foregroundStyle(theme.secondaryText) } }
                    }
                }.listRowBackground(theme.row)
                Section {
                    NavigationLink { MobileSettingsView(controller: controller, profiles: profiles) } label: { rowLabel("Settings", "gearshape", theme) }
                }.listRowBackground(theme.row)
            }.orivListStyle(theme).navigationTitle("Library")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

private struct MobileSavedPages: View {
    @Environment(\.browserTheme) private var theme
    let controller: MobileController
    let history: Bool
    @State private var query = ""
    private var title: String { history ? "History" : "Bookmarks" }
    private func matches(_ title: String, _ url: URL) -> Bool { query.isEmpty || title.localizedCaseInsensitiveContains(query) || url.absoluteString.localizedCaseInsensitiveContains(query) }
    var body: some View {
        List {
            if history {
                let entries = controller.session.history.filter { matches($0.title, $0.url) }
                if entries.isEmpty { empty(isEmpty: controller.session.history.isEmpty) }
                let context = URLDisplay.Context(entries.map { ($0.title, $0.url) })
                ForEach(entries) { entry in
                    link(entry.title, url: entry.url, context: context).listRowBackground(theme.row)
                        .swipeActions { Button("Remove", role: .destructive) { controller.session.removeHistory(entry.id) } }
                }
            } else {
                let entries = controller.session.bookmarks.filter { matches($0.title, $0.url) }
                if controller.session.canUndoBookmarkRemoval {
                    HStack { Text("Bookmark removed").foregroundStyle(theme.secondaryText); Spacer(); Button("Undo") { controller.session.undoBookmarkRemoval() } }.listRowBackground(theme.row)
                }
                if entries.isEmpty { empty(isEmpty: controller.session.bookmarks.isEmpty) }
                let context = URLDisplay.Context(entries.map { ($0.title, $0.url) })
                ForEach(entries) { entry in
                    link(entry.title, url: entry.url, context: context).listRowBackground(theme.row)
                        .swipeActions { Button("Delete", role: .destructive) { controller.session.removeBookmark(entry.id) } }
                }
            }
        }.orivListStyle(theme).navigationTitle(title).searchable(text: $query, prompt: "Search \(title.lowercased())")
    }
    @ViewBuilder private func empty(isEmpty: Bool) -> some View {
        BrowserEmptyState(isEmpty ? (history ? "No history yet. Private tabs aren’t included." : "No bookmarks yet. Bookmark a page from its options menu.") : "No results for “\(query)”.")
            .listRowBackground(theme.row).listRowSeparator(.hidden)
    }
    private func link(_ title: String, url: URL, context: URLDisplay.Context) -> some View {
        Button { controller.open(url) } label: {
            PageRowContent(title: title, url: url, context: context).frame(minHeight: 44)
        }.contextMenu { Button("Open in New Tab") { controller.session.openSavedPage(url, inNewTab: true); controller.sheet = nil } }
    }
}

struct MobileTabsView: View {
    @Environment(\.browserTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let controller: MobileController
    let profileName: String
    var profiles = 1
    @State private var query = ""
    @State private var closing: UUID?
    private var matches: [BrowserTab] { controller.session.orderedTabs.filter { query.isEmpty || $0.displayTitle.localizedCaseInsensitiveContains(query) || $0.hostname.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        NavigationStack {
            List {
                tabSection(matches.contains(where: \.isPrivate) ? "Tabs" : nil, privateMode: false)
                if matches.contains(where: \.isPrivate) { tabSection("Private", privateMode: true) }
                if matches.isEmpty { BrowserEmptyState(query.isEmpty ? "No open tabs" : "No results for “\(query)”.").listRowBackground(theme.row).listRowSeparator(.hidden) }
                if controller.session.canReopenTab {
                    Button("Reopen Closed Tab", systemImage: "arrow.uturn.backward") { controller.session.reopenClosedTab(); dismiss() }.listRowBackground(theme.row)
                }
            }.orivListStyle(theme).navigationTitle(profiles > 1 ? "Tabs · \(profileName)" : "Tabs").navigationBarTitleDisplayMode(.inline)
                .searchable(text: $query, prompt: "Search tabs")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) {
                        Menu { Button("New Tab") { controller.newTab() }; Button("New Private Tab") { controller.newTab(isPrivate: true) } } label: { Label("New Tab", systemImage: "plus") }
                    }
                }
                .alert("Close a page with edited fields?", isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } })) {
                    Button("Keep Tab", role: .cancel) { closing = nil }
                    Button("Close Tab", role: .destructive) { if let id = closing { controller.session.closeTab(id) }; closing = nil }
                } message: { Text("Oriv cannot determine whether the website saved your edits. Closing this tab may lose them.") }
        }
    }
    private func tabSection(_ title: String?, privateMode: Bool) -> some View {
        Section {
            let shown = matches.filter { $0.isPrivate == privateMode }
            let context = URLDisplay.Context(shown.compactMap { tab in tab.url.map { (tab.displayTitle, $0) } })
            ForEach(shown) { tab in
                HStack(spacing: OrivSpacing.small) {
                    Button { controller.session.selectTab(tab.id); dismiss() } label: {
                        PageRowContent(title: tab.displayTitle, url: tab.url, context: context,
                                       titleWeight: controller.session.selectedTabID == tab.id ? .semibold : .regular,
                                       isPrivate: tab.isPrivate, isSelected: controller.session.selectedTabID == tab.id,
                                       accessory: controller.session.selectedTabID == tab.id ? .selected : .none)
                            .frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityAddTraits(controller.session.selectedTabID == tab.id ? [.isSelected] : [])
                    Button { close(tab) } label: { Image(systemName: "xmark").font(.footnote.weight(.semibold)).frame(width: 44, height: 44) }
                        .buttonStyle(.borderless).foregroundStyle(theme.secondaryText).accessibilityLabel("Close \(tab.displayTitle)")
                }.listRowBackground(theme.row).swipeActions { Button("Close", role: .destructive) { close(tab) } }
            }
        } header: { if let title { Text(title) } }
    }
    private func close(_ tab: BrowserTab) {
        if controller.session.requiresCloseConfirmation(tab.id) { closing = tab.id }
        else { controller.session.closeTab(tab.id) }
    }
}

struct MobileDownloadsView: View {
    @Environment(\.browserTheme) private var theme
    let downloads: MobileDownloads
    var body: some View {
        List {
            if downloads.entries.isEmpty { BrowserEmptyState("No downloads yet. Save files you want to keep to Files.").listRowBackground(theme.row).listRowSeparator(.hidden) }
            ForEach(downloads.entries) { entry in
                VStack(alignment: .leading, spacing: OrivSpacing.small) {
                    Text(entry.name).font(.headline); Text(entry.status).font(.callout).foregroundStyle(theme.secondaryText)
                    if entry.isActive {
                        if entry.totalBytes > 0 { ProgressView(value: Double(entry.bytesReceived), total: Double(max(entry.totalBytes, entry.bytesReceived))).tint(theme.accent) }
                        else { ProgressView() }
                        Text(ByteCountFormatter.string(fromByteCount: entry.bytesReceived, countStyle: .file)).font(.caption)
                        Button("Cancel") { downloads.cancel(entry.id) }
                    }
                    if let url = entry.url { ShareLink("Save to Files or Share", item: url) }
                }.padding(.vertical, 6).listRowBackground(theme.row)
            }
            if !downloads.entries.isEmpty {
                Section { } footer: { Text("Downloads are kept until you close Oriv. Use Share to save files to Files.") }
            }
        }.orivListStyle(theme).navigationTitle("Downloads")
    }
}

/// Library and settings rows: quiet icons, primary text.
func rowLabel(_ title: String, _ symbol: String, _ theme: Theme) -> some View {
    Label { Text(title).foregroundStyle(theme.text) } icon: { Image(systemName: symbol).foregroundStyle(theme.secondaryText) }
}
