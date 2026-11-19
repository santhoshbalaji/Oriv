import AppKit
import BrowserEngine
import SwiftUI
import UniformTypeIdentifiers

/// A drag is scoped to this controller, so another profile/window cannot move it.
struct SidebarTabTransfer: Codable, Transferable {
    let id: UUID
    let owner: UUID
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: UTType(exportedAs: "com.oriv.browser.sidebar-tab"))
    }
}

enum SidebarDropTarget { case tab(UUID), pinned(Bool) }
enum SidebarTabCommand { case pin, duplicate, moveUp, moveDown, media, close, newPrivate }

/// SwiftUI focus can use a window-sized AppKit responder. Publish ownership
/// separately so collapse can hand focus to its surviving toggle in this window.
struct SidebarKeyboardFocusKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// Shared by the real drop targets and their tests. Cross-section drops are
/// explicit on headings; a row drop never silently changes privacy or pin state.
@MainActor enum SidebarTabs {
    static let gridLimit = 8
    static func countLabel(_ count: Int) -> String { count == 1 ? "1 tab" : "\(count) tabs" }
    static func perform(_ command: SidebarTabCommand, tab: BrowserTab, controller: BrowserController) {
        guard controller.session.tabs.contains(where: { $0 === tab }) else { return }
        switch command {
        case .pin: controller.session.togglePinned(tab.id)
        case .duplicate: controller.session.duplicateTab(tab.id)
        case .moveUp: controller.session.moveTab(tab.id, offset: -1)
        case .moveDown: controller.session.moveTab(tab.id, offset: 1)
        case .media: tab.toggleMediaSuspension()
        case .close: controller.requestCloseTab(tab.id)
        case .newPrivate: controller.newTab(isPrivate: true)
        }
    }
    static func filtered(_ tabs: [BrowserTab], query: String) -> [BrowserTab] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return tabs.filter { query.isEmpty || $0.displayTitle.localizedCaseInsensitiveContains(query) || $0.hostname.localizedCaseInsensitiveContains(query) }
    }
    static func keyboardTarget(from id: UUID, key: KeyEquivalent, tabs: [BrowserTab], rail: Bool) -> BrowserTab? {
        guard let index = tabs.firstIndex(where: { $0.id == id }), !tabs.isEmpty else { return nil }
        let gridCount = min(gridLimit, tabs.filter(\.isPinned).count)
        let inGrid = !rail && index < gridCount
        let destination: Int
        switch key {
        case .upArrow: destination = inGrid ? (index >= 4 ? index - 4 : index) : index - 1
        case .downArrow: destination = inGrid ? min(gridCount, index + 4) : index + 1
        case .leftArrow: destination = index - 1
        case .rightArrow: destination = index + 1
        default: return nil
        }
        return tabs[max(0, min(tabs.count - 1, destination))]
    }
    static func label(_ tab: BrowserTab, selected: Bool) -> String {
        ([tab.displayTitle, tab.hostname] + (selected ? ["Selected"] : []) +
         (tab.isPinned ? ["Pinned"] : []) + (tab.isPrivate ? ["Private"] : []) +
         (tab.isLoading ? ["Loading"] : []) + (tab.mediaSuspended ? ["Media paused"] : (tab.isPlayingAudio ? ["Playing audio"] : [])))
            .joined(separator: ", ")
    }
    static func drop(_ items: [SidebarTabTransfer], on target: SidebarDropTarget, controller: BrowserController) -> Bool {
        guard items.count == 1, let item = items.first, item.owner == controller.sidebarDragID,
              let source = controller.session.tabs.first(where: { $0.id == item.id }) else { return false }
        switch target {
        case .pinned(let pinned):
            guard !source.isPrivate else { return false }
            controller.session.moveTab(source.id, intoPinnedSection: pinned)
        case .tab(let id):
            guard let destination = controller.session.tabs.first(where: { $0.id == id }),
                  source.isPrivate == destination.isPrivate, source.isPinned == destination.isPinned else { return false }
            controller.session.moveTab(source.id, to: id)
        }
        return true
    }
}

/// Keep the request independent of the focus binding: a LazyVStack can discard
/// focus assigned before the destination exists. Visibility is the acknowledgement
/// that scrolling has materialized the row; no delay or retry timer is needed.
private struct SidebarTabFocus: ViewModifier {
    let id: UUID
    let requestedID: UUID?
    let focused: FocusState<UUID?>.Binding
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .onScrollVisibilityChange { visible in
                self.visible = visible
                if visible { focusIfRequested() }
            }
            .onChange(of: requestedID) { _, _ in focusIfRequested() }
    }

    private func focusIfRequested() {
        if visible, requestedID == id { focused.wrappedValue = id }
    }
}

private struct SidebarFocusContext: Equatable {
    let rail: Bool
    let request: Int
}

struct BrowserSidebar: View {
    private let theme = Theme.sidebar
    @Bindable var controller: BrowserController
    var profiles: BrowserProfiles? = nil
    var focusRequest = 0
    var profileTrailingInset: CGFloat = 0
    @State private var closeOthers: UUID?
    @State private var closeToRight = false
    @State private var pendingFocus: UUID?
    @State private var draggingTab = false
    @State private var railAnchor: UUID?
    @State private var expandedAnchor: UUID?
    @State private var settledQuery = ""
    @FocusState private var searchFocused: Bool
    @FocusState private var focusedTab: UUID?
    @FocusState private var utilityFocus: String?
    private var session: BrowserSession { controller.session }
    private var compact: Bool { controller.sidebar.rail }
    private var peeking: Bool { controller.sidebar.peeking }
    private var railLayout: Bool { compact || peeking }
    private var filteredTabs: [BrowserTab] { SidebarTabs.filtered(session.orderedTabs, query: settledQuery) }

    var body: some View { sidebarContent.environment(\.browserTheme, Theme.sidebar) }

    private var sidebarContent: some View {
        VStack(spacing: railLayout ? 6 : 0) {
            if !railLayout { profileHeader.focused($utilityFocus, equals: "profile") }
            searchField
            if railLayout { newTab }
            if let notice = profiles?.notice, !session.isExternalPrivate, !compact {
                Text(notice).font(.caption).foregroundStyle(theme.secondaryText).padding(.horizontal, 14)
            }
            tabCollection
            if !railLayout { newTab.padding(.bottom, MacBrowserLayout.sidebarFooterGap) }
            footer
        }
        .padding(.horizontal, railLayout ? 0 : MacBrowserLayout.sidebarInset)
        .padding(.bottom, railLayout ? 0 : MacBrowserLayout.sidebarInset)
        .font(.system(size: 14))
        .foregroundStyle(theme.text)
        .focusEffectDisabled()
        .onDragSessionUpdated { drag in
            switch drag.phase {
            case .initial, .active: draggingTab = true; controller.sidebar.dragging = true; controller.sidebar.pointer(true, drag: true)
            default: draggingTab = false; controller.sidebar.dragging = false; controller.sidebar.pointer(false)
            }
        }
        .transformPreference(SidebarKeyboardFocusKey.self) { $0 = $0 || searchFocused || utilityFocus != nil }
        .task(id: controller.tabSearch) {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard !Task.isCancelled else { return }
            settledQuery = controller.tabSearch
        }
        .onChange(of: controller.tabSearchFocusRequest) { _, _ in if !controller.tabSearchPanel { searchFocused = true } }
        .onChange(of: session.selectedTabID) { _, id in
            controller.sidebarTooltip.dismiss()
            if let id, !SidebarTabs.filtered(session.orderedTabs, query: controller.tabSearch).contains(where: { $0.id == id }) { controller.tabSearch = "" }
        }
        .confirmationDialog(closeToRight ? "Close tabs to the right?" : "Close other tabs?", isPresented: Binding(get: { closeOthers != nil }, set: { if !$0 { closeOthers = nil } })) {
            Button("Close Tabs", role: .destructive) { if let id = closeOthers { session.closeOtherTabs(id, toRight: closeToRight) }; closeOthers = nil }
        } message: { Text("Pinned tabs and tabs in the other privacy group stay open. Unsaved website forms in closed tabs may be lost.") }
    }

    private var profileHeader: some View {
        Group {
            if let profiles, !session.isExternalPrivate {
                ProfileMenu(profiles: profiles, iconOnly: compact, tabCount: session.tabs.count)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: session.isExternalPrivate ? "eyeglasses" : "rectangle.stack").font(.system(size: 17, weight: .semibold))
                    if !compact {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.isExternalPrivate ? "Private" : controller.profile?.name ?? "Personal").font(OrivType.title)
                            if !session.tabs.isEmpty { Text(SidebarTabs.countLabel(session.tabs.count)).font(OrivType.caption).foregroundStyle(theme.secondaryText) }
                        }
                        Spacer(minLength: 0)
                    }
                }
                .padding(.horizontal, MacBrowserLayout.sidebarRowInset)
                .foregroundStyle(session.isExternalPrivate ? theme.privateAccent : theme.text)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(session.isExternalPrivate ? "Private browsing, \(SidebarTabs.countLabel(session.tabs.count))" : "\(controller.profile?.name ?? "Personal"), \(SidebarTabs.countLabel(session.tabs.count))")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44, alignment: .leading)
        .browserGeometryMarker("sidebarProfileGeometry")
        .padding(.trailing, profileTrailingInset)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var searchField: some View {
        if railLayout {
            Button { controller.searchTabs() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").frame(width: 42, height: 36)
                    if peeking { Text("Search Tabs").modifier(SidebarLabelFade()); Spacer() }
                }
            }.frame(width: compact ? MacBrowserLayout.railItemWidth : nil)
                .buttonStyle(ContentButtonStyle()).focused($utilityFocus, equals: "search")
                .browserGeometryMarker("sidebarSearchGeometry")
                .accessibilityLabel("Search tabs").help("Search Tabs (⇧⌘A)")
                .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
                .padding(.horizontal, MacBrowserLayout.railInset)
        } else {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").accessibilityHidden(true)
                TextField("Search tabs", text: $controller.tabSearch,
                          prompt: Text("Search tabs").foregroundStyle(theme.secondaryText)).textFieldStyle(.plain)
                    .focusEffectDisabled().focused($searchFocused).accessibilityLabel("Search tabs").accessibilityIdentifier("tabSearchField")
                    .onExitCommand { controller.tabSearch = ""; focusTabAfterSearch(session.selectedTabID) }
                    .onKeyPress(.downArrow) {
                        guard let first = filteredTabs.first else { return .ignored }
                        focusTabAfterSearch(first.id); return .handled
                    }
                    .onSubmit {
                        if let first = filteredTabs.first { focusTabAfterSearch(first.id); session.selectTab(first.id) }
                    }
                if controller.tabSearch.isEmpty {
                    Text("⇧⌘A").font(.system(size: 10)).accessibilityHidden(true)
                } else {
                    Button { controller.tabSearch = ""; searchFocused = true } label: {
                        Image(systemName: "xmark.circle.fill").frame(width: 24, height: 24)
                    }.buttonStyle(ContentButtonStyle()).accessibilityLabel("Clear tab search")
                }
            }
            .font(OrivType.detail).foregroundStyle(theme.secondaryText)
            .padding(.horizontal, MacBrowserLayout.sidebarRowInset).frame(height: 32)
            .background(theme.field.opacity(searchFocused ? 1 : 0.7), in: .rect(cornerRadius: 9))
            .modifier(ChromeFocusIndicator(focused: searchFocused, marker: "sidebarSearchFocusIndicator"))
            .browserGeometryMarker("sidebarSearchGeometry")
            .padding(.bottom, 10)
        }
    }

    private func focusTabAfterSearch(_ id: UUID?) {
        searchFocused = false
        // Finish the native field editor's resignation before requesting a
        // SwiftUI row. Doing both in one transaction can discard the new focus.
        DispatchQueue.main.async { pendingFocus = id }
    }

    private var tabRows: some View {
        LazyVStack(spacing: railLayout ? 6 : 1) {
            let pinned = filteredTabs.filter(\.isPinned)
            let regular = filteredTabs.filter { !$0.isPrivate && !$0.isPinned }
            let privateTabs = filteredTabs.filter(\.isPrivate)
            if railLayout {
                ForEach(Array(filteredTabs.enumerated()), id: \.element.id) { index, tab in
                    if index > 0, filteredTabs[index - 1].isPinned != tab.isPinned || filteredTabs[index - 1].isPrivate != tab.isPrivate {
                        Rectangle().fill(theme.separator.opacity(0.7)).frame(width: 24, height: 1).padding(.vertical, 6)
                    }
                    tabItem(tab, tile: true)
                }
            } else {
                if !session.isExternalPrivate {
                    if !pinned.isEmpty { sectionHeading("Pinned", count: pinned.count, target: .pinned(true)) }
                    if pinned.isEmpty && controller.tabSearch.isEmpty && draggingTab {
                        Text("Pin tab").font(OrivType.caption).foregroundStyle(theme.secondaryText)
                            .frame(maxWidth: .infinity, minHeight: 27)
                            .modifier(SidebarDropTargetModifier(target: .pinned(true), controller: controller))
                    }
                    if !controller.tabSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        // Search always exposes titles, including matching pins.
                        ForEach(pinned) { tab in tabItem(tab) }
                    } else {
                            // At most eight eager cells; every remaining tab is lazy.
                            ForEach(0..<((min(pinned.count, SidebarTabs.gridLimit) + 3) / 4), id: \.self) { row in
                                HStack(spacing: 8) {
                                    ForEach(0..<4) { column in
                                        let index = row * 4 + column
                                        if index < pinned.count { tabItem(pinned[index], tile: true) }
                                        else { Color.clear.frame(width: 56, height: 48) }
                                    }
                                }.padding(.horizontal, 6).padding(.vertical, 4)
                            }
                            if pinned.count > SidebarTabs.gridLimit {
                                sectionHeading("More pinned tabs", count: pinned.count - SidebarTabs.gridLimit)
                                ForEach(Array(pinned.dropFirst(SidebarTabs.gridLimit))) { tab in tabItem(tab) }
                            }
                    }
                    if !regular.isEmpty { sectionHeading("Tabs", count: regular.count, target: .pinned(false)) }
                    else if draggingTab && controller.tabSearch.isEmpty {
                        Text("Unpin tab").font(OrivType.caption).frame(maxWidth: .infinity, minHeight: 27)
                            .modifier(SidebarDropTargetModifier(target: .pinned(false), controller: controller))
                    }
                    ForEach(regular) { tab in tabItem(tab) }
                }
                if !privateTabs.isEmpty {
                    Section {
                        ForEach(privateTabs) { tab in tabItem(tab) }
                    } header: { sectionHeading("Private", count: privateTabs.count) }
                    .accessibilityLabel("Private tabs")
                }
            }
            if filteredTabs.isEmpty {
                Text(controller.tabSearch.isEmpty ? "No tabs" : "No matching tabs").font(OrivType.detail).foregroundStyle(theme.secondaryText).padding(12)
            }
        }
        .padding(.horizontal, railLayout ? MacBrowserLayout.railInset : 0).padding(.bottom, railLayout ? 0 : 10)
        // Lazy rows share tab IDs across the two collections. Rebuild
        // their layout on a mode change instead of reusing expanded cells.
        .scrollTargetLayout()
        .id(railLayout)
        .transaction(value: railLayout) { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    private var tabCollection: some View {
        ScrollViewReader { reader in
            ScrollView {
                tabRows
            }
            .scrollPosition(id: Binding(get: { railLayout ? railAnchor : expandedAnchor }, set: {
                if railLayout { railAnchor = $0 } else { expandedAnchor = $0 }
            }))
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    controller.sidebar.voiceOver = NSWorkspace.shared.isVoiceOverEnabled
                    controller.sidebar.pointer(true, moved: true)
                case .ended: controller.sidebar.pointer(false)
                }
            }
            // On Macs with legacy scrollbars, .hidden still reserves a 17 pt
            // gutter. The 56 pt rail needs its full width for 42 pt focus rings
            // and 7 pt insets; keyboard arrows and the scroll wheel remain usable.
            .scrollIndicators(railLayout ? .never : .hidden)
            .accessibilityIdentifier("sidebarTabs")
            .onChange(of: session.selectedTabID) { _, id in if let id { reader.scrollTo(id) } }
            .onChange(of: pendingFocus) { _, id in
                if let id { reader.scrollTo(id) }
            }
            .onChange(of: focusedTab) { _, id in
                if let id {
                    reader.scrollTo(id)
                    // Acknowledges the target, or cancels it if the user moved
                    // focus to another row while scrolling was in progress.
                    pendingFocus = nil
                }
            }
            .onChange(of: SidebarFocusContext(rail: railLayout, request: focusRequest)) { previous, next in
                // A busy run loop can coalesce the toggle handoff with the
                // collection rebuild. Cancel the old layout's request before
                // applying the new one, rather than letting separate observers
                // erase the handoff after it has been installed.
                pendingFocus = previous.request != next.request ? session.selectedTabID : nil
                if let id = pendingFocus ?? (next.rail ? railAnchor : expandedAnchor) ?? session.selectedTabID {
                    reader.scrollTo(id)
                }
            }
            .onChange(of: searchFocused) { _, focused in if focused { pendingFocus = nil } }
            .onChange(of: utilityFocus) { _, focused in if focused != nil { pendingFocus = nil } }
            .onChange(of: session.tabs.map(\.id)) { _, ids in
                if let pendingFocus, !ids.contains(pendingFocus) { self.pendingFocus = nil }
                if let focusedTab, !ids.contains(focusedTab) { pendingFocus = session.selectedTabID }
            }
        }
    }

    private func sectionHeading(_ title: String, count: Int, target: SidebarDropTarget? = nil) -> some View {
        SidebarSectionHeading(title: title, count: count, target: target, controller: controller)
    }

    private func tabItem(_ tab: BrowserTab, tile: Bool = false) -> some View {
        SidebarTabItem(tab: tab, selected: tab.id == session.selectedTabID, tile: tile, rail: railLayout, peek: peeking,
                       focused: $focusedTab, select: { session.selectTab(tab.id) }, close: { controller.requestCloseTab(tab.id) }, tooltip: controller.sidebarTooltip, nextFocus: { session.selectedTabID })
            .id(tab.id)
            .draggable(SidebarTabTransfer(id: tab.id, owner: controller.sidebarDragID)) {
                Label(tab.displayTitle, systemImage: tab.isPinned ? "pin" : "globe").padding(8)
            }
            .modifier(SidebarDropTargetModifier(target: .tab(tab.id), controller: controller))
            .contextMenu { tabMenu(tab) }
            .modifier(SidebarTabFocus(id: tab.id, requestedID: pendingFocus, focused: $focusedTab))
            .onKeyPress(.return) { session.selectTab(tab.id); return .handled }
            .onKeyPress(.escape) { controller.tabSearch = ""; return .handled }
            .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
                guard let next = SidebarTabs.keyboardTarget(from: pendingFocus ?? tab.id, key: press.key, tabs: filteredTabs,
                    rail: railLayout || !controller.tabSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) else { return .ignored }
                pendingFocus = focusedTab == next.id ? nil : next.id
                session.selectTab(next.id); return .handled
            }
    }

    @ViewBuilder private func tabMenu(_ tab: BrowserTab) -> some View {
        if !tab.isPrivate {
            Button(tab.isPinned ? "Unpin Tab" : "Pin Tab", systemImage: tab.isPinned ? "pin.slash" : "pin") { SidebarTabs.perform(.pin, tab: tab, controller: controller) }
        }
        Button("Duplicate Tab", systemImage: "plus.square.on.square") { SidebarTabs.perform(.duplicate, tab: tab, controller: controller) }
        Button("Move Up", systemImage: "arrow.up") { SidebarTabs.perform(.moveUp, tab: tab, controller: controller) }
        Button("Move Down", systemImage: "arrow.down") { SidebarTabs.perform(.moveDown, tab: tab, controller: controller) }
        if tab.url != nil {
            Button(tab.mediaSuspended ? "Resume Media Playback" : "Pause and Block Media Playback", systemImage: tab.mediaSuspended ? "play" : "pause") { SidebarTabs.perform(.media, tab: tab, controller: controller) }
        }
        Divider()
        Button("Close Tab", systemImage: "xmark") { SidebarTabs.perform(.close, tab: tab, controller: controller) }
        Button("Close Other Tabs") { closeToRight = false; closeOthers = tab.id }
        Button("Close Tabs to the Right") { closeToRight = true; closeOthers = tab.id }
        Divider()
        Button("New Private Tab", systemImage: "eyeglasses") { SidebarTabs.perform(.newPrivate, tab: tab, controller: controller) }
    }

    private var newTab: some View {
        Button { controller.newTab(isPrivate: session.selectedTab?.isPrivate ?? session.isExternalPrivate) } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus").frame(width: railLayout ? 42 : 19)
                if peeking { Text("New Tab").modifier(SidebarLabelFade()); Spacer() }
                if !railLayout { Text("New Tab"); Spacer(); Text("⌘T").font(.system(size: 10)).foregroundStyle(theme.secondaryText) }
            }.font(OrivType.body).padding(.horizontal, railLayout ? 0 : MacBrowserLayout.sidebarRowInset).frame(maxWidth: .infinity, minHeight: 36).contentShape(Rectangle())
        }.buttonStyle(ContentButtonStyle()).frame(width: compact ? 42 : nil)
            .padding(.horizontal, peeking ? MacBrowserLayout.railInset : 0)
            .browserGeometryMarker("sidebarNewTabGeometry")
            .focused($utilityFocus, equals: "new-tab")
            .accessibilityLabel("New Tab").accessibilityIdentifier("newTabButton").help("New Tab (⌘T)")
    }

    @ViewBuilder private var footer: some View {
        if railLayout {
            VStack(alignment: .leading, spacing: 6) { footerButtons }.frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, MacBrowserLayout.railInset).foregroundStyle(theme.secondaryText)
                .browserGeometryMarker("sidebarFooterGeometry")
        } else {
            HStack(spacing: 0) { footerButtons }.padding(.horizontal, 8).frame(height: 42)
                .background(theme.surface, in: .rect(cornerRadius: 14))
                .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(theme.separator.opacity(0.5), lineWidth: 0.5) }
                .browserGeometryMarker("sidebarFooterGeometry")
        }
    }
    @ViewBuilder private var footerButtons: some View {
        ForEach(LibrarySection.allCases) { section in
            Button { controller.library = section } label: {
                HStack(spacing: 8) {
                    Image(systemName: section == .bookmarks ? "book" : section.symbol).font(.system(size: 16)).frame(width: railLayout ? 42 : 32, height: railLayout ? 36 : 32)
                    .overlay(alignment: .topTrailing) {
                        if section == .downloads && controller.downloads.hasActiveDownloads {
                            Circle().fill(theme.accent).frame(width: 6, height: 6).padding(3).accessibilityHidden(true)
                        }
                    }
                    if peeking { Text(section.rawValue).font(OrivType.body).modifier(SidebarLabelFade()); Spacer() }
                }
            }.buttonStyle(ContentButtonStyle()).foregroundStyle(theme.secondaryText)
                .focused($utilityFocus, equals: section.rawValue)
                .accessibilityLabel(section == .downloads && controller.downloads.hasActiveDownloads ? "Downloads in progress" : section.rawValue)
                .help(section.rawValue).browserGeometryMarker("sidebarFooter-\(section.rawValue)")
        }
        if !railLayout { Spacer(minLength: 0) }
        SettingsLink {
            HStack(spacing: 8) {
                Image(systemName: "gearshape").font(.system(size: 16)).frame(width: railLayout ? 42 : 32, height: railLayout ? 36 : 32)
                if peeking { Text("Settings").font(OrivType.body).modifier(SidebarLabelFade()); Spacer() }
            }
        }
            .buttonStyle(ContentButtonStyle()).foregroundStyle(theme.secondaryText).accessibilityLabel("Settings").help("Settings (⌘,)")
            .focused($utilityFocus, equals: "settings")
            .browserGeometryMarker("sidebarFooter-Settings")
    }
}

private struct SidebarSectionHeading: View {
    @Environment(\.browserTheme) private var theme
    let title: String
    let count: Int
    let target: SidebarDropTarget?
    let controller: BrowserController
    var body: some View {
        HStack(spacing: 6) {
            if title == "Private" { Image(systemName: "eyeglasses").accessibilityHidden(true) }
            Text(title).modifier(SidebarLabelFade()); Spacer(); if count > 0 { Text("\(count)").font(.system(size: 11)).monospacedDigit() }
        }.font(OrivType.caption.weight(.semibold)).foregroundStyle(theme.secondaryText)
            .browserGeometryMarker("sidebarSection-\(title)")
            .padding(.horizontal, MacBrowserLayout.sidebarRowInset).frame(height: 27).padding(.top, title == "Private" ? 8 : (title == "Pinned" ? 0 : 4))
            .accessibilityElement(children: .ignore).accessibilityLabel("\(title), \(SidebarTabs.countLabel(count))").accessibilityAddTraits(.isHeader)
            .modifier(SidebarDropTargetModifier(target: target, controller: controller))
            .help(target.map { _ in title == "Pinned" ? "Drop a regular tab here to pin it" : "Drop a pinned tab here to unpin it" } ?? title)
    }
}

private struct SidebarDropTargetModifier: ViewModifier {
    @Environment(\.browserTheme) private var theme
    let target: SidebarDropTarget?
    let controller: BrowserController
    @State private var targeted = false
    func body(content: Content) -> some View {
        if let target {
            content.contentShape(Rectangle())
                .dropDestination(for: SidebarTabTransfer.self) { items, _ in SidebarTabs.drop(items, on: target, controller: controller) } isTargeted: { targeted = $0 }
                .overlay(alignment: .top) { if targeted { Rectangle().fill(theme.accent).frame(height: 2).accessibilityHidden(true) } }
        } else { content }
    }
}

private struct SidebarTabItem: View {
    @Environment(\.browserTheme) private var theme
    @Environment(\.sidebarContrast) private var contrast
    @Environment(\.browserReduceMotion) private var reduceMotion
    @Environment(\.chromeFocusState) private var input
    let tab: BrowserTab
    let selected: Bool
    let tile: Bool
    let rail: Bool
    let peek: Bool
    let focused: FocusState<UUID?>.Binding
    let select: () -> Void
    let close: () -> Void
    let tooltip: SidebarTooltip
    let nextFocus: () -> UUID?
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var pointerHovered = false
    #if DEBUG
    @Environment(\.sidebarCaptureState) private var captureState
    #endif
    private var hovered: Bool {
        #if DEBUG
        pointerHovered || captureState.hover == tab.id
        #else
        pointerHovered
        #endif
    }
    private var keyboardFocused: Bool {
        #if DEBUG
        focused.wrappedValue == tab.id || captureState.focus == tab.id
        #else
        focused.wrappedValue == tab.id
        #endif
    }
    private var showsFocus: Bool {
        #if DEBUG
        captureState.focus == tab.id || ((keyboardFocused || closeFocused) && (input?.showsFocus ?? NSApp.isFullKeyboardAccessEnabled))
        #else
        (keyboardFocused || closeFocused) && (input?.showsFocus ?? NSApp.isFullKeyboardAccessEnabled)
        #endif
    }
    private var loading: Bool {
        #if DEBUG
        tab.isLoading || captureState.loading == tab.id
        #else
        tab.isLoading
        #endif
    }
    private var audio: Bool {
        #if DEBUG
        tab.isPlayingAudio || captureState.audio == tab.id
        #else
        tab.isPlayingAudio
        #endif
    }
    @FocusState private var closeFocused: Bool
    var body: some View {
        HStack(spacing: 0) {
            Button(action: select) {
                if rail {
                    HStack(spacing: 8) {
                        railIcon
                        if peek { Text(tab.displayTitle).font(OrivType.body).lineLimit(1).modifier(SidebarLabelFade()).frame(maxWidth: .infinity, alignment: .leading) }
                    }.contentShape(Rectangle())
                } else {
                    HStack(spacing: 8) {
                        favicon
                        if !tile { Text(tab.displayTitle).font(.system(size: textSize.isAccessibilitySize ? 26 : 13, weight: selected ? .medium : .regular)).rowTitleLines().modifier(SidebarLabelFade()).frame(maxWidth: .infinity, alignment: .leading) }
                    }.padding(.leading, tile ? 0 : MacBrowserLayout.sidebarRowInset).frame(maxWidth: .infinity, minHeight: tile ? 48 : (textSize.isAccessibilitySize ? 60 : 36)).contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain).focusable().focusEffectDisabled().focused(focused, equals: tab.id)
            .accessibilityLabel(SidebarTabs.label(tab, selected: selected))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityCustomContent("Address", tab.url?.absoluteString ?? tab.hostname)
            .accessibilityAction(named: "Close Tab", closeTab)
            if !rail && !tile {
                if tab.mediaSuspended || audio {
                    Button { tab.toggleMediaSuspension() } label: {
                        Image(systemName: tab.mediaSuspended ? "pause.circle" : "speaker.wave.2.fill")
                            .font(.system(size: 11)).frame(width: 24, height: 24)
                    }.buttonStyle(ContentButtonStyle()).foregroundStyle(theme.accentText)
                        .accessibilityLabel(tab.mediaSuspended ? "Resume media for \(tab.displayTitle)" : "Pause media for \(tab.displayTitle)")
                }
                Button(action: closeTab) { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24).contentShape(Rectangle()) }
                    .buttonStyle(.plain).focusEffectDisabled().foregroundStyle(theme.secondaryText).focused($closeFocused)
                    .opacity(hovered || selected || closeFocused || keyboardFocused ? 1 : 0)
                    .accessibilityHidden(false)
                    .accessibilityLabel("Close \(tab.displayTitle)").help("Close tab")
                    .browserGeometryMarker("sidebarClose-\(tab.id)")
                    .padding(.trailing, MacBrowserLayout.sidebarRowInset)
            }
        }
        .frame(width: rail && !peek ? 42 : (tile && !rail ? 56 : nil))
        .background(SidebarHitTarget(kind: .tab(tab.id)))
        .browserGeometryMarker("sidebarKeyboardFocus-\(tab.id)", when: keyboardFocused)
        // The mock's lifted selection stays centred within the rail inset.
        .background(selected ? theme.selection : (hovered ? theme.thread : (tile && !rail ? theme.field.opacity(0.6) : .clear)),
                    in: .rect(cornerRadius: rail ? 10 : (tile ? 12 : 9)))
        .browserGeometryMarker("sidebarSelection-\(tab.id)", when: selected)
        .overlay(alignment: .leading) {
            if selected {
                SelectionMarker(height: 16).browserGeometryMarker("sidebarAccent-\(tab.id)").padding(.leading, 1)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: rail ? 10 : (tile ? 12 : 9))
                .strokeBorder(showsFocus ? theme.accent : (selected && contrast == .increased ? theme.text : .clear), lineWidth: 2)
                .allowsHitTesting(false).accessibilityHidden(true)
                .browserGeometryMarker("sidebarFocusIndicator-\(tab.id)", when: showsFocus)
        }
        .anchorPreference(key: SidebarTooltipBounds.self, value: .bounds) { [tab.id: $0] }
        .onContinuousHover { phase in
            switch phase {
            case .active:
                pointerHovered = true
                tooltip.hover(id: tab.id, text: SidebarTabs.label(tab, selected: selected))
            case .ended: pointerHovered = false; tooltip.exit()
            }
        }
        .onDisappear { if tooltip.tabID == tab.id || tooltip.pendingID == tab.id { tooltip.dismiss() } }
        .preference(key: SidebarKeyboardFocusKey.self, value: focused.wrappedValue == tab.id || closeFocused)
    }

    private func closeTab() {
        let restore = focused.wrappedValue == tab.id || closeFocused
        close()
        if restore {
            DispatchQueue.main.async { focused.wrappedValue = nextFocus() }
        }
    }

    private var railIcon: some View {
        favicon.frame(width: 42, height: 36)
            .overlay(alignment: .bottomTrailing) {
                if tab.mediaSuspended || audio { statusBadge(tab.mediaSuspended ? "pause.fill" : "speaker.wave.2.fill") }
            }
            .overlay(alignment: .topTrailing) { if tab.isPrivate { statusBadge("eyeglasses") } }
    }

    private func statusBadge(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 10, weight: .bold)).frame(width: 12, height: 12)
            .background(theme.surface, in: Circle()).accessibilityHidden(true).allowsHitTesting(false)
    }

    private var favicon: some View {
        ZStack {
            SiteIdentity(url: tab.url, size: rail ? 22 : (tile ? 24 : 19), isPrivate: tab.isPrivate, isSelected: selected, sidebarIcon: true)
                .browserGeometryMarker("sidebarFavicon-\(tab.id)")
            if loading {
                Circle().trim(from: 0, to: 0.75).stroke(theme.accent, lineWidth: 2)
                    .frame(width: rail ? 26 : 24, height: rail ? 26 : 24).accessibilityHidden(true)
            }
        }.frame(width: rail ? 22 : (tile ? 24 : 19), height: rail ? 22 : (tile ? 24 : 19))
    }
}

#if DEBUG
struct SidebarCaptureState {
    var hover: UUID? = nil
    var focus: UUID? = nil
    var loading: UUID? = nil
    var audio: UUID? = nil
}
private struct SidebarCaptureStateKey: EnvironmentKey { static let defaultValue = SidebarCaptureState() }
private struct SidebarCaptureBackdropKey: EnvironmentKey { static let defaultValue: Color? = nil }
private struct SidebarCaptureContrastKey: EnvironmentKey { static let defaultValue: ColorSchemeContrast? = nil }
private struct SidebarCaptureReduceMotionKey: EnvironmentKey { static let defaultValue: Bool? = nil }
extension EnvironmentValues {
    var sidebarCaptureState: SidebarCaptureState {
        get { self[SidebarCaptureStateKey.self] }
        set { self[SidebarCaptureStateKey.self] = newValue }
    }
    /// macOS exposes the system Reduce Motion environment as read-only.
    var sidebarCaptureReduceMotion: Bool? {
        get { self[SidebarCaptureReduceMotionKey.self] }
        set { self[SidebarCaptureReduceMotionKey.self] = newValue }
    }
    /// Synthetic glass input for off-screen contrast evidence, never a live compositor capture.
    var sidebarCaptureBackdrop: Color? {
        get { self[SidebarCaptureBackdropKey.self] }
        set { self[SidebarCaptureBackdropKey.self] = newValue }
    }
    var sidebarCaptureContrast: ColorSchemeContrast? {
        get { self[SidebarCaptureContrastKey.self] }
        set { self[SidebarCaptureContrastKey.self] = newValue }
    }
}
#endif

extension EnvironmentValues {
    var browserReduceMotion: Bool {
        #if DEBUG
        sidebarCaptureReduceMotion ?? accessibilityReduceMotion
        #else
        accessibilityReduceMotion
        #endif
    }
    var sidebarContrast: ColorSchemeContrast {
        #if DEBUG
        sidebarCaptureContrast ?? colorSchemeContrast
        #else
        colorSchemeContrast
        #endif
    }
}

/// A single system glass surface, never one effect per tab. A contrast backing
/// above the glass bounds even its brightest/darkest sampled pixels, so theme
/// text cannot become white-on-light-grey when the page and system differ.
/// check-contrast.py reads these constants to test the composited backgrounds.
struct MacSidebarGlass: ViewModifier {
    static let backingOpacity = 0.96
    private let theme = Theme.sidebar
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.chromeReduceTransparencyOverride) private var captureReduceTransparency
    @Environment(\.sidebarContrast) private var contrast
    #if DEBUG
    @Environment(\.sidebarCaptureBackdrop) private var captureBackdrop
    #endif
    func body(content: Content) -> some View {
        if reduceTransparency || captureReduceTransparency || contrast == .increased {
            edge(content.background(theme.surface))
        } else {
            edge(glass(content.background(theme.surface.opacity(Self.backingOpacity))))
        }
    }
    private func edge<Surface: View>(_ content: Surface) -> some View {
        content.overlay(alignment: .trailing) {
            Rectangle().fill(contrast == .increased ? theme.text : theme.separator.opacity(0.5))
                .frame(width: contrast == .increased ? 1.5 : 0.5).allowsHitTesting(false).accessibilityHidden(true)
        }
    }
    @ViewBuilder private func glass<Surface: View>(_ content: Surface) -> some View {
        #if DEBUG
        if let captureBackdrop {
            content.background(captureBackdrop)
        } else {
            GlassEffectContainer { content.glassEffect(.regular, in: Rectangle()) }
        }
        #else
        GlassEffectContainer { content.glassEffect(.regular, in: Rectangle()) }
        #endif
    }
}
