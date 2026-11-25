import BrowserCore
import BrowserEngine
import SwiftUI
import WebKit

struct BrowserWindow: View {
    @Environment(\.browserTheme) private var theme
    @Environment(\.self) private var environment
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.displayScale) private var displayScale
    @Environment(\.sidebarContrast) private var contrast
    @Environment(\.browserReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.chromeReduceTransparencyOverride) private var captureReduceTransparency
    @Bindable var controller: BrowserController
    var profiles: BrowserProfiles? = nil
    @State private var windowWidth: CGFloat = 1250
    @State private var sidebarClipWidth: CGFloat = MacBrowserLayout.sidebarWidth
    @State private var peekReturnFocus: NSResponder?
    @State private var windowSidebarWidth: CGFloat?
    @State private var fullscreen = false
    @State private var windowActive = true
    @State private var windowContext = MacBrowserWindowContext()
    @State private var sidebarTabs = SidebarListHandle()
    @FocusState private var sidebarHeaderToggleFocused: Bool
    @State private var sidebarContainsKeyboardFocus = false
    @State private var addressFocused = false
    @State private var addressHovered = false
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
    private var isPrivateWindow: Bool { session.isExternalPrivate || controller.profile == nil }
    private var v3Mode: OrivMacV3.AppearanceMode {
        OrivMacV3.AppearanceMode.resolve(theme: theme, colorScheme: colorScheme, isPrivateWindow: isPrivateWindow)
    }
    private var isStartPage: Bool { tab?.url == nil && tab?.hasLoaded != true }
    private var increasedContrast: Bool { contrast == .increased }
    private var usesReducedBackdrop: Bool { reduceTransparency || captureReduceTransparency || increasedContrast }
    private var usesOpaqueToolbar: Bool {
        OrivMacV3.usesOpaqueSurface(theme: theme, reduceTransparency: reduceTransparency,
                                    captureReduceTransparency: captureReduceTransparency, contrast: contrast)
    }
    private var requiresSolidScrollEdge: Bool {
        reduceTransparency || captureReduceTransparency || increasedContrast || v3Mode == .black
    }
    private var siteProtectionsActive: Bool {
        guard let tab, let url = tab.url else { return false }
        return session.adBlocker.isEnabled(for: url, isPrivate: tab.isPrivate)
            || PrivacyLayer.allCases.contains { session.settings.privacy.isEnabled($0, for: url, isPrivate: tab.isPrivate) }
    }
    private var toolbarInk: Color { OrivMacV3.Ink.primary(v3Mode) }
    private var toolbarSecondaryInk: Color { OrivMacV3.Ink.secondary(v3Mode, increasedContrast: increasedContrast) }
    private var activeProfileColor: ProfileColor { controller.sidebarProfileColor(in: profiles) ?? .mulberry }
    private var webpageFullscreen: Bool { controller.sidebar.webpageFullscreen }
    private var cardInset: CGFloat { webpageFullscreen ? OrivMacV3.Frame.webpageFullscreenInset : MacBrowserLayout.windowInset }
    private var hasPageTopBars: Bool {
        showsExternalPrivateBar
            || session.canUndoBookmarkRemoval
            || profiles?.continuity.notice != nil
            || controller.browserNotice != nil
            || session.persistenceNotice != nil
            || ui.showFind
    }
    private var compact: Bool { controller.sidebar.rail }
    private var pageRail: Bool { controller.sidebar.reservesRail }
    private var showsToolbarDownloads: Bool { controller.downloads.hasActiveDownloads }
    private var showsExpandedToolbarActions: Bool { pageRail || windowWidth - controller.sidebar.reservation - cardInset >= 728 }
    private var canFillPassword: Bool {
        controller.canAutoFillPassword && !addressFocused && !findFocused && !sidebarContainsKeyboardFocus
    }
    private var reservesToolbarPasswordKey: Bool {
        controller.canAutoFillPassword && tab?.passwordFields.showsGlyph == false
    }
    private var trailingToolbarButtonCount: Int {
        2 + (reservesToolbarPasswordKey ? 1 : 0)
            + (showsExpandedToolbarActions && tab?.url != nil ? 1 : 0)
            + (showsExpandedToolbarActions && showsToolbarDownloads ? 1 : 0)
    }
    private var toolbarSideWidth: CGFloat {
        let count = max(2, trailingToolbarButtonCount)
        let buttons = CGFloat(count) * OrivMacV3.ToolbarLayout.buttonSize
        let dividers = CGFloat(count - 1) * (OrivMacV3.ToolbarLayout.dividerSize.width + 2 * OrivMacV3.ToolbarLayout.dividerMarginHorizontal)
        let gaps = CGFloat(max(0, count * 2 - 2)) * OrivMacV3.ToolbarLayout.groupGap
        // Match the trailing action group on the leading side so the address
        // and the start-page column share the center of the page viewport.
        return ceil(buttons + dividers + gaps + 2 * OrivMacV3.ToolbarLayout.groupPadding)
    }
    private var addressWidth: CGFloat {
        let cardWidth = max(0, windowWidth - controller.sidebar.reservation - cardInset)
        let reserved = 2 * (OrivMacV3.ToolbarLayout.paddingHorizontal + toolbarSideWidth + OrivSpacing.small)
        return min(OrivMacV3.ToolbarLayout.addressRestWidth, max(OrivMacV3.ToolbarLayout.addressMinWidth, cardWidth - reserved))
    }
    private var compactAddress: String? { tab?.url.flatMap(URLDisplay.site) }
    private var compactAddressWidth: CGFloat? {
        guard !addressFocused, let compactAddress else { return nil }
        let width = (compactAddress as NSString).size(withAttributes: [.font: AddressField.restFont]).width
        return ceil(width) + OrivSpacing.xs
    }
    private var emptyPageColor: ChromeColor {
        PageChrome.resolveCanvas(OrivMacV3.Card.fill(v3Mode), scheme: isPrivateWindow ? .dark : colorScheme)
    }
    private var contentUnderChrome: Bool { pageChrome.showsContentUnderChrome && !reduceTransparency && !captureReduceTransparency && contrast != .increased }
    private var usesWindowMaterial: Bool {
        !fullscreen && !theme.isT3Code && !reduceTransparency && !captureReduceTransparency
            && contrast != .increased && !BackgroundUIMode.isEnabled
    }


    private var sceneContent: some View {
        routedContent
            .background(BrowserKeyRouter(session: session, fillPassword: fillPassword))
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

    private var displayedSidebarWidth: CGFloat {
        controller.sidebar.isResizing ? controller.sidebar.width : sidebarClipWidth
    }

    private var shell: some View {
        let cardRadius = webpageFullscreen ? .zero : OrivMacV3.Radius.pageCard
        let cardShape = RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
        return ZStack(alignment: .topLeading) {
            if !webpageFullscreen {
                OrivMacV3.Backdrop.BackdropView(
                    mode: v3Mode,
                    startPage: isStartPage,
                    profileColor: activeProfileColor,
                    reduced: usesReducedBackdrop
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            ZStack(alignment: .top) {
                page
                mainTopBar.zIndex(1)
                    .opacity(webpageFullscreen ? 0 : 1)
                    .allowsHitTesting(!webpageFullscreen)
                    .accessibilityHidden(webpageFullscreen)
            }
            .background(OrivMacV3.Card.fill(v3Mode))
            .clipShape(cardShape)
            .overlay {
                if !webpageFullscreen {
                    cardShape.strokeBorder(
                        OrivMacV3.Card.rim(v3Mode, increasedContrast: contrast == .increased),
                        lineWidth: contrast == .increased ? OrivOutline.enhanced : OrivOutline.hairline
                    )
                    .allowsHitTesting(false)
                }
            }
            .browserGeometryMarker("browserPageCardGeometry")
            .orivV3Shadow(webpageFullscreen ? .none : OrivMacV3.Card.elevation(v3Mode))
            .padding(.leading, controller.sidebar.reservation)
            .padding(.trailing, cardInset)
            .padding(.vertical, cardInset)
            // The page receives one final viewport update, never interpolated widths.
            .transaction(value: controller.sidebar.reservation) { $0.animation = nil; $0.disablesAnimations = true }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: .zero) {
                sidebarPanel
                if !railHeader {
                    SidebarResizeGrip(width: controller.sidebar.expandedWidth, direction: layoutDirection,
                                      resize: resizeSidebar)
                        .frame(width: MacBrowserLayout.sidebarResizeGripWidth)
                        .padding(.vertical, OrivSpacing.xl)
                }
            }
            .padding(.leading, MacBrowserLayout.windowInset)
            .opacity(webpageFullscreen ? 0 : 1)
            .allowsHitTesting(!webpageFullscreen)
            .accessibilityHidden(webpageFullscreen)
        }
        .environment(\.colorScheme, isPrivateWindow ? .dark : colorScheme)
        .environment(\.v3AppearanceMode, v3Mode)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Browser")
        .ignoresSafeArea(.container, edges: .top)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
            windowWidth = $0
        }
        .onAppear {
            windowSidebarWidth = controller.sidebar.expandedWidth
            sidebarClipWidth = controller.sidebar.width
        }
        .onChange(of: controller.sidebarDragID) { _, _ in
            if let windowSidebarWidth { controller.sidebar.setExpandedWidth(windowSidebarWidth) }
        }
        .onChange(of: controller.scoped(controller.sidebar.transition)) { previous, next in
            withAnimation(reduceMotion || controller.sidebar.isResizing || previous.owner != next.owner
                          ? nil : (previous.value.peeking || next.value.peeking ? OrivMotion.quick : OrivMotion.standard)) {
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
        .background(BrowserWindowChrome(windowContext: windowContext, compact: controller.sidebar.reservesRail, sidebarWidth: controller.sidebar.width,
            backdrop: OrivMacV3.Backdrop.reduced(v3Mode), usesWindowMaterial: usesWindowMaterial,
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
                    .padding(.leading, max(MacBrowserLayout.windowInset,
                                           min(MacBrowserLayout.windowInset + controller.sidebar.width + MacBrowserLayout.sidebarCardGap,
                                               geometry.size.width - width - MacBrowserLayout.windowInset)))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .offset(y: min(max(16, geometry.size.height - rect.maxY), max(16, geometry.size.height - 196)))
                    .accessibilityHidden(true)
                }
            }
        }
        .overlay(alignment: .topLeading) {
            if controller.tabSearchPanel {
                SidebarSearchPanel(controller: controller, profileColor: controller.sidebarProfileColor(in: profiles), dismiss: { controller.dismissTabSearch() })
                    .frame(width: min(360, windowWidth - 16), height: min(420, (windowContext.window?.contentView?.bounds.height ?? 600) - 32))
                    .padding(.leading, min(MacBrowserLayout.railReservation, max(MacBrowserLayout.windowInset, windowWidth - 376)))
                    .padding(.top, MacBrowserLayout.windowInset + MacBrowserLayout.sidebarTitlebarHeight + OrivSpacing.large)
            }
        }
        .overlayPreferenceValue(MacAddressBounds.self) { anchor in
            GeometryReader { geometry in
                if let anchor, addressFocused && !ui.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let rect = geometry[anchor]
                    let leading = layoutDirection == .rightToLeft ? geometry.size.width - rect.maxX : rect.minX
                    addressSuggestions.frame(width: rect.width)
                        .browserGeometryMarker("browserAddressSuggestionsGeometry")
                        .padding(.leading, max(0, leading))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .offset(y: rect.maxY + OrivSpacing.xxs)
                }
            }
        }
    }

    private var sidebarPanel: some View {
        VStack(spacing: 0) {
            sidebarHeader
            BrowserSidebar(controller: controller, profiles: profiles, tabList: sidebarTabs,
                           profileTrailingInset: fullscreen && !railHeader ? MacBrowserLayout.fullscreenProfileTrailingInset : 0)
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
                .padding(.leading, railHeader ? MacBrowserLayout.railInset : controller.sidebar.width - MacBrowserLayout.sidebarInset - MacBrowserLayout.sidebarToggleSize)
                .padding(.top, railHeader ? (fullscreen ? MacBrowserLayout.railFullscreenTopInset : MacBrowserLayout.sidebarTitlebarHeight)
                                          : (fullscreen ? OrivSpacing.xs : MacBrowserLayout.sidebarToggleTopInset))
                .opacity(windowActive ? 1 : 0.75)
        }
        .browserGeometryMarker("browserSidebarGeometry")
        .frame(width: displayedSidebarWidth, alignment: .leading)
        .background {
            Color.clear.accessibilityHidden(true).browserGeometryMarker("sidebarSurfaceGeometry")
        }
        .modifier(OrivMaterial.navigation(color: controller.sidebarColor,
                                          profileColor: controller.sidebarProfileColor(in: profiles),
                                          isPrivateWindow: isPrivateWindow))
        .onHover { inside in controller.sidebar.panelInside = inside }
        .onChange(of: sidebarHeaderToggleFocused) { _, focused in controller.sidebar.focusInside = focused || sidebarContainsKeyboardFocus }
        .padding(.vertical, MacBrowserLayout.windowInset)
    }

    private func resizeSidebar(to width: CGFloat, dragging: Bool) {
        controller.sidebar.setExpandedWidth(width, resizing: dragging)
        sidebarClipWidth = controller.sidebar.width
        windowSidebarWidth = controller.sidebar.expandedWidth
        if !dragging, !controller.testing {
            UserDefaults.standard.set(Double(controller.sidebar.expandedWidth), forKey: SidebarPresentation.widthPreferenceKey)
        }
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
            .frame(height: railHeader
                   ? (fullscreen ? MacBrowserLayout.railItemHeight + MacBrowserLayout.railFullscreenTopInset : MacBrowserLayout.sidebarTitlebarHeight + MacBrowserLayout.railItemHeight)
                   : (fullscreen ? 0 : MacBrowserLayout.sidebarTitlebarHeight))
            .background(BrowserDragRegion())
            .browserGeometryMarker("sidebarTitlebarGeometry")
            .accessibilityHidden(true)
    }

    private var sidebarToggle: some View {
        Button(action: toggleSidebar) {
            Image(systemName: layoutDirection == .rightToLeft ? "sidebar.right" : "sidebar.left").font(OrivIcon.toolbarFont).frame(width: railHeader ? MacBrowserLayout.railItemWidth : MacBrowserLayout.sidebarToggleSize, height: railHeader ? MacBrowserLayout.railItemHeight : MacBrowserLayout.sidebarToggleSize).contentShape(Rectangle())
        }
        .buttonStyle(SidebarToneButtonStyle()).focusable().focused($sidebarHeaderToggleFocused)
        .keyboardShortcut("s", modifiers: [.command, .option])
        .help(controller.sidebar.peeking ? "Keep Sidebar Expanded (⌥⌘S)" : railHeader ? "Expand Sidebar (⌥⌘S)" : "Collapse to Icon Rail (⌥⌘S)")
        .accessibilityLabel(controller.sidebar.peeking ? "Keep Sidebar Expanded" : railHeader ? "Expand Sidebar" : "Collapse Sidebar")
        .accessibilityValue(railHeader ? "Icon rail" : "Expanded")
        .accessibilityHint("Toggle sidebar with Option-Command-S")
        .accessibilityIdentifier("sidebarToggle")
        .browserGeometryMarker("sidebarToggleGeometry")
        .browserGeometryMarker("sidebarToggleKeyboardFocus", when: sidebarHeaderToggleFocused)
        .onKeyPress(.downArrow) {
            sidebarTabs.focus(session.selectedTabID)
            return .handled
        }
        .accessibilitySortPriority(2)
        .foregroundStyle(theme.text)
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
        HStack(spacing: OrivSpacing.small) {
            GlassEffectContainer(spacing: OrivMacV3.ToolbarLayout.groupGap) {
                navigationControls
            }
            .frame(width: toolbarSideWidth, alignment: .leading)
            Spacer(minLength: .zero)
            addressCapsule
            Spacer(minLength: .zero)
            GlassEffectContainer(spacing: OrivMacV3.ToolbarLayout.groupGap) {
                trailingControls
            }
            .frame(width: toolbarSideWidth, alignment: .trailing)
        }
        .padding(.horizontal, OrivMacV3.ToolbarLayout.paddingHorizontal)
        .frame(height: MacBrowserLayout.headerHeight)
        .background(alignment: .top) { toolbarScrollEdge }
        .background(BrowserDragRegion())
        .accessibilityIdentifier("mainTopBar")
        .browserGeometryMarker("browserTopBarGeometry")
    }

    @ViewBuilder private var toolbarScrollEdge: some View {
        if requiresSolidScrollEdge {
            Rectangle()
                .fill(OrivMacV3.Toolbar.scrollEdge(v3Mode, tint: v3Mode == .black || isPrivateWindow || isStartPage ? nil : pageChrome.color, solid: true))
                .frame(height: MacBrowserLayout.headerHeight)
                .allowsHitTesting(false)
                .browserGeometryMarker("browserSolidScrollEdgeGeometry")
        } else if pageChrome.hasScrolled && !hasPageTopBars && !isStartPage {
            Rectangle()
                .fill(OrivMacV3.Toolbar.scrollEdge(v3Mode, tint: isPrivateWindow ? nil : pageChrome.color, solid: false))
                .frame(height: MacBrowserLayout.headerHeight + OrivMacV3.Toolbar.scrollEdgeFadeExtension)
                .allowsHitTesting(false)
                .browserGeometryMarker("browserSoftScrollEdgeGeometry")
        }
    }

    private var toolbarGroupDivider: some View {
        Rectangle()
            .fill(OrivMacV3.Toolbar.divider(v3Mode, increasedContrast: increasedContrast))
            .frame(width: OrivMacV3.ToolbarLayout.dividerSize.width, height: OrivMacV3.ToolbarLayout.dividerSize.height)
            .padding(.horizontal, OrivMacV3.ToolbarLayout.dividerMarginHorizontal)
            .accessibilityHidden(true)
    }

    private var navigationControls: some View {
        HStack(spacing: OrivMacV3.ToolbarLayout.groupGap) {
            ToolbarButton(label: "Back", symbol: "chevron.backward", help: "Back (⌘[)") { tab?.goBack() }
                .disabled(tab?.canGoBack != true)
            toolbarGroupDivider
            ToolbarButton(label: "Forward", symbol: "chevron.forward", help: "Forward (⌘])") { tab?.goForward() }
                .disabled(tab?.canGoForward != true)
        }
        .padding(OrivMacV3.ToolbarLayout.groupPadding)
        .frame(height: OrivMacV3.ToolbarLayout.groupHeight)
        .modifier(OptionalForegroundStyle(color: usesOpaqueToolbar ? toolbarInk : nil))
        .orivV3Glass(OrivMacV3.Toolbar.groupTint(v3Mode), in: Capsule())
        .orivV3Shadow(OrivMacV3.Toolbar.groupShadow(v3Mode))
        .browserGeometryMarker("browserNavGroupGeometry")
    }

    private var addressCapsule: some View {
        @Bindable var ui = self.ui
        let placeholder = tab?.isPrivate == true ? OrivStrings.privateSearch : OrivStrings.addressPlaceholder
        let recipe = addressFocused
            ? OrivMacV3.Address.focusFill(v3Mode)
            : (addressHovered ? OrivMacV3.Address.hoverFill(v3Mode) : OrivMacV3.Address.restFill(v3Mode))
        return AddressBarLayout(centered: !addressFocused && compactAddress != nil, spacing: OrivSpacing.xs) {
            addressLeadingControls
            AddressField(text: $ui.address, isEditing: $addressFocused,
                         placeholder: placeholder, displayText: compactAddress,
                         foreground: usesOpaqueToolbar ? toolbarInk : nil, showsNativePlaceholder: false,
                         focusRequest: controller.activeAddressFocusRequest,
                         profileEpoch: controller.sidebarDragID, focusStillValid: { controller.session.isProfileActive }, submit: {
                if ui.addressMatches.query == ui.address, let index = ui.addressMatches.selected, suggestions.indices.contains(index) {
                    chooseSuggestion(suggestions[index])
                    return true
                }
                controller.navigate(ui.address)
                return controller.addressError == nil
            }, cancel: { syncAddress() }, completion: ui.addressMatches.completion,
                         hasSelectedSuggestion: ui.addressMatches.selected != nil && ui.addressMatches.query == ui.address,
                         moveSelection: { ui.addressMatches.move($0) })
                .frame(idealWidth: compactAddressWidth, maxWidth: compactAddressWidth ?? .infinity)
                .frame(height: OrivMacV3.ToolbarLayout.addressInlineIconSize)
                .overlay(alignment: .leading) {
                    if ui.address.isEmpty && (addressFocused || compactAddress == nil) {
                        Text(placeholder).font(OrivType.body).foregroundStyle(toolbarSecondaryInk)
                            .lineLimit(1).truncationMode(.tail)
                            .browserGeometryMarker("browserAddressPlaceholderGeometry")
                            .padding(.leading, OrivSpacing.xxs)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
            addressTrailingControls
        }
        .padding(.horizontal, OrivMacV3.ToolbarLayout.addressRestPaddingHorizontal)
        .frame(height: OrivMacV3.ToolbarLayout.addressRestHeight)
        .frame(minWidth: OrivMacV3.ToolbarLayout.addressMinWidth, idealWidth: addressWidth, maxWidth: addressWidth)
        .background { AddressCapsuleHitArea { controller.focusAddress() } }
        .modifier(OptionalForegroundStyle(color: usesOpaqueToolbar ? toolbarInk : nil))
        .orivV3Glass(recipe, in: Capsule())
        .overlay(alignment: .bottomLeading) {
            AddressProgressBar(
                isLoading: tab?.isLoading == true,
                progress: tab?.progress ?? 0,
                mode: v3Mode,
                solid: requiresSolidScrollEdge,
                reduceMotion: reduceMotion
            )
            .clipShape(Capsule())
        }
        .overlay {
            if addressFocused {
                if increasedContrast {
                    OrivMacV3.CapsuleBorder(
                        color: OrivMacV3.Focus.addressRing(v3Mode, increasedContrast: true),
                        lineWidth: OrivMacV3.Focus.addressRingWidth(increasedContrast: true)
                    )
                } else {
                    OrivMacV3.CapsuleBorder(
                        color: OrivMacV3.Address.focusHalo(v3Mode),
                        lineWidth: OrivMacV3.Focus.addressHaloWidth,
                        inset: -OrivMacV3.Focus.addressHaloWidth
                    )
                }
            }
        }
        .orivV3Shadow(addressFocused ? OrivMacV3.Address.focusShadow(v3Mode) : OrivMacV3.Address.restShadow(v3Mode))
        .onHover { addressHovered = $0 }
        .anchorPreference(key: MacAddressBounds.self, value: .bounds) { $0 }
        .browserGeometryMarker("browserAddressGeometry")
        .browserGeometryMarker("browserAddressFocusedGeometry", when: addressFocused)
    }

    private var addressLeadingControls: some View {
        @Bindable var ui = self.ui
        return HStack(spacing: OrivSpacing.xs) {
            if tab?.isPrivate == true {
                let pill = OrivMacV3.Address.privatePillStyle(mode: v3Mode, solid: requiresSolidScrollEdge, increasedContrast: increasedContrast)
                HStack(spacing: OrivMacV3.ToolbarLayout.privatePillGap) {
                    Image(systemName: "eyeglasses")
                    Text("Private")
                }
                .font(OrivMacV3.Typography.sectionLabel)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, OrivMacV3.ToolbarLayout.privatePillPaddingHorizontal)
                .frame(height: OrivMacV3.ToolbarLayout.privatePillHeight)
                .foregroundStyle(pill.ink)
                .background(pill.fill, in: Capsule())
                .overlay { OrivMacV3.CapsuleBorder(color: pill.border, lineWidth: pill.borderWidth) }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Private browsing")
                .browserGeometryMarker("privateAddressPillGeometry")
            }
            if let tab, tab.url != nil {
                let cue = ConnectionCue(tab)
                let cueColor: Color? = (usesOpaqueToolbar || cue == .notSecure || cue == .recording) ? cue.color(theme) : nil
                Button { ui.showSiteInfo.toggle() } label: {
                    HStack(spacing: OrivSpacing.xs) {
                        Image(systemName: cue.symbol).font(OrivIcon.toolbarFont)
                            .frame(width: OrivTarget.macMinimum.width)
                        if cue == .notSecure { Text(cue.label).font(OrivType.detail.weight(.medium)).fixedSize() }
                    }
                    .frame(height: OrivTarget.macMinimum.height)
                    .contentShape(Rectangle())
                }
                .buttonStyle(ToolbarButtonStyle(active: ui.showSiteInfo))
                .modifier(OptionalForegroundStyle(color: cueColor))
                .accessibilityLabel("\(cue.label). Site information and permissions")
                .help("Site information and permissions")
                .browserGeometryMarker("browserSiteInformationGeometry")
                .background {
                    BrowserPopover(isPresented: $ui.showSiteInfo) {
                        SiteInformationView(session: session, tab: tab).environment(\.colorScheme, colorScheme)
                    }
                }
            } else {
                Image(systemName: "magnifyingglass").font(OrivIcon.toolbarFont)
                    .frame(width: OrivTarget.macMinimum.width, height: OrivTarget.macMinimum.height)
                    .modifier(OptionalForegroundStyle(color: usesOpaqueToolbar ? toolbarSecondaryInk : nil))
                    .accessibilityHidden(true).allowsHitTesting(false)
                    .browserGeometryMarker("browserAddressSearchIconGeometry")
            }
        }
    }

    private var addressTrailingControls: some View {
        HStack(spacing: OrivSpacing.xxs) {
            if let tab, tab.url != nil {
                if tab.pageZoom != 1 {
                    Button { tab.resetZoom() } label: {
                        Text("\(Int(tab.pageZoom * 100))%").font(OrivType.caption.monospacedDigit())
                            .padding(.horizontal, OrivSpacing.xs)
                            .frame(minWidth: OrivTarget.macMinimum.width, minHeight: OrivTarget.macMinimum.height)
                    }
                    .buttonStyle(ToolbarButtonStyle())
                    .modifier(OptionalForegroundStyle(color: usesOpaqueToolbar ? toolbarSecondaryInk : nil))
                    .accessibilityLabel("Reset Page Zoom")
                    .accessibilityValue("\(Int(tab.pageZoom * 100)) percent")
                    .help("Reset Page Zoom")
                    .browserGeometryMarker("browserZoomGeometry")
                }
                Button { tab.isLoading ? tab.stop() : tab.reload() } label: {
                    Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise").font(OrivIcon.toolbarFont)
                        .frame(width: OrivTarget.macMinimum.width, height: OrivTarget.macMinimum.height)
                }
                .buttonStyle(ToolbarButtonStyle())
                .modifier(OptionalForegroundStyle(color: usesOpaqueToolbar ? toolbarSecondaryInk : nil))
                .accessibilityLabel(tab.isLoading ? "Stop loading" : "Reload page")
                .help(tab.isLoading ? "Stop loading" : "Reload (⌘R)")
                .browserGeometryMarker("browserReloadGeometry")
            } else {
                Spacer(minLength: .zero).frame(width: OrivTarget.macMinimum.width).accessibilityHidden(true)
            }
        }
    }

    // Site privacy, share, and browser actions share one trailing glass capsule.
    private var trailingControls: some View {
        @Bindable var ui = self.ui
        return HStack(spacing: OrivMacV3.ToolbarLayout.groupGap) {
            if reservesToolbarPasswordKey {
                ToolbarButton(label: "AutoFill from Passwords", symbol: "key.fill", action: fillPassword)
                    .opacity(canFillPassword ? 1 : 0)
                    .disabled(!canFillPassword)
                    .allowsHitTesting(canFillPassword)
                    .accessibilityHidden(!canFillPassword)
                    .browserGeometryMarker("browserPasswordGeometry")
                if canFillPassword { toolbarGroupDivider }
            }
            if showsToolbarDownloads && showsExpandedToolbarActions {
                ToolbarButton(label: "Downloads in progress", symbol: "arrow.down.circle.fill",
                              help: "View downloads in progress", active: true) { controller.library = .downloads }
                toolbarGroupDivider
            }
            ToolbarButton(label: OrivStrings.sitePrivacy, symbol: "shield.lefthalf.filled", active: ui.showProtection) {
                ui.showProtection.toggle()
            }
            .overlay(alignment: .topTrailing) {
                if siteProtectionsActive {
                    Circle()
                        .fill(OrivMacV3.Toolbar.shieldDot(v3Mode))
                        .frame(width: OrivMacV3.ToolbarLayout.shieldDotSize, height: OrivMacV3.ToolbarLayout.shieldDotSize)
                        .background {
                            Circle()
                                .fill(OrivMacV3.Toolbar.shieldDotRing(v3Mode))
                                .padding(-OrivMacV3.Toolbar.shieldDotRingWidth)
                        }
                        .padding(.top, OrivMacV3.ToolbarLayout.shieldDotInset)
                        .padding(.trailing, OrivMacV3.ToolbarLayout.shieldDotInset)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .browserGeometryMarker("browserPrivacyActiveDotGeometry")
                }
            }
            .accessibilityIdentifier("sitePrivacyButton")
            .browserGeometryMarker("browserPrivacyGeometry")
            .background {
                BrowserPopover(isPresented: $ui.showProtection) {
                    AdBlockingPopover(session: session)
                        .environment(\.colorScheme, colorScheme)
                }
            }
            if showsExpandedToolbarActions, let url = tab?.url {
                toolbarGroupDivider
                ShareLink(item: URLCleaner.clean(url)) {
                    Image(systemName: "square.and.arrow.up").font(OrivIcon.toolbarFont)
                        .frame(width: OrivTarget.macToolbar.width, height: OrivTarget.macToolbar.height)
                }
                .buttonStyle(ToolbarButtonStyle()).help("Share Page").accessibilityLabel("Share Page")
                .browserGeometryMarker("browserShareGeometry")
            }
            toolbarGroupDivider
            toolbarMenu
        }
        .padding(OrivMacV3.ToolbarLayout.groupPadding)
        .frame(height: OrivMacV3.ToolbarLayout.groupHeight)
        .modifier(OptionalForegroundStyle(color: usesOpaqueToolbar ? toolbarInk : nil))
        .orivV3Glass(OrivMacV3.Toolbar.groupTint(v3Mode), in: Capsule())
        .orivV3Shadow(OrivMacV3.Toolbar.groupShadow(v3Mode))
        .browserGeometryMarker("browserActionsGroupGeometry")
    }

    private var toolbarMenu: some View {
        @Bindable var ui = self.ui
        let fillAction: (() -> Void)? = canFillPassword ? { fillPassword() } : nil
        let menu = MacPageMenu(active: ui.showPasswords) {
            MacPageActions(controller: controller, profiles: profiles,
                findOnPage: { ui.showFind = true; findFocused = true },
                showSitePrivacy: { ui.showProtection = true },
                fillPassword: fillAction, showPasswordsGuide: { showPasswordHelp() },
                requestSiteForget: { ui.siteToForget = $0 })
        } label: {
            Image(systemName: "ellipsis").font(OrivIcon.toolbarFont)
                .frame(width: MacBrowserLayout.pageMenuTarget.width, height: MacBrowserLayout.pageMenuTarget.height)
        }
        return menu
        .help("Browser Actions").accessibilityLabel("Browser Actions")
        .accessibilityIdentifier("browserPageMenu")
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
        .sheet(item: $controller.library) { section in
            LibraryView(controller: controller, profiles: profiles, section: section)
        }
        .sheet(isPresented: Binding(get: { profiles?.showManager == true }, set: { profiles?.showManager = $0 }), onDismiss: { profiles?.finishProfileSheet() }) {
            if let profiles { ProfilesSheet(profiles: profiles) }
        }
        .alert("Couldn’t complete profile action", isPresented: Binding(get: { profiles?.error != nil }, set: { if !$0 { profiles?.error = nil } })) {
            Button("OK") { profiles?.error = nil }
        } message: { Text(profiles?.error ?? "") }
        .sheet(item: $controller.readerCapture) { capture in ReaderTextView(capture: capture) }
        .sheet(isPresented: $controller.showWebsiteData) { WebsiteDataView(manager: session.websiteData) }
        .sheet(isPresented: $controller.showClearBrowsingData) { ClearBrowsingDataView(session: session) }
        .alert(controller.browserError?.title ?? "", isPresented: Binding(
            get: { controller.browserError != nil }, set: { if !$0 { controller.browserError = nil } }
        ), presenting: controller.browserError) { _ in
            Button("OK") { controller.browserError = nil }
        } message: { Text($0.message) }
        .forgetSiteAlert($ui.siteToForget, session: session) {
            controller.browserError = BrowserActionError(title: "Couldn’t forget site", message: $0)
        }
    }

    private var routedContent: some View {
        panels
        .alert("Unable to open address", isPresented: Binding(get: { controller.addressError != nil }, set: { if !$0 { controller.addressError = nil } })) {
            Button("OK") { controller.addressError = nil }
        } message: { Text(controller.addressError ?? "") }
    }

    private var page: some View {
        @Bindable var ui = self.ui
        let topInset = webpageFullscreen ? 0 : MacBrowserLayout.headerHeight
        return VStack(spacing: 0) {
                if hasPageTopBars {
                    VStack(spacing: .zero) {
                        if showsExternalPrivateBar, let profiles {
                            ExternalPrivateBar(sourceName: profiles.externalSourceName, profiles: profiles.available,
                                selection: Binding(get: { profiles.externalMoveProfileID }, set: { profiles.externalMoveProfileID = $0 }),
                                canMove: ExternalLinkRouting.movableURL(tab?.url) != nil,
                                move: { profiles.perform { try profiles.moveExternalTab() } }, dismiss: { profiles.externalBannerVisible = false })
                        }
                        if session.canUndoBookmarkRemoval {
                            OrivBanner(message: "Bookmark removed", dismiss: { session.dismissBookmarkUndo() }) {
                                Button("Undo") { session.undoBookmarkRemoval() }.orivButton(.link)
                            }
                        }
                        if let notice = profiles?.continuity.notice { ContinuityNotice(text: notice) }
                        if let notice = controller.browserNotice {
                            OrivBanner(notice, tone: .success, dismiss: { controller.browserNotice = nil })
                        }
                        if let notice = session.persistenceNotice {
                            OrivBanner(notice, tone: .warning, symbol: "externaldrive.badge.exclamationmark",
                                       dismiss: session.canPersist ? { session.dismissNotice() } : nil)
                        }
                        if ui.showFind {
                            findBar
                            Divider()
                        }
                    }
                    .padding(.top, topInset)
                }
                if let tab {
                    ZStack(alignment: .top) {
                        tabContent(tab)
                        if tab.httpWarningURL != nil {
                            HTTPFallbackView(tab: tab)
                                .padding(.top, hasPageTopBars ? 0 : topInset)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(theme.canvas)
                        }
                        if let error = tab.errorMessage {
                            PageErrorState(message: error, host: tab.url?.host, retry: tab.reload)
                                .padding(.top, hasPageTopBars ? 0 : topInset)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(OrivMacV3.Card.fill(v3Mode), ignoresSafeAreaEdges: [])
    }

    private var findBar: some View {
        @Bindable var ui = self.ui
        return HStack(spacing: OrivSpacing.small) {
            OrivSearchField(text: $ui.findText, focused: findFocused, clearLabel: "Clear find query",
                            onClear: { tab?.clearFind(); findFocused = true }) {
                TextField("Find in page", text: $ui.findText)
                    .foregroundStyle(theme.text)
                    .focused($findFocused)
                    .onSubmit { tab?.find(ui.findText, caseSensitive: ui.findCaseSensitive) }
                    .onExitCommand(perform: closeFindBar)
            }
            if tab?.findResult == false, !ui.findText.isEmpty {
                Text("No match").font(OrivType.caption).foregroundStyle(theme.textSecondary)
            }
            Toggle("Match case", isOn: $ui.findCaseSensitive).toggleStyle(.checkbox)
            ToolbarButton(label: "Find previous", symbol: "chevron.up") {
                tab?.find(ui.findText, backwards: true, caseSensitive: ui.findCaseSensitive)
            }.disabled(ui.findText.isEmpty)
            ToolbarButton(label: "Find next", symbol: "chevron.down") {
                tab?.find(ui.findText, caseSensitive: ui.findCaseSensitive)
            }.disabled(ui.findText.isEmpty)
            ToolbarButton(label: "Close find bar", symbol: "xmark", action: closeFindBar)
        }
        .padding(.horizontal, OrivSpacing.medium)
        .padding(.vertical, OrivSpacing.xs)
        .background(theme.surface)
        .browserGeometryMarker("browserFindBarGeometry")
    }

    private func closeFindBar() {
        ui.showFind = false
        findFocused = false
        tab?.clearFind()
    }

    @ViewBuilder private func tabContent(_ tab: BrowserTab) -> some View {
        let webHeaderInset = (webpageFullscreen || hasPageTopBars) ? 0 : MacBrowserLayout.headerHeight
        if tab.isResettingSiteData {
            Color.clear
        } else if tab.url != nil || tab.hasLoaded {
            WebPageView(tab: tab, chrome: pageChrome, contentUnderChrome: contentUnderChrome, headerInset: webHeaderInset, profileTransition: profiles?.sidebarSwitch.isPresenting(controller.profile?.id) == true, profileEpoch: controller.sidebarDragID, fullscreenChanged: { controller.sidebar.fullscreen($0) })
                .scrollEdgeEffectStyle(.soft, for: .top)
        }
        else {
            StartPage(controller: controller, isPrivate: tab.isPrivate)
                .padding(.top, webHeaderInset)
                .scrollEdgeEffectStyle(.soft, for: .top)
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


}

private struct MacAddressBounds: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = nextValue() ?? value }
}

private struct OptionalForegroundStyle: ViewModifier {
    let color: Color?

    @ViewBuilder func body(content: Content) -> some View {
        if let color { content.foregroundStyle(color) }
        else { content }
    }
}

/// Keeps the compact host optically centered in the capsule even when leading
/// ("Not secure", Private pill) and trailing (zoom, reload) controls differ in
/// width, while clamping cleanly on narrow windows and filling during editing.
private struct AddressBarLayout: Layout {
    let centered: Bool
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? OrivMacV3.ToolbarLayout.addressRestHeight
        return CGSize(width: proposal.width ?? OrivMacV3.ToolbarLayout.addressRestWidth, height: proposal.height ?? height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let leadingSize = subviews[0].sizeThatFits(.unspecified)
        let trailingSize = subviews[2].sizeThatFits(.unspecified)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: leadingSize.width, height: bounds.height))
        subviews[2].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing,
                          proposal: ProposedViewSize(width: trailingSize.width, height: bounds.height))
        let minFieldX = bounds.minX + leadingSize.width + spacing
        let maxFieldRight = bounds.maxX - trailingSize.width - spacing
        let available = max(0, maxFieldRight - minFieldX)
        if centered {
            let fieldSize = subviews[1].sizeThatFits(ProposedViewSize(width: available, height: bounds.height))
            let width = min(fieldSize.width, available)
            let idealX = bounds.midX - width / 2
            let clampedX = min(max(idealX, minFieldX), max(minFieldX, maxFieldRight - width))
            subviews[1].place(at: CGPoint(x: clampedX, y: bounds.midY), anchor: .leading,
                              proposal: ProposedViewSize(width: width, height: fieldSize.height))
        } else {
            let fieldSize = subviews[1].sizeThatFits(ProposedViewSize(width: available, height: bounds.height))
            subviews[1].place(at: CGPoint(x: minFieldX, y: bounds.midY), anchor: .leading,
                              proposal: ProposedViewSize(width: available, height: fieldSize.height))
        }
    }
}

/// Integrated 2 pt loading progress line tucked along the inside bottom edge of
/// the address capsule, animating width smoothly and fading out on completion.
private struct AddressProgressBar: View {
    @Environment(\.browserTheme) private var theme
    let isLoading: Bool
    let progress: Double
    let mode: OrivMacV3.AppearanceMode
    let solid: Bool
    let reduceMotion: Bool
    @State private var displayedProgress: Double = 0
    @State private var visible = false
    @State private var opacity: Double = 0
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            OrivMacV3.Card.fillStartPage
            if visible {
                GeometryReader { proxy in
                    let trackWidth = max(0, proxy.size.width - 2 * OrivMacV3.ToolbarLayout.progressHorizontalInset)
                    let fillWidth = trackWidth * max(0.03, min(1, displayedProgress))
                    Group {
                        if solid {
                            Capsule().fill(theme.accent)
                        } else {
                            Capsule()
                                .fill(OrivMacV3.Address.progressBar(mode))
                                .orivV3Shadow(OrivMacV3.Address.progressGlow(mode))
                        }
                    }
                    .frame(width: fillWidth, height: OrivMacV3.ToolbarLayout.progressHeight)
                    .padding(.horizontal, OrivMacV3.ToolbarLayout.progressHorizontalInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
                .opacity(opacity)
                .browserGeometryMarker("browserAddressProgressGeometry")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Loading page")
                .accessibilityValue("\(Int(max(0, min(1, progress)) * 100)) percent")
                .accessibilityHidden(!isLoading)
            }
        }
        .allowsHitTesting(false)
        .onAppear { syncState(loading: isLoading, value: progress, animated: false) }
        .onChange(of: isLoading) { _, loading in syncState(loading: loading, value: progress, animated: true) }
        .onChange(of: progress) { _, value in
            guard isLoading else { return }
            withAnimation(OrivMacV3.Motion.progressShimmer(reduceMotion: reduceMotion)) {
                displayedProgress = max(0.03, min(1, value))
            }
        }
        .onDisappear { hideTask?.cancel(); hideTask = nil }
    }

    private func syncState(loading: Bool, value: Double, animated: Bool) {
        hideTask?.cancel()
        hideTask = nil
        if loading {
            visible = true
            opacity = 1
            let clamped = max(0.03, min(1, value))
            if animated {
                withAnimation(OrivMacV3.Motion.progressShimmer(reduceMotion: reduceMotion)) {
                    displayedProgress = clamped
                }
            } else {
                displayedProgress = clamped
            }
        } else if visible {
            if reduceMotion || !animated {
                visible = false
                opacity = 0
                displayedProgress = 0
            } else {
                withAnimation(OrivMacV3.Motion.progressShimmer(reduceMotion: false)) {
                    displayedProgress = 1
                }
                withAnimation(OrivMacV3.Motion.standard) {
                    opacity = 0
                }
                hideTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(220))
                    guard !Task.isCancelled, !isLoading else { return }
                    visible = false
                    displayedProgress = 0
                }
            }
        }
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
                    SectionHeader(title: match.source.rawValue)
                        .padding(.horizontal, OrivSpacing.medium).padding(.top, OrivSpacing.xs)
                }
                Button { choose(match) } label: {
                    AddressSuggestionRow(suggestion: match, query: address, isPrivate: isPrivate)
                        .padding(.horizontal, OrivLayout.rowInset).frame(height: OrivLayout.suggestionRowHeight).contentShape(Rectangle())
                        .modifier(ListSelection(selected: selectedIndex == index))
                }.buttonStyle(.plain).accessibilityAddTraits(selectedIndex == index ? [.isSelected] : [])
            }
            // Snapshot/noninteractive callers can still supply local matches.
            if !suggestions.contains(where: { $0.source == .search }) {
                Button { choose(BrowserSuggestion(title: "Search for ‘\(address)’", url: engine.searchURL(address), source: .search)) } label: {
                    Label("Search for ‘\(address)’", systemImage: "magnifyingglass")
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(theme.text).padding(.horizontal, OrivLayout.rowInset).frame(height: OrivLayout.controlHeight).frame(maxWidth: .infinity, alignment: .leading)
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
                host.sizingOptions.insert(.preferredContentSize)
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
