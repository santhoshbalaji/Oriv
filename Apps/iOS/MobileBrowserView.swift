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
    @State private var pageChrome = PageChrome()
    @State private var minimized = false
    @State private var barHeight: CGFloat = 64
    @State private var pageSystemScheme: ColorScheme = .light
    private var solidChrome: Bool { reduceTransparency || contrast == .increased }
    private var extendsTopColor: Bool { solidChrome || !pageChrome.showsContentUnderChrome }
    private var displayDomain: String { tab?.url.flatMap(URLDisplay.site) ?? (tab?.isPrivate == true ? "Private search" : "Search or address") }
    private var bottomForeground: Color { tab?.isPrivate == true ? theme.text : .primary }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @FocusState private var findFocused: Bool
    private var tab: BrowserTab? { controller.session.selectedTab }
    private var showsExternalPrivateBar: Bool { controller.session.isExternalPrivate && profiles.externalBannerVisible }
    private var profileName: String { profiles.profiles.first { $0.id == controller.profileID }?.name ?? "External Private Tabs" }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ZStack {
                    pageChrome.color.ignoresSafeArea()
                    if editingAddress {
                        suggestions.background(theme.canvas)
                            .safeAreaBar(edge: .bottom) { addressEditor }
                    } else {
                        page(top: geometry.safeAreaInsets.top, bottom: geometry.safeAreaInsets.bottom + barHeight)
                            .ignoresSafeArea(.container, edges: [.top, .bottom])
                            .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
                            .scrollEdgeEffectHidden(reduceTransparency, for: [.top, .bottom])
                            .safeAreaBar(edge: .bottom) {
                                bottomChrome.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
                            }
                            .overlay(alignment: .top) {
                                VStack(spacing: 0) { notices; if finding { findBar } }
                            }
                    }
                }
                .overlay(alignment: .top) {
                    if !editingAddress {
                        statusBackdrop.frame(height: geometry.safeAreaInsets.top)
                            .offset(y: -geometry.safeAreaInsets.top)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .preferredColorScheme(editingAddress || tab?.url == nil ? controller.appearance.colorScheme : (pageChrome.isDark ? .dark : .light))
            .task(id: "\(tab?.id.uuidString ?? "none")-\(tab?.url != nil || tab?.hasLoaded == true)") { pageChrome.observe(tab.flatMap { $0.url != nil || $0.hasLoaded ? $0.webView : nil }, isPrivate: tab?.isPrivate == true) }
            .onDisappear { pageChrome.observe(nil) }
                .onAppear { controller.session.activateSelectedTab() }
                .task(id: controller.addressFocusRequest) {
                    await Task.yield()
                    consumeFocusRequest()
                }
                .onChange(of: controller.session.tabs.count) { _, _ in profiles.finishExternalGroupIfEmpty() }
                .onChange(of: tab?.id) { _, _ in finding = false; findText = ""; editingAddress = false; minimized = false }
                .fullScreenCover(isPresented: Binding(get: { controller.sheet == .tabs }, set: { if !$0 { controller.sheet = nil } }), onDismiss: consumeFocusRequest) {
                    MobileTabsView(controller: controller, profiles: profiles).browserAppearance(controller.appearance)
                }
                .sheet(item: Binding(get: { controller.sheet == .tabs ? nil : controller.sheet }, set: { controller.sheet = $0 }), onDismiss: consumeFocusRequest) { sheet in
                    Group {
                    switch sheet {
                    case .tabs: MobileTabsView(controller: controller, profiles: profiles)
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

    private var bottomChrome: some View {
        VStack(spacing: 8) {
            if showsExternalPrivateBar {
                ExternalPrivateBar(sourceName: nil, profiles: profiles.profiles.filter { $0.archivedAt == nil },
                    selection: Binding(get: { profiles.externalMoveProfileID }, set: { profiles.externalMoveProfileID = $0 }),
                    canMove: ExternalLinkRouting.movableURL(tab?.url) != nil,
                    move: { profiles.moveExternalTab() }, dismiss: { profiles.externalBannerVisible = false })
            }
            if minimized && !typeSize.isAccessibilitySize && !finding {
                Button {
                    setMinimized(false)
                } label: {
                    HStack(spacing: 5) {
                        if tab?.isPrivate == true { Image(systemName: "eyeglasses").foregroundStyle(theme.privateAccent) }
                        if let tab, ConnectionCue(tab) == .notSecure { Text("Not secure").foregroundStyle(tab.isPrivate ? theme.warning : Color.primary) }
                        Text(displayDomain).lineLimit(1)
                    }.font(.caption.weight(.medium)).foregroundStyle(bottomForeground)
                        .padding(.horizontal, 16).frame(minHeight: 32).modifier(MobileBottomGlass(isPrivate: tab?.isPrivate == true))
                        .frame(minHeight: 44).contentShape(Capsule())
                }.buttonStyle(.plain).accessibilityLabel("\(tab?.isPrivate == true ? "Private browsing. " : "")Expand browser controls, \(tab?.hostname ?? "Oriv")")
                    .accessibilityIdentifier("browserCompactAddress")
            } else {
                GlassEffectContainer(spacing: 8) {
                    if typeSize.isAccessibilitySize {
                        VStack(spacing: 8) {
                            addressCapsule
                            HStack { backButton; Spacer(); pageMenu.frame(width: 48, height: 48).modifier(MobileBottomGlass(isPrivate: tab?.isPrivate == true)) }
                        }
                    } else {
                        HStack(spacing: 8) {
                            backButton
                            addressCapsule
                            pageMenu.frame(width: 48, height: 48).modifier(MobileBottomGlass(isPrivate: tab?.isPrivate == true))
                        }
                    }
                }.padding(.horizontal, typeSize.isAccessibilitySize ? 12 : 34)
            }
        }.padding(.top, 8).foregroundStyle(bottomForeground)
            .environment(\.colorScheme, tab?.isPrivate == true ? .dark : pageSystemScheme)
    }

    private var backButton: some View {
        Button { tab?.goBack() } label: {
            Image(systemName: "chevron.left").font(.system(size: 21, weight: .medium)).frame(width: 48, height: 48)
        }.disabled(tab?.canGoBack != true).buttonStyle(.plain).modifier(MobileBottomGlass(isPrivate: tab?.isPrivate == true)).accessibilityLabel("Back")
    }

    private var statusBackdrop: some View {
        pageChrome.color.opacity(extendsTopColor ? 1 : 0)
    }

    private var addressCapsule: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button { controller.sheet = .site } label: {
                    Image(systemName: tab?.isPrivate == true ? "eyeglasses" : (tab.map { ConnectionCue($0) == .notSecure ? "exclamationmark.triangle" : "slider.horizontal.3" } ?? "magnifyingglass"))
                        .font(.system(size: 20))
                        .foregroundStyle(tab?.isPrivate == true ? theme.privateAccent : Color.primary)
                        .frame(width: 44, height: 48)
                }.disabled(tab?.url == nil).accessibilityLabel("\(tab?.isPrivate == true ? "Private browsing. " : "")\(tab.map { ConnectionCue($0).label } ?? "New tab"). Site settings")
                Button(action: beginAddressEditing) {
                    Text(displayDomain)
                        .font(.body).foregroundStyle(bottomForeground).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, minHeight: 48).contentShape(Rectangle())
                }.accessibilityIdentifier("browserAddressDisplay").accessibilityShowsLargeContentViewer()
                    .accessibilityLabel("Address and search, \(tab?.url?.absoluteString ?? (tab?.isPrivate == true ? "private tab" : "new tab"))")
                Button(tab?.isLoading == true ? "Stop" : "Reload", systemImage: tab?.isLoading == true ? "xmark" : "arrow.clockwise") {
                    tab?.isLoading == true ? tab?.stop() : tab?.reload()
                }.labelStyle(.iconOnly).font(.system(size: 20)).frame(width: 44, height: 48).disabled(tab?.url == nil)
            }
            if let tab, ConnectionCue(tab) == .notSecure {
                Text("Not secure").font(.caption.weight(.medium)).foregroundStyle(tab.isPrivate ? theme.warning : Color.primary).padding(.bottom, 6)
            }
        }.padding(.vertical, typeSize.isAccessibilitySize ? 8 : 0).buttonStyle(.plain).modifier(MobileBottomGlass(isPrivate: tab?.isPrivate == true))
    }

    private var addressEditor: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                if tab?.isPrivate == true { Image(systemName: "eyeglasses").font(.system(size: 20)).foregroundStyle(theme.privateAccent).accessibilityLabel("Private") }
                CappedAddressEditor(text: $address, editing: $editingAddress, submit: submitAddress)
            }.padding(.horizontal, 14).padding(.vertical, 4).browserGlass()
            Button {
                editingAddress = false; address = tab?.url?.absoluteString ?? ""
            } label: { Image(systemName: "xmark").font(.system(size: 20)).frame(width: 48, height: 48) }
                .buttonStyle(.plain).browserGlass().accessibilityLabel("Cancel address editing")
        }.foregroundStyle(theme.text).padding(12).background(theme.canvas)
            .environment(\.colorScheme, .dark)
    }

    private func setMinimized(_ value: Bool) {
        guard !typeSize.isAccessibilitySize else { minimized = false; return }
        if reduceMotion { minimized = value }
        else { withAnimation(.easeInOut(duration: 0.2)) { minimized = value } }
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
    @ViewBuilder private func page(top: CGFloat, bottom: CGFloat) -> some View {
        if let tab, tab.url != nil {
            if let error = tab.errorMessage {
                ContentUnavailableView { Label("Page could not load", systemImage: "network.slash") } description: { Text(error) } actions: { Button("Try Again") { tab.reload() } }
                    .background(theme.canvas).environment(\.colorScheme, controller.appearance.colorScheme ?? .dark)
            } else { MobileWebView(webView: tab.webView, chrome: pageChrome, topInset: top, bottomInset: bottom, reduceTransparency: solidChrome, onAppearanceChange: { pageSystemScheme = $0 ? .dark : .light }, onScroll: { offset, down in
                if offset < 40 { setMinimized(false) }
                else if offset > 120 && down && !showsExternalPrivateBar { setMinimized(true) }
                else if !down { setMinimized(false) }
            }).id(tab.id) }
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
    private var pageMenu: some View {
            Menu {
                Button("Forward", systemImage: "chevron.right") { tab?.goForward() }.disabled(tab?.canGoForward != true)
                Button("Tabs (\(controller.session.tabs.count))", systemImage: "square.on.square") { controller.sheet = .tabs }
                Button(controller.downloads.hasActivity ? "Library, downloads available" : "Library", systemImage: "book") { controller.sheet = .library }
                Button("Site Settings", systemImage: "slider.horizontal.3") { controller.sheet = .site }.disabled(tab?.url == nil)
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
            } label: { Label("Page options and settings", systemImage: "ellipsis").labelStyle(.iconOnly).font(.system(size: 22, weight: .semibold)).frame(width: 48, height: 48).contentShape(Circle()) }.accessibilityIdentifier("browserPageMenu")
    }
    private func beginAddressEditing() { minimized = false; address = tab?.url?.absoluteString ?? ""; editingAddress = true }
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

/// Untinted regular glass owns adaptation; never back it with the page's top colour.
private struct MobileBottomGlass: ViewModifier {
    @Environment(\.browserTheme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let isPrivate: Bool
    func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content.background(isPrivate ? theme.field : Color(uiColor: .secondarySystemBackground), in: Capsule())
                .overlay { Capsule().strokeBorder(Color.primary.opacity(contrast == .increased ? 0.8 : 0.35), lineWidth: 1) }
        } else if isPrivate {
            content.browserGlass()
        } else {
            content.glassEffect(.regular.interactive(), in: Capsule())
        }
    }
}
