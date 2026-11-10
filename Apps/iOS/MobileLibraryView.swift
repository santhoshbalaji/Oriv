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
    let profiles: MobileProfiles
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var query = ""
    @State private var closing: UUID?
    private var matches: [BrowserTab] { controller.session.orderedTabs.filter { query.isEmpty || $0.displayTitle.localizedCaseInsensitiveContains(query) || $0.hostname.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: typeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 22) {
                    tabSection(matches.contains(where: \.isPrivate) ? "Tabs" : nil, privateMode: false)
                    if matches.contains(where: \.isPrivate) { tabSection("Private", privateMode: true) }
                }.padding(16)
                if matches.isEmpty { BrowserEmptyState(query.isEmpty ? "No open tabs" : "No results for “\(query)”.") }
                if controller.session.canReopenTab {
                    Button("Reopen Closed Tab", systemImage: "arrow.uturn.backward") { controller.session.reopenClosedTab() }.padding()
                }
            }.background(theme.canvas).navigationTitle("Tabs").navigationBarTitleDisplayMode(.inline)
                .searchable(text: $query, prompt: "Search tabs")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Button("New Private Tab", systemImage: "eyeglasses") { controller.newTab(isPrivate: true) }
                            Button("Library", systemImage: "book") { controller.sheet = .library }
                        } label: { Image(systemName: "ellipsis").font(.system(size: 22)).frame(minWidth: 44, minHeight: 44) }.accessibilityLabel("Tab actions")
                    }
                    ToolbarItem(placement: .bottomBar) {
                        Button { controller.newTab() } label: { Image(systemName: "plus").font(.system(size: 22)).frame(minWidth: 44, minHeight: 44) }.accessibilityLabel("New Tab")
                    }
                    ToolbarSpacer(.flexible, placement: .bottomBar)
                    ToolbarItem(placement: .bottomBar) { profilePicker }.sharedBackgroundVisibility(.hidden)
                    ToolbarSpacer(.flexible, placement: .bottomBar)
                    ToolbarItem(placement: .bottomBar) {
                        Button { dismiss() } label: { Image(systemName: "checkmark").font(.system(size: 22)).foregroundStyle(.white).frame(minWidth: 44, minHeight: 44) }
                            .buttonStyle(.glassProminent).tint(theme.controlFill).accessibilityLabel("Done")
                    }
                }
                .alert("Close a page with edited fields?", isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } })) {
                    Button("Keep Tab", role: .cancel) { closing = nil }
                    Button("Close Tab", role: .destructive) { if let id = closing { controller.session.closeTab(id) }; closing = nil }
                } message: { Text("Oriv cannot determine whether the website saved your edits. Closing this tab may lose them.") }
        }
    }
    @ViewBuilder private var profilePicker: some View {
        let available = profiles.profiles.filter { $0.archivedAt == nil }
        if available.count == 2 && controller.profileID != nil && !typeSize.isAccessibilitySize {
            Picker("Profile", selection: Binding(get: { controller.profileID ?? BrowserProfile.personalID }, set: { id in
                if let profile = available.first(where: { $0.id == id }) { switchProfile(profile) }
            })) {
                ForEach(available) { profile in Text(profile.name).tag(profile.id) }
            }.pickerStyle(.segmented).frame(width: 194, height: 44).accessibilityLabel("Profile")
        } else {
            Menu {
                ForEach(available) { profile in
                    Button(profile.name, systemImage: profile.symbol.rawValue) { switchProfile(profile) }
                }
                if profiles.externalPrivate != nil { Button("External Private Tabs", systemImage: "eyeglasses") { dismiss(); profiles.showExternalPrivate() } }
            } label: {
                Text(available.first { $0.id == controller.profileID }?.name ?? "Private")
                    .font(.body).dynamicTypeSize(...DynamicTypeSize.xxxLarge).lineLimit(1).frame(minHeight: 44).padding(.horizontal, 8)
            }.accessibilityLabel("Switch Profile").browserGlass()
        }
    }
    private func switchProfile(_ profile: BrowserProfile) {
        guard controller.profileID != profile.id else { return }
        // Dismiss before changing the profile that owns this presentation.
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            profiles.select(profile)
            profiles.current.sheet = .tabs
        }
    }
    private func tabSection(_ title: String?, privateMode: Bool) -> some View {
        Section {
            ForEach(matches.filter { $0.isPrivate == privateMode }) { tab in
                VStack(spacing: 8) {
                    Button { controller.session.selectTab(tab.id); dismiss() } label: {
                        MobileTabThumbnail(tab: tab)
                            .frame(height: typeSize.isAccessibilitySize ? 220 : 240)
                            .clipShape(.rect(cornerRadius: 18))
                            .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(controller.session.selectedTabID == tab.id ? theme.accent : theme.separator, lineWidth: controller.session.selectedTabID == tab.id ? 2 : 1) }
                    }.buttonStyle(.plain).accessibilityLabel("Open \(tab.displayTitle)")
                        .accessibilityAddTraits(controller.session.selectedTabID == tab.id ? [.isSelected] : [])
                        .overlay(alignment: .topTrailing) {
                            Button { close(tab) } label: { Image(systemName: "xmark").font(.footnote.weight(.semibold)).frame(width: 44, height: 44) }
                                .buttonStyle(.plain).foregroundStyle(theme.text).browserGlass().padding(6).accessibilityLabel("Close \(tab.displayTitle)")
                        }
                    Label(tab.displayTitle, systemImage: tab.isPrivate ? "eyeglasses" : "globe")
                        .font(.footnote.weight(.medium)).foregroundStyle(tab.isPrivate ? theme.privateAccent : theme.text)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 2).frame(maxWidth: .infinity)
                }
            }
        } header: { if let title { Text(title).font(.headline).foregroundStyle(privateMode ? theme.privateAccent : theme.secondaryText).frame(maxWidth: .infinity, alignment: .leading) } }
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

/// Snapshots only already-loaded tabs; never creates a WebView or starts background loads.
private struct MobileTabThumbnail: View {
    @Environment(\.browserTheme) private var theme
    let tab: BrowserTab
    @State private var image: UIImage?
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                theme.surface
                if let image {
                    Image(uiImage: image).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height, alignment: .top).clipped()
                } else {
                    VStack(spacing: 16) { SiteIdentity(url: tab.url, size: 48, isPrivate: tab.isPrivate); Text(tab.displayTitle).font(.headline).multilineTextAlignment(.center).foregroundStyle(theme.text) }.padding()
                }
            }
        }.accessibilityHidden(true)
            .task(id: tab.documentRevision) {
                guard tab.hasLoaded else { return }
                let configuration = WKSnapshotConfiguration(); configuration.snapshotWidth = 360
                image = try? await tab.webView.takeSnapshot(configuration: configuration)
            }
    }
}
