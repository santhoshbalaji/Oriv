import BrowserCore
import BrowserEngine
import SwiftUI
import WebKit

struct BrowserWindow: View {
    @Environment(\.browserTheme) private var theme
    @Bindable var controller: BrowserController
    var profiles: BrowserProfiles? = nil
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
    @FocusState private var findFocused: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    private var session: BrowserSession { controller.session }
    private var tab: BrowserTab? { session.selectedTab }
    private var showsExternalPrivateBar: Bool { session.isExternalPrivate && profiles?.externalBannerVisible == true }
    private var compact: Bool { controller.compactSidebar }
    private var addressWidth: CGFloat { min(760, max(230, windowWidth - 470)) }

    var body: some View {
        routedContent
        .focusedSceneValue(\.browserController, controller)
        .onAppear {
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
        .onChange(of: controller.findRequest) { _, _ in showFind = true; findFocused = true }
        .onChange(of: controller.findNextRequest) { _, _ in
            showFind = true
            if findText.isEmpty { findFocused = true }
            else { tab?.find(findText, backwards: controller.findBackwards, caseSensitive: findCaseSensitive) }
        }
        .onChange(of: controller.passwordsGuideRequest) { _, _ in showPasswords = true }
        .onChange(of: scenePhase) { _, phase in if phase != .active { session.saveNow() } }
    }

    private var shell: some View {
        HStack(spacing: 0) {
            BrowserSidebar(controller: controller, profiles: profiles, compact: compact)
                .frame(width: compact ? 56 : 212)
            Divider()
            page
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
        .toolbar(removing: .title)
        .navigationTitle(session.isExternalPrivate ? "Oriv — Private" : profiles.map { "\(AppIdentity.name) — \($0.active.name)" } ?? AppIdentity.name)
        .toolbar { browserToolbar }
        .overlay(alignment: .top) {
            if addressFocused && !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                addressSuggestions.frame(width: addressWidth).padding(.top, OrivSpacing.xs)
            }
        }
    }

    @ToolbarContentBuilder private var browserToolbar: some ToolbarContent {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    controller.compactSidebar.toggle()
                } label: { Image(systemName: "sidebar.left") }
                    .help(compact ? "Expand sidebar" : "Compact sidebar").accessibilityLabel("Toggle sidebar")
                    .keyboardShortcut("s", modifiers: [.command, .option])
                Button { tab?.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(tab?.canGoBack != true).help("Back (⌘[)").accessibilityLabel("Back")
                Button { tab?.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(tab?.canGoForward != true).help("Forward (⌘])").accessibilityLabel("Forward")
            }
            ToolbarItem(placement: .principal) {
                HStack(spacing: 7) {
                    if let tab, tab.url != nil {
                        let cue = ConnectionCue(tab)
                        Button { showSiteInfo.toggle() } label: {
                            HStack(spacing: OrivSpacing.xs) {
                                Image(systemName: cue.symbol)
                                if cue == .notSecure { Text(cue.label).font(OrivType.detail.weight(.medium)).fixedSize() }
                            }.font(OrivType.detail).foregroundStyle(cue.color(theme)).frame(minWidth: 24, minHeight: 24).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("\(cue.label). Site information and permissions").help("Site information and permissions")
                            .popover(isPresented: $showSiteInfo) { SiteInformationView(session: session, tab: tab) }
                    } else {
                        Image(systemName: tab?.isPrivate == true ? "eyeglasses" : "magnifyingglass").font(OrivType.detail)
                            .foregroundStyle(tab?.isPrivate == true ? theme.privateAccent : theme.secondaryText).accessibilityHidden(true)
                    }
                    AddressField(text: $address, isEditing: $addressFocused,
                                 placeholder: "Search or enter website",
                                 focusRequest: controller.addressFocusRequest, submit: {
                            if let index = suggestionIndex, suggestions.indices.contains(index) { chooseSuggestion(suggestions[index]); return true }
                            controller.navigate(address)
                            return controller.addressError == nil
                        }, cancel: { syncAddress() }, moveSelection: { offset in
                            guard !suggestions.isEmpty else { return }
                            suggestionIndex = min(suggestions.count - 1, max(0, (suggestionIndex ?? (offset > 0 ? -1 : suggestions.count)) + offset))
                        })
                        .frame(height: 20)
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
                }
                .padding(.leading, OrivSpacing.medium).padding(.trailing, tab?.url == nil ? 12 : 4)
                .frame(width: addressWidth, height: 28)
                .overlay {
                    Capsule().strokeBorder(addressFocused ? theme.accent : .clear, lineWidth: 1.5)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if controller.downloads.hasActiveDownloads {
                    Button { controller.library = .downloads } label: { Label("Downloads in progress", systemImage: "arrow.down.circle.fill") }
                        .labelStyle(.iconOnly).help("View downloads in progress")
                }
                Button { controller.saveCurrentPage() } label: {
                    Image(systemName: session.isBookmarked(tab?.url) ? "bookmark.fill" : "bookmark")
                }
                .disabled(tab?.url == nil || tab?.isPrivate == true)
                .accessibilityLabel("Toggle bookmark")
                .help("Toggle bookmark (⌘D)")
                Menu {
                    Button("New Tab", systemImage: "plus") { controller.newTab() }
                    Button("New Private Tab", systemImage: "eyeglasses") { controller.newTab(isPrivate: true) }
                    Button("Reopen Closed Tab", systemImage: "arrow.uturn.backward") { session.reopenClosedTab() }.disabled(!session.canReopenTab)
                    Divider()
                    if let profiles { SendPageMenu(continuity: profiles.continuity, session: session, profile: controller.profile) }
                    Button("Read Page Text", systemImage: "doc.text") { controller.openReader() }.disabled(tab?.url == nil)
                    Button("Ad Blocking", systemImage: "shield.lefthalf.filled") { showProtection = true }
                    Button("Password AutoFill Help", systemImage: "key") { showPasswords = true }
                } label: { Image(systemName: "ellipsis") }.help("Browser actions").accessibilityLabel("Browser actions")
                    .popover(isPresented: $showPasswords) { PasswordsGuide(compact: true) }
                    .popover(isPresented: $showProtection) { AdBlockingPopover(session: session) }
            }
    }

    private var panels: some View {
        shell
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
                    .background(theme.privateAccent.opacity(0.08))
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
            .background(theme.canvas)
    }

    @ViewBuilder private func tabContent(_ tab: BrowserTab) -> some View {
        if tab.url != nil || tab.hasLoaded { WebPageView(tab: tab) }
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
