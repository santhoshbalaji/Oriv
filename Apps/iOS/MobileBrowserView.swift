import SwiftUI
import BrowserCore
import BrowserEngine
import WebKit

struct MobileBrowserView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.browserTheme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var controller: MobileController
    let profiles: MobileProfiles
    @State private var address = ""
    @State private var siteToForget: BrowserSite?
    @State private var editingAddress = false
    @State private var addressMatches = AddressSuggestions()
    @State private var nativeFinding = false
    @State private var keyboardOverlap:CGFloat = 0
    @State private var consumedFocusRequest = 0
    @State private var gestures = MobileChromeGestureState()
    private var pageChrome: PageChrome { controller.chrome(for: tab) }
    @State private var minimized = false
    @State private var barHeight: CGFloat = 64
    @State private var pageSystemScheme: ColorScheme = .light
    @State private var transitionGeneration = 0
    @State private var gridOrigin: MobileGridRestingState?
    @State private var restoringGridState = false
    @State private var gridPrepared = false
    @State private var swipeHandoff:UUID?
    @State private var fallbackDestinationID:UUID?
    @State private var fallbackPreparation:UUID?
    @State private var fallbackReady = false
    @State private var fallbackPaintRevision:Int?
    private var swipe:MobileTabSwipe { controller.tabSwipe }
    private var liveTabs:[BrowserTab] {
        controller.session.tabs.filter {
            ($0.id == controller.session.selectedTabID || $0.id == swipe.destinationID || $0.id == fallbackDestinationID) &&
                $0.isInstantiated && $0.url != nil && $0.errorMessage == nil && $0.httpWarningURL == nil
        }
    }
    private var solidChrome: Bool { reduceTransparency || contrast == .increased }
    private var extendsTopColor: Bool { solidChrome || !pageChrome.showsContentUnderChrome }
    private var displayDomain: String { tab?.url.flatMap(URLDisplay.site) ?? (tab?.isPrivate == true ? OrivStrings.privateSearch : OrivStrings.search) }
    private var bottomForeground: Color { .primary }
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    var reduceMotionOverride:Bool? = nil
    private var reduceMotion:Bool { reduceMotionOverride ?? systemReduceMotion }
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    private var tab: BrowserTab? { controller.session.selectedTab }
    private var showsExternalPrivateBar: Bool { controller.session.isExternalPrivate && profiles.externalBannerVisible }
    private var profileName: String { profiles.profiles.first { $0.id == controller.profileID }?.name ?? "External Private Tabs" }

    private var presentation: MobileTabPresentation { controller.tabPresentation }
    private var bottomOcclusion:CGFloat { max(windowInsets.bottom,keyboardOverlap) }
    private var hasLivePage: Bool { tab?.url != nil && tab?.errorMessage == nil && tab?.httpWarningURL == nil }
    private var homeColor: ChromeColor {
        let systemScheme = tab?.url == nil ? colorScheme : pageSystemScheme
        return PageChrome.resolveCanvas(theme.canvas, scheme: controller.appearance.colorScheme ?? systemScheme)
    }
    private var statusScheme:ColorScheme? {
        if tab?.url == nil { return controller.appearance.colorScheme }
        let dark = controller.topChrome.isDark
        // Seed the first hosting pass from known paint, before the native fill
        // attaches. Avoid an artificial dark-to-light trait change at mounting.
        if !controller.topChrome.hasRendered {
            return editingAddress ? controller.appearance.colorScheme : (topColor(for: tab).whiteForeground ? .dark : .light)
        }
        return dark ? .dark : .light
    }

    private var windowInsets: UIEdgeInsets {
        if let tab, tab.isInstantiated, let window = tab.webView.window { return window.safeAreaInsets }
        return (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.keyWindow?.safeAreaInsets ?? .zero
    }
    private var barContentVersion:[AnyHashable]? {
        // Geometry and WebKit progress must not rebuild the bar's separate
        // SwiftUI graph. Native history/address providers read current state
        // when opened; document revisions refresh the remaining menu content.
        guard !editingAddress else { return nil }
        return [AnyHashable(tab?.id),AnyHashable(tab?.url),AnyHashable(tab?.isPrivate),
            AnyHashable(tab?.documentRevision),AnyHashable(tab?.title),AnyHashable(tab?.isPinned),AnyHashable(tab?.httpWarningURL),
            AnyHashable(tab?.isLoading),AnyHashable(tab?.isSecure),AnyHashable(tab?.errorMessage),
            AnyHashable(tab?.canGoBack),AnyHashable(tab?.canGoForward),AnyHashable(tab?.pageZoom),
            AnyHashable(controller.session.tabs.count),AnyHashable(controller.session.tabsInSelectedMode.count),
            AnyHashable(controller.session.isBookmarked(tab?.url)),AnyHashable(controller.session.canReopenTab),
            AnyHashable(controller.downloads.hasActivity),AnyHashable(minimized),
            AnyHashable(pageChrome.isDark),AnyHashable(pageSystemScheme == .dark),AnyHashable(solidChrome),
            AnyHashable(reduceMotion),AnyHashable(String(describing:typeSize)),AnyHashable(controller.appearance.rawValue),
            AnyHashable(showsExternalPrivateBar),AnyHashable(profiles.externalMoveProfileID),
            AnyHashable(profiles.externalPrivate?.profileID),
            AnyHashable(profiles.profiles.map(\.id)),AnyHashable(profiles.profiles.map(\.name)),
            AnyHashable(profiles.profiles.map { $0.symbol.rawValue }),
            AnyHashable(profiles.profiles.map { $0.archivedAt != nil })]
    }
    var body: some View {
        GeometryReader { geometry in
            let full = CGRect(origin:.zero,size:geometry.size)
            let id = presentation.activeID
            let isLive = !reduceMotion && id != nil && id == tab?.id && presentation.pendingNewTab == nil && tab?.url != nil && tab?.isInstantiated == true && tab?.isRestoringWebView != true
            let global = id.flatMap { presentation.cardFrames[$0] } ?? (presentation.pendingNewTab != nil
                ? CGRect(x:24,y:geometry.size.height-78,width:44,height:44)
                : CGRect(x:16,y:geometry.safeAreaInsets.top+60,width:(geometry.size.width-48)/2,height:geometry.size.height*0.35))
            let origin = geometry.frame(in:.global).origin
            let card = global.offsetBy(dx:-origin.x,dy:-origin.y)
            ZStack {
                theme.canvas.ignoresSafeArea()
                ForEach(liveTabs) { surface in
                    livePage(surface, top:geometry.safeAreaInsets.top, bottom:geometry.safeAreaInsets.bottom,
                             card:card, progress:isLive && surface.id == tab?.id ? gestures.gridProgress : 0)
                        .onChange(of:surface.documentRevision) { _,_ in
                            if surface.id == fallbackDestinationID {
                                fallbackPreparation = UUID(); fallbackReady = false; fallbackPaintRevision = nil
                            }
                        }
                        .opacity(editingAddress ? 0 : (reduceMotion ? 1-gestures.gridProgress : (isLive || gestures.gridProgress == 0 ? 1 : 0)))
                        .offset(x:reduceMotion ? 0 : gestures.translation)
                        .allowsHitTesting(surface.id == tab?.id && !swipe.isActive && !editingAddress && gestures.gridProgress == 0 && controller.sheet == nil)
                        .zIndex(isLive && presentation.liveReady ? 2 : (swipe.isActive && surface.id == swipe.sourceID ? 1 : 0))
                }
                if swipe.isActive {
                    MobileSwipeBacking(swipe:swipe,background:UIColor(controller.chrome(for:controller.session.tabs.first { $0.id == swipe.destinationID }).color))
                        .allowsHitTesting(false).accessibilityHidden(true).zIndex(3)
                }
                browser
                    .opacity(hasLivePage ? 1-gestures.gridProgress : (reduceMotion || id == nil ? 1 : 0))
                    .offset(x:reduceMotion ? 0 : geometry.size.width*presentation.insertionProgress)
                    .opacity(reduceMotion ? 1-presentation.insertionProgress : 1)
                    .allowsHitTesting(gestures.source != nil || (controller.sheet != .tabs && !gestures.gridClosing))
                    .accessibilityHidden(gestures.gridProgress > 0 || controller.sheet == .tabs)
                    .zIndex(hasLivePage ? 4 : 0)
                if gridPrepared || gestures.gridProgress > 0 || controller.sheet == .tabs || id != nil {
                    MobileTabsView(controller:controller,profiles:profiles,dismissGrid:closeGrid,onPull:pullGrid,onPinch:pinchGrid,presented:controller.sheet == .tabs && !gestures.gridClosing,visible:controller.sheet == .tabs || gestures.gridProgress > 0 || gestures.gridClosing || id != nil,reduceMotionOverride:reduceMotionOverride)
                        .browserAppearance(controller.appearance,followsPage:true)
                        .environment(\.colorScheme,gestures.gridProgress > 0 || controller.sheet == .tabs ? (controller.appearance.colorScheme ?? pageSystemScheme) : (pageChrome.isDark ? .dark : .light))
                        .opacity(gestures.gridProgress)
                        .allowsHitTesting(controller.sheet == .tabs && !gestures.gridClosing)
                        .accessibilityHidden(controller.sheet != .tabs || gestures.gridClosing)
                }
                if !reduceMotion, let id, !isLive {
                    MobilePageMorph(image:presentation.images[id],full:full,card:card,progress:gestures.gridProgress,reduceMotion:false,background:theme.canvas)
                        .allowsHitTesting(false).accessibilityHidden(true).zIndex(3)
                }
                if isLive && gestures.gridProgress == 1 {
                    // The real page remains in its card until its one final
                    // thumbnail is ready. Keep the grid's close affordance visible.
                    Image(systemName:"xmark").font(.system(size:12,weight:.semibold)).foregroundStyle(.secondary)
                        .frame(width:22,height:22).modifier(OrivMaterial.control())
                        .position(x:card.maxX-22,y:card.minY+22)
                        .allowsHitTesting(false).accessibilityHidden(true).zIndex(4)
                }
            }
            .onChange(of:geometry.size) { old, new in if old != new { cancelTransition() } }
        }.ignoresSafeArea()
            .background { MobileGridProgressView(morph:controller.gridMorph).frame(width:1,height:1).allowsHitTesting(false).accessibilityHidden(true) }
            .onChange(of: homeColor, initial: true) { _, color in
                controller.chrome(for: nil).setEmptyPageColor(color)
            }
            .preferredColorScheme(statusScheme)
    }
    private var browserSurface: some View {
        GeometryReader { geometry in
            ZStack {
                pageChrome.color.opacity(hasLivePage && !editingAddress ? 0 : 1).ignoresSafeArea().allowsHitTesting(false)
                    .animation(reduceMotion || !pageChrome.animatesColor ? nil : .easeInOut(duration: 0.2), value: pageChrome.color)
                if editingAddress {
                    suggestions.background(theme.canvas).safeAreaPadding(.bottom,bottomOcclusion+barHeight)
                } else {
                    page(top: max(geometry.safeAreaInsets.top, windowInsets.top), bottom: max(geometry.safeAreaInsets.bottom, windowInsets.bottom) + (nativeFinding ? 0 : barHeight))
                        .opacity(reduceMotion ? 1-min(abs(gestures.translation)/max(geometry.size.width,1),1) : 1)
                        .overlay { swipePreview(width: geometry.size.width) }
                        .offset(x: reduceMotion ? 0 : gestures.translation)
                        .ignoresSafeArea(.container, edges: [.top, .bottom])
                        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
                        .scrollEdgeEffectHidden(reduceTransparency, for: [.top, .bottom])
                        .overlay(alignment: .top) {
                            VStack(spacing: 0) { notices }.padding(.leading,windowInsets.left).padding(.trailing,windowInsets.right)
                        }
                }
            }
            .overlay(alignment:.top) {
                topBar(width:geometry.size.width)
                    .frame(height:max(geometry.safeAreaInsets.top,windowInsets.top))
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }

    private var keyboardBar: some View {
        MobileKeyboardBar(content:{ AnyView(barContent) },contentVersion:barContentVersion,handoff:swipeHandoff,reduceMotion:reduceMotion,
            hidden:nativeFinding || (controller.sheet == .tabs && presentation.activeID == nil && gestures.gridProgress == 1),
            interactive:!gestures.finishingSwipe && (gestures.source != nil || (controller.sheet == nil && !gestures.gridClosing && gestures.gridProgress == 0)),
            accessibilityHidden:gestures.gridProgress > 0 || controller.sheet == .tabs || gestures.gridClosing) { height,occlusion in
                controller.viewportLayout.update(barHeight:height,keyboardOverlap:occlusion,
                    resting:!editingAddress && !minimized && occlusion <= windowInsets.bottom+1)
                if !hasLivePage || editingAddress { barHeight = height; keyboardOverlap = occlusion }
            }
    }

    private var browserLifecycle: some View {
        browserSurface.overlay { keyboardBar }
            .toolbar(.hidden, for: .navigationBar)
            .onDisappear { cancelTransition(); presentation.discard() }
            .task(id:tab?.isLoading) {
                guard tab?.isLoading != true else { return }
                try? await Task.sleep(for:.milliseconds(250))
                if !Task.isCancelled { gridPrepared = true }
            }
            .onAppear { controller.session.activateSelectedTab() }
            .task(id: controller.addressFocusRequest) {
                await Task.yield()
                consumeFocusRequest()
            }
            .onChange(of:controller.session.tabs.map(\.id)) { old, ids in
                // The presentation model can clear activeID before this
                // callback runs. The moving image still owns its identity.
                let removedDuringTransition = gridOrigin != nil && old.contains { !ids.contains($0) }
                let removedSnapshot = controller.gridMorph.tabID.map { !ids.contains($0) } ?? false
                if removedDuringTransition || removedSnapshot { cancelTransition() }
                profiles.finishExternalGroupIfEmpty()
            }
            .onChange(of: tab?.id) { _, _ in
                if gestures.source != nil { cancelTransition() }
                editingAddress = false; nativeFinding = false
                if swipeHandoff != tab?.id { minimized = false }
                swipeHandoff = nil
                controller.trimBackgroundTabs()
                if presentation.inserting && gestures.gridProgress == 0 {
                    presentation.insertionProgress = 1
                    withAnimation(reduceMotion ? .easeInOut(duration:0.18) : .spring(response:0.4,dampingFraction:0.9),completionCriteria:.removed) {
                        presentation.insertionProgress = 0
                    } completion: { presentation.inserting = false; consumeFocusRequest() }
                }
            }
            .onChange(of:tab?.isLoading) { _, loading in
                if loading == false, let tab { presentation.refreshAfterScrolling(tab) }
            }
    }

    private var browserInteractions: some View {
        browserLifecycle
            .onChange(of:scenePhase) { _, phase in if phase != .active { cancelTransition() } }
            .onReceive(NotificationCenter.default.publisher(for:UIApplication.willResignActiveNotification)) { _ in cancelTransition() }
            .onReceive(NotificationCenter.default.publisher(for:UIApplication.didReceiveMemoryWarningNotification)) { _ in cancelTransition() }
            .onChange(of:swipe.isActive) { wasActive, active in
                if wasActive && !active && gestures.source != nil { cancelTransition() }
            }
            .environment(\.siteIcons, controller.session.siteIcons)
            .task(id: "\(address)-\(editingAddress)-\(tab?.id.uuidString ?? "")-\(controller.session.forgottenSiteRevision)") {
                await addressMatches.update(editingAddress ? address : "", session: controller.session, isPrivate: tab?.isPrivate == true)
            }
            .onReceive(NotificationCenter.default.publisher(for:UIResponder.keyboardWillChangeFrameNotification)) { _ in
                if gestures.source != nil || presentation.activeID != nil || gestures.gridClosing { cancelTransition() }
            }
    }

    private var browser: some View {
        browserInteractions
            .onChange(of: controller.sheet, initial: true, sheetChanged)
            .sheet(item: Binding(get: { controller.sheet == .tabs ? nil : controller.sheet }, set: { controller.sheet = $0 }), onDismiss: consumeFocusRequest) { sheet in
                Group {
                    switch sheet {
                    case .tabs: EmptyView()
                    case .library: MobileLibraryView(controller: controller, profiles: profiles)
                    case .bookmarks, .history:
                        NavigationStack {
                            MobileSavedPages(controller: controller, history: sheet == .history)
                                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { controller.sheet = nil } } }
                        }
                    case .settings: NavigationStack { MobileSettingsView(controller: controller, profiles: profiles) }
                    case .site: if let tab { NavigationStack { MobileSiteSettings(session: controller.session, tab: tab) } }
                    case .share: if let tab, let url = tab.url { MobilePageShare(webView: tab.webView, url: URLCleaner.clean(url)) }
                    }
                }.browserAppearance(controller.appearance)
                    .environment(\.siteIcons, controller.session.siteIcons)
            }
            .alert("Unable to complete action", isPresented: Binding(get: { controller.message != nil }, set: { if !$0 { controller.message = nil } })) {
                Button("OK") { controller.message = nil }
            } message: { Text(controller.message ?? "") }
            .forgetSiteAlert($siteToForget, session: controller.session) { controller.message = $0 }
    }

    private func sheetChanged(from oldSheet: MobileSheet?, to sheet: MobileSheet?) {
        gestures.gridPresented = sheet == .tabs
        if restoringGridState {
            restoringGridState = false; gestures.gridProgress = sheet == .tabs ? 1 : 0
            return
        }
        if oldSheet == sheet, sheet == .tabs { gestures.gridProgress = 1; return }
        if sheet == .tabs {
            transitionGeneration += 1; gestures.gridClosing = false
            if gridOrigin == nil { gridOrigin = .page }
            let progress = gestures.gridProgress
            gestures.cancel(); gestures.gridProgress = progress
            if let tab, tab.isInstantiated { tab.webView.findInteraction?.dismissFindNavigator(); tab.webView.endEditing(true) }
            presentation.begin(tab)
            animateGrid(to:1) { gridOrigin = nil; presentation.settleInGrid(tab) }
        }
        else if sheet != nil { cancelTransition() }
        else if !gestures.gridClosing && (gestures.gridProgress > 0 || controller.gridMorph.isAnimating || presentation.activeID != nil) { closeGrid() }
        else if !gestures.gridClosing { consumeFocusRequest() }
    }

    private func consumeFocusRequest() {
        guard controller.sheet == nil, !gestures.gridClosing, gestures.gridProgress == 0, !presentation.inserting,
              controller.addressFocusRequest > consumedFocusRequest else { return }
        consumedFocusRequest = controller.addressFocusRequest
        if tab?.url == nil { beginAddressEditing() }
    }

    @ViewBuilder private var barContent: some View {
        if editingAddress { addressEditor }
        else { bottomChrome.animation(reduceMotion ? nil : .easeInOut(duration:0.2),value:pageChrome.isDark) }
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
                        if tab?.isPrivate == true { Image(systemName: "eyeglasses").foregroundStyle(theme.controlPrivate) }
                        if let tab, ConnectionCue(tab) == .notSecure { Image(systemName: "exclamationmark.triangle") }
                        Text(displayDomain).lineLimit(1)
                    }.font(.caption.weight(.medium)).foregroundStyle(bottomForeground)
                        .padding(.horizontal, 16).frame(minHeight: 32).modifier(OrivMaterial.control())
                        .allowsHitTesting(false).accessibilityHidden(true)
                    MobileAddressMenuSource(controller: controller, profiles: profiles, tab: tab, compact: true) { setMinimized(false) }
                }.frame(height: 44).fixedSize(horizontal: true, vertical: false)
                    .background(capsuleGesture)
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
            .environment(\.colorScheme, controller.appearance.colorScheme ?? pageSystemScheme)
    }

    private var backButton: some View {
        ZStack {
            Image(systemName: "chevron.left").font(.system(size: 21, weight: .medium)).frame(width: 48, height: 48)
                .allowsHitTesting(false).accessibilityHidden(true)
            MobileHistoryMenuSource(tab:tab,forward:false)
        }.frame(width:48,height:48).tint(.primary)
            .disabled(tab?.canGoBack != true).buttonStyle(.plain).modifier(OrivMaterial.control()).accessibilityLabel("Back")
            .accessibilityAction(named: "Show History") { showHistory(forward: false) }
    }

    private var forwardButton: some View {
        ZStack {
            Image(systemName: "chevron.right").font(.system(size: 21, weight: .medium)).frame(width: 44, height: 48)
                .allowsHitTesting(false).accessibilityHidden(true)
            MobileHistoryMenuSource(tab:tab,forward:true)
        }.frame(width:44,height:48).tint(.primary)
            .buttonStyle(.plain).modifier(OrivMaterial.control()).accessibilityLabel("Forward")
            .accessibilityAction(named: "Show History") { showHistory(forward: true) }
    }
    @ViewBuilder private var tabsMenu: some View {
        Button("New Tab", systemImage: "plus") { controller.newTab() }
        Button("New Private Tab", systemImage: "eyeglasses") { controller.newTab(isPrivate: true) }
        Divider()
        Menu("Switch Profile", systemImage: "person.crop.circle") {
            ForEach(profiles.profiles.filter { $0.archivedAt == nil }) { profile in Button(profile.name) { profiles.select(profile) } }
        }
        Divider()
        Button("Close This Tab", systemImage: "xmark", role: .destructive) { if let tab { controller.close([tab.id]) } }
        Button("Close All Tabs", systemImage: "xmark.square", role: .destructive) { controller.closeAllTabs() }
    }

    private var tabsButton: some View {
        Menu {
            tabsMenu
        } label: {
            Image(systemName: "square.on.square").font(.system(size: 21, weight: .medium)).frame(width: 48, height: 48)
        } primaryAction: { controller.sheet = .tabs }
            .menuOrder(.fixed).tint(.primary)
            .buttonStyle(.plain).modifier(OrivMaterial.control())
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
    private func animateGrid(to value: CGFloat, completion: @escaping () -> Void = {}) {
        transitionGeneration += 1
        let request = transitionGeneration
        controller.gridMorph.animate(from:gestures.gridProgress,to:value,reduceMotion:reduceMotion,
            tabID:presentation.activeID,
            update:{ gestures.gridProgress = $0 }) {
            guard request == transitionGeneration else { return }
            completion()
        }
    }

    private func closeGrid() {
        guard !gestures.gridClosing else { return }
        transitionGeneration += 1
        controller.gridMorph.pause()
        gestures.gridClosing = true
        if gridOrigin == nil { gridOrigin = .grid }
        let changesPage = presentation.pendingNewTab != nil ||
            (presentation.pendingSelection != nil && presentation.pendingSelection != tab?.id)
        if changesPage && gestures.gridProgress < 1 {
            // A card tap may interrupt entry. Keep the outgoing live document
            // until it reaches its card; only then install another document
            // behind the opaque grid and run the same progress clock in reverse.
            animateGrid(to:1) { prepareGridDestinationAndClose() }
        } else { prepareGridDestinationAndClose() }
    }
    private func prepareGridDestinationAndClose() {
        guard gestures.gridClosing else { return }
        let selection = presentation.pendingSelection
        let newTab = presentation.pendingNewTab
        // Install the destination behind the opaque grid, before any expansion.
        // The same full-size host then stays attached through the last frame.
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) {
            if let newTab { controller.newTab(isPrivate:newTab,animated:false) }
            else if let selection, selection != controller.session.selectedTabID { controller.session.selectTab(selection) }
            minimized = false; nativeFinding = false
            if newTab != nil { presentation.beginNewTab() }
            else { presentation.begin(tab) }
            if newTab == nil, hasLivePage { presentation.prepareLive() }
            _ = pageChrome
        }
        let request = transitionGeneration
        Task { @MainActor in
            // Give SwiftUI a layout pass at the card endpoint. This is not a
            // timed screenshot handoff: the live layer is the animation surface.
            await Task.yield()
            let deadline = ProcessInfo.processInfo.systemUptime+4
            while tab?.isRestoringWebView == true || !presentation.liveReady {
                guard ProcessInfo.processInfo.systemUptime < deadline else { cancelTransition(); return }
                if tab?.isRestoringWebView != true, !hasLivePage, let token = presentation.livePreparation {
                    // A failed restore uses the normal error page, which has no
                    // WebKit surface to prepare.
                    presentation.didPrepareLive(token)
                }
                try? await Task.sleep(for:.milliseconds(20))
                guard request == transitionGeneration, gestures.gridClosing, scenePhase == .active else { return }
            }
            guard request == transitionGeneration, gestures.gridClosing, scenePhase == .active else { return }
            animateGrid(to:0) {
                var transaction = Transaction(); transaction.disablesAnimations = true
                withTransaction(transaction) {
                    gestures.gridClosing = false; gestures.gridPresented = false; gridOrigin = nil
                    if controller.sheet == .tabs { controller.sheet = nil }
                    presentation.finish(); presentation.inserting = false
                }
                consumeFocusRequest()
                UIAccessibility.post(notification:.screenChanged,argument:tab?.url != nil ? tab?.webView : nil)
            }
        }
    }
    private func cancelTransition() {
        #if DEBUG
        MobileTransitionMetrics.note("cancel-transition",["hasSource":gestures.source != nil,"finishing":gestures.finishingSwipe])
        #endif
        transitionGeneration += 1
        swipe.cancel(); swipeHandoff = nil
        clearFallbackSwipe()
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) {
            let origin = gridOrigin; gridOrigin = nil
            if controller.sheet == nil || controller.sheet == .tabs {
                if origin == .page, controller.sheet == .tabs { restoringGridState = true; controller.sheet = nil }
                else if origin == .grid, controller.sheet == nil { restoringGridState = true; controller.sheet = .tabs }
            }
            gestures.gridPresented = controller.sheet == .tabs
            controller.gridMorph.cancel(to:gestures.gridPresented ? 1 : 0)
            gestures.cancel(); presentation.finish(); presentation.inserting = false
            presentation.insertionProgress = 0
        }
    }
    private func pullGrid(_ progress: CGFloat, _ ended: Bool) {
        guard scenePhase == .active else { cancelTransition(); return }
        if gridOrigin == nil { gridOrigin = .grid }
        presentation.begin(tab)
        if ended {
            if progress > 0.25 { closeGrid() }
            else { animateGrid(to:1) { gridOrigin = nil; presentation.settleInGrid(tab) } }
        } else {
            transitionGeneration += 1; controller.gridMorph.pause(at:gestures.gridProgress)
            gestures.gridProgress = 1-min(max(progress,0),1)
            controller.gridMorph.track(gestures.gridProgress,tabID:tab?.id)
        }
    }
    private func pinchGrid(_ target: BrowserTab, _ progress: CGFloat, _ ended: Bool) {
        guard scenePhase == .active else { cancelTransition(); return }
        if gridOrigin == nil { gridOrigin = .grid }
        presentation.begin(target)
        if ended {
            if progress > 0.25 { presentation.pendingSelection = target.id; closeGrid() }
            else { animateGrid(to:1) { gridOrigin = nil; presentation.settleInGrid(tab) } }
        } else {
            transitionGeneration += 1; controller.gridMorph.pause(at:gestures.gridProgress)
            gestures.gridProgress = 1-min(max(progress,0),1)
            controller.gridMorph.track(gestures.gridProgress,tabID:target.id)
        }
    }
    private var capsuleGesture: some View {
        MobileCapsulePan(enabled:true,availability:{
            !editingAddress && controller.sheet == nil && !gestures.finishingSwipe && !gestures.gridClosing
        }) { phase, delta, predicted in
            if phase == .cancelled || phase == .failed { cancelTransition(); return }
            if phase == .began { controller.gridMorph.pause() }
            guard !editingAddress, controller.sheet == nil, scenePhase == .active else { return }
            // A short pan may go from a zero-translation begin straight to end.
            // Mount/prepare its horizontal destination before resolving the
            // spring, just as a changed callback would. Keep vertical grid
            // handling and the distance/velocity policy unchanged.
            let finishingHorizontalIntent = phase == .ended && gestures.axis == nil &&
                abs(delta.width) > max(8,abs(delta.height)*1.35)
            if phase == .began || phase == .changed || finishingHorizontalIntent {
                if gestures.axis == .horizontal, swipe.isActive {
                    if (delta.width < 0 ? 1 : -1) == swipe.direction { swipe.move(delta.width); return }
                    swipe.cancel()
                }
                _ = gestures.capsule(finishingHorizontalIntent ? .changed : phase,translation:delta,session:controller.session)
                if gestures.axis == .vertical {
                    if gridOrigin == nil { gridOrigin = .page }
                    transitionGeneration += 1; presentation.begin(tab)
                    controller.gridMorph.track(gestures.gridProgress,tabID:tab?.id)
                }
                else if gestures.translation != 0, case .tab(let id) = controller.session.tabSwipeTarget(gestures.translation < 0 ? 1 : -1),
                        let next = controller.session.tabs.first(where: { $0.id == id }), let source = gestures.source {
                    let delta = gestures.translation
                    next.activate(); _ = controller.chrome(for:next)
                    let liveDestination = next.url != nil && next.errorMessage == nil && next.httpWarningURL == nil
                    if hasLivePage && liveDestination {
                        clearFallbackSwipe()
                        swipe.begin(source:source,destination:next.id,direction:delta < 0 ? 1 : -1,
                                    image:presentation.images[next.id],reduceMotion:reduceMotion)
                        gestures.translation = 0
                        swipe.move(delta)
                    } else if liveDestination, fallbackDestinationID != next.id {
                        fallbackDestinationID = next.id; fallbackPreparation = UUID(); fallbackReady = false; fallbackPaintRevision = nil
                    } else if !liveDestination { clearFallbackSwipe() }
                }
            }
            if phase == .ended, let source = gestures.source {
                if gestures.axis == .horizontal { finishTabSwipe(delta,predicted:predicted,source:source) }
                else {
                    let opens = gestures.gridProgress > 0.3 || (-predicted.height > 200 && -delta.height > 30)
                    let progress = gestures.gridProgress
                    gestures.cancel(); gestures.gridProgress = progress
                    if opens { controller.sheet = .tabs }
                    else { animateGrid(to:0) { gridOrigin = nil; presentation.finish() } }
                }
            }
        }
    }
    private func finishTabSwipe(_ delta: CGSize, predicted: CGSize, source: UUID) {
        let direction = delta.width < 0 ? 1 : -1
        let target = controller.session.tabSwipeTarget(direction)
        let commit = MobileChromeGestureState.commitsSwipe(delta.width,predicted:predicted.width,target:target)
        if swipe.isActive {
            guard case .tab(let destination) = target, destination == swipe.destinationID else { cancelTransition(); return }
            gestures.finishingSwipe = true
            swipe.finish(commit:commit) {
                guard gestures.source == source, controller.session.selectedTabID == source,
                      controller.session.tabSwipeTarget(direction) == .tab(destination) else { cancelTransition(); return }
                var transaction = Transaction(); transaction.disablesAnimations = true
                withTransaction(transaction) {
                    gestures.cancel()
                    if commit { swipeHandoff = destination; controller.session.commitTabSwipe(direction,from:source) }
                }
            }
            return
        }
        let width = max(1,(UIApplication.shared.connectedScenes.first as? UIWindowScene)?.keyWindow?.bounds.width ?? 402)
        #if DEBUG
        MobileTransitionMetrics.note("horizontal-end",["commit":commit,"delta":delta.width])
        #endif
        // Retain the source and destination until the spring reaches its endpoint.
        withAnimation(reduceMotion ? .easeInOut(duration:0.18) : .spring(response:0.34,dampingFraction:0.9), completionCriteria:.removed) {
            gestures.translation = commit ? (direction > 0 ? -width : width) : 0
        } completion: {
            #if DEBUG
            MobileTransitionMetrics.note("horizontal-completion",["valid":gestures.source == source && controller.session.selectedTabID == source])
            #endif
            Task { @MainActor in
                let deadline = ProcessInfo.processInfo.systemUptime+4
                while commit && fallbackDestinationID != nil && !fallbackIsReady {
                    guard gestures.source == source, controller.session.selectedTabID == source,
                          controller.session.tabSwipeTarget(direction) == target else { cancelTransition(); return }
                    guard ProcessInfo.processInfo.systemUptime < deadline else { cancelTransition(); return }
                    try? await Task.sleep(for:.milliseconds(10))
                }
                guard gestures.source == source, controller.session.selectedTabID == source,
                      !commit || controller.session.tabSwipeTarget(direction) == target else { cancelTransition(); return }
                var transaction = Transaction(); transaction.disablesAnimations = true
                withTransaction(transaction) {
                    gestures.cancel()
                    if commit {
                        minimized = false
                        controller.session.commitTabSwipe(direction,from:source)
                        swipeHandoff = controller.session.selectedTabID
                    }
                    clearFallbackSwipe()
                    if commit && target == .newTab { controller.addressFocusRequest += 1 }
                }
            }
        }
        // GestureState ending must not cancel the spring above.
        gestures.finishingSwipe = true
    }
    private func clearFallbackSwipe() {
        fallbackDestinationID = nil; fallbackPreparation = nil; fallbackReady = false; fallbackPaintRevision = nil
    }
    private var fallbackIsReady:Bool {
        guard let target = controller.session.tabs.first(where:{ $0.id == fallbackDestinationID }), target.isInstantiated else { return false }
        return fallbackReady && fallbackPaintRevision == target.documentRevision && !target.isRestoringWebView &&
            (!target.isLoading || controller.chrome(for:target).hasPaintedContent)
    }
    @ViewBuilder private func swipePreview(width: CGFloat) -> some View {
        if gestures.translation != 0 {
            let direction = gestures.translation < 0 ? 1 : -1
            let target = controller.session.tabSwipeTarget(direction)
            Group {
                if case .tab(let id) = target, let next = controller.session.tabs.first(where: { $0.id == id }) {
                    if next.url == nil {
                        home.safeAreaPadding(.top,windowInsets.top).safeAreaPadding(.bottom,bottomOcclusion+barHeight)
                            .background(theme.canvas).environment(\.colorScheme,controller.appearance.colorScheme ?? pageSystemScheme)
                    } else { MobileTabThumbnail(tab: next, presentation:presentation) }
                } else if target == .newTab {
                    ZStack { theme.canvas; Label(tab?.isPrivate == true ? "New Private Tab" : "New Tab", systemImage: "plus").foregroundStyle(theme.text) }
                }
            }.offset(x: reduceMotion ? 0 : (direction > 0 ? width : -width))
                .opacity(reduceMotion ? min(abs(gestures.translation) / max(width,1), 1) : 1)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    private func topColor(for tab: BrowserTab?) -> ChromeColor {
        let scheme = controller.appearance.colorScheme ?? pageSystemScheme
        if tab?.isPrivate == true && scheme == .light {
            return PageChrome.resolveCanvas(theme.privateWash, scheme: scheme)
        }
        return MobileTopChrome.rgb(UIColor(controller.chrome(for: tab).color))
    }

    private func topBar(width:CGFloat) -> some View {
        let canvas = homeColor
        var destination = canvas, destinationOpacity:CGFloat = 1
        if gestures.translation != 0,
           case .tab(let id) = controller.session.tabSwipeTarget(gestures.translation < 0 ? 1 : -1),
           let next = controller.session.tabs.first(where:{ $0.id == id }) {
            let chrome = controller.chrome(for:next)
            destination = topColor(for: next)
            destinationOpacity = solidChrome || !chrome.showsContentUnderChrome ? 1 : 0
        }
        return MobileTopBar(chrome:controller.topChrome,page:editingAddress || !hasLivePage ? canvas : topColor(for: tab),
            canvas:canvas,destination:destination,pageOpacity:editingAddress || extendsTopColor ? 1 : 0,destinationOpacity:destinationOpacity,
            pageID:tab?.id,gridProgress:gestures.gridProgress,swipeProgress:abs(gestures.translation)/max(1,width),
            interactive:gestures.source != nil || gestures.finishingSwipe || gestures.gridClosing || presentation.activeID != nil || editingAddress,
            reduceMotion:reduceMotion)
    }

    private var addressCapsule: some View {
            HStack(spacing: 0) {
                pageMenu.frame(width: 44, height: 48)
                ZStack {
                    HStack(spacing: 4) {
                        if tab?.isPrivate == true {
                            Image(systemName: "eyeglasses").foregroundStyle(theme.controlPrivate)
                        }
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
            .padding(.vertical, typeSize.isAccessibilitySize ? 8 : 0).buttonStyle(.plain).modifier(OrivMaterial.control())
            .background(capsuleGesture)
            .modifier(MobileCapsuleAccessibility(controller: controller))
    }

    private var addressEditor: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                if tab?.isPrivate == true { Image(systemName: "eyeglasses").font(.system(size: 20)).foregroundStyle(theme.privateAccent).accessibilityLabel("Private") }
                CappedAddressEditor(text: $address, editing: $editingAddress, submit: submitAddress,
                    completion: addressMatches.completion, hasSelectedSuggestion: addressMatches.selected != nil && addressMatches.query == address, moveSelection: { addressMatches.move($0) },
                    cancel: { editingAddress = false })
            }.padding(.horizontal, 14).padding(.vertical, 4).modifier(OrivMaterial.control())
            Button {
                editingAddress = false; address = tab?.url?.absoluteString ?? ""
            } label: { Image(systemName: "xmark").font(.system(size: 20)).frame(width: 48, height: 48) }
                .buttonStyle(.plain).modifier(OrivMaterial.control()).accessibilityLabel("Cancel address editing")
        }.foregroundStyle(theme.text).padding(12).background(theme.canvas)
            .environment(\.colorScheme, controller.appearance.colorScheme ?? pageSystemScheme)
    }

    private func setMinimized(_ value: Bool) {
        guard !typeSize.isAccessibilitySize else { minimized = false; return }
        guard minimized != value else { return }
        withAnimation(reduceMotion ? .easeInOut(duration:0.18) : .spring(response:0.38,dampingFraction:0.88)) { minimized = value }
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
        if let tab, tab.httpWarningURL != nil {
            HTTPFallbackView(tab: tab).background(theme.canvas)
        } else if let tab, let error = tab.errorMessage {
            PageErrorState(message: error, host: tab.url?.host, retry: tab.reload)
                .safeAreaPadding(.top, top).safeAreaPadding(.bottom, bottom)
        } else if tab?.url != nil {
            Color.clear.allowsHitTesting(false)
        } else {
            home.safeAreaPadding(.top, top).safeAreaPadding(.bottom, bottom)
                .safeAreaPadding(.leading, windowInsets.left).safeAreaPadding(.trailing, windowInsets.right)
        }
    }
    @ViewBuilder private func livePage(_ tab:BrowserTab, top:CGFloat, bottom:CGFloat, card:CGRect, progress:CGFloat) -> some View {
        // A retained child graph may receive its last update after shutdown.
        // Rendering must not invoke the lazy getter for a discarded/closed tab.
        if tab.isInstantiated {
        let revision = tab.documentRevision
        MobileWebView(webView:tab.webView,chrome:controller.chrome(for:tab),
            topInset:max(top,windowInsets.top), bottomInset:max(bottom,bottomOcclusion)+(nativeFinding ? 0 : barHeight),
            reduceTransparency:solidChrome,obscured:tab.id != controller.session.selectedTabID || swipe.isActive || editingAddress || gestures.finishingSwipe || gestures.translation != 0 || gestures.gridClosing || gestures.gridProgress > 0 || controller.sheet == .tabs,
            onFindVisibilityChange:{ visible in if controller.session.selectedTabID == tab.id { nativeFinding = visible } },
            onAppearanceChange:{ pageSystemScheme = $0 ? .dark : .light },onScroll:{ offset, down in
                presentation.refreshAfterScrolling(tab)
                guard gestures.source == nil, gestures.gridProgress == 0, !gestures.gridClosing else { return }
                if offset < 40 { setMinimized(false) }
                else if offset > 120 && down && !showsExternalPrivateBar { setMinimized(true) }
                else if !down { setMinimized(false) }
            },card:card,progress:progress,reduceMotion:reduceMotion,
            preparation:tab.isRestoringWebView ? nil : (tab.id == swipe.destinationID || tab.id == fallbackDestinationID
                ? (tab.isLoading && !controller.chrome(for:tab).hasPaintedContent ? nil : (tab.id == swipe.destinationID ? swipe.preparation : fallbackPreparation))
                : presentation.livePreparation),
            onPrepared:{ token,success in
                if token == swipe.preparation { swipe.prepared(token,success:success); return }
                if token == fallbackPreparation {
                    if success { fallbackReady = true; fallbackPaintRevision = revision } else { cancelTransition() }
                    return
                }
                guard token == presentation.livePreparation else { return }
                if success { presentation.didPrepareLive(token) }
                else { cancelTransition() }
            },swipe:swipe,tabID:tab.id,selected:tab.id == controller.session.selectedTabID,
            viewportLayout:controller.viewportLayout,baseBottomInset:max(bottom,windowInsets.bottom),includesBar:!nativeFinding,tab:tab)
            .id(ObjectIdentifier(tab.webView))
        }
    }
    private var otherProfiles: Bool { profiles.profiles.filter { $0.archivedAt == nil }.count > 1 }
    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if otherProfiles {
                    Label(profileName, systemImage: "person.crop.circle").font(.footnote).foregroundStyle(theme.secondaryText)
                }
                if tab?.isPrivate == true {
                    VStack(alignment: .leading, spacing: OrivSpacing.small) {
                        Label {
                            Text("Private browsing").foregroundStyle(theme.text)
                        } icon: {
                            Image(systemName: "eyeglasses").foregroundStyle(theme.privateAccent)
                        }.font(.headline)
                        Text("Private tabs aren’t saved or added to history. Cookies and website data are discarded when the last tab sharing them closes. Websites and your network can still see your activity.").font(.callout).foregroundStyle(theme.secondaryText)
                    }.padding(.top, 40)
                } else {
                    StartPageSites(session: controller.session, emptyMessage: "Bookmarks and frequently visited sites appear here.",
                        open: { controller.open($0) }, showBookmarks: { controller.sheet = .bookmarks },
                        showHistory: { controller.sheet = .history })
                }
            }.padding(.horizontal, 20).padding(.vertical, OrivSpacing.xl).frame(maxWidth: 650, alignment: .leading).frame(maxWidth: .infinity)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var suggestions: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(addressMatches.rows.enumerated()), id: \.element.id) { index, match in
                    if index == 0 || addressMatches.rows[index - 1].source != match.source {
                        Text(match.source.rawValue).font(.caption.weight(.semibold)).foregroundStyle(theme.secondaryText)
                            .padding(.horizontal, 12).padding(.top, 8)
                    }
                    Button { chooseSuggestion(match) } label: {
                        AddressSuggestionRow(suggestion: match, query: address, isPrivate: tab?.isPrivate == true)
                            .padding(.horizontal, 12).frame(minHeight: 52).contentShape(Rectangle())
                            .background { if addressMatches.selected == index { SelectedRowBackground() } }
                    }.buttonStyle(.plain).accessibilityAddTraits(addressMatches.selected == index ? [.isSelected] : [])
                }
            }.padding(OrivSpacing.small).modifier(OrivMaterial.overlay()).padding(.horizontal, OrivSpacing.medium).padding(.top, OrivSpacing.xs)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).scrollDismissesKeyboard(.interactively)
    }
    private func chooseSuggestion(_ match: BrowserSuggestion) {
        editingAddress = false
        if let id = match.tabID { controller.session.selectTab(id) }
        else { controller.perform { try controller.session.navigate(match.url.absoluteString) } }
    }
    private var pageMenu: some View {
            Menu {
                Section {
                    Button(controller.session.isBookmarked(tab?.url) ? "Remove Bookmark" : "Add Bookmark", systemImage: controller.session.isBookmarked(tab?.url) ? "bookmark.fill" : "bookmark") { controller.session.toggleBookmark() }.disabled(tab?.url == nil || tab?.isPrivate == true)
                    if let url = tab?.url {
                        Button("Copy Link", systemImage: "doc.on.doc") { PrivacyPasteboard.copy(url) }
                        Button("Copy Original Link", systemImage: "link") { PrivacyPasteboard.copy(url, original: true) }
                    }
                    Button("Find on Page", systemImage: "magnifyingglass") { tab?.showFind() }.disabled(tab?.url == nil)
                    Button("Share", systemImage: "square.and.arrow.up") { controller.sheet = .share }.disabled(tab?.url == nil)
                }
                if let tab, tab.url != nil {
                    Section {
                        ControlGroup {
                            Button("Zoom In", systemImage: "plus.magnifyingglass") { tab.zoomIn() }
                            Button("Zoom Out", systemImage: "minus.magnifyingglass") { tab.zoomOut() }
                        }
                        // VoiceOver uses the actual native menu title.
                        Button("Reset Page Zoom (\(Int(tab.pageZoom * 100))%)") { tab.resetZoom() }
                    }
                }
                Section {
                    Button("New Tab", systemImage: "plus") { controller.newTab() }
                    Button("New Private Tab", systemImage: "eyeglasses") { controller.newTab(isPrivate: true) }
                    if controller.session.canReopenTab { Button("Reopen Closed Tab", systemImage: "arrow.uturn.backward") { controller.session.reopenClosedTab() } }
                    Button("Tabs (\(controller.session.tabs.count))", systemImage: "square.on.square") { controller.sheet = .tabs }
                    Button("Bookmarks", systemImage: "bookmark") { controller.sheet = .bookmarks }
                    Button(controller.downloads.hasActivity ? "Library, Downloads Available" : "Library", systemImage: "book") { controller.sheet = .library }
                }
                Section {
                    if let tab {
                        MobileSendTabMenu(controller: controller, profiles: profiles, tab: tab)
                        MobileMoveTabMenu(controller: controller, profiles: profiles, tab: tab)
                    }
                    Button(OrivStrings.sitePrivacy, systemImage: "shield.lefthalf.filled") { controller.sheet = .site }.disabled(tab?.url == nil)
                    if let site = controller.session.forgettableSite(for: tab) {
                        Button("Forget This Site…", systemImage: "trash", role: .destructive) { siteToForget = site }
                    }
                    Menu("More Page Actions", systemImage: "ellipsis.circle") {
                        Menu("Back History", systemImage: "clock.arrow.circlepath") { MobileHistoryMenu(tab: tab, forward: false) }.disabled(tab?.canGoBack != true)
                        if tab?.canGoForward == true { Menu("Forward History") { MobileHistoryMenu(tab: tab, forward: true) } }
                        Button("Images on This Page", systemImage: "photo") { controller.showPageImages() }.disabled(tab?.url == nil)
                    }
                    if controller.session.isExternalPrivate {
                        Button("Return to Profile", systemImage: "person.crop.circle") {
                            if let profile = profiles.profiles.first(where: { $0.id == profiles.lastRegularProfileID }) { profiles.select(profile) }
                        }
                    } else if profiles.externalPrivate != nil {
                        Button("External Private Tabs", systemImage: "eyeglasses") { profiles.showExternalPrivate() }
                    }
                }
                Section { Button("Settings", systemImage: "gearshape") { controller.sheet = .settings } }
            } label: {
                Label("Page Menu", systemImage: "ellipsis")
                    .labelStyle(.iconOnly).font(.system(size: 20))
                    .frame(width: 44, height: 48).contentShape(Rectangle())
            }.accessibilityIdentifier("browserPageMenu").menuOrder(.fixed).tint(.primary)
    }
    private func beginAddressEditing() { minimized = false; address = tab?.url?.absoluteString ?? ""; editingAddress = true }
    private func submitAddress() {
        if addressMatches.query == address, let index = addressMatches.selected, addressMatches.rows.indices.contains(index) {
            chooseSuggestion(addressMatches.rows[index]); return
        }
        do { try controller.session.navigate(address); editingAddress = false }
        catch { controller.message = error.localizedDescription }
    }
}

private struct MobilePageShare: UIViewControllerRepresentable {
    let webView: WKWebView
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [URLCleaner.clean(url)], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
/// Read the capped environment inside the address bar, rather than scaling at the screen root.
private struct CappedAddressEditor: View {
    @Binding var text: String
    @Binding var editing: Bool
    let submit: () -> Void
    var completion: String? = nil
    var hasSelectedSuggestion = false
    var moveSelection: (Int) -> Void = { _ in }
    var cancel: () -> Void = {}
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 44
    var body: some View {
        MobileAddressField(text: $text, editing: $editing, submit: submit, completion: completion, hasSelectedSuggestion: hasSelectedSuggestion, moveSelection: moveSelection, cancel: cancel)
            .frame(height: height)
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

/// Geometry is supplied by the collection layout in window coordinates. SwiftUI
/// interpolates these simple properties at display refresh rate; no DOM/snapshot
/// work occurs as the finger moves. Reduce Motion uses only opacity.
private struct MobilePageMorph: View {
    let image: UIImage?
    let full: CGRect
    let card: CGRect
    let progress: CGFloat
    let reduceMotion: Bool
    let background: Color
    var body: some View {
        let p = min(max(progress,0),1)
        let rect = reduceMotion ? full : MobileGridMorph.frame(full:full,card:card,progress:p)
        ZStack(alignment:.top) {
            background
            if let image { Image(uiImage:image).resizable().scaledToFill().frame(width:rect.width,height:rect.height,alignment:.top).clipped() }
        }.frame(width:rect.width,height:rect.height)
            .clipShape(.rect(cornerRadius:reduceMotion ? 0 : 18*p))
            .position(x:rect.midX,y:rect.midY)
            .opacity(reduceMotion ? 1-p : 1)
    }
}

private enum MobileGridRestingState: Equatable { case page, grid }
