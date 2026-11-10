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
    @State private var nativeFinding = false
    @State private var consumedFocusRequest = 0
    @State private var gestures = MobileChromeGestureState()
    @GestureState private var capsuleDragging = false
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
    private var tab: BrowserTab? { controller.session.selectedTab }
    private var showsExternalPrivateBar: Bool { controller.session.isExternalPrivate && profiles.externalBannerVisible }
    private var profileName: String { profiles.profiles.first { $0.id == controller.profileID }?.name ?? "External Private Tabs" }

    var body: some View {
        browser.accessibilityHidden(gestures.gridProgress > 0 || controller.sheet == .tabs)
            .overlay {
                if gestures.gridProgress > 0 || controller.sheet == .tabs {
                    GeometryReader { geometry in
                        MobileTabsView(controller: controller, profiles: profiles, dismissGrid: closeGrid, onPull: pullGrid)
                            .browserAppearance(controller.appearance)
                            .offset(y: reduceMotion ? 0 : geometry.size.height * (1 - gestures.gridProgress))
                            .opacity(reduceMotion ? gestures.gridProgress : 1)
                            .allowsHitTesting(controller.sheet == .tabs && !gestures.gridClosing)
                    }.ignoresSafeArea().zIndex(10)
                }
            }
            .preferredColorScheme(gestures.gridProgress > 0 || controller.sheet == .tabs || editingAddress || tab?.url == nil ? controller.appearance.colorScheme : (pageChrome.isDark ? .dark : .light))
    }
    private var browser: some View {
        NavigationStack {
            GeometryReader { geometry in
                ZStack {
                    pageChrome.color.ignoresSafeArea()
                    if editingAddress {
                        suggestions.background(theme.canvas)
                            .safeAreaBar(edge: .bottom) { addressEditor }
                    } else {
                        page(top: geometry.safeAreaInsets.top, bottom: geometry.safeAreaInsets.bottom + (nativeFinding ? 0 : barHeight))
                            .overlay { swipePreview(width: geometry.size.width) }
                            .offset(x: reduceMotion ? 0 : gestures.translation)
                            .opacity(reduceMotion && gestures.translation != 0 ? 0.65 : 1)
                            .ignoresSafeArea(.container, edges: [.top, .bottom])
                            .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
                            .scrollEdgeEffectHidden(reduceTransparency, for: [.top, .bottom])
                            .safeAreaBar(edge: .bottom) {
                                if !nativeFinding { bottomChrome.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 } }
                            }
                            .overlay(alignment: .top) {
                                VStack(spacing: 0) { notices }
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
            .task(id: "\(tab?.id.uuidString ?? "none")-\(tab?.url != nil || tab?.hasLoaded == true)") { pageChrome.observe(tab.flatMap { $0.url != nil || $0.hasLoaded ? $0.webView : nil }, isPrivate: tab?.isPrivate == true) }
            .onDisappear { pageChrome.observe(nil) }
                .onAppear { controller.session.activateSelectedTab() }
                .task(id: controller.addressFocusRequest) {
                    await Task.yield()
                    consumeFocusRequest()
                }
                .onChange(of: controller.session.tabs.count) { _, _ in profiles.finishExternalGroupIfEmpty() }
                .onChange(of: tab?.id) { _, _ in editingAddress = false; minimized = false; nativeFinding = false }
                .onChange(of: capsuleDragging) { _, dragging in
                    if !dragging && gestures.source != nil {
                        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.8)) { gestures.cancel() }
                    }
                }
                .onChange(of: controller.sheet, initial: true) { _, sheet in
                    gestures.gridPresented = sheet == .tabs
                    if sheet == .tabs {
                        if let tab, tab.isInstantiated { tab.webView.findInteraction?.dismissFindNavigator(); tab.webView.endEditing(true) }
                        animateGrid(to: 1)
                    }
                    else if !gestures.gridClosing { gestures.gridProgress = 0; consumeFocusRequest() }
                }
                .sheet(item: Binding(get: { controller.sheet == .tabs ? nil : controller.sheet }, set: { controller.sheet = $0 }), onDismiss: consumeFocusRequest) { sheet in
                    Group {
                    switch sheet {
                    case .tabs: EmptyView()
                    case .library: MobileLibraryView(controller: controller, profiles: profiles)
                    case .bookmarks:
                        NavigationStack {
                            MobileSavedPages(controller: controller, history: false)
                                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { controller.sheet = nil } } }
                        }
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
            if minimized && !typeSize.isAccessibilitySize {
                ZStack {
                    HStack(spacing: 5) {
                        if tab?.isPrivate == true { Image(systemName: "eyeglasses").foregroundStyle(theme.privateAccent) }
                        if let tab, ConnectionCue(tab) == .notSecure { Image(systemName: "exclamationmark.triangle") }
                        Text(displayDomain).lineLimit(1)
                    }.font(.caption.weight(.medium)).foregroundStyle(bottomForeground)
                        .padding(.horizontal, 16).frame(minHeight: 32).modifier(MobileBottomGlass(isPrivate: tab?.isPrivate == true))
                        .allowsHitTesting(false).accessibilityHidden(true)
                    MobileAddressMenuSource(controller: controller, profiles: profiles, tab: tab, compact: true) { setMinimized(false) }
                }.frame(height: 44).fixedSize(horizontal: true, vertical: false)
                    .simultaneousGesture(capsuleGesture)
                    .modifier(MobileCapsuleAccessibility(controller: controller))
            } else {
                GlassEffectContainer(spacing: 8) {
                    if typeSize.isAccessibilitySize {
                        VStack(spacing: 8) {
                            addressCapsule
                            HStack { backButton; if tab?.canGoForward == true { forwardButton }; Spacer(); tabsButton }
                        }
                    } else {
                        HStack(spacing: 8) {
                            backButton
                            if tab?.canGoForward == true { forwardButton }
                            addressCapsule
                            tabsButton
                        }
                    }
                }.padding(.horizontal, typeSize.isAccessibilitySize || tab?.canGoForward == true ? 12 : 24)
            }
        }.padding(.top, 8).foregroundStyle(bottomForeground)
            .environment(\.colorScheme, tab?.isPrivate == true ? .dark : pageSystemScheme)
    }

    private var backButton: some View {
        Menu { MobileHistoryMenu(tab: tab, forward: false) } label: {
            Image(systemName: "chevron.left").font(.system(size: 21, weight: .medium)).frame(width: 48, height: 48)
        } primaryAction: { tab?.goBack() }
            .menuOrder(.fixed).tint(.primary)
            .disabled(tab?.canGoBack != true).buttonStyle(.plain).modifier(MobileBottomGlass(isPrivate: tab?.isPrivate == true)).accessibilityLabel("Back")
            .accessibilityAction(named: "Show History") { showHistory(forward: false) }
    }

    private var forwardButton: some View {
        Menu { MobileHistoryMenu(tab: tab, forward: true) } label: {
            Image(systemName: "chevron.right").font(.system(size: 21, weight: .medium)).frame(width: 44, height: 48)
        } primaryAction: { tab?.goForward() }
            .menuOrder(.fixed).tint(.primary)
            .buttonStyle(.plain).modifier(MobileBottomGlass(isPrivate: tab?.isPrivate == true)).accessibilityLabel("Forward")
            .accessibilityAction(named: "Show History") { showHistory(forward: true) }
    }
    private var tabsButton: some View {
        Menu {
            Button("New Tab", systemImage: "plus") { controller.newTab() }
            Button("New Private Tab", systemImage: "eyeglasses") { controller.newTab(isPrivate: true) }
            Divider()
            Menu("Switch Profile", systemImage: "person.crop.circle") {
                ForEach(profiles.profiles.filter { $0.archivedAt == nil }) { profile in Button(profile.name) { profiles.select(profile) } }
            }
            Divider()
            Button("Close This Tab", systemImage: "xmark", role: .destructive) { if let tab { controller.close([tab.id]) } }
            Button("Close All Tabs", systemImage: "xmark.square", role: .destructive) { controller.closeAllTabs() }
        } label: {
            Image(systemName: "square.on.square").font(.system(size: 21, weight: .medium)).frame(width: 48, height: 48)
        } primaryAction: { controller.sheet = .tabs }
            .menuOrder(.fixed).tint(.primary)
            .buttonStyle(.plain).modifier(MobileBottomGlass(isPrivate: tab?.isPrivate == true))
            .accessibilityLabel("Show All Tabs").accessibilityValue("\(controller.session.tabsInSelectedMode.count) tabs")
            .accessibilityIdentifier("browserTabs")
    }
    private func showHistory(forward: Bool) {
        guard let tab else { return }
        let items = forward ? tab.webView.backForwardList.forwardList : Array(tab.webView.backForwardList.backList.reversed())
        let alert = UIAlertController(title: forward ? "Forward History" : "Back History", message: nil, preferredStyle: .actionSheet)
        for item in items { alert.addAction(UIAlertAction(title: item.title ?? item.url.absoluteString, style: .default) { _ in tab.go(to: item) }) }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let presenter = MobileWebDelegate.presenter {
            alert.popoverPresentationController?.sourceView = presenter.view
            alert.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.maxY - 80, width: 1, height: 1)
            presenter.present(alert, animated: !reduceMotion)
        }
    }
    private func animateGrid(to value: CGFloat) {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.18) : .spring(response: 0.32, dampingFraction: 0.88)) { gestures.gridProgress = value }
    }
    private func closeGrid() {
        guard !gestures.gridClosing else { return }
        gestures.gridClosing = true; animateGrid(to: 0)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            if controller.sheet == .tabs { controller.sheet = nil }
            gestures.gridClosing = false; consumeFocusRequest()
        }
    }
    private func pullGrid(_ progress: CGFloat, _ ended: Bool) {
        if ended { if progress > 0.25 { closeGrid() } else { animateGrid(to: 1) } }
        else { gestures.gridProgress = 1 - min(max(progress, 0), 1) }
    }
    private var capsuleGesture: some Gesture {
        DragGesture(minimumDistance: 14, coordinateSpace: .global)
            .updating($capsuleDragging) { _, dragging, _ in dragging = true }
            .onChanged { value in
                guard !editingAddress, controller.sheet == nil else { return }
                _ = gestures.capsule(gestures.source == nil ? .began : .changed, translation: value.translation, session: controller.session)
            }.onEnded { value in
                withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.8)) {
                    if gestures.capsule(.ended, translation: value.translation, predicted: value.predictedEndTranslation, session: controller.session) {
                        controller.sheet = .tabs
                    }
                }
            }
    }
    @ViewBuilder private func swipePreview(width: CGFloat) -> some View {
        if gestures.translation != 0 {
            let direction = gestures.translation < 0 ? 1 : -1
            let target = controller.session.tabSwipeTarget(direction)
            Group {
                if case .tab(let id) = target, let next = controller.session.tabs.first(where: { $0.id == id }) {
                    MobileTabThumbnail(tab: next)
                } else if target == .newTab {
                    ZStack { theme.canvas; Label(tab?.isPrivate == true ? "New Private Tab" : "New Tab", systemImage: "plus").foregroundStyle(theme.text) }
                }
            }.offset(x: reduceMotion ? 0 : (direction > 0 ? width : -width))
                .opacity(reduceMotion ? min(abs(gestures.translation) / 160, 1) : 1)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    private var statusBackdrop: some View {
        pageChrome.color.opacity(extendsTopColor ? 1 : 0)
    }

    private var addressCapsule: some View {
            HStack(spacing: 0) {
                pageMenu.frame(width: 44, height: 48)
                ZStack {
                    HStack(spacing: 4) {
                        if let tab, ConnectionCue(tab) == .notSecure {
                            Image(systemName: "exclamationmark.triangle").font(.system(size: 12))
                        }
                        Text(displayDomain).lineLimit(1).truncationMode(.middle)
                    }.font(.body).foregroundStyle(bottomForeground).allowsHitTesting(false).accessibilityHidden(true)
                    MobileAddressMenuSource(controller: controller, profiles: profiles, tab: tab) { beginAddressEditing() }
                }.frame(maxWidth: .infinity).frame(height: 48)
                Button(tab?.isLoading == true ? "Stop" : "Reload", systemImage: tab?.isLoading == true ? "xmark" : "arrow.clockwise") {
                    tab?.isLoading == true ? tab?.stop() : tab?.reload()
                }.labelStyle(.iconOnly).font(.system(size: 20)).frame(width: 44, height: 48).disabled(tab?.url == nil)
            }
            .padding(.vertical, typeSize.isAccessibilitySize ? 8 : 0).buttonStyle(.plain).modifier(MobileBottomGlass(isPrivate: tab?.isPrivate == true))
            .simultaneousGesture(capsuleGesture)
            .modifier(MobileCapsuleAccessibility(controller: controller))
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
    @ViewBuilder private func page(top: CGFloat, bottom: CGFloat) -> some View {
        if let tab, tab.url != nil {
            if let error = tab.errorMessage {
                ContentUnavailableView { Label("Page could not load", systemImage: "network.slash") } description: { Text(error) } actions: { Button("Try Again") { tab.reload() } }
                    .background(theme.canvas).environment(\.colorScheme, controller.appearance.colorScheme ?? .dark)
            } else { MobileWebView(webView: tab.webView, chrome: pageChrome, topInset: top, bottomInset: bottom, reduceTransparency: solidChrome, obscured: gestures.gridProgress > 0 || controller.sheet == .tabs, onFindVisibilityChange: { visible in
                if controller.session.selectedTabID == tab.id { nativeFinding = visible }
            }, onAppearanceChange: { pageSystemScheme = $0 ? .dark : .light }, onScroll: { offset, down in
                if offset < 40 { setMinimized(false) }
                else if offset > 120 && down && !showsExternalPrivateBar { setMinimized(true) }
                else if !down { setMinimized(false) }
            }).id(tab.id) }
        } else { home.safeAreaPadding(.top, top).safeAreaPadding(.bottom, bottom) }
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
                Menu("Back History", systemImage: "clock.arrow.circlepath") { MobileHistoryMenu(tab: tab, forward: false) }.disabled(tab?.canGoBack != true)
                if tab?.canGoForward == true { Menu("Forward History") { MobileHistoryMenu(tab: tab, forward: true) } }
                Button("Tabs (\(controller.session.tabs.count))", systemImage: "square.on.square") { controller.sheet = .tabs }
                Button("Bookmarks", systemImage: "bookmark") { controller.sheet = .bookmarks }
                Button(controller.downloads.hasActivity ? "Library, Downloads Available" : "Library", systemImage: "book") { controller.sheet = .library }
                Button("Site Settings", systemImage: "slider.horizontal.3") { controller.sheet = .site }.disabled(tab?.url == nil)
                Button(controller.session.isBookmarked(tab?.url) ? "Remove Bookmark" : "Add Bookmark", systemImage: controller.session.isBookmarked(tab?.url) ? "bookmark.fill" : "bookmark") { controller.session.toggleBookmark() }.disabled(tab?.url == nil || tab?.isPrivate == true)
                if let tab { MobileMoveTabMenu(controller: controller, profiles: profiles, tab: tab); MobileSendTabMenu(controller: controller, profiles: profiles, tab: tab) }
                Button("Share", systemImage: "square.and.arrow.up") { controller.sheet = .share }.disabled(tab?.url == nil)
                Button("Find on Page", systemImage: "magnifyingglass") { tab?.showFind() }.disabled(tab?.url == nil)
                Button("Images on This Page", systemImage: "photo") { controller.showPageImages() }.disabled(tab?.url == nil)
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
            } label: { Label("Page Menu", systemImage: tab?.isPrivate == true ? "eyeglasses" : "slider.horizontal.3").labelStyle(.iconOnly).font(.system(size: 20)).frame(width: 44, height: 48).contentShape(Rectangle()) }.accessibilityIdentifier("browserPageMenu").menuOrder(.fixed).tint(.primary)
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

private struct MobileCapsuleAccessibility: ViewModifier {
    let controller: MobileController
    func body(content: Content) -> some View {
        content.accessibilityAction(named: "Next Tab") { step(1) }
            .accessibilityAction(named: "Previous Tab") { step(-1) }
            .accessibilityAction(named: "Show All Tabs") { controller.sheet = .tabs }
            .accessibilityAction(named: "Close Tab") { if let id = controller.session.selectedTabID { controller.close([id]) } }
    }
    private func step(_ direction: Int) {
        // Next/Previous never create tabs; New Tab remains a separately named command.
        if case .tab(let id) = controller.session.tabSwipeTarget(direction) { controller.session.selectTab(id) }
    }
}
