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
    @State private var inlineCompletionActive = false
    @State private var startAddressSlot: CGRect? = nil
    @State private var addressMorphOpacity: Double = 1
    @State private var addressMorphFadeTask: Task<Void, Never>?
    @State private var addressMorphStartedAt: Date?
    @Namespace private var addressMorphNamespace
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
    private var isPrivateTab: Bool { tab?.isPrivate == true }
    private var v3Mode: OrivMacV3.AppearanceMode {
        OrivMacV3.AppearanceMode.resolve(theme: theme, colorScheme: colorScheme, isPrivateWindow: isPrivateWindow)
    }
    private var isStartPage: Bool { tab?.url == nil && tab?.hasLoaded != true }
    private var startPageMode: OrivMacV3.AppearanceMode { isPrivateTab ? .private : v3Mode }
    private var effectiveAddressMode: OrivMacV3.AppearanceMode { (isStartPage && isPrivateTab) ? .private : v3Mode }
    private var usesEmbeddedPrivateStartCard: Bool { isStartPage && isPrivateTab && !isPrivateWindow }
    private var increasedContrast: Bool { contrast == .increased }
    private var usesReducedBackdrop: Bool { reduceTransparency || captureReduceTransparency || increasedContrast || theme.isT3Code }
    private var usesOpaqueToolbar: Bool {
        OrivMacV3.usesOpaqueSurface(theme: theme, reduceTransparency: reduceTransparency,
                                    captureReduceTransparency: captureReduceTransparency, contrast: contrast)
    }
    private var requiresSolidScrollEdge: Bool {
        reduceTransparency || captureReduceTransparency || increasedContrast || v3Mode == .black || theme.isT3Code
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
    private static let pageCardSpace = "browserPageCard"
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
    private var showsAddressSuggestions: Bool {
        addressFocused && !ui.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var addressWidth: CGFloat {
        let cardWidth = max(0, windowWidth - controller.sidebar.reservation - cardInset)
        let reserved = 2 * (OrivMacV3.ToolbarLayout.paddingHorizontal + toolbarSideWidth + OrivSpacing.small)
        let ideal = addressFocused ? OrivMacV3.ToolbarLayout.addressFocusWidth : OrivMacV3.ToolbarLayout.addressRestWidth
        return min(ideal, max(OrivMacV3.ToolbarLayout.addressMinWidth, cardWidth - reserved))
    }
    private var addressHeight: CGFloat {
        addressFocused ? OrivMacV3.ToolbarLayout.addressFocusHeight : OrivMacV3.ToolbarLayout.addressRestHeight
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
                addressFocused = false; endAddressEditing(); syncAddress()
                ui.showFind = false; ui.showSiteInfo = false; ui.showProtection = false
            }
            .onChange(of: controller.scoped(tab?.url)) { old, new in
                if old.owner == new.owner, !addressFocused { syncAddress() }
            }
            .onChange(of: isStartPage) { _, onStart in
                // Keep the last measured slot: returning to a start page then has its exact
                // target in the first frame instead of an estimate corrected mid-travel.
                addressMorphStartedAt = Date()
                addressMorphFadeTask?.cancel()
                addressMorphFadeTask = nil
                if reduceMotion && !BackgroundUIMode.isEnabled {
                    // Snap geometry without travel, then run the <= 0.15 s reduced opacity fade.
                    var instant = Transaction()
                    instant.animation = nil
                    withTransaction(instant) { addressMorphOpacity = 0.2 }
                    addressMorphFadeTask = Task { @MainActor in
                        await Task.yield()
                        guard !Task.isCancelled else { return }
                        withAnimation(OrivMacV3.Motion.addressMorph(reduceMotion: true)) {
                            addressMorphOpacity = 1
                        }
                    }
                } else if addressMorphOpacity != 1 {
                    addressMorphOpacity = 1
                }
            }
            .onChange(of: addressFocused) { _, focused in
                if !focused { inlineCompletionActive = false }
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
            .onDisappear {
                addressMorphFadeTask?.cancel()
                addressMorphFadeTask = nil
                pageChrome.observe(nil)
            }
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
                    startPage: isStartPage && !usesEmbeddedPrivateStartCard,
                    profileColor: activeProfileColor,
                    reduced: usesReducedBackdrop
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            ZStack(alignment: .top) {
                page
                if showsAddressSuggestions && !webpageFullscreen {
                    addressSuggestionsScrim
                        .zIndex(0.5)
                        .transition(.opacity)
                }
                mainTopBar.zIndex(1)
                    .opacity(webpageFullscreen ? 0 : 1)
                    .allowsHitTesting(!webpageFullscreen)
                    .accessibilityHidden(webpageFullscreen)
            }
            // The start page reports its address slot in this space, which is the
            // overlay's own origin, so top bars above the start page are included.
            .coordinateSpace(name: Self.pageCardSpace)
            .overlay {
                GeometryReader { cardProxy in
                    let startRect = startAddressSlot
                    let useStartSlot = isStartPage && !webpageFullscreen
                    let targetWidth: CGFloat = {
                        if useStartSlot {
                            if let startRect, startRect.width > 0 { return startRect.width }
                            return OrivMacV3.StartLayout.columnWidth(for: cardProxy.size.width)
                        }
                        return addressWidth
                    }()
                    let targetHeight: CGFloat = useStartSlot
                        ? OrivMacV3.StartLayout.bigFieldSize.height
                        : addressHeight
                    let leading: CGFloat = {
                        if useStartSlot, let startRect, startRect.width > 0 {
                            return layoutDirection == .rightToLeft ? cardProxy.size.width - startRect.maxX : startRect.minX
                        }
                        return (cardProxy.size.width - targetWidth) / 2
                    }()
                    let top: CGFloat = {
                        if useStartSlot, let startRect, startRect.width > 0 {
                            return startRect.minY
                        }
                        if useStartSlot {
                            return OrivMacV3.StartLayout.bigFieldTop(for: cardProxy.size, hasTopBars: hasPageTopBars)
                        }
                        return (MacBrowserLayout.headerHeight - targetHeight) / 2
                    }()
                    GlassEffectContainer(spacing: OrivMacV3.ToolbarLayout.groupGap) {
                        addressCapsule(isBigField: useStartSlot, width: targetWidth, height: targetHeight)
                            .glassEffectID("addressCapsule", in: addressMorphNamespace)
                            .glassEffectTransition(reduceMotion ? .identity : .matchedGeometry)
                            .padding(.leading, max(0, leading))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .offset(y: top)
                            .opacity(webpageFullscreen ? 0 : addressMorphOpacity)
                            .allowsHitTesting(!webpageFullscreen)
                            .accessibilityHidden(webpageFullscreen)
                            // Key morph travel strictly on `isStartPage` so start-page layout and
                            // window resizing never lag; under Reduce Motion geometry snaps instantly.
                            .animation(OrivMacV3.Motion.addressMorphGeometry(reduceMotion: reduceMotion), value: isStartPage)
                            .animation(OrivMacV3.Motion.addressFocus(reduceMotion: reduceMotion), value: addressFocused)
                    }
                }
            }
            .animation(OrivMacV3.Motion.standard(reduceMotion: reduceMotion), value: showsAddressSuggestions)
            .background {
                if !isStartPage {
                    OrivMacV3.Card.fill(v3Mode)
                } else if usesEmbeddedPrivateStartCard {
                    OrivMacV3.Backdrop.BackdropView(mode: .private, startPage: true, reduced: usesReducedBackdrop)
                } else {
                    OrivMacV3.Card.fillStartPage
                }
            }
            .clipShape(cardShape)
            .overlay {
                if !webpageFullscreen {
                    cardShape.strokeBorder(
                        OrivMacV3.Card.rim(usesEmbeddedPrivateStartCard ? .private : v3Mode, increasedContrast: contrast == .increased),
                        lineWidth: contrast == .increased ? OrivOutline.enhanced : OrivOutline.hairline
                    )
                    .allowsHitTesting(false)
                }
            }
            .browserGeometryMarker("browserPageCardGeometry")
            .orivV3Shadow(webpageFullscreen || (isStartPage && !usesEmbeddedPrivateStartCard) ? .none : OrivMacV3.Card.elevation(v3Mode))
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
            let sidebarAnimation: Animation? = controller.sidebar.isResizing || previous.owner != next.owner
                ? nil
                : (previous.value.peeking || next.value.peeking
                   ? OrivMacV3.Motion.quick(reduceMotion: reduceMotion)
                   : OrivMacV3.Motion.standardGeometry(reduceMotion: reduceMotion))
            withAnimation(sidebarAnimation) {
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
            darkWindowControls: isPrivateWindow,
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
                    .transition(.opacity)
            }
        }
        .animation(OrivMacV3.Motion.popover(reduceMotion: reduceMotion), value: controller.tabSearchPanel)
        .overlayPreferenceValue(MacAddressBounds.self) { anchor in
            GeometryReader { geometry in
                if let anchor, showsAddressSuggestions {
                    let rect = geometry[anchor]
                    let leading = layoutDirection == .rightToLeft ? geometry.size.width - rect.maxX : rect.minX
                    addressSuggestions.frame(width: rect.width)
                        .environment(\.v3AppearanceMode, effectiveAddressMode)
                        .environment(\.colorScheme, effectiveAddressMode.isDark ? .dark : colorScheme)
                        .browserGeometryMarker("browserAddressSuggestionsGeometry")
                        .padding(.leading, max(0, leading))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .offset(y: rect.maxY + OrivMacV3.ToolbarLayout.suggestionsTopGap)
                        .transition(.opacity)
                }
            }
            .animation(OrivMacV3.Motion.popover(reduceMotion: reduceMotion), value: showsAddressSuggestions)
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
        .foregroundStyle(isPrivateWindow ? OrivMacV3.Ink.secondary(v3Mode, increasedContrast: increasedContrast) : theme.text)
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
            OrivMacV3.Card.fillStartPage
                .frame(minWidth: OrivMacV3.ToolbarLayout.addressMinWidth, idealWidth: addressWidth, maxWidth: addressWidth, maxHeight: OrivOutline.hairline)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
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
        if !isStartPage {
            if requiresSolidScrollEdge {
                Rectangle()
                    .fill(OrivMacV3.Toolbar.scrollEdge(v3Mode, tint: v3Mode == .black || isPrivateWindow ? nil : pageChrome.color, solid: true))
                    .frame(height: MacBrowserLayout.headerHeight)
                    .allowsHitTesting(false)
                    .browserGeometryMarker("browserSolidScrollEdgeGeometry")
            } else if pageChrome.hasScrolled && !hasPageTopBars {
                Rectangle()
                    .fill(OrivMacV3.Toolbar.scrollEdge(v3Mode, tint: isPrivateWindow ? nil : pageChrome.color, solid: false))
                    .frame(height: MacBrowserLayout.headerHeight + OrivMacV3.Toolbar.scrollEdgeFadeExtension)
                    .allowsHitTesting(false)
                    .browserGeometryMarker("browserSoftScrollEdgeGeometry")
            }
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

    /// The focus state alone does not stop AppKit's field editor: without this, a tab
    /// switch leaves the toolbar showing the full URL with a live selection.
    private func endAddressEditing() {
        guard let window = windowContext.window,
              let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
              editor.delegate is FocusAwareAddressField else { return }
        window.makeFirstResponder(nil)
    }

    private func addressCapsule(isBigField: Bool, width: CGFloat, height: CGFloat) -> some View {
        @Bindable var ui = self.ui
        let mode = effectiveAddressMode
        let placeholder = isPrivateTab ? OrivStrings.privateSearch : OrivStrings.addressPlaceholder
        let recipe: OrivMacV3.GlassRecipe = isBigField
            ? OrivMacV3.StartPage.bigFieldFill(mode, focused: addressFocused)
            : (addressFocused
               ? OrivMacV3.Address.focusFill(mode)
               : (addressHovered ? OrivMacV3.Address.hoverFill(mode) : OrivMacV3.Address.restFill(mode)))
        let leadingPadding = isBigField
            ? OrivMacV3.StartLayout.bigFieldLeadingPadding
            : (addressFocused ? OrivMacV3.ToolbarLayout.addressFocusLeadingPadding : OrivMacV3.ToolbarLayout.addressRestPaddingHorizontal)
        let trailingPadding = isBigField
            ? OrivMacV3.StartLayout.bigFieldTrailingPadding
            : (addressFocused ? OrivMacV3.ToolbarLayout.addressFocusTrailingPadding : OrivMacV3.ToolbarLayout.addressRestPaddingHorizontal)
        let layoutSpacing = isBigField
            ? OrivMacV3.StartLayout.bigFieldGap
            : (addressFocused ? OrivMacV3.ToolbarLayout.addressFocusGap : OrivSpacing.xs)
        let fieldHeight = isBigField ? OrivMacV3.StartLayout.bigFieldTextHeight : OrivMacV3.ToolbarLayout.addressInlineIconSize
        let explicitInk: Color? = (usesOpaqueToolbar || (isBigField && isPrivateTab)) ? OrivMacV3.Ink.primary(mode) : nil
        let placeholderFont = isBigField
            ? OrivMacV3.Typography.startBigField
            : (addressFocused ? OrivMacV3.Typography.addressFocused : OrivType.body)
        let placeholderInk = isBigField
            ? OrivMacV3.StartPage.bigFieldPlaceholderInk(mode, increasedContrast: increasedContrast)
            : OrivMacV3.Ink.secondary(mode, increasedContrast: increasedContrast)
        let focusRingColor = isBigField
            ? OrivMacV3.StartPage.bigFieldFocusBorder(mode, increasedContrast: true)
            : OrivMacV3.Focus.addressRing(mode, increasedContrast: true)
        let focusHaloColor = isBigField
            ? OrivMacV3.StartPage.bigFieldFocusHalo(mode)
            : OrivMacV3.Address.focusHalo(mode)
        let shadow = isBigField
            ? OrivMacV3.StartPage.bigFieldShadow(mode)
            : (addressFocused ? OrivMacV3.Address.focusShadow(mode) : OrivMacV3.Address.restShadow(mode))
        return AddressBarLayout(centered: !isBigField && !addressFocused && compactAddress != nil, spacing: layoutSpacing) {
            addressLeadingControls(isBigField: isBigField, mode: mode)
            AddressField(text: $ui.address, isEditing: $addressFocused,
                         placeholder: placeholder, displayText: isBigField ? nil : compactAddress,
                         foreground: explicitInk, isBigField: isBigField, showsNativePlaceholder: false,
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
                         moveSelection: { ui.addressMatches.move($0) },
                         onInlineCompletionChange: { inlineCompletionActive = $0 })
                .frame(idealWidth: isBigField ? nil : compactAddressWidth, maxWidth: isBigField ? .infinity : (compactAddressWidth ?? .infinity))
                .frame(height: fieldHeight)
                .overlay(alignment: .leading) {
                    if ui.address.isEmpty && (addressFocused || isBigField || compactAddress == nil) {
                        Text(placeholder).font(placeholderFont).foregroundStyle(placeholderInk)
                            .lineLimit(1).truncationMode(.tail)
                            .browserGeometryMarker("browserAddressPlaceholderGeometry")
                            .padding(.leading, OrivSpacing.xxs)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
            addressTrailingControls(isBigField: isBigField, mode: mode)
        }
        .padding(.leading, leadingPadding)
        .padding(.trailing, trailingPadding)
        .frame(width: width, height: height)
        .background { AddressCapsuleHitArea { controller.focusAddress() } }
        .modifier(OptionalForegroundStyle(color: explicitInk))
        .orivV3Glass(recipe, in: Capsule())
        .overlay(alignment: .bottomLeading) {
            AddressProgressBar(
                isLoading: !isBigField && tab?.isLoading == true,
                progress: tab?.progress ?? 0,
                mode: mode,
                solid: requiresSolidScrollEdge,
                reduceMotion: reduceMotion
            )
            .clipShape(Capsule())
        }
        .overlay {
            if addressFocused {
                if increasedContrast {
                    OrivMacV3.CapsuleBorder(
                        color: focusRingColor,
                        lineWidth: OrivMacV3.Focus.addressRingWidth(increasedContrast: true)
                    )
                } else {
                    OrivMacV3.CapsuleBorder(
                        color: focusHaloColor,
                        lineWidth: OrivMacV3.Focus.addressHaloWidth,
                        inset: -OrivMacV3.Focus.addressHaloWidth
                    )
                }
            }
        }
        .orivV3Shadow(shadow)
        .environment(\.v3AppearanceMode, mode)
        .environment(\.colorScheme, mode.isDark ? .dark : colorScheme)
        .onHover { addressHovered = $0 }
        .anchorPreference(key: MacAddressBounds.self, value: .bounds) { $0 }
        .browserGeometryMarker("browserAddressGeometry")
        .browserGeometryMarker("browserAddressFocusedGeometry", when: addressFocused)
    }

    private func addressLeadingControls(isBigField: Bool, mode: OrivMacV3.AppearanceMode) -> some View {
        @Bindable var ui = self.ui
        return HStack(spacing: OrivSpacing.xs) {
            if isPrivateTab {
                let pill = OrivMacV3.Address.privatePillStyle(mode: mode, solid: requiresSolidScrollEdge, increasedContrast: increasedContrast)
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
            if isBigField {
                if !isPrivateTab {
                    Image(systemName: "magnifyingglass").font(OrivMacV3.Typography.startBigFieldSearchIcon)
                        .foregroundStyle(OrivMacV3.Ink.secondary(mode, increasedContrast: increasedContrast))
                        .frame(width: OrivMacV3.StartLayout.privateCardIconSize, height: OrivTarget.macMinimum.height)
                        .accessibilityHidden(true).allowsHitTesting(false)
                        .browserGeometryMarker("browserAddressSearchIconGeometry")
                }
            } else if addressFocused {
                Image(systemName: "magnifyingglass").font(OrivMacV3.Typography.addressFocusSearchIcon)
                    .foregroundStyle(OrivMacV3.Address.focusSearchIconInk(mode, increasedContrast: increasedContrast))
                    .frame(width: OrivMacV3.ToolbarLayout.addressFocusIconWidth, height: OrivTarget.macMinimum.height)
                    .accessibilityHidden(true).allowsHitTesting(false)
                    .browserGeometryMarker("browserAddressSearchIconGeometry")
            } else if let tab, tab.url != nil {
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

    private func addressTrailingControls(isBigField: Bool, mode: OrivMacV3.AppearanceMode) -> some View {
        HStack(spacing: OrivSpacing.xs) {
            if addressFocused {
                if inlineCompletionActive {
                    let chipShape = RoundedRectangle(cornerRadius: OrivMacV3.Radius.tabHint, style: .continuous)
                    Text("Tab")
                        .font(OrivMacV3.Typography.shortcutHintBold)
                        .foregroundStyle(OrivMacV3.Address.tabHintInk(mode, increasedContrast: increasedContrast))
                        .padding(.horizontal, OrivMacV3.ToolbarLayout.addressTabHintPaddingHorizontal)
                        .padding(.vertical, OrivMacV3.ToolbarLayout.addressTabHintPaddingVertical)
                        .background(OrivMacV3.Address.tabHintFill(mode, solid: requiresSolidScrollEdge), in: chipShape)
                        .overlay {
                            chipShape.strokeBorder(
                                OrivMacV3.Address.tabHintBorder(mode, increasedContrast: increasedContrast),
                                lineWidth: increasedContrast ? OrivOutline.enhanced : OrivOutline.hairline
                            )
                        }
                        .fixedSize()
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .browserGeometryMarker("browserAddressTabHintGeometry")
                }
                if !ui.address.isEmpty {
                    Button {
                        ui.address = ""
                        inlineCompletionActive = false
                        controller.focusAddress()
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(OrivIcon.toolbarFont)
                            .foregroundStyle(OrivMacV3.Address.clearIconInk(mode, increasedContrast: increasedContrast))
                            .frame(width: OrivTarget.macMinimum.width, height: OrivTarget.macMinimum.height)
                            .contentShape(Circle())
                    }
                    .buttonStyle(ToolbarButtonStyle())
                    .accessibilityLabel("Clear address")
                    .help("Clear address")
                    .browserGeometryMarker("browserAddressClearGeometry")
                } else if isBigField {
                    startPageEngineChip(mode: mode)
                }
            } else if isBigField {
                startPageEngineChip(mode: mode)
            } else if let tab, tab.url != nil {
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

    private func startPageEngineChip(mode: OrivMacV3.AppearanceMode) -> some View {
        HStack(spacing: OrivMacV3.StartLayout.engineChipGap) {
            Image(systemName: "magnifyingglass")
                .font(OrivMacV3.Typography.detail)
            Text(session.settings.searchEngine.rawValue)
                .font(OrivMacV3.Typography.detail)
        }
        .foregroundStyle(OrivMacV3.Ink.secondary(mode, increasedContrast: increasedContrast))
        .padding(.horizontal, OrivMacV3.StartLayout.engineChipPaddingHorizontal)
        .frame(height: OrivMacV3.StartLayout.engineChipHeight)
        .background(OrivMacV3.StartPage.engineChipFill(mode, solid: usesOpaqueToolbar), in: OrivMacV3.Radius.capsule)
        .fixedSize()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .browserGeometryMarker("startPageEngineChipGeometry")
    }

    private var addressSuggestionsScrim: some View {
        OrivMacV3.Suggestions.scrim(effectiveAddressMode, increasedContrast: increasedContrast)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay { AddressScrimHitArea { dismissAddressEditing() } }
            .accessibilityHidden(true)
            .browserGeometryMarker("browserAddressScrimGeometry", when: !increasedContrast)
    }

    private func dismissAddressEditing() {
        addressFocused = false
        inlineCompletionActive = false
        windowContext.window?.makeFirstResponder(nil)
        syncAddress()
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
                VStack(spacing: .zero) {
                    if showsExternalPrivateBar, let profiles {
                        ExternalPrivateBar(sourceName: profiles.externalSourceName, profiles: profiles.available,
                            selection: Binding(get: { profiles.externalMoveProfileID }, set: { profiles.externalMoveProfileID = $0 }),
                            canMove: ExternalLinkRouting.movableURL(tab?.url) != nil,
                            move: { profiles.perform { try profiles.moveExternalTab() } }, dismiss: { profiles.externalBannerVisible = false })
                            .transition(.opacity)
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
                        VStack(spacing: .zero) {
                            findBar
                            Divider()
                        }
                        .transition(.opacity)
                    }
                }
                .padding(.top, hasPageTopBars ? topInset : .zero)
                .animation(OrivMacV3.Motion.popover(reduceMotion: reduceMotion), value: showsExternalPrivateBar)
                .animation(OrivMacV3.Motion.standard(reduceMotion: reduceMotion), value: ui.showFind)
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
            .background(isStartPage ? OrivMacV3.Card.fillStartPage : OrivMacV3.Card.fill(v3Mode), ignoresSafeAreaEdges: [])
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
            StartPage(session: session, isPrivate: tab.isPrivate, profile: profiles?.active ?? controller.profile, hasTopBars: hasPageTopBars, openLibrary: { controller.library = $0 }, onAddressSlotChange: { rect in
                guard startAddressSlot != rect else { return }
                // A measurement that lands while the field is travelling retargets the same
                // motion; outside it (window resizing) the field follows without lag.
                let travelling = addressMorphStartedAt.map {
                    Date().timeIntervalSince($0) < OrivMacV3.Motion.addressMorphRetargetWindow
                } ?? false
                withAnimation(travelling ? OrivMacV3.Motion.addressMorphGeometry(reduceMotion: reduceMotion) : nil) {
                    startAddressSlot = rect
                }
            }, addressSlotSpace: Self.pageCardSpace)
                .overlay {
                    HomeProfileFade(epoch: controller.sidebarDragID,
                                    color: OrivMacV3.Card.fillStartPageSolid(startPageMode),
                                    startsOnMount: profiles?.sidebarSwitch.isPresenting(controller.profile?.id) == true,
                                    reduceMotion: reduceMotion)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .transition(.opacity.animation(OrivMacV3.Motion.startPageFade(reduceMotion: reduceMotion)))
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
                    try? await Task.sleep(for: .milliseconds(OrivMacV3.Motion.progressFinishDelayMilliseconds))
                    guard !Task.isCancelled, !isLoading else { return }
                    visible = false
                    displayedProgress = 0
                }
            }
        }
    }
}

/// The address field's floating Liquid Glass suggestion popover.
struct AddressSuggestionList: View {
    @Environment(\.browserTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.v3AppearanceMode) private var inheritedMode
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.chromeContrastOverride) private var captureContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.chromeReduceTransparencyOverride) private var captureReduceTransparency
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var hoveredID: URL?

    let suggestions: [BrowserSuggestion]
    let selectedIndex: Int?
    let address: String
    let engine: SearchEngine
    let isPrivate: Bool
    let choose: (BrowserSuggestion) -> Void
    let submit: () -> Void

    private var mode: OrivMacV3.AppearanceMode {
        if inheritedMode == .private { return .private }
        return OrivMacV3.AppearanceMode.resolve(theme: theme, colorScheme: colorScheme, isPrivateWindow: false)
    }

    private var contrast: ColorSchemeContrast { captureContrast ?? systemContrast }
    private var increasedContrast: Bool { contrast == .increased }
    private var usesSolid: Bool {
        OrivMacV3.usesOpaqueSurface(theme: theme, reduceTransparency: reduceTransparency,
                                    captureReduceTransparency: captureReduceTransparency, contrast: contrast)
    }

    private var displayedRows: [(index: Int?, match: BrowserSuggestion)] {
        var rows: [(Int?, BrowserSuggestion)] = suggestions.enumerated().map { ($0.offset, $0.element) }
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, !suggestions.contains(where: { $0.source == .search }) {
            rows.append((nil, BrowserSuggestion(title: "Search for ‘\(trimmed)’", url: engine.searchURL(trimmed), source: .search)))
        }
        return rows
    }

    var body: some View {
        let rows = displayedRows
        let popoverShape = RoundedRectangle(cornerRadius: OrivMacV3.Radius.sidebar, style: .continuous)
        return VStack(alignment: .leading, spacing: .zero) {
            ForEach(Array(rows.enumerated()), id: \.element.match.id) { position, item in
                let match = item.match
                let isSelected = item.index != nil && selectedIndex == item.index
                let isHovered = hoveredID == match.id
                let startsGroup = position == 0 || rows[position - 1].match.source != match.source

                if position > 0 && startsGroup {
                    Rectangle()
                        .fill(OrivMacV3.Suggestions.divider(mode, increasedContrast: increasedContrast))
                        .frame(height: increasedContrast ? OrivOutline.enhanced : OrivOutline.hairline)
                        .padding(.horizontal, OrivMacV3.ToolbarLayout.suggestionRowPaddingHorizontal)
                        .padding(.vertical, OrivMacV3.ToolbarLayout.suggestionDividerPaddingVertical)
                        .accessibilityHidden(true)
                }

                if startsGroup && match.source != .search {
                    Text(match.source.rawValue)
                        .font(OrivMacV3.Typography.sectionLabel)
                        .tracking(OrivMacV3.Typography.labelTracking)
                        .foregroundStyle(OrivMacV3.Suggestions.headerInk(mode, increasedContrast: increasedContrast))
                        .padding(.top, OrivMacV3.ToolbarLayout.suggestionGroupPaddingTop)
                        .padding(.bottom, OrivMacV3.ToolbarLayout.suggestionGroupPaddingBottom)
                        .padding(.horizontal, OrivMacV3.ToolbarLayout.suggestionRowPaddingHorizontal)
                        .accessibilityAddTraits(.isHeader)
                }

                Button { choose(match) } label: {
                    rowContent(for: match, selected: isSelected, hovered: isHovered)
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside { hoveredID = match.id }
                    else if hoveredID == match.id { hoveredID = nil }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                .modifier(SuggestionAddressAccessibility(url: match.source == .search ? nil : match.url))
            }
        }
        .padding(OrivMacV3.ToolbarLayout.suggestionsPadding)
        .orivV3Glass(OrivMacV3.Popover.glassFill(mode), in: popoverShape)
        .orivV3Shadow(OrivMacV3.Popover.elevation(mode))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Address suggestions")
    }

    @ViewBuilder
    private func rowContent(for match: BrowserSuggestion, selected: Bool, hovered: Bool) -> some View {
        let isSearch = match.source == .search
        let rowRadius = isSearch ? OrivMacV3.Radius.sidebarSearch : OrivMacV3.Radius.row
        let rowShape = RoundedRectangle(cornerRadius: rowRadius, style: .continuous)
        let targetHeight = isSearch ? OrivMacV3.ToolbarLayout.suggestionSearchRowHeight : OrivMacV3.ToolbarLayout.suggestionRowHeight
        Group {
            if isSearch {
                searchRowBody(match, selected: selected)
            } else {
                matchRowBody(match, selected: selected)
            }
        }
        .padding(.horizontal, OrivMacV3.ToolbarLayout.suggestionRowPaddingHorizontal)
        .frame(minHeight: targetHeight, maxHeight: typeSize.isAccessibilitySize ? nil : targetHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if selected {
                rowShape.fill(OrivMacV3.Suggestions.selectedFill(mode, solid: usesSolid))
                    .overlay {
                        if !increasedContrast, let highlight = OrivMacV3.Suggestions.selectedTopHighlight(mode) {
                            rowShape.inset(by: OrivOutline.hairline)
                                .stroke(
                                    LinearGradient(colors: [highlight, .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.14)),
                                    lineWidth: OrivOutline.hairline
                                )
                        }
                    }
                    .overlay {
                        rowShape.strokeBorder(
                            OrivMacV3.Suggestions.selectedBorder(mode, increasedContrast: increasedContrast),
                            lineWidth: increasedContrast ? OrivOutline.focus : OrivOutline.hairline
                        )
                    }
            } else if hovered {
                rowShape.fill(OrivMacV3.Suggestions.rowHover(mode, solid: usesSolid))
            }
        }
        .contentShape(rowShape)
    }

    private func matchRowBody(_ match: BrowserSuggestion, selected: Bool) -> some View {
        let title = match.title.isEmpty ? (URLDisplay.site(match.url) ?? "Page") : match.title
        let titleInk = selected ? OrivMacV3.Suggestions.selectedTitleInk(mode) : OrivMacV3.Ink.primary(mode)
        let urlInk = selected ? OrivMacV3.Suggestions.selectedURLInk(mode) : OrivMacV3.Ink.secondary(mode, increasedContrast: increasedContrast)
        return HStack(spacing: OrivMacV3.ToolbarLayout.suggestionRowGap) {
            SiteIdentity(url: match.url, size: OrivMacV3.ToolbarLayout.suggestionIconSize, isPrivate: isPrivate, isSelected: selected)
            VStack(alignment: .leading, spacing: OrivMacV3.ToolbarLayout.suggestionTextGap) {
                suggestionText(title, query: address)
                    .font(OrivMacV3.Typography.sidebarRow)
                    .foregroundStyle(titleInk)
                    .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                suggestionText(displayAddress(for: match.url), query: address)
                    .font(OrivMacV3.Typography.suggestionURL)
                    .foregroundStyle(urlInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: OrivMacV3.ToolbarLayout.suggestionChipGap) {
                if match.tabID != nil {
                    alreadyOpenPill
                }
                if selected {
                    returnKeyChip
                }
            }
        }
    }

    private func searchRowBody(_ match: BrowserSuggestion, selected: Bool) -> some View {
        let iconShape = RoundedRectangle(cornerRadius: OrivMacV3.Radius.profileAvatar, style: .continuous)
        let titleInk = selected ? OrivMacV3.Suggestions.selectedTitleInk(mode) : OrivMacV3.Ink.primary(mode)
        let symbolInk = selected ? OrivMacV3.Suggestions.selectedTitleInk(mode) : OrivMacV3.Ink.secondary(mode, increasedContrast: increasedContrast)
        let engineInk = selected ? OrivMacV3.Suggestions.selectedURLInk(mode) : OrivMacV3.Suggestions.enginePillInk(mode, increasedContrast: increasedContrast)
        return HStack(spacing: OrivMacV3.ToolbarLayout.suggestionRowGap) {
            ZStack {
                iconShape.fill(OrivMacV3.Suggestions.searchIconFill(mode, selected: selected))
                Image(systemName: "magnifyingglass")
                    .font(OrivMacV3.Typography.suggestionSearchSymbol)
                    .foregroundStyle(symbolInk)
            }
            .frame(width: OrivMacV3.ToolbarLayout.suggestionIconSize, height: OrivMacV3.ToolbarLayout.suggestionIconSize)
            .accessibilityHidden(true)

            suggestionText(match.title, query: address)
                .font(OrivMacV3.Typography.sidebarRow)
                .foregroundStyle(titleInk)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: OrivMacV3.ToolbarLayout.suggestionChipGap) {
                Text(engine.rawValue)
                    .font(OrivMacV3.Typography.suggestionEnginePill)
                    .foregroundStyle(engineInk)
                    .padding(.horizontal, OrivMacV3.ToolbarLayout.suggestionEnginePillPaddingHorizontal)
                    .padding(.vertical, OrivMacV3.ToolbarLayout.suggestionEnginePillPaddingVertical)
                    .background(OrivMacV3.Suggestions.enginePillFill(mode, solid: usesSolid), in: Capsule())
                    .fixedSize()
                if selected {
                    returnKeyChip
                }
            }
        }
    }

    private var alreadyOpenPill: some View {
        HStack(spacing: OrivSpacing.xs) {
            Image(systemName: "arrow.right")
                .font(OrivMacV3.Typography.suggestionAlreadyOpenArrow)
                .accessibilityHidden(true)
            Text(OrivStrings.alreadyOpen)
                .font(OrivMacV3.Typography.shortcutHintBold)
        }
        .foregroundStyle(OrivMacV3.Suggestions.alreadyOpenPillInk(mode))
        .padding(.horizontal, OrivMacV3.ToolbarLayout.suggestionAlreadyOpenPaddingHorizontal)
        .padding(.vertical, OrivMacV3.ToolbarLayout.suggestionAlreadyOpenPaddingVertical)
        .background(OrivMacV3.Suggestions.alreadyOpenPillFill(mode, solid: usesSolid), in: Capsule())
        .overlay {
            OrivMacV3.CapsuleBorder(
                color: OrivMacV3.Suggestions.alreadyOpenPillBorder(mode, increasedContrast: increasedContrast),
                lineWidth: increasedContrast ? OrivOutline.enhanced : OrivOutline.hairline
            )
        }
        .fixedSize()
    }

    private var returnKeyChip: some View {
        let shape = RoundedRectangle(cornerRadius: OrivMacV3.Radius.accessory, style: .continuous)
        return Text("↵")
            .font(OrivMacV3.Typography.sectionLabel)
            .foregroundStyle(OrivMacV3.Suggestions.returnKeyChipInk(mode))
            .padding(.horizontal, OrivMacV3.ToolbarLayout.suggestionReturnChipPaddingHorizontal)
            .padding(.vertical, OrivMacV3.ToolbarLayout.suggestionReturnChipPaddingVertical)
            .background(OrivMacV3.Suggestions.returnKeyChipFill(mode, solid: usesSolid), in: shape)
            .overlay {
                shape.strokeBorder(
                    OrivMacV3.Suggestions.returnKeyChipBorder(mode, increasedContrast: increasedContrast),
                    lineWidth: increasedContrast ? OrivOutline.enhanced : OrivOutline.hairline
                )
            }
            .orivV3Shadow(OrivMacV3.Suggestions.returnKeyChipShadow(mode))
            .fixedSize()
            .accessibilityHidden(true)
    }

    private func displayAddress(for url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.user = nil
        components?.password = nil
        let value = components?.string ?? url.absoluteString
        return value.replacingOccurrences(of: "^https?://", with: "", options: .regularExpression)
    }
}

private struct SuggestionAddressAccessibility: ViewModifier {
    let url: URL?
    @ViewBuilder func body(content: Content) -> some View {
        if let url { content.accessibilityCustomContent(Text("Address"), Text(verbatim: url.absoluteString)) }
        else { content }
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
        anchor.reduceMotion = context.environment.browserReduceMotion
        let root = AnyView(content().environment(\.self, context.environment))
        anchor.update(root)
    }

    static func dismantleNSView(_ anchor: Anchor, coordinator: ()) { anchor.close() }

    final class Anchor: NSView, NSPopoverDelegate {
        var isPresented: Binding<Bool> = .constant(false)
        var reduceMotion = false {
            didSet { popover?.animates = !BackgroundUIMode.isEnabled && !reduceMotion }
        }
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
                popover.animates = !BackgroundUIMode.isEnabled && !reduceMotion
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
