import BrowserCore
import BrowserEngine
import SwiftUI
import WebKit

struct BrowserWindow: View {
    @Environment(\.browserTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.browserReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.chromeReduceTransparencyOverride) private var captureReduceTransparency
    @Bindable var controller: BrowserController
    var profiles: BrowserProfiles? = nil
    @State private var windowWidth: CGFloat = 1250
    @State private var sidebarClipWidth: CGFloat = MacBrowserLayout.sidebarWidth
    @State private var peekReturnFocus: NSResponder?
    @State private var fullscreen = false
    @State private var windowActive = true
    @State private var windowContext = MacBrowserWindowContext()
    @State private var sidebarTabs = SidebarListHandle()
    @FocusState private var sidebarHeaderToggleFocused: Bool
    @State private var sidebarContainsKeyboardFocus = false
    @State private var address = ""
    @State private var findText = ""
    @State private var showFind = false
    @State private var showProtection = false
    @State private var showPasswords = false
    @State private var showSiteInfo = false
    @State private var findCaseSensitive = false
    @State private var addressFocused = false
    @State private var addressMatches = AddressSuggestions()
    @State private var pageChrome = PageChrome()
    @State private var showTabs = false
    @FocusState private var findFocused: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    private var session: BrowserSession { controller.session }
    private var tab: BrowserTab? { session.selectedTab }
    private var showsExternalPrivateBar: Bool { session.isExternalPrivate && profiles?.externalBannerVisible == true }
    private var compact: Bool { controller.sidebar.rail }
    private var pageRail: Bool { controller.sidebar.reservesRail }
    private var showsToolbarDownloads: Bool { controller.downloads.hasActiveDownloads && (pageRail || windowWidth >= 800) }
    private var addressWidth: CGFloat {
        let actions = windowWidth < 1000 && !pageRail ? 28 : 30 * CGFloat(3 + (tab?.url == nil ? 0 : 1) + (showsToolbarDownloads ? 1 : 0))
        let reserved = (pageRail ? MacBrowserLayout.railWidth : MacBrowserLayout.sidebarWidth) + 24 + 58 + 36 + 20 + actions
        return min(640, max(230, windowWidth - reserved))
    }
    private var compactAddress: String? { tab?.url.flatMap(URLDisplay.site) }
    private var compactAddressWidth: CGFloat? {
        guard !addressFocused, let compactAddress else { return nil }
        let width = (compactAddress as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width
        return min(ceil(width) + 4, max(60, addressWidth - 180))
    }
    private var emptyPageColor: ChromeColor { PageChrome.resolveCanvas(theme.page, scheme: colorScheme) }
    private var toolbarTheme: Theme { pageChrome.isDark ? theme : .classic }
    private var contentUnderChrome: Bool { pageChrome.showsContentUnderChrome && !reduceTransparency && !captureReduceTransparency && contrast != .increased }
    private var chromeForeground: Color { pageChrome.foreground }
    private var chromeGlass: MacAddressGlass { MacAddressGlass(color: pageChrome.color, isDark: pageChrome.isDark) }
    private var privateCue: Color { pageChrome.contrasting(pageChrome.isDark ? Color(red: 0.733, green: 0.522, blue: 0.961) : Color(red: 0.537, green: 0.267, blue: 0.671)) }

    private var sceneContent: some View {
        routedContent
            .background(BrowserKeyRouter(session: session, overviewVisible: showTabs))
            .environment(\.siteIcons, session.siteIcons)
            .focusedSceneValue(\.browserController, controller)
    }

    private var windowLifecycle: some View {
        sceneContent
            .onAppear(perform: prepareWindow)
            .onChange(of: session.tabs.count) { _, count in
                if session.isExternalPrivate && count == 0 { dismissWindow(id: "external-private"); profiles?.endExternalPrivate() }
            }
            .task(id: "\(address)-\(addressFocused)-\(session.selectedTabID?.uuidString ?? "")") {
                await addressMatches.update(addressFocused ? address : "", session: session, isPrivate: tab?.isPrivate == true)
            }
            .onChange(of: session.selectedTabID) { _, _ in addressFocused = false; syncAddress(); showFind = false; showSiteInfo = false; showProtection = false }
            .onChange(of: tab?.url) { _, _ in if !addressFocused { syncAddress() } }
    }

    var body: some View {
        windowLifecycle
            .onChange(of: controller.findRequest) { _, _ in showFind = true; findFocused = true }
            .onChange(of: controller.findNextRequest) { _, _ in
                showFind = true
                if findText.isEmpty { findFocused = true }
                else { tab?.find(findText, backwards: controller.findBackwards, caseSensitive: findCaseSensitive) }
            }
            .onChange(of: controller.passwordsGuideRequest) { _, _ in showPasswords = true }
            .onChange(of: scenePhase) { _, phase in if phase != .active { session.saveNow() } }
            .task(id: selectedPage) { observeSelectedPage() }
            .onChange(of: emptyPageColor, initial: true) { _, color in pageChrome.setEmptyPageColor(color) }
            .onChange(of: colorScheme) { _, _ in pageChrome.requestSample() }
            .onDisappear { pageChrome.observe(nil) }
    }

    private func prepareWindow() {
        session.activateSelectedTab(); syncAddress(); if tab?.url == nil { controller.focusAddress() }
        if !session.isExternalPrivate {
            profiles?.showRegularWindow = { openWindow(id: "browser") }
            profiles?.showExternalWindow = { openWindow(id: "external-private") }
            profiles?.closeExternalWindow = { dismissWindow(id: "external-private") }
            if profiles?.externalPrivate != nil { openWindow(id: "external-private") }
        }
    }

    private var selectedPage: String {
        let id = tab?.id.uuidString ?? "none"
        let hasPage = tab?.url != nil || tab?.hasLoaded == true
        return "\(id)-\(hasPage)"
    }

    private func observeSelectedPage() {
        let selected = tab
        let isPrivate = selected?.isPrivate == true
        if let selected, selected.url != nil || selected.hasLoaded {
            pageChrome.observe(selected.webView, isPrivate: isPrivate)
        } else {
            pageChrome.observe(nil, isPrivate: isPrivate)
        }
    }

    private var shell: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                mainTopBar.zIndex(1)
                    .opacity(controller.sidebar.webpageFullscreen ? 0 : 1)
                    .allowsHitTesting(!controller.sidebar.webpageFullscreen)
                    .accessibilityHidden(controller.sidebar.webpageFullscreen)
                page.environment(\.layoutDirection, layoutDirection)
            }
            .padding(.leading, controller.sidebar.reservation)
            // The page receives one final viewport update, never interpolated widths.
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            sidebarPanel
                .frame(width: sidebarClipWidth, alignment: .leading).contentShape(Rectangle()).clipped()
                .shadow(color: .black.opacity(controller.sidebar.overlay ? 0.12 : 0), radius: 8, x: 4)
                .opacity(controller.sidebar.webpageFullscreen ? 0 : 1)
                .allowsHitTesting(!controller.sidebar.webpageFullscreen)
                .accessibilityHidden(controller.sidebar.webpageFullscreen)
        }
        .environment(\.layoutDirection, .leftToRight)
        .ignoresSafeArea(.container, edges: .top)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
            windowWidth = $0
        }
        .onAppear { sidebarClipWidth = controller.sidebar.width }
        .onChange(of: controller.sidebar.transition) { previous, next in
            withAnimation(reduceMotion ? nil : .easeOut(duration: previous.peeking || next.peeking ? 0.18 : 0.2)) {
                sidebarClipWidth = next.width
            }
        }
        .onChange(of: controller.sidebar.peeking) { _, open in
            if open { peekReturnFocus = windowContext.window?.firstResponder }
            else if sidebarContainsKeyboardFocus {
                if let peekReturnFocus { windowContext.window?.makeFirstResponder(peekReturnFocus) }
                peekReturnFocus = nil
            }
        }
        .onChange(of: controller.sidebarToggleRequest) { _, _ in toggleSidebar() }
        .onChange(of: controller.tabSearchPanel) { _, open in
            if !open { restoreSearchFocus() }
        }
        .onDisappear { controller.sidebar.cancel(); controller.sidebarTooltip.dismiss() }
        .background(SidebarWindowEvents(controller: controller, dismiss: dismissSidebarOverlay))
        .navigationTitle(session.isExternalPrivate ? "Oriv — Private" : profiles.map { "\(AppIdentity.name) — \($0.active.name)" } ?? AppIdentity.name)
        .background(pageChrome.color, ignoresSafeAreaEdges: [])
        .background(BrowserTitlebar(color: pageChrome.color, reduceMotion: reduceMotion || !pageChrome.animatesColor))
        .background(BrowserWindowChrome(windowContext: windowContext, compact: controller.sidebar.reservesRail, initialContentFocus: tab?.url == nil ? nil : tab?.webView,
            externalPresentationRequest: session.isExternalPrivate ? profiles?.externalPresentationRequest : nil,
            stateChanged: { fullscreen = $0; windowActive = $1 },
            contentWidthChanged: { controller.sidebar.resize(availableWidth: $0) }))
        .overlay {
            GeometryReader { geometry in
                if let id = controller.sidebarTooltip.tabID, let rect = sidebarTabs.frame(for: id), !controller.tabSearchPanel {
                    let width = min(320, max(1, geometry.size.width - 16))
                    SidebarTooltipBubble(text: controller.sidebarTooltip.text, width: width,
                                         maximumHeight: min(180, geometry.size.height - 32))
                    .browserGeometryMarker("sidebarTooltipGeometry")
                    .onHover { controller.sidebarTooltip.hold($0) }
                    .offset(x: min(controller.sidebar.width - 10 + 8, geometry.size.width - width - 8),
                            y: min(max(16, geometry.size.height - rect.maxY), max(16, geometry.size.height - 196)))
                    .accessibilityHidden(true)
                }
            }
        }
        .overlay(alignment: .topLeading) {
            if controller.tabSearchPanel {
                SidebarSearchPanel(controller: controller, dismiss: { controller.dismissTabSearch() })
                    .frame(width: min(360, windowWidth - 16), height: min(420, (windowContext.window?.contentView?.bounds.height ?? 600) - 32))
                    .padding(.leading, min(MacBrowserLayout.railWidth + 8, max(8, windowWidth - 376))).padding(.top, 76)
            }
        }
        .overlayPreferenceValue(MacAddressBounds.self) { anchor in
            GeometryReader { geometry in
                if let anchor, addressFocused && !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let rect = geometry[anchor]
                    addressSuggestions.frame(width: rect.width)
                        .offset(x: rect.minX, y: rect.maxY + OrivSpacing.xs)
                }
            }
        }
    }

    private var sidebarPanel: some View {
        VStack(spacing: 0) {
            sidebarHeader
            BrowserSidebar(controller: controller, profiles: profiles, tabList: sidebarTabs,
                           profileTrailingInset: fullscreen ? 38 : 0)
                .environment(\.layoutDirection, layoutDirection)
                .onPreferenceChange(SidebarKeyboardFocusKey.self) {
                    sidebarContainsKeyboardFocus = $0; controller.sidebar.focusInside = $0 || sidebarHeaderToggleFocused
                }

        }
        .frame(width: controller.sidebar.width).frame(maxHeight: .infinity)
        // One surviving toggle preserves focus across rail/fullscreen changes.
        // In fullscreen it shares the profile line instead of reserving a band.
        .overlay(alignment: .topLeading) {
            sidebarToggle
                .padding(.leading, railHeader ? MacBrowserLayout.railInset : controller.sidebar.width - MacBrowserLayout.sidebarInset - 30)
                .padding(.top, railHeader ? (fullscreen ? 0 : MacBrowserLayout.sidebarTitlebarHeight) : (fullscreen ? 8 : 1))
                .opacity(windowActive ? 1 : 0.75)
        }
        .background {
            Color.clear.modifier(MacSidebarGlass())
                .browserGeometryMarker("sidebarSurfaceGeometry")
        }
        .onHover { inside in controller.sidebar.panelInside = inside }
        .onChange(of: sidebarHeaderToggleFocused) { _, focused in controller.sidebar.focusInside = focused || sidebarContainsKeyboardFocus }
        .browserGeometryMarker("browserSidebarGeometry")
    }

    private func restoreSearchFocus() {
        guard let target = controller.tabSearchReturnFocus else { return }
        controller.tabSearchReturnFocus = nil
        let window = windowContext.window
        DispatchQueue.main.async {
            guard !controller.tabSearchPanel else { return }
            window?.makeFirstResponder(target)
        }
    }
    private func dismissSidebarOverlay() {
        controller.sidebarTooltip.dismiss()
        controller.dismissTabSearch(); controller.sidebar.dismissOverlay()
        if let peekReturnFocus { windowContext.window?.makeFirstResponder(peekReturnFocus) }
        peekReturnFocus = nil
        restoreSearchFocus()
    }

    private var railHeader: Bool { compact || controller.sidebar.peeking }
    private var sidebarHeader: some View {
        Color.clear
            .frame(height: railHeader ? (fullscreen ? 36 : MacBrowserLayout.sidebarTitlebarHeight + 36) : (fullscreen ? 0 : MacBrowserLayout.sidebarTitlebarHeight))
            .background(BrowserDragRegion())
            .browserGeometryMarker("sidebarTitlebarGeometry")
            .accessibilityHidden(true)
    }

    private var sidebarToggle: some View {
        Button(action: toggleSidebar) {
            Image(systemName: "sidebar.left").font(.system(size: 14)).frame(width: railHeader ? 42 : 30, height: railHeader ? 36 : 30).contentShape(Rectangle())
        }
        .buttonStyle(.plain).focusable().focused($sidebarHeaderToggleFocused)
        .keyboardShortcut("s", modifiers: [.command, .option])
        .help(controller.sidebar.peeking ? "Keep Sidebar Expanded (⌥⌘S)" : railHeader ? "Expand Sidebar (⌥⌘S)" : "Collapse to Icon Rail (⌥⌘S)")
        .accessibilityLabel(controller.sidebar.peeking ? "Keep Sidebar Expanded" : railHeader ? "Expand Sidebar" : "Collapse Sidebar")
        .accessibilityValue(railHeader ? "Icon rail" : "Expanded")
        .accessibilityHint("Toggle sidebar with Option-Command-S")
        .accessibilityIdentifier("sidebarToggle")
        .browserGeometryMarker("sidebarToggleGeometry")
        .browserGeometryMarker("sidebarToggleKeyboardFocus", when: sidebarHeaderToggleFocused)
        .onKeyPress(.downArrow) { sidebarTabs.focus(); return .handled }
        .accessibilitySortPriority(2)
        .foregroundStyle(Theme.sidebar.text)
    }

    private func toggleSidebar() {
        let returnFocus = sidebarHeaderToggleFocused || sidebarContainsKeyboardFocus || windowContext.sidebarContainsFocus
        if returnFocus { windowContext.window?.makeFirstResponder(nil) }
        controller.toggleSidebar()
        if returnFocus {
            DispatchQueue.main.async {
                sidebarHeaderToggleFocused = true
            }
        }
    }

    private var mainTopBar: some View {
        HStack(spacing: 4) {
            navigationControls
            Spacer(minLength: 0)
            addressCapsule
            Spacer(minLength: 0)
            toolbarActions
            toolbarMenu
        }
        .padding(.horizontal, 12).frame(height: MacBrowserLayout.headerHeight)
        .background(pageChrome.color)
        .background(BrowserDragRegion())
        .environment(\.colorScheme, pageChrome.isDark ? .dark : .light)
        .accessibilityIdentifier("mainTopBar")
        .browserGeometryMarker("browserTopBarGeometry")
    }

    private var navigationControls: some View {
                HStack(spacing: 2) {
                Button { tab?.goBack() } label: { Image(systemName: "chevron.left").frame(width: 28, height: 28) }
                    .disabled(tab?.canGoBack != true).help("Back (⌘[)").accessibilityLabel("Back")
                    .foregroundStyle(chromeForeground)
                Button { tab?.goForward() } label: { Image(systemName: "chevron.right").frame(width: 28, height: 28) }
                    .disabled(tab?.canGoForward != true).help("Forward (⌘])").accessibilityLabel("Forward")
                    .foregroundStyle(chromeForeground)
                }.buttonStyle(MacChromeButtonStyle()).frame(height: 32)
                    .environment(\.colorScheme, pageChrome.isDark ? .dark : .light)
    }

    private var addressCapsule: some View {
                HStack(spacing: 7) {
                    if tab?.isPrivate == true {
                        Image(systemName: "eyeglasses").font(OrivType.detail)
                            .foregroundStyle(privateCue).accessibilityLabel("Private browsing")
                    }
                    if let tab, tab.url != nil {
                        let cue = ConnectionCue(tab)
                        Button { showSiteInfo.toggle() } label: {
                            HStack(spacing: OrivSpacing.xs) {
                                Image(systemName: cue.symbol)
                                if cue == .notSecure { Text(cue.label).font(OrivType.detail.weight(.medium)).fixedSize() }
                            }.font(OrivType.detail).foregroundStyle(chromeForeground).frame(minWidth: 24, minHeight: 24).contentShape(Rectangle())
                        }.buttonStyle(MacChromeButtonStyle()).accessibilityLabel("\(cue.label). Site information and permissions").help("Site information and permissions")
                            .popover(isPresented: $showSiteInfo) { SiteInformationView(session: session, tab: tab) }
                    } else {
                        Image(systemName: "magnifyingglass").font(OrivType.detail)
                            .foregroundStyle(chromeForeground).accessibilityHidden(true)
                    }
                    AddressField(text: $address, isEditing: $addressFocused,
                                 placeholder: "Search or enter website",
                                 displayText: compactAddress,
                                 foreground: chromeForeground,
                                 focusRequest: controller.addressFocusRequest, submit: {
                            if addressMatches.query == address, let index = addressMatches.selected, suggestions.indices.contains(index) { chooseSuggestion(suggestions[index]); return true }
                            controller.navigate(address)
                            return controller.addressError == nil
                        }, cancel: { syncAddress() }, completion: addressMatches.completion, hasSelectedSuggestion: addressMatches.selected != nil && addressMatches.query == address, moveSelection: { addressMatches.move($0) })
                        .frame(width: compactAddressWidth, height: 20)
                        .frame(maxWidth: compactAddressWidth == nil ? .infinity : nil)
                }
                .padding(.horizontal, tab?.pageZoom != 1 && tab?.url != nil ? 72 : 36)
                .frame(height: 32).frame(minWidth: 230, idealWidth: addressWidth, maxWidth: addressWidth)
                .overlay(alignment: .trailing) {
                    HStack(spacing: 4) {
                        if tab?.url != nil {
                            if let tab, tab.pageZoom != 1 {
                                Button { tab.resetZoom() } label: {
                                    Text("\(Int(tab.pageZoom * 100))%").font(.caption2).frame(minWidth: 24, minHeight: 24).contentShape(Rectangle())
                                }.buttonStyle(MacChromeButtonStyle()).accessibilityLabel("Reset Page Zoom").accessibilityValue("\(Int(tab.pageZoom * 100)) percent").help("Reset Page Zoom")
                            }
                            Button { tab?.isLoading == true ? tab?.stop() : tab?.reload() } label: {
                                Image(systemName: tab?.isLoading == true ? "xmark" : "arrow.clockwise")
                                    .font(OrivType.detail).frame(width: 24, height: 24)
                            }
                            .buttonStyle(MacChromeButtonStyle())
                            .accessibilityLabel(tab?.isLoading == true ? "Stop loading" : "Reload page")
                            .help(tab?.isLoading == true ? "Stop loading" : "Reload (⌘R)")
                        }
                    }.padding(.trailing, 4)
                }
                .foregroundStyle(chromeForeground)
                .modifier(chromeGlass)
                .environment(\.colorScheme, pageChrome.isDark ? .dark : .light)
                .environment(\.browserTheme, toolbarTheme)
                .anchorPreference(key: MacAddressBounds.self, value: .bounds) { $0 }
                .browserGeometryMarker("browserAddressGeometry")
    }

    // Site privacy shares the content header's glass and adaptive foreground.
    private var toolbarActions: some View {
                HStack(spacing: 2) {
                if showsToolbarDownloads && (pageRail || windowWidth >= 1000) {
                    Button { controller.library = .downloads } label: { Label("Downloads in progress", systemImage: "arrow.down.circle.fill") }
                        .labelStyle(.iconOnly).help("View downloads in progress")
                }
                Button { showProtection.toggle() } label: {
                    Image(systemName: "shield.lefthalf.filled").frame(width: 28, height: 28).foregroundStyle(chromeForeground)
                }
                .help("Site Privacy").accessibilityLabel("Site Privacy")
                .accessibilityIdentifier("sitePrivacyButton")
                .browserGeometryMarker("browserPrivacyGeometry")
                .popover(isPresented: $showProtection) { AdBlockingPopover(session: session) }
                if let url = tab?.url, pageRail || windowWidth >= 1000 {
                    ShareLink(item: URLCleaner.clean(url)) { Image(systemName: "square.and.arrow.up").frame(width: 28, height: 28).foregroundStyle(chromeForeground) }
                        .help("Share Page").accessibilityLabel("Share Page")
                }
                if pageRail || windowWidth >= 1000 {
                Button { controller.newTab() } label: { Image(systemName: "plus").frame(width: 28, height: 28).foregroundStyle(chromeForeground) }
                    .help("New Tab (⌘T)").accessibilityLabel("New Tab")
                Button { showTabs = true } label: { Image(systemName: "square.on.square").frame(width: 28, height: 28).foregroundStyle(chromeForeground) }
                    .help("Tab Overview").accessibilityLabel("Tab Overview")
                }
                }.buttonStyle(MacChromeButtonStyle()).frame(height: 32)
                    .environment(\.colorScheme, pageChrome.isDark ? .dark : .light)
    }

    private var toolbarMenu: some View {
        MacPageMenu {
            MacPageActions(controller: controller, profiles: profiles,
                findOnPage: { showFind = true; findFocused = true },
                showSitePrivacy: { showProtection = true }, showPasswordsGuide: { showPasswords = true })
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 36, height: 32)
                .modifier(chromeGlass).contentShape(Rectangle())
        }
        .help("Browser Actions").accessibilityLabel("Browser Actions")
        .accessibilityIdentifier("browserPageMenu")
        .foregroundStyle(chromeForeground)
        .environment(\.colorScheme, pageChrome.isDark ? .dark : .light)
        .browserGeometryMarker("browserPageMenuGeometry")
        .popover(isPresented: $showPasswords) { PasswordsGuide(compact: true) }
    }

    private var panels: some View {
        shell
        .sheet(isPresented: $showTabs) {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text("Tabs").font(.title2); Spacer(); Button("Done") { showTabs = false }.keyboardShortcut(.cancelAction) }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220))]) {
                        ForEach(session.orderedTabs) { item in
                            Button { session.selectTab(item.id); showTabs = false } label: {
                                PageRowContent(title: item.displayTitle, url: item.url, isPrivate: item.isPrivate,
                                               isSelected: item.id == session.selectedTabID,
                                               accessory: item.id == session.selectedTabID ? .selected : .none)
                                    .padding(16).frame(maxWidth: .infinity, minHeight: 90)
                                    .background(item.id == session.selectedTabID ? theme.selection : theme.surface, in: .rect(cornerRadius: 12))
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }.padding(24).frame(width: 760, height: 500)
        }
        .sheet(item: $controller.library) { section in
            LibraryView(controller: controller, profiles: profiles, section: section)
        }
        .sheet(isPresented: Binding(get: { profiles?.showManager == true }, set: { profiles?.showManager = $0 }), onDismiss: { profiles?.finishProfileSheet() }) {
            if let profiles { ProfilesSheet(profiles: profiles) }
        }
        .alert("Profiles", isPresented: Binding(get: { profiles?.error != nil }, set: { if !$0 { profiles?.error = nil } })) {
            Button("OK") { profiles?.error = nil }
        } message: { Text(profiles?.error ?? "") }
        .sheet(item: $controller.readerCapture) { capture in ReaderTextView(capture: capture) }
        .sheet(isPresented: $controller.showWebsiteData) { WebsiteDataView(manager: session.websiteData) }
        .sheet(isPresented: $controller.showClearBrowsingData) { ClearBrowsingDataView(session: session) }
        .alert("Browser", isPresented: Binding(get: { controller.browserError != nil }, set: { if !$0 { controller.browserError = nil } })) {
            Button("OK") { controller.browserError = nil }
        } message: { Text(controller.browserError ?? "") }
    }

    private var routedContent: some View {
        panels
        .alert("Unable to open address", isPresented: Binding(get: { controller.addressError != nil }, set: { if !$0 { controller.addressError = nil } })) {
            Button("OK") { controller.addressError = nil }
        } message: { Text(controller.addressError ?? "") }
    }

    private var page: some View {
            VStack(spacing: 0) {
                if showsExternalPrivateBar, let profiles {
                    ExternalPrivateBar(sourceName: profiles.externalSourceName, profiles: profiles.available,
                        selection: Binding(get: { profiles.externalMoveProfileID }, set: { profiles.externalMoveProfileID = $0 }),
                        canMove: ExternalLinkRouting.movableURL(tab?.url) != nil,
                        move: { profiles.perform { try profiles.moveExternalTab() } }, dismiss: { profiles.externalBannerVisible = false })
                }
                if session.canUndoBookmarkRemoval {
                    HStack { Text("Bookmark removed").foregroundStyle(theme.secondaryText); Spacer(); Button("Undo") { session.undoBookmarkRemoval() }.buttonStyle(.borderless); Button("Dismiss", systemImage: "xmark") { session.dismissBookmarkUndo() }.labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(theme.secondaryText) }
                        .font(OrivType.detail).padding(.horizontal, OrivSpacing.large).frame(height: 32).background(theme.surface)
                }
                if let notice = profiles?.continuity.notice { ContinuityNotice(text: notice) }
                if let notice = controller.browserNotice {
                    noticeBar(notice, symbol: "checkmark.circle", isWarning: false) { controller.browserNotice = nil }
                }
                if let notice = session.persistenceNotice {
                    noticeBar(notice, symbol: "externaldrive.badge.exclamationmark") {
                        session.dismissNotice()
                    }
                }
                // The private start page explains itself; loaded private pages keep this persistent cue.
                if tab?.isPrivate == true && !showsExternalPrivateBar && tab?.url != nil {
                    HStack(spacing: 6) {
                        Image(systemName: "eyeglasses")
                        Text("Private browsing")
                        Spacer()
                    }
                    .font(OrivType.caption.weight(.medium)).foregroundStyle(theme.privateAccent)
                    .padding(.horizontal, OrivSpacing.large).frame(height: 24)
                    .background(theme.field)
                    .accessibilityElement(children: .combine)
                }
                if showFind {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(theme.secondaryText)
                        TextField("Find in page", text: $findText)
                            .textFieldStyle(.plain).focused($findFocused)
                            .onSubmit { tab?.find(findText, caseSensitive: findCaseSensitive) }
                            .onExitCommand { showFind = false; tab?.clearFind() }
                        if tab?.findResult == false { Text("No match").font(.caption).foregroundStyle(theme.secondaryText) }
                        Toggle("Match case", isOn: $findCaseSensitive).toggleStyle(.checkbox)
                        Button { tab?.find(findText, backwards: true, caseSensitive: findCaseSensitive) } label: { Image(systemName: "chevron.up") }.accessibilityLabel("Find previous").disabled(findText.isEmpty)
                        Button { tab?.find(findText, caseSensitive: findCaseSensitive) } label: { Image(systemName: "chevron.down") }.accessibilityLabel("Find next").disabled(findText.isEmpty)
                        Button { showFind = false; tab?.clearFind() } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless).accessibilityLabel("Close find bar")
                    }
                    .padding(10)
                    Divider()
                }
                if let tab {
                    ZStack(alignment: .top) {
                        tabContent(tab)
                        if tab.httpWarningURL != nil { HTTPFallbackView(tab: tab).frame(maxWidth: .infinity, maxHeight: .infinity).background(theme.canvas) }
                        if let error = tab.errorMessage {
                            ContentUnavailableView {
                                Label("This page couldn’t load", systemImage: "network.slash")
                            } description: {
                                Text(error)
                                Text(tab.url?.host ?? "").font(.caption)
                            } actions: {
                                Button("Reload Page") { tab.reload() }.buttonStyle(.borderedProminent).tint(theme.controlFill)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(theme.canvas)
                        }
                        if tab.isLoading {
                            GeometryReader { geometry in
                                Rectangle().fill(theme.accent)
                                    .frame(width: geometry.size.width * max(0.03, tab.progress), height: 2)
                            }
                            .frame(height: 2)
                            .accessibilityLabel("Loading page")
                            .accessibilityValue("\(Int(tab.progress * 100)) percent")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(pageChrome.color, ignoresSafeAreaEdges: [])
    }

    @ViewBuilder private func tabContent(_ tab: BrowserTab) -> some View {
        if tab.url != nil || tab.hasLoaded {
            WebPageView(tab: tab, chrome: pageChrome, contentUnderChrome: contentUnderChrome, headerInset: MacBrowserLayout.headerHeight, fullscreenChanged: { controller.sidebar.fullscreen($0) })
                .scrollEdgeEffectStyle(.automatic, for: .top)

        }
        else { StartPage(controller: controller, isPrivate: tab.isPrivate) }
    }

    private var suggestions: [BrowserSuggestion] { addressMatches.rows }
    private var addressSuggestions: some View {
        AddressSuggestionList(suggestions: suggestions, selectedIndex: addressMatches.selected, address: address,
                              engine: session.settings.searchEngine, isPrivate: tab?.isPrivate == true,
                              choose: chooseSuggestion,
                              submit: { controller.navigate(address); if controller.addressError == nil { addressFocused = false; NSApp.keyWindow?.makeFirstResponder(nil) } })
    }
    private func chooseSuggestion(_ match: BrowserSuggestion) {
        addressFocused = false
        NSApp.keyWindow?.makeFirstResponder(nil)
        if let id = match.tabID { session.selectTab(id) } else { controller.navigate(match.url.absoluteString) }
        syncAddress()
    }
    private func syncAddress() { address = tab?.url?.absoluteString ?? "" }

    private func noticeBar(_ message: String, symbol: String, isWarning: Bool = true, dismiss: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: symbol)
            Text(message).font(.caption)
            Spacer()
            if !isWarning || session.canPersist { Button("Dismiss", action: dismiss).buttonStyle(.borderless) }
        }
        .padding(10).background(isWarning ? Color.yellow.opacity(0.12) : theme.surface)
    }
}

private struct MacAddressBounds: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = nextValue() ?? value }
}

/// A filled address capsule without the system glass rim. Its colour still
/// follows the page; a contrast guard bounds the lifted dark fill.
struct MacAddressGlass: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.self) private var environment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let color: Color
    let isDark: Bool
    static let lift = 0.10
    static let lightShade = 0.06
    private var fill: Color {
        let rgb = color.resolve(in: environment)
        let source = [Double(rgb.red), Double(rgb.green), Double(rgb.blue)]
        let lifted = source.map { isDark ? $0 * (1 - Self.lift) + Self.lift : $0 * (1 - Self.lightShade) }
        let linear = lifted.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        let luminance = linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
        let safe = isDark ? 1.05 / (luminance + 0.05) >= 4.55 : (luminance + 0.05) / 0.05 >= 4.55
        let value = safe ? lifted : source.map { isDark ? $0 * 0.88 : $0 * 0.88 + 0.12 }
        return Color(.sRGB, red: value[0], green: value[1], blue: value[2], opacity: 1)
    }
    func body(content: Content) -> some View {
        content.background(fill, in: Capsule())
            .overlay {
                if contrast == .increased { Capsule().strokeBorder((isDark ? Color.white : .black).opacity(0.8), lineWidth: 1) }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: color)
    }
}

/// Disabled navigation keeps its disabled action/AX state without reducing the
/// glyph's contrast against a page of arbitrary colour.
struct MacChromeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MacChromeButtonFace(label: configuration.label, pressed: configuration.isPressed)
    }
}

private struct MacChromeButtonFace<Label: View>: View {
    let label: Label
    let pressed: Bool
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false
    var body: some View {
        label.contentShape(Rectangle())
            .background(.primary.opacity(enabled ? (pressed ? 0.12 : hovered ? 0.07 : 0) : 0), in: Capsule())
            .onHover { hovered = $0 }
    }
}

/// The address field's suggestion popover. Separate so it can be rendered on its own.
struct AddressSuggestionList: View {
    @Environment(\.browserTheme) private var theme
    let suggestions: [BrowserSuggestion]
    let selectedIndex: Int?
    let address: String
    let engine: SearchEngine
    let isPrivate: Bool
    let choose: (BrowserSuggestion) -> Void
    let submit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: OrivSpacing.xs) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, match in
                if index == 0 || suggestions[index - 1].source != match.source {
                    Text(match.source.rawValue).font(.caption.weight(.semibold)).foregroundStyle(theme.secondaryText)
                        .padding(.horizontal, 10).padding(.top, 4)
                }
                Button { choose(match) } label: {
                    AddressSuggestionRow(suggestion: match, query: address, isPrivate: isPrivate)
                        .padding(.horizontal, 10).frame(height: 38).contentShape(Rectangle())
                        .background { if selectedIndex == index { SelectedRowBackground() } }
                }.buttonStyle(.plain).accessibilityAddTraits(selectedIndex == index ? [.isSelected] : [])
            }
            // Snapshot/noninteractive callers can still supply local matches.
            if !suggestions.contains(where: { $0.source == .search }) {
                Button { choose(BrowserSuggestion(title: "Search for ‘\(address)’", url: engine.searchURL(address), source: .search)) } label: {
                    Label("Search for ‘\(address)’", systemImage: "magnifyingglass")
                        .foregroundStyle(theme.text).padding(.horizontal, 10).frame(height: 32).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
            }
        }.font(OrivType.body).padding(6).background(theme.surface, in: .rect(cornerRadius: OrivRadius.medium))
            .overlay { RoundedRectangle(cornerRadius: OrivRadius.medium).strokeBorder(theme.separator) }
            .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
    }
}
