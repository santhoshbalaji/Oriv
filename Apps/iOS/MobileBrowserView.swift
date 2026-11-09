import SwiftUI
import BrowserCore
import BrowserEngine
import WebKit

struct MobileBrowserView: View {
    @Environment(\.browserTheme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Bindable var controller: MobileController
    let profiles: MobileProfiles
    @State private var address = ""
    @State private var editingAddress = false
    @State private var consumedFocusRequest = 0
    @State private var finding = false
    @State private var findText = ""
    @FocusState private var findFocused: Bool
    private var tab: BrowserTab? { controller.session.selectedTab }
    private var showsExternalPrivateBar: Bool { controller.session.isExternalPrivate && profiles.externalBannerVisible }
    private var profileName: String { profiles.profiles.first { $0.id == controller.profileID }?.name ?? "External Private Tabs" }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                addressBar
                if showsExternalPrivateBar {
                    ExternalPrivateBar(sourceName: nil, profiles: profiles.profiles.filter { $0.archivedAt == nil },
                        selection: Binding(get: { profiles.externalMoveProfileID }, set: { profiles.externalMoveProfileID = $0 }),
                        canMove: ExternalLinkRouting.movableURL(tab?.url) != nil,
                        move: { profiles.moveExternalTab() }, dismiss: { profiles.externalBannerVisible = false })
                }
                if let tab, tab.isLoading { ProgressView(value: tab.progress).tint(theme.accent).accessibilityLabel("Loading page") }
                // Shown while editing too, so a new private tab never looks like a regular one.
                if tab?.isPrivate == true && !showsExternalPrivateBar && (tab?.url != nil || editingAddress) {
                    Label("Private", systemImage: "eyeglasses").font(.footnote.weight(.medium)).foregroundStyle(theme.privateAccent)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.bottom, OrivSpacing.xs)
                        .accessibilityElement(children: .combine)
                }
                if !editingAddress {
                    notices
                    if finding { findBar }
                    page
                    browserToolbar
                } else { suggestions }
            }.background(theme.canvas).toolbar(.hidden, for: .navigationBar)
                .onAppear { controller.session.activateSelectedTab() }
                .task(id: controller.addressFocusRequest) {
                    await Task.yield()
                    consumeFocusRequest()
                }
                .onChange(of: controller.session.tabs.count) { _, _ in profiles.finishExternalGroupIfEmpty() }
                .onChange(of: tab?.id) { _, _ in finding = false; findText = ""; editingAddress = false }
                .sheet(item: $controller.sheet, onDismiss: consumeFocusRequest) { sheet in
                    Group {
                    switch sheet {
                    case .tabs: MobileTabsView(controller: controller, profileName: profileName, profiles: profiles.profiles.filter { $0.archivedAt == nil }.count)
                    case .library: MobileLibraryView(controller: controller, profiles: profiles)
                    case .settings: NavigationStack { MobileSettingsView(controller: controller, profiles: profiles) }
                    case .site: if let tab { NavigationStack { MobileSiteSettings(session: controller.session, tab: tab) } }
                    case .share: if let tab, let url = tab.url { MobilePageShare(webView: tab.webView, url: url) }
                    }
                    }.browserAppearance(controller.appearance)
                }
                .alert("Unable to complete action", isPresented: Binding(get: { controller.message != nil }, set: { if !$0 { controller.message = nil } })) {
                    Button("OK") { controller.message = nil }
                } message: { Text(controller.message ?? "") }
        }
    }

    private func consumeFocusRequest() {
        guard controller.sheet == nil, controller.addressFocusRequest > consumedFocusRequest else { return }
        consumedFocusRequest = controller.addressFocusRequest
        if tab?.url == nil { beginAddressEditing() }
    }

    private var addressBar: some View {
        VStack(spacing: OrivSpacing.small) {
            if editingAddress {
                CappedAddressEditor(text: $address, editing: $editingAddress, submit: submitAddress)
                    .padding(.horizontal, OrivSpacing.medium).background(theme.field, in: .rect(cornerRadius: OrivRadius.large))
                HStack {
                    Spacer(); Button("Cancel") { editingAddress = false; address = tab?.url?.absoluteString ?? "" }
                }
            } else {
                HStack(spacing: OrivSpacing.xs) {
                    if let tab, tab.url != nil {
                        let cue = ConnectionCue(tab)
                        Button { controller.sheet = .site } label: {
                            HStack(spacing: OrivSpacing.xs) {
                                Image(systemName: cue.symbol)
                                if cue == .notSecure { Text(cue.label).font(.subheadline.weight(.medium)).lineLimit(1).layoutPriority(1) }
                            }.font(.subheadline).foregroundStyle(cue.color(theme))
                                .frame(minWidth: 44, minHeight: 44).padding(.leading, cue == .notSecure ? 10 : 0).contentShape(Rectangle())
                        }.accessibilityLabel("\(cue.label). Site settings").accessibilityShowsLargeContentViewer()
                    } else {
                        Image(systemName: tab?.isPrivate == true ? "eyeglasses" : "magnifyingglass").font(.subheadline)
                            .foregroundStyle(tab?.isPrivate == true ? theme.privateAccent : theme.secondaryText).frame(width: 44, height: 44).accessibilityHidden(true)
                    }
                    Button(action: beginAddressEditing) {
                        Text(tab?.url?.host() ?? (tab?.isPrivate == true ? "Private search or address" : "Search or enter address"))
                            .font(.body).foregroundStyle(tab?.url == nil ? theme.secondaryText : theme.text).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("browserAddressDisplay").accessibilityShowsLargeContentViewer()
                        .accessibilityLabel("Address and search, \(tab?.url?.absoluteString ?? (tab?.isPrivate == true ? "private tab" : "new tab"))")
                    if tab?.url != nil {
                        Button(tab?.isLoading == true ? "Stop" : "Reload", systemImage: tab?.isLoading == true ? "xmark" : "arrow.clockwise") {
                            tab?.isLoading == true ? tab?.stop() : tab?.reload()
                        }.labelStyle(.iconOnly).font(.subheadline).foregroundStyle(theme.secondaryText).frame(width: 44, height: 44)
                    }
                }.padding(.horizontal, 2).background(theme.field, in: .rect(cornerRadius: OrivRadius.large))
            }
        }.padding(.horizontal, OrivSpacing.medium).padding(.vertical, OrivSpacing.small)
            // Like Safari, the address bar stops growing at the largest standard size; long-press shows the large content viewer.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
    @ViewBuilder private var notices: some View {
        if let notice = profiles.continuity.notice { ContinuityNotice(text: notice) }
        if let notice = controller.session.persistenceNotice {
            HStack { Text(notice).font(.footnote); Spacer(); if controller.session.canPersist { Button("Dismiss") { controller.session.dismissNotice() } } }
                .padding(.horizontal, OrivSpacing.large).padding(.vertical, 10).background(theme.surface)
        }
        if controller.session.canUndoBookmarkRemoval {
            HStack { Text("Bookmark removed").foregroundStyle(theme.secondaryText); Spacer(); Button("Undo") { controller.session.undoBookmarkRemoval() }; Button("Dismiss", systemImage: "xmark") { controller.session.dismissBookmarkUndo() }.labelStyle(.iconOnly).foregroundStyle(theme.secondaryText) }
                .font(.footnote).padding(.horizontal, OrivSpacing.large).frame(minHeight: 44).background(theme.surface)
        }
    }
    private var findBar: some View {
        VStack(alignment: .leading) {
            TextField("Find in page", text: $findText).focused($findFocused).submitLabel(.search).onSubmit { tab?.find(findText) }
            HStack {
                if tab?.findResult == false { Text("No match").font(.caption) }
                Spacer()
                Button("Previous", systemImage: "chevron.up") { tab?.find(findText, backwards: true) }.labelStyle(.iconOnly).disabled(findText.isEmpty)
                Button("Next", systemImage: "chevron.down") { tab?.find(findText) }.labelStyle(.iconOnly).disabled(findText.isEmpty)
                Button("Done") { finding = false; tab?.clearFind() }
            }
        }.padding(OrivSpacing.medium).background(theme.surface)
    }
    @ViewBuilder private var page: some View {
        if let tab, tab.url != nil {
            if let error = tab.errorMessage {
                ContentUnavailableView { Label("Page could not load", systemImage: "network.slash") } description: { Text(error) } actions: { Button("Try Again") { tab.reload() } }
            } else { MobileWebView(webView: tab.webView).id(tab.id) }
        } else { home }
    }
    private var otherProfiles: Bool { profiles.profiles.filter { $0.archivedAt == nil }.count > 1 }
    private var homeBookmarks: [Bookmark] { Array(controller.session.bookmarks.prefix(6)) }
    private var homeRecent: [HistoryEntry] {
        let shown = Set(homeBookmarks.map(\.url))
        return Array(controller.session.history.filter { !shown.contains($0.url) }.prefix(5))
    }
    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if otherProfiles {
                    Label(profileName, systemImage: "person.crop.circle").font(.footnote).foregroundStyle(theme.secondaryText)
                }
                if tab?.isPrivate == true {
                    VStack(alignment: .leading, spacing: OrivSpacing.small) {
                        Label("Private browsing", systemImage: "eyeglasses").font(.headline).foregroundStyle(theme.privateAccent)
                        Text("Private tabs aren’t saved or added to history. Their cookies and website data are erased when the last private tab closes. Websites and your network can still see your activity.").font(.callout).foregroundStyle(theme.secondaryText)
                    }.padding(.top, 40)
                } else if homeBookmarks.isEmpty && homeRecent.isEmpty {
                    BrowserEmptyState("Bookmarks and recent pages appear here.").padding(.top, 56)
                } else {
                    let context = URLDisplay.Context(homeBookmarks.map { ($0.title, $0.url) } + homeRecent.map { ($0.title, $0.url) })
                    if !homeBookmarks.isEmpty { homeSection("Bookmarks", items: homeBookmarks.map { ($0.title, $0.url) }, context: context) }
                    if !homeRecent.isEmpty { homeSection("Recent", items: homeRecent.map { ($0.title, $0.url) }, context: context) }
                }
            }.padding(.horizontal, 20).padding(.vertical, OrivSpacing.xl).frame(maxWidth: 650, alignment: .leading).frame(maxWidth: .infinity)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func homeSection(_ title: String, items: [(String, URL)], context: URLDisplay.Context) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.footnote.weight(.medium)).foregroundStyle(theme.secondaryText).accessibilityAddTraits(.isHeader).padding(.bottom, 6)
            ForEach(items, id: \.1) { item in homeLink(item.0, url: item.1, context: context) }
        }
    }
    private func homeLink(_ title: String, url: URL, context: URLDisplay.Context) -> some View {
        Button { controller.open(url) } label: {
            PageRowContent(title: title, url: url, context: context)
                .frame(minHeight: 48).contentShape(Rectangle())
        }.buttonStyle(.plain).contextMenu { Button("Open in New Tab") { controller.session.openSavedPage(url, inNewTab: true) } }
    }
    private var suggestions: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(action: submitAddress) {
                        Label(AddressAction.title(for: address, engine: controller.session.settings.searchEngine, compact: typeSize.isAccessibilitySize), systemImage: AddressAction.symbol(for: address, engine: controller.session.settings.searchEngine))
                            .foregroundStyle(theme.text).lineLimit(typeSize.isAccessibilitySize ? 3 : 1).padding(.horizontal, OrivSpacing.small).frame(minHeight: 52, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                let matches = controller.session.suggestions(for: address, isPrivate: tab?.isPrivate == true)
                let context = URLDisplay.Context(matches.map { ($0.title, $0.url) })
                ForEach(matches) { match in
                    Button {
                        editingAddress = false
                        if let id = match.tabID { controller.session.selectTab(id) } else { controller.perform { try controller.session.navigate(match.url.absoluteString) } }
                    } label: {
                        PageRowContent(title: match.title, url: match.url, context: context,
                                       isPrivate: tab?.isPrivate == true,
                                       accessory: match.tabID != nil ? .alreadyOpen : .none)
                            .padding(.horizontal, OrivSpacing.small).frame(minHeight: 52).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal, OrivSpacing.medium).padding(.top, OrivSpacing.xs)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).scrollDismissesKeyboard(.interactively)
    }
    private var browserToolbar: some View {
        HStack(spacing: 0) {
            Button("Back", systemImage: "chevron.left") { tab?.goBack() }.disabled(tab?.canGoBack != true)
                .frame(maxWidth: .infinity, minHeight: 48)
            Button("Forward", systemImage: "chevron.right") { tab?.goForward() }.disabled(tab?.canGoForward != true)
                .frame(maxWidth: .infinity, minHeight: 48)
            Button { controller.sheet = .library } label: {
                Image(systemName: controller.downloads.hasActivity ? "arrow.down.circle" : "book")
                    .foregroundStyle(controller.downloads.hasActivity ? theme.accentText : theme.text)
            }.accessibilityLabel(controller.downloads.hasActivity ? "Library, downloads available" : "Library").frame(maxWidth: .infinity, minHeight: 48)
            Button { controller.sheet = .tabs } label: {
                Text("\(controller.session.tabs.count)").font(.footnote.weight(.semibold)).monospacedDigit()
                    .frame(minWidth: 22, minHeight: 22).overlay { RoundedRectangle(cornerRadius: OrivRadius.compact).strokeBorder(lineWidth: 1.5) }
            }.accessibilityLabel("Tabs, \(controller.session.tabs.count) open, \(controller.profileID == nil ? "External Private Tabs" : "profile " + profileName)").accessibilityIdentifier("browserTabs").frame(maxWidth: .infinity, minHeight: 48)
            Menu {
                Button(controller.session.isBookmarked(tab?.url) ? "Remove Bookmark" : "Add Bookmark", systemImage: controller.session.isBookmarked(tab?.url) ? "bookmark.fill" : "bookmark") { controller.session.toggleBookmark() }.disabled(tab?.url == nil || tab?.isPrivate == true)
                SendPageMenu(continuity: profiles.continuity, session: controller.session, profile: profiles.profiles.first { $0.id == controller.profileID })
                Button("Share", systemImage: "square.and.arrow.up") { controller.sheet = .share }.disabled(tab?.url == nil)
                Button("Find on Page", systemImage: "magnifyingglass") { finding = true; findFocused = true }.disabled(tab?.url == nil)
                if let tab, tab.url != nil {
                    ControlGroup {
                        Button("Zoom Out", systemImage: "minus.magnifyingglass") { tab.zoomOut() }
                        Button("Zoom In", systemImage: "plus.magnifyingglass") { tab.zoomIn() }
                    }
                    // Native menus use the actual title for VoiceOver, ignoring a custom label
                    // on a ControlGroup segment. Give reset its own full-width menu item.
                    Button("Reset Page Zoom (\(Int(tab.pageZoom * 100))%)") { tab.resetZoom() }
                }
                Section {
                    Button("New Tab", systemImage: "plus") { controller.newTab() }
                    Button("New Private Tab", systemImage: "eyeglasses") { controller.newTab(isPrivate: true) }
                    if controller.session.canReopenTab { Button("Reopen Closed Tab", systemImage: "arrow.uturn.backward") { controller.session.reopenClosedTab() } }
                }
                if controller.session.isExternalPrivate {
                    Button("Return to Profile", systemImage: "person.crop.circle") {
                        if let profile = profiles.profiles.first(where: { $0.id == profiles.lastRegularProfileID }) { profiles.select(profile) }
                    }
                } else if profiles.externalPrivate != nil {
                    Button("External Private Tabs", systemImage: "eyeglasses") { profiles.showExternalPrivate() }
                }
                Section { Button("Settings", systemImage: "gearshape") { controller.sheet = .settings } }
            } label: { Label("Page options and settings", systemImage: "ellipsis").frame(maxWidth: .infinity, minHeight: 48) }
        // Toolbar glyphs keep their compact geometry; the count above uses scalable footnote text.
        }.labelStyle(.iconOnly).font(.system(size: 18)).tint(theme.text).padding(.horizontal, OrivSpacing.small).background(theme.chrome)
    }
    private func beginAddressEditing() { address = tab?.url?.absoluteString ?? ""; editingAddress = true }
    private func submitAddress() {
        do { try controller.session.navigate(address); editingAddress = false }
        catch { controller.message = error.localizedDescription }
    }
}

private struct MobilePageShare: UIViewControllerRepresentable {
    let webView: WKWebView
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url, webView], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
private struct MobileWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// Read the capped environment inside the address bar, rather than scaling at the screen root.
private struct CappedAddressEditor: View {
    @Binding var text: String
    @Binding var editing: Bool
    let submit: () -> Void
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 44
    var body: some View {
        MobileAddressField(text: $text, editing: $editing, submit: submit)
            .frame(height: height)
    }
}
