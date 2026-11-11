import SwiftUI
import BrowserCore
import BrowserEngine
import WebKit

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

struct MobileSavedPages: View {
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
    let controller: MobileController
    let profiles: MobileProfiles
    let dismissGrid: () -> Void
    let onPull: (CGFloat, Bool) -> Void
    var onPinch: ((BrowserTab, CGFloat, Bool) -> Void)? = nil
    var presented = true
    var visible = true
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var searching = false
    @State private var privateMode = false
    private var modeTabs: [BrowserTab] { controller.session.orderedTabs.filter { $0.isPrivate == privateMode } }
    private var matches: [BrowserTab] { modeTabs.filter { query.isEmpty || $0.displayTitle.localizedCaseInsensitiveContains(query) || $0.hostname.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        NavigationStack {
            MobileTabGrid(controller: controller, profiles: profiles, tabs: matches,
                largeText: typeSize.isAccessibilitySize, reduceMotion: reduceMotion, open: { tab in controller.tabPresentation.pendingSelection = tab.id; dismissGrid() }, onPull: onPull, onPinch: onPinch, presented:presented, visible:visible)
                .background(theme.canvas).navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .top, spacing: 0) {
                    if searching {
                        HStack {
                            Image(systemName: "magnifyingglass")
                            TextField("Search tabs", text: $query).accessibilityIdentifier("tabSearch")
                            Button("Cancel") { query = ""; searching = false }
                        }.padding(12).browserGlass().padding(.horizontal, 16).padding(.bottom, 8)
                    }
                }
                .onAppear { privateMode = controller.session.selectedTab?.isPrivate == true }
                .onChange(of:presented) { _, visible in if visible { privateMode = controller.session.selectedTab?.isPrivate == true } }
                .onChange(of:controller.session.selectedTab?.isPrivate) { _, value in if !presented { privateMode = value == true } }
                .toolbar(.visible, for: .navigationBar)
                .toolbarColorScheme(presented ? controller.appearance.colorScheme : nil, for: .navigationBar, .bottomBar)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Button("New Private Tab", systemImage: "eyeglasses") { controller.newTab(isPrivate: true) }
                            Button("Library", systemImage: "book") { controller.sheet = .library }
                            Menu("Recently Closed Tabs") { recentlyClosed }
                            Divider()
                            Button("Close All Tabs", role: .destructive) { closeModeTabs() }
                        } label: { Image(systemName: "ellipsis").font(.system(size: 22)).frame(minWidth: 44, minHeight: 44) }.accessibilityLabel("Tab actions").menuOrder(.fixed).tint(.primary)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Search Tabs", systemImage: "magnifyingglass") { searching.toggle(); if !searching { query = "" } }
                            .tint(.primary)
                    }
                    ToolbarItem(placement: .bottomBar) {
                        Button { controller.newTab(isPrivate: privateMode) } label: { Image(systemName: "plus").font(.system(size: 22)).frame(minWidth: 44, minHeight: 44) }
                            .accessibilityLabel("New Tab").tint(.primary).contextMenu { recentlyClosed }.menuOrder(.fixed)
                    }
                    ToolbarSpacer(.flexible, placement: .bottomBar)
                    ToolbarItem(placement: .bottomBar) { profilePicker }.sharedBackgroundVisibility(.hidden)
                    ToolbarSpacer(.flexible, placement: .bottomBar)
                    ToolbarItem(placement: .bottomBar) {
                        Button(action: finishBrowsingMode) { Image(systemName: "checkmark").font(.system(size: 22)).frame(minWidth: 44, minHeight: 44) }
                            .tint(.primary).accessibilityLabel("Done")
                            .contextMenu { Button("Close All Tabs", role: .destructive) { closeModeTabs() } }.menuOrder(.fixed)
                    }
                }
        }
    }
    @ViewBuilder private var recentlyClosed: some View {
        if controller.session.recentlyClosedTabs.isEmpty { Text("No Recently Closed Tabs") }
        ForEach(controller.session.recentlyClosedTabs) { record in
            Button(record.title.isEmpty ? "New Tab" : record.title) { controller.session.reopenClosedTab(record.id); dismissGrid() }
        }
    }
    private func finishBrowsingMode() {
        if controller.session.selectedTab?.isPrivate != privateMode {
            if let tab = modeTabs.first { controller.tabPresentation.pendingSelection = tab.id }
            else { controller.tabPresentation.pendingNewTab = privateMode }
        }
        dismissGrid()
    }
    private func closeModeTabs() { controller.close(modeTabs.map(\.id), confirmAll: true) }
    private var profilePicker: some View {
        Menu {
            Button("Private", systemImage: "eyeglasses") { privateMode = true }
            Button("\(controller.session.tabs.filter { !$0.isPrivate }.count) Tabs", systemImage: "square.on.square") { privateMode = false }
            Divider()
            ForEach(profiles.profiles.filter { $0.archivedAt == nil }) { profile in
                Button(profile.name, systemImage: controller.profileID == profile.id ? "checkmark" : profile.symbol.rawValue) {
                    guard controller.profileID != profile.id else { return }
                    controller.sheet = nil
                    profiles.select(profile); profiles.current.sheet = .tabs
                }
            }
            if profiles.externalPrivate != nil { Button("External Private Tabs", systemImage: "eyeglasses") { controller.sheet = nil; profiles.showExternalPrivate(); profiles.current.sheet = .tabs } }
        } label: {
            HStack(spacing: 8) {
                if !typeSize.isAccessibilitySize {
                    Text("Private").foregroundStyle(privateMode ? .primary : .secondary)
                    Divider().frame(height: 18)
                }
                Text(typeSize.isAccessibilitySize && privateMode ? "Private" : "\(controller.session.tabs.filter { !$0.isPrivate }.count) Tabs").fontWeight(.semibold)
                    .foregroundStyle(privateMode && !typeSize.isAccessibilitySize ? .secondary : .primary)
                Image(systemName: "chevron.down").font(.caption)
            }.font(.subheadline).lineLimit(1).frame(minHeight: 44).padding(.horizontal, 12)
        }.accessibilityLabel("Browsing Mode and Profile")
            .accessibilityValue("\(privateMode ? "Private" : "Tabs"), \(profiles.profiles.first { $0.id == controller.profileID }?.name ?? "External Private Tabs")")
            .menuOrder(.fixed).tint(.primary).browserGlass()
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

/// Snapshots only already-loaded tabs; never creates a WebView or starts background loads.
struct MobileTabThumbnail: View {
    @Environment(\.browserTheme) private var theme
    let tab: BrowserTab
    var presentation: MobileTabPresentation? = nil
    @State private var image: UIImage?
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                theme.surface
                if let image = presentation?.images[tab.id] ?? image {
                    Image(uiImage: image).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height, alignment: .top).clipped()
                } else {
                    VStack(spacing: 16) { SiteIdentity(url: tab.url, size: 48, isPrivate: tab.isPrivate); Text(tab.displayTitle).font(.headline).multilineTextAlignment(.center).foregroundStyle(theme.text) }.padding()
                }
            }
        }.accessibilityHidden(true)
            .task(id: "\(tab.documentRevision)-\(presentation?.cacheRevision ?? 0)") {
                if let presentation { presentation.capture(tab); return }
                guard tab.hasLoaded else { return }
                let configuration = WKSnapshotConfiguration(); configuration.snapshotWidth = 360
                image = try? await tab.webView.takeSnapshot(configuration: configuration)
            }
    }
}
