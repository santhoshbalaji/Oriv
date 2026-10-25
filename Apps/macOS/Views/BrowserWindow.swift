import BrowserEngine
import SwiftUI
import WebKit

struct BrowserWindow: View {
    @Bindable var controller: BrowserController
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var windowWidth: CGFloat = 1250
    @State private var sidebarWidth: CGFloat = 240
    @State private var address = ""
    @State private var findText = ""
    @State private var showFind = false
    @State private var showProtection = false
    @State private var showPasswords = false
    @State private var addressFocused = false
    @FocusState private var findFocused: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow

    private var session: BrowserSession { controller.session }
    private var tab: BrowserTab? { session.selectedTab }
    private var addressWidth: CGFloat {
        let sidebarHidden = columnVisibility == .detailOnly
        let occupiedSidebar = sidebarHidden ? 0 : sidebarWidth
        // Collapsing the sidebar moves the window controls into the same toolbar budget.
        let controlsWidth: CGFloat = sidebarHidden ? 540 : 360
        return min(720, max(180, windowWidth - occupiedSidebar - controlsWidth))
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            BrowserSidebar(controller: controller)
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { sidebarWidth = $0 }
        } detail: {
            VStack(spacing: 0) {
                if let notice = session.persistenceNotice {
                    noticeBar(notice, symbol: "externaldrive.badge.exclamationmark") {
                        session.dismissNotice()
                    }
                }
                if tab?.isPrivate == true {
                    HStack(spacing: 6) {
                        Image(systemName: "eyeglasses")
                        Text("Private browsing")
                        Spacer()
                        Text("Session only").foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .padding(.horizontal, 18).padding(.vertical, 7)
                    .background(Theme.privateAccent.opacity(0.09))
                    .accessibilityElement(children: .combine)
                }
                if showFind {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Find in page", text: $findText)
                            .textFieldStyle(.plain).focused($findFocused)
                            .onSubmit { tab?.find(findText) }
                        Button("Find next") { tab?.find(findText) }.disabled(findText.isEmpty)
                        Button { showFind = false } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless).accessibilityLabel("Close find bar")
                    }
                    .padding(10)
                    Divider()
                }
                if let tab {
                    ZStack(alignment: .top) {
                        if tab.url != nil || tab.hasLoaded {
                            WebPageView(tab: tab).id(tab.id)
                        } else {
                            StartPage(controller: controller, isPrivate: tab.isPrivate)
                        }
                        if let error = tab.errorMessage {
                            ContentUnavailableView {
                                Label("This page couldn’t load", systemImage: "network.slash")
                            } description: {
                                Text(error)
                                Text(tab.url?.host ?? "").font(.caption)
                            } actions: {
                                Button("Reload page") { tab.reload() }.buttonStyle(.borderedProminent)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.background)
                        }
                        if tab.isLoading {
                            GeometryReader { geometry in
                                Rectangle().fill(Theme.accent)
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
            .background(.background)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { tab?.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(tab?.canGoBack != true).help("Back (⌘[)").accessibilityLabel("Back")
                Button { tab?.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(tab?.canGoForward != true).help("Forward (⌘])").accessibilityLabel("Forward")
            }
            ToolbarItem(placement: .principal) {
                HStack(spacing: 7) {
                    Image(systemName: tab?.isPrivate == true ? "eyeglasses" : (tab?.isSecure == true ? "lock" : "magnifyingglass"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .accessibilityLabel(tab?.isPrivate == true ? "Private browsing" : (tab?.isSecure == true ? "HTTPS connection" : "Address or search"))
                        .id("address-status-\(tab?.isPrivate == true)-\(tab?.isSecure == true)")
                    AddressField(text: $address, isEditing: $addressFocused,
                                 focusRequest: controller.addressFocusRequest, submit: {
                            controller.navigate(address)
                            return controller.addressError == nil
                        }, cancel: { syncAddress() })
                        .frame(height: 20)
                    if tab?.url != nil {
                        Button { tab?.isLoading == true ? tab?.stop() : tab?.reload() } label: {
                            Image(systemName: tab?.isLoading == true ? "xmark" : "arrow.clockwise")
                                .font(.system(size: 12)).frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(tab?.isLoading == true ? "Stop loading" : "Reload page")
                        .help(tab?.isLoading == true ? "Stop loading" : "Reload (⌘R)")
                    }
                }
                .padding(.leading, 12).padding(.trailing, tab?.url == nil ? 12 : 4)
                .frame(width: addressWidth, height: 28)
                .overlay {
                    Capsule().strokeBorder(addressFocused ? Theme.accent : .clear, lineWidth: 2)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showPasswords.toggle() } label: { Image(systemName: "key") }
                    .help("How to fill passwords in this page").accessibilityLabel("Password AutoFill help")
                    .popover(isPresented: $showPasswords) { PasswordsGuide(compact: true) }
                Button { showProtection.toggle() } label: {
                    Image(systemName: session.adBlocker.isEnabled(for: tab?.url, isPrivate: tab?.isPrivate == true) ? "shield.lefthalf.filled" : "shield.slash")
                }
                .help("Ad blocking").accessibilityLabel("Ad blocking")
                .popover(isPresented: $showProtection) {
                    AdBlockingPopover(session: session)
                }
                Button { controller.saveCurrentPage() } label: {
                    Image(systemName: controller.workspace?.existingItem(for: tab?.url ?? URL(string: "about:blank")!) != nil ? "bookmark.fill" : "bookmark")
                }
                .disabled(tab?.url == nil || tab?.isPrivate == true || controller.isCapturing)
                .accessibilityLabel("Save page with context")
                .help("Save page with context (⌘D)")
                Button { controller.library = .downloads } label: { Image(systemName: "arrow.down.circle") }
                    .accessibilityLabel("Downloads").help("Downloads")
                Button { controller.newTab() } label: { Image(systemName: "plus") }
                    .accessibilityLabel("New tab").help("New tab (⌘T)")
            }
        }
        .sheet(item: Binding(get: { controller.library == .bookmarks ? nil : controller.library }, set: { controller.library = $0 })) { section in
            LibraryView(controller: controller, section: section)
        }
        .sheet(item: $controller.captureDraft) { capture in CaptureSheet(controller: controller, capture: capture) }
        .onChange(of: controller.library) { _, value in
            if value == .bookmarks { controller.library = nil; controller.showWorkspace() }
        }
        .onChange(of: controller.workspaceRequest) { _, _ in openWindow(id: "workspace") }
        .alert("Workspace", isPresented: Binding(get: { controller.workspaceError != nil && controller.captureDraft == nil }, set: { if !$0 { controller.workspaceError = nil } })) {
            Button("OK") { controller.workspaceError = nil }
        } message: { Text(controller.workspaceError ?? "") }
        .alert("Unable to open address", isPresented: Binding(get: { controller.addressError != nil }, set: { if !$0 { controller.addressError = nil } })) {
            Button("OK") { controller.addressError = nil }
        } message: { Text(controller.addressError ?? "") }
        .onAppear { session.activateSelectedTab(); syncAddress(); controller.refreshReminders() }
        .onChange(of: session.selectedTabID) { _, _ in addressFocused = false; syncAddress(); showFind = false }
        .onChange(of: tab?.url) { _, _ in if !addressFocused { syncAddress() } }
        .onChange(of: controller.findRequest) { _, _ in showFind = true; findFocused = true }
        .onChange(of: controller.passwordsGuideRequest) { _, _ in showPasswords = true }
        .onChange(of: scenePhase) { _, phase in if phase != .active { session.saveNow() } }
    }

    private func syncAddress() { address = tab?.url?.absoluteString ?? "" }

    private func noticeBar(_ message: String, symbol: String, dismiss: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: symbol)
            Text(message).font(.caption)
            Spacer()
            if session.canPersist { Button("Dismiss", action: dismiss).buttonStyle(.borderless) }
        }
        .padding(10).background(.yellow.opacity(0.12))
    }
}
