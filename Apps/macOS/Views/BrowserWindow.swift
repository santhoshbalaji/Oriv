import BrowserCore
import BrowserEngine
import SwiftUI
import WebKit

struct BrowserWindow: View {
    @Environment(\.browserTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.chromeReduceTransparencyOverride) private var captureReduceTransparency
    @Bindable var controller: BrowserController
    var profiles: BrowserProfiles? = nil
    var initialPageMenu = false
    @State private var windowWidth: CGFloat = 1250
    @State private var address = ""
    @State private var findText = ""
    @State private var showFind = false
    @State private var showProtection = false
    @State private var showPasswords = false
    @State private var showSiteInfo = false
    @State private var findCaseSensitive = false
    @State private var addressFocused = false
    @State private var suggestionIndex: Int?
    @State private var pageChrome = PageChrome()
    @State private var showTabs = false
    @State private var showPageMenu = false
    @FocusState private var findFocused: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    private var session: BrowserSession { controller.session }
    private var tab: BrowserTab? { session.selectedTab }
    private var showsExternalPrivateBar: Bool { session.isExternalPrivate && profiles?.externalBannerVisible == true }
    private var compact: Bool { controller.compactSidebar }
    private var addressWidth: CGFloat { min(640, max(230, windowWidth - 500)) }
    private var compactAddress: String? { tab?.url.flatMap(URLDisplay.site) }
    private var compactAddressWidth: CGFloat? {
        guard !addressFocused, let compactAddress else { return nil }
        let width = (compactAddress as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width
        return min(ceil(width) + 4, max(60, addressWidth - 180))
    }
    private var toolbarTheme: Theme { pageChrome.isDark ? theme : .classic }
    private var contentUnderChrome: Bool { pageChrome.showsContentUnderChrome && !reduceTransparency && !captureReduceTransparency && contrast != .increased }
    private var chromeForeground: Color { contentUnderChrome ? .primary : pageChrome.foreground }
    private var chromeGlass: MacAddressGlass { MacAddressGlass(color: pageChrome.color, isDark: pageChrome.isDark, adaptive: contentUnderChrome) }
    private var privateCue: Color { pageChrome.contrasting(pageChrome.isDark ? Color(red: 0.733, green: 0.522, blue: 0.961) : Color(red: 0.537, green: 0.267, blue: 0.671)) }

    var body: some View {
        routedContent
        .focusedSceneValue(\.browserController, controller)
        .onAppear {
            showPageMenu = initialPageMenu
            session.activateSelectedTab(); syncAddress(); if tab?.url == nil { controller.focusAddress() }
            if !session.isExternalPrivate {
                profiles?.showRegularWindow = { openWindow(id: "browser") }
                profiles?.showExternalWindow = { openWindow(id: "external-private") }
                profiles?.closeExternalWindow = { dismissWindow(id: "external-private") }
                if profiles?.externalPrivate != nil { openWindow(id: "external-private") }
            }
        }
        .onChange(of: session.tabs.count) { _, count in
            if session.isExternalPrivate && count == 0 { dismissWindow(id: "external-private"); profiles?.endExternalPrivate() }
        }
        .onChange(of: address) { _, _ in suggestionIndex = nil }
        .onChange(of: session.selectedTabID) { _, _ in addressFocused = false; syncAddress(); showFind = false; showSiteInfo = false; showProtection = false }
        .onChange(of: tab?.url) { _, _ in if !addressFocused { syncAddress() } }
        .onChange(of: controller.addressFocusRequest) { _, _ in showPageMenu = false }
        .onChange(of: controller.findRequest) { _, _ in showFind = true; findFocused = true }
        .onChange(of: controller.findNextRequest) { _, _ in
            showFind = true
            if findText.isEmpty { findFocused = true }
            else { tab?.find(findText, backwards: controller.findBackwards, caseSensitive: findCaseSensitive) }
        }
        .onChange(of: controller.passwordsGuideRequest) { _, _ in showPasswords = true }
        .onChange(of: scenePhase) { _, phase in if phase != .active { session.saveNow() } }
        .task(id: "\(tab?.id.uuidString ?? "none")-\(tab?.url != nil || tab?.hasLoaded == true)") { pageChrome.observe(tab.flatMap { $0.url != nil || $0.hasLoaded ? $0.webView : nil }, isPrivate: tab?.isPrivate == true) }
        .onChange(of: colorScheme) { _, _ in pageChrome.requestSample() }
        .onDisappear { pageChrome.observe(nil) }
    }

    private var shell: some View {
        HStack(spacing: 0) {
            BrowserSidebar(controller: controller, profiles: profiles, compact: compact)
                .frame(width: compact ? 56 : 212)
                .padding(8)
            // Extend the page colour, never a mirrored copy of the page's text.
            page
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
        .toolbar(removing: .title)
        .navigationTitle(session.isExternalPrivate ? "Oriv — Private" : profiles.map { "\(AppIdentity.name) — \($0.active.name)" } ?? AppIdentity.name)
        .toolbar { browserToolbar }
        .toolbarBackgroundVisibility(contentUnderChrome ? .automatic : .hidden, for: .windowToolbar)
        .toolbarColorScheme(contentUnderChrome ? colorScheme : (pageChrome.isDark ? .dark : .light), for: .windowToolbar)
        .background(pageChrome.color, ignoresSafeAreaEdges: [])
        .background(BrowserTitlebar(color: pageChrome.color, reduceMotion: reduceMotion || !pageChrome.animatesColor))
        .overlay(alignment: .topTrailing) {
            if showPageMenu {
                ZStack(alignment: .topTrailing) {
                    Color.clear.contentShape(Rectangle()).onTapGesture { showPageMenu = false }
                    pageActionsPanel.padding(12)
                }
            }
        }
        .overlay(alignment: .top) {
            if addressFocused && !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                addressSuggestions.frame(width: addressWidth).padding(.top, OrivSpacing.xs)
            }
        }
    }

    @ToolbarContentBuilder private var browserToolbar: some ToolbarContent {
            ToolbarItem(placement: .navigation) {
                Button {
                    controller.compactSidebar.toggle()
                } label: { Image(systemName: "sidebar.left") }
                    .help(compact ? "Expand sidebar" : "Compact sidebar").accessibilityLabel("Toggle sidebar")
                    .keyboardShortcut("s", modifiers: [.command, .option])
                    .buttonStyle(.plain).frame(width: 36, height: 32).modifier(chromeGlass)
                    // This marker travels with NSToolbar into AppKit's separate
                    // fullscreen/reveal host. Tint the window that actually draws it.
                    .background(BrowserToolbarBackdrop(color:pageChrome.color,adaptive:contentUnderChrome,reduceMotion:reduceMotion || !pageChrome.animatesColor))
                    .foregroundStyle(chromeForeground)
                    .environment(\.colorScheme, pageChrome.isDark ? .dark : .light)
            }.sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.fixed, placement: .navigation)
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 2) {
                Button { tab?.goBack() } label: { Image(systemName: "chevron.left").frame(width: 28, height: 28) }
                    .disabled(tab?.canGoBack != true).help("Back (⌘[)").accessibilityLabel("Back")
                    .foregroundStyle(chromeForeground)
                Button { tab?.goForward() } label: { Image(systemName: "chevron.right").frame(width: 28, height: 28) }
                    .disabled(tab?.canGoForward != true).help("Forward (⌘])").accessibilityLabel("Forward")
                    .foregroundStyle(chromeForeground)
                }.buttonStyle(MacChromeButtonStyle()).padding(.horizontal, 6).frame(height: 32)
                    .modifier(chromeGlass)
                    .environment(\.colorScheme, pageChrome.isDark ? .dark : .light)
            }.sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .principal) {
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
                        }.buttonStyle(.plain).accessibilityLabel("\(cue.label). Site information and permissions").help("Site information and permissions")
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
                            if let index = suggestionIndex, suggestions.indices.contains(index) { chooseSuggestion(suggestions[index]); return true }
                            controller.navigate(address)
                            return controller.addressError == nil
                        }, cancel: { syncAddress() }, moveSelection: { offset in
                            guard !suggestions.isEmpty else { return }
                            suggestionIndex = min(suggestions.count - 1, max(0, (suggestionIndex ?? (offset > 0 ? -1 : suggestions.count)) + offset))
                        })
                        .frame(width: compactAddressWidth, height: 20)
                        .frame(maxWidth: compactAddressWidth == nil ? .infinity : nil)
                }
                .padding(.horizontal, tab?.pageZoom != 1 && tab?.url != nil ? 72 : 36)
                .frame(width: addressWidth, height: 32)
                .overlay(alignment: .trailing) {
                    HStack(spacing: 4) {
                        if tab?.url != nil {
                            if let tab, tab.pageZoom != 1 {
                                Button { tab.resetZoom() } label: {
                                    Text("\(Int(tab.pageZoom * 100))%").font(.caption2).frame(minWidth: 24, minHeight: 24).contentShape(Rectangle())
                                }.buttonStyle(.plain).accessibilityLabel("Reset Page Zoom").accessibilityValue("\(Int(tab.pageZoom * 100)) percent").help("Reset Page Zoom")
                            }
                            Button { tab?.isLoading == true ? tab?.stop() : tab?.reload() } label: {
                                Image(systemName: tab?.isLoading == true ? "xmark" : "arrow.clockwise")
                                    .font(OrivType.detail).frame(width: 24, height: 24)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(tab?.isLoading == true ? "Stop loading" : "Reload page")
                            .help(tab?.isLoading == true ? "Stop loading" : "Reload (⌘R)")
                        }
                    }.padding(.trailing, 4)
                }
                .foregroundStyle(chromeForeground)
                .modifier(chromeGlass)
                .environment(\.colorScheme, pageChrome.isDark ? .dark : .light)
                .environment(\.browserTheme, toolbarTheme)
                .overlay {
                    Capsule().strokeBorder(addressFocused ? theme.accent : .clear, lineWidth: 1.5)
                }
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 2) {
                if controller.downloads.hasActiveDownloads {
                    Button { controller.library = .downloads } label: { Label("Downloads in progress", systemImage: "arrow.down.circle.fill") }
                        .labelStyle(.iconOnly).help("View downloads in progress")
                }
                if let url = tab?.url {
                    ShareLink(item: URLCleaner.clean(url)) { Image(systemName: "square.and.arrow.up").frame(width: 28, height: 28).foregroundStyle(chromeForeground) }
                        .help("Share Page").accessibilityLabel("Share Page")
                }
                Button { controller.newTab() } label: { Image(systemName: "plus").frame(width: 28, height: 28).foregroundStyle(chromeForeground) }
                    .help("New Tab (⌘T)").accessibilityLabel("New Tab")
                Button { showTabs = true } label: { Image(systemName: "square.on.square").frame(width: 28, height: 28).foregroundStyle(chromeForeground) }
                    .help("Tab Overview").accessibilityLabel("Tab Overview")
                }.buttonStyle(MacChromeButtonStyle()).padding(.horizontal, 6).frame(height: 32)
                    .modifier(chromeGlass)
                    .environment(\.colorScheme, pageChrome.isDark ? .dark : .light)
            }.sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Button { showPageMenu.toggle() } label: { Image(systemName: "ellipsis") }
                    .help("Browser actions").accessibilityLabel("Browser actions")
                    .foregroundStyle(chromeForeground)
                    .buttonStyle(.plain).frame(width: 36, height: 32).modifier(chromeGlass)
                    .environment(\.colorScheme, pageChrome.isDark ? .dark : .light)
                    .popover(isPresented: $showPasswords) { PasswordsGuide(compact: true) }
                    .popover(isPresented: $showProtection) { AdBlockingPopover(session: session) }
            }.sharedBackgroundVisibility(.hidden)
    }

    private var pageActionsPanel: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(tab?.displayTitle ?? "Oriv").font(.headline).lineLimit(2).padding(8)
                    Button("New Tab", systemImage: "plus") { showPageMenu = false; controller.newTab() }
                    Button("New Private Tab", systemImage: "eyeglasses") { showPageMenu = false; controller.newTab(isPrivate: true) }
                    Button("Reopen Closed Tab", systemImage: "arrow.uturn.backward") { showPageMenu = false; session.reopenClosedTab() }.disabled(!session.canReopenTab)
                    Divider()
                    if let url = tab?.url {
                        Button("Copy Link", systemImage: "doc.on.doc") { PrivacyPasteboard.copy(url); showPageMenu = false }
                        Button("Copy Original Link") { PrivacyPasteboard.copy(url, original: true); showPageMenu = false }
                    }
                    if let profiles { SendPageMenu(continuity: profiles.continuity, session: session, profile: controller.profile) }
                    Button(session.isBookmarked(tab?.url) ? "Remove Bookmark" : "Add Bookmark", systemImage: "bookmark") { showPageMenu = false; controller.saveCurrentPage() }
                        .disabled(tab?.url == nil || tab?.isPrivate == true)
                    Button("Find on Page", systemImage: "magnifyingglass") { showPageMenu = false; showFind = true; findFocused = true }.disabled(tab?.url == nil)
                    Button("Zoom In", systemImage: "plus.magnifyingglass") { showPageMenu = false; tab?.zoomIn() }.disabled(tab?.url == nil)
                    Button("Zoom Out", systemImage: "minus.magnifyingglass") { showPageMenu = false; tab?.zoomOut() }.disabled(tab?.url == nil)
                    Button("Reset Page Zoom") { showPageMenu = false; tab?.resetZoom() }.disabled(tab?.url == nil)
                    Button("Read Page Text", systemImage: "doc.text") { showPageMenu = false; controller.openReader() }.disabled(tab?.url == nil)
                    Button("Site Privacy", systemImage: "shield.lefthalf.filled") { showPageMenu = false; showProtection = true }
                    Button("Password AutoFill Help", systemImage: "key") { showPageMenu = false; showPasswords = true }
        }
        .buttonStyle(PageMenuButtonStyle()).labelStyle(.titleAndIcon).font(OrivType.body)
        .padding(16).frame(width: 282, alignment: .leading)
        .foregroundStyle(theme.text).browserGlass(radius: 22)
        .focusSection().onExitCommand { showPageMenu = false }
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
                                PageRowContent(title: item.displayTitle, url: item.url, isPrivate: item.isPrivate)
                                    .padding(16).frame(maxWidth: .infinity, minHeight: 90)
                                    .background(theme.surface, in: .rect(cornerRadius: 12))
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }.padding(24).frame(width: 760, height: 500)
        }
        .onChange(of: controller.library) { _, value in if value != nil { showPageMenu = false } }
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
                        tabContent(tab).id(tab.id)
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
            WebPageView(tab: tab, chrome: pageChrome, contentUnderChrome: contentUnderChrome)
                .scrollEdgeEffectStyle(.automatic, for: .top)

        }
        else { StartPage(controller: controller, isPrivate: tab.isPrivate) }
    }

    private var suggestions: [BrowserSuggestion] { session.suggestions(for: address, isPrivate: tab?.isPrivate == true) }
    private var addressSuggestions: some View {
        AddressSuggestionList(suggestions: suggestions, selectedIndex: suggestionIndex, address: address,
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

/// Clear native glass preserves the page hue. A lightly biased backing keeps the
/// chosen black/white foreground readable even when scrolled imagery passes below.
/// The sidebar and iPhone retain their own material.
struct MacAddressGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.chromeReduceTransparencyOverride) private var captureReduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let color: Color
    let isDark: Bool
    var adaptive = false
    static let contrastBias = 0.12
    static let backingOpacity = 0.96
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var solid: Bool { reduceTransparency || captureReduceTransparency || contrast == .increased }
    func body(content: Content) -> some View {
        // Keep content in one structural branch. Replacing it recreates the
        // AppKit field/coordinator and can replay a previous Command-L request.
        content
            .background {
                Capsule().fill(color)
                    .overlay { Capsule().fill((isDark ? Color.black : .white).opacity(solid ? 0 : Self.contrastBias)) }
                    .opacity(solid ? 1 : (adaptive ? 0 : Self.backingOpacity))
            }
            .glassEffect(solid ? .identity : (adaptive ? .regular : .clear.tint(color.opacity(0.25))), in: Capsule())
            .overlay {
                if solid {
                    Capsule().strokeBorder((isDark ? Color.white : .black).opacity(contrast == .increased ? 0.8 : 0.35), lineWidth: 1)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: adaptive)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: color)
    }
}

/// Disabled navigation keeps its disabled action/AX state without reducing the
/// glyph's contrast against a page of arbitrary colour.
private struct MacChromeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.contentShape(Rectangle())
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
        let context = URLDisplay.Context(suggestions.map { ($0.title, $0.url) })
        VStack(alignment: .leading, spacing: OrivSpacing.xs) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, match in
                Button { choose(match) } label: {
                    PageRowContent(title: match.title, url: match.url, context: context,
                                   iconSize: 20, spacing: 10, secondaryFont: .caption, isPrivate: isPrivate,
                                   accessory: match.tabID != nil ? .alreadyOpen : .none)
                        .padding(.horizontal, 10).frame(height: 32).contentShape(Rectangle())
                        .background { if selectedIndex == index { SelectedRowBackground() } }
                }.buttonStyle(.plain).accessibilityAddTraits(selectedIndex == index ? [.isSelected] : [])
            }
            Button(action: submit) {
                Label(AddressAction.title(for: address, engine: engine), systemImage: AddressAction.symbol(for: address, engine: engine))
                    .foregroundStyle(theme.text).padding(.horizontal, 10).frame(height: 32).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }.font(OrivType.body).padding(6).background(theme.surface, in: .rect(cornerRadius: OrivRadius.medium))
            .overlay { RoundedRectangle(cornerRadius: OrivRadius.medium).strokeBorder(theme.separator) }
            .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
    }
}

private struct PageMenuButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .padding(.horizontal, 8).contentShape(Rectangle())
            .background(configuration.isPressed ? Color.white.opacity(0.1) : .clear, in: .rect(cornerRadius: 8))
    }
}
