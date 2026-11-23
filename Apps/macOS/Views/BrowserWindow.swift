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
    @State private var addressFocused = false
    @State private var passwordGuideFallback = false
    @State private var requestingPassword = false
    @FocusState private var findFocused: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    private var ui: BrowserProfileUI { controller.profileUI }
    private var pageChrome: PageChrome { ui.pageChrome }
    private var session: BrowserSession { controller.session }
    private var tab: BrowserTab? { session.selectedTab }
    private var showsExternalPrivateBar: Bool { session.isExternalPrivate && profiles?.externalBannerVisible == true }
    private var compact: Bool { controller.sidebar.rail }
    private var pageRail: Bool { controller.sidebar.reservesRail }
    private var showsToolbarDownloads: Bool { controller.downloads.hasActiveDownloads && (pageRail || windowWidth >= 800) }
    private var showsExpandedToolbarActions: Bool { pageRail || windowWidth >= 1000 }
    private var canFillPassword: Bool {
        controller.canAutoFillPassword && !addressFocused && !findFocused && !sidebarContainsKeyboardFocus
    }
    private var showsToolbarPasswordKey: Bool { canFillPassword && tab?.passwordFields.showsGlyph == false }
    private var addressWidth: CGFloat {
        let actions = showsExpandedToolbarActions ? 30 * CGFloat(2 + (tab?.url == nil ? 0 : 1) + (showsToolbarDownloads ? 1 : 0)) : 28
        let reserved = (pageRail ? MacBrowserLayout.railWidth : MacBrowserLayout.sidebarWidth) + 24 + 58 + 36 + 20 + actions
        return min(640, max(230, windowWidth - reserved - (showsToolbarPasswordKey ? 30 : 0)))
    }
    private var compactAddress: String? { tab?.url.flatMap(URLDisplay.site) }
    private var compactAddressWidth: CGFloat? {
        guard !addressFocused, let compactAddress else { return nil }
        let width = (compactAddress as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width
        return min(ceil(width) + 4, max(60, addressWidth - 180))
    }
    private var emptyPageColor: ChromeColor { PageChrome.resolveCanvas(theme.page, scheme: colorScheme) }
    private var contentUnderChrome: Bool { pageChrome.showsContentUnderChrome && !reduceTransparency && !captureReduceTransparency && contrast != .increased }
    private var chromeForeground: Color { pageChrome.foreground }
    private var chromeGlass: MacAddressGlass { MacAddressGlass(color: pageChrome.color, isDark: pageChrome.isDark) }
    private var privateCue: Color { pageChrome.contrasting(pageChrome.isDark ? Theme.privateDark : Theme.privateLight) }

    private var sceneContent: some View {
        routedContent
            .background(BrowserKeyRouter(session: session, overviewVisible: ui.showTabs, fillPassword: fillPassword))
            .environment(\.siteIcons, session.siteIcons)
            .focusedSceneValue(\.browserController, controller)
    }

    private var windowLifecycle: some View {
        sceneContent
            .onAppear(perform: prepareWindow)
            .task(id: controller.scoped("\(ui.address)-\(addressFocused)-\(session.selectedTabID?.uuidString ?? "")-\(session.forgottenSiteRevision)")) {
                await ui.addressMatches.update(addressFocused ? ui.address : "", session: session, isPrivate: tab?.isPrivate == true)
            }
            .onChange(of: controller.sidebarDragID) { _, _ in
                addressFocused = false
                findFocused = false
                sidebarHeaderToggleFocused = false
                sidebarContainsKeyboardFocus = false
                peekReturnFocus = nil
                session.activateSelectedTab()
                syncAddress()
            }
            .onChange(of: controller.scoped(session.selectedTabID)) { old, new in
                guard old.owner == new.owner else { return }
                addressFocused = false; syncAddress()
                ui.showFind = false; ui.showSiteInfo = false; ui.showProtection = false
            }
            .onChange(of: controller.scoped(tab?.url)) { old, new in
                if old.owner == new.owner, !addressFocused { syncAddress() }
            }
    }

    var body: some View {
        windowLifecycle
            .onChange(of: controller.scoped(controller.findRequest)) { old, new in
                guard old.owner == new.owner else { return }
                ui.showFind = true
                findFocused = true
            }
            .onChange(of: controller.scoped(controller.findNextRequest)) { old, new in
                guard old.owner == new.owner else { return }

                ui.showFind = true
                if ui.findText.isEmpty { findFocused = true }
                else { tab?.find(ui.findText, backwards: controller.findBackwards, caseSensitive: ui.findCaseSensitive) }
            }
            .onChange(of: controller.scoped(controller.passwordsGuideRequest)) { old, new in
                guard old.owner == new.owner else { return }
                showPasswordHelp()
            }
            .onChange(of: controller.scoped(controller.passwordFillRequest)) { old, new in
                guard old.owner == new.owner else { return }
                fillPassword()
            }
            .onChange(of: glyphRequest) { old, new in
                guard old?.tabID == new?.tabID, old?.count != new?.count else { return }
                fillPassword()
            }
            .onChange(of: scenePhase) { _, phase in if phase != .active { session.saveNow() } }
            .task(id: controller.scoped(selectedPage)) { observeSelectedPage() }
            .onChange(of: controller.scoped(emptyPageColor), initial: true) { _, color in pageChrome.setEmptyPageColor(color.value) }
            .onChange(of: colorScheme) { _, _ in pageChrome.requestSample() }
            .onDisappear { pageChrome.observe(nil) }
    }

    private struct GlyphRequest: Equatable {
        let tabID: UUID
        let count: Int
    }

    private var glyphRequest: GlyphRequest? {
        tab.map { GlyphRequest(tabID: $0.id, count: $0.passwordFields.glyphRequest) }
    }

    private func showPasswordHelp(fallback: Bool = false) {
        passwordGuideFallback = fallback
        ui.showPasswords = true
    }

    private func fillPassword() {
        guard !requestingPassword else { return }
        guard canFillPassword, let tab, let window = windowContext.window else {
            showPasswordHelp(fallback: true)
            return
        }
        requestingPassword = true
        Task { @MainActor in
            defer { requestingPassword = false }
            let requested = await ApplePasswords.requestFill(in: tab, window: window, picker: AppKitPasswordPicker()) {
                session.selectedTab === tab
            }
            if !requested, session.selectedTab === tab { showPasswordHelp(fallback: true) }
        }
    }

    private func prepareWindow() {
        session.activateSelectedTab()
        syncAddress()
        if controller.addressFocusRequestAtProfileSwitch == nil, tab?.url == nil, tab?.hasLoaded != true {
            controller.focusAddress()
        }
        if !session.isExternalPrivate {
            profiles?.showRegularWindow = { openWindow(id: "browser") }
            profiles?.showExternalWindow = { openWindow(id: "external-private") }
            profiles?.closeExternalWindow = { dismissWindow(id: "external-private") }
            if profiles?.externalPrivate != nil { openWindow(id: "external-private") }
        }
    }

    private var profileSwitchFocus: (() -> Bool)? {
        guard controller.addressFocusRequestAtProfileSwitch != nil else { return nil }
        return { controller.session.isProfileActive && controller.activeAddressFocusRequest == 0 }
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
                page
            }
            .padding(.leading, controller.sidebar.reservation)
            // The page receives one final viewport update, never interpolated widths.
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            sidebarPanel
                .frame(width: sidebarClipWidth, alignment: .leading).contentShape(Rectangle()).clipped()
                .shadow(color: .black.opacity(controller.sidebar.overlay ? 0.12 : 0), radius: 8, x: layoutDirection == .rightToLeft ? -4 : 4)
                .opacity(controller.sidebar.webpageFullscreen ? 0 : 1)
                .allowsHitTesting(!controller.sidebar.webpageFullscreen)
                .accessibilityHidden(controller.sidebar.webpageFullscreen)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Browser")
        .ignoresSafeArea(.container, edges: .top)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
            windowWidth = $0
        }
        .onAppear { sidebarClipWidth = controller.sidebar.width }
        .onChange(of: controller.scoped(controller.sidebar.transition)) { previous, next in
            withAnimation(reduceMotion || previous.owner != next.owner ? nil : .easeOut(duration: previous.value.peeking || next.value.peeking ? 0.18 : 0.2)) {
                sidebarClipWidth = next.value.width
            }
        }
        .onChange(of: controller.scoped(controller.sidebar.peeking)) { old, new in
            guard old.owner == new.owner else { return }
            let open = new.value
            if open { peekReturnFocus = windowContext.window?.firstResponder }
            else if sidebarContainsKeyboardFocus {
                if let peekReturnFocus { windowContext.window?.makeFirstResponder(peekReturnFocus) }
                peekReturnFocus = nil
            }
        }
        .onChange(of: controller.scoped(controller.sidebarToggleRequest)) { old, new in
            guard old.owner == new.owner else { return }
            toggleSidebar()
        }
        .onChange(of: controller.scoped(controller.tabSearchPanel)) { old, new in
            guard old.owner == new.owner else { return }
            let open = new.value
            if !open { restoreSearchFocus() }
        }
        .onDisappear { controller.sidebar.cancel(); controller.sidebarTooltip.dismiss() }
        .background(SidebarWindowEvents(controller: controller, profiles: controller === profiles?.controller ? profiles : nil, tabList: sidebarTabs, layoutDirection: layoutDirection, dismiss: dismissSidebarOverlay))
        .navigationTitle(session.isExternalPrivate ? "Oriv — Private" : profiles.map { "\(AppIdentity.name) — \($0.active.name)" } ?? AppIdentity.name)
        .background(pageChrome.color, ignoresSafeAreaEdges: [])
        .background(BrowserTitlebar(color: pageChrome.color, reduceMotion: reduceMotion || !pageChrome.animatesColor, profileEpoch: controller.sidebarDragID))
        .background(BrowserWindowChrome(windowContext: windowContext, compact: controller.sidebar.reservesRail,
            initialContentFocus: tab?.url != nil || tab?.hasLoaded == true ? tab?.webView : nil,
            shouldApplyProfileSwitchFocus: profileSwitchFocus, profileEpoch: controller.sidebarDragID,
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
                    .padding(.leading, max(0, min(controller.sidebar.width - 2, geometry.size.width - width - 8)))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .offset(y: min(max(16, geometry.size.height - rect.maxY), max(16, geometry.size.height - 196)))
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
                if let anchor, addressFocused && !ui.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let rect = geometry[anchor]
                    let leading = layoutDirection == .rightToLeft ? geometry.size.width - rect.maxX : rect.minX
                    addressSuggestions.frame(width: rect.width)
                        .padding(.leading, max(0, leading))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .offset(y: rect.maxY + OrivSpacing.xs)
                }
            }
        }
    }

    private var sidebarPanel: some View {
        VStack(spacing: 0) {
            sidebarHeader
            BrowserSidebar(controller: controller, profiles: profiles, tabList: sidebarTabs,
                           profileTrailingInset: fullscreen ? 38 : 0)
                .onPreferenceChange(SidebarKeyboardFocusKey.self) {
                    sidebarContainsKeyboardFocus = $0; controller.sidebar.focusInside = $0 || sidebarHeaderToggleFocused
                }

        }
        .frame(width: controller.sidebar.width).frame(maxHeight: .infinity)
        // One surviving toggle preserves focus across rail/fullscreen changes.
        // In fullscreen it shares the profile line instead of reserving a band.
        .overlay(alignment: .topLeading) {
            sidebarToggle
                .background {
                    if let profiles, fullscreen {
                        ProfileSidebarSwipeRegion(switcher: profiles.sidebarSwitch, controller: controller, kind: .titlebarControl)
                    }
                }
                .padding(.leading, railHeader ? MacBrowserLayout.railInset : controller.sidebar.width - MacBrowserLayout.sidebarInset - 30)
                .padding(.top, railHeader ? (fullscreen ? 0 : MacBrowserLayout.sidebarTitlebarHeight) : (fullscreen ? 8 : 1))
                .opacity(windowActive ? 1 : 0.75)
        }
        .background {
            Color.clear.modifier(OrivMaterial.navigation(color: controller.sidebarColor,
                                                 profileColor: controller.sidebarProfileColor(in: profiles)))
                .accessibilityHidden(true)
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
            guard controller.session.isProfileActive, !controller.tabSearchPanel else { return }
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
            Image(systemName: layoutDirection == .rightToLeft ? "sidebar.right" : "sidebar.left").font(.system(size: 14)).frame(width: railHeader ? 42 : 30, height: railHeader ? 36 : 30).contentShape(Rectangle())
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
        .foregroundStyle(.primary)
    }

    private func toggleSidebar() {
        let returnFocus = sidebarHeaderToggleFocused || sidebarContainsKeyboardFocus || windowContext.sidebarContainsFocus
        if returnFocus { windowContext.window?.makeFirstResponder(nil) }
        controller.toggleSidebar()
        if returnFocus {
            DispatchQueue.main.async {
                guard controller.session.isProfileActive else { return }
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
                Button { tab?.goBack() } label: { Image(systemName: "chevron.backward").frame(width: 28, height: 28) }
                    .disabled(tab?.canGoBack != true).help("Back (⌘[)").accessibilityLabel("Back")
                    .foregroundStyle(chromeForeground)
                Button { tab?.goForward() } label: { Image(systemName: "chevron.forward").frame(width: 28, height: 28) }
                    .disabled(tab?.canGoForward != true).help("Forward (⌘])").accessibilityLabel("Forward")
                    .foregroundStyle(chromeForeground)
                }.buttonStyle(MacChromeButtonStyle()).frame(height: 32)
                    .environment(\.colorScheme, pageChrome.isDark ? .dark : .light)
    }

    private var addressCapsule: some View {
        @Bindable var ui = self.ui
        return HStack(spacing: 7) {
                    if tab?.isPrivate == true {
                        Image(systemName: "eyeglasses").font(OrivType.detail)
                            .foregroundStyle(privateCue).accessibilityLabel("Private browsing")
                    }
                    if let tab, tab.url != nil {
                        let cue = ConnectionCue(tab)
                        Button { ui.showSiteInfo.toggle() } label: {
                            HStack(spacing: OrivSpacing.xs) {
                                Image(systemName: cue.symbol)
                                if cue == .notSecure { Text(cue.label).font(OrivType.detail.weight(.medium)).fixedSize() }
                            }.font(OrivType.detail).foregroundStyle(chromeForeground).frame(minWidth: 24, minHeight: 24).contentShape(Rectangle())
                        }.buttonStyle(MacChromeButtonStyle()).accessibilityLabel("\(cue.label). Site information and permissions").help("Site information and permissions")
                            .browserGeometryMarker("browserSiteInformationGeometry")
                            .background {
                                BrowserPopover(isPresented: $ui.showSiteInfo) {
                                    SiteInformationView(session: session, tab: tab)
                                        .environment(\.colorScheme, colorScheme)
                                }
                            }
                    } else {
                        Image(systemName: "magnifyingglass").font(OrivType.detail)
                            .foregroundStyle(chromeForeground).accessibilityHidden(true)
                    }
                    AddressField(text: $ui.address, isEditing: $addressFocused,
                                 placeholder: OrivStrings.addressPlaceholder,
                                 displayText: compactAddress,
                                 foreground: chromeForeground,
                                 focusRequest: controller.activeAddressFocusRequest,
                                 profileEpoch: controller.sidebarDragID, focusStillValid: { controller.session.isProfileActive }, submit: {
                            if ui.addressMatches.query == ui.address, let index = ui.addressMatches.selected, suggestions.indices.contains(index) { chooseSuggestion(suggestions[index]); return true }
                            controller.navigate(ui.address)
                            return controller.addressError == nil
                        }, cancel: { syncAddress() }, completion: ui.addressMatches.completion, hasSelectedSuggestion: ui.addressMatches.selected != nil && ui.addressMatches.query == ui.address, moveSelection: { ui.addressMatches.move($0) })
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
                .anchorPreference(key: MacAddressBounds.self, value: .bounds) { $0 }
                .browserGeometryMarker("browserAddressGeometry")
    }

    // Site privacy shares the content header's glass and adaptive foreground.
    private var toolbarActions: some View {
        @Bindable var ui = self.ui
        return HStack(spacing: 2) {
            if showsToolbarPasswordKey {
                Button(action: fillPassword) {
                    Image(systemName: "key.fill")
                        .frame(width: 28, height: 28)
                        .foregroundStyle(chromeForeground)
                        .background(chromeForeground.opacity(0.16), in: Circle())
                }
                .help("AutoFill from Passwords")
                .accessibilityLabel("AutoFill from Passwords")
            }
            if showsToolbarDownloads && showsExpandedToolbarActions {
                Button { controller.library = .downloads } label: { Label("Downloads in progress", systemImage: "arrow.down.circle.fill") }
                    .labelStyle(.iconOnly).help("View downloads in progress")
            }
            Button { ui.showProtection.toggle() } label: {
                Image(systemName: "shield.lefthalf.filled").frame(width: 28, height: 28).foregroundStyle(chromeForeground)
            }
            .help(OrivStrings.sitePrivacy).accessibilityLabel(OrivStrings.sitePrivacy)
            .accessibilityIdentifier("sitePrivacyButton")
            .browserGeometryMarker("browserPrivacyGeometry")
            .background {
                BrowserPopover(isPresented: $ui.showProtection) {
                    AdBlockingPopover(session: session)
                        .environment(\.colorScheme, colorScheme)
                }
            }
            if showsExpandedToolbarActions {
                if let url = tab?.url {
                    ShareLink(item: URLCleaner.clean(url)) { Image(systemName: "square.and.arrow.up").frame(width: 28, height: 28).foregroundStyle(chromeForeground) }
                        .help("Share Page").accessibilityLabel("Share Page")
                }
                Button { ui.showTabs = true } label: { Image(systemName: "square.on.square").frame(width: 28, height: 28).foregroundStyle(chromeForeground) }
                    .help("Tab Overview").accessibilityLabel("Tab Overview")
                    .browserGeometryMarker("browserOverviewGeometry")
            }
        }.buttonStyle(MacChromeButtonStyle()).frame(height: 32)
            .environment(\.colorScheme, pageChrome.isDark ? .dark : .light)
    }

    private var toolbarMenu: some View {
        @Bindable var ui = self.ui
        let fillAction: (() -> Void)? = canFillPassword ? { fillPassword() } : nil
        let menu = MacPageMenu {
            MacPageActions(controller: controller, profiles: profiles,
                findOnPage: { ui.showFind = true; findFocused = true },
                showSitePrivacy: { ui.showProtection = true },
                fillPassword: fillAction, showPasswordsGuide: { showPasswordHelp() },
                requestSiteForget: { ui.siteToForget = $0 })
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 36, height: 32)
                .modifier(chromeGlass).contentShape(Rectangle())
        }
        return menu
        .help("Browser Actions").accessibilityLabel("Browser Actions")
        .accessibilityIdentifier("browserPageMenu")
        .foregroundStyle(chromeForeground)
        .environment(\.colorScheme, pageChrome.isDark ? .dark : .light)
        .browserGeometryMarker("browserPageMenuGeometry")
        .background {
            BrowserPopover(isPresented: $ui.showPasswords) {
                PasswordsGuide(compact: true, showsFillHint: canFillPassword && !passwordGuideFallback)
                    .environment(\.colorScheme, colorScheme)
            }
        }
    }

    private var panels: some View {
        @Bindable var ui = self.ui
        return shell
        .sheet(isPresented: $ui.showTabs) {
            MacTabOverview(session: session) { ui.showTabs = false }
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
        .forgetSiteAlert($ui.siteToForget, session: session) { controller.browserError = $0 }
    }

    private var routedContent: some View {
        panels
        .alert("Unable to open address", isPresented: Binding(get: { controller.addressError != nil }, set: { if !$0 { controller.addressError = nil } })) {
            Button("OK") { controller.addressError = nil }
        } message: { Text(controller.addressError ?? "") }
    }

    private var page: some View {
        @Bindable var ui = self.ui
        return VStack(spacing: 0) {
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
                if ui.showFind {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(theme.secondaryText)
                        TextField("Find in page", text: $ui.findText)
                            .textFieldStyle(.plain).focused($findFocused)
                            .onSubmit { tab?.find(ui.findText, caseSensitive: ui.findCaseSensitive) }
                            .onExitCommand { ui.showFind = false; tab?.clearFind() }
                        if tab?.findResult == false { Text("No match").font(.caption).foregroundStyle(theme.secondaryText) }
                        Toggle("Match case", isOn: $ui.findCaseSensitive).toggleStyle(.checkbox)
                        Button { tab?.find(ui.findText, backwards: true, caseSensitive: ui.findCaseSensitive) } label: { Image(systemName: "chevron.up") }.accessibilityLabel("Find previous").disabled(ui.findText.isEmpty)
                        Button { tab?.find(ui.findText, caseSensitive: ui.findCaseSensitive) } label: { Image(systemName: "chevron.down") }.accessibilityLabel("Find next").disabled(ui.findText.isEmpty)
                        Button { ui.showFind = false; tab?.clearFind() } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless).accessibilityLabel("Close find bar")
                    }
                    .padding(10)
                    .browserGeometryMarker("browserFindBarGeometry")
                    Divider()
                }
                if let tab {
                    ZStack(alignment: .top) {
                        tabContent(tab)
                        if tab.httpWarningURL != nil { HTTPFallbackView(tab: tab).frame(maxWidth: .infinity, maxHeight: .infinity).background(theme.canvas) }
                        if let error = tab.errorMessage {
                            PageErrorState(message: error, host: tab.url?.host, retry: tab.reload)
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
        if tab.isResettingSiteData {
            Color.clear
        } else if tab.url != nil || tab.hasLoaded {
            WebPageView(tab: tab, chrome: pageChrome, contentUnderChrome: contentUnderChrome, headerInset: MacBrowserLayout.headerHeight, profileTransition: profiles?.sidebarSwitch.isPresenting(controller.profile?.id) == true, profileEpoch: controller.sidebarDragID, fullscreenChanged: { controller.sidebar.fullscreen($0) })
                .scrollEdgeEffectStyle(.automatic, for: .top)

        }
        else {
            StartPage(controller: controller, isPrivate: tab.isPrivate)
                .overlay {
                    HomeProfileFade(epoch: controller.sidebarDragID, color: pageChrome.color,
                                    startsOnMount: profiles?.sidebarSwitch.isPresenting(controller.profile?.id) == true,
                                    reduceMotion: reduceMotion)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
        }
    }

    private var suggestions: [BrowserSuggestion] { ui.addressMatches.rows }
    private var addressSuggestions: some View {
        AddressSuggestionList(suggestions: suggestions, selectedIndex: ui.addressMatches.selected, address: ui.address,
                              engine: session.settings.searchEngine, isPrivate: tab?.isPrivate == true,
                              choose: chooseSuggestion,
                              submit: { controller.navigate(ui.address); if controller.addressError == nil { addressFocused = false; NSApp.keyWindow?.makeFirstResponder(nil) } })
    }
    private func chooseSuggestion(_ match: BrowserSuggestion) {
        addressFocused = false
        NSApp.keyWindow?.makeFirstResponder(nil)
        if let id = match.tabID { session.selectTab(id) } else { controller.navigate(match.url.absoluteString) }
        syncAddress()
    }
    private func syncAddress() { ui.address = tab?.url?.absoluteString ?? "" }

    private func noticeBar(_ message: String, symbol: String, isWarning: Bool = true, dismiss: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: symbol).foregroundStyle(isWarning ? theme.warning : theme.secondaryText)
            Text(message).font(OrivType.caption).foregroundStyle(isWarning ? theme.warning : theme.text)
            Spacer()
            if !isWarning || session.canPersist { Button("Dismiss", action: dismiss).buttonStyle(.borderless) }
        }
        .padding(10).background(theme.surface)
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
struct MacTabOverview: View {
    @Environment(\.browserTheme) private var theme
    let session: BrowserSession
    let dismiss: () -> Void

    var body: some View {
        OrivSheet(title: "Tabs", size: .large, height: 500) {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220))]) {
                    ForEach(session.orderedTabs) { tab in
                        let selected = tab.id == session.selectedTabID
                        Button {
                            session.selectTab(tab.id)
                            dismiss()
                        } label: {
                            PageRowContent(title: tab.displayTitle, url: tab.url, isPrivate: tab.isPrivate,
                                           isSelected: selected, accessory: selected ? .selected : .none)
                                .padding(16).frame(maxWidth: .infinity, minHeight: 90)
                                .background(selected ? theme.selection : theme.surface, in: .rect(cornerRadius: 12))
                        }.buttonStyle(.plain)
                    }
                }
            }
        } actions: {
            Button("Done", action: dismiss).keyboardShortcut(.cancelAction)
        }
    }
}

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
                        .modifier(ListSelection(selected: selectedIndex == index))
                }.buttonStyle(.plain).accessibilityAddTraits(selectedIndex == index ? [.isSelected] : [])
            }
            // Snapshot/noninteractive callers can still supply local matches.
            if !suggestions.contains(where: { $0.source == .search }) {
                Button { choose(BrowserSuggestion(title: "Search for ‘\(address)’", url: engine.searchURL(address), source: .search)) } label: {
                    Label("Search for ‘\(address)’", systemImage: "magnifyingglass")
                        .foregroundStyle(theme.text).padding(.horizontal, 10).frame(height: 32).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
            }
        }.font(OrivType.body).padding(OrivSpacing.small).modifier(OrivMaterial.overlay())
    }
}

/// Hosts an anchored popover in its own key window, preserving the browser's
/// first responder across both mouse and accessibility activation.
private struct BrowserPopover<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> Anchor { Anchor() }

    func updateNSView(_ anchor: Anchor, context: Context) {
        anchor.isPresented = $isPresented
        let root = AnyView(content().environment(\.self, context.environment))
        anchor.update(root)
    }

    static func dismantleNSView(_ anchor: Anchor, coordinator: ()) { anchor.close() }

    final class Anchor: NSView, NSPopoverDelegate {
        var isPresented: Binding<Bool> = .constant(false)
        private var root: AnyView?
        private var host: NSHostingController<AnyView>?
        private var popover: NSPopover?
        private weak var returnWindow: NSWindow?
        private weak var returnResponder: NSResponder?
        private var keyMonitor: Any?
        private var pendingPresentation = false
        private var finishingDismissal = false
        private var restoreResponderOnClose = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func update(_ content: AnyView) {
            guard !finishingDismissal else { return }
            guard isPresented.wrappedValue else { close(restoreResponder: true); return }
            if let host {
                host.rootView = content
            } else {
                root = content
                presentWhenReady()
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { close() }
            else { presentWhenReady() }
        }

        override func layout() {
            super.layout()
            presentWhenReady()
        }

        private func presentWhenReady() {
            guard root != nil, window != nil, !bounds.isEmpty, !pendingPresentation else { return }
            pendingPresentation = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                pendingPresentation = false
                guard isPresented.wrappedValue, popover == nil, let window,
                      let root, !bounds.isEmpty else { return }
                self.root = nil
                let responder = window.firstResponder
                let editor = responder as? NSTextView
                returnWindow = window
                // The shared field editor can end editing when its window
                // resigns key. The field can start editing again on return.
                returnResponder = editor?.isFieldEditor == true ? (editor?.delegate as? NSResponder ?? responder) : responder
                let host = NSHostingController(rootView: root)
                let popover = NSPopover()
                popover.behavior = .transient
                popover.appearance = window.effectiveAppearance
                popover.animates = !BackgroundUIMode.isEnabled
                popover.contentViewController = host
                popover.delegate = self
                self.host = host
                self.popover = popover
                popover.show(relativeTo: bounds, of: self, preferredEdge: .minY)
                focusPopover()
            }
        }

        func popoverDidShow(_ notification: Notification) { focusPopover() }

        private func focusPopover() {
            guard let view = host?.view, let window = view.window else { return }
            if !window.isKeyWindow { window.makeKey() }
            if window.firstResponder == nil || window.firstResponder === window {
                window.makeFirstResponder(view)
            }
            guard keyMonitor == nil else { return }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
                let handled = MainActor.assumeIsolated {
                    guard let self, let window, event.window === window, window.attachedSheet == nil else { return false }
                    if event.keyCode == 53 {
                        self.close(restoreResponder: true)
                        return true
                    }
                    let modifiers = event.modifierFlags.intersection([.shift, .command, .option, .control])
                    guard event.keyCode == 48, modifiers.isSubset(of: .shift) else { return false }
                    if modifiers.contains(.shift) { window.selectPreviousKeyView(nil) }
                    else { window.selectNextKeyView(nil) }
                    return true
                }
                return handled ? nil : event
            }
            BackgroundUIMode.checkFrontmost()
        }

        func popoverDidClose(_ notification: Notification) {
            finishingDismissal = true
            let closedWindow = host?.view.window
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
            popover = nil
            host = nil
            let window = returnWindow
            let responder = restoreResponderOnClose ? returnResponder : nil
            restoreResponderOnClose = false
            returnWindow = nil
            returnResponder = nil
            let presentation = isPresented
            // Let AppKit finish its own window and field-editor handoff before
            // restoring the invoking responder or updating SwiftUI's binding.
            DispatchQueue.main.async { [weak self, weak window, weak responder, weak closedWindow] in
                if presentation.wrappedValue { presentation.wrappedValue = false }
                self?.finishingDismissal = false
                guard let window, window.isVisible,
                      NSApp.keyWindow == nil || NSApp.keyWindow === window || NSApp.keyWindow === closedWindow else { return }
                if !window.isKeyWindow { window.makeKey() }
                if let responder { window.makeFirstResponder(responder) }
            }
        }

        func close(restoreResponder: Bool = false) {
            root = nil
            guard let popover else { return }
            restoreResponderOnClose = restoreResponder
            popover.close()
        }
    }
}
