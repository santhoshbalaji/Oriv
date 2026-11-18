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

struct BrowserSidebar: View {
    @Environment(\.browserTheme) private var theme
    @Bindable var controller: BrowserController
    var profiles: BrowserProfiles? = nil
    var focusRequest = 0
    @State private var closeOthers: UUID?
    @State private var closeToRight = false
    @State private var pendingFocus: UUID?
    @FocusState private var searchFocused: Bool
    @FocusState private var focusedTab: UUID?
    @FocusState private var utilityFocus: String?
    private var session: BrowserSession { controller.session }
    private var compact: Bool { controller.compactSidebar }
    private var filteredTabs: [BrowserTab] { SidebarTabs.filtered(session.orderedTabs, query: controller.tabSearch) }

    var body: some View {
        VStack(spacing: 8) {
            profileHeader
                .focused($utilityFocus, equals: "profile")
            searchField
            if let notice = profiles?.notice, !session.isExternalPrivate, !compact {
                Text(notice).font(.caption).foregroundStyle(theme.secondaryText).padding(.horizontal, 14)
            }
            tabCollection
            newTab
            footer
        }
        .padding(.bottom, 12)
        .foregroundStyle(theme.text)
        .transformPreference(SidebarKeyboardFocusKey.self) { $0 = $0 || searchFocused || utilityFocus != nil }
        .onChange(of: controller.tabSearchFocusRequest) { _, _ in searchFocused = true }
        .onChange(of: session.selectedTabID) { _, id in
            if let id, !filteredTabs.contains(where: { $0.id == id }) { controller.tabSearch = "" }
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
                    Image(systemName: session.isExternalPrivate ? "eyeglasses" : "rectangle.stack")
                    if !compact {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.isExternalPrivate ? "Private" : controller.profile?.name ?? "Personal").font(OrivType.title)
                            Text(SidebarTabs.countLabel(session.tabs.count)).font(OrivType.caption).foregroundStyle(theme.secondaryText)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .foregroundStyle(session.isExternalPrivate ? theme.privateAccent : theme.text)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(session.isExternalPrivate ? "Private browsing, \(SidebarTabs.countLabel(session.tabs.count))" : "\(controller.profile?.name ?? "Personal"), \(SidebarTabs.countLabel(session.tabs.count))")
            }
        }
        .frame(maxWidth: .infinity, minHeight: compact ? 30 : 58, alignment: compact ? .center : .leading)
        .padding(.horizontal, compact ? 8 : 18)
    }

    @ViewBuilder private var searchField: some View {
        if compact {
            Button { controller.searchTabs() } label: { Image(systemName: "magnifyingglass").frame(width: 40, height: 32) }
                .buttonStyle(ContentButtonStyle()).accessibilityLabel("Search tabs").help("Search Tabs (⇧⌘A)")
        } else {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").accessibilityHidden(true)
                TextField("Search tabs", text: $controller.tabSearch,
                          prompt: Text("Search tabs").foregroundStyle(theme.secondaryText)).textFieldStyle(.plain)
                    .focused($searchFocused).accessibilityLabel("Search tabs").accessibilityIdentifier("tabSearchField")
                    .onExitCommand { controller.tabSearch = ""; searchFocused = false; focusedTab = session.selectedTabID }
                    .onKeyPress(.downArrow) {
                        guard let first = filteredTabs.first else { return .ignored }
                        searchFocused = false; focusedTab = first.id; return .handled
                    }
                    .onSubmit {
                        if let first = filteredTabs.first { searchFocused = false; focusedTab = first.id; session.selectTab(first.id) }
                    }
                if controller.tabSearch.isEmpty {
                    Text("⇧⌘A").font(OrivType.caption).accessibilityHidden(true)
                } else {
                    Button { controller.tabSearch = ""; searchFocused = true } label: {
                        Image(systemName: "xmark.circle.fill").frame(width: 24, height: 24)
                    }.buttonStyle(.plain).accessibilityLabel("Clear tab search")
                }
            }
            .font(OrivType.detail).foregroundStyle(theme.secondaryText)
            .padding(.horizontal, 10).frame(height: 32)
            .background(theme.field.opacity(0.65), in: .rect(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(searchFocused ? theme.accent : .clear, lineWidth: 2) }
            .padding(.horizontal, 14)
        }
    }

    private var tabCollection: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(spacing: 3) {
                    let pinned = filteredTabs.filter(\.isPinned)
                    let regular = filteredTabs.filter { !$0.isPrivate && !$0.isPinned }
                    let privateTabs = filteredTabs.filter(\.isPrivate)
                    if compact {
                        ForEach(filteredTabs) { tab in tabItem(tab, tile: true) }
                    } else {
                        if !session.isExternalPrivate {
                            sectionHeading("Pinned", count: pinned.count, target: .pinned(true))
                            if pinned.isEmpty && controller.tabSearch.isEmpty {
                                Text("Drop tabs here to pin").font(OrivType.caption).foregroundStyle(theme.secondaryText)
                                    .frame(maxWidth: .infinity, minHeight: 34)
                                    .modifier(SidebarDropTargetModifier(target: .pinned(true), controller: controller))
                            }
                            if !controller.tabSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                // Search always exposes titles, including matching pins.
                                ForEach(pinned) { tab in tabItem(tab) }
                            } else {
                                    // At most eight eager cells; every remaining tab is lazy.
                                    ForEach(0..<((min(pinned.count, SidebarTabs.gridLimit) + 3) / 4), id: \.self) { row in
                                        HStack(spacing: 8) {
                                            ForEach(Array(pinned.dropFirst(row * 4).prefix(4))) { tab in tabItem(tab, tile: true) }
                                            if min(4, pinned.count - row * 4) < 4 { Spacer(minLength: 0) }
                                        }.padding(.horizontal, 6)
                                    }
                                    if pinned.count > SidebarTabs.gridLimit {
                                        sectionHeading("More pinned tabs", count: pinned.count - SidebarTabs.gridLimit)
                                        ForEach(Array(pinned.dropFirst(SidebarTabs.gridLimit))) { tab in tabItem(tab) }
                                    }
                            }
                            sectionHeading("Tabs", count: regular.count, target: .pinned(false))
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
                        Text("No matching tabs").font(OrivType.detail).foregroundStyle(theme.secondaryText).padding(12)
                    }
                }
                .padding(.horizontal, compact ? 8 : 10).padding(.bottom, 6)
            }
            .accessibilityIdentifier("sidebarTabs")
            .onChange(of: session.selectedTabID) { _, id in if let id { reader.scrollTo(id) } }
            .onChange(of: focusedTab) { _, id in if let id { reader.scrollTo(id) } }
            .onChange(of: focusRequest) { _, _ in
                pendingFocus = session.selectedTabID
                if let id = pendingFocus { reader.scrollTo(id) }
            }
            .onChange(of: compact) { _, _ in if let id = session.selectedTabID { reader.scrollTo(id) } }
            .onChange(of: session.tabs.map(\.id)) { _, ids in
                if let focusedTab, !ids.contains(focusedTab) { self.focusedTab = session.selectedTabID }
            }
        }
    }

    private func sectionHeading(_ title: String, count: Int, target: SidebarDropTarget? = nil) -> some View {
        SidebarSectionHeading(title: title, count: count, target: target, controller: controller)
    }

    private func tabItem(_ tab: BrowserTab, tile: Bool = false) -> some View {
        SidebarTabItem(tab: tab, selected: tab.id == session.selectedTabID, tile: tile, rail: compact,
                       focused: $focusedTab, select: { session.selectTab(tab.id) }, close: { controller.requestCloseTab(tab.id) })
            .id(tab.id)
            .draggable(SidebarTabTransfer(id: tab.id, owner: controller.sidebarDragID)) {
                Label(tab.displayTitle, systemImage: tab.isPinned ? "pin" : "globe").padding(8)
            }
            .modifier(SidebarDropTargetModifier(target: .tab(tab.id), controller: controller))
            .contextMenu { tabMenu(tab) }
            .onAppear { focusWhenReady(tab) }
            .onChange(of: focusRequest) { _, _ in focusWhenReady(tab) }
            .onKeyPress(.return) { session.selectTab(tab.id); return .handled }
            .onKeyPress(.escape) { controller.tabSearch = ""; return .handled }
            .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
                guard let next = SidebarTabs.keyboardTarget(from: tab.id, key: press.key, tabs: filteredTabs,
                    rail: compact || !controller.tabSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) else { return .ignored }
                focusedTab = next.id; session.selectTab(next.id); return .handled
            }
    }

    private func focusWhenReady(_ tab: BrowserTab) {
        guard tab.id == session.selectedTabID else { return }
        // Lazy targets must finish mounting before their focus binding accepts
        // a request. Visible targets use the same next-run-loop path.
        DispatchQueue.main.async {
            guard pendingFocus == tab.id else { return }
            focusedTab = tab.id; pendingFocus = nil
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
        Button { controller.newTab() } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus").frame(width: 20)
                if !compact { Text("New Tab"); Spacer(); Text("⌘T").font(OrivType.caption) }
            }.font(OrivType.body).frame(maxWidth: .infinity, minHeight: 36).contentShape(Rectangle())
        }.buttonStyle(ContentButtonStyle()).padding(.horizontal, compact ? 8 : 18)
            .focused($utilityFocus, equals: "new-tab")
            .accessibilityLabel("New Tab").accessibilityIdentifier("newTabButton").help("New Tab (⌘T)")
    }

    private var footer: some View {
        ViewThatFits {
            if !compact { HStack(spacing: 2) { footerButtons }.padding(4) }
            VStack(spacing: 2) { footerButtons }.padding(4)
        }
        .frame(maxWidth: .infinity)
        .background(theme.field.opacity(0.35), in: .rect(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(theme.separator.opacity(0.5), lineWidth: 0.5) }
        .padding(.horizontal, compact ? 6 : 12)
    }
    @ViewBuilder private var footerButtons: some View {
        ForEach(LibrarySection.allCases) { section in
            Button { controller.library = section } label: {
                Image(systemName: section.symbol).font(OrivType.body).frame(width: 32, height: 30)
                    .overlay(alignment: .topTrailing) {
                        if section == .downloads && controller.downloads.hasActiveDownloads {
                            Circle().fill(theme.accent).frame(width: 6, height: 6).padding(3).accessibilityHidden(true)
                        }
                    }
            }.buttonStyle(ContentButtonStyle()).foregroundStyle(theme.secondaryText)
                .focused($utilityFocus, equals: section.rawValue)
                .accessibilityLabel(section == .downloads && controller.downloads.hasActiveDownloads ? "Downloads in progress" : section.rawValue)
                .help(section.rawValue)
        }
        if !compact { Spacer(minLength: 0) }
        SettingsLink { Image(systemName: "gearshape").font(OrivType.body).frame(width: 32, height: 30) }
            .buttonStyle(ContentButtonStyle()).foregroundStyle(theme.secondaryText).accessibilityLabel("Settings").help("Settings (⌘,)")
            .focused($utilityFocus, equals: "settings")
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
            Text(title); Spacer(); Text("\(count)").monospacedDigit()
        }.font(OrivType.caption.weight(.medium)).foregroundStyle(theme.secondaryText)
            .padding(.horizontal, 4).frame(height: 28).padding(.top, 8)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let tab: BrowserTab
    let selected: Bool
    let tile: Bool
    let rail: Bool
    let focused: FocusState<UUID?>.Binding
    let select: () -> Void
    let close: () -> Void
    @State private var hovered = false
    @FocusState private var closeFocused: Bool
    var body: some View {
        HStack(spacing: 0) {
            Button(action: select) {
                HStack(spacing: 8) {
                    ZStack {
                        SiteIdentity(url: tab.url, size: tile ? 24 : 19, isPrivate: tab.isPrivate, isSelected: selected)
                        if tab.isLoading {
                            ProgressView().controlSize(.mini).tint(theme.accent)
                                .frame(width: tile ? 30 : 24, height: tile ? 30 : 24).accessibilityHidden(true)
                        }
                    }
                    if !tile { Text(tab.displayTitle).font(OrivType.body.weight(selected ? .medium : .regular)).rowTitleLines().frame(maxWidth: .infinity, alignment: .leading) }
                    if tab.mediaSuspended || tab.isPlayingAudio {
                        Image(systemName: tab.mediaSuspended ? "pause.circle" : "speaker.wave.2.fill")
                            .font(OrivType.caption).foregroundStyle(theme.accentText).accessibilityHidden(true)
                    }
                }.padding(.horizontal, tile ? 0 : 10).frame(maxWidth: .infinity, minHeight: tile && !rail ? 44 : 36).contentShape(Rectangle())
            }
            .buttonStyle(.plain).focusable().focused(focused, equals: tab.id)
            .accessibilityLabel(SidebarTabs.label(tab, selected: selected))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityCustomContent("Address", tab.url?.absoluteString ?? tab.hostname)
            .accessibilityAction(named: "Close Tab", close)
            if !tile {
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: 24, height: 24).contentShape(Rectangle()) }
                    .buttonStyle(.plain).foregroundStyle(theme.secondaryText).focused($closeFocused)
                    .opacity(hovered || selected || closeFocused || focused.wrappedValue == tab.id ? 1 : 0)
                    .accessibilityHidden(false)
                    .accessibilityLabel("Close \(tab.displayTitle)").help("Close tab").padding(.trailing, 4)
            }
        }
        .frame(width: tile && !rail ? 52 : nil)
        // A native foreground highlight lifts dark glass and shades light glass.
        // It must never become the opaque theme selection plate in the rail.
        .background(.primary.opacity(selected ? MacSidebarGlass.selectionOpacity : (hovered ? MacSidebarGlass.hoverOpacity : 0)),
                    in: .rect(cornerRadius: tile ? 12 : 9))
        .overlay(alignment: .leading) { if selected { SelectionMarker(height: tile ? 20 : 16).padding(.leading, 2) } }
        .overlay { RoundedRectangle(cornerRadius: tile ? 12 : 9).strokeBorder(focused.wrappedValue == tab.id || closeFocused ? theme.accent : (selected && contrast == .increased ? theme.text : .clear), lineWidth: 2) }
        .scaleEffect(tile && hovered && !reduceMotion ? 1.025 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
        .onHover { hovered = $0 }.help("\(tab.displayTitle)\n\(tab.hostname)")
        .preference(key: SidebarKeyboardFocusKey.self, value: focused.wrappedValue == tab.id || closeFocused)
    }
}

#if DEBUG
private struct SidebarCaptureBackdropKey: EnvironmentKey { static let defaultValue: Color? = nil }
private struct SidebarCaptureContrastKey: EnvironmentKey { static let defaultValue: ColorSchemeContrast? = nil }
extension EnvironmentValues {
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
    static let selectionOpacity = 0.04
    static let hoverOpacity = 0.02
    @Environment(\.browserTheme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.chromeReduceTransparencyOverride) private var captureReduceTransparency
    @Environment(\.sidebarContrast) private var contrast
    #if DEBUG
    @Environment(\.sidebarCaptureBackdrop) private var captureBackdrop
    #endif
    func body(content: Content) -> some View {
        if reduceTransparency || captureReduceTransparency || contrast == .increased {
            content.background(theme.surface, in: .rect(cornerRadius: 20))
                .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(contrast == .increased ? theme.text : theme.separator, lineWidth: contrast == .increased ? 1.5 : 0.5) }
        } else {
            glass(content)
                .overlay { RoundedRectangle(cornerRadius: 20).fill(theme.surface.opacity(Self.backingOpacity)) }
        }
    }
    @ViewBuilder private func glass(_ content: Content) -> some View {
        #if DEBUG
        if let captureBackdrop {
            content.background(captureBackdrop, in: .rect(cornerRadius: 20))
        } else {
            GlassEffectContainer { content.glassEffect(.regular, in: .rect(cornerRadius: 20)) }
        }
        #else
        GlassEffectContainer { content.glassEffect(.regular, in: .rect(cornerRadius: 20)) }
        #endif
    }
}
