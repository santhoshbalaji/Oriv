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
                    } } label: { rowLabel(OrivStrings.otherDevices, "laptopcomputer.and.iphone", theme) }
                    NavigationLink { MobileDownloadsView(downloads: controller.downloads) } label: {
                        SettingRow(detail: controller.downloads.activeCount > 0 ? "\(controller.downloads.activeCount) active" : nil) {
                            rowLabel("Downloads", "arrow.down.circle", theme)
                        }
                    }
                }.listRowBackground(theme.surfaceRaised)
                Section {
                    NavigationLink { MobileSettingsView(controller: controller, profiles: profiles) } label: { rowLabel("Settings", "gearshape", theme) }
                }.listRowBackground(theme.surfaceRaised)
            }.orivListStyle(theme).navigationTitle("Library").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct MobileSavedPages: View {
    @Environment(\.browserTheme) private var theme
    let controller: MobileController
    let history: Bool
    @State private var query = ""
    @State private var historyOffset = 0
    @State private var confirmClear = false
    private let historyPageSize = 100
    private var title: String { history ? "History" : "Bookmarks" }
    private func matches(_ title: String, _ url: URL) -> Bool { query.isEmpty || title.localizedCaseInsensitiveContains(query) || url.absoluteString.localizedCaseInsensitiveContains(query) }
    var body: some View {
        List {
            if history {
                let page = controller.session.historyPage(search: query, offset: historyOffset, limit: historyPageSize + 1)
                let entries = Array(page.prefix(historyPageSize))
                if entries.isEmpty { empty(isEmpty: controller.session.historyCount == 0) }
                let context = URLDisplay.Context(entries.map { ($0.title, $0.url) })
                ForEach(entries) { entry in
                    link(entry.title, url: entry.url, context: context).listRowBackground(theme.surfaceRaised)
                        .swipeActions { Button("Remove", role: .destructive) { controller.session.removeHistory(entry.id) } }
                }
                if historyOffset > 0 || page.count > historyPageSize {
                    HStack {
                        Button("Previous Page") { historyOffset -= historyPageSize }.disabled(historyOffset == 0)
                        Spacer()
                        Button("Next Page") { historyOffset += historyPageSize }.disabled(page.count <= historyPageSize)
                    }.buttonStyle(.borderless).listRowBackground(theme.surfaceRaised)
                }
                if controller.session.historyCount > 0 {
                    Button(OrivStrings.clearHistoryPrompt, role: .destructive) { confirmClear = true }
                        .orivButton(.destructive).listRowBackground(theme.surfaceRaised)
                }
            } else {
                let entries = controller.session.bookmarks.filter { matches($0.title, $0.url) }
                if controller.session.canUndoBookmarkRemoval {
                    OrivBanner(message: "Bookmark removed") {
                        Button("Undo") { controller.session.undoBookmarkRemoval() }
                    }.listRowBackground(theme.surfaceRaised)
                }
                if entries.isEmpty { empty(isEmpty: controller.session.bookmarks.isEmpty) }
                let context = URLDisplay.Context(entries.map { ($0.title, $0.url) })
                ForEach(entries) { entry in
                    link(entry.title, url: entry.url, context: context).listRowBackground(theme.surfaceRaised)
                        .swipeActions { Button("Delete", role: .destructive) { controller.session.removeBookmark(entry.id) } }
                }
            }
        }.orivListStyle(theme).navigationTitle(title).searchable(text: $query, prompt: "Search \(title.lowercased())")
            .onChange(of: query) { _, _ in historyOffset = 0 }
            .onChange(of: controller.session.historyRevision) { _, _ in
                if history && controller.session.historyPage(search: query, offset: historyOffset, limit: 1).isEmpty { historyOffset = 0 }
            }
            .confirmationDialog("Clear browsing history?", isPresented: $confirmClear) {
                Button(OrivStrings.clearHistory, role: .destructive) { controller.session.clearHistory() }
            }
    }
    @ViewBuilder private func empty(isEmpty: Bool) -> some View {
        BrowserEmptyState(isEmpty ? (history ? "No history yet. Private tabs aren’t included." : "No bookmarks yet. Bookmark a page from its options menu.") : "No results for “\(query)”.")
            .listRowBackground(theme.surfaceRaised).listRowSeparator(.hidden)
    }
    private func link(_ title: String, url: URL, context: URLDisplay.Context) -> some View {
        Button { controller.open(url) } label: {
            PageRowContent(title: title, url: url, context: context).frame(minHeight: OrivTarget.touch.height)
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
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    var reduceMotionOverride:Bool? = nil
    private var reduceMotion:Bool { reduceMotionOverride ?? systemReduceMotion }
    @State private var query = ""
    @State private var searching = false
    @State private var privateMode = false
    private var modeTabs: [BrowserTab] { controller.session.orderedTabs.filter { $0.isPrivate == privateMode } }
    var body: some View {
        let matches = modeTabs.filter {
            query.isEmpty || $0.displayTitle.localizedCaseInsensitiveContains(query) || $0.hostname.localizedCaseInsensitiveContains(query)
        }
        NavigationStack {
            MobileTabGrid(controller: controller, profiles: profiles, tabs: matches,
                largeText: typeSize.isAccessibilitySize, reduceMotion: reduceMotion, open: { tab in controller.tabPresentation.pendingSelection = tab.id; dismissGrid() }, onPull: onPull, onPinch: onPinch, presented:presented, visible:visible)
                .background(theme.canvas)
                .overlay {
                    if presented && matches.isEmpty {
                        BrowserEmptyState(query.isEmpty ? (privateMode ? "No private tabs" : "No tabs") : "No results for “\(query)”.")
                            .padding(OrivSpacing.large)
                            .allowsHitTesting(false)
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $query, isPresented: $searching, placement: .toolbar, prompt: OrivStrings.searchTabs)
                .toolbar(removing: .search)
                .onAppear { privateMode = controller.session.selectedTab?.isPrivate == true }
                .onChange(of:presented) { _, visible in if visible { privateMode = controller.session.selectedTab?.isPrivate == true } }
                .onChange(of:controller.session.selectedTab?.isPrivate) { _, value in if !presented { privateMode = value == true } }
                .toolbar(visible ? .visible : .hidden, for: .navigationBar, .bottomBar)
                .toolbarColorScheme(presented ? controller.appearance.colorScheme : nil, for: .navigationBar, .bottomBar)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Button(controller.downloads.hasActivity ? "Library, Downloads Available" : "Library", systemImage: "books.vertical") {
                                controller.sheet = .library
                            }
                            Menu("Recently Closed Tabs") { recentlyClosed }
                            Divider()
                            Button("Close All Tabs", role: .destructive) { closeModeTabs() }
                        } label: { BarButtonIcon(symbol: "ellipsis", secondary: true, width: OrivTarget.touch.width) }
                            .accessibilityLabel("Tab actions").menuOrder(.fixed).tint(.primary)
                    }
                    if typeSize.isAccessibilitySize {
                        ToolbarItem(placement: .principal) { profilePicker }
                    }
                    DefaultToolbarItem(kind: .search, placement: .topBarTrailing)
                    ToolbarItem(placement: .bottomBar) { gridControls }.sharedBackgroundVisibility(.hidden)
                }
        }
    }
    private var gridControls: some View {
        HStack(spacing: OrivSpacing.small) {
            BarButton {
                Button { controller.newTab(isPrivate: privateMode) } label: {
                    BarButtonIcon(symbol: "plus")
                }
                .accessibilityLabel(privateMode ? "New Private Tab" : "New Tab")
                .contextMenu { recentlyClosed }.menuOrder(.fixed)
            }
            Spacer(minLength: 0)
            Picker("Browsing mode", selection: $privateMode) {
                Text("Tabs").tag(false)
                Text("Private").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: typeSize.isAccessibilitySize ? 164 : 124)
            .frame(minHeight: OrivTarget.touch.height)
            .accessibilityIdentifier("tabGridMode")
            if !typeSize.isAccessibilitySize { profilePicker }
            Spacer(minLength: 0)
            BarButton {
                Button(action: finishBrowsingMode) {
                    BarButtonIcon(symbol: "checkmark")
                }
                .accessibilityLabel("Done").accessibilityIdentifier("tabGridDone")
                .contextMenu { Button("Close All Tabs", role: .destructive) { closeModeTabs() } }.menuOrder(.fixed)
            }
        }
        .frame(maxWidth: .infinity)
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
    @ViewBuilder private var profileChoices: some View {
        ForEach(profiles.profiles.filter { $0.archivedAt == nil }) { profile in
            Button(profile.name, systemImage: controller.profileID == profile.id ? "checkmark" : profile.symbol.rawValue) {
                guard controller.profileID != profile.id else { return }
                controller.sheet = nil
                profiles.select(profile); profiles.current.sheet = .tabs
            }
        }
        if profiles.externalPrivate != nil {
            Button("External Private Tabs", systemImage: controller.profileID == nil ? "checkmark" : "eyeglasses") {
                guard controller.profileID != nil else { return }
                controller.sheet = nil
                profiles.showExternalPrivate()
                profiles.current.sheet = .tabs
            }
        }
    }

    private var profilePicker: some View {
        let profile = profiles.profiles.first { $0.id == controller.profileID }
        let name = profile?.name ?? "External Private Tabs"
        return Menu {
            profileChoices
        } label: {
            HStack(spacing: OrivSpacing.xs) {
                Image(systemName: profile?.symbol.rawValue ?? "eyeglasses")
                    .foregroundStyle(profileInk(profile?.color))
                Text(name).font(OrivType.detail.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(OrivType.caption)
            }
            .padding(.horizontal, OrivSpacing.small)
            .frame(minHeight: OrivTarget.touch.height)
        }
        .accessibilityLabel("Profile").accessibilityValue(name)
        .accessibilityIdentifier("tabGridProfile")
        .menuOrder(.fixed).tint(theme.text).modifier(OrivMaterial.control())
    }

    private func profileInk(_ color: ProfileColor?) -> Color {
        switch color {
        case .mulberry, nil: theme.private
        case .ocean: theme.accent
        case .fern: theme.success
        case .amber: theme.warning
        case .slate: theme.textSecondary
        }
    }
}

struct MobileDownloadsView: View {
    @Environment(\.browserTheme) private var theme
    let downloads: MobileDownloads
    var body: some View {
        List {
            if downloads.entries.isEmpty { BrowserEmptyState("No downloads yet. Save files you want to keep to Files.").listRowBackground(theme.surfaceRaised).listRowSeparator(.hidden) }
            ForEach(downloads.entries) { entry in
                VStack(alignment: .leading, spacing: OrivSpacing.small) {
                    Text(entry.name).font(OrivType.title); Text(entry.status).font(OrivType.body).foregroundStyle(theme.textSecondary)
                    if entry.isActive {
                        if entry.totalBytes > 0 { ProgressView(value: Double(entry.bytesReceived), total: Double(max(entry.totalBytes, entry.bytesReceived))).tint(theme.accent) }
                        else { ProgressView() }
                        Text(ByteCountFormatter.string(fromByteCount: entry.bytesReceived, countStyle: .file)).font(OrivType.caption)
                        Button("Cancel") { downloads.cancel(entry.id) }
                    }
                    if let url = entry.url { ShareLink("Save to Files or Share", item: url) }
                }.padding(.vertical, OrivSpacing.small).listRowBackground(theme.surfaceRaised)
            }
            if !downloads.entries.isEmpty {
                Section { } footer: { Text("Downloads are kept until you close Oriv. Use Share to save files to Files.") }
            }
        }.orivListStyle(theme).navigationTitle("Downloads")
    }
}

/// Library and settings rows: quiet icons, primary text.
func rowLabel(_ title: String, _ symbol: String, _ theme: Theme) -> some View {
    Label { Text(title).foregroundStyle(theme.text) } icon: { Image(systemName: symbol).foregroundStyle(theme.textSecondary) }
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
                    VStack(spacing: OrivSpacing.large) { SiteIdentity(url: tab.url, size: 48, isPrivate: tab.isPrivate); Text(tab.displayTitle).font(OrivType.title).lineLimit(2).multilineTextAlignment(.center).foregroundStyle(theme.text) }.padding()
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
